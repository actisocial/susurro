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

**El primer build tarda unos 20 minutos.** MLX compila sus shaders de Metal y hay
que bajar FluidAudio, WhisperKit y MLX enteros. Los siguientes son incrementales.
No canceles un build creyendo que se colgó.

Necesita el toolchain de Metal, que no viene con Xcode:
`xcodebuild -downloadComponent MetalToolchain`.

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

## La invariante que no se negocia

El LLM de limpieza **solo puede borrar y puntuar. Nunca agregar palabras.**

No es una recomendación del prompt: está garantizado estructuralmente. La salida
del modelo se trata como un *voto*, y el texto final se reconstruye alineándolo
contra lo que la persona dictó (`TextProjection`, alineación por programación
dinámica). Una palabra que no estaba en la entrada no puede llegar al texto.

Encima hay un guardarraíl (`RefinementGuard`) que rechaza el refinado entero si se
borró demasiado, si se perdió una negación, o si el modelo se desvió más de la
cuenta. Cuando rechaza, se inserta la transcripción cruda.

La división es a propósito: se proyecta para que la garantía sea estructural, y se
rechaza para que la falla sea *ruidosa*. Si la proyección reparara en silencio
todo lo que el modelo hace mal, nadie se enteraría de que el modelo está mal.

**Cualquier cambio en `Refine/` que afloje esto necesita medirse**, no razonarse.
Ver la sección del banco.

## El banco de calidad

```
Susurro --bench                    # los 46 casos, con el modelo por defecto
Susurro --bench --modelo-refinado <id>
Susurro --selftest audio.wav       # el pipeline real sobre un archivo
Susurro --permisos                 # qué permisos ve la app
```

El corpus está en `Susurro/Resources/benchmark.json`: 46 casos con `id`, `lang`,
`raw` (lo dictado) y `expected` (lo que debería salir). Repartidos en `es` 17,
`en` 6, `mix` 8 y `heavy` 15 — «heavy» son dictados largos con los dos idiomas
entreverados, que es donde todo se rompe primero.

Mide F1 de puntuación y F1 de borrado. **Precisión de borrado por debajo de 95 %
es una regresión seria**: significa que está borrando palabras que hacen falta.

Referencia actual con Qwen3.5 2B 8-bit: puntuación 82 %, borrado 85 % (precisión
98 %), p50 928 ms, cero rechazos, cero timeouts.

**Los tests verdes no alcanzan para `Refine/`.** Pasó: un cambio en las muletillas
inglesas dejó los 54 tests en verde y hundió el F1 de borrado en inglés de 90 % a
58 %. Lo agarró el banco, no la suite. Si tocás limpieza, corré el banco.

## Estructura

```
Susurro/Sources/
├── App/      main, AppDelegate, DictationController (la orquestación), Benchmark, SelfTest
├── ASR/      motores de reconocimiento + catálogo de modelos
├── Audio/    captura de micrófono a 16 kHz mono
├── Input/    tecla global (CGEventTap) e inserción de texto
├── Refine/   limpieza con LLM, proyección y guardarraíles
├── System/   permisos, preferencias, modelos en disco, progreso de descarga
└── UI/       barra de menús, HUD, ajustes, onboarding
```

El flujo entero vive en `DictationController`, en el actor principal y en un solo
hilo. El trabajo pesado está en actores (captura, ASR, LLM) pero las
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

- **La mitad de arriba del sistema no está medida.** El banco arranca de
  transcripciones correctas escritas a mano: mide la limpieza, nunca el
  reconocimiento. No hay ni un archivo de audio en el repo. Las cifras de los
  modelos de ASR son las publicadas por quien los entrenó, y así están
  etiquetadas en la interfaz.
- **La tokenización no es idempotente**: «cobramos $100» sale «cobramos$ 100» y
  los emoji desaparecen. Ocurre *antes* de la alineación, así que el guardarraíl
  es ciego por construcción.
- **Dictar un mail o una ruta fonéticamente** («punto», «arroba») se rechaza por
  borrado excesivo o se corrompe.
- **Dictados largos**: la transcripción arranca al soltar la tecla, así que la
  espera crece con el largo. Se arregla transcribiendo por tramos con el VAD; no
  está hecho.
