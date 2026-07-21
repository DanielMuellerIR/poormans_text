#!/usr/bin/env bash
# Prüft das gepackte Produkt unabhängig vom SwiftPM-Buildverzeichnis.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Aufruf: verify_bundle.sh <App-Bundle> [--notarized]" >&2
    exit 64
fi

app="$1"
notarized=0
if [ "${2:-}" = "--notarized" ]; then
    notarized=1
elif [ -n "${2:-}" ]; then
    echo "Unbekannte Option: $2" >&2
    exit 64
fi

info_plist="$app/Contents/Info.plist"
bundled_cli="$app/Contents/Resources/poormans-text"
[ -f "$info_plist" ] || { echo "Info.plist fehlt im Bundle." >&2; exit 66; }
[ -x "$bundled_cli" ] || { echo "Ausführbare CLI fehlt im Bundle." >&2; exit 66; }

codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$bundled_cli"

signature_details="$(codesign -d --verbose=4 "$app" 2>&1)"
if ! printf '%s\n' "$signature_details" | grep -q 'flags=.*runtime'; then
    echo "Hardened Runtime fehlt in der App-Signatur." >&2
    exit 65
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
if [ "$("$bundled_cli" --version)" != "Poor Man's Text $version" ]; then
    echo "App- und CLI-Version stimmen nicht überein." >&2
    exit 65
fi

if [ "$notarized" -eq 1 ]; then
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
fi

echo "VERIFY OK: $app ($version)"
