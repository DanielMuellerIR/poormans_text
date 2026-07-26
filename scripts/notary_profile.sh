#!/usr/bin/env bash
# Public-safe Verwaltung des clone-lokalen notarytool-Profilnamens.
# Credential-Werte bleiben ausschließlich im macOS-Schlüsselbund.

poormans_text_require_notary_profile() {
    local profile="${NOTARY_PROFILE:-}"

    if [ -z "$profile" ]; then
        profile="$(git config --local --get poormansText.notaryProfile 2>/dev/null || true)"
    fi

    if [ -z "$profile" ]; then
        if [ ! -t 0 ]; then
            echo "Kein lokales Notary-Profil konfiguriert." >&2
            echo "Einmalig interaktiv ausführen oder nur für diesen Clone setzen:" >&2
            echo "git config --local poormansText.notaryProfile <profil>" >&2
            return 1
        fi

        printf "Notary-Profilname für diesen Mac [notary]: " >&2
        IFS= read -r profile
        profile="${profile:-notary}"
    fi

    # Nur ein echter notarytool-Aufruf erkennt alle gültigen Profil-Speicherorte.
    #
    # Fünf Versuche statt einem: `history` meldet gelegentlich fälschlich „No
    # Keychain password item found", obwohl das Profil da ist (2026-07-26 auf M3
    # belegt — Versuch 1 fehlgeschlagen, Versuch 2 sofort ok). Ein einzelner
    # Fehlversuch würde sonst einen ganzen Lauf grundlos abbrechen oder unnötig
    # nach store-credentials fragen; ein wirklich fehlendes Profil scheitert auch
    # nach fünf Versuchen.
    local attempt profile_ok=0
    for attempt in 1 2 3 4 5; do
        if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
            profile_ok=1
            break
        fi
        sleep 3
    done
    if [ "$profile_ok" = 0 ]; then
        echo "Das Notary-Profil '$profile' ist auf diesem Mac nicht verwendbar." >&2
        echo "Keychain-Profile werden nicht zwischen Macs synchronisiert." >&2

        if [ ! -t 0 ]; then
            echo "In einer lokalen GUI-Terminalsitzung einmalig einrichten:" >&2
            echo "xcrun notarytool store-credentials '$profile' --apple-id '<apple-id>' --team-id '<team-id>'" >&2
            echo "Das App-Passwort nur an der verdeckten Abfrage eingeben." >&2
            return 1
        fi

        printf "Profil jetzt interaktiv im Schlüsselbund einrichten? [j/N] " >&2
        local answer
        IFS= read -r answer
        case "$answer" in
            j|J|ja|Ja|JA|y|Y|yes|Yes|YES) ;;
            *) return 1 ;;
        esac

        local apple_id team_id
        printf "Apple-ID: " >&2
        IFS= read -r apple_id
        printf "Team-ID: " >&2
        IFS= read -r team_id
        if [ -z "$apple_id" ] || [ -z "$team_id" ]; then
            echo "Apple-ID und Team-ID dürfen nicht leer sein." >&2
            return 1
        fi

        # Absichtlich ohne --password: notarytool fragt verdeckt und speichert
        # das App-Passwort direkt im lokalen Schlüsselbund.
        xcrun notarytool store-credentials "$profile" \
            --apple-id "$apple_id" --team-id "$team_id"
        xcrun notarytool history --keychain-profile "$profile" >/dev/null
    fi

    # .git/config ist clone-lokal und kann nicht committed werden.
    git config --local poormansText.notaryProfile "$profile"
    NOTARY_PROFILE="$profile"
    export NOTARY_PROFILE
}
