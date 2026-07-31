import Foundation

/// Cuánto se le permite intervenir al modelo de refinado.
enum RefinementMode: String, CaseIterable, Codable, Sendable {
    /// Sin LLM. Solo limpieza determinista de muletillas y espacios.
    case off
    /// Puntuación, mayúsculas, muletillas fuera. No reescribe ideas.
    case light
    /// Además ordena en párrafos o viñetas si el dictado lo pide.
    case structured

    var label: String {
        switch self {
        case .off:        return String(localized: "Sin refinar")
        case .light:      return String(localized: "Ligero")
        case .structured: return String(localized: "Con estructura")
        }
    }

    var explanation: String {
        switch self {
        case .off:
            return String(localized: "Inserta la transcripción tal cual. La latencia más baja posible.")
        case .light:
            return String(localized: "Corrige puntuación y mayúsculas y saca muletillas, sin tocar lo que dijiste.")
        case .structured:
            return String(localized: "Además arma párrafos o listas cuando el dictado lo pide.")
        }
    }
}

/// Qué pasó con el refinado. Importa distinguirlo.
///
/// «El texto salió igual» puede significar tres cosas muy distintas: que el
/// modelo no tenía nada que corregir, que tardó de más y se abandonó, o que
/// devolvió algo que los guardarraíles rechazaron. Las tres terminan insertando
/// el transcripto crudo —que es lo correcto— pero solo la primera es una buena
/// noticia. Sin esta distinción, un refinador que falla siempre se ve idéntico
/// a uno que anda perfecto, y el bug puede vivir meses sin que nadie lo note.
struct Refinement: Sendable {
    let text: String
    let status: Status

    enum Status: Sendable, Equatable {
        /// El modelo corrigió algo.
        case refined
        /// El modelo no encontró nada que cambiar.
        case unchanged
        /// Se agotó el presupuesto de tiempo; se usa el crudo.
        case timedOut
        /// La salida no pasó la validación; se usa el crudo.
        case rejected(reason: String)
        /// El refinado está apagado o el modelo todavía no cargó.
        case skipped

        var isProblem: Bool {
            switch self {
            case .timedOut, .rejected: return true
            case .refined, .unchanged, .skipped: return false
            }
        }
    }

    var description: String {
        switch status {
        case .refined:                return "refinado"
        case .unchanged:              return "sin cambios que hacer"
        case .timedOut:               return "el modelo tardó de más; se usó el crudo"
        case .rejected(let reason):   return "rechazado (\(reason)); se usó el crudo"
        case .skipped:                return "no se refinó"
        }
    }
}

/// Contrato del refinador de texto.
protocol TextRefiner: Actor {
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func refine(_ transcript: String, mode: RefinementMode, language: LanguageHint) async -> Refinement
    func unload() async
    var isReady: Bool { get async }
}
