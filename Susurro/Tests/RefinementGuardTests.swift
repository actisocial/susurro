import Foundation
import Observation
import Testing
@testable import Susurro

/// Los casos que este test cubre no son hipotéticos: son los modos de falla
/// documentados de las apps de dictado que ya existen. El de la receta viene de
/// un exploit reproducible reportado en Handy (#1261).
/// Los casos que antes vivían acá —responder, traducir, resumir, obedecer una
/// inyección, devolver vacío— se mudaron a `ProjectionTests`, que los prueba
/// contra la proyección y el guardarraíl nuevos. Lo que queda en este archivo
/// es lo que sigue siendo suyo: la limpieza de la salida cruda del modelo y el
/// limpiador determinista de muletillas.
struct ModelOutputTests {

    @Test("limpia bloques de razonamiento del modelo")
    func stripsThinkBlocks() {
        let raw = "<think>El usuario quiere que corrija esto.</think>Hola, ¿cómo andás?"
        #expect(LocalLLMRefiner.cleanUpOutput(raw) == "Hola, ¿cómo andás?")
    }

    @Test("descarta un bloque de razonamiento sin cerrar")
    func discardsUnterminatedThinking() {
        let raw = "<think>Veamos, el usuario dictó algo sobre"
        #expect(LocalLLMRefiner.cleanUpOutput(raw).isEmpty)
    }

    @Test("saca comillas que envuelven todo el texto")
    func stripsWrappingQuotes() {
        #expect(LocalLLMRefiner.cleanUpOutput("\"Hola, ¿cómo andás?\"") == "Hola, ¿cómo andás?")
    }

    @Test("la semilla del prefill es la primera palabra capitalizada")
    func prefillSeed() {
        // Es lo que fija el idioma antes de muestrear el primer token.
        #expect(LocalLLMRefiner.firstWordCapitalized("entonces el informe quedó listo") == "Entonces")
        #expect(LocalLLMRefiner.firstWordCapitalized("so the deploy is done") == "So")
        #expect(LocalLLMRefiner.firstWordCapitalized("¿cuánto sale?") == "Cuánto")
        #expect(LocalLLMRefiner.firstWordCapitalized("") == "")
    }
}

/// La limpieza determinista tiene que ser exactamente eso: determinista, y
/// conservadora. Cada caso donde borra de más es una palabra que la persona
/// dijo y desapareció, así que los tests que más importan son los negativos.
struct FillerStripperTests {

    @Test("saca interjecciones puras")
    func stripsInterjections() {
        #expect(FillerStripper.strip("Eh el informe quedó listo") == "El informe quedó listo")
        #expect(FillerStripper.strip("Um so the deploy is done") == "So the deploy is done")
    }

    @Test("saca «o sea» sin dejar «sea» suelto")
    func stripsPhrases() {
        #expect(FillerStripper.strip("Se cayó, o sea, hay que restaurar")
            == "Se cayó, hay que restaurar")
    }

    @Test("saca los tics que cierran la oración")
    func stripsTrailingTics() {
        #expect(FillerStripper.strip("Falta que lo revise Juan, viste.")
            == "Falta que lo revise Juan.")
        #expect(FillerStripper.strip("Hay que restaurar el backup, nada.")
            == "Hay que restaurar el backup.")
    }

    @Test("NO toca «este» cuando es demostrativo")
    func keepsDemonstratives() {
        let text = "Este documento hay que mandarlo este lunes."
        #expect(FillerStripper.strip(text) == text)
    }

    @Test("NO toca «sea» cuando es verbo")
    func keepsSubjunctive() {
        let text = "Cualquiera sea el resultado, avisame."
        #expect(FillerStripper.strip(text) == text)
    }

    @Test("NO toca «nada» ni «viste» en medio de la frase")
    func keepsMidSentenceWords() {
        let a = "No quedó nada en la heladera."
        #expect(FillerStripper.strip(a) == a)
        let b = "¿Viste la película que te dije?"
        #expect(FillerStripper.strip(b) == b)
    }

    @Test("NO toca «like» como comparación")
    func keepsLikeAsComparison() {
        let text = "It works like a charm."
        #expect(FillerStripper.strip(text) == text)
    }

    @Test("repara la puntuación que deja el borrado")
    func tidiesPunctuation() {
        #expect(FillerStripper.strip("Eh, entonces, el deploy quedó listo.")
            == "Entonces, el deploy quedó listo.")
    }

    @Test("no rompe con texto vacío ni con solo muletillas")
    func handlesDegenerateInput() {
        #expect(FillerStripper.strip("") == "")
        #expect(FillerStripper.strip("eh um uh").isEmpty)
    }
}

/// Las preferencias fallaron de una forma particularmente engañosa: el valor se
/// guardaba bien en disco, pero como eran propiedades *computadas* sobre
/// `UserDefaults`, el macro `@Observable` no las instrumentaba y SwiftUI nunca
/// recibía la notificación de cambio. Los menús de Ajustes se veían congelados
/// en la opción vieja aunque por debajo ya hubiera cambiado — parecía un bug de
/// interfaz y era de observación.
///
/// Estos tests fijan las dos mitades: que el valor persista, y que la propiedad
/// sea observable de verdad.
struct PreferencesTests {

    /// Cada test usa su propio dominio para no pisar los ajustes reales.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "test.susurro.\(name)")!
        defaults.removePersistentDomain(forName: "test.susurro.\(name)")
        return defaults
    }

    @Test("los valores por defecto son los esperados")
    func defaults() {
        let prefs = Preferences(defaults: makeDefaults("defaults"))
        #expect(prefs.trigger == .rightCommand)
        #expect(prefs.refinementMode == .light)
        #expect(prefs.language == .automatic)
        #expect(prefs.keepsMicrophoneWarm == false)
        #expect(prefs.hasCompletedOnboarding == false)
    }

    @Test("cambiar una preferencia la persiste en disco")
    func persists() {
        let store = makeDefaults("persist")
        let prefs = Preferences(defaults: store)

        prefs.trigger = .fn
        prefs.language = .spanish
        prefs.refinementMode = .off

        // Una instancia nueva sobre el mismo almacén tiene que ver lo guardado.
        let reloaded = Preferences(defaults: store)
        #expect(reloaded.trigger == .fn)
        #expect(reloaded.language == .spanish)
        #expect(reloaded.refinementMode == .off)
    }

    @Test("cambiar una preferencia notifica a los observadores")
    func notifiesObservers() {
        let prefs = Preferences(defaults: makeDefaults("observe"))

        // Caja de referencia porque `onChange` es un cierre `@Sendable` y no
        // puede mutar una variable local capturada.
        final class Box: @unchecked Sendable { var fired = false }
        let box = Box()

        // Esto es exactamente lo que hace SwiftUI y lo que no funcionaba:
        // registrarse para el próximo cambio de `trigger`. Con propiedades
        // computadas sobre UserDefaults, el callback no llegaba nunca.
        withObservationTracking {
            _ = prefs.trigger
        } onChange: {
            box.fired = true
        }

        prefs.trigger = .rightOption

        #expect(box.fired)
        #expect(prefs.trigger == .rightOption)
    }

    @Test("el modelo de reconocimiento persiste por identificador")
    func modelPersists() {
        let store = makeDefaults("model")
        let prefs = Preferences(defaults: store)
        prefs.asrModel = ModelCatalog.parakeetEnglishFast

        let reloaded = Preferences(defaults: store)
        #expect(reloaded.asrModel.id == ModelCatalog.parakeetEnglishFast.id)
    }

    // MARK: - Regresiones que encontró la auditoría

    @Test("no borra palabras con significado al final de la oración")
    func keepsMeaningfulTrailingWords() {
        // Sin coma delante, «nada», «viste» y «right» son el objeto de una
        // negación, el verbo y el predicado. Antes se borraban igual.
        #expect(FillerStripper.strip("En la caja no hay nada.") == "En la caja no hay nada.")
        #expect(FillerStripper.strip("¿Lo viste?") == "¿Lo viste?")
        #expect(FillerStripper.strip("The answer is right.") == "The answer is right.")
        #expect(FillerStripper.strip("Make a left and then a right.")
                == "Make a left and then a right.")
    }

    @Test("con coma delante sí son tics y se van")
    func stripsTrailingTicsAfterComma() {
        #expect(FillerStripper.strip("Quedó listo, viste.") == "Quedó listo.")
        #expect(FillerStripper.strip("Ya está, nada.") == "Ya está.")
    }

    @Test("distingue el atenuador del inglés de su lectura literal")
    func disambiguatesEnglishHedges() {
        // Literales: no se tocan.
        #expect(FillerStripper.strip("do you know if the deploy went out")
                == "Do you know if the deploy went out")
        #expect(FillerStripper.strip("you know the answer") == "You know the answer")
        #expect(FillerStripper.strip("what kind of error is it") == "What kind of error is it")
        #expect(FillerStripper.strip("we need some kind of fallback")
                == "We need some kind of fallback")
        #expect(FillerStripper.strip("i mean what i say") == "I mean what i say")

        // Atenuadores: se van.
        #expect(FillerStripper.strip("we should you know postpone the launch")
                == "We should postpone the launch")
        #expect(FillerStripper.strip("it is kind of slow") == "It is slow")
    }

    @Test("«o sea» se limpia salvo en «ya sea A o sea B»")
    func keepsDisjunctiveSubjunctive() {
        #expect(FillerStripper.strip("o sea, hay que restaurar") == "Hay que restaurar")
        #expect(FillerStripper.strip("ya sea una cosa o sea otra")
                == "Ya sea una cosa o sea otra")
    }
}
