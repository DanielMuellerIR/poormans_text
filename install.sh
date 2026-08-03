#!/usr/bin/env bash
# Root-Wrapper: bauen, signieren, notarisieren und nach /Applications installieren.
#
# Normal ohne DMG — das baut ./release.sh. Die drei Einstiegspunkte des Projekts
# trennen bewusst:
#   ./build.sh     baut die App im Projektverzeichnis, mehr nicht
#   ./install.sh   baut, notarisiert und installiert nach /Applications
#   ./release.sh   baut, notarisiert und packt das Release-DMG, installiert nie
#
# Für ein vollständiges Release gibt es --with-dmg: dann entstehen DMG,
# Checksumme und Installation in einem einzigen Lauf aus demselben signierten
# Bundle. Nur so tragen Repo-App, installierte App und die App im DMG denselben
# CodeDirectory-Hash, den scripts/verify_release.sh vergleicht.
#
# Aufruf:
#   ./install.sh                  # notarisiert installieren
#   ./install.sh --with-dmg       # Release: DMG, Checksumme und Installation in einem Lauf
#   ./install.sh --no-notarize    # nur bauen und lokal signieren (kein /Applications)
set -euo pipefail

exec "$(cd "$(dirname "$0")" && pwd)/scripts/install.sh" --no-dmg "$@"
