import AVFoundation
import Foundation
import OSLog

/// Captura de micrófono para dictado.
///
/// Los modelos de ASR (Parakeet, Whisper) quieren exactamente lo mismo: PCM
/// mono, Float32, 16 kHz. El nodo de entrada de macOS entrega otra cosa —
/// típicamente 48 kHz y, según el dispositivo, más de un canal— así que acá
/// convertimos en el propio callback del tap y acumulamos los samples ya
/// listos para el modelo. Así al soltar la tecla no hay que hacer ninguna
/// conversión: el array está listo.
///
/// Dos detalles que definen si el dictado se siente bien o no:
///
/// 1. **Arranque en frío.** `AVAudioEngine.start()` tarda decenas de
///    milisegundos y ese tiempo se come el principio de la primera palabra. La
///    tentación es dejar el motor corriendo siempre, pero el propio header de
///    AVAudioEngine avisa que una vez habilitado el nodo de entrada, el
///    indicador naranja de micrófono aparece *mientras el motor corra*, se esté
///    grabando o no. Un punto naranja permanente en una app que promete que
///    todo es local se lee exactamente como lo contrario.
///
///    Así que se separa en dos: `prepare()` hace toda la configuración cara
///    (formato, conversor, `engine.prepare()`) sin arrancar nada ni encender
///    ningún indicador, y `startRecording()` solo hace el `start()`. El costo
///    en el momento del gatillo baja a unas pocas decenas de milisegundos.
///
///    Quien prefiera latencia cero entre dictados seguidos puede activar
///    `keepsMicrophoneWarm`, que deja el motor prendido un rato — con el punto
///    naranja encendido, y eso se dice explícitamente en Ajustes.
///
/// 2. **Pre-roll.** Con el motor caliente, además, se puede recuperar audio
///    anterior al gatillo: la gente empieza a hablar *mientras* aprieta la
///    tecla, no después. Se mantiene un buffer circular con los últimos
///    `preRollDuration` segundos y se antepone a la grabación.
actor AudioCapture {

    // MARK: - Configuración

    /// Frecuencia de muestreo que esperan los modelos de ASR.
    static let targetSampleRate: Double = 16_000

    /// Cuánto audio previo al gatillo se conserva para no comerse el arranque.
    private let preRollDuration: TimeInterval = 0.35

    /// Cuánto sigue corriendo el motor sin grabar, cuando se pidió mantenerlo
    /// caliente.
    private let idleShutdownDelay: TimeInterval = 30

    /// Si se deja el micrófono tomado entre dictados.
    ///
    /// Apagado por defecto: gana latencia en dictados encadenados a cambio de
    /// dejar el indicador naranja prendido, y además fuerza a los auriculares
    /// Bluetooth al perfil HFP, que degrada audiblemente el sonido que se está
    /// escuchando. Que lo decida quien lo necesite.
    var keepsMicrophoneWarm: Bool = false

    /// Corte duro de seguridad: nadie dicta 10 minutos seguidos de una sola vez,
    /// y sin límite un toggle olvidado llenaría la RAM.
    private let maxRecordingDuration: TimeInterval = 600

    // MARK: - Estado

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    /// Formato con el que se armó el conversor, para detectar cambios de
    /// dispositivo entre un dictado y el siguiente.
    private var configuredInputFormat: AVAudioFormat?

    /// Dispositivo de entrada del sistema cuando se armó el grafo.
    ///
    /// El formato solo no alcanza para saber si cambió el micrófono: dos
    /// distintos suelen compartirlo. Esto es la identidad real.
    private var configuredInputDevice: AudioDeviceID?

    private var isEngineRunning = false
    private var isRecording = false

    /// Samples de la grabación en curso, ya a 16 kHz mono.
    private var recordedSamples: [Float] = []

    /// Buffer circular con el audio inmediatamente anterior al gatillo.
    private var preRoll: [Float] = []
    private var preRollCapacity: Int { Int(Self.targetSampleRate * preRollDuration) }

    private var shutdownTask: Task<Void, Never>?
    private var levelContinuation: AsyncStream<Float>.Continuation?

    /// Observador de cambios de configuración del motor de audio.
    ///
    /// Es lo que avisa cuando cambia el dispositivo de entrada **sin que se
    /// enchufe ni se desenchufe nada**: elegir otro micrófono en Ajustes del
    /// Sistema entre dos que ya estaban conectados. Antes solo se escuchaban
    /// `AVCaptureDeviceWasConnected` y `…Disconnected`, que en ese caso no
    /// disparan, y la app se quedaba grabando del micrófono anterior.
    ///
    /// Había una mitigación parcial en `startEngine()`, que compara el formato
    /// contra el de la última configuración. No alcanza por dos motivos: dos
    /// micrófonos distintos suelen compartir formato —48 kHz es lo habitual— y
    /// entonces la comparación pasa; y con el micrófono caliente el motor ya
    /// está corriendo, así que `startEngine()` ni se ejecuta.
    private var configurationObserver: NSObjectProtocol?

    private let logger = Logger(subsystem: "com.acti.susurro", category: "AudioCapture")

    // MARK: - Nivel de entrada (para el HUD)

    /// Abre un flujo con el nivel de entrada normalizado 0…1.
    ///
    /// Alimenta la onda del HUD y nada más: ninguna decisión depende de este
    /// valor. Se crea uno nuevo por sesión de escucha —el anterior se cierra—
    /// porque un `AsyncStream` tiene un solo consumidor y dejar continuaciones
    /// viejas colgando pierde memoria.
    func levelStream() -> AsyncStream<Float> {
        levelContinuation?.finish()
        let (stream, continuation) = AsyncStream<Float>.makeStream()
        levelContinuation = continuation
        return stream
    }

    // MARK: - Errores

    enum CaptureError: LocalizedError {
        case noInputDevice
        case formatUnsupported(String)
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return String(localized: "No hay ningún micrófono disponible.")
            case .formatUnsupported(let detail):
                return String(localized: "El formato del micrófono no es compatible: \(detail)")
            case .engineFailed(let detail):
                return String(localized: "No se pudo iniciar la captura de audio: \(detail)")
            }
        }
    }

    // MARK: - Ciclo de vida

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    /// Hace toda la configuración cara sin tomar el micrófono.
    ///
    /// Se llama al arrancar la app y cada vez que cambia el dispositivo de
    /// entrada. Configura el tap y llama a `engine.prepare()`, que asigna los
    /// recursos del grafo de audio pero no arranca la captura — así el
    /// indicador naranja sigue apagado y el `start()` posterior es barato.
    func prepare() throws {
        observeConfigurationChanges()
        guard !isEngineRunning else { return }
        try configureEngine()
        engine.prepare()
    }

    /// Empieza a escuchar los cambios de configuración del motor.
    ///
    /// Se engancha acá y no en un `init` porque `prepare()` es lo primero que
    /// corre siempre, y registrarlo dos veces no hace daño: la guarda se ocupa.
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }

        // El `object: engine` es importante: sin él llegan los cambios de
        // cualquier motor de audio del proceso.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // La notificación llega en una cola cualquiera, así que se vuelve al
            // actor antes de tocar nada del grafo.
            Task { await self?.handleInputDeviceChange() }
        }
    }

    /// Toma el micrófono ya mismo, sin grabar todavía.
    ///
    /// Solo se usa cuando `keepsMicrophoneWarm` está activo: llena el buffer de
    /// pre-roll para que el gatillo no pierda ni la primera sílaba.
    func warmUp() throws {
        shutdownTask?.cancel()
        shutdownTask = nil
        guard keepsMicrophoneWarm, !isEngineRunning else { return }
        try startEngine()
    }

    /// Comienza a acumular audio. Devuelve cuando el motor ya está capturando.
    func startRecording() async throws {
        shutdownTask?.cancel()
        shutdownTask = nil

        if !isEngineRunning {
            try startEngine()
        }

        recordedSamples.removeAll(keepingCapacity: true)
        recordedSamples.reserveCapacity(Int(Self.targetSampleRate * 15))

        // El pre-roll trae la fracción de segundo previa al gatillo.
        recordedSamples.append(contentsOf: preRoll)
        isRecording = true
        logger.debug("grabación iniciada con \(self.preRoll.count) samples de pre-roll")
    }

    /// Corta la grabación y devuelve el audio capturado a 16 kHz mono.
    @discardableResult
    func stopRecording() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false

        let samples = recordedSamples
        recordedSamples.removeAll(keepingCapacity: true)
        levelContinuation?.yield(0)

        releaseMicrophone()

        logger.debug("grabación detenida: \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / Self.targetSampleRate)) s)")
        return samples
    }

    /// Aborta sin devolver nada (cancelación por Esc, error, etc.).
    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        recordedSamples.removeAll(keepingCapacity: true)
        levelContinuation?.yield(0)
        releaseMicrophone()
    }

    /// Suelta el micrófono ahora o dentro de un rato, según la preferencia.
    private func releaseMicrophone() {
        if keepsMicrophoneWarm {
            scheduleIdleShutdown()
        } else {
            // Por defecto se suelta enseguida: el punto naranja se apaga en
            // cuanto termina el dictado, que es lo que la gente espera de una
            // app que dice no estar escuchando.
            shutdown()
        }
    }

    /// Suelta el micrófono de inmediato. Lo llama el shutdown diferido y también
    /// el cierre de la app.
    func shutdown() {
        shutdownTask?.cancel()
        shutdownTask = nil
        guard isEngineRunning else { return }

        engine.stop()
        isEngineRunning = false
        preRoll.removeAll(keepingCapacity: false)
        // El tap y el conversor se dejan puestos: rearmarlos es la parte cara y
        // `startEngine()` los revalida contra el formato del dispositivo actual
        // antes de reusarlos.
        logger.debug("captura detenida, micrófono liberado")
    }

    var recordingDuration: TimeInterval {
        Double(recordedSamples.count) / Self.targetSampleRate
    }

    var isActive: Bool { isRecording }

    /// Cambia la política de micrófono caliente desde Ajustes.
    func setKeepsWarm(_ enabled: Bool) {
        keepsMicrophoneWarm = enabled
        if !enabled, !isRecording {
            shutdown()
        }
    }

    // MARK: - Interno

    /// Arma el grafo de audio y el conversor. No arranca la captura: después de
    /// esto el indicador de micrófono sigue apagado.
    private func configureEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        // Un micrófono ausente o recién desconectado se presenta con 0 canales
        // o 0 Hz. Arrancar el motor así aborta con una excepción de Obj-C que
        // no se puede atrapar desde Swift, así que hay que chequearlo antes.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw CaptureError.noInputDevice
        }

        guard let targetFormat else {
            throw CaptureError.formatUnsupported("no se pudo crear el formato de 16 kHz")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.formatUnsupported(
                "\(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) canales")
        }
        // Downmix a mono cuando el dispositivo entrega estéreo (varias
        // interfaces USB lo hacen aunque solo una entrada tenga señal).
        converter.downmix = true
        self.converter = converter
        self.configuredInputFormat = inputFormat
        self.configuredInputDevice = Self.defaultInputDeviceID()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // El tap corre en un hilo de audio en tiempo real. Convertimos acá
            // (barato, vDSP por debajo) y mandamos el resultado al actor.
            guard let converted = Self.convert(buffer, using: converter, to: targetFormat) else {
                return
            }
            Task { await self.ingest(converted) }
        }
    }

    /// Cuál es el micrófono que el sistema tiene puesto como entrada.
    ///
    /// Se pregunta a CoreAudio directamente porque `AVAudioEngine` no lo expone,
    /// y es la única forma de distinguir «cambió el micrófono» de «cambió el
    /// formato». Devuelve `nil` si no hay ninguno, que es un estado legítimo
    /// —una Mac sin micrófono conectado— y no un error.
    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Nombre del micrófono que se está usando, para poder mostrarlo.
    ///
    /// Existe porque «¿agarró el micrófono nuevo?» era imposible de contestar
    /// desde afuera: la app no decía en ninguna parte de qué entrada estaba
    /// grabando, así que un cambio de dispositivo que no se detectaba se veía
    /// idéntico a uno que sí. Con el nombre a la vista, la respuesta es mirar.
    func currentInputDeviceName() -> String? {
        guard let deviceID = Self.defaultInputDeviceID() else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }

        let resolved = name as String
        return resolved.isEmpty ? nil : resolved
    }

    private func startEngine() throws {
        // El dispositivo pudo haber cambiado desde el último `prepare()`, y hay
        // que darse cuenta antes de grabar del micrófono equivocado.
        //
        // Se comparan dos cosas y no una. El formato detecta los cambios
        // groseros —una interfaz USB a 96 kHz en lugar del micrófono interno—
        // pero **no alcanza**: dos micrófonos distintos comparten formato a
        // menudo, y a 48 kHz mono la comparación no ve ninguna diferencia
        // mientras el grafo sigue apuntando al anterior. Por eso se compara
        // además el identificador del dispositivo de entrada del sistema, que
        // es la pregunta que de verdad importa.
        //
        // Esta comprobación no depende de que llegue ninguna notificación, así
        // que cubre el caso en que el motor estaba detenido cuando la persona
        // cambió de micrófono — que es lo más común, porque el motor solo queda
        // prendido si se activó mantener el micrófono listo.
        let currentFormat = engine.inputNode.inputFormat(forBus: 0)
        let currentDevice = Self.defaultInputDeviceID()
        if converter == nil || configuredInputFormat != currentFormat
            || configuredInputDevice != currentDevice
        {
            try configureEngine()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            converter = nil
            configuredInputFormat = nil
            configuredInputDevice = nil
            throw CaptureError.engineFailed(error.localizedDescription)
        }

        isEngineRunning = true
        logger.debug("captura iniciada — entrada: \(currentFormat.sampleRate) Hz × \(currentFormat.channelCount) ch")
    }

    /// Rearma el grafo tras un cambio de dispositivo de entrada.
    func handleInputDeviceChange() {
        let wasRecording = isRecording
        // Estaba tomado el micrófono sin grabar: hay que volver a dejarlo así.
        let wasWarm = isEngineRunning && !isRecording

        shutdown()

        // El conversor se descarta siempre, sin comparar formatos.
        //
        // La comparación existe en `startEngine()` como atajo barato, pero acá
        // sería un error: dos micrófonos distintos comparten formato a menudo
        // —48 kHz es lo habitual— y entonces la comparación diría que no cambió
        // nada mientras el grafo sigue apuntando al dispositivo anterior. Cuando
        // el sistema avisa que la configuración cambió, se rehace y listo.
        converter = nil
        configuredInputFormat = nil
        configuredInputDevice = nil

        do {
            try prepare()
            let format = engine.inputNode.inputFormat(forBus: 0)
            let device = currentInputDeviceName() ?? "desconocido"
            logger.notice(
                "entrada rearmada — \(device, privacy: .public) · \(format.sampleRate, privacy: .public) Hz × \(format.channelCount, privacy: .public) ch")
        } catch {
            logger.error("no se pudo rearmar la entrada: \(error.localizedDescription, privacy: .public)")
        }

        // Volver a calentarlo si lo estaba. Sin esto, cambiar de micrófono
        // apagaba en silencio la función de mantenerlo listo, y el siguiente
        // dictado perdía la primera sílaba sin ningún motivo visible.
        if wasWarm, keepsMicrophoneWarm {
            try? warmUp()
        }

        if wasRecording {
            // Si el micrófono cambió en medio de un dictado no se puede seguir;
            // quien orquesta se entera porque `isActive` pasa a falso.
            logger.notice("el dispositivo de entrada cambió durante la grabación")
        }
    }

    /// Convierte un buffer del formato del dispositivo a 16 kHz mono Float32.
    /// Estático y `nonisolated` a propósito: corre en el hilo de audio.
    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> [Float]? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, statusPtr in
            if consumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPtr.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil,
              let channel = output.floatChannelData?[0], output.frameLength > 0
        else { return nil }

        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Recibe audio ya convertido desde el tap.
    private func ingest(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        if isRecording {
            recordedSamples.append(contentsOf: samples)

            // Freno de emergencia por si un toggle queda abierto.
            if recordingDuration > maxRecordingDuration {
                logger.warning("se alcanzó el límite de \(self.maxRecordingDuration) s; cortando")
                isRecording = false
            }
        } else {
            // Sin grabar, el audio va al buffer circular de pre-roll.
            preRoll.append(contentsOf: samples)
            if preRoll.count > preRollCapacity {
                preRoll.removeFirst(preRoll.count - preRollCapacity)
            }
        }

        levelContinuation?.yield(Self.rmsLevel(samples))
    }

    /// RMS convertido a una escala perceptual 0…1 para la animación del HUD.
    private nonisolated static func rmsLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()

        // -50 dBFS ≈ silencio de sala, 0 dBFS ≈ saturación.
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 50) / 50, 0), 1)
    }

    private func scheduleIdleShutdown() {
        shutdownTask?.cancel()
        shutdownTask = Task { [idleShutdownDelay] in
            try? await Task.sleep(for: .seconds(idleShutdownDelay))
            guard !Task.isCancelled else { return }
            await self.shutdown()
        }
    }
}
