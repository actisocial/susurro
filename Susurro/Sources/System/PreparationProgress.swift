import Foundation
import os

/// Qué está haciendo la app mientras deja un modelo listo, y cuánto falta.
///
/// Existe porque un porcentaje solo no alcanza. Preparar un modelo son varios
/// minutos, y durante esos minutos el número se queda quieto en dos tramos
/// distintos por dos motivos distintos: mientras baja el archivo grande, y
/// mientras CoreML compila. Un usuario que ve «2 %» sin nada más no puede
/// distinguir eso de un cuelgue, y la conclusión razonable es que la app está
/// rota. Pasó, y por eso este tipo lleva la fase y los bytes además de la
/// fracción.
struct PreparationProgress: Sendable, Equatable {

    /// En qué etapa está la preparación.
    ///
    /// Se corresponde con `DownloadPhase` de FluidAudio, traducida al borde como
    /// todo lo demás que viene de un SDK. La distinción que importa de cara al
    /// usuario es descargar contra compilar: son las dos mitades de la barra
    /// —FluidAudio le da peso 0,5 a cada una— y tienen causas de lentitud
    /// completamente distintas. Decir «Descargando» durante la compilación es
    /// mentir la mitad del tiempo, y encima es la mitad en la que el número no
    /// se mueve.
    enum Phase: Sendable, Equatable {
        /// Pidiendo la lista de archivos al repositorio remoto.
        case listing
        /// Bajando archivos. Los índices son los que informa la librería.
        case downloading(file: Int, of: Int)
        /// Compilando para el Neural Engine. Es local, no usa red, y no emite
        /// progreso intermedio: salta de modelo en modelo.
        case compiling(model: String)
        /// Cargando en memoria lo ya compilado.
        case loading
    }

    var phase: Phase

    /// Fracción global de la operación, tal como la informa la librería.
    var fraction: Double

    /// Bytes que hay en disco ahora mismo.
    ///
    /// **Medido, no estimado.** Se podría derivar de `fraction` sabiendo que
    /// FluidAudio le da peso 0,5 a la descarga, pero ese 0,5 es un detalle
    /// interno suyo: el día que lo cambie, la app mostraría cifras falsas sin
    /// que nada falle. Contar lo que hay en el directorio es exacto, cuesta un
    /// recorrido de diez archivos, y sigue siendo cierto pase lo que pase
    /// upstream.
    var bytesOnDisk: Int64 = 0

    /// Cuánto se espera que pese en total, del catálogo.
    var bytesExpected: Int64 = 0

    /// Velocidad suavizada. `nil` hasta tener dos muestras.
    var bytesPerSecond: Double?

    /// Cuánto falta, derivado de la velocidad suavizada.
    var secondsRemaining: TimeInterval?

    static let starting = PreparationProgress(phase: .listing, fraction: 0)

    // MARK: - Texto para la interfaz

    /// Qué está pasando, en una línea, sin el nombre del modelo.
    ///
    /// El nombre lo pone quien llama, porque en la barra de menú conviene
    /// («Descargando Parakeet TDT v3») y en la fila de Ajustes sobra: el nombre
    /// ya está escrito justo arriba.
    var summary: String {
        switch phase {
        case .listing:
            return String(localized: "Buscando los archivos…")
        case .downloading:
            return String(localized: "Descargando")
        case .compiling:
            return String(localized: "Compilando para el Neural Engine")
        case .loading:
            return String(localized: "Cargando en memoria…")
        }
    }

    /// El detalle que acompaña a `summary`: bytes, velocidad y cuánto falta.
    ///
    /// Devuelve `nil` cuando no hay nada honesto que decir todavía —al empezar,
    /// o mientras compila, que no tiene unidades intermedias—. Preferible un
    /// renglón menos que un número inventado.
    var detail: String? {
        switch phase {
        case .listing, .loading:
            return nil

        case .compiling(let model):
            // La compilación no informa avance dentro de cada modelo, así que
            // lo único cierto que se puede decir es cuál se está compilando.
            return model.isEmpty ? nil : model

        case .downloading:
            guard bytesExpected > 0 else { return nil }
            let format = ByteCountFormatter.string(fromByteCount:countStyle:)
            var parts = [
                String(
                    localized: "\(format(bytesOnDisk, .file)) de \(format(bytesExpected, .file))")
            ]
            if let speed = bytesPerSecond, speed > 0 {
                parts.append(String(localized: "\(format(Int64(speed), .file))/s"))
            }
            if let remaining = secondsRemaining, remaining > 1 {
                parts.append(Self.remainingText(remaining))
            }
            return parts.joined(separator: " · ")
        }
    }

    /// «falta 1 min», «faltan 3 min», «faltan 40 s».
    ///
    /// Sin segundos por debajo del minuto y sin decimales: una cuenta regresiva
    /// precisa sobre una estimación ruidosa se ve nerviosa y no agrega nada.
    private static func remainingText(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(localized: "faltan \(Int(seconds.rounded())) s")
        }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1
            ? String(localized: "falta 1 min")
            : String(localized: "faltan \(minutes) min")
    }
}

/// Mide cuánto pesa un directorio mientras se llena, y de ahí saca velocidad y
/// tiempo restante.
///
/// La velocidad se suaviza con una media exponencial en vez de usar la
/// diferencia entre dos muestras. La cruda salta demasiado —una ráfaga de red,
/// o una muestra tomada justo entre dos escrituras, da cifras absurdas— y una
/// velocidad que parpadea entre 300 KB/s y 40 MB/s es peor que no mostrar
/// ninguna: transmite que la app no sabe lo que hace.
/// No es un actor a propósito. FluidAudio entrega el progreso por un closure
/// sincrónico, desde una cola cualquiera; con un actor habría que abrir una
/// `Task` en cada aviso, y los avisos de bytes llegan muchas veces por segundo.
/// Un candado sobre un estado chiquito es la herramienta correcta acá.
final class DownloadMeter: Sendable {

    /// Peso que se le da a la muestra nueva. Más bajo, más estable y más lento
    /// en reaccionar; 0,3 reacciona en unos pocos segundos y no parpadea.
    private static let smoothing = 0.3

    /// Cada cuánto se mira el disco. Recorrer el directorio en cada aviso de
    /// bytes sería caro y no aportaría nada: nadie lee una cifra que cambia
    /// veinte veces por segundo.
    private static let sampleInterval: TimeInterval = 0.5

    private struct State {
        var smoothedRate: Double?
        var lastSample: (bytes: Int64, at: Date)?
        var lastMeasured: PreparationProgress?
    }

    private let directory: URL
    private let expected: Int64
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(directory: URL, expected: Int64) {
        self.directory = directory
        self.expected = expected
    }

    /// Devuelve el progreso enriquecido, midiendo el disco como mucho una vez
    /// cada `sampleInterval` y reutilizando la última medición el resto del
    /// tiempo.
    func sample(phase: PreparationProgress.Phase, fraction: Double) -> PreparationProgress {
        let now = Date()

        let needsMeasurement = state.withLock { state -> Bool in
            guard let last = state.lastSample else { return true }
            return now.timeIntervalSince(last.at) >= Self.sampleInterval
        }

        guard needsMeasurement else {
            // Se reutilizan los bytes de la última medición, pero la fase y la
            // fracción son las de ahora: son gratis y es lo que más se mueve.
            return state.withLock { state in
                var progress = state.lastMeasured
                    ?? PreparationProgress(phase: phase, fraction: fraction)
                progress.phase = phase
                progress.fraction = fraction
                return progress
            }
        }

        // La medición se hace fuera del candado: es E/S y puede tardar.
        let bytes = Self.size(of: directory)

        return state.withLock { state in
            var progress = PreparationProgress(phase: phase, fraction: fraction)
            progress.bytesExpected = expected
            progress.bytesOnDisk = bytes

            if let previous = state.lastSample {
                let elapsed = now.timeIntervalSince(previous.at)
                // Muestras muy juntas dividen por casi cero. Y los bytes pueden
                // bajar si la librería descarta un `.partial` que no se podía
                // reanudar: ahí no hay velocidad negativa que valga, se ignora.
                if elapsed > 0.2, bytes > previous.bytes {
                    let instant = Double(bytes - previous.bytes) / elapsed
                    state.smoothedRate = state.smoothedRate.map {
                        $0 * (1 - Self.smoothing) + instant * Self.smoothing
                    } ?? instant
                }
            }
            state.lastSample = (bytes, now)

            if let rate = state.smoothedRate, rate > 0, expected > bytes {
                progress.bytesPerSecond = rate
                progress.secondsRemaining = Double(expected - bytes) / rate
            }
            state.lastMeasured = progress
            return progress
        }
    }

    /// Peso total de un directorio, contando solo archivos.
    ///
    /// Cuenta los `.partial` porque son justamente los bytes que ya se bajaron;
    /// no contarlos haría que la cifra se quedara en cero durante todo el
    /// archivo grande, que es el tramo que más falta hace explicar.
    static func size(of directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
