import AppKit

/// Dos sonidos muy cortos: uno al empezar a escuchar y otro al terminar.
///
/// Parecen un detalle prescindible y no lo son. El HUD puede quedar en otro
/// escritorio, tapado por una app en pantalla completa, o simplemente fuera de
/// donde la persona está mirando —que es su propio cursor de texto—. El sonido
/// es la única confirmación que llega siempre. Sin él, la duda «¿me estará
/// escuchando?» aparece en cada dictado.
///
/// Se usan sonidos del sistema en vez de archivos propios: pesan cero, respetan
/// el volumen de alertas del sistema y ya suenan como macOS.
@MainActor
enum Sounds {

    private static let startSound = NSSound(named: "Tink")
    private static let stopSound = NSSound(named: "Pop")

    static func start() {
        play(startSound)
    }

    static func stop() {
        play(stopSound)
    }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        // Al 25%: tiene que ser una señal, no un evento. A volumen completo,
        // veinte dictados por hora se vuelven insoportables.
        sound.volume = 0.25
        // Rebobinar permite dictados encadenados sin que el segundo sonido se
        // pierda porque el primero todavía estaba sonando.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
