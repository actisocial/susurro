#!/bin/bash
#
# Empaqueta Susurro.app en un .dmg listo para publicar.
#
# Usa solo `hdiutil`, que viene con macOS, en vez de `create-dmg` u otra
# herramienta de Homebrew. En CI eso ahorra un paso de instalación y, más
# importante, evita que la publicación dependa de que un paquete de terceros
# siga existiendo dentro de dos años.
#
# ¿Por qué un .dmg si ya se publica un .zip? Porque el gesto que propone cada
# formato es distinto, y con esta app uno de los dos deja al usuario roto.
#
# Cuando alguien descomprime un zip en Descargas y hace doble clic sin mover la
# app, macOS no la ejecuta desde ahí: la monta en una ruta aleatoria de solo
# lectura bajo `/private/var/folders/…/AppTranslocation/`. Esa ruta cambia en
# cada arranque, y la base de permisos del sistema indexa por ruta más
# identidad de código. Para Susurro eso significa que el micrófono y la
# accesibilidad que el usuario concedió dejan de valer en el siguiente arranque,
# sin ningún mensaje que lo explique.
#
# El .dmg no apaga la translocación por sí solo —abrir la app desde el disco
# montado también translocada—, pero su ventana pone el ícono y el alias a
# Aplicaciones uno al lado del otro, y ese arrastre es justamente lo que la
# desactiva: una vez movida con el Finder, macOS deja de aplicarla.
#
# Uso:  Tools/make-dmg.sh <ruta/al/Susurro.app> <salida.dmg> [nombre del volumen]

set -euo pipefail

APP="${1:?falta la ruta al .app}"
OUTPUT="${2:?falta la ruta del .dmg de salida}"
VOLUME_NAME="${3:-Susurro}"

if [ ! -d "$APP" ]; then
  echo "✗ no existe $APP" >&2
  exit 1
fi

# Que el bundle exista no quiere decir que sirva. Xcode arma el `.app` y le
# copia los recursos antes de enlazar, así que un build fallido deja un
# directorio con ícono, traducciones y todo lo demás, y sin binario. Empaquetar
# eso produce un .dmg que se monta, se ve bien y no abre. Pasó: la v1.0.0 salió
# así, firmada y notarizada, con 4 MB de recursos y cero ejecutable.
NAME="$(basename "$APP" .app)"
if [ ! -x "$APP/Contents/MacOS/$NAME" ]; then
  echo "✗ $APP no tiene ejecutable en Contents/MacOS/$NAME" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$STAGING"
}
trap cleanup EXIT

echo "→ armando el contenido del disco"

# `ditto` y no `cp -R`, por el mismo motivo que en el zip: es la herramienta que
# preserva enlaces simbólicos, atributos extendidos y el ticket de notarización
# grapado adentro del bundle. Una copia que pierda cualquiera de las tres
# invalida la firma, y eso no se nota hasta que alguien intenta abrir la app.
ditto "$APP" "$STAGING/$NAME.app"

# El enlace a /Applications es lo que permite el gesto de arrastrar-para-instalar
# que todo el mundo espera al abrir un .dmg de macOS.
ln -s /Applications "$STAGING/Applications"

# La nota de adentro se arma según cómo esté firmada la app *de verdad*, y no
# según lo que se supone que debería pasar. Cuando no hay certificado de
# Developer ID el workflow cae a una firma ad-hoc, y decirle al usuario que la
# app está verificada cuando Gatekeeper la va a rechazar es peor que no decir
# nada: lo deja sin saber que el bloqueo es esperable ni cómo seguir.
# La salida se captura antes de examinarla, y no se encadena `codesign | grep -q`.
#
# Ese encadenamiento parecía correcto y es una carrera. `grep -q` sale apenas
# encuentra la coincidencia y cierra el pipe; si `codesign` todavía estaba
# escribiendo, muere con SIGPIPE y termina en 141. Como el script corre con
# `set -o pipefail`, ese 141 pasa a ser el estado del pipeline entero y el `if`
# se va por la rama contraria: se detecta "firma válida" en una app ad-hoc y el
# disco sale con la nota equivocada, que es justo la que le hace falta a quien
# se topa con el bloqueo de Gatekeeper.
#
# Quién gana la carrera depende de cuánto tarde `codesign`. En CI venía ganando
# `codesign` y el resultado era correcto; en esta máquina gana `grep`. O sea que
# el dmg publicado estaba bien por suerte, no por construcción.
SIGNATURE_INFO="$(codesign -dv "$APP" 2>&1 || true)"

# Y la comparación se hace con `[[ ]]`, sin pipe: donde no hay pipe no hay
# SIGPIPE que pueda envenenar el estado.
if [[ "$SIGNATURE_INFO" == *"Signature=adhoc"* ]]; then
  echo "→ firma ad-hoc: se incluye la nota de Gatekeeper"
  cat > "$STAGING/LEEME.txt" <<'EOF'
Susurro — dictado local para macOS

Instalación
  Arrastrá Susurro a la carpeta Aplicaciones.

  Arrastrala de verdad, no la abras desde este disco. Si la ejecutás desde
  acá o desde la carpeta Descargas, macOS la corre desde una ruta temporal
  que cambia en cada arranque, y los permisos de micrófono y accesibilidad
  que le des se pierden al cerrarla.

La primera vez: es probable que no pase NADA
  Al abrirla, lo más probable es que no veas absolutamente nada. Ni una
  ventana, ni un error, ni el ícono en la barra de menús. Parece que la app
  está rota. No lo está.

  Lo que pasa es que esta compilación no está firmada con un certificado de
  pago de Apple, así que macOS retiene el proceso esperando que vos la
  autorices. Y como Susurro vive solo en la barra de menús —sin ventanas y
  sin ícono en el Dock— no tiene por dónde avisarte: el código que dibujaría
  el aviso es justamente el que macOS no está dejando correr.

  Para autorizarla:
    Ajustes del Sistema › Privacidad y seguridad › desplazate hasta abajo
    › "Abrir de todos modos"

  Ese botón aparece recién después de haber intentado abrirla, y caduca
  aproximadamente en una hora. Si no lo ves, hacé doble clic en la app otra
  vez y volvé a mirar.

  O, si preferís la terminal, en un solo paso:
    xattr -dr com.apple.quarantine /Applications/Susurro.app

  Puede quedarte un proceso "Susurro" colgado de los intentos anteriores,
  sin consumir nada. Se cierra con:
    pkill -f Susurro.app

  El código es abierto: si preferís no lidiar con esto, `make install` lo
  compila y lo firma con tu propia identidad de desarrollador, y entonces
  macOS no lo bloquea nunca.

Si los permisos no se recuerdan
  Susurro --permisos    imprime qué ve la app y cómo arreglarlo

Código y documentación
  https://github.com/actisocial/susurro
EOF
else
  cat > "$STAGING/LEEME.txt" <<'EOF'
Susurro — dictado local para macOS

Instalación
  Arrastrá Susurro a la carpeta Aplicaciones.

  Arrastrala de verdad, no la abras desde este disco. Si la ejecutás desde
  acá o desde la carpeta Descargas, macOS la corre desde una ruta temporal
  que cambia en cada arranque, y los permisos de micrófono y accesibilidad
  que le des se pierden al cerrarla.

La primera vez
  Susurro pide micrófono y accesibilidad, y explica para qué sirve cada uno
  antes de pedirlo.

Si los permisos no se recuerdan
  Susurro --permisos    imprime qué ve la app y cómo arreglarlo

Código y documentación
  https://github.com/actisocial/susurro
EOF
fi

rm -f "$OUTPUT"

echo "→ creando el disco"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$OUTPUT" >/dev/null

# Verificar lo que se publica, no lo que se compiló.
#
# Esta comprobación es la que faltaba cuando salió la v1.0.0: el .app se había
# revisado, el .dmg no, y lo que llegó a la gente fue el .dmg. Montarlo y mirar
# adentro cuesta dos segundos y es la única forma de saber que el archivo que
# se sube sirve.
echo "→ verificando el disco"
MOUNT="$(mktemp -d)"
hdiutil attach "$OUTPUT" -mountpoint "$MOUNT" -nobrowse -readonly -quiet

if [ ! -x "$MOUNT/$NAME.app/Contents/MacOS/$NAME" ]; then
  echo "✗ el disco quedó sin ejecutable adentro" >&2
  exit 1
fi
if [ ! -L "$MOUNT/Applications" ]; then
  echo "✗ falta el enlace a /Applications" >&2
  exit 1
fi
codesign --verify --deep --strict "$MOUNT/$NAME.app"

hdiutil detach "$MOUNT" -quiet
MOUNT=""

SIZE=$(du -h "$OUTPUT" | cut -f1)
echo "✓ $OUTPUT ($SIZE) · firma válida montando el disco"
