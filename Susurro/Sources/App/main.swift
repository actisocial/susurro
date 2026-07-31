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

// Bajo XCTest la app es solo el contenedor del bundle de tests, y no tiene que
// arrancar como app.
//
// Esto no es higiene abstracta: hacía daño real. El esquema usa la app como
// `TEST_HOST`, así que cada `xcodebuild test` la lanzaba de verdad, corría
// `AppDelegate` y `prepareEngines()` empezaba a descargar modelos **en el
// directorio real de la persona**. Una segunda instancia peleando por los
// mismos archivos con la app que ya estaba corriendo, y muerta a los pocos
// segundos cuando terminaban los tests: el modelo quedaba con el manifiesto
// abierto y el directorio vacío. Correr los tests rompía la instalación.
//
// Se detecta por la variable de entorno que inyecta XCTest, no por buscar la
// clase `XCTestCase`: la variable existe desde antes de que se cargue el bundle,
// que es justo cuando hace falta decidir.
let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil

let application = NSApplication.shared
let delegate = AppDelegate()
if !isHostingTests {
    application.delegate = delegate
}
application.run()
