import KeyboardShortcuts
import SwiftUI

/// Ajustes de Susurro. Tres pestañas y se terminó.
///
/// La restricción real acá no es qué poner sino qué dejar afuera. Las apps de
/// esta categoría acumulan opciones hasta volverse impenetrables, y cada perilla
/// suele ser un bug que se decidió exponer en vez de arreglar. Lo que está acá
/// es lo que depende genuinamente de quien la usa: qué tecla, qué modelo, cuánto
/// intervenir el texto.
struct SettingsView: View {
    @Bindable var controller: DictationController
    @Bindable var preferences: Preferences

    var body: some View {
        TabView {
            GeneralSettings(controller: controller, preferences: preferences)
                .tabItem { Label("General", systemImage: "gearshape") }

            ModelSettings(controller: controller, preferences: preferences)
                .tabItem { Label("Modelos", systemImage: "square.stack.3d.up") }

            AboutSettings()
                .tabItem { Label("Acerca de", systemImage: "info.circle") }
        }
        // Sin tamaño fijo: la ventana ya define el marco y la vista lo llena.
        // Fijar acá el ancho además del de la ventana es pedir que se peleen.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var controller: DictationController
    @Bindable var preferences: Preferences

    /// Copia local del atajo grabado. Ver el comentario en el `Recorder`.
    @State private var recordedShortcut: KeyboardShortcuts.Shortcut?

    var body: some View {
        Form {
            Section {
                Picker("Tecla para dictar", selection: triggerBinding) {
                    ForEach(DictationTrigger.allCases, id: \.self) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }

                if preferences.trigger == .custom {
                    // El `onChange` no es opcional: leer `getShortcut(for:)`
                    // directo en el cuerpo de la vista no funciona, porque no es
                    // un valor observable y SwiftIU no vuelve a evaluar la
                    // condición cuando cambia. El cartel se quedaba diciendo
                    // «falta grabar el atajo» con el atajo ya grabado al lado.
                    KeyboardShortcuts.Recorder("Atajo", name: .dictate) { shortcut in
                        recordedShortcut = shortcut
                    }

                    if recordedShortcut == nil {
                        // Sin esto, elegir «atajo personalizado» y no grabar
                        // nada deja la app muda: no hay tecla que dispare el
                        // dictado y tampoco nada que explique por qué.
                        Label(
                            "Falta grabar el atajo. Hacé clic en el recuadro y apretá la combinación.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    } else if let collision = universalShortcutWarning {
                        Label(collision, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let caveat = preferences.trigger.caveat {
                    Text(caveat)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Cómo dictar")
            } footer: {
                Text("Mantenela apretada mientras hablás y soltala para insertar el texto. Dos toques rápidos dejan el dictado enganchado hasta que la vuelvas a apretar. Esc cancela.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Idioma") {
                Picker("Idioma del dictado", selection: languageBinding) {
                    ForEach(LanguageHint.allCases, id: \.self) { hint in
                        Text(hint.label).tag(hint)
                    }
                }
                Text("Fijar un idioma mejora un poco la precisión. Dejalo en automático si mezclás idiomas al hablar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Detalles") {
                Toggle("Abrir Susurro al iniciar sesión", isOn: launchAtLoginBinding)
                if LaunchAtLogin.state == .requiresApproval {
                    HStack {
                        Text("macOS necesita que lo apruebes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Abrir Ajustes") { LaunchAtLogin.openSystemSettings() }
                            .controlSize(.small)
                    }
                }

                Toggle("Sonidos al empezar y terminar", isOn: soundsBinding)

                Toggle("Devolver el portapapeles a como estaba", isOn: clipboardBinding)
                    .disabled(!TextInjector.clipboardReadIsPermitted)
                if !TextInjector.clipboardReadIsPermitted {
                    Text("macOS tiene bloqueado el acceso de Susurro al portapapeles, así que no se puede restaurar. Se puede cambiar en Ajustes del Sistema › Privacidad y seguridad › Pegado desde otras apps.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Mantener el micrófono listo entre dictados", isOn: warmBinding)
                Text("Hace que los dictados encadenados arranquen al instante, pero deja el punto naranja de micrófono encendido y baja la calidad del audio en auriculares Bluetooth.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Permisos") {
                PermissionRow(
                    title: "Micrófono",
                    state: controller.permissions.microphone,
                    pane: .microphone)

                // Cuál está usando, no solo si tiene permiso.
                //
                // Sin esto, «cambié de micrófono y no lo agarró» era imposible
                // de comprobar desde la app: no decía en ninguna parte de qué
                // entrada estaba grabando, así que un cambio que no se detectaba
                // se veía igual que uno que sí.
                if let device = controller.inputDeviceName {
                    LabeledContent("Entrada en uso") {
                        Text(device).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                PermissionRow(
                    title: "Accesibilidad",
                    state: controller.permissions.accessibility,
                    pane: .accessibility,
                    repair: { Task { await controller.permissions.repairAccessibility() } })
                Text("Accesibilidad hace falta para dos cosas: escuchar la tecla aunque estés en otra app, y pegar el texto donde tenés el cursor. Sin ese permiso Susurro transcribe igual, pero deja el texto en el portapapeles.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            controller.permissions.startPolling()
            controller.refreshInputDevice()
            recordedShortcut = KeyboardShortcuts.getShortcut(for: .dictate)
        }
        .onDisappear { controller.permissions.stopPolling() }
    }

    /// Avisa cuando el atajo elegido pisa una convención universal de macOS.
    ///
    /// Un atajo global se registra para *todo* el sistema, así que elegir ⌘,
    /// —el atajo de Ajustes de literalmente todas las apps— significa que
    /// ninguna vuelve a abrir sus ajustes. Lo mismo con ⌘C, ⌘V o ⌘Q. No se
    /// prohíbe, porque hay casos legítimos y es la máquina de quien la usa,
    /// pero descubrirlo por las consecuencias sería bastante cruel.
    private var universalShortcutWarning: String? {
        guard let shortcut = recordedShortcut,
              let key = shortcut.key,
              shortcut.modifiers == [.command]
        else { return nil }

        let reserved: [KeyboardShortcuts.Key: String] = [
            .comma: "abrir los ajustes",
            .c: "copiar", .v: "pegar", .x: "cortar", .z: "deshacer",
            .a: "seleccionar todo", .s: "guardar", .q: "salir",
            .w: "cerrar la ventana", .n: "nuevo", .o: "abrir",
            .p: "imprimir", .f: "buscar", .t: "nueva pestaña",
        ]

        guard let action = reserved[key] else { return nil }
        return String(localized: "Ojo: ese atajo es el de «\(action)» en todas las apps de macOS. Si lo usás para dictar, deja de funcionar en el resto del sistema.")
    }

    private var triggerBinding: Binding<DictationTrigger> {
        Binding(
            get: { preferences.trigger },
            set: {
                preferences.trigger = $0
                controller.installHotkeys()
            })
    }

    private var languageBinding: Binding<LanguageHint> {
        Binding(get: { preferences.language }, set: { preferences.language = $0 })
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            // Se lee del sistema, no de las preferencias: si alguien lo apagó
            // desde Ajustes del Sistema, el interruptor tiene que reflejarlo.
            get: { LaunchAtLogin.state.isOn },
            set: { LaunchAtLogin.set($0) })
    }

    private var soundsBinding: Binding<Bool> {
        Binding(get: { preferences.playsFeedbackSounds }, set: { preferences.playsFeedbackSounds = $0 })
    }

    private var clipboardBinding: Binding<Bool> {
        Binding(
            get: { preferences.restoresClipboard },
            set: {
                preferences.restoresClipboard = $0
                controller.applyClipboardPreference()
            })
    }

    private var warmBinding: Binding<Bool> {
        Binding(
            get: { preferences.keepsMicrophoneWarm },
            set: {
                preferences.keepsMicrophoneWarm = $0
                controller.applyMicrophonePreference()
            })
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let state: Permissions.State
    let pane: Permissions.Pane
    /// Solo se pasa para Accesibilidad, que es el único que se puede reparar.
    var repair: (() -> Void)?

    @State private var repairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: state.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state.isGranted ? .green : .orange)
                }
                Spacer()

                if state == .stale, let repair {
                    repairButton(repair)
                        .buttonStyle(.borderedProminent)
                } else if !state.isGranted {
                    Button("Abrir Ajustes") { Permissions.openSystemSettings(pane) }
                }
            }

            // El caso confuso se explica, en vez de mostrar el mismo triángulo
            // naranja que cuando el permiso nunca se dio. Son situaciones
            // opuestas: en una falta darlo, en la otra ya está dado y aun así no
            // sirve, y desde Ajustes del Sistema se ven idénticas.
            if state == .stale {
                Text("Susurro aparece encendido en Ajustes del Sistema, pero ese permiso quedó atado a una versión anterior de la app y macOS ya no lo reconoce. Apagar y prender el interruptor no alcanza. «Reparar» borra la entrada vieja y vuelve a pedirlo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // La reparación también se ofrece cuando el permiso figura como
            // denegado a secas.
            //
            // Detectar la entrada vieja requiere haber visto el permiso
            // concedido antes, con este binario; para quien viene de una versión
            // que todavía no anotaba eso, el estado se ve como un `denied`
            // común. O sea que justo la gente que ya está atascada es la que no
            // recibiría el diagnóstico. Ofrecer la salida acá también cubre ese
            // hueco, y no cuesta nada: reparar cuando el permiso simplemente
            // falta es inofensivo — borra una entrada que no existe y lo pide.
            if state == .denied, let repair {
                HStack(spacing: 4) {
                    Text("¿Ya figura encendido en Ajustes y aun así no anda?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    repairButton(repair)
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func repairButton(_ repair: @escaping () -> Void) -> some View {
        Button(repairing ? "Reparando…" : "Reparar") {
            repairing = true
            repair()
            // El estado real lo confirma el sondeo de permisos; esto solo
            // devuelve el botón a su forma normal.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { repairing = false }
        }
        .disabled(repairing)
    }
}

// MARK: - Modelos

private struct ModelSettings: View {
    @Bindable var controller: DictationController
    @Bindable var preferences: Preferences

    @State private var storageUsed: Int64 = 0

    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.available) { model in
                    ModelRow(
                        model: model,
                        isSelected: preferences.asrModel.id == model.id,
                        isInstalled: controller.isInstalled(model),
                        progress: preferences.asrModel.id == model.id ? asrProgress : nil,
                        select: { Task { await controller.switchModel(to: model) } },
                        delete: { controller.deleteModel(model); refreshStorage() }
                    )
                }
            } header: {
                Text("Reconocimiento de voz")
            } footer: {
                Text("Parakeet corre en el Neural Engine: es más rápido que Whisper y más preciso en español, y deja la GPU libre para el refinado. Whisper está para los idiomas que Parakeet no cubre.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Refinado", selection: modeBinding) {
                    ForEach(RefinementMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(preferences.refinementMode.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if preferences.refinementMode != .off {
                    // Antes esto era un menú desplegable con nombre y tamaño, y
                    // el texto explicativo de abajo hablaba solo del que ya
                    // estaba elegido. O sea que para comparar dos modelos había
                    // que elegir uno, leer, elegir el otro, leer —y en el
                    // camino disparar dos descargas de gigas—. Con filas, las
                    // cifras de todos están a la vista sin tocar nada.
                    ForEach(RefinementCatalog.all) { model in
                        RefinementRow(
                            model: model,
                            isSelected: preferences.refinementModel.id == model.id,
                            isRecommended: model.id == RefinementCatalog.default.id,
                            progress: preferences.refinementModel.id == model.id
                                ? controller.refinementProgress : nil,
                            select: { Task { await controller.switchRefinementModel(to: model) } }
                        )
                    }
                }
            } header: {
                Text("Limpieza del texto")
            } footer: {
                Text("Si el modelo tarda más de un segundo y medio, o si devuelve algo que no se parece a lo que dictaste, Susurro descarta el refinado e inserta la transcripción cruda. Nunca vas a recibir una respuesta del modelo en vez de tu texto.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Almacenamiento") {
                LabeledContent("Modelos descargados") {
                    Text(ByteCountFormatter.string(fromByteCount: storageUsed, countStyle: .file))
                        .monospacedDigit()
                }
                Button("Mostrar en el Finder") { controller.revealModelsInFinder() }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshStorage)
    }

    private func refreshStorage() {
        storageUsed = controller.totalModelDiskUsage()
    }

    /// El progreso del modelo de reconocimiento, sacado del estado del dictado.
    private var asrProgress: PreparationProgress? {
        if case .preparing(let progress) = controller.state { return progress }
        return nil
    }

    private var modeBinding: Binding<RefinementMode> {
        Binding(
            get: { preferences.refinementMode },
            set: {
                preferences.refinementMode = $0
                Task { await controller.applyRefinementPreference() }
            })
    }

}

/// Fila de un modelo de limpieza. Misma anatomía que la de reconocimiento, pero
/// con la marca de recomendado, que en este catálogo sí está respaldada por
/// mediciones propias.
private struct RefinementRow: View {
    let model: RefinementModel
    let isSelected: Bool
    let isRecommended: Bool
    let progress: PreparationProgress?
    let select: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.system(size: 15))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName).fontWeight(.medium)
                    if isRecommended {
                        Text("Recomendado")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: .capsule)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(model.tagline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                MetricsStrip(metrics: model.metrics)

                Text("\(model.formattedDownloadSize) · \(model.license)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if let progress {
                    PreparationStrip(progress: progress)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .padding(.vertical, 2)
    }
}

private struct ModelRow: View {
    let model: ASRModel
    let isSelected: Bool
    let isInstalled: Bool
    /// Progreso en vivo, solo para el modelo elegido y solo mientras trabaja.
    let progress: PreparationProgress?
    let select: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.system(size: 15))
                .onTapGesture(perform: select)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName).fontWeight(.medium)
                    if isInstalled, model.requiresDownload {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                            .help("Descargado y listo")
                    }
                }
                Text(model.tagline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let metrics = model.metrics {
                    MetricsStrip(metrics: metrics)
                }

                Text("\(model.languageSummary) · \(model.formattedDownloadSize) · \(model.license)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                // La respuesta a haber hecho clic, en esta ventana.
                //
                // Antes elegir un modelo disparaba una descarga de cientos de
                // megas y *nada* cambiaba acá: el único progreso vivía en la
                // barra de menú, que es otra ventana. Quien no supiera mirar
                // ahí no tenía forma de enterarse de que había pasado algo.
                if let progress {
                    PreparationStrip(progress: progress)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            if isInstalled, model.requiresDownload, !isSelected {
                Button("Borrar", role: .destructive, action: delete)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .padding(.vertical, 2)
    }
}

/// Los números medidos de un modelo, con la procedencia del dato a la vista.
private struct MetricsStrip: View {
    let metrics: ModelMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !metrics.facts.isEmpty {
                HStack(spacing: 5) {
                    ForEach(metrics.facts, id: \.label) { fact in
                        HStack(spacing: 3) {
                            Text(fact.label).foregroundStyle(.secondary)
                            Text(fact.value).fontWeight(.medium).monospacedDigit()
                        }
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 5))
                    }
                }
                .help(metrics.provenance.note)
            }

            if let caveat = metrics.caveat {
                // La advertencia se pinta distinto del resto a propósito: no es
                // un número más, es el motivo por el que alguien debería *no*
                // elegir este modelo aunque las otras cifras lo favorezcan.
                Label(caveat, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if metrics.provenance == .published {
                Text(metrics.provenance.note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Qué está pasando mientras un modelo se prepara.
private struct PreparationStrip: View {
    let progress: PreparationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: min(max(progress.fraction, 0), 1))
                .progressViewStyle(.linear)
                .controlSize(.small)

            HStack(spacing: 4) {
                Text(progress.summary)
                if let detail = progress.detail {
                    Text("·").foregroundStyle(.tertiary)
                    Text(detail).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Acerca de

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                Text("Susurro transcribe lo que dictás usando modelos que corren en tu Mac. El audio no sale del dispositivo: no hay servidor, no hay cuenta y no hay historial. La única vez que Susurro usa la red es para descargar un modelo, y siempre porque vos se lo pediste.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Podés comprobarlo: desconectá el wifi después de bajar el modelo y seguí dictando.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Todo pasa acá")
            }

            Section("Modelos") {
                ForEach(ModelCatalog.all.filter { $0.attribution != nil }) { model in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.attribution ?? "").font(.callout)
                        Text(model.license).font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Qwen3 — Alibaba Cloud").font(.callout)
                    Text("Apache-2.0").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Silero VAD").font(.callout)
                    Text("MIT").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Bibliotecas") {
                Text("FluidAudio · Apache-2.0").font(.callout)
                Text("WhisperKit (argmax-oss-swift) · MIT").font(.callout)
                Text("MLX Swift · MIT").font(.callout)
                Text("KeyboardShortcuts · MIT").font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
