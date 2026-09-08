#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${1:-debug}

cd "$project_root"
swift build --configuration "$configuration" --product EZTunnel
swift build --configuration "$configuration" --product EZTunnelAskPass
binary_directory=$(swift build --configuration "$configuration" --show-bin-path)
app_bundle="$project_root/.build/EZ Tunnel.app"

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$project_root/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$binary_directory/EZTunnel" "$app_bundle/Contents/MacOS/EZTunnel"
chmod 755 "$app_bundle/Contents/MacOS/EZTunnel"
cp "$binary_directory/EZTunnelAskPass" "$app_bundle/Contents/MacOS/EZTunnelAskPass"
chmod 755 "$app_bundle/Contents/MacOS/EZTunnelAskPass"
codesign --force --sign - "$app_bundle/Contents/MacOS/EZTunnelAskPass" >/dev/null
codesign --force --sign - "$app_bundle" >/dev/null

printf '%s\n' "$app_bundle"
