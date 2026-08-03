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
# Für ein vollständiges, mit scripts/verify_release.sh prüfbares Release ist
# dieser Wrapper der falsche: er baut nur das DMG, und ein zweiter Lauf für die
# Installation würde erneut bauen und signieren. Dafür gibt es
# `./install.sh --with-dmg` — ein Lauf, ein signiertes Bundle, alle Artefakte.
#
# Vorhandene DMG-/Checksummen-Dateien werden nie überschrieben: existiert das
# Paar dieser Version schon, bricht der Lauf mit Exit 73 ab.
#
# Aufruf:  ./release.sh
# Letzte Zeile bei Erfolg (maschinenlesbar):  RELEASE OK: <pfad-zum-dmg> (<version>)
set -euo pipefail

exec "$(cd "$(dirname "$0")" && pwd)/scripts/install.sh" --no-install "$@"
