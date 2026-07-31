import AppKit
import Combine
import Observation
import OSLog

/// El ítem de Susurro en la barra de menús.
///
/// Está hecho con `NSStatusItem` y no con el `MenuBarExtra` de SwiftUI, y la
/// razón es concreta: el estilo `.menu` de `MenuBarExtra` bloquea el runloop
/// mientras el menú está abierto, así que la animación del ícono se congela
/// justo cuando alguien lo está mirando. Además `MenuBarExtra` no da acceso al
/// `NSStatusItem` de abajo, lo que deja sin `autosaveName` (recordar la posición
/// donde la persona lo arrastró), sin `isVisible` y sin forma de cerrar el menú
/// por código.
///
/// Reglas de la HIG que se siguen acá:
/// - Al hacer clic se abre un **menú**, no un popover.
/// - El ícono es una imagen de plantilla monocroma: se adapta solo a la barra
///   clara, oscura, con fondo y con «reducir transparencia».
/// - Los ítems no disponibles se muestran desactivados, no se esconden.
/// - Ajustes con ⌘, y Salir con ⌘Q, en ese orden y al final.
@MainActor
final class StatusItemController: NSObject {

    private let statusItem: NSStatusItem
    private let controller: DictationController
    private let preferences: Preferences
    private var openSettings: () -> Void
    private var openOnboarding: () -> Void

    private let menu = NSMenu()
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var observationTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.acti.susurro", category: "StatusItem")

    init(
        controller: DictationController,
        preferences: Preferences,
        openSettings: @escaping () -> Void,
        openOnboarding: @escaping () -> Void
    ) {
        self.controller = controller
        self.preferences = preferences
        self.openSettings = openSettings
        self.openOnboarding = openOnboarding

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Hace que macOS recuerde dónde lo dejó la persona si lo arrastró.
        statusItem.autosaveName = "SusurroStatusItem"

        // `NSMenuDelegate` obliga a heredar de `NSObject`, y el delegado no se
        // puede asignar antes de que la inicialización esté completa.
        super.init()

        configureButton()
        observeState()
        render()
    }

    /// Da de baja el temporizador y la observación. Lo llama el delegado de la
    /// app al terminar; no hay `deinit` porque bajo concurrencia estricta no
    /// puede tocar estado aislado al actor principal.
    func tearDown() {
        stopAnimating()
        observationTask?.cancel()
        observationTask = nil
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(String(localized: "Susurro"))

        // El menú se arma en `menuWillOpen`, no acá ni en cada redibujo. Es la
        // única forma de garantizar que lo que se ve sea el estado del momento
        // en que se abre: reconstruirlo por observación deja ventanas donde un
        // cambio se pierde y el menú miente. Ver el comentario en `observeState`.
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Estado → ícono

    /// Mantiene el ícono en sintonía con el estado.
    ///
    /// Redibuja en **cada vuelta**, no solo cuando `withObservationTracking`
    /// avisa. La razón es un bug que se vio en uso: esa API notifica una única
    /// vez y hay que volver a suscribirse después de cada aviso, así que todo
    /// cambio que ocurra entre el aviso y la nueva suscripción se pierde en
    /// silencio. Justamente la transición «terminé de descargar» caía en ese
    /// hueco y el menú se quedaba diciendo «Descargando… 100 %» para siempre.
    ///
    /// Redibujar el ícono cada 150 ms es barato —asignar una imagen y un
    /// tooltip— y elimina la clase entera de fallas. El contenido del menú, que
    /// sí es caro de armar, se construye recién al abrirlo.
    private func observeState() {
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                render()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }

        switch controller.state {
        case .idle:
            stopAnimating()
            button.image = Self.symbol("mic")
            button.toolTip = tooltipForIdle()

        case .preparing(let progress):
            stopAnimating()
            // El ícono también cambia por fase: la flecha hacia abajo mientras
            // baja, y el engranaje mientras compila. Es la única señal de que
            // algo sigue pasando en el tramo donde el número no se mueve.
            button.image = Self.symbol(Self.symbolName(for: progress.phase))
            button.toolTip = [progress.summary, progress.detail]
                .compactMap { $0 }
                .joined(separator: " — ")

        case .listening(let locked):
            startAnimating()
            button.toolTip = locked
                ? String(localized: "Escuchando (manos libres). Apretá otra vez para terminar.")
                : String(localized: "Escuchando… Soltá para transcribir.")

        case .transcribing, .refining:
            startAnimating()
            button.toolTip = String(localized: "Transcribiendo…")

        case .failed(let message):
            stopAnimating()
            button.image = Self.symbol("mic.slash")
            button.toolTip = message
        }
    }

    private func tooltipForIdle() -> String {
        if let notice = controller.lastNotice { return notice }
        return String(localized: "Susurro — mantené \(preferences.trigger.label) para dictar")
    }

    // MARK: - Animación

    /// Tres cuadros a 6 fps y nada más.
    ///
    /// La tentación es dibujar una onda a 60 fps que siga el nivel del
    /// micrófono, pero macOS 26 tiene una regresión conocida en la suavidad de
    /// las animaciones de `NSStatusItem`, y además el menú abierto bloquea el
    /// runloop. Una animación discreta y lenta se ve bien igual y no se rompe.
    /// El medidor de nivel de verdad está en el HUD, donde SwiftUI anima como
    /// corresponde.
    private static let listeningFrames = ["waveform", "waveform.badge.mic", "waveform"]

    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationFrame = 0
        tickAnimation()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAnimation() }
        }
    }

    private func tickAnimation() {
        guard let button = statusItem.button else { return }
        let frames = Self.listeningFrames
        button.image = Self.symbol(frames[animationFrame % frames.count])
        animationFrame += 1
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        // Imagen de plantilla: macOS la recolorea sola para la barra clara,
        // oscura, con fondo de escritorio detrás y con transparencia reducida.
        // Un ícono a color se vería mal en al menos una de esas.
        image?.isTemplate = true
        return image
    }

    // MARK: - Menú

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.autoenablesItems = false

        // 1. La acción principal, con el atajo a la vista para que se aprenda solo.
        let action = NSMenuItem(
            title: controller.state.isRecording
                ? String(localized: "Terminar dictado")
                : String(localized: "Dictar"),
            action: #selector(toggleDictation),
            keyEquivalent: ""
        )
        action.target = self
        action.isEnabled = !isPreparing
        menu.addItem(action)

        let hint = NSMenuItem(
            title: String(localized: "Mantené \(preferences.trigger.label)"),
            action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        // 2. Estado. Es la única forma de que alguien entienda por qué la app no
        //    responde cuando está bajando un modelo o falta un permiso.
        for item in statusItems() {
            let entry = NSMenuItem(title: item, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }

        if !controller.permissions.allGranted {
            menu.addItem(.separator())
            let fix = NSMenuItem(
                title: String(localized: "Faltan permisos…"),
                action: #selector(showOnboarding), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: String(localized: "Ajustes…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(
            title: String(localized: "Salir de Susurro"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private var isPreparing: Bool {
        if case .preparing = controller.state { return true }
        return false
    }

    private func statusItems() -> [String] {
        var items: [String] = []

        switch controller.state {
        case .preparing(let progress):
            items.append(contentsOf: Self.lines(
                for: progress, model: preferences.asrModel.displayName))
        case .failed(let message):
            items.append(message)
        default:
            items.append(String(localized: "Modelo: \(preferences.asrModel.displayName)"))
            if preferences.refinementMode != .off {
                items.append(String(localized: "Refinado: \(preferences.refinementMode.label)"))
            }
        }

        // La descarga del refinador va aparte y puede seguir después de que el
        // dictado ya funciona, así que se muestra en cualquier estado. Antes no
        // se mostraba nunca: eran 2,5 GB invisibles, cinco veces lo que decía la
        // línea de arriba.
        if let refinement = controller.refinementProgress {
            items.append(contentsOf: Self.lines(
                for: refinement, model: preferences.refinementModel.displayName))
        }

        // Los permisos se avisan acá y no solo en Ajustes.
        //
        // Susurro no tiene ventana ni ícono en el Dock: si el permiso está mal,
        // la única pista es que apretás la tecla y no pasa nada. Descubrirlo
        // exige abrir Ajustes a propósito, sospechando de antemano cuál es el
        // problema. La barra de menús es el único lugar que siempre está a la
        // vista, así que el aviso va acá.
        switch controller.permissions.accessibility {
        case .stale:
            items.append(String(localized: "⚠︎ El permiso de Accesibilidad quedó viejo"))
            items.append(String(localized: "    Abrí Ajustes y tocá «Reparar»"))
        case .denied, .notDetermined:
            items.append(String(localized: "⚠︎ Falta el permiso de Accesibilidad"))
            items.append(String(localized: "    El texto va al portapapeles"))
        case .granted:
            break
        }

        if let notice = controller.lastNotice, case .idle = controller.state {
            items.append(notice)
        }
        return items
    }

    /// Dos renglones por descarga: qué está pasando, y el detalle con bytes.
    ///
    /// Van separados a propósito. El primero cambia poco y da el contexto; el
    /// segundo se mueve todo el tiempo y es el que prueba que la app está viva.
    /// Antes había un solo renglón con un porcentaje, y un porcentaje quieto
    /// durante minutos se lee como un cuelgue — que fue exactamente lo que pasó.
    private static func lines(for progress: PreparationProgress, model: String) -> [String] {
        var lines = [String(localized: "\(progress.summary) \(model)")]
        if let detail = progress.detail {
            lines.append("    " + detail)
        }
        return lines
    }

    /// Ícono por fase. Compilar no usa la red, y la flecha de descarga ahí
    /// miente.
    private static func symbolName(for phase: PreparationProgress.Phase) -> String {
        switch phase {
        case .listing:     return "magnifyingglass"
        case .downloading: return "arrow.down.circle"
        case .compiling:   return "gearshape"
        case .loading:     return "memorychip"
        }
    }

    // MARK: - Acciones

    @objc private func toggleDictation() {
        controller.toggleFromMenu()
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func showOnboarding() {
        openOnboarding()
    }
}

// MARK: - Delegado del menú

extension StatusItemController: NSMenuDelegate {

    /// Arma el menú justo antes de mostrarlo.
    ///
    /// Acá se releen también los permisos, y eso arregla un bug concreto: el
    /// estado de Accesibilidad solo se consultaba al arrancar la app y mientras
    /// hubiera una ventana de Ajustes abierta. Si alguien concedía el permiso
    /// después —que es lo normal, porque la app arranca sin él— el menú seguía
    /// mostrando «Faltan permisos…» indefinidamente aunque ya estuviera todo
    /// bien. macOS no notifica los cambios de permiso, así que el único momento
    /// confiable para preguntarlo es cuando alguien va a mirar la respuesta.
    func menuWillOpen(_ menu: NSMenu) {
        controller.permissions.refresh()
        rebuildMenu()
    }
}
