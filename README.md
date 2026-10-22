# Susurro

[![CI](https://github.com/actisocial/susurro/actions/workflows/ci.yml/badge.svg)](https://github.com/actisocial/susurro/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20Silicon-lightgrey.svg)](#requisitos)

**[actisocial.github.io/susurro](https://actisocial.github.io/susurro/)** — descarga y presentación

Dictado por voz para macOS. Vive en la barra de menús, no tiene ventana
principal y no manda nada a ningún lado.

Mantenés una tecla, hablás, la soltás, y el texto aparece donde tenías el
cursor. Dos toques rápidos dejan el dictado enganchado para las manos libres.
Esc cancela.

Todo el reconocimiento ocurre en tu Mac, con modelos abiertos que la app
descarga la primera vez. La única vez que Susurro
usa la red es para bajar un modelo. Se puede comprobar: bajá el modelo,
desconectá el wifi, seguí dictando.

## Instalar

Bajá el `.dmg` de la [última release](https://github.com/actisocial/susurro/releases/latest),
abrilo y arrastrá Susurro a Aplicaciones.

**Arrastralo de verdad, no lo abras desde el disco montado.** Si ejecutás la app
sin moverla —desde el disco o desde Descargas—, macOS la corre desde una ruta
temporal que cambia en cada arranque, y como los permisos se indexan por ruta,
el micrófono y la accesibilidad que le des dejan de valer la próxima vez que la
abras. No hay ningún aviso cuando pasa; `Susurro --permisos` lo diagnostica.

El `.zip` de la misma release tiene exactamente la misma app, para quien
prefiera automatizar la instalación. Vale la misma advertencia.

Las compilaciones automáticas no están notarizadas por Apple, así que la primera
vez macOS va a decir que no puede verificar al desarrollador. Se abre desde
**Ajustes del Sistema › Privacidad y seguridad › «Abrir de todos modos»**, o
sacándole la marca de cuarentena:

```
xattr -dr com.apple.quarantine /Applications/Susurro.app
```

Si preferís no confiar en un binario ajeno —razonable para una app que escucha
el micrófono— compilala vos: `make install` la firma con tu propia identidad de
desarrollador.

## Compilar

```
make run       # compila, firma y lanza
make install   # la copia a /Applications
make test      # tests unitarios
make help      # todos los targets
```

La primera vez pide micrófono y Accesibilidad, y explica para qué sirve cada
uno antes de pedirlo.

### Probar el pipeline sin hablarle a la computadora

```
Susurro --selftest audio.wav [otro.wav …] [--modelo <id>]
```

Corre exactamente el mismo camino que un dictado real —VAD y motor— sobre
archivos de audio, e imprime cada etapa con su latencia.
Sirve para verificar que todo anda sin depender de permisos, y sobre todo para
medir en *tu* Mac en vez de creerle a un benchmark ajeno. Se puede generar
material de prueba con el propio sistema:

```
say -v "Mónica" -o prueba.aiff "eh entonces este el informe quedó listo viste"
afconvert -f WAVE -d LEF32@16000 -c 1 prueba.aiff prueba.wav
```

Medido así en un M2 Pro con Parakeet v3: la transcripción tarda entre 100 y
500 ms para dictados de 4 a 6 segundos —de 9 a 55 veces más rápido que tiempo
real.

## Qué hay adentro

```
Susurro/Sources/
├── App/          arranque, orquestación del dictado
├── Audio/        captura de micrófono a 16 kHz mono
├── ASR/          motores de reconocimiento + catálogo de modelos
├── Input/        tecla global e inserción del texto
├── System/       permisos, preferencias, modelos en disco
└── UI/           barra de menús, HUD, ajustes, puesta en marcha
```

El flujo es lineal y vive en `DictationController`:

```
tecla abajo → captura de audio → (soltar) → recorte por VAD
            → reconocimiento → inserción en la app de adelante
```

Lo que sale del reconocimiento se inserta tal cual, sin reescribirlo. Si no se
puede pegar, el texto queda en el portapapeles con un aviso que dice por qué.

## Los modelos

Se eligen en Ajustes › Modelos. Se descargan a
`~/Library/Application Support/Susurro/Models/` y se pueden borrar de a uno.

| Modelo | Tamaño | Idiomas | Para qué |
|---|---|---|---|
| Parakeet TDT v3 | 483 MB | 25 europeos | El recomendado |
| Parakeet TDT v3 compacto | 336 MB | 25 europeos | Menos disco |
| Parakeet 110M | 120 MB | inglés | El más rápido |
| Whisper large-v3 turbo | 632 MB | ~100 | Idiomas que Parakeet no cubre |
| Dictado del sistema | 0 MB | 30 | Sin descarga (macOS 26+) |

Parakeet es el default y no Whisper, aunque Whisper sea el nombre conocido: en
español mide alrededor de 3,45 % de WER contra ~4,7 % de Whisper large-v3-turbo,
y corre unas cinco veces más rápido porque va sobre el Neural Engine en vez de
la GPU. Es mejor *y* más rápido en los dos idiomas que le importan a esta app.
Whisper está para los idiomas que Parakeet no cubre.

## Limitación conocida: dictados largos

La transcripción arranca cuando soltás la tecla, así que la espera crece con el
largo del dictado. Para lo que hace la app —frases, mensajes, párrafos de unos
segundos— la espera es de unas décimas y no se nota. En un dictado de tres
minutos son cuatro o cinco segundos de silencio incómodo al final.

La solución conocida es transcribir por tramos mientras la persona sigue
hablando: cortar por silencios con el VAD y mandar cada tramo al modelo apenas
cierra, de forma que al soltar la tecla solo quede pendiente el último. Así la
espera pasa a depender del tramo final y no del total. No está implementado
porque duplica la complejidad de la máquina de estados y la app está pensada
para dictados cortos, pero es el camino si el uso se corre hacia textos largos.

## Decisiones que parecen raras y no lo son

**No usa el App Sandbox.** `CGEventTap` y la API de Accesibilidad no funcionan
adentro del sandbox, y sin ellas no hay tecla global ni inserción de texto. Por
eso se distribuye firmada con Developer ID en vez de por la Mac App Store —donde
además la guía 2.4.5 rechaza explícitamente el pegado automático vía
Accesibilidad, que es lo que hace la app.

**El `Makefile` compila sin firmar y firma después.** Suena raro y es
importante: el permiso de Accesibilidad está atado a la firma de código, y una
firma ad-hoc cambia en cada build, así que macOS pediría el permiso de nuevo
cada vez que recompilás. Firmando con una identidad estable, el *designated
requirement* no cambia y el permiso sobrevive.

**El micrófono se suelta apenas termina el dictado.** El header de
`AVAudioEngine` avisa que el indicador naranja aparece mientras el motor corra,
se esté grabando o no. Un punto naranja permanente en una app que promete que
todo es local se lee exactamente como lo contrario. Hay un ajuste para dejarlo
caliente, apagado por defecto.

**Ajustes tiene pocas opciones.** Es deliberado. Handy tiene 107 campos de
configuración; VoiceInk llegó a 312 archivos Swift. Cada perilla de sus paneles
de depuración es la cicatriz de un bug que se decidió exponer en vez de
arreglar. Acá, si hay un valor correcto, va hardcodeado.

## Requisitos

macOS 14 o superior, Apple Silicon. Xcode 26 y
[XcodeGen](https://github.com/yonaskolb/XcodeGen) para compilar.

## Licencia

Apache 2.0. Ver [LICENSE](LICENSE).

Se eligió por encima de MIT por dos razones concretas: incluye una cesión
explícita de patentes —relevante en un proyecto publicado por una empresa— y su
mecanismo de `NOTICE` es el lugar natural para la atribución que exige la
licencia CC-BY-4.0 de los pesos de Parakeet. Y por encima de GPL porque el
objetivo es que esto se pueda usar, no restringir quién lo usa.

**Susurro no distribuye ningún peso de modelo.** Se descargan de Hugging Face
cuando vos los pedís y quedan solo en tu máquina, así que las licencias de los
modelos aplican a lo que elegís bajar, no a este repositorio ni a sus releases.
El detalle completo está en [NOTICE](NOTICE).

## Créditos

Parakeet TDT v3 es de NVIDIA (CC-BY-4.0). Whisper es de OpenAI (MIT). Silero VAD
(MIT). Las bibliotecas:
[FluidAudio](https://github.com/FluidInference/FluidAudio),
[argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift),
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).
