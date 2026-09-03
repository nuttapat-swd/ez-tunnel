#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${1:-debug}

cd "$project_root"
swift build --configuration "$configuration" --product EZTunnel
binary_directory=$(swift build --configuration "$configuration" --show-bin-path)
app_bundle="$project_root/.build/EZ Tunnel.app"

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$project_root/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$binary_directory/EZTunnel" "$app_bundle/Contents/MacOS/EZTunnel"
chmod 755 "$app_bundle/Contents/MacOS/EZTunnel"
codesign --force --sign - "$app_bundle" >/dev/null

printf '%s\n' "$app_bundle"
