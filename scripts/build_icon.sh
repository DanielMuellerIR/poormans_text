#!/usr/bin/env bash
# Erzeugt das macOS-Icon reproduzierbar aus dem getrackten 1024-Pixel-Master.
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_directory/.." && pwd)"
source_icon="$project_root/Assets/AppIcon.png"
build_directory="$project_root/.build/icon"
iconset="$build_directory/AppIcon.iconset"
output_icon="$build_directory/AppIcon.icns"

[ -f "$source_icon" ] || {
    echo "Icon-Master fehlt: $source_icon" >&2
    exit 66
}

width="$(sips -g pixelWidth "$source_icon" | awk '/pixelWidth/{print $2}')"
height="$(sips -g pixelHeight "$source_icon" | awk '/pixelHeight/{print $2}')"
has_alpha="$(sips -g hasAlpha "$source_icon" | awk '/hasAlpha/{print $2}')"
if [ "$width" != "1024" ] || [ "$height" != "1024" ] || [ "$has_alpha" != "yes" ]; then
    echo "Assets/AppIcon.png muss 1024 × 1024 Pixel groß sein und Transparenz enthalten." >&2
    exit 65
fi

mkdir -p "$build_directory"
if [ -e "$iconset" ]; then
    /usr/bin/swift -e \
        'import Foundation; try FileManager.default.removeItem(atPath: CommandLine.arguments[1])' \
        "$iconset"
fi
mkdir "$iconset"

create_icon() {
    local size="$1"
    local filename="$2"
    sips -z "$size" "$size" "$source_icon" --out "$iconset/$filename" >/dev/null
}

create_icon 16 icon_16x16.png
create_icon 32 icon_16x16@2x.png
create_icon 32 icon_32x32.png
create_icon 64 icon_32x32@2x.png
create_icon 128 icon_128x128.png
create_icon 256 icon_128x128@2x.png
create_icon 256 icon_256x256.png
create_icon 512 icon_256x256@2x.png
create_icon 512 icon_512x512.png
cp "$source_icon" "$iconset/icon_512x512@2x.png"

iconutil -c icns "$iconset" -o "$output_icon"
[ "$(sips -g format "$output_icon" | awk '/format:/{print $2}')" = "icns" ] || {
    echo "Das erzeugte AppIcon.icns ist ungültig." >&2
    exit 65
}

echo "ICON OK: $output_icon"
