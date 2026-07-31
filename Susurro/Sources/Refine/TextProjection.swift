import Foundation

/// Proyecta la salida del modelo sobre las palabras que la persona realmente dijo.
///
/// Esta es la pieza que hace segura toda la etapa de refinado, y su idea central
/// es un cambio de encuadre: **la cadena que devuelve el modelo no es el
/// resultado, es un voto**. Lo que se inserta se reconstruye desde los tokens
/// de la entrada que la alineación conservó. Así, cada palabra de la salida es
/// por construcción una palabra de la entrada, en el mismo orden.
///
/// El camino alternativo era restringir la decodificación —impedir que el
/// modelo *pueda* emitir una palabra que no esté en la entrada— y se descartó
/// por dos razones. La primera es de costo: la máscara hay que recompilarla
/// para cada dictado, no se puede cachear, y obliga a sincronizar con la GPU en
/// cada token. La segunda es más grave: bajo una máscara de subsecuencia,
/// copiar textualmente siempre es legal y es el camino legal más probable para
/// un modelo de 2B propenso a copiar — o sea que agravaría el problema medido
/// (que en español el modelo no hace nada) en vez de resolverlo. Y de paso
/// volvería silenciosas todas las fallas: si toda salida es válida por
/// construcción, ningún guardarraíl vuelve a disparar y se pierde la única
/// telemetría disponible.
///
/// La proyección funciona porque la restricción es *reparable*. Un JSON roto no
/// tiene arreglo canónico; una limpieza inválida sí: se alinea y se descarta lo
/// que no encaja.
enum TextProjection {

    // MARK: - Tokens

    /// Una palabra con su puntuación pegada.
    ///
    /// La puntuación se guarda aparte del núcleo para que la comparación sea
    /// solo entre letras: así agregar una coma, un signo de apertura o una
    /// mayúscula es gratis, que es justamente lo que el modelo tiene permitido
    /// hacer.
    struct Token: Equatable {
        /// Espacios (o saltos de línea) que preceden al token.
        let space: String
        /// Puntuación pegada por delante: ¿ ¡ ( « " —
        let lead: String
        /// La palabra en sí, tal como aparece, con sus tildes.
        let core: String
        /// Puntuación pegada por detrás: , . ? ! ; : ) » …
        let trail: String
        /// El núcleo normalizado para comparar: sin tildes, sin mayúsculas y
        /// sin apóstrofos ni guiones. Es lo que permite aceptar «esta» → «está»
        /// o «dont» → «don't» como el mismo token.
        let key: String

        var rendered: String { space + lead + core + trail }
    }

    private static let leadingPunctuation = CharacterSet(charactersIn: "¿¡([{«\"'“‘—-")
    private static let trailingPunctuation = CharacterSet(charactersIn: ",.;:!?)]}»\"'”’…—-")

    /// Parte un texto en tokens con núcleo no vacío.
    ///
    /// Que el núcleo nunca esté vacío es lo que mantiene simple la programación
    /// dinámica: la puntuación suelta se adhiere al token siguiente, así que no
    /// existen tokens que sean solo puntuación y no hay casos especiales.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var pendingSpace = ""
        var pendingLead = ""

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]

            if character.isWhitespace {
                pendingSpace.append(character)
                index = text.index(after: index)
                continue
            }

            if character.unicodeScalars.allSatisfy({ leadingPunctuation.contains($0) })
                && !character.isLetter && !character.isNumber {
                pendingLead.append(character)
                index = text.index(after: index)
                continue
            }

            // Núcleo: letras, dígitos y los conectores internos de una palabra.
            var core = ""
            while index < text.endIndex {
                let inner = text[index]
                let isConnector = (inner == "'" || inner == "\u{2019}" || inner == "-" || inner == ".")
                    && !core.isEmpty
                    && text.index(after: index) < text.endIndex
                    && (text[text.index(after: index)].isLetter || text[text.index(after: index)].isNumber)

                guard inner.isLetter || inner.isNumber || isConnector else { break }
                core.append(inner)
                index = text.index(after: index)
            }

            guard !core.isEmpty else {
                // Puntuación que no abre nada: se pega como cola del token
                // anterior si existe, y si no se descarta.
                if !tokens.isEmpty {
                    let last = tokens.removeLast()
                    tokens.append(Token(
                        space: last.space, lead: last.lead, core: last.core,
                        trail: last.trail + String(character), key: last.key))
                }
                index = text.index(after: index)
                continue
            }

            var trail = ""
            while index < text.endIndex {
                let inner = text[index]
                guard inner.unicodeScalars.allSatisfy({ trailingPunctuation.contains($0) }),
                      !inner.isLetter, !inner.isNumber else { break }
                trail.append(inner)
                index = text.index(after: index)
            }

            tokens.append(Token(
                space: pendingSpace, lead: pendingLead, core: core,
                trail: trail, key: fold(core)))
            pendingSpace = ""
            pendingLead = ""
        }

        return tokens
    }

    /// Normaliza una palabra para compararla: sin tildes, sin mayúsculas y sin
    /// apóstrofos ni guiones internos.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    // MARK: - Resultado

    struct Result {
        let text: String
        /// Tokens de la salida que no se explican con ninguna palabra de la
        /// entrada. Uno solo ya invalida el refinado.
        let fabricated: Int
        /// Índices de los tokens de la entrada que se borraron.
        let deletedIndices: [Int]
        let sourceTokens: [Token]

        var deletedCount: Int { deletedIndices.count }

        /// La corrida contigua de borrados más larga. Un modelo que se come una
        /// oración entera lo hace de forma contigua; uno que saca muletillas las
        /// saca de a una.
        var longestDeletedRun: Int {
            var longest = 0, current = 0, previous = -2
            for index in deletedIndices.sorted() {
                current = index == previous + 1 ? current + 1 : 1
                longest = max(longest, current)
                previous = index
            }
            return longest
        }
    }

    // MARK: - Alineación

    /// Cuántos tokens se permite agrupar de cada lado en una coincidencia.
    /// Cubre «dá me lo» → «dámelo» (3→1) con margen.
    private static let maxGroup = 4

    /// Penalización de fabricar una palabra. Enorme a propósito: cualquier
    /// alineación que evite fabricar es preferible a cualquiera que fabrique,
    /// sin importar cuántos borrados cueste.
    private static let fabricationCost = 10_000

    /// Costo de borrar un token de la entrada.
    private static let deletionCost = 10

    /// Penalización por agrupar. Es lo que hace que, cuando dos alineaciones
    /// explican lo mismo, gane la más simple.
    ///
    /// Sin esto, «decile si viene» contra «Decile sí viene» se podía alinear
    /// como un grupo de dos («decilesi» ↔ «decilesí») en vez de dos parejas, y
    /// entonces la salvaguarda de tildes ambiguas —que solo mira parejas de uno
    /// a uno— nunca llegaba a aplicarse: «si» se convertía en «sí» y cambiaba
    /// el sentido de la frase.
    ///
    /// El valor es deliberadamente menor que `deletionCost`: agrupar sigue
    /// siendo siempre preferible a borrar.
    private static let groupingPenalty = 1

    /// Alinea la salida contra la entrada y reconstruye el texto final.
    ///
    /// La programación dinámica permite tres movimientos: borrar un token de la
    /// entrada (costo 1), emparejar un grupo de tokens de cada lado cuyos
    /// núcleos normalizados concatenados coinciden (costo 0), o fabricar un
    /// token de salida sin respaldo (costo 1000).
    ///
    /// El emparejamiento de grupo es el detalle que hace que esto no dispare
    /// todo el tiempo con español correcto: «por que» → «porque», «sino» →
    /// «si no», «dá me lo» → «dámelo» son todas fusiones o divisiones legítimas
    /// que un cotejo palabra a palabra rechazaría.
    static func project(source: String, candidate: String) -> Result {
        let src = tokenize(source)
        let out = tokenize(candidate)

        guard !src.isEmpty else {
            return Result(text: "", fabricated: out.count, deletedIndices: [], sourceTokens: src)
        }

        let n = src.count, m = out.count

        // Longitudes acumuladas de las claves, para descartar grupos por tamaño
        // antes de comparar cadenas.
        var srcPrefix = [Int](repeating: 0, count: n + 1)
        for i in 0..<n { srcPrefix[i + 1] = srcPrefix[i] + src[i].key.count }
        var outPrefix = [Int](repeating: 0, count: m + 1)
        for j in 0..<m { outPrefix[j + 1] = outPrefix[j] + out[j].key.count }

        let infinity = Int.max / 4
        var cost = [[Int]](repeating: [Int](repeating: infinity, count: m + 1), count: n + 1)
        // De cada celda, de dónde se llegó: (di, dj).
        var from = [[(Int, Int)]](repeating: [(Int, Int)](repeating: (0, 0), count: m + 1), count: n + 1)

        cost[0][0] = 0

        for i in 0...n {
            for j in 0...m {
                let here = cost[i][j]
                guard here < infinity else { continue }

                // Borrar un token de la entrada.
                if i < n, here + deletionCost < cost[i + 1][j] {
                    cost[i + 1][j] = here + deletionCost
                    from[i + 1][j] = (1, 0)
                }

                // Fabricar un token de salida.
                if j < m, here + fabricationCost < cost[i][j + 1] {
                    cost[i][j + 1] = here + fabricationCost
                    from[i][j + 1] = (0, 1)
                }

                // Emparejar grupos.
                guard i < n, j < m else { continue }
                for a in 1...min(maxGroup, n - i) {
                    let srcLength = srcPrefix[i + a] - srcPrefix[i]
                    for b in 1...min(maxGroup, m - j) {
                        let outLength = outPrefix[j + b] - outPrefix[j]
                        guard srcLength == outLength else { continue }

                        let srcKey = src[i..<(i + a)].map(\.key).joined()
                        let outKey = out[j..<(j + b)].map(\.key).joined()
                        guard srcKey == outKey else { continue }

                        let candidate = here + (a - 1 + b - 1) * groupingPenalty
                        if candidate < cost[i + a][j + b] {
                            cost[i + a][j + b] = candidate
                            from[i + a][j + b] = (a, b)
                        }
                    }
                }
            }
        }

        // Reconstrucción.
        //
        // Se recorre hacia atrás, así que los grupos salen en orden inverso.
        // Cada grupo se guarda como una unidad y al final se invierte la lista
        // de grupos —no la de tokens—: aplanar primero y revertir después
        // daría vuelta también el contenido de cada grupo, y «¿Por qué» saldría
        // «qué ¿Por».
        var groups: [[String]] = []
        var deleted: [Int] = []
        var fabricated = 0
        var i = n, j = m

        while i > 0 || j > 0 {
            let (di, dj) = from[i][j]

            if di > 0 && dj > 0 {
                // Coincidencia: se emite lo que produjo el modelo, que es lo
                // que trae la puntuación, las mayúsculas y las tildes nuevas.
                let sourceGroup = Array(src[(i - di)..<i])
                let outputGroup = Array(out[(j - dj)..<j])
                groups.append(rendered(source: sourceGroup, output: outputGroup))
                i -= di
                j -= dj
            } else if di > 0 {
                deleted.append(i - 1)
                i -= 1
            } else {
                fabricated += 1
                j -= 1
            }
        }

        let text = groups.reversed()
            .flatMap { $0 }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Result(
            text: text,
            fabricated: fabricated,
            deletedIndices: deleted.sorted(),
            sourceTokens: src)
    }

    /// Palabras de una sola sílaba donde la tilde cambia el significado.
    ///
    /// En una coincidencia se emite normalmente la versión del modelo, porque
    /// eso es lo que restituye las tildes. Pero en estas la tilde no es
    /// ortografía sino semántica —«sí» y «si» son palabras distintas— y un
    /// modelo de 2B se equivoca lo suficiente como para que no valga la pena el
    /// riesgo. Acá gana lo que dijo la persona.
    ///
    /// A propósito NO están las interrogativas (qué, cómo, cuándo, dónde,
    /// quién, cuál, cuánto): esas sí queremos que el modelo las acentúe, y
    /// tiene con qué acertar porque acaba de poner los signos de interrogación.
    private static let riskyMonosyllables: Set<String> = [
        "si", "el", "tu", "mi", "se", "mas", "de", "te", "aun", "solo",
    ]

    private static func rendered(source: [Token], output: [Token]) -> [String] {
        if source.count == 1, output.count == 1 {
            let src = source[0], out = output[0]
            if src.key == out.key, src.core != out.core,
               riskyMonosyllables.contains(src.key) {
                return [out.space + out.lead + src.core + out.trail]
            }
        }
        return output.map(\.rendered)
    }
}
