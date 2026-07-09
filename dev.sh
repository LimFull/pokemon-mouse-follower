#!/bin/bash
set -euo pipefail

# Fast dev loop: compile (arm64 only, no signing) and run in the foreground.
# Logs print to this terminal; press Ctrl+C to quit the app.

cd "$(dirname "$0")"

APP_NAME="PokemonMouseFollower"
BUNDLE="${APP_NAME}.app"

# Stop any running instance so we don't stack characters.
pkill -x "$APP_NAME" 2>/dev/null || true

# Make sure the bundle scaffolding (Info.plist + sprite Resources) exists.
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp Info.plist "$BUNDLE/Contents/Info.plist"
rm -rf "$BUNDLE/Contents/Resources/characters"
mkdir -p "$BUNDLE/Contents/Resources/characters"
cp -R animations/* "$BUNDLE/Contents/Resources/characters/"
cp -R Localizable/*.lproj "$BUNDLE/Contents/Resources/"
cp icon/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cp icon/backpack.svg "$BUNDLE/Contents/Resources/backpack.svg"   # bag header (Lucide, ISC)
rm -rf "$BUNDLE/Contents/Resources/gamedata"
cp -R gamedata "$BUNDLE/Contents/Resources/gamedata"

echo "==> Compiling (arm64, debug)..."
SWIFT_SOURCES=()
while IFS= read -r f; do SWIFT_SOURCES+=("$f"); done < <(find Sources -name '*.swift' | sort)
swiftc -Onone -g "${SWIFT_SOURCES[@]}" -o "$BUNDLE/Contents/MacOS/${APP_NAME}"

echo "==> Running in foreground (Ctrl+C to quit). Logs below:"
echo "-------------------------------------------------------"
# PMF_DEV exposes the status-bar debug submenu (release builds hide it).
PMF_DEV=1 exec "$BUNDLE/Contents/MacOS/${APP_NAME}"
