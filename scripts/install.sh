#!/usr/bin/env bash
# Baut, signiert, notarisiert und installiert App sowie CLI.
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_directory/.." && pwd)"
cd "$project_root"

notarize=1
for argument in "$@"; do
    case "$argument" in
        --no-notarize) notarize=0 ;;
        *)
            echo "Aufruf: ./install.sh [--no-notarize]" >&2
            exit 64
            ;;
    esac
done

if [ "$notarize" -eq 1 ]; then
    # shellcheck source=notary_profile.sh
    source "$script_directory/notary_profile.sh"
    poormans_text_require_notary_profile
fi

sign_identity="${POORMANS_TEXT_SIGN_IDENTITY:-}"
if [ -z "$sign_identity" ]; then
    sign_identity="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
if [ -z "$sign_identity" ]; then
    echo "Kein Developer-ID-Application-Zertifikat im Schlüsselbund gefunden." >&2
    exit 69
fi
echo "Developer-ID-Signatur verfügbar"

"$script_directory/build_app.sh" release
app="$project_root/.build/app/Poor Man's Text.app"
root_app="$project_root/Poor Man's Text.app"
root_cli="$project_root/poormans-text"
[ -d "$app" ] || { echo "Build-Ergebnis fehlt: $app" >&2; exit 70; }

echo "Signiere App und CLI mit Developer ID und Hardened Runtime …"
"$script_directory/sign_bundle.sh" "$app" "$sign_identity"

remove_exact_path() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        /usr/bin/swift -e \
            'import Foundation; try FileManager.default.removeItem(atPath: CommandLine.arguments[1])' \
            "$path"
    fi
}

refresh_root_artifacts() {
    remove_exact_path "$root_app"
    remove_exact_path "$root_cli"
    ditto "$app" "$root_app"
    ditto "$app/Contents/Resources/poormans-text" "$root_cli"
    chmod 755 "$root_cli"
}

if [ "$notarize" -eq 0 ]; then
    "$script_directory/verify_bundle.sh" "$app"
    refresh_root_artifacts
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
    echo "BUILD OK: $root_app ($version, Developer ID, nicht notarisiert)"
    exit 0
fi

temporary_directory="$(mktemp -d /tmp/poormans-notary.XXXXXX)"
cleanup() {
    if [ -d "$temporary_directory" ]; then
        /usr/bin/swift -e \
            'import Foundation; try FileManager.default.removeItem(atPath: CommandLine.arguments[1])' \
            "$temporary_directory"
    fi
}
trap cleanup EXIT

archive="$temporary_directory/Poor-Mans-Text.zip"
echo "Reiche App zur Notarisierung ein und warte auf Apple …"
ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait

echo "Hefte das Notarisierungs-Ticket an …"
xcrun stapler staple "$app"
"$script_directory/verify_bundle.sh" "$app" --notarized
refresh_root_artifacts

destination_app="/Applications/Poor Man's Text.app"
cli_directory="${CLI_INSTALL_DIR:-/usr/local/bin}"
case "$cli_directory" in
    /*) ;;
    *) echo "CLI_INSTALL_DIR muss ein absoluter Pfad sein." >&2; exit 64 ;;
esac
destination_cli="$cli_directory/poormans-text"
installed_cli="$destination_app/Contents/Resources/poormans-text"

if [ -e "$destination_app" ] || [ -L "$destination_app" ]; then
    existing_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$destination_app/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$existing_bundle_id" != "org.poormanstext.PoorMansText" ]; then
        echo "Das vorhandene App-Ziel gehört nicht zu Poor Man's Text: $destination_app" >&2
        exit 73
    fi
fi

if [ -L "$destination_cli" ]; then
    existing_link="$(readlink "$destination_cli")"
    if [ "$existing_link" != "$installed_cli" ]; then
        echo "Das vorhandene CLI-Symbolic-Link zeigt auf ein fremdes Ziel: $destination_cli" >&2
        exit 73
    fi
elif [ -e "$destination_cli" ]; then
    existing_cli_version="$("$destination_cli" --version 2>/dev/null || true)"
    case "$existing_cli_version" in
        "Poor Man's Text "*) ;;
        *) echo "Das vorhandene CLI-Ziel gehört nicht zu Poor Man's Text: $destination_cli" >&2; exit 73 ;;
    esac
fi

current_command="$(command -v poormans-text 2>/dev/null || true)"
if [ -n "$current_command" ] && [ "$current_command" != "$destination_cli" ]; then
    echo "Ein anderes poormans-text liegt früher im PATH: $current_command" >&2
    echo "CLI_INSTALL_DIR passend wählen oder das alte Ziel zuerst bewusst entfernen." >&2
    exit 73
fi

needs_admin=0
if [ ! -w /Applications ] || { [ -d "$cli_directory" ] && [ ! -w "$cli_directory" ]; }; then
    needs_admin=1
fi
if [ ! -d "$cli_directory" ] && [ ! -w "$(dirname "$cli_directory")" ]; then
    needs_admin=1
fi
if [ "$needs_admin" -eq 1 ]; then
    if [ ! -t 0 ]; then
        echo "Installation benötigt Administratorrechte und muss in einem Terminal laufen." >&2
        exit 77
    fi
    sudo -v
fi

if pgrep -x PoorMansTextApp >/dev/null 2>&1; then
    echo "Beende die laufende App vor der Installation …"
    pkill -x PoorMansTextApp || true
    sleep 1
fi

if [ -w /Applications ]; then
    remove_exact_path "$destination_app"
    ditto "$app" "$destination_app"
else
    sudo /usr/bin/swift -e \
        'import Foundation; let path = CommandLine.arguments[1]; if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }' \
        "$destination_app"
    sudo ditto "$app" "$destination_app"
fi

if [ -d "$cli_directory" ] && [ -w "$cli_directory" ]; then
    ln -sfn "$installed_cli" "$destination_cli"
else
    sudo mkdir -p "$cli_directory"
    sudo ln -sfn "$installed_cli" "$destination_cli"
fi

"$script_directory/verify_bundle.sh" "$destination_app" --notarized
[ -L "$destination_cli" ] || { echo "CLI-Link wurde nicht angelegt." >&2; exit 74; }
[ "$(readlink "$destination_cli")" = "$installed_cli" ] || { echo "CLI-Link zeigt auf ein falsches Ziel." >&2; exit 74; }

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$destination_app/Contents/Info.plist")"
if [ "$("$destination_cli" --version)" != "Poor Man's Text $version" ]; then
    echo "Installierte CLI-Version stimmt nicht mit der App überein." >&2
    exit 65
fi
hash -r
if [ "$(command -v poormans-text 2>/dev/null || true)" != "$destination_cli" ]; then
    echo "Die CLI wurde installiert, wird aber im aktuellen PATH nicht aufgelöst." >&2
    exit 65
fi

echo "INSTALL OK: $destination_app ($version); CLI: $destination_cli"
