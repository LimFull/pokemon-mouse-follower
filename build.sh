#!/bin/bash
set -euo pipefail

# Build MouseFollower.app from source. No Xcode project needed.
#   ./build.sh            -> builds ./MouseFollower.app
#   ./build.sh install    -> builds, then copies to /Applications and launches it

cd "$(dirname "$0")"

APP_NAME="PokemonMouseFollower"
BUNDLE="${APP_NAME}.app"
# Compile every .swift under Sources/ (main + RaisingMode modules).
SWIFT_SOURCES=()
while IFS= read -r f; do SWIFT_SOURCES+=("$f"); done < <(find Sources -name '*.swift' | sort)

echo "==> Compiling (universal binary): ${#SWIFT_SOURCES[@]} source files..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

swiftc -O \
  -target arm64-apple-macosx13.0 \
  "${SWIFT_SOURCES[@]}" -o "/tmp/${APP_NAME}_arm64"
swiftc -O \
  -target x86_64-apple-macosx13.0 \
  "${SWIFT_SOURCES[@]}" -o "/tmp/${APP_NAME}_x86_64" 2>/dev/null || true

if [ -f "/tmp/${APP_NAME}_x86_64" ]; then
  lipo -create "/tmp/${APP_NAME}_arm64" "/tmp/${APP_NAME}_x86_64" \
    -output "$BUNDLE/Contents/MacOS/${APP_NAME}"
else
  cp "/tmp/${APP_NAME}_arm64" "$BUNDLE/Contents/MacOS/${APP_NAME}"
fi
rm -f "/tmp/${APP_NAME}_arm64" "/tmp/${APP_NAME}_x86_64"

cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "==> Bundling sprite assets..."
rm -rf "$BUNDLE/Contents/Resources/characters"
mkdir -p "$BUNDLE/Contents/Resources/characters"
cp -R animations/* "$BUNDLE/Contents/Resources/characters/"

echo "==> Bundling localizations..."
cp -R Localizable/*.lproj "$BUNDLE/Contents/Resources/"

echo "==> Bundling app icon..."
cp icon/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Bundling game data..."
rm -rf "$BUNDLE/Contents/Resources/gamedata"
cp -R gamedata "$BUNDLE/Contents/Resources/gamedata"

echo "==> Ad-hoc code signing..."
codesign --force --deep --sign - "$BUNDLE"

echo "==> Built ./$BUNDLE"

if [ "${1:-}" = "install" ]; then
  echo "==> Installing to /Applications..."
  rm -rf "/Applications/$BUNDLE"
  cp -R "$BUNDLE" "/Applications/"
  open "/Applications/$BUNDLE"
  echo "==> Installed and launched. Look for the 🐾 icon in the menu bar."
else
  echo "Run it with:  open ./$BUNDLE"
  echo "Or install:   ./build.sh install"
fi
