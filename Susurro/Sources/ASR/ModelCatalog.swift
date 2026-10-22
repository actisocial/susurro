import Foundation

/// Familia de motor que sabe correr un modelo dado.
enum EngineKind: String, Codable, Sendable, CaseIterable {
    /// Parakeet TDT de NVIDIA, convertido a CoreML, corriendo en el Neural
    /// Engine. Es el camino por defecto: el más rápido y el que menos batería
    /// gasta, y además deja la GPU libre para el LLM de refinado.
    case parakeet
    /// Whisper de OpenAI vía WhisperKit. Más lento, pero cubre ~75 idiomas que
    /// Parakeet no toca.
    case whisper
    /// El motor de dictado del propio sistema (macOS 26+). Cero descarga.
    case apple
}

/// Un modelo concreto que la persona puede elegir en Ajustes.
///
/// Esto es lo que el usuario pidió tener "parametrizado": no una lista de
/// nombres sueltos, sino tamaño en disco, idiomas cubiertos y en qué se destaca
/// cada uno, para poder decidir con criterio.
struct ASRModel: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let engine: EngineKind
    /// Identificador interno que el adaptador traduce a su propia
    /// configuración (versión de Parakeet, nombre de repo de Whisper, etc.).
    let variant: String
    let displayName: String
    /// Tamaño aproximado de la descarga. Se muestra antes de bajar nada.
    let downloadBytes: Int64
    /// Cuánta RAM ocupa mientras está cargado.
    let residentBytes: Int64
    let languageSummary: String
    /// Frase corta que explica cuándo conviene este modelo.
    let tagline: String
    /// Licencia de los pesos. Parakeet es CC-BY-4.0 y exige atribución.
    let license: String
    let attribution: String?
    /// Repo de Hugging Face de donde sale, para poder auditarlo.
    let sourceRepository: String?
    /// Versión mínima de macOS.
    let minimumMacOS: Int

    /// Qué se sabe de su precisión, y de dónde salió ese dato.
    ///
    /// Acá la procedencia es siempre `.published`, y es importante que se vea.
    /// El banco que trae la app mide la *limpieza* del texto: arranca de
    /// transcripciones correctas escritas a mano y evalúa qué les hace el
    /// modelo de refinado. O sea que **nunca midió el reconocimiento**. Estas
    /// cifras son las que publica quien entrenó cada modelo, sobre sus propios
    /// conjuntos de prueba, y no están verificadas en esta Mac ni con esta voz.
    ///
    /// Se muestran igual porque son mejor que nada para elegir, pero etiquetadas
    /// como lo que son. `nil` donde no hay una cifra atribuible: inventar un
    /// número plausible sería peor que dejar el hueco.
    let metrics: ModelMetrics?

    var isAvailableOnThisMac: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: minimumMacOS, minorVersion: 0, patchVersion: 0))
    }

    var requiresDownload: Bool { downloadBytes > 0 }

    var formattedDownloadSize: String {
        guard downloadBytes > 0 else { return String(localized: "Sin descarga") }
        return ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file)
    }

    /// Nombre de carpeta que FluidAudio le va a poner al modelo.
    ///
    /// Hay que saberlo porque su descargador no respeta del todo la ruta que se
    /// le pasa: toma el directorio *padre* de lo que recibe y crea adentro una
    /// carpeta con nombre derivado del repo (el último componente, sin el
    /// sufijo `-coreml`). Si uno le pasa `Modelos/mi-id`, los archivos terminan
    /// en `Modelos/parakeet-tdt-0.6b-v3`, fuera del directorio que la app cree
    /// estar administrando — y entonces borrar el modelo deja medio giga
    /// huérfano y la cuenta de disco miente.
    ///
    /// La solución es anticiparlo: se le pasa `<nuestro-dir>/<este-nombre>`, así
    /// el padre es nuestro directorio y todo queda adentro.
    var enclosingFolderName: String {
        guard let repository = sourceRepository,
              let last = repository.split(separator: "/").last
        else { return id }
        return last.replacingOccurrences(of: "-coreml", with: "")
    }
}

/// Los modelos que Susurro ofrece.
///
/// La lista es corta a propósito. Las apps de esta categoría se mueren de lo
/// mismo: superwhisper y VoiceInk terminaron con decenas de modelos y catorce
/// proveedores en la nube, y sus propios usuarios dicen que ya no se entiende
/// cuál elegir. Cuatro opciones bien diferenciadas cubren todos los casos
/// reales sin obligar a nadie a investigar.
///
/// Por qué Parakeet v3 es el default y no Whisper, que es el nombre conocido:
/// en español mide 3,45 % de WER contra ~4,7 % de Whisper large-v3-turbo, y
/// corre unas cinco veces más rápido porque va sobre el Neural Engine en vez de
/// la GPU. Es mejor y más rápido en los dos idiomas que importan acá. Whisper
/// queda como opción para los idiomas que Parakeet no cubre.
enum ModelCatalog {

    static let parakeetV3Int8 = ASRModel(
        id: "parakeet-v3-int8",
        engine: .parakeet,
        variant: "v3-int8",
        displayName: "Parakeet TDT v3",
        downloadBytes: 483 * 1_000_000,
        residentBytes: 140 * 1_000_000,
        languageSummary: String(localized: "25 idiomas europeos, incluido español"),
        tagline: String(localized: "El equilibrio recomendado: rápido, preciso y multilingüe."),
        license: "CC-BY-4.0",
        attribution: "NVIDIA — nvidia/parakeet-tdt-0.6b-v3",
        sourceRepository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        minimumMacOS: 14,
        metrics: ModelMetrics(
            facts: [
                .init(label: String(localized: "Error en español"), value: "3,45 %"),
                .init(label: String(localized: "Dónde corre"), value: String(localized: "Neural Engine")),
            ],
            provenance: .published)
    )

    static let parakeetV3Int4 = ASRModel(
        id: "parakeet-v3-int4",
        engine: .parakeet,
        variant: "v3-int4",
        displayName: String(localized: "Parakeet TDT v3 (compacto)"),
        downloadBytes: 336 * 1_000_000,
        residentBytes: 110 * 1_000_000,
        languageSummary: String(localized: "25 idiomas europeos, incluido español"),
        tagline: String(localized: "El mismo modelo con menos peso en disco; pierde un poco de precisión."),
        license: "CC-BY-4.0",
        attribution: "NVIDIA — nvidia/parakeet-tdt-0.6b-v3",
        sourceRepository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        minimumMacOS: 14,
        // Sin cifras: es el mismo modelo comprimido más fuerte, y cuánta
        // precisión pierde exactamente no está publicado en ningún lado que se
        // pueda citar. Poner un número plausible sería inventarlo.
        metrics: nil
    )

    static let parakeetEnglishFast = ASRModel(
        id: "parakeet-tdtctc-110m",
        engine: .parakeet,
        variant: "tdt-ctc-110m",
        displayName: String(localized: "Parakeet 110M (solo inglés)"),
        downloadBytes: 120 * 1_000_000,
        residentBytes: 60 * 1_000_000,
        languageSummary: String(localized: "Solo inglés"),
        tagline: String(localized: "El más liviano y el más rápido, si dictás únicamente en inglés."),
        license: "CC-BY-4.0",
        attribution: "NVIDIA — nvidia/parakeet-tdt_ctc-110m",
        sourceRepository: "FluidInference/parakeet-tdt-ctc-110m-coreml",
        minimumMacOS: 14,
        metrics: ModelMetrics(
            facts: [
                .init(label: String(localized: "Dónde corre"), value: String(localized: "Neural Engine")),
            ],
            caveat: String(localized: "No entiende español. Si dictás una frase en español, el resultado va a ser inservible."),
            provenance: .published)
    )

    static let whisperLargeV3Turbo = ASRModel(
        id: "whisper-large-v3-turbo",
        engine: .whisper,
        variant: "openai_whisper-large-v3-v20240930_turbo",
        displayName: "Whisper large-v3 turbo",
        downloadBytes: 632 * 1_000_000,
        residentBytes: 900 * 1_000_000,
        languageSummary: String(localized: "Cerca de 100 idiomas"),
        tagline: String(localized: "Para idiomas que Parakeet no cubre. Más lento y puede inventar texto sobre silencio."),
        license: "MIT",
        attribution: "OpenAI — openai/whisper-large-v3-turbo",
        sourceRepository: "argmaxinc/whisperkit-coreml",
        minimumMacOS: 14,
        metrics: ModelMetrics(
            facts: [
                .init(label: String(localized: "Error en español"), value: "~4,7 %"),
                .init(label: String(localized: "Dónde corre"), value: "GPU"),
            ],
            caveat: String(localized: "Sobre silencio o ruido tiende a inventar texto que nadie dijo. Conviene solo para idiomas que Parakeet no cubre."),
            provenance: .published)
    )

    static let appleSpeech = ASRModel(
        id: "apple-speech",
        engine: .apple,
        variant: "system",
        displayName: String(localized: "Dictado del sistema"),
        downloadBytes: 0,
        residentBytes: 0,
        languageSummary: String(localized: "30 idiomas que gestiona macOS"),
        tagline: String(localized: "Cero descarga: usa el motor que ya trae macOS. Ideal para probar la app al instante."),
        license: String(localized: "Propietario de Apple"),
        attribution: nil,
        sourceRepository: nil,
        minimumMacOS: 26,
        // Apple no publica cifras de precisión de su motor de dictado.
        metrics: nil
    )

    /// Todos los modelos, en el orden en que se muestran.
    static let all: [ASRModel] = [
        parakeetV3Int8,
        parakeetV3Int4,
        parakeetEnglishFast,
        whisperLargeV3Turbo,
        appleSpeech,
    ]

    /// Los que esta Mac puede correr.
    static var available: [ASRModel] {
        all.filter(\.isAvailableOnThisMac)
    }

    static let `default` = parakeetV3Int8

    static func model(id: String) -> ASRModel? {
        all.first { $0.id == id }
    }

    /// Qué modelo proponer en el primer arranque.
    ///
    /// En macOS 26 o superior conviene arrancar con el motor del sistema: la
    /// app funciona en el mismo segundo en que se instala, sin media hora de
    /// descarga antes de poder probar nada. La HIG lo dice explícitamente («no
    /// dejes que una descarga grande entorpezca la puesta en marcha»), y es
    /// además donde más gente abandona el onboarding. Parakeet se ofrece
    /// después, ya con la app funcionando.
    static var firstRunSuggestion: ASRModel {
        appleSpeech.isAvailableOnThisMac ? appleSpeech : parakeetV3Int8
    }
}
