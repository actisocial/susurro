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

    static let all: [RefinementModel] = [qwen35_2b, qwen35_08b]

    static let `default` = qwen35_2b

    static func model(id: String) -> RefinementModel? {
        all.first { $0.id == id }
    }
}
