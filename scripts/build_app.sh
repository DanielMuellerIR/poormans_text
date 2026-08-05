#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_directory/.." && pwd)"
build_configuration="${1:-${CONFIGURATION:-release}}"

case "$build_configuration" in
    debug|release) ;;
    *)
        echo "Aufruf: ./build.sh [debug|release]" >&2
        exit 64
        ;;
esac

bundle_root="$project_root/.build/app"
bundle_path="$bundle_root/Poor Man's Text.app"
contents_path="$bundle_path/Contents"
bundled_cli="$contents_path/Resources/poormans-text"
bundled_license="$contents_path/Resources/LICENSE.txt"
bundled_sparkle_license="$contents_path/Resources/Sparkle-LICENSE.txt"
bundled_icon="$contents_path/Resources/AppIcon.icns"
sparkle_framework="$contents_path/Frameworks/Sparkle.framework"
root_app="$project_root/Poor Man's Text.app"
root_cli="$project_root/poormans-text"

remove_exact_path() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        /usr/bin/swift -e \
            'import Foundation; try FileManager.default.removeItem(atPath: CommandLine.arguments[1])' \
            "$path"
    fi
}

cd "$project_root"
build_arguments=(--configuration "$build_configuration")
if [ "$build_configuration" = "release" ]; then
    build_arguments+=(--arch arm64 --arch x86_64)
fi

swift build "${build_arguments[@]}" --product PoorMansTextApp
swift build "${build_arguments[@]}" --product poormans-text
binary_directory="$(swift build "${build_arguments[@]}" --show-bin-path)"
"$script_directory/build_icon.sh"

if [ "$build_configuration" = "release" ]; then
    lipo "$binary_directory/PoorMansTextApp" -verify_arch arm64 x86_64
    lipo "$binary_directory/poormans-text" -verify_arch arm64 x86_64
fi

# Das Bundle ist ein vollständig generiertes Artefakt unter .build. Ein alter
# lokaler Test-Build wird nur innerhalb dieses eindeutig begrenzten Pfads ersetzt.
remove_exact_path "$bundle_path"

mkdir -p "$contents_path/MacOS" "$contents_path/Resources" "$contents_path/Frameworks"
cp "$binary_directory/PoorMansTextApp" "$contents_path/MacOS/PoorMansTextApp"
cp "$binary_directory/poormans-text" "$bundled_cli"
cp "$project_root/LICENSE" "$bundled_license"
cp "$project_root/.build/icon/AppIcon.icns" "$bundled_icon"
cp "$project_root/App/Info.plist" "$contents_path/Info.plist"
chmod 755 "$contents_path/MacOS/PoorMansTextApp" "$bundled_cli"

# SwiftPM linkt Sparkle, kopiert das dynamische Framework aber nicht in ein
# selbst gebautes App-Bundle. `ditto` erhält die für Frameworks nötigen
# Symlinks und Rechte. Ohne diesen Schritt startet die App gar nicht: dyld
# findet Sparkle zur Laufzeit nur unter Contents/Frameworks.
sparkle_source="$(find "$project_root/.build/artifacts/sparkle" \
    -type d -name Sparkle.framework -print -quit 2>/dev/null || true)"
if [ -z "$sparkle_source" ]; then
    echo "Sparkle.framework fehlt nach dem SwiftPM-Build." >&2
    exit 70
fi
ditto "$sparkle_source" "$sparkle_framework"
# Die App ist nicht sandboxed. Sparkles XPC-Dienste sind damit weder aktiviert
# noch nötig und werden bewusst nicht ausgeliefert.
remove_exact_path "$sparkle_framework/Versions/B/XPCServices"
remove_exact_path "$sparkle_framework/XPCServices"

# Die Lizenz der Fremdkomponente gehört in die verteilte App, nicht nur ins
# Quellverzeichnis.
sparkle_license="$(find "$project_root/.build/artifacts/sparkle" \
    -type f -name LICENSE -print -quit 2>/dev/null || true)"
if [ -z "$sparkle_license" ]; then
    echo "Sparkles Lizenzdatei fehlt nach dem SwiftPM-Build." >&2
    exit 70
fi
cp "$sparkle_license" "$bundled_sparkle_license"

# Debug-Symbole entfernen, BEVOR signiert wird (strip macht eine vorhandene
# Signatur ungültig). `swift build -c release` legt eine Debug-Map in jede
# Binärdatei: für jede übersetzte Quelldatei einen Eintrag mit dem vollen Pfad
# ihrer .o-Datei auf DIESEM Mac. Die App braucht das nicht, es verrät nur
# Benutzernamen und Projektaufbau (gefunden am 2026-08-04). `strip -S` nimmt
# genau diese Debug-Symbole und lässt die normale Symboltabelle stehen, damit
# Absturzberichte lesbar bleiben. Xcode tut das bei Release-Builds von sich aus
# (STRIP_STYLE=debugging), SwiftPM nicht.
strip -S "$contents_path/MacOS/PoorMansTextApp" "$bundled_cli"

# Ad-hoc signieren über dasselbe Skript wie der Developer-ID-Weg. Die
# Reihenfolge der verschachtelten Signaturen — eingebettete CLI, Sparkles
# Helfer, dann das Bundle — steht damit nur an einer Stelle und kann zwischen
# lokalem Build und Release nicht auseinanderlaufen.
"$script_directory/sign_bundle.sh" "$bundle_path" -

# Sichtbare, gitignorierte Artefakte im Repo-Root erleichtern lokale Prüfungen.
remove_exact_path "$root_app"
remove_exact_path "$root_cli"
ditto "$bundle_path" "$root_app"
ditto "$binary_directory/poormans-text" "$root_cli"
chmod 755 "$root_cli"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root_app/Contents/Info.plist")"
expected_version="Poor Man's Text $version"
actual_version="$("$root_cli" --version)"
if [ "$actual_version" != "$expected_version" ]; then
    echo "CLI-Version stimmt nicht mit dem App-Bundle überein." >&2
    exit 70
fi

echo "BUILD OK: $root_app ($version, $build_configuration); CLI: $root_cli"
