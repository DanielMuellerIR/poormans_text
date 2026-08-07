#!/usr/bin/env bash
# Signiert eingebettete Programme von innen nach außen.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Aufruf: sign_bundle.sh <App-Bundle> <Codesign-Identität> [--strip-debug-symbols]" >&2
    exit 64
fi

app="$1"
identity="$2"
strip_debug_symbols=0
case "${3:-}" in
    "") ;;
    --strip-debug-symbols) strip_debug_symbols=1 ;;
    *) echo "Unbekannte Option: $3" >&2; exit 64 ;;
esac
bundled_cli="$app/Contents/Resources/poormans-text"
sparkle_framework="$app/Contents/Frameworks/Sparkle.framework"

[ -d "$app" ] || { echo "App-Bundle fehlt: $app" >&2; exit 66; }
[ -x "$bundled_cli" ] || { echo "Eingebettete CLI fehlt: $bundled_cli" >&2; exit 66; }
[ -d "$sparkle_framework" ] || { echo "Sparkle.framework fehlt: $sparkle_framework" >&2; exit 66; }

# Quarantäne-/Finder-Metadaten dürfen die versiegelte Signatur nicht verändern.
xattr -cr "$app"

# Debug-Symbole entfernen, bevor signiert wird. `swift build -c release` legt
# eine Debug-Map in jede Binärdatei: für jede übersetzte Quelldatei einen
# Eintrag mit dem vollen Pfad ihrer .o-Datei auf dem Build-Mac. Das verrät nur
# Benutzernamen und Projektaufbau (gefunden am 2026-08-04). build_app.sh macht
# das schon; hier steht es noch einmal, weil dieses Skript auch auf ein anders
# gebautes Bundle angewendet werden kann. Ein zweiter Lauf ändert nichts mehr.
#
# Nur der Release-Weg setzt die Option. Ein Debug-Build braucht genau diese
# Symbole für Quellzeilen im Debugger und lesbare lokale Absturzberichte, und
# ausgeliefert wird er nie.
if [ "$strip_debug_symbols" -eq 1 ]; then
    strip -S "$app/Contents/MacOS/PoorMansTextApp" "$bundled_cli"
fi

sign_arguments=(--force --sign "$identity")
if [ "$identity" != "-" ]; then
    sign_arguments+=(--options runtime --timestamp)
fi

codesign "${sign_arguments[@]}" "$bundled_cli"

# Sparkles Helfer haben eigene, verschachtelte Signaturgrenzen und müssen von
# innen nach außen signiert werden: erst das Hilfsprogramm, dann die Updater-App,
# dann das Framework. `--deep` wäre beim Signieren falsch — es bleibt allein der
# abschließenden Prüfung vorbehalten.
for sparkle_target in \
    "$sparkle_framework/Versions/B/Autoupdate" \
    "$sparkle_framework/Versions/B/Updater.app" \
    "$sparkle_framework"
do
    [ -e "$sparkle_target" ] || {
        echo "Sparkle-Signaturziel fehlt: $sparkle_target" >&2
        exit 66
    }
    codesign "${sign_arguments[@]}" "$sparkle_target"
done

codesign "${sign_arguments[@]}" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
