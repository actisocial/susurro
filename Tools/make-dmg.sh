#!/bin/bash
#
# Empaqueta Susurro.app en un .dmg listo para publicar.
#
# Usa solo `hdiutil`, que viene con macOS, en vez de `create-dmg` u otra
# herramienta de Homebrew. En CI eso ahorra un paso de instalación y, más
# importante, evita que la publicación dependa de que un paquete de terceros
# siga existiendo dentro de dos años.
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

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "→ armando el contenido del disco"
cp -R "$APP" "$STAGING/"

# El enlace a /Applications es lo que permite el gesto de arrastrar-para-instalar
# que todo el mundo espera al abrir un .dmg de macOS.
ln -s /Applications "$STAGING/Applications"

# Una nota corta dentro del disco, porque una app sin firmar de Apple hace que
# macOS la bloquee la primera vez y el mensaje que muestra no explica cómo
# seguir.
cat > "$STAGING/LEEME.txt" <<'EOF'
Susurro — dictado local para macOS

Instalación
  Arrastrá Susurro a la carpeta Aplicaciones.

La primera vez
  Si macOS dice que la app "no se puede abrir porque no se puede verificar
  el desarrollador", es porque esta compilación no está firmada con un
  certificado de pago de Apple. El código es abierto y podés compilarlo vos
  mismo si preferís no confiar en el binario.

  Para abrirla igual:
    Ajustes del Sistema › Privacidad y seguridad › desplazate hasta abajo
    › "Abrir de todos modos"

  O desde la terminal:
    xattr -dr com.apple.quarantine /Applications/Susurro.app

Código y documentación
  https://github.com/actisocial/susurro
EOF

rm -f "$OUTPUT"

echo "→ creando el disco"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$OUTPUT" >/dev/null

SIZE=$(du -h "$OUTPUT" | cut -f1)
echo "✓ $OUTPUT ($SIZE)"
