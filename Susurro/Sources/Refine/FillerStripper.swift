import Foundation

/// Saca las muletillas que se pueden sacar sin pensar.
///
/// Existe porque el LLM resultó desparejo justamente acá: en inglés limpia bien,
/// en español deja pasar «eh», «o sea», «digamos» y «viste» la mitad de las
/// veces. Medido, no supuesto — se ve en las pruebas de `--selftest`.
///
/// La respuesta correcta no es pelearla con el prompt. Un subconjunto de este
/// trabajo es puramente mecánico: «eh» y «um» no significan nada en ningún
/// contexto, y borrarlos es una operación de búsqueda y reemplazo que no puede
/// salir mal. Hacerlo acá deja al modelo un texto más limpio del que partir y,
/// cuando el refinado está apagado o el modelo todavía no cargó, la
/// transcripción igual sale mejor.
///
/// **El criterio para entrar a esta lista es la ausencia total de ambigüedad.**
/// «Eh» siempre es una muletilla. «Este» casi nunca lo es —«este documento»,
/// «este lunes»— así que no está, aunque sea de las más frecuentes al hablar.
/// Ante la duda, la palabra se queda: dejar una muletilla es un detalle
/// estético, borrar una palabra que significaba algo cambia lo que la persona
/// dijo. Esas quedan para el LLM, que sí puede mirar el contexto.
enum FillerStripper {

    /// Interjecciones puras. No significan nada en ningún contexto, en ninguno
    /// de los dos idiomas.
    private static let interjections: Set<String> = [
        "eh", "ehh", "ehhh", "em", "emm", "mmm", "mm", "ah", "ahh",
        "um", "umm", "uh", "uhh", "er", "err", "hmm", "hm",
    ]

    /// Locuciones de relleno. Van como frase completa porque los componentes
    /// sueltos sí significan cosas: «o sea» es muletilla, pero «sea» solo es un
    /// verbo perfectamente válido.
    private static let phrases: [String] = [
        "o sea", "osea", "es decir o sea",
        "you know", "i mean", "sort of", "kind of",
    ]

    /// Muletillas que solo lo son al final de la oración. «Viste» y «nada»
    /// cerrando una frase son tics; en el medio son verbo y sustantivo.
    private static let trailing: Set<String> = [
        "viste", "nada", "digamos", "right", "yeah",
    ]

    /// Limpia el transcripto.
    static func strip(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text

        // 1. Locuciones primero: si se borraran las palabras sueltas antes, «o
        //    sea» quedaría convertido en «sea» y ya no se reconocería.
        for phrase in phrases {
            result = removeOccurrences(of: phrase, in: result)
        }

        // 2. Interjecciones sueltas.
        for word in interjections {
            result = removeOccurrences(of: word, in: result)
        }

        // 3. Tics de cierre, solo pegados al final de una oración.
        result = removeTrailingTics(from: result)

        return tidy(result)
    }

    // MARK: - Interno

    /// Borra las apariciones de `needle` respetando límites de palabra y sin
    /// distinguir mayúsculas ni tildes.
    private static func removeOccurrences(of needle: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: needle)
        // `\b` no alcanza con acentos, así que el límite se expresa como
        // "principio de texto o algo que no sea letra".
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else { return text }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }

    /// Saca los tics que cierran una oración: «…que lo revise Juan, viste.» →
    /// «…que lo revise Juan.»
    private static func removeTrailingTics(from text: String) -> String {
        var result = text
        // Se repite porque pueden venir encadenados: «nada, eso, viste».
        for _ in 0..<3 {
            var changed = false
            for tic in trailing {
                let pattern = "[,\\s]+\(tic)\\s*(?=[.!?…]|$)"
                guard let regex = try? NSRegularExpression(
                    pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(result.startIndex..., in: result)
                let replaced = regex.stringByReplacingMatches(
                    in: result, range: range, withTemplate: "")
                if replaced != result {
                    result = replaced
                    changed = true
                }
            }
            if !changed { break }
        }
        return result
    }

    /// Repara lo que el borrado deja atrás: espacios dobles, comas huérfanas,
    /// puntuación desplazada y la mayúscula inicial.
    private static func tidy(_ text: String) -> String {
        var result = text

        let repairs: [(String, String)] = [
            ("\\s+", " "),           // espacios múltiples
            ("\\s+([,.;:!?…])", "$1"),  // espacio antes de puntuación
            ("([,;:])\\s*([,.;:!?…])", "$2"),  // puntuación duplicada
            ("^[\\s,;:]+", ""),      // arranque con coma huérfana
            ("([.!?…])\\s*,", "$1"), // coma pegada a un punto
        ]

        for (pattern, template) in repairs {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: template)
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Si al sacar la muletilla inicial la oración quedó empezando en
        // minúscula, se repone la mayúscula.
        if let first = result.first, first.isLowercase {
            result.replaceSubrange(
                result.startIndex...result.startIndex,
                with: String(first).uppercased())
        }

        return result
    }
}
