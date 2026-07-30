import Foundation
import OSLog
import WhisperKit

/// Motor alternativo: Whisper de OpenAI, vía WhisperKit.
///
/// No es el modelo por defecto y conviene explicar por qué, porque Whisper es
/// el nombre que todo el mundo conoce. En los dos idiomas que le importan a
/// esta app, Parakeet v3 es mejor *y* más rápido: alrededor de 3,45 % de WER en
/// español contra ~4,7 %, y unas cinco veces más rápido porque corre en el
/// Neural Engine en vez de la GPU. Whisper además alucina sobre silencio —el
/// clásico «Gracias por ver el video» apareciendo solo— cosa que un decodificador
/// por transductor como el de Parakeet no hace.
///
/// Lo que sí tiene Whisper es cobertura: cerca de 100 idiomas contra los 25 de
/// Parakeet. Para quien dicte en algo que Parakeet no cubre, esta es la opción,
/// y por eso está.
///
/// Detalle de concurrencia: `WhisperKit` declara explícitamente que no es
/// `Sendable`. Por eso este adaptador es un `actor` que lo contiene y nunca lo
/// deja salir — es la única forma de usarlo con concurrencia estricta de Swift 6
/// sin apagar los chequeos.
actor WhisperEngine: SpeechEngine {

    private var kit: WhisperKit?
    private var loadedModel: ASRModel?

    private let store: ModelStore
    private let logger = Logger(subsystem: "com.acti.susurro", category: "Whisper")

    init(store: ModelStore) {
        self.store = store
    }

    var isReady: Bool { kit != nil }

    // MARK: - Preparación

    func prepare(_ model: ASRModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard model.engine == .whisper else {
            throw SpeechEngineError.engineUnavailable("modelo \(model.id) no es de Whisper")
        }
        if loadedModel?.id == model.id, kit != nil {
            progress(1)
            return
        }

        if store.isIncomplete(model) {
            logger.notice("descarga previa incompleta de \(model.id, privacy: .public); se descarta")
            try? store.remove(model)
        }
        if !store.isInstalled(model) {
            try store.checkDiskSpace(for: model)
            try await store.beginInstall(model)
        }

        let directory = store.directory(for: model)

        do {
            let config = WhisperKitConfig(
                model: model.variant,
                downloadBase: directory,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            let kit = try await WhisperKit(config)
            self.kit = kit
            self.loadedModel = model
            try store.completeInstall(model)
            progress(1)
            logger.info("modelo \(model.id, privacy: .public) cargado")
        } catch {
            store.markFailed(model)
            throw SpeechEngineError.downloadFailed(error.localizedDescription)
        }
    }

    // MARK: - Transcripción

    func transcribe(_ samples: [Float], language: LanguageHint) async throws -> Transcript {
        guard let kit else { throw SpeechEngineError.modelNotInstalled }

        let started = Date()
        let audioDuration = Double(samples.count) / AudioCapture.targetSampleRate

        var options = DecodingOptions()
        options.language = language.whisperCode
        // Sin muestreo aleatorio: para dictado queremos la transcripción más
        // probable, no una variación.
        options.temperature = 0
        options.usePrefillPrompt = true
        // Whisper sabe emitir marcas de tiempo pero acá no se usan y cuestan
        // tokens de decodificación.
        options.withoutTimestamps = true

        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            let text = results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return Transcript(
                text: Self.stripHallucinations(text),
                audioDuration: audioDuration,
                processingDuration: Date().timeIntervalSince(started)
            )
        } catch {
            throw SpeechEngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    func unload() async {
        kit = nil
        loadedModel = nil
    }

    // MARK: - Alucinaciones

    /// Frases que Whisper inventa cuando le llega silencio o ruido.
    ///
    /// Son residuos de sus datos de entrenamiento (subtítulos de YouTube), y
    /// aparecen enteras y solas. El VAD ya filtra la mayoría de los casos
    /// evitando llamar al modelo sin voz, pero esto cubre lo que se cuela.
    private static let knownHallucinations: Set<String> = [
        "gracias por ver el video", "gracias por ver el vídeo",
        "suscríbete al canal", "subtítulos realizados por la comunidad de amara.org",
        "¡suscríbete!", "gracias por su atención",
        "thank you for watching", "thanks for watching",
        "subscribe to my channel", "please subscribe",
        "subtitles by the amara.org community", "you",
        "♪", "[música]", "[music]", "[aplausos]", "[applause]",
    ]

    private static func stripHallucinations(_ text: String) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!¡?¿"))
            .lowercased()
        return knownHallucinations.contains(normalized) ? "" : text
    }
}

private extension LanguageHint {
    /// Código ISO que espera Whisper. `nil` deja que detecte solo.
    var whisperCode: String? {
        switch self {
        case .automatic: return nil
        case .spanish:   return "es"
        case .english:   return "en"
        }
    }
}
