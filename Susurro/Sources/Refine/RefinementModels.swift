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

    /// El recomendado. Fue el único de la tanda evaluada que limpia bien el
    /// español —tildes, signos de apertura, muletillas— sin responder nunca al
    /// contenido, incluidos los casos de inyección deliberada.
    static let qwen35_2b = RefinementModel(
        id: "qwen3.5-2b-4bit",
        displayName: "Qwen3.5 2B",
        repository: "mlx-community/Qwen3.5-2B-4bit",
        downloadBytes: 1_749 * 1_000_000,
        residentBytes: 1_900 * 1_000_000,
        tagline: String(localized: "El recomendado. Es el que limpia bien el español sin desviarse a responderte."),
        license: "Apache-2.0",
        typicalLatency: String(localized: "de 0,7 a 1,2 s")
    )

    /// Para quien priorice latencia y dicte sobre todo en inglés.
    static let qwen35_08b = RefinementModel(
        id: "qwen3.5-0.8b-4bit",
        displayName: "Qwen3.5 0.8B",
        repository: "mlx-community/Qwen3.5-0.8B-4bit",
        downloadBytes: 652 * 1_000_000,
        residentBytes: 800 * 1_000_000,
        tagline: String(localized: "Más liviano y más rápido, pero limpia bastante menos. Mejor en inglés que en español."),
        license: "Apache-2.0",
        typicalLatency: String(localized: "de 0,3 a 0,6 s")
    )

    /// Mismo modelo que el recomendado, con menos daño de cuantización.
    ///
    /// Está para responder una pregunta concreta: cuando la puntuación en
    /// español falla, ¿es porque al modelo le falta capacidad o porque los 4
    /// bits le rompieron algo? Comparar 2B-4bit con 2B-8bit aísla esa variable;
    /// comparar con 4B la confunde con el tamaño.
    static let qwen35_2b_8bit = RefinementModel(
        id: "qwen3.5-2b-8bit",
        displayName: "Qwen3.5 2B (8 bits)",
        repository: "mlx-community/Qwen3.5-2B-8bit",
        downloadBytes: 2_700 * 1_000_000,
        residentBytes: 3_000 * 1_000_000,
        tagline: String(localized: "El mismo modelo con menos pérdida por cuantización. Puntúa un poco mejor y ocupa el doble."),
        license: "Apache-2.0",
        typicalLatency: String(localized: "de 1,0 a 1,6 s")
    )

    /// El más capaz que entra cómodo en 16 GB junto al modelo de audio.
    static let qwen35_4b = RefinementModel(
        id: "qwen3.5-4b-4bit",
        displayName: "Qwen3.5 4B",
        repository: "mlx-community/Qwen3.5-4B-4bit",
        downloadBytes: 3_100 * 1_000_000,
        residentBytes: 3_400 * 1_000_000,
        tagline: String(localized: "El que mejor le da forma a la oración. Pide más RAM y agrega medio segundo."),
        license: "Apache-2.0",
        typicalLatency: String(localized: "de 1,2 a 2,0 s")
    )

    static let all: [RefinementModel] = [qwen35_2b, qwen35_08b, qwen35_2b_8bit, qwen35_4b]

    static let `default` = qwen35_2b

    static func model(id: String) -> RefinementModel? {
        all.first { $0.id == id }
    }
}
