#!/bin/bash
# bundle.sh: makes dist/Sesame.app from the release build (run `swift build -c release` first).
# The app and the helper are signed ad hoc; only the app carries the entitlements file.
set -eu

project="$(cd "$(dirname "$0")/.." && pwd)"
bin="$(cd "$project" && swift build -c release --show-bin-path)"
app="$project/dist/Sesame.app"

for exe in Sesame SesameHelper; do
  [ -x "$bin/$exe" ] || { echo "missing $bin/$exe: run swift build -c release first" >&2; exit 1; }
done
[ -f "$project/Resources/AppIcon.icns" ] || { echo "missing $project/Resources/AppIcon.icns: run scripts/make-icon.swift" >&2; exit 1; }

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp "$project/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$project/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$bin/Sesame" "$app/Contents/MacOS/Sesame"
cp "$bin/SesameHelper" "$app/Contents/MacOS/SesameHelper"

codesign --force --sign - "$app/Contents/MacOS/SesameHelper"
codesign --force --sign - --entitlements "$project/Resources/Sesame.entitlements" "$app"
codesign --verify --strict "$app"

echo "made $app"
