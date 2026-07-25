#!/usr/bin/env bash
# Root-Wrapper: bauen, signieren, notarisieren und nach /Applications installieren.
#
# Kein DMG — das baut ./release.sh. Die drei Einstiegspunkte des Projekts
# trennen bewusst:
#   ./build.sh     baut die App im Projektverzeichnis, mehr nicht
#   ./install.sh   baut, notarisiert und installiert nach /Applications
#   ./release.sh   baut, notarisiert und packt das Release-DMG, installiert nie
#
# Aufruf:
#   ./install.sh                  # notarisiert installieren
#   ./install.sh --no-notarize    # nur bauen und lokal signieren (kein /Applications)
set -euo pipefail

exec "$(cd "$(dirname "$0")" && pwd)/scripts/install.sh" --no-dmg "$@"
