#!/usr/bin/env bash
# Prüft den vollständigen, bereits installierten Release gegen Commit und Tag.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Aufruf: verify_release.sh <Version>" >&2
    exit 64
fi

version="$1"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version muss als MAJOR.MINOR.PATCH angegeben werden." >&2
    exit 64
fi

script_directory="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_directory/.." && pwd)"
cd "$project_root"

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    echo "Der Git-Arbeitsbaum ist nicht sauber." >&2
    exit 65
fi

expected_tag="v$version"
actual_tag="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
[ "$actual_tag" = "$expected_tag" ] || {
    echo "HEAD ist nicht exakt mit $expected_tag getaggt." >&2
    exit 65
}
[ "$(git cat-file -t "$expected_tag" 2>/dev/null || true)" = "tag" ] || {
    echo "$expected_tag ist kein annotierter Tag." >&2
    exit 65
}

root_app="$project_root/Poor Man's Text.app"
installed_app="/Applications/Poor Man's Text.app"
dmg="$project_root/Poor-Mans-Text-$version.dmg"
checksum="$dmg.sha256"
for artifact in "$root_app" "$installed_app" "$dmg" "$checksum"; do
    [ -e "$artifact" ] || { echo "Release-Artefakt fehlt: $artifact" >&2; exit 66; }
done

source_version="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' \
    Sources/PoorMansTextCore/ProductInfo.swift)"
[ "$source_version" = "$version" ] || {
    echo "Die Quellversion stimmt nicht mit $version überein." >&2
    exit 65
}

# Repo-App, installierte App und die App im DMG müssen aus demselben Lauf
# stammen. Zwei getrennte Läufe (`./release.sh` und danach `./install.sh`) bauen,
# signieren und notarisieren zweimal; die Kopien tragen dann verschiedene
# CodeDirectory-Hashes und dieser Vergleich scheitert zu Recht. Ein vollständiges
# Release entsteht deshalb mit `./install.sh --with-dmg`.
code_directory_hash() {
    local target="$1"
    codesign -d --verbose=4 "$target" 2>&1 \
        | awk -F= '/^CDHash=/ && !found { print $2; found = 1 }'
}

root_app_hash="$(code_directory_hash "$root_app")"
root_cli_hash="$(code_directory_hash "$root_app/Contents/Resources/poormans-text")"
[ -n "$root_app_hash" ] && [ -n "$root_cli_hash" ] || {
    echo "CodeDirectory-Hash der Release-App fehlt." >&2
    exit 65
}

for app in "$root_app" "$installed_app"; do
    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$app/Contents/Info.plist")"
    [ "$app_version" = "$version" ] || {
        echo "Bundle-Version stimmt nicht mit $version überein: $app" >&2
        exit 65
    }
    "$script_directory/verify_bundle.sh" "$app" --notarized
    lipo "$app/Contents/MacOS/PoorMansTextApp" -verify_arch arm64 x86_64
    lipo "$app/Contents/Resources/poormans-text" -verify_arch arm64 x86_64
    [ "$(code_directory_hash "$app")" = "$root_app_hash" ] || {
        echo "CodeDirectory-Hash stimmt nicht mit der Release-App überein: $app" >&2
        echo "Alle Artefakte müssen aus einem Lauf stammen: ./install.sh --with-dmg" >&2
        exit 65
    }
    [ "$(code_directory_hash "$app/Contents/Resources/poormans-text")" = "$root_cli_hash" ] || {
        echo "CLI-CodeDirectory-Hash stimmt nicht mit der Release-App überein: $app" >&2
        echo "Alle Artefakte müssen aus einem Lauf stammen: ./install.sh --with-dmg" >&2
        exit 65
    }
done

checksum_hash="$(awk 'NR == 1 { print $1 }' "$checksum")"
checksum_name="$(awk 'NR == 1 { print $2 }' "$checksum")"
checksum_lines="$(awk 'END { print NR }' "$checksum")"
if [[ ! "$checksum_hash" =~ ^[[:xdigit:]]{64}$ ]] \
   || [ "$checksum_name" != "$(basename "$dmg")" ] \
   || [ "$checksum_lines" != "1" ]; then
    echo "Die SHA-256-Datei benennt nicht exakt das erwartete DMG." >&2
    exit 65
fi
(
    cd "$project_root"
    shasum -a 256 -c "$(basename "$checksum")"
)
"$script_directory/verify_dmg.sh" "$dmg" --notarized --matches-app "$root_app"

cli="$(command -v poormans-text 2>/dev/null || true)"
[ -n "$cli" ] || { echo "Installierte CLI ist nicht im PATH." >&2; exit 66; }
expected_cli="$installed_app/Contents/Resources/poormans-text"
[ -L "$cli" ] && [ "$(readlink "$cli")" = "$expected_cli" ] || {
    echo "CLI im PATH verweist nicht auf die installierte App: $cli" >&2
    exit 65
}
[ "$("$cli" --version)" = "Poor Man's Text $version" ] || {
    echo "Installierte CLI-Version stimmt nicht mit $version überein." >&2
    exit 65
}

echo "RELEASE OK: $expected_tag; App, CLI und DMG sind notarisiert und konsistent."
