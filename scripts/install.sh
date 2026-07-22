#!/usr/bin/env bash
# Baut, signiert, notarisiert und installiert App sowie CLI.
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_directory/.." && pwd)"
# shellcheck source=install_transaction.sh
source "$script_directory/install_transaction.sh"
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
    "$script_directory/verify_bundle.sh" "$app" --signed
    refresh_root_artifacts
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
    echo "BUILD OK: $root_app ($version, Developer ID, nicht notarisiert)"
    exit 0
fi

temporary_directory="$(mktemp -d "$project_root/.build/poormans-notary.XXXXXX")"
published_checksum=0
cleanup() {
    local original_status=$?
    local installation_cleanup_status=0
    if declare -F cleanup_installation >/dev/null; then
        cleanup_installation || installation_cleanup_status=$?
    fi
    if [ "${published_checksum:-0}" -eq 1 ] \
       && [ ! -e "${dmg:-}" ] && [ ! -L "${dmg:-}" ] \
       && [ -n "${checksum_identity:-}" ] \
       && [ "$(/usr/bin/stat -f '%d:%i' "$checksum" 2>/dev/null || true)" = "$checksum_identity" ]; then
        remove_exact_path "$checksum" || true
    fi
    if [ -d "$temporary_directory" ]; then
        /usr/bin/swift -e \
            'import Foundation; try FileManager.default.removeItem(atPath: CommandLine.arguments[1])' \
            "$temporary_directory"
    fi
    if [ "$installation_cleanup_status" -ne 0 ]; then
        trap - EXIT
        exit "$installation_cleanup_status"
    fi
    return "$original_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="$project_root/Poor-Mans-Text-$version.dmg"
checksum="$dmg.sha256"
for final_artifact in "$dmg" "$checksum"; do
    if [ -e "$final_artifact" ] || [ -L "$final_artifact" ]; then
        echo "Das Release-Artefakt existiert bereits und wird nicht überschrieben: $final_artifact" >&2
        exit 73
    fi
done
staged_dmg="$temporary_directory/$(basename "$dmg")"
staged_checksum="$temporary_directory/$(basename "$checksum")"

notarize_and_check_log() {
    local artifact="$1"
    local label="$2"
    local response="$temporary_directory/$label-response.json"
    local log="$temporary_directory/$label-log.json"

    xcrun notarytool submit "$artifact" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json > "$response"

    local status submission_id
    status="$(plutil -extract status raw -o - "$response")"
    submission_id="$(plutil -extract id raw -o - "$response")"
    if [ "$status" != "Accepted" ]; then
        echo "Notarisierung für $label nicht akzeptiert: $status" >&2
        exit 65
    fi

    xcrun notarytool log "$submission_id" \
        --keychain-profile "$NOTARY_PROFILE" "$log" >/dev/null
    if plutil -extract issues xml1 -o - "$log" 2>/dev/null | grep -q '<dict>'; then
        echo "Das akzeptierte Notary-Log für $label enthält Hinweise oder Warnungen." >&2
        exit 65
    fi
    echo "NOTARY OK: $label"
}

archive="$temporary_directory/Poor-Mans-Text.zip"
echo "Reiche App zur Notarisierung ein und warte auf Apple …"
ditto -c -k --keepParent "$app" "$archive"
notarize_and_check_log "$archive" "app"

echo "Hefte das Notarisierungs-Ticket an …"
xcrun stapler staple "$app"
"$script_directory/verify_bundle.sh" "$app" --notarized
refresh_root_artifacts

echo "Erzeuge und signiere das Distributions-DMG …"
"$script_directory/create_dmg.sh" "$app" "$staged_dmg"
codesign --force --sign "$sign_identity" --timestamp "$staged_dmg"
"$script_directory/verify_dmg.sh" "$staged_dmg" --signed

echo "Reiche das DMG zur Notarisierung ein und warte auf Apple …"
notarize_and_check_log "$staged_dmg" "dmg"
xcrun stapler staple "$staged_dmg"
"$script_directory/verify_dmg.sh" "$staged_dmg" --notarized
(
    cd "$temporary_directory"
    shasum -a 256 "$(basename "$staged_dmg")" > "$(basename "$staged_checksum")"
)

# Die finale DMG-Datei erscheint zuletzt und kennzeichnet damit ein vollständiges
# Release-Paar. FileManager verweigert dabei weiterhin vorhandene Ziele.
checksum_identity="$(/usr/bin/stat -f '%d:%i' "$staged_checksum")"
published_checksum=1
/usr/bin/swift -e \
    'import Foundation; try FileManager.default.moveItem(atPath: CommandLine.arguments[1], toPath: CommandLine.arguments[2])' \
    "$staged_checksum" "$checksum"
if ! /usr/bin/swift -e \
    'import Foundation; try FileManager.default.moveItem(atPath: CommandLine.arguments[1], toPath: CommandLine.arguments[2])' \
    "$staged_dmg" "$dmg"; then
    remove_exact_path "$checksum"
    echo "Das fertige DMG konnte nicht veröffentlicht werden." >&2
    exit 74
fi
published_checksum=0

destination_app="/Applications/Poor Man's Text.app"
cli_directory="${CLI_INSTALL_DIR:-/usr/local/bin}"
case "$cli_directory" in
    /*) ;;
    *) echo "CLI_INSTALL_DIR muss ein absoluter Pfad sein." >&2; exit 64 ;;
esac
destination_cli="$cli_directory/poormans-text"
installed_cli="$destination_app/Contents/Resources/poormans-text"

expected_requirement="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
[ -n "$expected_requirement" ] || { echo "Designated Requirement der neuen App fehlt." >&2; exit 65; }

app_matches_release_identity() {
    local candidate="$1"
    [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
    codesign --verify --deep --strict "$candidate" >/dev/null 2>&1 || return 1
    local candidate_requirement
    candidate_requirement="$(codesign -d -r- "$candidate" 2>&1 | sed -n 's/^designated => //p')"
    [ "$candidate_requirement" = "$expected_requirement" ]
}

validate_existing_app() {
    local candidate="$1"
    if ! app_matches_release_identity "$candidate"; then
        echo "Das vorhandene App-Ziel hat nicht die erwartete Developer-ID-Signatur: $candidate" >&2
        return 1
    fi
    if ! xcrun stapler validate "$candidate" >/dev/null 2>&1; then
        echo "Das vorhandene App-Ziel hat kein gültiges Notarisierungs-Ticket: $candidate" >&2
        return 1
    fi
}

if [ -e "$destination_app" ] || [ -L "$destination_app" ]; then
    validate_existing_app "$destination_app" || exit 73
fi

if [ -L "$destination_cli" ]; then
    existing_link="$(readlink "$destination_cli")"
    if [ "$existing_link" != "$installed_cli" ]; then
        echo "Das vorhandene CLI-Symbolic-Link zeigt auf ein fremdes Ziel: $destination_cli" >&2
        exit 73
    fi
elif [ -e "$destination_cli" ]; then
    echo "Eine vorhandene reguläre CLI-Datei wird nicht automatisch ersetzt: $destination_cli" >&2
    exit 73
fi

current_command="$(command -v poormans-text 2>/dev/null || true)"
if [ -n "$current_command" ] && [ "$current_command" != "$destination_cli" ]; then
    echo "Ein anderes poormans-text liegt früher im PATH: $current_command" >&2
    echo "CLI_INSTALL_DIR passend wählen oder das alte Ziel zuerst bewusst entfernen." >&2
    exit 73
fi

case ":${PATH:-}:" in
    *":$cli_directory:"*) ;;
    *)
        echo "CLI_INSTALL_DIR liegt nicht im aktuellen PATH: $cli_directory" >&2
        exit 64
        ;;
esac

needs_admin=0
if [ ! -w /Applications ] || { [ -d "$cli_directory" ] && [ ! -w "$cli_directory" ]; }; then
    needs_admin=1
fi
if [ ! -d "$cli_directory" ] && [ ! -w "$(dirname "$cli_directory")" ]; then
    needs_admin=1
fi
if [ "$needs_admin" -eq 1 ]; then
    if sudo -n true 2>/dev/null; then
        : # Ein vorhandener sudo-Zeitstempel erlaubt auch einen headless Lauf.
    elif [ ! -t 0 ]; then
        echo "Installation benötigt Administratorrechte und muss in einem Terminal laufen." >&2
        exit 77
    else
        sudo -v
    fi
fi

if pgrep -x PoorMansTextApp >/dev/null 2>&1; then
    echo "Beende die laufende App vor der Installation …"
    pkill -x PoorMansTextApp || true
    sleep 1
fi

install_token="$(uuidgen | tr '[:upper:]' '[:lower:]')"
staged_app="/Applications/.PoorMansText-install-$install_token.app"
installation_state="preparing"
had_existing_app=0
created_cli=0

move_install_path() {
    local source="$1"
    local destination="$2"
    local swift_code='import Foundation; try FileManager.default.moveItem(atPath: CommandLine.arguments[1], toPath: CommandLine.arguments[2])'
    if [ "$needs_admin" -eq 1 ]; then
        sudo /usr/bin/swift -e "$swift_code" "$source" "$destination"
    else
        /usr/bin/swift -e "$swift_code" "$source" "$destination"
    fi
}

swap_install_paths() {
    local first="$1"
    local second="$2"
    local swift_code='import Darwin; if renameatx_np(AT_FDCWD, CommandLine.arguments[1], AT_FDCWD, CommandLine.arguments[2], UInt32(RENAME_SWAP)) != 0 { perror("renameatx_np"); exit(1) }'
    if [ "$needs_admin" -eq 1 ]; then
        sudo /usr/bin/swift -e "$swift_code" "$first" "$second"
    else
        /usr/bin/swift -e "$swift_code" "$first" "$second"
    fi
}

remove_install_path() {
    local path="$1"
    local swift_code='import Foundation; let manager = FileManager.default; let path = CommandLine.arguments[1]; let isLink = (try? manager.destinationOfSymbolicLink(atPath: path)) != nil; if manager.fileExists(atPath: path) || isLink { try manager.removeItem(atPath: path) }'
    if [ "$needs_admin" -eq 1 ]; then
        sudo /usr/bin/swift -e "$swift_code" "$path"
    else
        /usr/bin/swift -e "$swift_code" "$path"
    fi
}

copy_staged_app() {
    if [ "$needs_admin" -eq 1 ]; then
        sudo ditto "$app" "$staged_app"
    else
        ditto "$app" "$staged_app"
    fi
}

cleanup_installation() {
    poormans_text_cleanup_installation
}

rollback_app_installation() {
    cleanup_installation
}

if [ ! -d "$cli_directory" ]; then
    if [ "$needs_admin" -eq 1 ]; then
        sudo mkdir -p "$cli_directory"
    else
        mkdir -p "$cli_directory"
    fi
fi

if ! copy_staged_app; then
    remove_install_path "$staged_app" || true
    echo "Die neue App konnte nicht in /Applications gestagt werden." >&2
    exit 74
fi
installation_state="staged"
if ! "$script_directory/verify_bundle.sh" "$staged_app" --notarized; then
    remove_install_path "$staged_app" || true
    echo "Die gestagte App hat die Distributionsprüfung nicht bestanden." >&2
    exit 65
fi

if [ -e "$destination_app" ] || [ -L "$destination_app" ]; then
    validate_existing_app "$destination_app" || {
        remove_install_path "$staged_app" || true
        exit 73
    }
    if ! swap_install_paths "$staged_app" "$destination_app"; then
        remove_install_path "$staged_app" || true
        echo "Die vorhandene und die neue App konnten nicht atomar getauscht werden." >&2
        exit 74
    fi
    had_existing_app=1
    installation_state="swapped"
else
    if ! move_install_path "$staged_app" "$destination_app"; then
        remove_install_path "$staged_app" || true
        echo "Die neue App konnte nicht atomar installiert werden." >&2
        exit 74
    fi
    installation_state="installed-new"
fi

if [ ! -L "$destination_cli" ] && [ ! -e "$destination_cli" ]; then
    if [ "$needs_admin" -eq 1 ]; then
        if ! sudo ln -s "$installed_cli" "$destination_cli"; then
            rollback_app_installation
            exit 74
        fi
    elif ! ln -s "$installed_cli" "$destination_cli"; then
        rollback_app_installation
        exit 74
    fi
    created_cli=1
fi

installation_valid=1
"$script_directory/verify_bundle.sh" "$destination_app" --notarized || installation_valid=0
[ -L "$destination_cli" ] || installation_valid=0
[ "$(readlink "$destination_cli" 2>/dev/null || true)" = "$installed_cli" ] || installation_valid=0

installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$destination_app/Contents/Info.plist" 2>/dev/null || true)"
if [ "$("$destination_cli" --version 2>/dev/null || true)" != "Poor Man's Text $installed_version" ]; then
    installation_valid=0
fi
hash -r
if [ "$(command -v poormans-text 2>/dev/null || true)" != "$destination_cli" ]; then
    installation_valid=0
fi

if [ "$installation_valid" -ne 1 ]; then
    if [ "$created_cli" -eq 1 ] && [ -L "$destination_cli" ] \
       && [ "$(readlink "$destination_cli")" = "$installed_cli" ]; then
        remove_install_path "$destination_cli" || true
    fi
    rollback_app_installation
    echo "Die installierte App/CLI-Kombination hat die Endprüfung nicht bestanden." >&2
    exit 65
fi

if [ "$had_existing_app" -eq 1 ] && ! app_matches_release_identity "$staged_app"; then
        rollback_app_installation
        echo "Die atomar gesicherte alte App hat unerwartet die Identität gewechselt: $staged_app" >&2
        exit 73
fi
installation_state="committed"
created_cli=0
remove_install_path "$staged_app"
installation_state="clean"

echo "INSTALL OK: $destination_app ($installed_version); CLI: $destination_cli; DMG: $dmg"
