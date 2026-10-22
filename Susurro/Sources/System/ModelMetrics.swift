import Foundation

/// Lo que se sabe sobre qué tan bien anda un modelo, y de dónde salió ese dato.
///
/// Existe porque elegir modelo por el nombre lleva a elegir mal. «4B tiene que
/// ser mejor que 2B» es la intuición razonable y en esta Mac es falsa: el 4B es
/// más capaz y aun así rinde peor, porque no llega a contestar dentro del
/// presupuesto de tiempo y entonces no corrige nada. Un número al lado del
/// nombre convierte esa trampa en una decisión informada.
///
/// **La procedencia es parte del dato, no un adorno.** El catálogo de refinado
/// se midió acá, sobre los 46 casos del banco. El de reconocimiento no se midió
/// nunca: sus cifras vienen de lo que publica quien entrenó el modelo, sobre sus
/// propios conjuntos de prueba. Mostrar las dos cosas con la misma cara sería
/// decirle a la persona que hay evidencia donde no la hay.
struct ModelMetrics: Sendable, Hashable, Codable {

    enum Provenance: String, Sendable, Codable {
        /// Medido en esta Mac con el banco que trae la app.
        case measuredHere
        /// Publicado por quien entrenó el modelo. No verificado acá.
        case published

        var note: String {
            switch self {
            case .measuredHere:
                return String(localized: "Medido en esta Mac sobre 46 dictados de prueba.")
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
