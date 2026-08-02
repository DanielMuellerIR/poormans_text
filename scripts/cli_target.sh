#!/usr/bin/env bash
# Wahl und Vergleich des CLI-Zielverzeichnisses getrennt halten, damit die
# PATH-Logik ohne Build, Signatur oder /Applications getestet werden kann.

# Vergleicht Pfade unabhängig von bedeutungslosen Schreibweisen.
#
# `/opt/homebrew/bin/` und `/opt/homebrew/bin` meinen dasselbe Verzeichnis, ein
# roher Zeichenkettenvergleich sieht aber einen Unterschied. Genau daran hing
# die Zielwahl: Ein PATH mit abschließendem Schrägstrich fiel auf `/usr/local/bin`
# zurück und konnte den Lauf anschließend mit Exit 64 abbrechen.
poormans_text_normalize_path() {
    local path="$1"
    # Der einzelne Schrägstrich steht in einer Variablen, weil er als
    # Ersetzungstext direkt hinter dem Muster mehrdeutig wäre.
    local slash='/'
    while [[ "$path" == *//* ]]; do
        path="${path//\/\//$slash}"
    done
    case "$path" in
        /) ;;
        */) path="${path%/}" ;;
    esac
    printf '%s\n' "$path"
}

# Liegt dieses Verzeichnis im aktuellen PATH? Verglichen wird normalisiert.
poormans_text_path_contains_directory() {
    local wanted rest component
    wanted="$(poormans_text_normalize_path "$1")"
    rest="${PATH:-}:"
    while [ -n "$rest" ]; do
        component="${rest%%:*}"
        rest="${rest#*:}"
        [ -n "$component" ] || continue
        if [ "$(poormans_text_normalize_path "$component")" = "$wanted" ]; then
            return 0
        fi
    done
    return 1
}

# Standardziel der CLI. Kein fester Pfad: `/usr/local/bin` ist auf Apple Silicon
# nicht das Homebrew-bin, und ein dort neu angelegtes `poormans-text` würde von
# einem bereits vorhandenen in `/opt/homebrew/bin` verschattet — der Installer
# bricht dann berechtigt mit 73 ab (am 2026-07-26 genau so beobachtet).
# Deshalb: ein bereits installiertes Ziel gewinnt, sonst das erste
# Homebrew-Verzeichnis im aktuellen PATH, sonst der alte Standard.
poormans_text_default_cli_directory() {
    local existing candidate
    existing="$(command -v poormans-text 2>/dev/null || true)"
    if [ -n "$existing" ]; then
        poormans_text_normalize_path "$(dirname "$existing")"
        return
    fi
    for candidate in /opt/homebrew/bin /usr/local/bin; do
        if poormans_text_path_contains_directory "$candidate"; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    printf '%s\n' /usr/local/bin
}
