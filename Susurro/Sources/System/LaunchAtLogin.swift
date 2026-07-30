import Foundation
import OSLog
import ServiceManagement

/// Registrar Susurro para que se abra al iniciar sesión.
///
/// Para una app que vive en la barra de menús esto no es un lujo: si hay que
/// abrirla a mano después de cada reinicio, la tecla de dictado falla justo
/// cuando uno se olvidó, que es siempre.
///
/// Está apagado por defecto igual. La HIG es explícita en que arrancar solo es
/// una decisión de la persona, no de la app, y una utilidad que se auto-instala
/// en el arranque sin preguntar es exactamente lo que uno no quiere de un
/// programa que escucha el micrófono.
///
/// El detalle importante de la implementación: **nunca hay que confiar en que
/// `register()` funcionó**. `SMAppService` tiene un historial largo de fallar en
/// silencio según la versión de macOS, y además el sistema puede dejar el
/// registro «pendiente de aprobación», donde la app cree que quedó configurada y
/// en realidad no arranca nunca. Por eso siempre se relee el estado después de
/// escribir, y ese estado real es el que se le muestra a la persona.
@MainActor
enum LaunchAtLogin {

    private static let logger = Logger(subsystem: "com.acti.susurro", category: "LaunchAtLogin")

    enum State: Equatable {
        case enabled
        case disabled
        /// macOS lo aceptó pero espera que la persona lo apruebe en Ajustes del
        /// Sistema › General › Ítems de inicio de sesión.
        case requiresApproval
        case unsupported

        var isOn: Bool { self == .enabled }
    }

    /// Estado real, leído del sistema. No se cachea a propósito: la persona
    /// puede desactivarlo desde Ajustes del Sistema sin que la app se entere.
    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:            return .enabled
        case .requiresApproval:   return .requiresApproval
        case .notRegistered:      return .disabled
        case .notFound:           return .unsupported
        @unknown default:         return .unsupported
        }
    }

    /// Activa o desactiva, y devuelve lo que realmente quedó configurado.
    @discardableResult
    static func set(_ enabled: Bool) -> State {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("no se pudo \(enabled ? "registrar" : "quitar") el inicio automático: \(error.localizedDescription, privacy: .public)")
        }

        // Se relee en vez de asumir: es la única forma de detectar el caso
        // «quedó pendiente de aprobación», que de otro modo se ve idéntico
        // a un éxito.
        let result = state
        logger.debug("inicio automático: \(String(describing: result), privacy: .public)")
        return result
    }

    /// Abre el panel donde se aprueban los ítems de inicio de sesión.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
