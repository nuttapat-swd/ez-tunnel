#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
/bin/sh "$project_root/Scripts/build-app.sh"
app_bundle="$project_root/.build/EZ Tunnel.app"
info_plist="$app_bundle/Contents/Info.plist"
executable="$app_bundle/Contents/MacOS/EZTunnel"

test -x "$executable"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$info_plist")" = "APPL"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" = "dev.nuttapat.ez-tunnel"
codesign --verify "$app_bundle"

application_pid=""
cleanup() {
    test -z "$application_pid" || kill "$application_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

open -n "$app_bundle"
attempt=0
while test "$attempt" -lt 20; do
    application_pid=$(pgrep -f "^$executable$" | tail -n 1 || true)
    test -n "$application_pid" && break
    attempt=$((attempt + 1))
    sleep 0.1
done

if test -z "$application_pid"; then
    printf 'App bundle failed to launch: %s\n' "$app_bundle" >&2
    exit 1
fi

sleep 0.5
kill -0 "$application_pid"
printf 'App bundle build and launch smoke test passed: %s\n' "$app_bundle"
