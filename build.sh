#!/bin/bash
set -euo pipefail

# Build MouseFollower.app from source. No Xcode project needed.
#   ./build.sh            -> builds ./MouseFollower.app
#   ./build.sh install    -> builds, then copies to /Applications and launches it

cd "$(dirname "$0")"

APP_NAME="MouseFollower"
BUNDLE="${APP_NAME}.app"
EXEC="Sources/main.swift"

echo "==> Compiling (universal binary)..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

swiftc -O \
  -target arm64-apple-macosx13.0 \
  "$EXEC" -o "/tmp/${APP_NAME}_arm64"
swiftc -O \
  -target x86_64-apple-macosx13.0 \
  "$EXEC" -o "/tmp/${APP_NAME}_x86_64" 2>/dev/null || true

if [ -f "/tmp/${APP_NAME}_x86_64" ]; then
  lipo -create "/tmp/${APP_NAME}_arm64" "/tmp/${APP_NAME}_x86_64" \
    -output "$BUNDLE/Contents/MacOS/${APP_NAME}"
else
  cp "/tmp/${APP_NAME}_arm64" "$BUNDLE/Contents/MacOS/${APP_NAME}"
fi
rm -f "/tmp/${APP_NAME}_arm64" "/tmp/${APP_NAME}_x86_64"

cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "==> Bundling sprite assets..."
cp animations/007/Idle-Anim.png "$BUNDLE/Contents/Resources/"
cp animations/007/Walk-Anim.png "$BUNDLE/Contents/Resources/"

echo "==> Ad-hoc code signing..."
codesign --force --deep --sign - "$BUNDLE"

echo "==> Built ./$BUNDLE"

if [ "${1:-}" = "install" ]; then
  echo "==> Installing to /Applications..."
  rm -rf "/Applications/$BUNDLE"
  cp -R "$BUNDLE" "/Applications/"
  open "/Applications/$BUNDLE"
  echo "==> Installed and launched. Look for the 🐇 icon in the menu bar."
else
  echo "Run it with:  open ./$BUNDLE"
  echo "Or install:   ./build.sh install"
fi
