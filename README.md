# Susurro

[![CI](https://github.com/actisocial/susurro/actions/workflows/ci.yml/badge.svg)](https://github.com/actisocial/susurro/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20Silicon-lightgrey.svg)](#requisitos)

Dictado por voz para macOS. Vive en la barra de menús, no tiene ventana
principal y no manda nada a ningún lado.

Mantenés una tecla, hablás, la soltás, y el texto aparece donde tenías el
cursor. Dos toques rápidos dejan el dictado enganchado para las manos libres.
Esc cancela.

Todo el reconocimiento y toda la limpieza del texto ocurren en tu Mac, con
modelos abiertos que la app descarga la primera vez. La única vez que Susurro
usa la red es para bajar un modelo. Se puede comprobar: bajá el modelo,
desconectá el wifi, seguí dictando.

## Instalar

Bajá el `.zip` de la [última release](https://github.com/actisocial/susurro/releases/latest),
descomprimilo y arrastrá Susurro a Aplicaciones.

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

Requiere el toolchain de Metal de Xcode, que no viene instalado por defecto y
que MLX necesita para compilar sus shaders:

```
xcodebuild -downloadComponent MetalToolchain
```

### Probar el pipeline sin hablarle a la computadora

```
Susurro --selftest audio.wav [otro.wav …] [--modelo <id>] [--sin-refinado]
```

Corre exactamente el mismo camino que un dictado real —VAD, motor, limpieza,
guardarraíles— sobre archivos de audio, e imprime cada etapa con su latencia.
Sirve para verificar que todo anda sin depender de permisos, y sobre todo para
medir en *tu* Mac en vez de creerle a un benchmark ajeno. Se puede generar
material de prueba con el propio sistema:

```
say -v "Mónica" -o prueba.aiff "eh entonces este el informe quedó listo viste"
afconvert -f WAVE -d LEF32@16000 -c 1 prueba.aiff prueba.wav
```

Medido así en un M2 Pro con Parakeet v3: la transcripción tarda entre 100 y
500 ms para dictados de 4 a 6 segundos —de 9 a 55 veces más rápido que tiempo
real— y la limpieza con Qwen3.5 2B agrega alrededor de 900 ms.

## Qué hay adentro

```
Susurro/Sources/
├── App/          arranque, orquestación del dictado
├── Audio/        captura de micrófono a 16 kHz mono
├── ASR/          motores de reconocimiento + catálogo de modelos
├── Refine/       limpieza del texto con un LLM local
├── Input/        tecla global e inserción del texto
├── System/       permisos, preferencias, modelos en disco
└── UI/           barra de menús, HUD, ajustes, puesta en marcha
```

El flujo es lineal y vive en `DictationController`:

```
tecla abajo → captura de audio → (soltar) → recorte por VAD
            → reconocimiento → limpieza con LLM → inserción en la app de adelante
```

Cada etapa puede fallar sin llevarse puesta a la siguiente: si el LLM tarda o
devuelve cualquier cosa, se inserta la transcripción cruda; si no se puede
pegar, el texto queda en el portapapeles con un aviso que dice por qué.

## Los modelos

Se eligen en Ajustes › Modelos. Se descargan a
`~/Library/Application Support/Susurro/Models/` y se pueden borrar de a uno.

**Reconocimiento**

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

**Limpieza del texto**

| Modelo | Tamaño | Latencia típica |
|---|---|---|
| Qwen3.5 2B | 1,7 GB | 0,7–1,2 s |
| Qwen3.5 0.8B | 652 MB | 0,3–0,6 s |

Se probaron modelos más chicos y el problema no es la velocidad sino la
fidelidad: por debajo de ~2B, con entrada en español, unos traducen al inglés,
otros resumen, otros contestan lo que se les dictó, y alguno directamente emite
caracteres cirílicos. Se pueden ver los resultados en los comentarios de
`RefinementModels.swift`.

## Sobre la limpieza con LLM

Es la parte que está rota en todas las apps de dictado que existen, así que vale
explicarla.

Un transcripto es texto que una persona dijo en voz alta. Si alguien dicta «che,
pasame la receta de la lasaña», un modelo chico puede *contestar* con la receta,
y eso termina pegado en el mail que estaba escribiendo. Hay un exploit
reproducible exactamente así en Handy (#1261), lo mismo reportado en VoiceInk
(#838), y el mantenedor de Whispering describe el mismo problema.

La defensa no puede ser solo un buen prompt, porque el prompt es justamente lo
que el ataque dobla. Susurro valida la salida desde afuera del modelo
(`RefinementGuard`): si el texto creció demasiado, si arranca como una respuesta
de asistente, o si desapareció más del 20 % de las palabras que se dictaron, se
descarta y se inserta la transcripción cruda. Peor puntuación es un problema
infinitamente menor que texto ajeno apareciendo en un documento.

Los tests de `RefinementGuardTests` cubren los seis modos de falla reales:
responder, traducir, resumir, obedecer una inyección, escribir un poema y
devolver vacío.

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

Parakeet TDT v3 es de NVIDIA (CC-BY-4.0). Whisper es de OpenAI (MIT). Qwen3.5 es
de Alibaba Cloud (Apache-2.0). Silero VAD (MIT). Las bibliotecas:
[FluidAudio](https://github.com/FluidInference/FluidAudio),
[argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift),
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm),
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).
