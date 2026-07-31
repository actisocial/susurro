import SwiftUI

/// Puesta en marcha: cinco pasos y afuera.
///
/// Tres reglas que se respetan acá:
///
/// - **Antes de pedir un permiso hay que explicar para qué.** La alerta del
///   sistema aparece después del «Continuar», nunca de sorpresa. Y en una
///   pantalla que antecede a un permiso no va un botón de «Saltear»: o se
///   explica y se pide, o no se pide.
/// - **Los modelos vienen elegidos, no se preguntan.** Pedirle a alguien que
///   todavía no usó la app que elija entre cinco modelos de reconocimiento y
///   cinco de limpieza es descargarle encima una decisión que no tiene con qué
///   tomar. Susurro elige el que ganó la medición y sigue; el que quiera
///   cambiarlo tiene la puerta abierta y señalizada.
/// - **Pero se cuenta qué se eligió y por qué.** Elegir por la persona sin
///   decírselo es lo que hace que después aparezca una descarga de gigas sin
///   explicación, que fue exactamente lo que pasaba: el último paso mencionaba
///   el modelo de reconocimiento en una línea al pie y no decía una palabra del
///   de limpieza, que pesa cinco veces más.
struct OnboardingView: View {
    @Bindable var controller: DictationController
    @Bindable var preferences: Preferences
    let openSettings: () -> Void
    let finish: () -> Void

    @State private var step = 0

    private var stepCount: Int { 5 }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)

            Divider()

            HStack {
                ForEach(0..<stepCount, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
                Spacer()
                primaryButton
            }
            .padding(16)
        }
        .onAppear { controller.permissions.startPolling() }
        .onDisappear { controller.permissions.stopPolling() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: microphone
        case 2: accessibility
        case 3: hotkey
        default: models
        }
    }

    // MARK: - Pasos

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Susurro")
                .font(.title)
            Text("Mantené una tecla, hablá, soltá. El texto aparece donde tengas el cursor.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Todo pasa en tu Mac. El audio no sale de acá: no hay servidor, no hay cuenta y no se guarda nada.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var microphone: some View {
        StepLayout(
            symbol: "mic",
            title: "Susurro necesita el micrófono",
            message: "Es para escuchar lo que dictás. El audio se procesa acá mismo y se descarta apenas se transcribe: no se guarda ni se envía a ningún lado.",
            granted: controller.permissions.microphone.isGranted,
            grantedLabel: "Micrófono habilitado"
        )
    }

    private var accessibility: some View {
        StepLayout(
            symbol: "keyboard",
            title: "Y el permiso de Accesibilidad",
            message: "Hace falta para dos cosas: escuchar la tecla de dictado aunque estés escribiendo en otra app, y pegar el texto donde tenés el cursor. Susurro no lee lo que escribís ni lo que hay en pantalla.",
            granted: controller.permissions.accessibility.isGranted,
            grantedLabel: "Accesibilidad habilitada"
        ) {
            if !controller.permissions.accessibility.isGranted {
                Text("Si ya lo activaste y sigue en rojo, hay que reiniciar Susurro para que macOS lo tome.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Reiniciar Susurro") { Permissions.relaunch() }
                    .controlSize(.small)
            }
        }
    }

    private var hotkey: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.tap")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Elegí tu tecla")
                .font(.title2)

            Picker("", selection: triggerBinding) {
                ForEach(DictationTrigger.allCases.filter { $0 != .custom }, id: \.self) { trigger in
                    Text(trigger.label).tag(trigger)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                Label("Mantenela apretada mientras hablás y soltala.", systemImage: "1.circle")
                Label("Dos toques rápidos dejan el dictado enganchado.", systemImage: "2.circle")
                Label("Esc cancela sin insertar nada.", systemImage: "3.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)

        }
    }

    /// Qué modelos quedaron elegidos, por qué, y cuánto pesa eso.
    ///
    /// El paso existe porque su ausencia se notaba: la app arrancaba y empezaba
    /// a bajar 3 GB sin haberlo mencionado nunca. La descarga era legítima y las
    /// elecciones eran las correctas —son las que ganaron el banco— pero nadie
    /// se había enterado, y una app que consume gigas en silencio se siente rota
    /// aunque esté haciendo lo que corresponde.
    private var models: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Ya elegimos por vos")
                .font(.title2)
            Text("Estos son los que mejor midieron en las pruebas. No hace falta que decidas nada ahora.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ChosenModel(
                    role: String(localized: "Para entender lo que decís"),
                    name: preferences.asrModel.displayName,
                    reason: preferences.asrModel.tagline,
                    size: preferences.asrModel.formattedDownloadSize)

                if preferences.refinementMode != .off {
                    ChosenModel(
                        role: String(localized: "Para puntuar y sacar muletillas"),
                        name: preferences.refinementModel.displayName,
                        reason: preferences.refinementModel.tagline,
                        size: preferences.refinementModel.formattedDownloadSize)
                }
            }
            .padding(.top, 2)

            // La suma va aparte y en grande: es el número que a alguien le
            // importa antes de que su conexión empiece a trabajar.
            Text("Se descargan ahora, una sola vez: \(totalDownload). Podés dictar apenas termine el primero.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Prefiero elegirlos yo") { openSettings() }
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    private var totalDownload: String {
        var bytes = preferences.asrModel.downloadBytes
        if preferences.refinementMode != .off {
            bytes += preferences.refinementModel.downloadBytes
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Navegación

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case 0:
            Button("Empezar") { step = 1 }
                .keyboardShortcut(.defaultAction)

        case 1:
            if controller.permissions.microphone.isGranted {
                Button("Continuar") { step = 2 }.keyboardShortcut(.defaultAction)
            } else {
                Button("Dar acceso al micrófono") {
                    Task {
                        await controller.permissions.requestMicrophone()
                        // Si ya se había denegado antes, la alerta del sistema no
                        // vuelve a aparecer y hay que ir a Ajustes a mano.
                        if controller.permissions.microphone == .denied {
                            Permissions.openSystemSettings(.microphone)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }

        case 2:
            if controller.permissions.accessibility.isGranted {
                Button("Continuar") { step = 3 }.keyboardShortcut(.defaultAction)
            } else {
                Button("Abrir Ajustes del Sistema") {
                    controller.permissions.requestAccessibility()
                    Permissions.openSystemSettings(.accessibility)
                }
                .keyboardShortcut(.defaultAction)
            }

        case 3:
            Button("Continuar") { step = 4 }.keyboardShortcut(.defaultAction)

        default:
            Button("Listo") { finish() }.keyboardShortcut(.defaultAction)
        }
    }

    private var triggerBinding: Binding<DictationTrigger> {
        Binding(
            get: { preferences.trigger },
            set: {
                preferences.trigger = $0
                controller.installHotkeys()
            })
    }
}

/// Un modelo ya elegido, con su rol, su motivo y su peso.
private struct ChosenModel: View {
    let role: String
    let name: String
    let reason: String
    let size: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 14))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(role)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 5) {
                    Text(name).fontWeight(.medium)
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}

// MARK: - Plantilla de paso

private struct StepLayout<Extra: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let granted: Bool
    let grantedLabel: LocalizedStringKey
    @ViewBuilder var extra: () -> Extra

    init(
        symbol: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        granted: Bool,
        grantedLabel: LocalizedStringKey,
        @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.granted = granted
        self.grantedLabel = grantedLabel
        self.extra = extra
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.title2)
                .multilineTextAlignment(.center)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if granted {
                Label(grantedLabel, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }

            extra()
        }
    }
}
