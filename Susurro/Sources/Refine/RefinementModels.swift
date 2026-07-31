import Foundation

/// Modelo de lenguaje que limpia el transcripto.
///
/// El trabajo es deliberadamente chico: puntuación, tildes, mayúsculas y sacar
/// muletillas. Parakeet ya devuelve texto razonablemente puntuado, así que lo
/// que agrega el LLM son los «eh», «este», «o sea» y los arranques en falso, que
/// ningún modelo de audio filtra.
///
/// La intuición dice que para una tarea tan chica alcanza el modelo más chico.
/// Es falso, y se midió en esta máquina: los modelos por debajo de ~2B no fallan
/// por lentos, fallan por **infieles**. Con entrada en español, uno traduce al
/// inglés, otro resume, otro contesta la pregunta que le dictaron, y Qwen3-0.6B
/// directamente emite caracteres cirílicos y árabes. Un modelo que no se puede
/// usar es infinitamente peor que uno que tarda 300 ms más.
struct RefinementModel: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let displayName: String
    /// Repo de Hugging Face en formato MLX.
    let repository: String
    let downloadBytes: Int64
    let residentBytes: Int64
    let tagline: String
    let license: String
    /// Latencia típica para un dictado corto, medida en un M2 Pro.
    let typicalLatency: String

    var formattedDownloadSize: String {
        ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
    }
}

enum RefinementCatalog {

    /// El mismo modelo que el recomendado, comprimido más fuerte.
    ///
    /// Es 130 ms más rápido y ocupa 1,1 GB menos de memoria, a cambio de unos
    /// cuatro puntos de puntuación —y de ocho a once en dictados largos con los
    /// dos idiomas entreverados—. Vale la pena en Macs de 8 GB, donde 1,9 GB
    /// residentes contra 3,0 no es un detalle, y para quien note la diferencia
    /// entre 840 y 970 ms.
    static let qwen35_2b = RefinementModel(
        id: "qwen3.5-2b-4bit",
        displayName: "Qwen3.5 2B",
        repository: "mlx-community/Qwen3.5-2B-4bit",
        downloadBytes: 1_749 * 1_000_000,
        residentBytes: 1_900 * 1_000_000,
        tagline: String(localized: "Más liviano y algo más rápido que el recomendado, a cambio de puntuar un poco peor."),
        license: "Apache-2.0",
        typicalLatency: String(localized: "de 0,8 a 1,0 s")
    )

    /// Para quien priorice latencia por encima de todo.
    ///
    /// Es dos veces y media más rápido que el recomendado —p50 de 386 ms contra
    /// 928— y se nota: el texto aparece casi al soltar la tecla. Lo que se paga
    /// es puntuación, y bastante: 46 % contra 80 %. Borra las muletillas casi
    /// tan bien como los grandes (F1 88 %), pero le pone poco más de la mitad de
    /// las comas y los signos de apertura que hacen falta.
    ///
    /// O sea que sirve para quien quiera sobre todo que le saquen los «eh» y
    /// los «o sea» al vuelo, y no le moleste puntuar a mano.
    static let qwen35_08b = RefinementModel(
        id: "qwen3.5-0.8b-4bit",
        displayName: "Qwen3.5 0.8B",
        repository: "mlx-community/Qwen3.5-0.8B-4bit",
        downloadBytes: 652 * 1_000_000,
        residentBytes: 800 * 1_000_000,
        tagline: String(localized: "El más rápido: el texto aparece casi al instante. Saca las muletillas bien, pero puntúa la mitad."),
        license: "Apache-2.0",
        typicalLatency: String(localized: "de 0,3 a 0,6 s")
    )

    /// El recomendado.
    ///
    /// Medido sobre los 46 casos del banco, contra el mismo modelo a 4 bits:
    ///
    ///     puntuación F1        4 bits    8 bits
    ///     inglés                  88 %      94 %
    ///     español                 79 %      75 %
    ///     mezcla                  72 %      77 %
    ///     mezcla pesada           73 %      82 %
    ///     ─────────────────────────────────────
    ///     total                   77 %      81 %
    ///     coincidencia exacta     26 %      33 %
    ///     p50                   835 ms    931 ms
    ///
    /// Gana en todo menos en español puro, y gana por más donde más se nota: en
    /// dictados largos con los dos idiomas entreverados. Cuesta 1 GB más de
    /// descarga, 1,1 GB más de memoria y unos 130 ms.
    ///
    /// **Corrección de una conclusión anterior.** Este archivo afirmaba lo
    /// contrario —que los 8 bits derrumbaban la mezcla pesada a un 17 %— con una
    /// explicación elaborada sobre representaciones por idioma más nítidas que
    /// se desorientan al entreverarse los idiomas. Era falso. Ese 17 % no medía
    /// la cuantización: medía tres bugs que había en el camino y que se
    /// arreglaron después —el guardarraíl descartaba el refinado entero por una
    /// sola palabra reescrita, la alineación no sabía representar una
    /// reescritura y perdía la palabra original, y el presupuesto de tiempo era
    /// fijo y cortaba justo los dictados largos—. Los tres pegaban más fuerte
    /// justamente en las frases largas y mezcladas, que es donde el 8 bits se
    /// veía peor. Con eso corregido, la misma medición da 84 %.
    ///
    /// Queda anotado porque el error no fue medir mal: fue *explicar* bien un
    /// número malo. La teoría era plausible y por eso mismo dejó de buscarse la
    /// causa real durante varias horas.
    static let qwen35_2b_8bit = RefinementModel(
        id: "qwen3.5-2b-8bit",
        displayName: "Qwen3.5 2B (8 bits)",
        repository: "mlx-community/Qwen3.5-2B-8bit",
        downloadBytes: 2_700 * 1_000_000,
        residentBytes: 3_000 * 1_000_000,
        tagline: String(localized: "El recomendado. El que mejor puntúa cuando mezclás español e inglés, y nunca se atrasa."),
        license: "Apache-2.0",
        typicalLatency: String(localized: "de 0,9 a 1,3 s")
    )

    // Qwen3.5 4B se probó y **no entra al catálogo**, aunque sea el más capaz de
    // la familia. En esta Mac llegó tarde en 45 de los 46 casos del banco, con
    // un p50 de 2025 ms contra un presupuesto que en la mayoría de los dictados
    // ronda los 1500. Un modelo que no contesta a tiempo no da un refinado peor:
    // da **cero** refinado, porque se inserta el texto sin puntuar. Su
    // puntuación medida fue 19 % contra 77 % del 2B, y esa diferencia es
    // enteramente latencia, no capacidad.
    //
    // Ofrecerlo en la lista sería ofrecer una trampa: se elige por el nombre
    // —«4B tiene que ser mejor que 2B»— y se recibe una app que dejó de
    // corregir, sin ninguna pista de por qué. En una Mac bastante más rápida
    // que ésta la conclusión podría darse vuelta, pero la app no tiene forma de
    // saberlo, y el riesgo no es simétrico.

    /// Gemma 4, en su variante entrenada para cuantizar.
    ///
    /// Es el más interesante del catálogo y también el de recomendación más
    /// difícil, porque **le gana al recomendado en casi todo menos en lo que
    /// más se usa**. Medido sobre el mismo banco:
    ///
    ///                          Gemma 4 E2B    el recomendado
    ///     coincidencia exacta          37 %            30 %
    ///     borrado F1                   92 %            88 %
    ///     puntuación, español          84 %            75 %
    ///     puntuación, mezcla           75 %            77 %
    ///     puntuación, mezcla pesada    39 %            84 %
    ///     llegó tarde                 22/46            1/46
    ///
    /// La fila que decide es la penúltima, y la explica la última. Gemma limpia
    /// mejor cuando contesta; el problema es que en dictados largos y muy
    /// mezclados no contesta a tiempo —p50 de 1602 ms en esa fila contra 1100 del
    /// recomendado— y entonces el texto sale sin tocar. No es que puntúe mal la
    /// mezcla: es que no llega.
    ///
    /// Queda en el catálogo porque para quien dicte frases cortas o medianas,
    /// en un idioma por vez, es sensiblemente mejor: más del doble de dictados
    /// salen exactamente como corresponde. La contra es la RAM — 5,3 GB contra
    /// 1,7 — que en una Mac de 16 GB es un tercio de la memoria mientras esté
    /// cargado. El «e2b» son 2B *efectivos*: activa menos parámetros de los que
    /// carga, así que anda mejor de lo que el tamaño sugiere, pero ocuparla la
    /// ocupa igual.
    static let gemma4_e2b = RefinementModel(
        id: "gemma4-e2b-qat",
        displayName: "Gemma 4 E2B",
        repository: "mlx-community/gemma-4-e2b-it-qat-OptiQ-4bit",
        downloadBytes: 5_300 * 1_000_000,
        residentBytes: 5_600 * 1_000_000,
        tagline: String(localized: "Limpia mejor que el recomendado en frases cortas y medianas. Pide bastante RAM y se atrasa en dictados largos muy mezclados."),
        license: "Gemma Terms of Use",
        typicalLatency: String(localized: "de 1,0 a 1,6 s")
    )

    static let all: [RefinementModel] = [
        qwen35_2b_8bit, qwen35_2b, qwen35_08b, gemma4_e2b,
    ]

    static let `default` = qwen35_2b_8bit

    static func model(id: String) -> RefinementModel? {
        all.first { $0.id == id }
    }
}
