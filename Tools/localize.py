#!/usr/bin/env python3
"""Aplica las traducciones al inglés sobre el catálogo de cadenas.

El orden importa. Primero se compila con `SWIFT_EMIT_LOC_STRINGS`, que hace que
Xcode extraiga del código todas las cadenas localizables y las escriba en
`Localizable.xcstrings` con las claves exactas — incluidos los marcadores de
formato (`%@`, `%lld`) que genera Swift para las interpolaciones. Recién después
corre este script, que rellena el inglés de cada clave que encuentre en
`translations.json`.

Hacerlo al revés —escribir el catálogo a mano— parece más rápido y no funciona:
las claves con interpolación quedan mal y Xcode las ignora en silencio, así que
la app se ve en español aunque el sistema esté en inglés y no hay ningún error
que lo delate.

Uso:  python3 Tools/localize.py [--check]
      --check  no escribe nada; solo informa qué falta traducir (para CI).
"""

import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Susurro" / "Resources" / "Localizable.xcstrings"
TRANSLATIONS = ROOT / "Tools" / "translations.json"
BUILD = ROOT / "build" / "dd" / "Build" / "Intermediates.noindex" / "Susurro.build"


def sync_from_build() -> bool:
    """Vuelca al catálogo las cadenas que el compilador extrajo del código.

    Cada archivo fuente deja un `.stringsdata` con sus cadenas localizables y
    los marcadores de formato ya resueltos (`%@`, `%lld`). `xcstringstool sync`
    —la misma herramienta que usa Xcode— los mezcla en el catálogo.
    """
    data_files = sorted(BUILD.glob("*/Susurro.build/Objects-normal/*/*.stringsdata"))
    if not data_files:
        print("· no hay .stringsdata; compilá primero")
        return False

    command = ["xcrun", "xcstringstool", "sync", str(CATALOG)]
    for path in data_files:
        command += ["--stringsdata", str(path)]

    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"✗ xcstringstool falló: {result.stderr.strip()[:200]}")
        return False
    return True


def main() -> int:
    check_only = "--check" in sys.argv

    if not CATALOG.exists():
        print(f"✗ falta {CATALOG.relative_to(ROOT)}")
        return 1

    if not check_only:
        sync_from_build()

    catalog = json.loads(CATALOG.read_text())
    table = {k: v for k, v in json.loads(TRANSLATIONS.read_text()).items()
             if not k.startswith("_")}

    strings = catalog.setdefault("strings", {})
    applied, missing, unused = 0, [], set(table)

    for key, entry in strings.items():
        # Las claves que no llevan traducción son las que ya están en inglés o
        # son neutras: nombres propios, licencias, identificadores de modelo.
        english = table.get(key)
        if english is None:
            if key.strip() and not _looks_neutral(key):
                missing.append(key)
            continue

        unused.discard(key)
        localizations = entry.setdefault("localizations", {})
        localizations["en"] = {
            "stringUnit": {"state": "translated", "value": english}
        }
        applied += 1

    if not check_only:
        CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")

    print(f"✓ {applied} cadenas traducidas al inglés")
    if missing:
        print(f"\n⚠ {len(missing)} sin traducción (quedan en español):")
        for key in sorted(missing)[:40]:
            print(f"   · {key[:90]}")
    if unused:
        print(f"\n⚠ {len(unused)} traducciones que ya no corresponden a ninguna cadena del código:")
        for key in sorted(unused)[:20]:
            print(f"   · {key[:90]}")

    return 1 if (check_only and missing) else 0


def _looks_neutral(key: str) -> bool:
    """Cadenas que no hace falta traducir: se leen igual en los dos idiomas."""
    neutral = {
        "Apache-2.0", "MIT", "Susurro", "Silero VAD",
        "FluidAudio · Apache-2.0", "KeyboardShortcuts · MIT",
        "MLX Swift · MIT", "WhisperKit (argmax-oss-swift) · MIT",
        "Qwen3 — Alibaba Cloud",
    }
    return key in neutral


if __name__ == "__main__":
    sys.exit(main())
