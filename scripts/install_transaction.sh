#!/usr/bin/env bash
# Transaktions-Cleanup getrennt halten, damit der kritische Rollback ohne
# /Applications, Signatur oder Administratorrechte getestet werden kann.

poormans_text_cleanup_installation() {
    local cleanup_status=0

    # INT/TERM kann nach einem atomaren Dateisystemaufruf, aber vor der nächsten
    # Shell-Zuweisung eintreffen. In den beiden Pending-Zuständen entscheidet
    # deshalb nicht ein verspätetes Flag, sondern die vor der Mutation gemerkte
    # Geräte-/Inode-Identität darüber, ob noch der Ausgangsstand oder bereits das
    # Ergebnis sichtbar ist.
    local reconcile_status=0
    poormans_text_reconcile_pending_installation || reconcile_status=$?
    if [ "$reconcile_status" -ne 0 ]; then
        return "$reconcile_status"
    fi

    # Das DMG erscheint als letzter atomarer Move. Ist es zusammen mit seiner
    # Prüfsumme unter exakt der zuvor gemerkten Identität sichtbar, ist die
    # Veröffentlichung vollständig — auch wenn INT/TERM zwischen dem Move und
    # der folgenden Shell-Zuweisung eintraf. Dann darf die validierte
    # Installation nicht mehr zurückgerollt werden.
    if { [ "${installation_state:-preparing}" = "swapped" ] \
         || [ "${installation_state:-preparing}" = "installed-new" ]; } \
       && poormans_text_release_artifacts_are_published; then
        installation_state="published"
        created_cli=0
        published_dmg=0
        published_checksum=0
    fi

    if [ "${installation_state:-preparing}" = "swapped" ] \
       && ! poormans_text_path_matches_identity "$staged_app" "${old_app_identity:-}"; then
        installation_state="backup-suspicious"
        created_cli=0
        echo "Die atomar gesicherte alte App hat vor dem Rollback unerwartet die Identität gewechselt: $staged_app" >&2
        echo "Die geprüfte neue App und ihr CLI-Link bleiben installiert." >&2
    fi

    # Ein übernommener Endzustand umfasst App und CLI. Ob der Link noch über
    # das ältere Flag als "erzeugt" markiert ist, darf ihn dort nicht wieder
    # zu Rollback-Abfall machen: Ein Signal kann zwischen zwei
    # Shell-Zuweisungen eintreffen. Nur Zustände, in denen auch die App
    # tatsächlich zurückgenommen wird, dürfen den eigenen CLI-Link entfernen.
    local rollback_cli=0
    case "${installation_state:-preparing}" in
        staged|swapped|installed-new|rolled-back)
            case "${cli_state:-}" in
                stage-pending|staged|move-pending|installed) rollback_cli=1 ;;
                *) [ "${created_cli:-0}" -eq 1 ] && rollback_cli=1 ;;
            esac
            ;;
    esac

    case "${installation_state:-preparing}" in
        swapped)
            # Nach RENAME_SWAP liegt die alte App am eindeutigen Stage-Pfad.
            # Der Pfad darf erst nach einem bestätigten Rücktausch entfernt werden.
            if ! poormans_text_path_matches_identity "$staged_app" "${old_app_identity:-}" \
               || ! poormans_text_path_matches_identity "$destination_app" "${new_app_identity:-}"; then
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
            if ! poormans_text_remove_install_path_with_identity \
                "$staged_app" "${new_app_identity:-}" "zurückgenommene neue App"; then
                echo "Die zurückgenommene neue App konnte nicht entfernt werden: $staged_app" >&2
                cleanup_status=74
            fi
            ;;
        rolled-back)
            # Der Rücktausch ist abgeschlossen, aber das Entfernen der neuen App
            # oder ihres CLI-Links kann zuvor fehlgeschlagen sein. Dieser Zustand
            # bleibt deshalb bis zum tatsächlich sauberen Ende wiederholbar.
            if ! poormans_text_remove_install_path_with_identity \
                "$staged_app" "${new_app_identity:-}" "zurückgenommene neue App"; then
                echo "Die zurückgenommene neue App konnte nicht entfernt werden: $staged_app" >&2
                cleanup_status=74
            fi
            ;;
        rollback-failed)
            echo "Rollback weiterhin unvollständig; Rettungspfad bleibt erhalten: $staged_app" >&2
            return 74
            ;;
        backup-suspicious)
            # Die neue App ist bereits vollständig geprüft. Das alte Bundle am
            # Stage-Pfad darf weder zurückgetauscht noch gelöscht werden, wenn
            # sich seine Identität nach dem Tausch unerwartet geändert hat.
            ;;
        published)
            # Das Release-Paar ist sichtbar; App und CLI gehören nun dazu. Nur
            # das geprüfte alte Bundle am Stage-Pfad darf noch entfernt werden.
            if [ "${had_existing_app:-0}" -eq 1 ]; then
                if ! poormans_text_path_matches_identity "$staged_app" "${old_app_identity:-}"; then
                    installation_state="backup-suspicious"
                    echo "Die atomar gesicherte alte App hat nach der Veröffentlichung unerwartet die Identität gewechselt: $staged_app" >&2
                    return 73
                fi
                if ! poormans_text_remove_install_path_with_identity \
                    "$staged_app" "${old_app_identity:-}" "alte App-Sicherung"; then
                    cleanup_status=74
                fi
            fi
            ;;
        installed-new)
            if [ -e "$destination_app" ] || [ -L "$destination_app" ]; then
                if ! poormans_text_path_matches_identity \
                    "$destination_app" "${new_app_identity:-}"; then
                    installation_state="rollback-failed"
                    echo "Die neu installierte App hat vor dem Rollback unerwartet die Identität gewechselt und bleibt unangetastet: $destination_app" >&2
                    return 74
                fi
                if ! poormans_text_remove_install_path_with_identity \
                    "$destination_app" "${new_app_identity:-}" "neu installierte App"; then
                    cleanup_status=74
                fi
            fi
            ;;
        committed)
            # Hier enthält der Stage-Pfad nur noch die validierte alte App.
            if [ "${had_existing_app:-0}" -eq 1 ]; then
                if ! poormans_text_path_matches_identity "$staged_app" "${old_app_identity:-}"; then
                    installation_state="backup-suspicious"
                    echo "Die atomar gesicherte alte App hat vor dem Entfernen unerwartet die Identität gewechselt: $staged_app" >&2
                    return 73
                fi
                if ! poormans_text_remove_install_path_with_identity \
                    "$staged_app" "${old_app_identity:-}" "alte App-Sicherung"; then
                    cleanup_status=74
                fi
            fi
            ;;
        staged)
            if ! poormans_text_remove_install_path_with_identity \
                "$staged_app" "${new_app_identity:-}" "gestagte neue App"; then
                cleanup_status=74
            fi
            ;;
        preparing|rolled-back|clean)
            ;;
        *)
            local unknown_state="${installation_state:-}"
            installation_state="rollback-failed"
            echo "Unbekannter Installationszustand; Dateipfade bleiben unangetastet: $unknown_state" >&2
            return 74
            ;;
    esac

    if [ "$rollback_cli" -eq 1 ]; then
        local cli_cleanup_status=0
        poormans_text_cleanup_created_cli || cli_cleanup_status=$?
        if [ "$cli_cleanup_status" -ne 0 ]; then
            cleanup_status="$cli_cleanup_status"
        fi
    fi

    if [ "$cleanup_status" -eq 0 ]; then
        installation_state="clean"
    fi
    return "$cleanup_status"
}

poormans_text_cleanup_created_cli() {
    local cleanup_status=0
    local removal_status=0
    for candidate in "${destination_cli:-}" "${staged_cli:-}"; do
        [ -n "$candidate" ] || continue
        if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
            continue
        fi
        if ! poormans_text_path_matches_identity "$candidate" "${new_cli_identity:-}"; then
            echo "Ein CLI-Link am Installationspfad hat eine fremde Identität und bleibt unangetastet: $candidate" >&2
            cleanup_status=73
            continue
        fi
        removal_status=0
        remove_install_path "$candidate" || removal_status=$?
        if [ "$removal_status" -ne 0 ]; then
            echo "Der während der Installation erzeugte CLI-Link konnte nicht entfernt werden: $candidate" >&2
            cleanup_status=74
        fi
    done
    if [ "$cleanup_status" -eq 0 ]; then
        created_cli=0
    fi
    return "$cleanup_status"
}

poormans_text_path_identity() {
    /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null || true
}

poormans_text_path_matches_identity() {
    local path="$1"
    local expected_identity="$2"
    [ -n "$expected_identity" ] \
        && [ "$(poormans_text_path_identity "$path")" = "$expected_identity" ]
}

poormans_text_create_staged_cli_link() {
    local link_status=0
    if [ "$needs_admin" -eq 1 ]; then
        sudo ln -s "$installed_cli" "$staged_cli" || link_status=$?
    else
        ln -s "$installed_cli" "$staged_cli" || link_status=$?
    fi
    # Ein Prozessgruppensignal kann `ln` nach erfolgreichem symlink(2), aber vor
    # seinem normalen Exit treffen. Auch bei Fehlerstatus zählt deshalb zuerst
    # der beobachtbare Endzustand; der aufrufende Wrapper liefert das vorgemerkte
    # Signal anschließend aus.
    if [ -L "$staged_cli" ] \
       && [ "$(readlink "$staged_cli" 2>/dev/null || true)" = "$installed_cli" ]; then
        new_cli_identity="$(poormans_text_path_identity "$staged_cli")"
        if [ -n "$new_cli_identity" ]; then
            cli_state="staged"
        fi
    fi
    [ "${cli_state:-}" = "staged" ] || return 74
    [ "$link_status" -eq 0 ] || return 74
}

# INT und TERM dürfen den erzeugten Link nicht zwischen `ln` und seiner
# Identitätserfassung verwaisen lassen. Die Handler merken das Signal deshalb
# während der kurzen kritischen Sektion nur vor. Erst wenn die Identität in
# der aufrufenden Shell steht, wird der ursprüngliche Signalstatus geliefert;
# der EXIT-Cleanup kann den Link dann zweifelsfrei als eigenen erkennen.
poormans_text_create_staged_cli_link_with_deferred_signals() {
    local link_status=0
    local deferred_signal_status=0
    trap 'deferred_signal_status=130' INT
    trap 'deferred_signal_status=143' TERM
    poormans_text_create_staged_cli_link || link_status=$?
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$deferred_signal_status" -ne 0 ]; then
        return "$deferred_signal_status"
    fi
    return "$link_status"
}

poormans_text_remove_install_path_with_identity() {
    local path="$1"
    local expected_identity="$2"
    local label="$3"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        return 0
    fi
    if ! poormans_text_path_matches_identity "$path" "$expected_identity"; then
        echo "$label hat unerwartet ihre Identität geändert und bleibt unangetastet: $path" >&2
        return 73
    fi
    remove_install_path "$path"
}

poormans_text_reconcile_pending_installation() {
    case "${installation_state:-preparing}" in
        swap-pending)
            if poormans_text_path_matches_identity "$staged_app" "${old_app_identity:-}" \
               && poormans_text_path_matches_identity "$destination_app" "${new_app_identity:-}"; then
                installation_state="swapped"
            elif poormans_text_path_matches_identity "$staged_app" "${new_app_identity:-}" \
                 && poormans_text_path_matches_identity "$destination_app" "${old_app_identity:-}"; then
                installation_state="staged"
            else
                installation_state="rollback-failed"
                echo "Der tatsächliche App-Tauschzustand ist nicht eindeutig; beide Pfade bleiben unangetastet." >&2
                return 74
            fi
            ;;
        install-pending)
            if poormans_text_path_matches_identity "$destination_app" "${new_app_identity:-}" \
               && [ ! -e "$staged_app" ] && [ ! -L "$staged_app" ]; then
                installation_state="installed-new"
            elif poormans_text_path_matches_identity "$staged_app" "${new_app_identity:-}" \
                 && [ ! -e "$destination_app" ] && [ ! -L "$destination_app" ]; then
                installation_state="staged"
            else
                installation_state="rollback-failed"
                echo "Der tatsächliche Erstinstallationszustand ist nicht eindeutig; beide Pfade bleiben unangetastet." >&2
                return 74
            fi
            ;;
    esac
}

poormans_text_release_artifacts_are_published() {
    [ "${make_dmg:-0}" -eq 1 ] \
        && [ -n "${dmg:-}" ] \
        && [ -n "${checksum:-}" ] \
        && [ -n "${dmg_identity:-}" ] \
        && [ -n "${checksum_identity:-}" ] \
        && [ "$(/usr/bin/stat -f '%d:%i' "$dmg" 2>/dev/null || true)" = "$dmg_identity" ] \
        && [ "$(/usr/bin/stat -f '%d:%i' "$checksum" 2>/dev/null || true)" = "$checksum_identity" ]
}

poormans_text_discard_published_checksum() {
    if [ ! -e "$checksum" ] && [ ! -L "$checksum" ]; then
        published_checksum=0
        return 0
    fi
    if [ -z "${checksum_identity:-}" ] \
       || [ "$(/usr/bin/stat -f '%d:%i' "$checksum" 2>/dev/null || true)" != "$checksum_identity" ]; then
        echo "Die unvollständig veröffentlichte Prüfsumme hat unerwartet ihre Identität geändert und bleibt unangetastet: $checksum" >&2
        return 73
    fi
    if ! remove_exact_path "$checksum"; then
        echo "Die unvollständig veröffentlichte Prüfsumme konnte nicht entfernt werden: $checksum" >&2
        return 74
    fi
    published_checksum=0
}

poormans_text_discard_published_dmg() {
    if [ ! -e "$dmg" ] && [ ! -L "$dmg" ]; then
        published_dmg=0
        return 0
    fi
    if [ -z "${dmg_identity:-}" ] \
       || [ "$(poormans_text_path_identity "$dmg")" != "$dmg_identity" ]; then
        echo "Das unvollständig veröffentlichte DMG hat unerwartet seine Identität geändert und bleibt unangetastet: $dmg" >&2
        return 73
    fi
    if ! remove_exact_path "$dmg"; then
        echo "Das unvollständig veröffentlichte DMG konnte nicht entfernt werden: $dmg" >&2
        return 74
    fi
    published_dmg=0
}

poormans_text_discard_tracked_release_artifacts() {
    local cleanup_status=0
    local current_status=0
    if [ "${published_dmg:-0}" -eq 1 ]; then
        poormans_text_discard_published_dmg || current_status=$?
        [ "$current_status" -eq 0 ] || cleanup_status="$current_status"
    fi
    current_status=0
    if [ "${published_checksum:-0}" -eq 1 ]; then
        poormans_text_discard_published_checksum || current_status=$?
        if [ "$cleanup_status" -eq 0 ] && [ "$current_status" -ne 0 ]; then
            cleanup_status="$current_status"
        fi
    fi
    return "$cleanup_status"
}

poormans_text_verify_or_discard_release_artifacts() {
    if poormans_text_release_artifacts_are_published; then
        published_dmg=0
        published_checksum=0
        return 0
    fi
    local cleanup_status=0
    poormans_text_discard_tracked_release_artifacts || cleanup_status=$?
    if [ "$cleanup_status" -ne 0 ]; then
        return "$cleanup_status"
    fi
    return 74
}
