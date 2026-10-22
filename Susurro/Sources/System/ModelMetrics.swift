import Foundation

/// Lo que se sabe sobre qué tan bien anda un modelo, y de dónde salió ese dato.
///
/// Existe porque elegir modelo por el nombre lleva a elegir mal. Un número al
/// lado del nombre convierte esa trampa en una decisión informada.
///
/// **La procedencia es parte del dato, no un adorno.** Ninguna cifra se midió
/// acá: vienen de lo que publica quien entrenó el modelo, sobre sus propios
/// conjuntos de prueba, y se muestran etiquetadas así.
struct ModelMetrics: Sendable, Hashable, Codable {

    enum Provenance: String, Sendable, Codable {
        /// Publicado por quien entrenó el modelo. No verificado acá.
        case published

        var note: String {
            switch self {
            case .published:
                return String(localized: "Según quien entrenó el modelo. No verificado en esta Mac.")
            }
        }
    }

    /// Un dato suelto, con su etiqueta. Se muestran en fila bajo el modelo.
    struct Fact: Sendable, Hashable, Codable {
        let label: String
        let value: String
    }

    var facts: [Fact] = []

    /// Advertencia que cambia la decisión, no un matiz.
    ///
    /// Va aparte de los `facts` y se pinta distinto porque no es un número más:
    /// es el motivo por el que alguien debería *no* elegir este modelo aunque
    /// las demás cifras lo favorezcan.
    var caveat: String?

    var provenance: Provenance
}
