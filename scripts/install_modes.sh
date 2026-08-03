#!/usr/bin/env bash
# Die Betriebsarten der beiden notarisierten Wege an einer Stelle. Eigene Datei,
# damit ein Test sie ohne Build, Signatur, Notarisierung und /Applications prüfen
# kann — wie bei cli_target.sh und install_transaction.sh.

# Wertet die Argumente aus und setzt notarize, make_dmg und do_install.
#
# Die Root-Wrapper stellen ihre Vorgabe voran (`./install.sh` schickt --no-dmg,
# `./release.sh` schickt --no-install) und reichen die Nutzerargumente dahinter
# durch. Ein späteres Flag gewinnt deshalb bewusst: `./install.sh --with-dmg`
# hebt das vorangestellte --no-dmg wieder auf und erzeugt DMG, Checksumme und
# Installation in einem einzigen Lauf. Genau diesen Lauf verlangt
# scripts/verify_release.sh, weil es die CodeDirectory-Hashes von Repo-App,
# installierter App und der App im DMG vergleicht: zwei getrennte Läufe bauen,
# signieren und notarisieren zweimal und können diese Gleichheit nicht liefern.
poormans_text_parse_install_modes() {
    notarize=1
    make_dmg=1
    do_install=1

    local argument
    for argument in "$@"; do
        case "$argument" in
            --no-notarize) notarize=0 ;;
            --no-dmg) make_dmg=0 ;;
            --with-dmg) make_dmg=1 ;;
            --no-install) do_install=0 ;;
            *)
                echo "Aufruf: $(basename "$0") [--no-notarize] [--no-dmg|--with-dmg] [--no-install]" >&2
                return 64
                ;;
        esac
    done

    if [ "$make_dmg" -eq 0 ] && [ "$do_install" -eq 0 ]; then
        echo "--no-dmg und --no-install zusammen ergeben keinen Lauf." >&2
        return 64
    fi
    return 0
}
