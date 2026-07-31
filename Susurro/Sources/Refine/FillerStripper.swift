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
    ///
    /// Las locuciones del inglés **no** están acá: viven en `hedges`, porque
    /// necesitan mirar la palabra de al lado. Ver ahí el porqué.
    ///
    /// Se fue también «es decir» suelto, por «lo que quiero es decir la
    /// verdad»: como conector siempre viene con coma o con «que», y en esas dos
    /// formas sigue estando.
    ///
    /// «O sea» se queda, porque es la muletilla más frecuente del rioplatense y
    /// su única lectura literal —«ya sea una cosa o sea otra»— se reconoce sin
    /// ambigüedad por el «ya sea» que la abre. Ver `hasDisjunctiveSubjunctive`.
    private static let phrases: [String] = [
        "o sea que", "osea que", "es decir que",
        "o sea", "osea",
        "you know what i mean",
    ]

    /// Locuciones del inglés que son relleno **o no** según lo que tengan al
    /// lado, con la prueba que las distingue.
    ///
    /// Estaban en `phrases`, borrándose en cualquier posición, y destruían
    /// inglés corriente:
    ///
    ///     do you know if the deploy went out  ->  Do if the deploy went out
    ///     what kind of error is it            ->  What error is it
    ///     you know the answer                 ->  The answer
    ///
    /// Sacarlas del todo tampoco servía: medido, el borrado en inglés cayó de
    /// 90 % a 58 % de F1, porque el LLM solo no las levanta. O sea que ni
    /// borrarlas siempre ni nunca: hay que distinguir, y se puede.
    ///
    /// «Kind of» y «sort of» son sustantivo más preposición cuando los precede
    /// un determinante —«what kind of», «some kind of», «a sort of»—; en
    /// cualquier otra posición son atenuadores. «You know» y «I mean» son verbo
    /// pleno cuando los precede un auxiliar («do you know») o cuando los sigue
    /// un objeto («you know the answer», «I mean what I say»); si no, son
    /// parentéticas.
    ///
    /// Las tres pruebas son listas cerradas de palabras funcionales, que es
    /// justo lo que un limpiador sin contexto puede chequear sin equivocarse.
    private struct Hedge {
        let phrase: String
        /// Si aparece justo antes, la locución es literal y no se toca.
        let notAfter: [String]
        /// Si aparece justo después, la locución es literal y no se toca.
        let notBefore: [String]
    }

    private static let determiners = [
        "a", "an", "the", "this", "that", "these", "those",
        "some", "any", "no", "every", "each", "what", "which", "other", "another",
    ]

    /// Sólo el *do-support*, que es lo que fuerza la lectura verbal: «do you
    /// know», «didn't you know». Un modal no alcanza — «we should, you know,
    /// postpone» es parentética, y meter «should» acá la dejaba sin limpiar.
    private static let auxiliaries = [
        "do", "does", "did", "dont", "doesnt", "didnt", "don", "doesn", "didn",
    ]

    private static let objectStarters = [
        "the", "a", "an", "that", "this", "it", "what", "my", "your", "his",
        "her", "their", "our", "them", "him", "me", "us", "everything", "nothing",
    ]

    private static let hedges: [Hedge] = [
        Hedge(phrase: "kind of", notAfter: determiners, notBefore: []),
        Hedge(phrase: "sort of", notAfter: determiners, notBefore: []),
        Hedge(phrase: "you know", notAfter: auxiliaries, notBefore: objectStarters),
        Hedge(phrase: "i mean", notAfter: auxiliaries, notBefore: objectStarters),
    ]

    /// Si el texto trae la construcción «ya sea A o sea B».
    ///
    /// Es la única lectura de «o sea» que no es muletilla, y se anuncia sola:
    /// siempre viene precedida de «ya sea». Cuando aparece, se deja el texto en
    /// paz — perder una muletilla es un detalle, convertir «una cosa o sea
    /// otra» en «una cosa otra» es romper la frase.
    private static func hasDisjunctiveSubjunctive(_ text: String) -> Bool {
        let plain = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return plain.contains("ya sea")
    }

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

    /// Tics de cierre. **Exigen una coma delante**, y ese detalle es la
    /// diferencia entre limpiar y mutilar.
    ///
    /// Antes alcanzaba con un espacio, y el resultado era pérdida silenciosa de
    /// palabras dichas:
    ///
    ///     En la caja no hay nada.  ->  En la caja no hay.
    ///     ¿Lo viste?               ->  ¿Lo?
    ///     the answer is right      ->  The answer is
    ///     make a left and a right  ->  Make a left and a
    ///
    /// «Nada» al final de una oración negativa es el objeto de la negación, no
    /// un tic. «Viste» es el verbo. «Right» es el predicado. Lo que separa esos
    /// casos del tic es la pausa, y la pausa en el transcripto es la coma.
    ///
    /// El costo de exigirla es dejar pasar el tic cuando el ASR no puso la
    /// coma. Es el costo correcto: una muletilla de más es un detalle estético,
    /// una palabra borrada cambia lo que la persona dijo. Y el LLM, que sí mira
    /// el contexto, la saca igual.
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
        let disjunctive = hasDisjunctiveSubjunctive(result)
        for phrase in phrases {
            if disjunctive, phrase.hasSuffix("sea") { continue }
            result = removeOccurrences(of: phrase, in: result, sentenceInitial: true)
        }
        for phrase in phrasesNonInitial {
            result = removeOccurrences(of: phrase, in: result, sentenceInitial: false)
        }
        for hedge in hedges {
            result = removeHedge(hedge, in: result)
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

    /// Borra un atenuador del inglés sólo cuando el contexto descarta la
    /// lectura literal.
    private static func removeHedge(_ hedge: Hedge, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: hedge.phrase)
        var pattern = "(?<![\\p{L}\\p{N}])"
        if !hedge.notAfter.isEmpty {
            pattern += "(?<!\\b(?:\(hedge.notAfter.joined(separator: "|")))\\s)"
        }
        pattern += escaped + "(?![\\p{L}\\p{N}])"
        if !hedge.notBefore.isEmpty {
            pattern += "(?!\\s+(?:\(hedge.notBefore.joined(separator: "|")))\\b)"
        }
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
                let pattern = ",\\s*\(tic)\\s*(?=[.!?…]|$)"
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
