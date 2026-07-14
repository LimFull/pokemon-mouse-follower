#!/bin/bash
set -euo pipefail

# Build MouseFollower.app from source. No Xcode project needed.
#   ./build.sh            -> builds ./MouseFollower.app
#   ./build.sh install    -> builds, then copies to /Applications and launches it

cd "$(dirname "$0")"

APP_NAME="PokemonMouseFollower"
BUNDLE="${APP_NAME}.app"
# Compile the platform-neutral core + the macOS layer (Sources/Windows is
# built by build.ps1 on Windows — design/windows-port.md W1).
SWIFT_SOURCES=()
while IFS= read -r f; do SWIFT_SOURCES+=("$f"); done < <(find Sources/Core Sources/macOS -name '*.swift' | sort)

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

# Move playback needs each species' ROM caster-pose sheets (Swing/Double/Hop/
# Rotate/Strike & their CopyOf targets) on top of the walk/idle set — for both
# the base folder and its alt-color variant. They're committed, but a partial
# checkout can miss them, and it only shows up mid-move: a plain gap (base) or a
# wrong-color sprite when alt-color is on (altcolor -> base fallback in
# FollowerBrain.romSheet). Fetch on demand so a build is never silently short a
# sprite.
echo "==> Verifying sprite assets (fetch on demand)..."
# Base poses: this fetcher self-scans and downloads only what's missing (a no-op
# with no network when complete), so it's safe to run every build.
./fetch-rom-pose-anims.sh
# Alt-color poses: fetch-altcolors.sh re-pulls its whole whitelist over the
# network, so only run it when a variant is actually missing a ROM caster-pose
# sheet. We check exactly the move-pose set (indices 2/8/9/10/11/12, CopyOf-
# resolved from each variant's own AnimData.xml) — NOT every base sheet, since a
# few forms legitimately lack a Faint sheet upstream and would otherwise trip the
# fetch on every build.
if ! python3 - <<'PY'
import re, os, sys, glob
NEED = {2, 8, 9, 10, 11, 12}
def pose_sheets(xml):
    anims = {}
    for m in re.finditer(r'<Anim>\s*<Name>(\w+)</Name>(?:\s*<Index>(-?\d+)</Index>)?'
                         r'(?:\s*<CopyOf>(\w+)</CopyOf>)?', xml):
        anims[m.group(1)] = (int(m.group(2)) if m.group(2) else None, m.group(3))
    byidx = {idx: name for name, (idx, _) in anims.items() if idx is not None}
    for idx in NEED:
        name = byidx.get(idx)
        if not name:
            continue
        seen, target = set(), name           # follow CopyOf to the shipped sheet
        while anims.get(target, (None, None))[1] and target not in seen:
            seen.add(target)
            target = anims[target][1]
        yield target
for xmlp in glob.glob('animations/*/altcolor/AnimData.xml'):
    d = os.path.dirname(xmlp)
    for name in pose_sheets(open(xmlp).read()):
        if not os.path.isfile(f'{d}/{name}-Anim.png'):
            sys.exit(1)                       # a variant is missing a pose sheet
sys.exit(0)
PY
then
  echo "  alt-color variants missing pose sheets -> ./fetch-altcolors.sh"
  ./fetch-altcolors.sh
fi

echo "==> Bundling sprite assets..."
rm -rf "$BUNDLE/Contents/Resources/characters"
mkdir -p "$BUNDLE/Contents/Resources/characters"
cp -R animations/* "$BUNDLE/Contents/Resources/characters/"

echo "==> Bundling localizations..."
cp -R Localizable/*.lproj "$BUNDLE/Contents/Resources/"

echo "==> Bundling app icon..."
cp icon/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cp icon/backpack.svg "$BUNDLE/Contents/Resources/backpack.svg"   # bag header (Lucide, ISC)

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
