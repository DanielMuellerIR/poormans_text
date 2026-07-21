#!/usr/bin/env bash
# Prüft DMG, Ticket und die darin ausgelieferte App ohne Finder-Fenster.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Aufruf: verify_dmg.sh <Datei.dmg> [--signed|--notarized]" >&2
    exit 64
fi

dmg="$1"
mode="${2:-}"
case "$mode" in
    ""|--signed|--notarized) ;;
    *) echo "Unbekannte Option: $mode" >&2; exit 64 ;;
esac

[ -f "$dmg" ] || { echo "DMG fehlt: $dmg" >&2; exit 66; }
hdiutil verify "$dmg" >/dev/null

if [ "$mode" = "--signed" ] || [ "$mode" = "--notarized" ]; then
    codesign --verify --strict --verbose=2 "$dmg"
    signature_details="$(codesign -d --verbose=4 "$dmg" 2>&1)"
    if ! printf '%s\n' "$signature_details" | grep -q '^Authority=Developer ID Application:'; then
        echo "Developer-ID-Application-Autorität fehlt in der DMG-Signatur." >&2
        exit 65
    fi
    if ! printf '%s\n' "$signature_details" | grep -q '^Timestamp='; then
        echo "Sicherer Zeitstempel fehlt in der DMG-Signatur." >&2
        exit 65
    fi
fi
if [ "$mode" = "--notarized" ]; then
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

temporary_directory="$(mktemp -d /tmp/poormans-dmg-verify.XXXXXX)"
mount_root="$temporary_directory/mount"
mkdir -p "$mount_root"
mounted=0
device=""

detach_dmg() {
    [ "$mounted" -eq 1 ] || return 0
    local target="${device:-$mount_root}"
    local attempt
    for attempt in 1 2 3; do
        if hdiutil detach "$target" >/dev/null 2>&1; then
            mounted=0
            return 0
        fi
        sleep 1
    done
    if hdiutil detach -force "$target" >/dev/null 2>&1; then
        mounted=0
        return 0
    fi
    echo "Das DMG konnte nicht ausgehängt werden: $target" >&2
    return 1
}

cleanup() {
    detach_dmg || true
    if [ "$mounted" -eq 0 ] && [ -d "$temporary_directory" ]; then
        /usr/bin/swift -e \
            'import Foundation; try FileManager.default.removeItem(atPath: CommandLine.arguments[1])' \
            "$temporary_directory"
    fi
}
trap cleanup EXIT

mounted=1
attach_plist="$temporary_directory/attach.plist"
if ! hdiutil attach -plist -nobrowse -readonly -mountpoint "$mount_root" "$dmg" > "$attach_plist"; then
    mounted=0
    exit 74
fi
device="$(/usr/bin/swift -e '
import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let root = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
let entities = root["system-entities"] as? [[String: Any]] ?? []
let mountPoint = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath().path
guard let device = entities.first(where: {
    guard let path = $0["mount-point"] as? String else { return false }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == mountPoint
})?["dev-entry"] as? String else { exit(1) }
print(device)
' "$attach_plist" "$mount_root")"
[ -n "$device" ] || { echo "Device-ID des gemounteten DMG fehlt." >&2; exit 74; }
app="$mount_root/Poor Man's Text.app"
script_directory="$(cd "$(dirname "$0")" && pwd)"
"$script_directory/verify_bundle.sh" "$app" "$mode"
[ -L "$mount_root/Applications" ] || { echo "Applications-Link fehlt im DMG." >&2; exit 65; }
[ "$(readlink "$mount_root/Applications")" = "/Applications" ] || {
    echo "Applications-Link im DMG zeigt auf ein falsches Ziel." >&2
    exit 65
}

detach_dmg
echo "VERIFY DMG OK: $dmg"
