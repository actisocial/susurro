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

    /// Locuciones de relleno, **de la más larga a la más corta**.
    ///
    /// El orden no es cosmético: es la corrección de un bug que rompía las
    /// oraciones. Al borrar solo «o sea» de «o sea que hay que restaurar», el
    /// «que» quedaba huérfano —«se cayó noche que hay que restaurar»— y eso es
    /// español malformado. Peor: ese texto roto es el que después recibía el
    /// LLM, y partir la oración ahí es una reacción razonable a algo que ya
    /// venía mal. O sea que la mitad de los cortes de oración absurdos que le
    /// achacaba al modelo los estaba causando este limpiador.
    ///
    /// Estas locuciones se borran enteras. Los componentes sueltos no se tocan,
    /// porque «sea» solo es un verbo válido y «que» es una conjunción.
    /// Estas nunca significan nada, ni siquiera abriendo la oración.
    private static let phrases: [String] = [
        // Primero las que arrastran un «que» subordinante, para no dejarlo solo.
        "o sea que", "osea que", "es decir que",
        "o sea", "osea", "es decir",
        "you know what i mean", "you know", "i mean", "sort of", "kind of",
    ]

    /// Estas sí tienen una lectura literal cuando **abren** la oración.
    ///
    /// «Digamos que sí, aceptamos la propuesta» arranca con un «digamos que»
    /// que significa «supongamos» y es parte de lo que la persona quiso decir.
    /// En medio de la frase —«el deploy, digamos que, quedó listo»— es relleno.
    /// La distinción es solo posicional, así que se puede resolver sin entender
    /// nada.
    private static let phrasesNonInitial: [String] = [
        "digamos que", "quiero decir que", "vamos que", "quiero decir",
    ]

    /// Locuciones que cierran la oración y no significan nada: «…el backup nada
    /// eso», «…y listo nada». Solo se borran al final, porque en medio de la
    /// frase «nada» y «eso» son palabras con significado.
    private static let trailingPhrases: [String] = [
        "nada eso", "eso nada", "y nada", "nada más eso", "y eso nada",
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

        // 1. Cierres de oración primero: «nada eso» tiene que reconocerse antes
        //    de que se toque nada de lo que lo rodea.
        result = removeTrailingPhrases(from: result)

        // 2. Locuciones, de la más larga a la más corta. Si se borraran las
        //    palabras sueltas antes, «o sea» quedaría convertido en «sea» y ya
        //    no se reconocería; y si se borrara «o sea» antes que «o sea que»,
        //    quedaría un «que» huérfano.
        for phrase in phrases {
            result = removeOccurrences(of: phrase, in: result, sentenceInitial: true)
        }
        for phrase in phrasesNonInitial {
            result = removeOccurrences(of: phrase, in: result, sentenceInitial: false)
        }

        // 3. Interjecciones sueltas. Estas sí se borran en cualquier posición:
        //    «eh» al principio de una oración sigue sin significar nada.
        for word in interjections {
            result = removeOccurrences(of: word, in: result, sentenceInitial: true)
        }

        // 3. Tics de cierre, solo pegados al final de una oración.
        result = removeTrailingTics(from: result)

        return tidy(result)
    }

    // MARK: - Interno

    /// Borra las apariciones de `needle` respetando límites de palabra y sin
    /// distinguir mayúsculas ni tildes.
    ///
    /// - Parameter sentenceInitial: si se permite borrar cuando la locución abre
    ///   la oración. Para las interjecciones sí; para las locuciones no, porque
    ///   «Digamos que sí, aceptamos» abre con un «digamos que» literal que
    ///   significa «supongamos», no una muletilla.
    private static func removeOccurrences(
        of needle: String, in text: String, sentenceInitial: Bool
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: needle)
        // `\b` no alcanza con acentos, así que el límite se expresa como
        // "principio de texto o algo que no sea letra".
        let boundary = sentenceInitial
            ? "(?<![\\p{L}\\p{N}])"
            // Exige que haya contenido antes: una letra, un dígito o una coma.
            : "(?<=[\\p{L}\\p{N},])\\s"
        let pattern = "\(boundary)\(escaped)(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else { return text }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }

    /// Saca las locuciones que cierran la oración: «…restaurar el backup nada
    /// eso.» → «…restaurar el backup.»
    private static func removeTrailingPhrases(from text: String) -> String {
        var result = text
        for phrase in trailingPhrases {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            let pattern = "[,\\s]+\(escaped)\\s*(?=[.!?…]|$)"
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
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
