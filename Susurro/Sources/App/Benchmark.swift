import Foundation

/// Mide la calidad de la etapa de limpieza sobre un corpus fijo.
///
/// Existe porque «maximizar la calidad» no es accionable sin un número. Hasta
/// acá las decisiones se tomaron mirando cuatro ejemplos a ojo, y así no se
/// puede comparar un prompt contra otro, ni un modelo de 2B contra uno de 4B, ni
/// saber si un cambio mejoró o solo movió el problema de lugar.
///
/// **La métrica sale de la misma alineación que garantiza la seguridad.** De
/// `(crudo, esperado)` se deduce qué palabras había que borrar; de
/// `(crudo, obtenido)` cuáles se borraron de verdad. Comparar esos dos conjuntos
/// da precisión y exhaustividad sobre las palabras borradas — que es exactamente
/// la métrica que usa la literatura de eliminación de disfluencias, así que los
/// números son comparables con los papers.
///
/// Se evalúa sobre texto y no sobre audio a propósito: aísla la variable que se
/// quiere medir, y una corrida entera tarda segundos en vez de minutos.
///
/// Uso:  Susurro --bench [--modelo-refinado <id>] [--sin-refinado] [--verboso]
enum Benchmark {

    struct Case: Decodable {
        let id: String
        let lang: String
        let raw: String
        let expected: String
    }

    private struct Corpus: Decodable {
        let cases: [Case]
    }

    struct Score {
        var exactMatches = 0
        var total = 0

        /// Palabras que había que borrar y se borraron.
        var truePositives = 0
        /// Palabras que se borraron sin tener que borrarse. Cada una es contenido
        /// perdido, así que pesan más que las que quedaron de más.
        var falsePositives = 0
        /// Palabras que había que borrar y quedaron.
        var falseNegatives = 0

        var fabricated = 0
        var rejected = 0
        var latencies: [TimeInterval] = []

        /// Puntuación acertada, de más y de menos.
        ///
        /// Se mide aparte de los borrados porque son dos trabajos distintos y
        /// solo uno de los dos lo puede hacer el limpiador determinista. Mirar
        /// un F1 que solo cuenta borrados dice que el LLM aporta poco — y es
        /// falso, porque todo lo que aporta en darle forma a la oración (signos
        /// de interrogación, cortes de oración, listas) queda afuera de esa
        /// cuenta.
        var punctCorrect = 0
        var punctSpurious = 0
        var punctMissing = 0

        var punctPrecision: Double {
            let denominator = punctCorrect + punctSpurious
            return denominator == 0 ? 1 : Double(punctCorrect) / Double(denominator)
        }
        var punctRecall: Double {
            let denominator = punctCorrect + punctMissing
            return denominator == 0 ? 1 : Double(punctCorrect) / Double(denominator)
        }
        var punctF1: Double {
            let sum = punctPrecision + punctRecall
            return sum == 0 ? 0 : 2 * punctPrecision * punctRecall / sum
        }

        var precision: Double {
            let denominator = truePositives + falsePositives
            return denominator == 0 ? 1 : Double(truePositives) / Double(denominator)
        }
        var recall: Double {
            let denominator = truePositives + falseNegatives
            return denominator == 0 ? 1 : Double(truePositives) / Double(denominator)
        }
        var f1: Double {
            let sum = precision + recall
            return sum == 0 ? 0 : 2 * precision * recall / sum
        }
        var exactRate: Double {
            total == 0 ? 0 : Double(exactMatches) / Double(total)
        }

        func percentile(_ p: Double) -> TimeInterval {
            guard !latencies.isEmpty else { return 0 }
            let sorted = latencies.sorted()
            let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * p))
            return sorted[index]
        }
    }

    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--bench")
    }

    static func run() async -> Int32 {
        guard let url = Bundle.main.url(forResource: "benchmark", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let corpus = try? JSONDecoder().decode(Corpus.self, from: data)
        else {
            print("✗ no se encontró benchmark.json en el bundle")
            return 1
        }

        let verbose = CommandLine.arguments.contains("--verboso")
        let skipRefinement = CommandLine.arguments.contains("--sin-refinado")
        let preferences = Preferences.shared

        // Permite comparar modelos sin recompilar ni tocar los ajustes reales.
        let model: RefinementModel = {
            guard let index = CommandLine.arguments.firstIndex(of: "--modelo-refinado"),
                  CommandLine.arguments.indices.contains(index + 1),
                  let requested = RefinementCatalog.model(id: CommandLine.arguments[index + 1])
            else { return preferences.refinementModel }
            return requested
        }()

        print("corpus: \(corpus.cases.count) casos")
        print("refinado: \(skipRefinement ? "apagado (solo limpiador determinista)" : model.displayName)")
        print("")

        var refiner: LocalLLMRefiner?
        if !skipRefinement {
            let store = ModelStore()
            let candidate = LocalLLMRefiner(
                model: model, modelsDirectory: store.rootDirectory)
            do {
                try await candidate.prepare { _ in }
                refiner = candidate
            } catch {
                print("✗ no se pudo cargar el refinador: \(error.localizedDescription)")
                return 1
            }
        }

        // Validación del corpus contra sí mismo, antes de medir nada.
        //
        // Un «esperado» que contenga una palabra que no está en el crudo es
        // inalcanzable por construcción: la proyección lo rechazaría aunque el
        // modelo lo produjera exacto. Medir contra eso deprime el puntaje por
        // un error de la ficha, no del sistema — y es justo el tipo de error
        // que hace perder días persiguiendo un fantasma.
        var unreachable = 0
        for testCase in corpus.cases {
            let ideal = TextProjection.project(
                source: testCase.raw, candidate: testCase.expected)
            if ideal.fabricated > 0 {
                unreachable += 1
                print("⚠ \(testCase.id): el esperado usa \(ideal.fabricated) palabra(s) que no están en el crudo")
                print("    crudo:    \(testCase.raw)")
                print("    esperado: \(testCase.expected)")
            }
        }
        if unreachable > 0 {
            print("")
            print("⚠ \(unreachable) caso(s) con expectativa inalcanzable — corregilos antes de creerle al puntaje")
            print("")
        }

        var overall = Score()
        var byLanguage: [String: Score] = [:]

        for testCase in corpus.cases {
            let started = Date()

            // El mismo camino exacto que corre un dictado real.
            let stripped = FillerStripper.strip(testCase.raw)
            var actual = stripped
            var wasRejected = false

            if let refiner {
                let refinement = await refiner.refine(
                    stripped, mode: preferences.refinementMode, language: preferences.language)
                actual = refinement.text
                if case .rejected = refinement.status { wasRejected = true }
            }

            let latency = Date().timeIntervalSince(started)
            let result = evaluate(raw: testCase.raw, expected: testCase.expected, actual: actual)

            overall.accumulate(result, latency: latency, rejected: wasRejected)
            byLanguage[testCase.lang, default: Score()]
                .accumulate(result, latency: latency, rejected: wasRejected)

            if verbose || !result.exact {
                let mark = result.exact ? "✓" : "·"
                print("\(mark) \(testCase.id)\(wasRejected ? "  [rechazado]" : "")")
                if !result.exact {
                    print("    esperado: \(testCase.expected)")
                    print("    obtenido: \(actual)")
                }
            }
        }

        print("")
        report("TOTAL", overall)
        for lang in ["es", "en", "mix", "heavy"] {
            if let score = byLanguage[lang] { report(lang, score) }
        }

        return 0
    }

    // MARK: - Puntaje

    fileprivate struct CaseResult {
        let exact: Bool
        let truePositives: Int
        let falsePositives: Int
        let falseNegatives: Int
        let fabricated: Int
        let punctCorrect: Int
        let punctSpurious: Int
        let punctMissing: Int
    }

    /// Compara qué se borró contra qué había que borrar.
    ///
    /// Las dos alineaciones se hacen contra el mismo crudo, así que los índices
    /// son directamente comparables: son posiciones de la misma lista de tokens.
    private static func evaluate(raw: String, expected: String, actual: String) -> CaseResult {
        let ideal = TextProjection.project(source: raw, candidate: expected)
        let got = TextProjection.project(source: raw, candidate: actual)

        let shouldDelete = Set(ideal.deletedIndices)
        let didDelete = Set(got.deletedIndices)

        let punctuation = comparePunctuation(expected: expected, actual: actual)

        return CaseResult(
            exact: normalized(actual) == normalized(expected),
            truePositives: didDelete.intersection(shouldDelete).count,
            falsePositives: didDelete.subtracting(shouldDelete).count,
            falseNegatives: shouldDelete.subtracting(didDelete).count,
            fabricated: got.fabricated,
            punctCorrect: punctuation.correct,
            punctSpurious: punctuation.spurious,
            punctMissing: punctuation.missing)
    }

    /// Compara la puntuación como multiconjunto de marcas.
    ///
    /// No se compara posición por posición a propósito: una coma corrida un
    /// lugar sigue siendo una coma bien puesta la mayoría de las veces, y
    /// castigarla como error haría que la métrica exija coincidencia literal en
    /// vez de medir si el texto quedó bien formado. Lo que sí importa —y esto
    /// sí lo captura— es si aparecieron los signos de apertura, si se cerraron
    /// las preguntas y cuántos cortes de oración se hicieron.
    private static func comparePunctuation(
        expected: String, actual: String
    ) -> (correct: Int, spurious: Int, missing: Int) {
        func marks(_ text: String) -> [Character: Int] {
            var counts: [Character: Int] = [:]
            for character in text where "¿?¡!.,;:—-".contains(character) {
                counts[character, default: 0] += 1
            }
            return counts
        }

        let want = marks(expected)
        let got = marks(actual)

        var correct = 0, spurious = 0, missing = 0
        for mark in Set(want.keys).union(got.keys) {
            let wanted = want[mark] ?? 0
            let obtained = got[mark] ?? 0
            correct += min(wanted, obtained)
            if obtained > wanted { spurious += obtained - wanted }
            if wanted > obtained { missing += wanted - obtained }
        }
        return (correct, spurious, missing)
    }

    /// Para la comparación exacta se ignoran diferencias de espaciado, que no
    /// son un error de limpieza.
    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func report(_ label: String, _ score: Score) {
        let name = label.padding(toLength: 6, withPad: " ", startingAt: 0)
        print("""
            \(name) exacto \(pct(score.exactRate))  ·  borrado F1 \(pct(score.f1)) (P \(pct(score.precision)) R \(pct(score.recall)))  \
            ·  puntuación F1 \(pct(score.punctF1)) (P \(pct(score.punctPrecision)) R \(pct(score.punctRecall)))  \
            ·  \(score.rejected) rech.  ·  p50 \(ms(score.percentile(0.5))) p95 \(ms(score.percentile(0.95)))
            """)
    }

    private static func pct(_ value: Double) -> String {
        String(format: "%3.0f%%", value * 100)
    }

    private static func ms(_ value: TimeInterval) -> String {
        String(format: "%4.0fms", value * 1000)
    }
}

extension Benchmark.Score {
    fileprivate mutating func accumulate(
        _ result: Benchmark.CaseResult, latency: TimeInterval, rejected: Bool
    ) {
        total += 1
        if result.exact { exactMatches += 1 }
        truePositives += result.truePositives
        falsePositives += result.falsePositives
        falseNegatives += result.falseNegatives
        fabricated += result.fabricated
        punctCorrect += result.punctCorrect
        punctSpurious += result.punctSpurious
        punctMissing += result.punctMissing
        if rejected { self.rejected += 1 }
        latencies.append(latency)
    }
}
