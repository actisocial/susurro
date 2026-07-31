import AppKit

// Arranque explícito en vez de `@main`. Una app sin ventanas y sin ícono en el
// Dock no necesita nada del ciclo de vida de SwiftUI, y hacerlo a mano deja
// claro exactamente qué pasa al iniciar.

// Modo de autodiagnóstico: corre el pipeline sobre archivos de audio y sale.
// Sin barra de menús, sin permisos, sin interfaz.
if SelfTest.shouldRun() {
    let status = await SelfTest.run()
    exit(status)
}

// Banco de pruebas: mide la calidad de la limpieza sobre un corpus fijo.
if Benchmark.shouldRun() {
    let status = await Benchmark.run()
    exit(status)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
