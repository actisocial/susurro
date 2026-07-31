import FluidAudio
import Foundation
import OSLog

/// Motor por defecto: Parakeet TDT de NVIDIA, en CoreML, sobre el Neural Engine.
///
/// Dos cosas de este motor merecen explicación, porque no son obvias y las dos
/// vienen de bugs reales de upstream:
///
/// **1. El silencio del final rompe los dictados cortos.** Parakeet v3 tiene un
/// bug abierto (NVIDIA NeMo/Speech #15757) por el cual un enunciado corto con
/// cola de silencio decodifica a cadena vacía. Es exactamente la forma que
/// produce una app de dictado: se suelta la tecla un rato después de terminar
/// de hablar. Por eso el audio se recorta a la región con voz *antes* de
/// mandárselo al modelo, y si aun así vuelve vacío se reintenta con un recorte
/// más ajustado. Sin esto, una porción nada despreciable de los dictados cortos
/// devuelve nada en silencio — el peor bug posible, porque parece que la app no
/// escuchó.
///
/// **2. La caché de modelos de FluidAudio no valida nada.** Su chequeo de
/// "modelo instalado" es la mera existencia del directorio (issue #819), así que
/// una descarga interrumpida deja la app permanentemente rota: el directorio
/// existe, la librería no vuelve a bajar nada, y cargar falla para siempre.
/// Acá se lleva un manifiesto propio y se valida al arrancar; ante cualquier
/// discrepancia, se borra y se vuelve a bajar.
actor ParakeetEngine: SpeechEngine {

    private var manager: AsrManager?
    private var loadedModel: ASRModel?
    private var gate: SpeechGate?

    private let store: ModelStore
    private let logger = Logger(subsystem: "com.acti.susurro", category: "Parakeet")

    init(store: ModelStore) {
        self.store = store
    }

    var isReady: Bool { manager != nil }

    // MARK: - Preparación

    func prepare(
        _ model: ASRModel, progress: @escaping @Sendable (PreparationProgress) -> Void
    ) async throws {
        guard model.engine == .parakeet else {
            throw SpeechEngineError.engineUnavailable("modelo \(model.id) no es de Parakeet")
        }
        if loadedModel?.id == model.id, manager != nil {
            progress(PreparationProgress(phase: .loading, fraction: 1))
            return
        }

        let version = Self.version(for: model)
        let precision = Self.precision(for: model)
        // Ver `ASRModel.enclosingFolderName`: se le pasa la ruta ya "adelantada"
        // para que FluidAudio deposite los archivos dentro del directorio que
        // este store administra, y no al lado.
        let directory = store.directory(for: model)
            .appendingPathComponent(model.enclosingFolderName, isDirectory: true)

        // El manifiesto propio es la defensa contra el issue #819: FluidAudio da
        // por instalado cualquier directorio que exista, así que sin esto una
        // descarga cortada se cargaría rota para siempre.
        //
        // Lo que ya no se hace es borrar en cuanto algo esté a medias. Ver
        // `ModelStore.Salvage`: FluidAudio reanuda por rango con ETag y valida
        // el tamaño final contra el que declara Hugging Face, así que conservar
        // los bytes de una interrupción limpia es seguro y ahorra volver a bajar
        // cientos de megas.
        switch store.salvage(model) {
        case .nothingToDo:
            break
        case .resume(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            logger.notice("se reanuda \(model.id, privacy: .public) desde \(size, privacy: .public)")
        case .discard(let reason):
            logger.notice("se descarta \(model.id, privacy: .public): \(reason, privacy: .public)")
            try? store.remove(model)
        }

        if !store.isInstalled(model) {
            try store.checkDiskSpace(for: model)
            try await store.beginInstall(model)
        }

        // El medidor mira el directorio en vez de derivar los bytes de la
        // fracción: ver `DownloadMeter`.
        let meter = DownloadMeter(directory: store.directory(for: model), expected: model.downloadBytes)

        do {
            let models = try await AsrModels.downloadAndLoad(
                to: directory,
                version: version,
                encoderPrecision: precision,
                progressHandler: { downloadProgress in
                    progress(
                        meter.sample(
                            phase: Self.translate(downloadProgress.phase),
                            fraction: downloadProgress.fractionCompleted))
                }
            )

            // Cargar en memoria lo ya compilado tarda lo suyo y no emite avance.
            // Anunciarlo evita el último tramo de silencio, que es justo cuando
            // la persona ya está esperando hace rato.
            progress(PreparationProgress(phase: .loading, fraction: 1))

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)

            self.manager = manager
            self.loadedModel = model
            try store.completeInstall(model)

            logger.info("modelo \(model.id, privacy: .public) cargado")
        } catch {
            // Si algo falló, el directorio queda a medias. Se marca para que el
            // próximo intento lo borre en vez de heredar el estado roto.
            store.markFailed(model)
            throw Self.translate(error)
        }

        // El VAD es chiquito (~1 MB) y se comparte entre motores; se carga en
        // segundo plano para no demorar el primer dictado.
        if gate == nil {
            Task { [weak self] in
                let gate = try? await SpeechGate()
                await self?.adopt(gate)
            }
        }
    }

    private func adopt(_ gate: SpeechGate?) {
        guard self.gate == nil else { return }
        self.gate = gate
    }

    // MARK: - Transcripción

    func transcribe(_ samples: [Float], language: LanguageHint) async throws -> Transcript {
        guard let manager else { throw SpeechEngineError.modelNotInstalled }

        let started = Date()
        let audioDuration = Double(samples.count) / 16_000

        // Recorte a la región con voz. Además de esquivar el bug de la cola de
        // silencio, ahorra trabajo: no tiene sentido pasarle por el encoder los
        // 400 ms de nada que quedan al principio y al final de cada dictado.
        let trimmed = await gate?.trimToSpeech(samples) ?? samples

        guard !trimmed.isEmpty else {
            logger.debug("no se detectó voz; no se transcribe")
            return Transcript(text: "", audioDuration: audioDuration,
                              processingDuration: Date().timeIntervalSince(started))
        }

        var text = try await run(manager, on: trimmed, language: language)

        // Red de seguridad para el bug de arriba: si el recorte no alcanzó y el
        // modelo devolvió vacío pese a haber voz detectada, se reintenta con un
        // recorte más agresivo antes de darse por vencido.
        if text.isEmpty, let gate {
            let tight = await gate.trimToSpeech(samples, padding: 0.05)
            if !tight.isEmpty, tight.count != trimmed.count {
                logger.notice("decodificó vacío; reintentando con recorte ajustado")
                text = try await run(manager, on: tight, language: language)
            }
        }

        return Transcript(
            text: text,
            audioDuration: audioDuration,
            processingDuration: Date().timeIntervalSince(started)
        )
    }

    private func run(
        _ manager: AsrManager, on samples: [Float], language: LanguageHint
    ) async throws -> String {
        // El estado del decodificador es por enunciado. Reutilizarlo entre
        // dictados independientes arrastra contexto de uno al siguiente y
        // produce arranques raros.
        var state: TdtDecoderState
        do {
            state = try TdtDecoderState()
        } catch {
            throw SpeechEngineError.transcriptionFailed(error.localizedDescription)
        }

        do {
            let result = try await manager.transcribe(
                samples, decoderState: &state, language: Self.language(for: language))
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw SpeechEngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    func unload() async {
        manager = nil
        loadedModel = nil
        logger.debug("modelo descargado de memoria")
    }

    // MARK: - Traducción de tipos

    private static func version(for model: ASRModel) -> AsrModelVersion {
        switch model.variant {
        case "tdt-ctc-110m": return .tdtCtc110m
        default:             return .v3
        }
    }

    private static func precision(for model: ASRModel) -> ParakeetEncoderPrecision {
        model.variant.hasSuffix("int4") ? .int4 : .int8
    }

    /// Fase de FluidAudio traducida a la propia, como todo lo que cruza el borde
    /// de un SDK.
    ///
    /// La que importa es `.compiling`. FluidAudio reparte la fracción mitad y
    /// mitad entre descargar y compilar, así que del 50 % al 100 % la operación
    /// no toca la red: compila para el Neural Engine. Antes esta fase se
    /// descartaba y la app decía «Descargando» todo el tiempo, incluida la mitad
    /// en la que el número no se mueve porque la compilación solo avisa al
    /// terminar cada modelo.
    private static func translate(_ phase: DownloadPhase) -> PreparationProgress.Phase {
        switch phase {
        case .listing:
            return .listing
        case .downloading(let completed, let total):
            return .downloading(file: completed, of: total)
        case .compiling(let name):
            return .compiling(model: name)
        }
    }

    /// La pista de idioma solo la usa v3 (filtra los tokens candidatos por
    /// sistema de escritura); los demás la ignoran sin quejarse.
    private static func language(for hint: LanguageHint) -> Language? {
        switch hint {
        case .automatic: return nil
        case .spanish:   return .spanish
        case .english:   return .english
        }
    }

    private static func translate(_ error: Error) -> SpeechEngineError {
        if let error = error as? SpeechEngineError { return error }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("network")
            || text.localizedCaseInsensitiveContains("offline")
            || text.localizedCaseInsensitiveContains("internet") {
            return .downloadFailed(String(localized: "no hay conexión a internet"))
        }
        return .downloadFailed(text)
    }
}
