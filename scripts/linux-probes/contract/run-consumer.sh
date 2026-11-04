#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")" && pwd)
fastra=${1:-${FASTRA_REPO:?Fastra-Quellpfad als Argument oder FASTRA_REPO angeben}}
swiftc=${SWIFTC:-swiftc}
build=$(mktemp -d /tmp/pmt-consumer-build.XXXXXX)
trap 'rm -rf "$build"' EXIT
# Originalverbraucher unverändert; auf Linux nur den Systemimport ergänzen.
printf '#if os(Linux)\nimport Glibc\n#endif\n' > "$build/MarkdownImport.swift"
cat "$fastra/app/Sources/Fastra/MarkdownImport.swift" >> "$build/MarkdownImport.swift"
# Originalservice einschließlich publication; nur Frameworkimport und hier
# unbenötigten GitRunner-Ergebnisadapter aus der Kompilationskopie entfernen.
sed '/\/\/ Eigene Erweiterung/,$d' "$fastra/app/Sources/Fastra/MarkdownImportService.swift" | sed '/^import AppKit$/d' > "$build/MarkdownImportService.swift"
sed -n '/^\/\/\/ Sichtbarer Zustand der Umwandlung\./,$p' "$fastra/app/Sources/Fastra/MarkdownImportService.swift" >> "$build/MarkdownImportService.swift"
"$swiftc" "$build/MarkdownImportService.swift" "$base/service-stubs.swift" "$build/MarkdownImport.swift" "$fastra/app/Sources/Fastra/MarkdownImportProgress.swift" "$base/consumer-main.swift" -o "$build/consumer"
"$build/consumer" "$base/goldens"
