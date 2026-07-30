import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import OSLog
import Observation

/// Estado de los permisos que Susurro necesita, y cómo pedirlos.
///
/// Son dos, y conviene entender por qué:
///
/// - **Micrófono.** Obvio. Se pide con una alerta del sistema y se resuelve en
///   el momento.
/// - **Accesibilidad.** Hace falta para dos cosas distintas: escuchar la tecla
///   de dictado aunque otra app tenga el foco, y pegar el texto en esa app. Sin
///   esto, `CGEvent.post` no falla: no hace nada. Ese silencio es exactamente
///   el peor modo de falla posible, y por eso el estado se chequea siempre
///   antes de intentar en vez de asumir.
///
/// Un detalle que arruina a mucha gente: el permiso de Accesibilidad está atado
/// a la firma de código *y* a la ruta del binario. Mover la app, re-firmarla o
/// una actualización mal hecha lo invalidan sin ningún aviso — la tecla
/// simplemente deja de responder. Por eso se consulta en vivo con
/// `AXIsProcessTrusted()` en cada uso y nunca se cachea.
@Observable
@MainActor
final class Permissions {

    enum State: Equatable {
        case granted
        case denied
        case notDetermined

        var isGranted: Bool { self == .granted }
    }

    private(set) var microphone: State = .notDetermined
    private(set) var accessibility: State = .notDetermined

    /// Si la app puede funcionar completa.
    var allGranted: Bool { microphone.isGranted && accessibility.isGranted }

    /// Puede dictar pero no puede pegar: el texto va al portapapeles.
    var canDictateOnly: Bool { microphone.isGranted && !accessibility.isGranted }

    private var pollTimer: Timer?
    private let logger = Logger(subsystem: "com.acti.susurro", category: "Permissions")

    /// Último estado registrado, para no repetir la misma línea en cada sondeo.
    private var lastLogged: String?

    init() {
        refresh()
    }

    // MARK: - Consulta

    func refresh() {
        microphone = Self.microphoneState()
        accessibility = AXIsProcessTrusted() ? .granted : .denied

        // Se registra en el log del sistema porque «le di el permiso y no lo
        // detecta» es imposible de diagnosticar de otro modo: Ajustes del
        // Sistema puede mostrar el interruptor encendido mientras el proceso ve
        // lo contrario, y sin este rastro no hay forma de saber cuál de los dos
        // tiene razón. Se puede leer con:
        //   log show --predicate 'subsystem == "com.acti.susurro"' --last 5m --info
        let snapshot = "mic=\(microphone) ax=\(accessibility)"
        if snapshot != lastLogged {
            lastLogged = snapshot
            logger.info("permisos: \(snapshot, privacy: .public)")
        }
    }

    private static func microphoneState() -> State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .notDetermined: return .notDetermined
        default:             return .denied
        }
    }

    /// Vuelve a consultar cada segundo mientras la persona está en Ajustes del
    /// Sistema. macOS no notifica los cambios de permiso, así que sondear es la
    /// única forma de que la interfaz se actualice sola cuando vuelve.
    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Solicitud

    /// Muestra la alerta del sistema para el micrófono. Solo aparece una vez en
    /// la vida de la app; después hay que ir a Ajustes.
    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : .denied
    }

    /// Pide Accesibilidad. Con `prompt: true` macOS muestra el diálogo con el
    /// botón que lleva al panel correspondiente.
    func requestAccessibility(prompt: Bool = true) {
        // `kAXTrustedCheckOptionPrompt` es una global de C que Swift 6 no puede
        // garantizar como segura entre hilos. Acá se lee una sola vez y desde el
        // actor principal, así que la clave se arma con su valor literal, que es
        // estable y está documentado.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options) ? .granted : .denied
    }

    // MARK: - Enlaces a Ajustes del Sistema

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    /// Abre el panel exacto de Ajustes del Sistema.
    ///
    /// El esquema moderno (`com.apple.settings.PrivacySecurity.extension`) es el
    /// que anda en macOS 13 en adelante; se deja el viejo como red por si acaso,
    /// porque abrir el panel equivocado obliga a la persona a buscar a mano
    /// entre treinta filas.
    static func openSystemSettings(_ pane: Pane) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane.rawValue)",
            "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    /// Reinicia la app.
    ///
    /// Algunos cambios de permiso —Monitorización de entrada, sobre todo— no
    /// tienen efecto hasta que el proceso arranca de nuevo. Ofrecer el botón es
    /// mucho mejor que dejar a alguien preguntándose por qué concedió el permiso
    /// y sigue sin andar.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
