import AppKit
import Observation
import SwiftUI

/// El punto de entrada.
///
/// Es una app de AppKit y no de SwiftUI `App`, deliberadamente. El ciclo de vida
/// de SwiftUI resuelve mal justo lo que esta app necesita: la escena `Settings`
/// tiene problemas conocidos para abrirse por código desde una app sin ventanas,
/// y `MenuBarExtra` no da acceso al `NSStatusItem`. Con AppKit se controla todo
/// explícitamente: cuándo hay ventanas, cuándo la app es visible y cuándo no.
/// El contenido igual está escrito en SwiftUI y se monta con `NSHostingView`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let preferences = Preferences.shared
    private var controller: DictationController!
    private var statusItem: StatusItemController!
    private var hud: RecordingHUD!

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var stateObservation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agente de fondo: sin ícono en el Dock ni menú de app. Toda la
        // presencia es el ítem de la barra.
        NSApp.setActivationPolicy(.accessory)

        controller = DictationController(preferences: preferences)
        hud = RecordingHUD(controller: controller)

        statusItem = StatusItemController(
            controller: controller,
            preferences: preferences,
            openSettings: { [weak self] in self?.showSettings() },
            openOnboarding: { [weak self] in self?.showOnboarding() }
        )

        controller.start()
        observeStateForHUD()

        if !preferences.hasCompletedOnboarding {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateObservation?.cancel()
        statusItem.tearDown()
        controller.stop()
    }

    /// Sin ícono en el Dock no hay forma de "reabrir" la app, pero si alguien
    /// hace doble clic en el .app estando ya corriendo, lo razonable es mostrar
    /// Ajustes en vez de no hacer nada.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: - HUD

    private func observeStateForHUD() {
        stateObservation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = withObservationTracking {
                    controller.state
                } onChange: {
                    Task { @MainActor [weak self] in self?.syncHUD() }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func syncHUD() {
        switch controller.state {
        case .listening, .transcribing, .refining:
            hud.show()
        default:
            hud.hide()
        }
    }

    // MARK: - Ventanas

    /// Muestra Ajustes.
    ///
    /// El baile de `activationPolicy` es necesario: una app `.accessory` no
    /// puede traer una ventana al frente ni recibir foco de teclado. Se pasa a
    /// `.regular` mientras la ventana está abierta y se vuelve a `.accessory`
    /// al cerrarla, así el ícono del Dock aparece solo mientras hace falta.
    func showSettings() {
        if let settingsWindow {
            activate(settingsWindow)
            return
        }

        let view = SettingsView(controller: controller, preferences: preferences)
        let window = makeWindow(
            title: String(localized: "Ajustes de Susurro"),
            content: view,
            size: NSSize(width: 520, height: 560))
        settingsWindow = window
        activate(window)
    }

    func showOnboarding() {
        if let onboardingWindow {
            activate(onboardingWindow)
            return
        }

        let view = OnboardingView(
            controller: controller,
            preferences: preferences,
            openSettings: { [weak self] in self?.showSettings() },
            finish: { [weak self] in
                self?.preferences.hasCompletedOnboarding = true
                self?.onboardingWindow?.close()
            })
        let window = makeWindow(
            title: String(localized: "Bienvenido a Susurro"),
            content: view,
            size: NSSize(width: 460, height: 520))
        onboardingWindow = window
        activate(window)
    }

    private func makeWindow(
        title: String, content: some View, size: NSSize
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            // Sin `.fullSizeContentView`: eso hace que el contenido se dibuje
            // por debajo de la barra de título, y solo tiene sentido cuando uno
            // le da un tratamiento especial a esa zona. Acá no, así que lo único
            // que haría es tapar el borde superior.
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title

        let hosting = NSHostingView(rootView: content)

        // `sizingOptions = []` es lo que hace que esto funcione, y sin ello la
        // ventana sale deforme.
        //
        // Por defecto, `NSHostingView` deduce el tamaño de la ventana a partir
        // del tamaño ideal de la vista SwiftUI. Pero estas vistas usan
        // `.frame(maxHeight: .infinity)` para que el contenido se centre — y un
        // máximo infinito hace que el tamaño ideal también lo sea. El resultado
        // es una ventana altísima y angosta con el contenido perdido en el
        // medio.
        //
        // Vaciando las opciones, la vista deja de opinar sobre el tamaño y pasa
        // a llenar el marco que se le da, que es lo correcto: acá el tamaño lo
        // decide la ventana, no el contenido.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        window.contentView = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        return window
    }

    private func activate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === settingsWindow { settingsWindow = nil }
        if closing === onboardingWindow { onboardingWindow = nil }

        // Cuando no queda ninguna ventana, la app vuelve a ser invisible.
        if settingsWindow == nil, onboardingWindow == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
