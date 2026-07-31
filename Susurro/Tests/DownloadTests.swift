import Foundation
import Testing

@testable import Susurro

/// Lo que se prueba acá decide cuándo se tiran cientos de megas ya bajados y qué
/// ve la persona mientras espera. Son las dos cosas que hicieron que un primer
/// arranque real se sintiera roto: una descarga que se reiniciaba entera y un
/// «2 %» inmóvil sin nada al lado.
struct SalvageTests {

    /// Cada test arma su propio directorio de modelos y lo borra al terminar.
    private func withStore(_ body: (ModelStore, ASRModel) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("susurro-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(ModelStore(root: root), ModelCatalog.parakeetV3Int8)
    }

    @Test("sin archivos no hay nada que rescatar")
    func nothingOnDisk() async throws {
        try await withStore { store, model in
            #expect(store.salvage(model) == .nothingToDo)
        }
    }

    @Test("un modelo completo se deja en paz")
    func completeIsLeftAlone() async throws {
        try await withStore { store, model in
            try await store.beginInstall(model)
            try store.completeInstall(model)
            #expect(store.salvage(model) == .nothingToDo)
        }
    }

    /// El caso que motivó todo el cambio: la app se cerró en medio de la
    /// descarga. Antes esto borraba el directorio entero y volvía a empezar; con
    /// una conexión inestable, nunca terminaba.
    @Test("una descarga interrumpida se reanuda, no se borra")
    func interruptedResumes() async throws {
        try await withStore { store, model in
            try await store.beginInstall(model)
            let partial = store.directory(for: model)
                .appendingPathComponent("Encoder.mlmodelc/weights/weight.bin.partial")
            try FileManager.default.createDirectory(
                at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: 4096).write(to: partial)

            guard case .resume(let bytes) = store.salvage(model) else {
                Issue.record("una instalación a medias tiene que reanudarse")
                return
            }
            #expect(bytes >= 4096)
        }
    }

    /// La contracara: acá sí hubo un error de verdad y no se sabe qué quedó.
    /// Conservar bytes de un intento que falló sí sería imprudente.
    @Test("un intento que falló sí se descarta")
    func failedIsDiscarded() async throws {
        try await withStore { store, model in
            try await store.beginInstall(model)
            store.markFailed(model)
            guard case .discard = store.salvage(model) else {
                Issue.record("un intento fallido tiene que descartarse")
                return
            }
        }
    }

    /// Archivos de procedencia desconocida —los dejó otra versión de la app, con
    /// otro formato— tampoco se conservan.
    @Test("archivos sin manifiesto se descartan")
    func unknownProvenanceIsDiscarded() async throws {
        try await withStore { store, model in
            let dir = store.directory(for: model)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("viejo".utf8).write(to: dir.appendingPathComponent("algo.bin"))
            guard case .discard = store.salvage(model) else {
                Issue.record("sin manifiesto no se puede confiar en lo que hay")
                return
            }
        }
    }
}

struct PreparationProgressTests {

    @Test("mientras descarga dice cuántos bytes van de cuántos")
    func showsBytes() {
        var progress = PreparationProgress(phase: .downloading(file: 1, of: 5), fraction: 0.2)
        progress.bytesOnDisk = 100 * 1_000_000
        progress.bytesExpected = 483 * 1_000_000

        let detail = try! #require(progress.detail)
        #expect(detail.contains("100"))
        #expect(detail.contains("483"))
    }

    /// La velocidad y el tiempo restante solo aparecen cuando se conocen. Un
    /// «faltan 0 s» que no avanza es peor que no decir nada.
    @Test("sin velocidad medida no inventa un tiempo restante")
    func noFabricatedEstimate() {
        var progress = PreparationProgress(phase: .downloading(file: 0, of: 3), fraction: 0.1)
        progress.bytesOnDisk = 1_000
        progress.bytesExpected = 483 * 1_000_000

        let detail = try! #require(progress.detail)
        #expect(!detail.contains("/s"))
        #expect(!detail.contains("falta"))
    }

    /// El bug que hacía ilegible la pantalla: FluidAudio reparte la fracción
    /// mitad descarga, mitad compilación, y la app decía «Descargando» en las
    /// dos. Justo en la segunda mitad el número no se mueve.
    @Test("compilar no se anuncia como descarga")
    func compilingIsNotCalledDownloading() {
        let compiling = PreparationProgress(phase: .compiling(model: "Encoder"), fraction: 0.7)
        let downloading = PreparationProgress(phase: .downloading(file: 1, of: 3), fraction: 0.2)
        #expect(compiling.summary != downloading.summary)
        #expect(compiling.detail == "Encoder")
    }

    @Test("compilar sin nombre no deja un renglón vacío")
    func compilingWithoutNameHasNoDetail() {
        let progress = PreparationProgress(phase: .compiling(model: ""), fraction: 1)
        #expect(progress.detail == nil)
    }

    @Test("sin saber el total no muestra una cuenta a medias")
    func noTotalNoDetail() {
        var progress = PreparationProgress(phase: .downloading(file: 0, of: 0), fraction: 0)
        progress.bytesOnDisk = 5_000
        progress.bytesExpected = 0
        #expect(progress.detail == nil)
    }
}

struct RefinementCacheTests {

    /// Si este nombre no coincide con el que usa la caché de Hugging Face, el
    /// medidor apunta a un directorio inexistente, mide cero, y la barra del
    /// modelo de limpieza se queda clavada sin que falle nada. Un error que no
    /// rompe nada es el que más tarda en encontrarse.
    @Test("el nombre de carpeta coincide con el de la caché de Hugging Face")
    func cacheFolderMatchesHubLayout() {
        #expect(
            RefinementCatalog.qwen35_2b_8bit.cacheFolderName
                == "models--mlx-community--Qwen3.5-2B-8bit")
    }

    @Test("todos los modelos del catálogo derivan una carpeta válida")
    func everyModelHasAFolder() {
        for model in RefinementCatalog.all {
            #expect(model.cacheFolderName.hasPrefix("models--"))
            #expect(!model.cacheFolderName.contains("/"))
        }
    }

    /// El 4B volvió al catálogo. Estuvo afuera para que nadie lo eligiera por el
    /// nombre; ahora está adentro con sus cifras y su advertencia, que es la
    /// forma honesta de resolver lo mismo.
    @Test("el 4B está en el catálogo, y con su advertencia")
    func fourBIsListedWithItsCaveat() {
        #expect(RefinementCatalog.all.contains { $0.id == RefinementCatalog.qwen35_4b.id })
        #expect(RefinementCatalog.qwen35_4b.metrics.caveat != nil)
    }

    /// El recomendado no puede quedar con una advertencia: si la tiene, o la
    /// advertencia sobra o el recomendado está mal elegido.
    @Test("el recomendado no arrastra advertencias")
    func defaultHasNoCaveat() {
        #expect(RefinementCatalog.default.metrics.caveat == nil)
    }
}

struct DownloadMeterTests {

    @Test("cuenta lo que hay en disco, incluidos los archivos a medias")
    func measuresPartials() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("medidor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)

        try Data(repeating: 0, count: 1_000).write(to: dir.appendingPathComponent("a.bin"))
        // El `.partial` es justamente el archivo grande a medio bajar. No
        // contarlo dejaría la cifra clavada en cero durante todo el tramo que
        // más falta hace explicar.
        try Data(repeating: 0, count: 2_000)
            .write(to: dir.appendingPathComponent("sub/b.bin.partial"))

        #expect(DownloadMeter.size(of: dir) == 3_000)
    }

    @Test("un directorio que todavía no existe mide cero y no explota")
    func missingDirectoryIsZero() {
        let missing = URL(fileURLWithPath: "/no/existe/\(UUID().uuidString)")
        #expect(DownloadMeter.size(of: missing) == 0)
    }

    @Test("la primera muestra no reporta velocidad")
    func firstSampleHasNoRate() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("medidor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 500).write(to: dir.appendingPathComponent("a.bin"))

        let meter = DownloadMeter(directory: dir, expected: 10_000)
        let first = meter.sample(phase: .downloading(file: 0, of: 1), fraction: 0)
        #expect(first.bytesOnDisk == 500)
        #expect(first.bytesPerSecond == nil)
        #expect(first.secondsRemaining == nil)
    }
}
