#!/usr/bin/env bash
# Root-Wrapper: bauen, notarisieren und das Release-DMG packen — ohne Installation.
#
# Der Ablauf ist derselbe wie bei ./install.sh, nur endet er mit dem fertigen,
# notarisierten und gestapelten DMG plus SHA-256-Datei im Projektverzeichnis.
# /Applications bleibt unberührt.
#
# Die drei Einstiegspunkte des Projekts trennen bewusst:
#   ./build.sh     baut die App im Projektverzeichnis, mehr nicht
#   ./install.sh   baut, notarisiert und installiert nach /Applications
#   ./release.sh   baut, notarisiert und packt das Release-DMG, installiert nie
#
# Vorhandene DMG-/Checksummen-Dateien werden nie überschrieben: existiert das
# Paar dieser Version schon, bricht der Lauf mit Exit 73 ab.
#
# Aufruf:  ./release.sh
# Letzte Zeile bei Erfolg (maschinenlesbar):  RELEASE OK: <pfad-zum-dmg> (<version>)
set -euo pipefail

exec "$(cd "$(dirname "$0")" && pwd)/scripts/install.sh" --no-install "$@"
