#!/usr/bin/env bash
# Erzeugt ein DMG atomar aus einer bereits signierten und gestapelten App.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Aufruf: create_dmg.sh <App-Bundle> <Ausgabe.dmg>" >&2
    exit 64
fi

app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output_directory="$(cd "$(dirname "$2")" && pwd)"
output="$output_directory/$(basename "$2")"

[ -d "$app" ] || { echo "App-Bundle fehlt: $app" >&2; exit 66; }
case "$output" in
    *.dmg) ;;
    *) echo "Das Ausgabeziel muss auf .dmg enden." >&2; exit 64 ;;
esac
[ ! -e "$output" ] && [ ! -L "$output" ] || {
    echo "Das DMG-Ziel existiert bereits: $output" >&2
    exit 73
}

temporary_directory="$(mktemp -d "$output_directory/.poormans-dmg.XXXXXX")"
cleanup() {
    if [ -d "$temporary_directory" ]; then
        /usr/bin/swift -e \
            'import Foundation; try FileManager.default.removeItem(atPath: CommandLine.arguments[1])' \
            "$temporary_directory"
    fi
}
trap cleanup EXIT

staging_directory="$temporary_directory/staging"
temporary_dmg="$temporary_directory/Poor-Mans-Text.dmg"
mkdir -p "$staging_directory"
ditto "$app" "$staging_directory/Poor Man's Text.app"
ln -s /Applications "$staging_directory/Applications"

hdiutil create \
    -volname "Poor Man's Text" \
    -srcfolder "$staging_directory" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$temporary_dmg" >/dev/null
hdiutil verify "$temporary_dmg" >/dev/null
/usr/bin/swift -e \
    'import Foundation; try FileManager.default.moveItem(atPath: CommandLine.arguments[1], toPath: CommandLine.arguments[2])' \
    "$temporary_dmg" "$output"

echo "DMG OK: $output"
