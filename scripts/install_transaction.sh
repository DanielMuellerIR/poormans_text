#!/usr/bin/env bash
# Transaktions-Cleanup getrennt halten, damit der kritische Rollback ohne
# /Applications, Signatur oder Administratorrechte getestet werden kann.

poormans_text_cleanup_installation() {
    local cleanup_status=0

    if [ "${created_cli:-0}" -eq 1 ] && [ -L "$destination_cli" ] \
       && [ "$(readlink "$destination_cli" 2>/dev/null || true)" = "$installed_cli" ]; then
        if remove_install_path "$destination_cli"; then
            created_cli=0
        else
            echo "Der während der Installation erzeugte CLI-Link konnte nicht entfernt werden: $destination_cli" >&2
            cleanup_status=74
        fi
    fi

    case "${installation_state:-preparing}" in
        swapped)
            # Nach RENAME_SWAP liegt die alte App am eindeutigen Stage-Pfad.
            # Der Pfad darf erst nach einem bestätigten Rücktausch entfernt werden.
            if [ ! -e "$staged_app" ] || [ ! -e "$destination_app" ]; then
                installation_state="rollback-failed"
                echo "Rollback fehlgeschlagen; der Rettungspfad bleibt unangetastet: $staged_app" >&2
                return 74
            fi
            if ! swap_install_paths "$staged_app" "$destination_app"; then
                installation_state="rollback-failed"
                echo "Rollback fehlgeschlagen; die bisherige App bleibt am Rettungspfad: $staged_app" >&2
                return 74
            fi
            # Nach erfolgreichem Rücktausch enthält der Stage-Pfad nur die neue App.
            installation_state="rolled-back"
            if ! remove_install_path "$staged_app"; then
                echo "Die zurückgenommene neue App konnte nicht entfernt werden: $staged_app" >&2
                cleanup_status=74
            fi
            ;;
        rollback-failed)
            echo "Rollback weiterhin unvollständig; Rettungspfad bleibt erhalten: $staged_app" >&2
            return 74
            ;;
        installed-new)
            if app_matches_release_identity "$destination_app" \
               && ! remove_install_path "$destination_app"; then
                cleanup_status=74
            fi
            ;;
        committed)
            # Hier enthält der Stage-Pfad nur noch die validierte alte App.
            if ! remove_install_path "$staged_app"; then
                cleanup_status=74
            fi
            ;;
        *)
            if ! remove_install_path "$staged_app"; then
                cleanup_status=74
            fi
            ;;
    esac

    if [ "$cleanup_status" -eq 0 ]; then
        installation_state="clean"
    fi
    return "$cleanup_status"
}
