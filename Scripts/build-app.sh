#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$project" -c release >&2
binary="$(swift build --package-path "$project" -c release --show-bin-path)/MenuBarProbe"
stage="$(mktemp -d "$project/.build/app.XXXXXX")"
app="$stage/Full Screen Bar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$stage/AppIcon.iconset"
cp "$project/Scripts/Info.plist" "$app/Contents/Info.plist"
cp "$binary" "$app/Contents/MacOS/MenuBarProbe"
swift "$project/Scripts/MakeIcon.swift" "$stage/AppIcon.iconset"
iconutil -c icns "$stage/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
