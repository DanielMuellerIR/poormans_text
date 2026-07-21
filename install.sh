#!/usr/bin/env bash
# Root-Wrapper für den vollständigen Signatur-, Notarisierungs- und Installationslauf.
set -euo pipefail

exec "$(cd "$(dirname "$0")" && pwd)/scripts/install.sh" "$@"
