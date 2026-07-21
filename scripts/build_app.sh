#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
project_root="${script_directory:h}"
build_configuration="${CONFIGURATION:-release}"
bundle_root="$project_root/.build/app"
bundle_path="$bundle_root/Poor Man's Text.app"
contents_path="$bundle_path/Contents"

cd "$project_root"
swift build --configuration "$build_configuration" --product PoorMansTextApp
binary_directory="$(swift build --configuration "$build_configuration" --show-bin-path)"

# Das Bundle ist ein vollständig generiertes Artefakt unter .build. Ein alter
# lokaler Test-Build wird nur innerhalb dieses eindeutig begrenzten Pfads ersetzt.
if [[ -e "$bundle_path" ]]; then
    /usr/bin/swift -e 'import Foundation; try FileManager.default.removeItem(atPath: CommandLine.arguments[1])' "$bundle_path"
fi

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_directory/PoorMansTextApp" "$contents_path/MacOS/PoorMansTextApp"
cp "$project_root/App/Info.plist" "$contents_path/Info.plist"
codesign --force --sign - "$bundle_path"

print -r -- "$bundle_path"
