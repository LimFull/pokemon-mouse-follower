#!/bin/bash
set -euo pipefail

# Fast dev loop: compile (arm64 only, no signing) and run in the foreground.
# Logs print to this terminal; press Ctrl+C to quit the app.

cd "$(dirname "$0")"

APP_NAME="MouseFollower"
BUNDLE="${APP_NAME}.app"

# Stop any running instance so we don't stack characters.
pkill -x "$APP_NAME" 2>/dev/null || true

# Make sure the bundle scaffolding (Info.plist + sprite Resources) exists.
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp animations/007/Idle-Anim.png "$BUNDLE/Contents/Resources/"
cp animations/007/Walk-Anim.png "$BUNDLE/Contents/Resources/"

echo "==> Compiling (arm64, debug)..."
swiftc -Onone -g Sources/main.swift -o "$BUNDLE/Contents/MacOS/${APP_NAME}"

echo "==> Running in foreground (Ctrl+C to quit). Logs below:"
echo "-------------------------------------------------------"
exec "$BUNDLE/Contents/MacOS/${APP_NAME}"
