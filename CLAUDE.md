# Susurro

Dictado por voz local para macOS. App de barra de menús (`LSUIElement`), Swift 6,
sin ventana principal. El audio nunca sale de la máquina.

El README explica qué es y por qué. Este archivo es para trabajar en el código:
solo lo que no se deduce leyéndolo.

## Comandos

```
make build      # compila y firma (Release por defecto; CONFIG=Debug para Debug)
make run        # compila, mata la instancia previa y lanza
make test       # tests unitarios
make install    # copia a /Applications
make project    # regenera Susurro.xcodeproj desde project.yml
make help       # todos los targets
```

**El primer build tarda varios minutos**: hay que bajar FluidAudio y WhisperKit
enteros. Los siguientes son incrementales. No canceles un build creyendo que se
colgó.

## Trampas que cuestan tiempo

**`Susurro.xcodeproj` no está versionado.** Se genera con XcodeGen desde
`project.yml`. Si agregás un archivo `.swift` nuevo y compilás sin regenerar, el
error es `cannot find type 'X' in scope` — que parece un problema de código y no
lo es. `make project` (o `make build`, que lo hace solo).

**Los tests son Swift Testing, no XCTest.** Por eso `make test` parsea la salida a
mano: el canal de XCTest siempre informa «Executed 0 tests» y tomarlo como
veredicto daría verde con todo roto.

**El target de tests usa la app como `TEST_HOST`**, así que correr los tests
lanza la app de verdad. `main.swift` tiene una guarda que detecta XCTest por
variable de entorno y no arranca `AppDelegate`. **No la saques**: sin ella, cada
corrida de tests empieza a descargar modelos en el directorio real de la persona
y compite con la app que esté abierta. Rompió una instalación en curso.

**La firma es a mano y después de compilar.** `xcodebuild` compila sin firmar y el
Makefile firma con `codesign`. Es deliberado: el permiso de Accesibilidad está
atado al *designated requirement*, y una firma ad-hoc cambia en cada build, así
que macOS pediría el permiso de nuevo cada vez. Con identidad estable sobrevive.

**La app no está en el App Sandbox.** `CGEventTap` y la API de Accesibilidad no
funcionan adentro. No se puede activar sin romper la tecla global y el pegado.

## Sin limpieza del texto

Lo que devuelve el reconocimiento se inserta tal cual. Hubo una etapa de limpieza
con un LLM local (Qwen3.5 vía MLX) que puntuaba y sacaba muletillas; se sacó
entera para simplificar. Está en el historial de git si hace falta mirarla.

Parakeet v3 ya devuelve el texto puntuado y con mayúsculas.

```
Susurro --selftest audio.wav       # el pipeline real sobre un archivo
Susurro --permisos                 # qué permisos ve la app
```

## Estructura

```
Susurro/Sources/
├── App/      main, AppDelegate, DictationController (la orquestación), SelfTest
├── ASR/      motores de reconocimiento + catálogo de modelos
├── Audio/    captura de micrófono a 16 kHz mono
├── Input/    tecla global (CGEventTap) e inserción de texto
├── System/   permisos, preferencias, modelos en disco, progreso de descarga
└── UI/       barra de menús, HUD, ajustes, onboarding
```

El flujo entero vive en `DictationController`, en el actor principal y en un solo
hilo. El trabajo pesado está en actores (captura, ASR) pero las
*transiciones de estado* son secuenciales a propósito: repartirlas entre colas
produce dictados fantasma y grabaciones que no cierran.

Los modelos se descargan a `~/Library/Application Support/Susurro/Models/`
(`make models-dir`).

## Convenciones

**Todo en español rioplatense**: código, comentarios, mensajes de interfaz,
commits. La interfaz se traduce al inglés desde el catálogo de cadenas, que se
sincroniza solo en cada build (`make strings`).

**Los comentarios explican por qué, no qué.** El código ya dice qué hace. Un
comentario que valga la pena cuenta la razón de una decisión, el bug que
previene, o por qué la alternativa obvia no funciona. Si documenta un error
pasado, decir cuál fue.

**Ajustes tiene pocas opciones, y es deliberado.** Si hay un valor correcto, va
hardcodeado. Una perilla nueva necesita justificarse.

**No usar `@unchecked Sendable`.** El proyecto compila con
`SWIFT_STRICT_CONCURRENCY: complete`.

## Publicar

```
git tag -a vX.Y.Z -m "…" && git push origin vX.Y.Z
```

CI arma el `.dmg` y el `.zip`, los verifica montándolos, y publica la release.
El workflow tiene dos ramas de firma: con los secretos de Apple cargados firma
con Developer ID y notariza; sin ellos cae a firma ad-hoc y lo dice.

**Hoy salen ad-hoc**, y eso tiene dos consecuencias que se ven como bugs:
Gatekeeper retiene el proceso sin mostrar nada —una app de barra de menú no tiene
por dónde avisar— y el permiso de Accesibilidad se invalida en **cada** versión,
porque una firma ad-hoc identifica por `cdhash` y ese cambia en cada build. La
app detecta lo segundo y ofrece repararlo (`Permissions.repairAccessibility`).

## Lo que se sabe que falta

- **El reconocimiento no está medido.** No hay ni un archivo de audio en el
  repo. Las cifras de los modelos de ASR son las publicadas por quien los
  entrenó, y así están etiquetadas en la interfaz.
- **Parakeet v3 con frases largas que mezclan español e inglés** a veces
  devuelve la frase entera en inglés (reportado por uso, no medido). La pista de
  idioma no lo evita: en FluidAudio solo filtra tokens por alfabeto, y español e
  inglés comparten el latino. Whisper sí fija el idioma (`DecodingOptions.language`).
- **Dictados largos**: la transcripción arranca al soltar la tecla, así que la
  espera crece con el largo. Se arregla transcribiendo por tramos con el VAD; no
  está hecho.
