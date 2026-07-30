import AppKit
import Carbon.HIToolbox
import Foundation
import KeyboardShortcuts
import OSLog

/// Gatillo elegido por la persona para disparar el dictado.
///
/// Las opciones por defecto son modificadores "sueltos" del lado derecho del
/// teclado: apretados solos no escriben nada ni activan menús, así que se
/// pueden mantener presionados sin efectos colaterales en ninguna app. Ese es
/// justamente el requisito de un push-to-talk.
enum DictationTrigger: String, CaseIterable, Codable, Sendable {
    case rightOption
    case rightCommand
    case rightControl
    case fn
    case custom

    var label: String {
        switch self {
        case .rightOption:  return String(localized: "Opción derecha (⌥)")
        case .rightCommand: return String(localized: "Comando derecho (⌘)")
        case .rightControl: return String(localized: "Control derecho (⌃)")
        case .fn:           return String(localized: "Globo / Fn (🌐)")
        case .custom:       return String(localized: "Atajo personalizado")
        }
    }

    /// Advertencia que la UI muestra debajo de la opción, cuando hace falta.
    var caveat: String? {
        switch self {
        case .fn:
            return String(localized: "El sistema usa 🌐 para cambiar el idioma o mostrar emoji. Poné «No hacer nada» en Ajustes › Teclado para que quede libre.")
        case .rightOption:
            return String(localized: "Ojo: en el teclado estadounidense, Opción es la tecla de acentos (⌥+e da «é»). Susurro se hace a un lado al detectar la segunda tecla, pero si escribís mucho en español conviene otra.")
        default:
            return nil
        }
    }

    /// Códigos de tecla que corresponden a este modificador.
    /// Vienen de `Carbon.HIToolbox` y distinguen izquierda de derecha, cosa que
    /// `NSEvent.modifierFlags` por sí solo no hace.
    var keyCodes: Set<UInt16> {
        switch self {
        case .rightOption:  return [UInt16(kVK_RightOption)]
        case .rightCommand: return [UInt16(kVK_RightCommand)]
        case .rightControl: return [UInt16(kVK_RightControl)]
        case .fn:           return [UInt16(kVK_Function)]
        case .custom:       return []
        }
    }

    var modifierFlag: NSEvent.ModifierFlags? {
        switch self {
        case .rightOption:  return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn:           return .function
        case .custom:       return nil
        }
    }
}

extension KeyboardShortcuts.Name {
    /// `KeyboardShortcuts.Name` no es `Sendable`, pero esta constante solo se
    /// toca desde el actor principal —que es donde vive todo el manejo de
    /// teclado—, así que la promesa se cumple.
    @MainActor static let dictate = Self("dictate")
}

/// Traduce eventos crudos de teclado en intenciones de dictado.
///
/// El gesto tiene dos modos y hay una sutileza en cómo conviven:
///
/// - **Mantener**: apretás, hablás, soltás. Se transcribe al soltar.
/// - **Doble toque**: dos toques cortos seguidos dejan el dictado enganchado
///   (manos libres) hasta que lo vuelvas a apretar.
///
/// La sutileza es que en el instante del primer toque todavía no se sabe cuál
/// de los dos gestos está ocurriendo. La solución es empezar a grabar siempre
/// al apretar, y decidir recién al soltar: si el toque fue muy corto, en vez de
/// cerrar de una se espera `doubleTapWindow` por un segundo toque. Si llega, se
/// engancha y la grabación —que nunca se cortó— sigue de largo; si no llega, se
/// cierra el dictado corto. Nunca se pierde audio por estar deliberando.
@MainActor
final class HotkeyMonitor {

    enum Event: Sendable {
        /// Empezar a grabar (todavía sin saber si es mantener o doble toque).
        case begin
        /// Cerrar y transcribir.
        case commit
        /// Descartar sin transcribir.
        case cancel
        /// Pasó a modo manos libres: la UI debería mostrar el candado.
        case lock
    }

    /// Debajo de esto, soltar la tecla se interpreta como "toque", no como
    /// el final de un mantener.
    private let tapThreshold: TimeInterval = 0.28

    /// Ventana para que llegue el segundo toque.
    private let doubleTapWindow: TimeInterval = 0.35

    /// Durante este lapso desde el inicio, otra tecla cancela el dictado por
    /// considerarse un atajo y no un dictado. Pasado eso, ya está claro que la
    /// persona está hablando.
    private let accidentalKeyWindow: TimeInterval = 1.0

    private var dictationStartedAt: Date?

    private enum State {
        case idle
        /// Tecla abajo; todavía no sabemos si es mantener o el primer toque.
        case holding(since: Date)
        /// Se soltó rápido; esperando un posible segundo toque.
        case awaitingSecondTap
        /// Modo manos libres.
        case locked
    }

    private var state: State = .idle
    private var pendingTapTask: Task<Void, Never>?

    private var flagsMonitors: [Any] = []
    private var escapeMonitors: [Any] = []

    private var trigger: DictationTrigger = .rightCommand
    private var isModifierDown = false

    private let handler: @MainActor (Event) -> Void
    private let logger = Logger(subsystem: "com.acti.susurro", category: "Hotkey")

    init(handler: @escaping @MainActor (Event) -> Void) {
        self.handler = handler
    }

    // Sin `deinit`: los monitores se dan de baja en `stop()`, que llama
    // explícitamente quien orquesta al cerrar la app. Un `deinit` no puede tocar
    // estado aislado al actor principal bajo concurrencia estricta, y de todos
    // modos este objeto vive lo que vive la app: liberarlo en el `deinit` sería
    // código que nunca corre.

    // MARK: - Alta y baja

    /// Empieza a escuchar el gatillo indicado. Es idempotente: llamarlo de
    /// nuevo con otro gatillo reconfigura sin duplicar monitores.
    func start(trigger: DictationTrigger) {
        stop()
        self.trigger = trigger

        switch trigger {
        case .custom:
            // Los atajos con tecla normal van por Carbon (`RegisterEventHotKey`)
            // a través de KeyboardShortcuts: se consumen antes de llegar a la
            // app de adelante y —a diferencia de los monitores globales— no
            // requieren ningún permiso del sistema.
            KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
                self?.handlePress()
            }
            KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
                self?.handleRelease()
            }

        default:
            // Un modificador solo no se puede capturar con RegisterEventHotKey,
            // así que hay que mirar `.flagsChanged`. No hace falta consumir el
            // evento: apretar ⌥/⌘/⌃ del lado derecho sin ninguna otra tecla no
            // hace nada en el resto del sistema, así que dejarlo pasar es lo
            // correcto y además evita romper atajos ajenos.
            let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
            }
            let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
                return event
            }
            flagsMonitors = [global, local].compactMap { $0 }
        }

        logger.debug("gatillo activo: \(trigger.rawValue, privacy: .public)")
    }

    func stop() {
        for monitor in flagsMonitors { NSEvent.removeMonitor(monitor) }
        flagsMonitors.removeAll()
        KeyboardShortcuts.removeAllHandlers()
        stopWatchingEscape()
        pendingTapTask?.cancel()
        pendingTapTask = nil
        state = .idle
        isModifierDown = false
    }

    // MARK: - Interpretación de eventos

    private func handleFlagsChanged(_ event: NSEvent) {
        guard trigger.keyCodes.contains(event.keyCode) else { return }

        // En `.flagsChanged` no hay "abajo/arriba": hay que deducirlo mirando si
        // la bandera del modificador quedó puesta después del evento.
        let isDown = trigger.modifierFlag.map { event.modifierFlags.contains($0) } ?? false

        guard isDown != isModifierDown else { return }
        isModifierDown = isDown

        if isDown {
            handlePress()
        } else {
            handleRelease()
        }
    }

    private func handlePress() {
        pendingTapTask?.cancel()
        pendingTapTask = nil

        switch state {
        case .locked:
            // Estando enganchado, apretar de nuevo cierra el dictado.
            state = .idle
            stopWatchingEscape()
            handler(.commit)

        case .awaitingSecondTap:
            // Llegó el segundo toque: engancha. La grabación del primer toque
            // nunca se cortó, así que simplemente sigue.
            state = .locked
            handler(.lock)

        case .idle:
            state = .holding(since: Date())
            startWatchingEscape()
            handler(.begin)

        case .holding:
            break  // repetición de tecla; ignorar
        }
    }

    private func handleRelease() {
        switch state {
        case .holding(let since):
            if Date().timeIntervalSince(since) < tapThreshold {
                // Toque corto: puede ser el primero de un doble toque. Seguimos
                // grabando mientras esperamos.
                state = .awaitingSecondTap
                pendingTapTask = Task { [doubleTapWindow] in
                    try? await Task.sleep(for: .seconds(doubleTapWindow))
                    guard !Task.isCancelled else { return }
                    self.resolveLoneTap()
                }
            } else {
                state = .idle
                stopWatchingEscape()
                handler(.commit)
            }

        case .locked, .awaitingSecondTap, .idle:
            break  // en manos libres, soltar no hace nada
        }
    }

    /// El segundo toque nunca llegó: fue un toque suelto y aislado.
    private func resolveLoneTap() {
        guard case .awaitingSecondTap = state else { return }
        state = .idle
        stopWatchingEscape()
        // Fue un roce de menos de 300 ms: casi con seguridad accidental, y no
        // hay nada dictado ahí. Se descarta en silencio en vez de insertar
        // basura en el documento de la persona.
        handler(.cancel)
    }

    // MARK: - Teclas durante el dictado

    /// Vigila el teclado mientras se dicta. Dos cosas distintas:
    ///
    /// **Esc cancela.** Obvio y esperado.
    ///
    /// **Cualquier otra tecla también cancela, y esto no es obvio.** Un
    /// modificador apretado solo no hace nada, pero apretado *con otra tecla*
    /// es un atajo, y la persona no está dictando: está usando su teclado. El
    /// caso que más importa en español: en la distribución de teclado
    /// estadounidense, Opción es la tecla de acentos —⌥+e da «é», ⌥+n da «ñ»—
    /// así que sin esta regla, escribir «año» abriría un dictado. Como los
    /// eventos del modificador nunca se consumen, el acento se sigue
    /// escribiendo normalmente; lo único que pasa es que Susurro se hace a un
    /// lado.
    ///
    /// La ventana es de un segundo: si alguien lleva más de eso hablando, una
    /// tecla suelta es un tipeo accidental y no vale la pena tirar el dictado.
    private func startWatchingEscape() {
        guard escapeMonitors.isEmpty else { return }
        dictationStartedAt = Date()

        let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                _ = self?.handleKeyDownDuringDictation(event)
            }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let consumed: Bool = MainActor.assumeIsolated {
                self?.handleKeyDownDuringDictation(event) ?? false
            }
            // Esc se consume para que no llegue a la app de adelante y le cierre
            // un diálogo sin querer. Las demás teclas se dejan pasar: la persona
            // está escribiendo.
            return consumed ? nil : event
        }
        escapeMonitors = [global, local].compactMap { $0 }
    }

    /// Devuelve `true` si el evento se consumió (solo pasa con Esc).
    @discardableResult
    private func handleKeyDownDuringDictation(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) {
            abort()
            return true
        }

        // Repetición de tecla mantenida: no es una tecla nueva.
        guard !event.isARepeat else { return false }

        let elapsed = dictationStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard elapsed < accidentalKeyWindow else { return false }

        abort()
        return false
    }

    private func stopWatchingEscape() {
        for monitor in escapeMonitors { NSEvent.removeMonitor(monitor) }
        escapeMonitors.removeAll()
        dictationStartedAt = nil
    }

    private func abort() {
        pendingTapTask?.cancel()
        pendingTapTask = nil
        state = .idle
        stopWatchingEscape()
        handler(.cancel)
    }
}
