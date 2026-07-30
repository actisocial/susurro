import AVFoundation
import Foundation
import OSLog
import Speech

/// Motor de reconocimiento del propio macOS (26 en adelante).
///
/// Existe por una razón de producto, no técnica: **la app tiene que servir para
/// algo en el minuto cero**. Bajar Parakeet son casi 500 MB, y obligar a
/// esperar eso antes de poder probar nada es donde más gente abandona — la HIG
/// lo dice con todas las letras («no dejes que una descarga grande entorpezca la
/// puesta en marcha»). Con este motor, Susurro dicta apenas se instala, y
/// Parakeet se ofrece después, con la app ya andando y el valor ya demostrado.
///
/// No es software libre y por eso no es el modelo destacado, pero es honesto
/// tenerlo: es rápido, no ocupa disco, y en inglés mide muy bien. Cubre 30
/// idiomas que gestiona el sistema.
@available(macOS 26.0, *)
actor AppleSpeechEngine: SpeechEngine {

    private var transcriber: SpeechTranscriber?
    private var locale: Locale?
    private let logger = Logger(subsystem: "com.acti.susurro", category: "AppleSpeech")

    var isReady: Bool { transcriber != nil }

    // MARK: - Preparación

    func prepare(_ model: ASRModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechEngineError.engineUnavailable(
                String(localized: "el dictado del sistema no está disponible en esta Mac"))
        }

        let target = await Self.resolveLocale()
        guard let target else {
            throw SpeechEngineError.engineUnavailable(
                String(localized: "el sistema no reconoce ni español ni inglés en esta Mac"))
        }

        if transcriber != nil, locale == target {
            progress(1)
            return
        }

        let transcriber = SpeechTranscriber(locale: target, preset: .transcription)

        // Los modelos de idioma los administra macOS. Puede que el que hace
        // falta no esté bajado todavía: se pide y se espera, informando el
        // avance como con cualquier otro modelo.
        if let request = try? await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            logger.info("descargando el paquete de idioma del sistema para \(target.identifier, privacy: .public)")
            let observation = request.progress.observe(\.fractionCompleted) { p, _ in
                progress(p.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }

        self.transcriber = transcriber
        self.locale = target
        progress(1)
        logger.info("motor del sistema listo (\(target.identifier, privacy: .public))")
    }

    /// Elige el idioma a usar entre los que el sistema soporta.
    private static func resolveLocale() async -> Locale? {
        let preferred = Locale.preferredLanguages.first.map(Locale.init(identifier:))
            ?? Locale.current
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
            return match
        }
        // Si el idioma del sistema no está cubierto, se cae a español y después
        // a inglés, que son los dos idiomas para los que se diseñó la app.
        for fallback in ["es-ES", "en-US"] {
            if let match = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: fallback)) {
                return match
            }
        }
        return await SpeechTranscriber.supportedLocales.first
    }

    // MARK: - Transcripción

    func transcribe(_ samples: [Float], language: LanguageHint) async throws -> Transcript {
        guard let transcriber else { throw SpeechEngineError.modelNotInstalled }

        let started = Date()
        let audioDuration = Double(samples.count) / AudioCapture.targetSampleRate

        // El analizador dicta en qué formato quiere el audio; no siempre es el
        // 16 kHz mono que produce la captura.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]) else {
            throw SpeechEngineError.engineUnavailable(
                String(localized: "el sistema no ofreció un formato de audio compatible"))
        }

        guard let buffer = Self.makeBuffer(from: samples, in: analyzerFormat) else {
            throw SpeechEngineError.transcriptionFailed(
                String(localized: "no se pudo convertir el audio al formato del sistema"))
        }

        // La entrada es una secuencia asincrónica. Como acá se transcribe un
        // enunciado ya completo, se emite un único buffer y se cierra: eso le
        // dice al analizador que puede finalizar y devolver el texto definitivo.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        // El orden de estas tres cosas importa, y hacerlo mal cuelga la app.
        //
        // La secuencia `transcriber.results` no termina hasta que el analizador
        // se finaliza, y el analizador no se finaliza hasta que el código llega
        // a esa línea. Si se recorren los resultados *antes* de finalizar, cada
        // uno queda esperando al otro: el bucle no sale nunca y el HUD se queda
        // en «Transcribiendo…» para siempre.
        //
        // La forma correcta es leer los resultados en una tarea aparte, que
        // corre mientras el hilo principal alimenta el audio y finaliza. Recién
        // entonces la secuencia se cierra sola y la tarea devuelve el texto.
        let collector = Task {
            var collected = ""
            // Solo interesan los resultados definitivos: los volátiles son
            // hipótesis intermedias que después cambian.
            for try await result in transcriber.results where result.isFinal {
                collected += String(result.text.characters)
            }
            return collected
        }

        let text: String
        do {
            try await analyzer.start(inputSequence: stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            text = try await collector.value
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw SpeechEngineError.transcriptionFailed(error.localizedDescription)
        }

        return Transcript(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            audioDuration: audioDuration,
            processingDuration: Date().timeIntervalSince(started)
        )
    }

    func unload() async {
        transcriber = nil
        locale = nil
    }

    // MARK: - Conversión de audio

    private static func makeBuffer(
        from samples: [Float], in format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let source = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            source.floatChannelData?[0].update(from: pointer.baseAddress!, count: samples.count)
        }

        if format == sourceFormat { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else { return nil }
        let ratio = format.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }

        return error == nil ? output : nil
    }
}
