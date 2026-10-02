#!/usr/bin/env bash
# Vergleicht Universal Binaries vollständig, unabhängig von der Host-Architektur.
code_directory_hash() {
    local target="$1" architecture details hash
    for architecture in arm64 x86_64; do
        details="$(codesign -d --arch "$architecture" --verbose=4 "$target" 2>&1)" || return
        hash="$(printf '%s\n' "$details" | awk -F= '/^CDHash=/ && !found { print $2; found = 1 }')"
        [ -n "$hash" ] || {
            echo "CodeDirectory-Hash für $architecture fehlt: $target" >&2
            return 65
        }
        printf '%s=%s\n' "$architecture" "$hash"
    done
}
