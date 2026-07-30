import FluidAudio
import Foundation
import OSLog

/// Detector de voz. Decide qué parte de la grabación es habla.
///
/// Cumple tres funciones, y las tres importan:
///
/// - **Recortar.** Todo dictado empieza y termina con silencio: el pre-roll por
///   delante y la reacción humana al soltar la tecla por detrás. Sacarlo hace
///   la transcripción más rápida y, en el caso de Parakeet v3, esquiva un bug
///   por el cual la cola de silencio hace que los enunciados cortos decodifiquen
///   a nada.
/// - **Filtrar.** Si no hay voz, no hay que llamar al modelo. Cualquier motor
///   autorregresivo —Whisper el primero— alucina sobre silencio: el clásico
///   «Gracias por ver el video» apareciendo solo en un documento.
/// - **Avisar.** Un dictado sin voz detectada tiene que decir «no escuché nada»
///   en vez de no hacer nada.
///
/// Usa Silero VAD en CoreML, que viene en el mismo paquete que Parakeet y pesa
/// aproximadamente 1 MB.
actor SpeechGate {

    private let vad: VadManager
    private let logger = Logger(subsystem: "com.acti.susurro", category: "SpeechGate")

    /// Margen que se deja alrededor de la voz detectada. El VAD tiende a
    /// recortar consonantes iniciales sordas —una «p» o una «t» al principio de
    /// palabra tienen muy poca energía— así que un poco de aire de más es más
    /// barato que perder la primera letra.
    private let defaultPadding: TimeInterval = 0.15

    init(threshold: Float = 0.85) async throws {
        // 0.85 es alto respecto del default de Silero, y es a propósito: el
        // dictado es con la boca cerca del micrófono, así que la voz llega
        // fuerte y conviene ser exigente para no tomar por habla el ruido de
        // fondo o el tecleo.
        let config = VadConfig(defaultThreshold: threshold)
        do {
            vad = try await VadManager(config: config)
        } catch {
            throw SpeechEngineError.engineUnavailable(
                String(localized: "no se pudo cargar el detector de voz: \(error.localizedDescription)"))
        }
    }

    /// Devuelve solo el tramo con voz. Si no hay ninguno, devuelve vacío.
    func trimToSpeech(_ samples: [Float], padding: TimeInterval? = nil) async -> [Float] {
        let pad = padding ?? defaultPadding
        guard samples.count > Int(AudioCapture.targetSampleRate * 0.1) else { return [] }

        let segments: [VadSegment]
        do {
            let config = VadSegmentationConfig(
                minSpeechDuration: 0.1,
                minSilenceDuration: 0.35,
                speechPadding: pad
            )
            segments = try await vad.segmentSpeech(samples, config: config)
        } catch {
            // Si el VAD falla, mejor transcribir de más que perder el dictado.
            logger.error("el VAD falló (\(error.localizedDescription, privacy: .public)); se usa el audio completo")
            return samples
        }

        guard let first = segments.first, let last = segments.last else {
            return []
        }

        // Se toma del principio del primer tramo al final del último, sin cortar
        // las pausas del medio: las pausas naturales entre frases son parte del
        // enunciado y quitarlas empeora la puntuación que produce el modelo.
        let rate = Int(AudioCapture.targetSampleRate)
        let start = max(0, first.startSample(sampleRate: rate))
        let end = min(samples.count, last.endSample(sampleRate: rate))

        guard start < end else { return [] }
        return Array(samples[start..<end])
    }

    /// Si hay algo de voz en el audio. Se usa para distinguir «no dijiste nada»
    /// de «el modelo falló».
    func containsSpeech(_ samples: [Float]) async -> Bool {
        !(await trimToSpeech(samples).isEmpty)
    }
}
