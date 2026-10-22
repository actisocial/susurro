import AppKit
import SwiftUI

/// Ventana flotante que muestra que Susurro está escuchando.
///
/// Esta clase es la pieza donde un error arruina toda la app, así que vale
/// explicar cada elección.
///
/// **El foco no se puede mover. Nunca.** El texto se va a insertar en la app que
/// la persona tenía adelante, y eso solo funciona si esa app sigue teniendo el
/// foco. Una ventana común lo roba apenas aparece. De ahí:
/// `.nonactivatingPanel`, `canBecomeKey` y `canBecomeMain` devolviendo `false`,
/// `orderFrontRegardless()` en vez de `makeKeyAndOrderFront`, y jamás un
/// `NSApp.activate`. Por la misma razón el HUD es solo informativo y no tiene
/// botones: en cuanto haya algo clicable hay que hacerlo `key`, y ahí se rompe
/// la inserción.
///
/// **Tiene que verse esté donde esté la persona.** `.canJoinAllSpaces` para que
/// aparezca en cualquier escritorio, `.fullScreenAuxiliary` para que se vea
/// sobre apps en pantalla completa, y nivel `.statusBar` para quedar por encima
/// de las ventanas normales. Se posiciona en la pantalla que tiene el mouse, no
/// en la principal: con dos monitores, un HUD que sale siempre en el otro
/// monitor es un HUD que no existe.
///
/// **La onda no es decoración.** Es la única prueba de que el micrófono está
/// capturando de verdad. Sin ella, un micrófono silenciado o el dispositivo
/// equivocado se descubren recién cuando el dictado sale vacío.
@MainActor
final class RecordingHUD {

    private let panel: NSPanel
    private let controller: DictationController

    init(controller: DictationController) {
        self.controller = controller

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 168, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Sin esto, el panel aparece en Mission Control y en el cambiador de apps.
        panel.isExcludedFromWindowsMenu = true

        let view = HUDView(controller: controller)
        panel.contentView = NSHostingView(rootView: view)
    }

    func show() {
        reposition()
        // `orderFrontRegardless` muestra la ventana sin activar la app. Un
        // `makeKeyAndOrderFront` acá le sacaría el foco al campo de texto donde
        // hay que escribir después.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Abajo y al centro de la pantalla donde está el puntero.
    private func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 96
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - Contenido

private struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        HStack(spacing: 12) {
            icon
            content
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .animation(.easeOut(duration: 0.15), value: controller.state)
    }

    @ViewBuilder
    private var icon: some View {
        switch controller.state {
        case .listening(let locked):
            Image(systemName: locked ? "lock.fill" : "mic.fill")
                .foregroundStyle(.red)
                .font(.system(size: 15, weight: .medium))
        default:
            ProgressView()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .listening:
            Waveform(level: controller.inputLevel)
        case .transcribing:
            Text("Transcribiendo…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        case .refining:
            Text("Puliendo…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

/// Barras que reaccionan al nivel del micrófono.
///
/// Cada barra reacciona con un desfase distinto para que el movimiento se vea
/// orgánico en vez de que las diez suban y bajen como un bloque.
private struct Waveform: View {
    let level: Float

    private let barCount = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(.primary.opacity(0.75))
                    .frame(width: 3, height: height(at: index))
            }
        }
        .frame(height: 26)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func height(at index: Int) -> CGFloat {
        // Una campana centrada: las barras del medio son las más altas, como en
        // cualquier medidor de audio.
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        let falloff = 1 - (distance * distance * 0.7)

        let amplitude = Double(min(max(level, 0), 1))
        let minimum = 3.0
        let maximum = 24.0
        return CGFloat(minimum + (maximum - minimum) * amplitude * falloff)
    }
}
