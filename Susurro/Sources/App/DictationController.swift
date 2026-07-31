import AppKit
import Foundation
import Observation
import OSLog

/// En qué anda la app. El ícono de la barra, el HUD y el menú son todos
/// funciones de esto.
enum DictationState: Equatable {
    case idle
    /// Cargando modelos. No se puede dictar todavía.
    case preparing(PreparationProgress)
    case listening(locked: Bool)
    case transcribing
    case refining
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .listening, .transcribing, .refining: return true
        default: return false
        }
    }

    var isRecording: Bool {
        if case .listening = self { return true }
        return false
    }
}

/// El coordinador del dictado: escucha el gatillo, graba, transcribe, refina e
/// inserta.
///
/// Todo el flujo vive acá y en un solo hilo (el principal) a propósito. El
/// trabajo pesado está en actores —captura, ASR, LLM— pero las *transiciones de
/// estado* son secuenciales y ordenadas. Handy terminó necesitando un
/// coordinador de un solo hilo con tests llamados
/// `push_to_talk_release_while_recording_defers_release` justamente porque
/// repartir esta máquina de estados entre varias colas produce dictados
/// fantasma y grabaciones que nunca cierran.
@MainActor
@Observable
final class DictationController {

    // MARK: - Estado observable

    private(set) var state: DictationState = .idle

    /// Progreso del modelo de limpieza, o `nil` si no hay nada en curso.
    ///
    /// Va aparte de `state` porque son dos cosas independientes: el refinado se
    /// prepara *sin bloquear* —el dictado crudo tiene que andar aunque el LLM
    /// todavía no esté— así que puede estar bajando mientras el estado ya es
    /// `.idle` y se puede dictar. Meterlo en la misma máquina de estados
    /// obligaría a elegir cuál de las dos cosas contar, y hoy la respuesta era
    /// no contar ninguna: se llamaba con `{ _ in }` y 2,5 GB bajaban en secreto.
    private(set) var refinementProgress: PreparationProgress?

    /// Nivel de entrada 0…1 para la onda del HUD.
    private(set) var inputLevel: Float = 0
    /// Último texto insertado. Vive solo hasta el próximo dictado: no hay
    /// historial, y es deliberado — la gente pidió explícitamente no tener sus
    /// dictados guardados en ningún lado.
    private(set) var lastTranscript: String?
    private(set) var lastNotice: String?

    // MARK: - Colaboradores

    private let capture = AudioCapture()
    private let injector = TextInjector()
    private let store: ModelStore
    private let preferences: Preferences
    let permissions: Permissions

    private var parakeet: ParakeetEngine
    private var whisper: WhisperEngine?
    /// El motor del sistema es de macOS 26+, así que no se puede nombrar su
    /// tipo en una propiedad de una clase que compila para macOS 14. Se guarda
    /// como existencial y se recupera con un cast dentro del `#available`.
    private var appleEngineBox: (any SpeechEngine)?
    private var refiner: LocalLLMRefiner

    private var hotkeys: HotkeyMonitor?

    /// App que tenía el foco cuando arrancó el dictado. Se captura al principio
    /// porque para cuando termina la transcripción la persona puede haber
    /// cambiado de ventana, y pegar a ciegas metería el texto en el lugar
    /// equivocado.
    private var pendingTarget: TextInjector.Target?

    private var levelTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var startSoundTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.acti.susurro", category: "Dictation")

    // MARK: - Ciclo de vida

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
        self.permissions = Permissions()
        self.store = ModelStore()
        self.parakeet = ParakeetEngine(store: store)
        self.refiner = LocalLLMRefiner(
            model: preferences.refinementModel,
            modelsDirectory: store.rootDirectory)
    }

    func start() {
        permissions.refresh()
        installHotkeys()
        observeSystemEvents()

        Task { await prepareEngines() }
    }

    func stop() {
        hotkeys?.stop()
        levelTask?.cancel()
        pipelineTask?.cancel()
        startSoundTask?.cancel()
        Task { await capture.shutdown() }
        waitForRefinerToSettle()
    }

    /// Bloquea un instante para que ninguna generación quede corriendo dentro de
    /// MLX cuando el proceso termine.
    ///
    /// Al salir se destruyen los objetos estáticos de MLX —entre ellos la caché
    /// de kernels de Metal—, y un hilo que siga generando en ese momento los usa
    /// después de liberados: SIGSEGV al cerrar. Sólo puede pasar si el último
    /// dictado expiró por tiempo y se cierra la app enseguida, así que en la
    /// práctica la espera es de cero.
    ///
    /// Se bloquea a propósito, con tope: `applicationWillTerminate` es
    /// sincrónico y el proceso muere al volver, así que una tarea suelta no
    /// llegaría a correr. El tope existe porque colgar el cierre es peor que el
    /// crash que evita.
    private func waitForRefinerToSettle() {
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) { [refiner] in
            await refiner.drain()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    // MARK: - Gatillo

    func installHotkeys() {
        let monitor = hotkeys ?? HotkeyMonitor { [weak self] event in
            self?.handle(event)
        }
        hotkeys = monitor
        monitor.start(trigger: preferences.trigger)
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .begin:  beginDictation()
        case .commit: commitDictation()
        case .cancel: cancelDictation()
        case .lock:
            if case .listening = state { state = .listening(locked: true) }
        }
    }

    // MARK: - Flujo principal

    private func beginDictation() {
        // No arrancar nunca una grabación que después no se va a poder
        // transcribir: es preferible decir "todavía estoy cargando" que perder
        // el audio de alguien que ya empezó a hablar.
        if case .preparing(let progress) = state {
            // Con el detalle cuando lo hay: quien intenta dictar en medio de la
            // descarga quiere saber cuánto falta, no que le repitan que espere.
            let percent = Int(progress.fraction * 100)
            if let detail = progress.detail {
                notify(String(localized: "\(progress.summary) — \(detail)"))
            } else {
                notify(String(localized: "\(progress.summary) — \(percent)%"))
            }
            return
        }
        guard !state.isBusy else { return }

        guard permissions.microphone.isGranted else {
            Task {
                await permissions.requestMicrophone()
                if !permissions.microphone.isGranted {
                    notify(String(localized: "Susurro necesita acceso al micrófono."))
                }
            }
            return
        }

        pendingTarget = TextInjector.Target.current()
        lastNotice = nil

        Task {
            do {
                try await capture.startRecording()
                state = .listening(locked: false)
                startLevelUpdates()
                scheduleStartSound()
            } catch {
                state = .failed(error.localizedDescription)
                notify(error.localizedDescription)
            }
        }
    }

    /// El sonido de inicio se demora un cuarto de segundo.
    ///
    /// Un dictado puede cancelarse apenas empezado —porque la persona en
    /// realidad estaba tecleando un atajo, o porque tocó la tecla sin querer—.
    /// Sonar de inmediato haría que cada atajo con el modificador produzca un
    /// «tink» fantasma. Con este retardo, los falsos arranques son silenciosos y
    /// los dictados de verdad suenan igual: nadie empieza a hablar en menos de
    /// 250 ms.
    private func scheduleStartSound() {
        guard preferences.playsFeedbackSounds else { return }
        startSoundTask?.cancel()
        startSoundTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, state.isRecording else { return }
            Sounds.start()
        }
    }

    private func commitDictation() {
        guard state.isRecording else { return }
        stopLevelUpdates()
        if preferences.playsFeedbackSounds { Sounds.stop() }

        pipelineTask = Task {
            let samples = await capture.stopRecording()
            await runPipeline(on: samples)
        }
    }

    private func cancelDictation() {
        guard state.isRecording else { return }
        startSoundTask?.cancel()
        stopLevelUpdates()
        Task {
            await capture.cancelRecording()
            state = .idle
        }
    }

    /// Audio → texto → refinado → inserción.
    private func runPipeline(on samples: [Float]) async {
        let duration = Double(samples.count) / AudioCapture.targetSampleRate

        // Menos de un cuarto de segundo no es un dictado: es un roce.
        guard duration > 0.25 else {
            state = .idle
            return
        }

        state = .transcribing

        let engine = currentEngine()
        let transcript: Transcript
        do {
            // Techo de tiempo sobre la transcripción.
            //
            // No está por si el modelo es lento —Parakeet hace 5 segundos de
            // audio en 200 ms— sino porque una etapa colgada deja el HUD en
            // «Transcribiendo…» para siempre, sin forma de salir salvo matar la
            // app. Ya pasó una vez con un deadlock en el motor del sistema, y el
            // problema no fue el deadlock en sí sino que nada lo atajaba.
            //
            // El presupuesto escala con el audio: lo que se mide es que el
            // motor esté trabajando, no que sea rápido.
            let budget = max(20.0, transcriptionBudget(for: samples))
            let language = preferences.language
            transcript = try await withTimeout(.seconds(budget)) {
                try await engine.transcribe(samples, language: language)
            }
        } catch is TimeoutError {
            state = .failed(String(localized: "La transcripción se colgó. Probá con otro modelo en Ajustes."))
            notify(String(localized: "La transcripción se colgó. Probá con otro modelo en Ajustes."))
            scheduleReturnToIdle()
            return
        } catch {
            state = .failed(error.localizedDescription)
            notify(error.localizedDescription)
            scheduleReturnToIdle()
            return
        }

        guard !transcript.isEmpty else {
            // Distinguir "no dijiste nada" de "falló algo" importa: son dos
            // problemas distintos con dos soluciones distintas, y no decir nada
            // deja a la persona hablándole a una app que no escuchó.
            state = .idle
            notify(String(localized: "No escuché nada."))
            return
        }

        // La limpieza determinista corre siempre, incluso con el refinado
        // apagado: no cuesta nada, no puede equivocarse y deja al LLM un texto
        // mejor del que partir.
        var text = preferences.refinementMode == .off
            ? transcript.text
            : FillerStripper.strip(transcript.text)

        if preferences.refinementMode != .off, await refiner.isReady {
            state = .refining
            let refinement = await refiner.refine(
                text, mode: preferences.refinementMode, language: preferences.language)
            text = refinement.text
            if refinement.status.isProblem {
                // No se le avisa a la persona: el texto crudo ya viene puntuado
                // y es perfectamente utilizable, así que un cartel de error
                // sería ruido por algo que se resolvió solo. Queda en el log
                // para poder diagnosticar un refinador que falle sistemáticamente.
                logger.notice("refinado descartado: \(refinement.description, privacy: .public)")
            }
        }

        lastTranscript = text
        let outcome = await injector.insert(text, into: pendingTarget)

        switch outcome {
        case .inserted:
            state = .idle
        case .copiedToClipboard(let reason):
            state = .idle
            notify(reason.message)
        }

        logger.info("dictado listo: \(String(format: "%.1f", duration))s de audio, \(String(format: "%.1f", transcript.realTimeFactor))× tiempo real")
    }

    // MARK: - Motores

    private func currentEngine() -> any SpeechEngine {
        switch preferences.asrModel.engine {
        case .parakeet:
            return parakeet
        case .whisper:
            if let whisper { return whisper }
            let engine = WhisperEngine(store: store)
            whisper = engine
            return engine
        case .apple:
            // El motor del sistema solo existe de macOS 26 en adelante. El
            // catálogo ya lo filtra por versión, pero si alguien copió las
            // preferencias desde una Mac más nueva hay que degradar en vez de
            // quedarse sin dictado.
            if #available(macOS 26.0, *) {
                if let appleEngineBox { return appleEngineBox }
                let engine = AppleSpeechEngine()
                appleEngineBox = engine
                return engine
            }
            return parakeet
        }
    }

    /// Deja los modelos cargados antes del primer dictado.
    ///
    /// La primera carga de un modelo CoreML compila para el Neural Engine y
    /// puede tardar bastante. Hacerlo al arrancar la app —cuando nadie está
    /// esperando— en vez de en el primer uso es la diferencia entre "instantáneo"
    /// y "la primera vez tarda quince segundos".
    func prepareEngines() async {
        let model = preferences.asrModel
        guard model.isAvailableOnThisMac else {
            state = .failed(String(localized: "\(model.displayName) necesita una versión más nueva de macOS."))
            return
        }

        // Sin descargar y sin red, no tiene sentido bloquear el arranque.
        state = .preparing(.starting)

        do {
            try await currentEngine().prepare(model) { [weak self] progress in
                // El aviso final se descarta a propósito. El callback despacha
                // al actor principal de forma asincrónica, así que ese último
                // aviso puede llegar *después* de que `prepareEngines` ya puso
                // el estado en reposo, y volvería a marcar «preparando» para
                // siempre. Quien decide que terminó es el retorno de `prepare`,
                // no el porcentaje.
                guard progress.fraction < 1 else { return }
                Task { @MainActor in
                    guard let self, case .preparing = self.state else { return }
                    self.state = .preparing(progress)
                }
            }
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
            notify(error.localizedDescription)
        }

        // El micrófono se deja configurado pero sin tomar: `prepare()` arma el
        // grafo de audio sin encender el indicador naranja.
        try? await capture.prepare()
        await capture.setKeepsWarm(preferences.keepsMicrophoneWarm)

        // El LLM se carga después y sin bloquear: el dictado crudo tiene que
        // funcionar aunque el refinado todavía no esté listo.
        if preferences.refinementMode != .off {
            prepareRefiner()
        }
    }

    /// Prepara el modelo de limpieza en segundo plano, informando el avance.
    ///
    /// Se llama desde tres lugares distintos —arranque, cambio de modelo, cambio
    /// de modo— y en los tres estaba escrito como `prepare { _ in }`. Ese
    /// descarte repetido era todo el motivo por el que la descarga más pesada de
    /// la app no se veía en ningún lado.
    private func prepareRefiner() {
        // El reporte se arma acá, todavía en el actor principal, y al task
        // desprendido viaja solo un closure `Sendable`. Capturar `self` adentro
        // del task y después saltar de vuelta al actor principal compila mal en
        // Swift 6 —y con razón: sería mandar una referencia aislada afuera de su
        // actor para leerla desde cualquier hilo.
        let report: @Sendable (PreparationProgress?) -> Void = { [weak self] progress in
            Task { @MainActor in self?.refinementProgress = progress }
        }

        Task.detached(priority: .utility) { [refiner] in
            defer { report(nil) }
            try? await refiner.prepare { progress in
                guard progress.fraction < 1 else { return }
                report(progress)
            }
        }
    }

    /// Cambia el modelo de reconocimiento y lo deja listo.
    func switchModel(to model: ASRModel) async {
        preferences.asrModel = model
        await parakeet.unload()
        await whisper?.unload()
        await prepareEngines()
    }

    func switchRefinementModel(to model: RefinementModel) async {
        preferences.refinementModel = model
        await refiner.use(model)
        prepareRefiner()
    }

    // MARK: - Acciones desde la interfaz

    /// Empezar o terminar desde el menú, para quien prefiera no usar la tecla.
    func toggleFromMenu() {
        if state.isRecording {
            commitDictation()
        } else {
            beginDictation()
            // Desde el menú no hay tecla que soltar, así que el dictado arranca
            // directamente en modo manos libres.
            if case .listening = state { state = .listening(locked: true) }
        }
    }

    func isInstalled(_ model: ASRModel) -> Bool {
        store.isInstalled(model)
    }

    func deleteModel(_ model: ASRModel) {
        try? store.remove(model)
    }

    func totalModelDiskUsage() -> Int64 {
        store.totalDiskUsage()
    }

    func revealModelsInFinder() {
        let directory = store.rootDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
    }

    func applyClipboardPreference() {
        injector.restoresClipboard =
            preferences.restoresClipboard && TextInjector.clipboardReadIsPermitted
    }

    func applyMicrophonePreference() {
        Task { await capture.setKeepsWarm(preferences.keepsMicrophoneWarm) }
    }

    func applyRefinementPreference() async {
        if preferences.refinementMode == .off {
            await refiner.unload()
        } else if await !refiner.isReady {
            prepareRefiner()
        }
    }

    // MARK: - Reacción al entorno

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter

        // Al despertar, los modelos CoreML pueden haber quedado en un estado
        // raro y el dispositivo de audio pudo cambiar. Se rearma todo.
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.permissions.refresh()
                Task { await self?.handleWake() }
            }
        }

        // Cambio de micrófono (auriculares enchufados, interfaz USB desconectada).
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDeviceChange() }
        }
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDeviceChange() }
        }
    }

    private func handleWake() async {
        try? await capture.prepare()
    }

    private func handleDeviceChange() {
        let wasRecording = state.isRecording
        Task {
            await capture.handleInputDeviceChange()
            if wasRecording {
                state = .idle
                notify(String(localized: "Se desconectó el micrófono durante el dictado."))
            }
        }
    }

    // MARK: - Nivel de entrada

    private func startLevelUpdates() {
        levelTask?.cancel()
        levelTask = Task { [capture] in
            let stream = await capture.levelStream()
            for await level in stream {
                guard !Task.isCancelled else { return }
                self.inputLevel = level
            }
        }
    }

    private func stopLevelUpdates() {
        levelTask?.cancel()
        levelTask = nil
        inputLevel = 0
    }

    // MARK: - Avisos

    /// Nada puede fallar en silencio. Cada camino que termina sin texto
    /// insertado tiene que decir por qué.
    private func notify(_ message: String) {
        lastNotice = message
        logger.notice("aviso: \(message, privacy: .public)")
    }

    /// Cuánto se le da al motor: unas cuantas veces la duración del audio.
    private func transcriptionBudget(for samples: [Float]) -> TimeInterval {
        Double(samples.count) / AudioCapture.targetSampleRate * 4
    }

    private func scheduleReturnToIdle() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            if case .failed = state { state = .idle }
        }
    }
}
