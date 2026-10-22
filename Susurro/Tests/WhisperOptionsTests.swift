import Testing

@testable import Susurro

struct WhisperOptionsTests {

    /// «Automático» le pasaba `nil` a WhisperKit creyendo que eso detectaba el
    /// idioma. No: forzaba inglés, y un dictado en español salía traducido.
    @Test("en automático detecta el idioma en vez de forzar inglés")
    func automaticDetects() {
        let options = WhisperEngine.options(for: .automatic)
        #expect(options.language == nil)
        #expect(options.detectLanguage)
    }

    @Test("con idioma elegido lo fija y no detecta")
    func pinnedLanguage() {
        let options = WhisperEngine.options(for: .spanish)
        #expect(options.language == "es")
        #expect(!options.detectLanguage)
    }
}
