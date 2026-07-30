import Foundation

/// Resultado de una transcripción, en tipos propios.
///
/// Deliberadamente no se deja escapar el tipo de resultado de ninguno de los
/// SDKs: FluidAudio está en 0.x con cadencia de cambios rápida y WhisperKit
/// acaba de romper su API en 1.0. Traduciendo en el borde, un cambio de
/// upstream toca un adaptador y nada más.
struct Transcript: Sendable, Equatable {
    let text: String
    /// Duración del audio de entrada.
    let audioDuration: TimeInterval
    /// Cuánto tardó el modelo.
    let processingDuration: TimeInterval

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Cuántas veces más rápido que tiempo real. Se muestra en Ajustes para que
    /// la comparación entre modelos sea sobre esta Mac y no sobre un benchmark
    /// ajeno corrido en otra máquina.
    var realTimeFactor: Double {
        guard processingDuration > 0 else { return 0 }
        return audioDuration / processingDuration
    }

    static let empty = Transcript(text: "", audioDuration: 0, processingDuration: 0)
}

/// Pista de idioma. Cuando la persona fija un idioma en Ajustes, Parakeet v3 la
/// usa para filtrar los tokens candidatos por sistema de escritura — es una
/// mejora de precisión gratis y evita que una palabra suelta salga en cirílico.
enum LanguageHint: String, CaseIterable, Codable, Sendable {
    case automatic
    case spanish
    case english

    var label: String {
        switch self {
        case .automatic: return String(localized: "Automático")
        case .spanish:   return String(localized: "Español")
        case .english:   return String(localized: "Inglés")
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .automatic: return nil
        case .spanish:   return "es-ES"
        case .english:   return "en-US"
        }
    }
}

/// Errores que la UI tiene que saber distinguir: cada uno se le explica distinto
/// a la persona y tiene una acción de salida diferente.
enum SpeechEngineError: LocalizedError, Sendable, Equatable {
    case modelNotInstalled
    case modelCorrupted
    case downloadFailed(String)
    case notEnoughDiskSpace(needed: Int64, available: Int64)
    case engineUnavailable(String)
    case transcriptionFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return String(localized: "El modelo todavía no está descargado.")
        case .modelCorrupted:
            return String(localized: "El modelo quedó incompleto. Volvé a descargarlo desde Ajustes.")
        case .downloadFailed(let detail):
            return String(localized: "No se pudo descargar el modelo: \(detail)")
        case .notEnoughDiskSpace(let needed, let available):
            let fmt = ByteCountFormatter.string(fromByteCount:countStyle:)
            return String(localized: "No hay espacio suficiente: hacen falta \(fmt(needed, .file)) y quedan \(fmt(available, .file)).")
        case .engineUnavailable(let detail):
            return String(localized: "El motor no está disponible: \(detail)")
        case .transcriptionFailed(let detail):
            return String(localized: "Falló la transcripción: \(detail)")
        case .cancelled:
            return String(localized: "Transcripción cancelada.")
        }
    }
}

/// Contrato común a todos los motores de reconocimiento.
///
/// Es `Actor` y no simplemente `Sendable` a propósito. Los objetos que hay
/// debajo no son seguros entre hilos —`WhisperKit` declara explícitamente que
/// no es `Sendable`— así que cada adaptador tiene que ser el actor que los
/// contiene y no dejarlos salir nunca. Constrañir el protocolo a `Actor` hace
/// que el compilador lo garantice en vez de dejarlo como convención.
protocol SpeechEngine: Actor {
    /// Descarga el modelo si falta y lo deja cargado en memoria.
    /// Llamarlo dos veces con el mismo modelo no debe hacer trabajo de nuevo.
    func prepare(_ model: ASRModel, progress: @escaping @Sendable (Double) -> Void) async throws

    /// Transcribe audio mono de 16 kHz.
    func transcribe(_ samples: [Float], language: LanguageHint) async throws -> Transcript

    /// Libera la memoria del modelo sin borrarlo del disco.
    func unload() async

    /// Si el modelo está cargado y listo para transcribir ya mismo.
    var isReady: Bool { get async }
}
