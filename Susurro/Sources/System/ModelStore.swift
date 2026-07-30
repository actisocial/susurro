import Foundation
import OSLog

/// Dónde viven los modelos descargados y en qué estado está cada uno.
///
/// Existe por una razón concreta: FluidAudio decide si un modelo está instalado
/// mirando únicamente si el directorio existe (issue #819). O sea que si la
/// descarga se corta a la mitad —wifi que se cae, app que se cierra, disco que
/// se llena— el directorio queda ahí con archivos incompletos, la librería nunca
/// vuelve a descargar, y la carga falla para siempre sin una forma obvia de
/// arreglarlo. Es el modo de falla más probable de un esquema de "descarga bajo
/// demanda".
///
/// La solución es un manifiesto al lado de cada modelo que registra si la
/// instalación llegó a terminar. Un directorio sin manifiesto completo se trata
/// como basura y se borra, no como modelo instalado.
///
/// Los modelos van en Application Support y no en Caches a propósito: son
/// descargas grandes y deliberadas, y macOS puede vaciar Caches cuando se le
/// antoje. Que el sistema borre 500 MB que la persona esperó cinco minutos, sin
/// avisar, sería inaceptable.
struct ModelStore: Sendable {

    private let root: URL
    /// `FileManager.default` se toma en cada uso en vez de guardarlo: la clase
    /// no es `Sendable` y esta estructura sí necesita serlo.
    private var fileManager: FileManager { .default }
    private let logger = Logger(subsystem: "com.acti.susurro", category: "ModelStore")

    private static let manifestName = ".susurro-manifest.json"

    private struct Manifest: Codable {
        enum State: String, Codable {
            case installing
            case complete
            case failed
        }
        var modelID: String
        var state: State
        var updatedAt: Date
        var appVersion: String
    }

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.root = support
                .appendingPathComponent("Susurro", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
        }
    }

    // MARK: - Ubicaciones

    var rootDirectory: URL { root }

    func directory(for model: ASRModel) -> URL {
        root.appendingPathComponent(model.id, isDirectory: true)
    }

    private func manifestURL(for model: ASRModel) -> URL {
        directory(for: model).appendingPathComponent(Self.manifestName)
    }

    // MARK: - Estado

    /// Instalado *y* verificado: existe el directorio y el manifiesto dice que
    /// la descarga terminó bien.
    func isInstalled(_ model: ASRModel) -> Bool {
        // El motor del sistema no descarga nada: siempre está listo.
        guard model.requiresDownload else { return true }
        guard let manifest = readManifest(for: model) else { return false }
        return manifest.state == .complete && fileManager.fileExists(atPath: directory(for: model).path)
    }

    /// Hay archivos pero la instalación nunca terminó. Hay que borrar y rehacer.
    func isIncomplete(_ model: ASRModel) -> Bool {
        let dir = directory(for: model)
        guard fileManager.fileExists(atPath: dir.path) else { return false }
        guard let manifest = readManifest(for: model) else {
            // Directorio sin manifiesto: o quedó de una descarga interrumpida, o
            // lo dejó una versión anterior de la app. En los dos casos, lo
            // seguro es rehacerlo.
            return true
        }
        return manifest.state != .complete
    }

    func beginInstall(_ model: ASRModel) async throws {
        let dir = directory(for: model)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        // Los modelos no son documentos: no tiene sentido subirlos a iCloud ni
        // meterlos en Time Machine. Son varios cientos de megas re-descargables.
        try? excludeFromBackup(dir)
        writeManifest(.installing, for: model)
    }

    func completeInstall(_ model: ASRModel) throws {
        writeManifest(.complete, for: model)
    }

    func markFailed(_ model: ASRModel) {
        writeManifest(.failed, for: model)
    }

    func remove(_ model: ASRModel) throws {
        let dir = directory(for: model)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        try fileManager.removeItem(at: dir)
        logger.info("modelo \(model.id, privacy: .public) eliminado del disco")
    }

    // MARK: - Disco

    /// Cuánto ocupa realmente un modelo ya bajado.
    func diskUsage(of model: ASRModel) -> Int64 {
        directorySize(directory(for: model))
    }

    /// Cuánto ocupan todos juntos. Se muestra en Ajustes: media docena de
    /// modelos suman varios gigabytes y la persona tiene que poder verlo.
    func totalDiskUsage() -> Int64 {
        directorySize(root)
    }

    /// Chequea el espacio libre antes de empezar. Descubrir que el disco está
    /// lleno recién a los 400 MB descargados es una forma pésima de enterarse.
    func checkDiskSpace(for model: ASRModel) throws {
        // Se pide 1,5× el tamaño anunciado: la descarga es comprimida y CoreML
        // además compila los modelos al instalarlos, lo que ocupa temporalmente
        // bastante más que el archivo bajado.
        let needed = Int64(Double(model.downloadBytes) * 1.5)
        guard let available = availableCapacity() else { return }
        guard available > needed else {
            throw SpeechEngineError.notEnoughDiskSpace(needed: needed, available: available)
        }
    }

    private func availableCapacity() -> Int64? {
        let values = try? root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        // Antes del primer modelo, `root` puede no existir todavía.
        let home = fileManager.homeDirectoryForCurrentUser
        let fallback = try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return fallback?.volumeAvailableCapacityForImportantUsage
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Manifiesto

    private func readManifest(for model: ASRModel) -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: model)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private func writeManifest(_ state: Manifest.State, for model: ASRModel) {
        let manifest = Manifest(
            modelID: model.id,
            state: state,
            updatedAt: Date(),
            appVersion: Bundle.main.appVersion
        )
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL(for: model), options: .atomic)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }
}
