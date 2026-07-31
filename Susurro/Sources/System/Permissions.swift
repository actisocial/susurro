import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import OSLog
import Observation
import Security

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
        /// Se concedió, pero la entrada quedó atada a un binario anterior.
        ///
        /// Es el caso más confuso de todos y merece existir aparte: Ajustes del
        /// Sistema muestra a Susurro en la lista **con el interruptor
        /// encendido**, y la app ve `false`. Cualquiera concluye que la app está
        /// rota, porque desde afuera el permiso está dado.
        ///
        /// Pasa porque macOS ata la entrada a la identidad de código, no al
        /// nombre ni a la ruta. Cambiar de una compilación propia a una
        /// descargada, o al revés, cambia esa identidad y la entrada deja de
        /// corresponder. Apagar y prender el interruptor no alcanza: hay que
        /// **quitar la fila con el botón «−» y volver a agregarla**, que no es
        /// algo que nadie adivine.
        case stale

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

        if AXIsProcessTrusted() {
            accessibility = .granted
            // Se anota con qué identidad de código quedó concedido. Es la única
            // forma de distinguir después «nunca lo dio» de «lo dio y se
            // invalidó», que necesitan instrucciones opuestas.
            Self.rememberGrantedIdentity()
        } else {
            accessibility = Self.wasGrantedForAnotherBinary() ? .stale : .denied
        }

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

    // MARK: - Identidad de código

    /// Clave donde se recuerda con qué binario se concedió Accesibilidad.
    ///
    /// Va directo a `UserDefaults` y no a `Preferences` porque no es una
    /// preferencia: nadie la elige ni la ve. Es una miga de pan para poder
    /// diagnosticar después.
    private static let grantedIdentityKey = "accessibilityGrantedForCodeIdentity"

    /// Huella de la identidad de código de este proceso.
    ///
    /// Es el `cdhash`, que es exactamente lo que macOS usa para decidir si una
    /// entrada de TCC corresponde al binario que está pidiendo. Cambia con cada
    /// recompilación y con cada cambio de firma, que es precisamente lo que hace
    /// falta detectar.
    private static func codeIdentity() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }

        return unique.map { String(format: "%02x", $0) }.joined()
    }

    private static func rememberGrantedIdentity() {
        guard let identity = codeIdentity() else { return }
        UserDefaults.standard.set(identity, forKey: grantedIdentityKey)
    }

    /// Si alguna vez se concedió, pero con un binario distinto del actual.
    private static func wasGrantedForAnotherBinary() -> Bool {
        guard let remembered = UserDefaults.standard.string(forKey: grantedIdentityKey) else {
            return false
        }
        // Sin poder leer la identidad actual no se puede afirmar nada. Ante la
        // duda se prefiere el mensaje genérico antes que uno específico y falso.
        guard let current = codeIdentity() else { return false }
        return remembered != current
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

    /// Borra la entrada vieja de Accesibilidad y vuelve a pedir el permiso.
    ///
    /// Esto existe porque la salida manual es adivinanza pura. Cuando la entrada
    /// quedó atada a un binario anterior, Ajustes del Sistema muestra a Susurro
    /// en la lista con el interruptor encendido y la app igual no puede escribir.
    /// Apagar y prender el interruptor **no** arregla nada: hay que seleccionar
    /// la fila, tocar «−», y volver a agregar la app. Nadie deduce eso, y menos
    /// cuando desde afuera el permiso se ve concedido.
    ///
    /// `tccutil reset` hace exactamente eso mismo desde adentro. No necesita
    /// privilegios de administrador mientras se limite al bundle propio, que es
    /// el caso — el identificador se toma del bundle y no se acepta de ningún
    /// lado más, así que no hay forma de que esto toque los permisos de otra app.
    ///
    /// Después del borrado el permiso queda sin decidir, y ahí `AXIsProcess-
    /// TrustedWithOptions` vuelve a mostrar el diálogo del sistema en vez de
    /// fallar en silencio, que es lo que hacía mientras la entrada vieja existía.
    func repairAccessibility() async {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        // La salida se descarta pero se captura igual: sin esto hereda la
        // consola del proceso y ensucia el log del sistema.
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
            }
        } catch {
            logger.error("no se pudo reparar el permiso: \(error.localizedDescription, privacy: .public)")
            // Si `tccutil` no está o falla, queda el camino manual.
            Self.openSystemSettings(.accessibility)
            return
        }

        UserDefaults.standard.removeObject(forKey: Self.grantedIdentityKey)
        requestAccessibility(prompt: true)
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
