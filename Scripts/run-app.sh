#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
/bin/sh "$project_root/Scripts/build-app.sh"
app_bundle="$project_root/.build/EZ Tunnel.app"

open "$app_bundle"
