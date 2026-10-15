#!/bin/sh
# Rebuild the macOS icon from the source artwork.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
iconset=$(mktemp -d "${TMPDIR:-/tmp}/EZTunnelIcon.XXXXXX")
trap 'rm -rf "$iconset"' EXIT INT TERM
mkdir "$iconset/AppIcon.iconset"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$project_root/Resources/AppIcon.png" \
        --out "$iconset/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$project_root/Resources/AppIcon.png" \
        --out "$iconset/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset/AppIcon.iconset" -o "$project_root/Resources/AppIcon.icns"
