#!/usr/bin/env bash
# Prüft das gepackte Produkt unabhängig vom SwiftPM-Buildverzeichnis.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Aufruf: verify_bundle.sh <App-Bundle> [--signed|--notarized]" >&2
    exit 64
fi

app="$1"
signed=0
notarized=0
case "${2:-}" in
    "") ;;
    --signed) signed=1 ;;
    --notarized) signed=1; notarized=1 ;;
    *) echo "Unbekannte Option: $2" >&2; exit 64 ;;
esac

info_plist="$app/Contents/Info.plist"
bundled_cli="$app/Contents/Resources/poormans-text"
bundled_license="$app/Contents/Resources/LICENSE.txt"
bundled_sparkle_license="$app/Contents/Resources/Sparkle-LICENSE.txt"
bundled_icon="$app/Contents/Resources/AppIcon.icns"
sparkle_framework="$app/Contents/Frameworks/Sparkle.framework"
[ -f "$info_plist" ] || { echo "Info.plist fehlt im Bundle." >&2; exit 66; }
[ -x "$bundled_cli" ] || { echo "Ausführbare CLI fehlt im Bundle." >&2; exit 66; }
[ -f "$bundled_license" ] || { echo "Lizenzdatei fehlt im Bundle." >&2; exit 66; }
[ -f "$bundled_sparkle_license" ] || { echo "Sparkles Lizenzdatei fehlt im Bundle." >&2; exit 66; }
[ -f "$bundled_icon" ] || { echo "App-Icon fehlt im Bundle." >&2; exit 66; }

# Ohne das Framework startet die App nicht, und ohne Updater-Programm bliebe die
# Aktualisierung beim Austausch der App stehen.
[ -d "$sparkle_framework" ] || { echo "Sparkle.framework fehlt im Bundle." >&2; exit 66; }
[ -x "$sparkle_framework/Versions/B/Autoupdate" ] || {
    echo "Sparkles Autoupdate-Programm fehlt im Bundle." >&2
    exit 66
}
[ -d "$sparkle_framework/Versions/B/Updater.app" ] || {
    echo "Sparkles Updater-App fehlt im Bundle." >&2
    exit 66
}
# Die App ist nicht sandboxed; Sparkles XPC-Dienste gehören deshalb nicht ins
# ausgelieferte Bundle. Sie wären unsignierte, nutzlose Angriffsfläche.
if [ -e "$sparkle_framework/Versions/B/XPCServices" ] \
   || [ -e "$sparkle_framework/XPCServices" ]; then
    echo "Sparkles XPC-Dienste sind noch im Bundle." >&2
    exit 65
fi

# Der Updater darf nur einem signierten Feed über HTTPS folgen. Fehlt der
# öffentliche Schlüssel, ließe sich jedes beliebige Archiv unterschieben.
feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist" 2>/dev/null || true)"
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_plist" 2>/dev/null || true)"
case "$feed_url" in
    https://*) ;;
    *) echo "SUFeedURL fehlt oder benutzt kein HTTPS: ${feed_url:-<leer>}" >&2; exit 65 ;;
esac
[ -n "$public_key" ] || { echo "SUPublicEDKey fehlt in der Info.plist." >&2; exit 65; }

icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist")"
[ "$icon_name" = "AppIcon" ] || { echo "CFBundleIconFile verweist nicht auf AppIcon." >&2; exit 65; }
[ "$(sips -g format "$bundled_icon" | awk '/format:/{print $2}')" = "icns" ] || {
    echo "AppIcon.icns ist ungültig." >&2
    exit 65
}

codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$bundled_cli"
codesign --verify --deep --strict --verbose=2 "$sparkle_framework"

verify_distribution_signature() {
    local executable="$1"
    local label="$2"
    local signature_details
    signature_details="$(codesign -d --verbose=4 "$executable" 2>&1)"
    if ! printf '%s\n' "$signature_details" | grep -q 'flags=.*runtime'; then
        echo "Hardened Runtime fehlt in der $label-Signatur." >&2
        exit 65
    fi
    if ! printf '%s\n' "$signature_details" | grep -q '^Authority=Developer ID Application:'; then
        echo "Developer-ID-Application-Autorität fehlt in der $label-Signatur." >&2
        exit 65
    fi
    if ! printf '%s\n' "$signature_details" | grep -q '^Timestamp='; then
        echo "Sicherer Zeitstempel fehlt in der $label-Signatur." >&2
        exit 65
    fi
}

if [ "$signed" -eq 1 ]; then
    verify_distribution_signature "$app" "App"
    verify_distribution_signature "$bundled_cli" "CLI"
    # Sparkle kommt fertig gebaut von außen und wird beim Signieren neu
    # gesiegelt. Diese Prüfung stellt sicher, dass die eigene Developer ID
    # wirklich auf Framework, Updater-App und Autoupdate liegt — sonst
    # verweigert die Notarisierung später den ganzen Lauf.
    verify_distribution_signature "$sparkle_framework" "Sparkle-Framework"
    verify_distribution_signature \
        "$sparkle_framework/Versions/B/Updater.app" "Sparkle-Updater"
    verify_distribution_signature \
        "$sparkle_framework/Versions/B/Autoupdate" "Sparkle-Autoupdate"
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
