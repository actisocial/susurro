import Foundation
import Observation

/// Las preferencias de la app.
///
/// La lista es corta y eso es una decisión de producto, no una etapa temprana.
/// Las apps de esta categoría se mueren de exceso de opciones: Handy tiene 107
/// campos de configuración, VoiceInk llegó a 312 archivos Swift y un cliente
/// que pagó escribió «no existe una versión de VoiceInk donde todo simplemente
/// funcione». Cada perilla de sus paneles de depuración —retardo antes de
/// pegar, retardo después de pegar, umbral de corrección de palabras— es la
/// cicatriz de un bug que había que arreglar en vez de exponer.
///
/// La regla acá es: si hay un valor correcto, va hardcodeado. Solo se expone lo
/// que depende genuinamente de la persona (qué tecla, qué idioma, qué modelo) o
/// lo que tiene un compromiso real que no podemos resolver por ella (el punto
/// naranja del micrófono).
///
/// **Sobre cómo se guardan.** Cada preferencia es una propiedad *almacenada* que
/// se persiste en su `didSet`, y no una propiedad computada que lea y escriba
/// `UserDefaults` directamente. La diferencia parece cosmética y no lo es: el
/// macro `@Observable` solo instrumenta propiedades almacenadas. Con las
/// computadas, el valor se guardaba bien en disco pero SwiftUI nunca recibía la
/// notificación de cambio — los menús desplegables de Ajustes se veían
/// congelados en la opción vieja aunque por debajo la preferencia ya había
/// cambiado. Un bug particularmente feo porque no parece un bug de datos sino
/// de la interfaz.
@Observable
final class Preferences: @unchecked Sendable {

    static let shared = Preferences()

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let trigger = "trigger"
        static let asrModelID = "asrModelID"
        static let refinementMode = "refinementMode"
        static let refinementModelID = "refinementModelID"
        static let language = "language"
        static let keepsMicrophoneWarm = "keepsMicrophoneWarm"
        static let restoresClipboard = "restoresClipboard"
        static let playsFeedbackSounds = "playsFeedbackSounds"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    // MARK: - Preferencias

    var trigger: DictationTrigger {
        didSet { defaults.set(trigger.rawValue, forKey: Key.trigger) }
    }

    var asrModel: ASRModel {
        didSet { defaults.set(asrModel.id, forKey: Key.asrModelID) }
    }

    var refinementMode: RefinementMode {
        didSet { defaults.set(refinementMode.rawValue, forKey: Key.refinementMode) }
    }

    var refinementModel: RefinementModel {
        didSet { defaults.set(refinementModel.id, forKey: Key.refinementModelID) }
    }

    var language: LanguageHint {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

    /// Mantener el micrófono tomado entre dictados. Apagado por defecto: el
    /// indicador naranja quedaría prendido y en Bluetooth degrada el audio.
    var keepsMicrophoneWarm: Bool {
        didSet { defaults.set(keepsMicrophoneWarm, forKey: Key.keepsMicrophoneWarm) }
    }

    /// Devolver el portapapeles a como estaba después de pegar.
    var restoresClipboard: Bool {
        didSet { defaults.set(restoresClipboard, forKey: Key.restoresClipboard) }
    }

    /// Dos sonidos muy cortos al empezar y terminar. Es la única confirmación
    /// que existe cuando el HUD queda en otro escritorio o hay pantalla completa.
    var playsFeedbackSounds: Bool {
        didSet { defaults.set(playsFeedbackSounds, forKey: Key.playsFeedbackSounds) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    // MARK: - Carga

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaults.register(defaults: [
            Key.trigger: DictationTrigger.rightCommand.rawValue,
            Key.asrModelID: ModelCatalog.firstRunSuggestion.id,
            Key.refinementMode: RefinementMode.light.rawValue,
            Key.refinementModelID: RefinementCatalog.default.id,
            Key.language: LanguageHint.automatic.rawValue,
            Key.keepsMicrophoneWarm: false,
            Key.restoresClipboard: true,
            Key.playsFeedbackSounds: true,
            Key.hasCompletedOnboarding: false,
        ])

        // Los valores se leen una sola vez, acá. A partir de este punto la
        // fuente de verdad son las propiedades y `UserDefaults` es solo su
        // reflejo en disco.
        trigger = DictationTrigger(rawValue: defaults.string(forKey: Key.trigger) ?? "")
            ?? .rightCommand
        asrModel = ModelCatalog.model(id: defaults.string(forKey: Key.asrModelID) ?? "")
            ?? ModelCatalog.firstRunSuggestion
        refinementMode = RefinementMode(rawValue: defaults.string(forKey: Key.refinementMode) ?? "")
            ?? .light
        refinementModel = RefinementCatalog.model(
            id: defaults.string(forKey: Key.refinementModelID) ?? "") ?? RefinementCatalog.default
        language = LanguageHint(rawValue: defaults.string(forKey: Key.language) ?? "")
            ?? .automatic
        keepsMicrophoneWarm = defaults.bool(forKey: Key.keepsMicrophoneWarm)
        restoresClipboard = defaults.bool(forKey: Key.restoresClipboard)
        playsFeedbackSounds = defaults.bool(forKey: Key.playsFeedbackSounds)
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }
}
