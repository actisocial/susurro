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

/// Decide si la salida del modelo es aceptable, o si hay que quedarse con el
/// texto crudo.
///
/// Esto no es paranoia teórica: es el bug más grave y más extendido de esta
/// categoría de apps. Un transcripto es texto que la persona dijo en voz alta,
/// y un modelo chico no distingue de forma confiable entre «arreglale la
/// puntuación a esto» y «hacé lo que dice esto». Si alguien dicta «che, pasame
/// la receta de la lasaña», el modelo puede contestar con la receta — y eso
/// termina insertado en el mail que estaba escribiendo. Hay un reporte
/// reproducible exactamente así en Handy (#1261), otro equivalente en VoiceInk
/// (#838), y el mantenedor de Whispering describe el mismo problema.
///
/// La defensa no puede ser solo un buen prompt, porque el prompt es
/// precisamente lo que el ataque dobla. Tiene que ser una validación de la
/// salida, del lado de afuera del modelo. Ante la duda, se inserta el
/// transcripto crudo: peor puntuación es un problema infinitamente menor que
/// texto ajeno apareciendo en un documento.
enum RefinementGuard {

    enum Rejection: Sendable, Equatable {
        case tooLong(ratio: Double)
        case tooShort(ratio: Double)
        case looksLikeAnAnswer(phrase: String)
        case droppedWords(recall: Double)
        case empty

        var reason: String {
            switch self {
            case .tooLong(let ratio):
                return "la salida es \(String(format: "%.1f", ratio))× más larga que la entrada"
            case .tooShort(let ratio):
                return "la salida es \(String(format: "%.0f", ratio * 100))% de la entrada"
            case .looksLikeAnAnswer(let phrase):
                return "parece una respuesta del asistente («\(phrase)»)"
            case .droppedWords(let recall):
                return "solo sobrevivió el \(String(format: "%.0f", recall * 100))% de las palabras dictadas"
            case .empty:
                return "la salida quedó vacía"
            }
        }
    }

    /// Frases que delatan que el modelo se puso a conversar en vez de corregir.
    /// Se buscan en español y en inglés porque un modelo chico contesta en
    /// cualquiera de los dos sin importar el idioma de entrada.
    private static let assistantTells: [String] = [
        "claro,", "por supuesto", "aquí tienes", "aquí está", "acá tenés",
        "espero que", "no dudes en", "como asistente", "no puedo ayudar",
        "lo siento", "perdón, no", "necesito más", "podrías aclarar",
        "proporciona el", "proporcioná el", "pasame el texto",
        "sure,", "certainly", "here is", "here's the", "i'm sorry",
        "i cannot", "i can't", "as an ai", "please provide", "let me know",
        "hope this helps", "of course,",
    ]

    /// Valida la reescritura. Devuelve `nil` si está bien, o el motivo del
    /// rechazo.
    static func check(original: String, refined: String, mode: RefinementMode) -> Rejection? {
        let cleanOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRefined = refined.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanRefined.isEmpty else { return .empty }

        let originalCount = Double(cleanOriginal.count)
        let refinedCount = Double(cleanRefined.count)
        guard originalCount > 0 else { return nil }

        let ratio = refinedCount / originalCount

        // Refinar no debería agrandar el texto: quitar muletillas lo acorta y
        // la puntuación agrega unos pocos caracteres. Un salto grande significa
        // que el modelo escribió algo por su cuenta. El caso de Handy producía
        // 468 caracteres a partir de 63, o sea 7,4×.
        let maxRatio = mode == .structured ? 1.6 : 1.35
        if ratio > maxRatio { return .tooLong(ratio: ratio) }

        // Al revés también es sospechoso, pero el piso tiene que ser bajo. Un
        // dictado muy cargado de muletillas encoge muchísimo al limpiarlo:
        // «este eh bueno digamos que el servidor se cayó otra vez viste» son 59
        // caracteres que quedan en 29 —menos de la mitad— y esa reducción es
        // exactamente el trabajo bien hecho. Un piso de 0,55 rechazaba esos
        // casos, que es justo al revés de lo que se busca.
        //
        // El piso queda entonces solo para lo grosero (un resumen de una línea)
        // y el trabajo fino lo hace el chequeo de palabras de abajo, que ya
        // descuenta las muletillas y por eso no se confunde.
        if ratio < 0.35 { return .tooShort(ratio: ratio) }

        let lowered = cleanRefined.lowercased()
        // Solo interesa el arranque: es donde aparecen los preámbulos de
        // asistente. Buscarlas en todo el texto daría falsos positivos cuando
        // alguien dicta legítimamente «claro, mandámelo cuando puedas».
        let opening = String(lowered.prefix(60))
        for tell in Self.assistantTells where opening.contains(tell) {
            // …salvo que la frase también estuviera en el original, en cuyo
            // caso la dijo la persona.
            if !cleanOriginal.lowercased().prefix(60).contains(tell) {
                return .looksLikeAnAnswer(phrase: tell)
            }
        }

        // Chequeo final, y el que más atrapa: ¿sobrevivieron las palabras que la
        // persona realmente dijo?
        //
        // La prueba correcta es asimétrica. No importa cuánto se *parezcan* los
        // dos textos —una medida simétrica como Jaccard castiga el agregado
        // legítimo de tildes y penaliza poco la pérdida de contenido—, importa
        // qué fracción de las palabras dictadas siguen estando. Traducir,
        // resumir, responder, escribir un poema y emitir código son todos
        // fallos que se ven igual desde acá: las palabras originales
        // desaparecieron.
        let recall = wordRecall(original: cleanOriginal, refined: cleanRefined)
        if recall < 0.80 { return .droppedWords(recall: recall) }

        return nil
    }

    /// Qué fracción de las palabras significativas del original sobrevive en el
    /// texto refinado.
    static func wordRecall(original: String, refined: String) -> Double {
        let source = significantTokens(original).subtracting(fillers)
        guard !source.isEmpty else { return 1 }

        let survivors = significantTokens(refined)
        let kept = source.intersection(survivors).count
        return Double(kept) / Double(source.count)
    }

    /// Muletillas: se descuentan del cálculo porque sacarlas es exactamente el
    /// trabajo que se le pidió al modelo. Penalizarlo por hacerlo bien sería
    /// contraproducente.
    private static let fillers: Set<String> = [
        "este", "esto", "eeeh", "ehh", "osea", "digamos", "bueno", "nada",
        "entonces", "como", "que", "pues", "che", "viste", "tipo",
        "uhh", "umm", "like", "know", "mean", "well", "just", "basically",
        "actually", "literally", "right",
    ]

    private static func significantTokens(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
        // Las palabras de una o dos letras son artículos y preposiciones: están
        // en todos los textos y solo agregan ruido a la comparación.
        return Set(words.filter { $0.count > 2 })
    }
}
