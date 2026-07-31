import AVFoundation
import Foundation

/// Modo de autodiagnóstico: `Susurro --selftest archivo.wav [...]`.
///
/// Corre el pipeline real —el mismo VAD, el mismo motor, el mismo refinador,
/// los mismos guardarraíles— sobre archivos de audio en vez de sobre el
/// micrófono, e imprime lo que sale y cuánto tardó cada etapa.
///
/// Sirve para dos cosas. Una es poder verificar que la cadena funciona sin
/// depender de permisos del sistema ni de hablarle a la computadora. La otra,
/// más importante, es medir la latencia en *esta* máquina en vez de citar el
/// benchmark de otra: los números que importan para decidir entre modelos son
/// los de tu Mac.
enum SelfTest {

    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--selftest")
            || CommandLine.arguments.contains("--permisos")
    }

    /// Imprime qué permisos ve la app y sale.
    ///
    /// Existe porque «le di el permiso y no lo detecta» es imposible de
    /// diagnosticar desde afuera: Ajustes del Sistema puede mostrar el
    /// interruptor encendido mientras el proceso ve `false`, y no hay forma de
    /// distinguir un permiso revocado de un bug propio sin preguntárselo a la
    /// app misma.
    @MainActor
    static func reportPermissions() -> Int32 {
        let permissions = Permissions()
        permissions.refresh()

        func mark(_ state: Permissions.State) -> String {
            switch state {
            case .granted:        return "✓ concedido"
            case .denied:         return "✗ denegado"
            case .notDetermined:  return "· sin decidir"
            }
        }

        print("bundle:        \(Bundle.main.bundleIdentifier ?? "?")")
        print("ruta:          \(Bundle.main.bundleURL.path)")
        print("micrófono:     \(mark(permissions.microphone))")
        print("accesibilidad: \(mark(permissions.accessibility))")

        if !permissions.accessibility.isGranted {
            print("")
            print("Si en Ajustes del Sistema aparece encendido pero acá dice denegado,")
            print("es que el binario cambió después de que se concedió el permiso.")
            print("macOS lo invalida en silencio cuando eso pasa. Solución:")
            print("  1. Sacá Susurro de la lista de Accesibilidad (botón −)")
            print("  2. Volvé a agregarlo, o dejá que la app lo pida de nuevo")
        }

        return permissions.accessibility.isGranted ? 0 : 1
    }

    static func run() async -> Int32 {
        if CommandLine.arguments.contains("--permisos") {
            return await MainActor.run { reportPermissions() }
        }

        // Hay que saltear tanto las banderas como *el valor que las sigue*: sin
        // esto, `--modelo parakeet-v3-int8` metía "parakeet-v3-int8" en la lista
        // de archivos a transcribir.
        let flagsWithValue: Set<String> = ["--modelo"]
        var paths: [String] = []
        var skipNext = false
        for argument in CommandLine.arguments.drop(while: { $0 != "--selftest" }).dropFirst() {
            if skipNext { skipNext = false; continue }
            if argument.hasPrefix("--") {
                skipNext = flagsWithValue.contains(argument)
                continue
            }
            paths.append(argument)
        }

        guard !paths.isEmpty else {
            print("uso: Susurro --selftest archivo.wav [archivo2.wav …] [--modelo <id>] [--sin-refinado]")
            print("\nmodelos disponibles:")
            for model in ModelCatalog.available {
                print("  \(model.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(model.displayName) · \(model.formattedDownloadSize)")
            }
            return 1
        }

        let preferences = Preferences.shared
        let requestedModel = value(for: "--modelo").flatMap(ModelCatalog.model(id:))
        let model = requestedModel ?? preferences.asrModel
        let skipRefinement = CommandLine.arguments.contains("--sin-refinado")

        print("modelo de reconocimiento: \(model.displayName) (\(model.id))")
        if !skipRefinement {
            print("modelo de refinado:       \(preferences.refinementModel.displayName)")
        }
        print("")

        let store = ModelStore()

        // --- Carga ---
        let engine: any SpeechEngine
        switch model.engine {
        case .parakeet: engine = ParakeetEngine(store: store)
        case .whisper:  engine = WhisperEngine(store: store)
        case .apple:
            guard #available(macOS 26.0, *) else {
                print("✗ el motor del sistema necesita macOS 26")
                return 1
            }
            engine = AppleSpeechEngine()
        }

        let loadStart = Date()
        do {
            try await engine.prepare(model) { progress in
                guard progress.fraction < 1 else { return }
                let detail = progress.detail.map { " · \($0)" } ?? ""
                print("\r  \(progress.summary)\(detail)          ", terminator: "")
                fflush(stdout)
            }
        } catch {
            print("\n✗ no se pudo preparar el modelo: \(error.localizedDescription)")
            return 1
        }
        print("\r✓ modelo listo en \(ms(since: loadStart))")

        var refiner: LocalLLMRefiner?
        if !skipRefinement {
            let start = Date()
            let candidate = LocalLLMRefiner(
                model: preferences.refinementModel, modelsDirectory: store.rootDirectory)
            do {
                try await candidate.prepare { progress in
                    guard progress.fraction < 1 else { return }
                    let detail = progress.detail.map { " · \($0)" } ?? ""
                    print("\r  refinado: \(progress.summary)\(detail)          ", terminator: "")
                    fflush(stdout)
                }
                refiner = candidate
                print("\r✓ refinador listo en \(ms(since: start))")
            } catch {
                print("\r⚠ no se pudo cargar el refinador: \(error.localizedDescription)")
                print("  se continúa solo con la transcripción cruda")
            }
        }
        print("")

        // --- Transcripción ---
        var failures = 0
        var rejections = 0
        var timeouts = 0

        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let samples = loadSamples(from: url) else {
                print("✗ no se pudo leer \(url.lastPathComponent)")
                failures += 1
                continue
            }

            let seconds = Double(samples.count) / AudioCapture.targetSampleRate
            print("── \(url.lastPathComponent) (\(String(format: "%.1f", seconds)) s de audio)")

            do {
                let transcript = try await engine.transcribe(samples, language: preferences.language)
                guard !transcript.isEmpty else {
                    print("   ✗ transcripción vacía")
                    failures += 1
                    continue
                }

                print("   crudo:    \(transcript.text)")
                print("   ↳ \(String(format: "%.0f", transcript.processingDuration * 1000)) ms · \(String(format: "%.0f", transcript.realTimeFactor))× tiempo real")

                let stripped = FillerStripper.strip(transcript.text)
                if stripped != transcript.text {
                    print("   limpio:   \(stripped)")
                }

                if let refiner {
                    let start = Date()
                    let refinement = await refiner.refine(
                        stripped,
                        mode: preferences.refinementMode,
                        language: preferences.language)
                    print("   refinado: \(refinement.text)")
                    print("   ↳ \(ms(since: start)) · \(refinement.description)")

                    // Un rechazo NO es un fallo: es el guardarraíl haciendo su
                    // trabajo, y el texto crudo que se insertó es correcto. Se
                    // cuenta aparte para poder ver si empiezan a ser demasiados
                    // —eso sí indicaría un refinador roto—, pero no tumba la
                    // corrida. Un timeout tampoco es un error de resultado, pero
                    // sí es una señal de que el modelo no entra en su
                    // presupuesto en esta máquina.
                    switch refinement.status {
                    case .rejected: rejections += 1
                    case .timedOut: timeouts += 1
                    default: break
                    }
                }
            } catch {
                print("   ✗ \(error.localizedDescription)")
                failures += 1
            }
            print("")
        }

        // Igual que en el banco: no se puede llamar a `exit()` con un hilo
        // todavía adentro de MLX.
        await refiner?.drain()

        if rejections > 0 {
            print("· \(rejections) refinado(s) rechazado(s) por los guardarraíles — se insertó el texto crudo, que es el comportamiento correcto")
        }
        if timeouts > 0 {
            print("⚠ \(timeouts) refinado(s) fuera de presupuesto de tiempo en esta máquina")
        }
        print(failures == 0 ? "✓ todo bien" : "✗ \(failures) fallo(s)")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Utilidades

    private static func value(for flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1)
        else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func ms(since start: Date) -> String {
        String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
    }

    /// Lee cualquier formato que entienda CoreAudio y lo convierte al 16 kHz
    /// mono Float32 que consumen los modelos — el mismo contrato que produce
    /// `AudioCapture`.
    private static func loadSamples(from url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            return nil
        }
        converter.downmix = true

        guard let input = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return nil }
        try? file.read(into: input)

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(file.length) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
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
            return input
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }

        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
