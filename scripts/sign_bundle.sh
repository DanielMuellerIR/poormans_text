#!/usr/bin/env bash
# Signiert eingebettete Programme von innen nach außen.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Aufruf: sign_bundle.sh <App-Bundle> <Codesign-Identität>" >&2
    exit 64
fi

app="$1"
identity="$2"
bundled_cli="$app/Contents/Resources/poormans-text"

[ -d "$app" ] || { echo "App-Bundle fehlt: $app" >&2; exit 66; }
[ -x "$bundled_cli" ] || { echo "Eingebettete CLI fehlt: $bundled_cli" >&2; exit 66; }

# Quarantäne-/Finder-Metadaten dürfen die versiegelte Signatur nicht verändern.
xattr -cr "$app"

# Debug-Symbole entfernen, bevor signiert wird. `swift build -c release` legt
# eine Debug-Map in jede Binärdatei: für jede übersetzte Quelldatei einen
# Eintrag mit dem vollen Pfad ihrer .o-Datei auf dem Build-Mac. Das verrät nur
# Benutzernamen und Projektaufbau (gefunden am 2026-08-04). build_app.sh macht
# das schon; hier steht es noch einmal, weil dieses Skript auch auf ein anders
# gebautes Bundle angewendet werden kann. Ein zweiter Lauf ändert nichts mehr.
strip -S "$app/Contents/MacOS/PoorMansTextApp" "$bundled_cli"

sign_arguments=(--force --sign "$identity")
if [ "$identity" != "-" ]; then
    sign_arguments+=(--options runtime --timestamp)
fi

codesign "${sign_arguments[@]}" "$bundled_cli"
codesign "${sign_arguments[@]}" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
