#!/bin/bash
set -euo pipefail

# Package PokemonMouseFollower.app into a .dmg and (optionally) publish a GitHub Release.
#   ./release.sh            -> builds .app, then ./PokemonMouseFollower-<version>.dmg
#   ./release.sh publish    -> also creates tag v<version> and uploads the .dmg to a GitHub Release

cd "$(dirname "$0")"

APP_NAME="PokemonMouseFollower"
BUNDLE="${APP_NAME}.app"
VOL_NAME="Pokémon Mouse Follower"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="${APP_NAME}-${VERSION}.dmg"
TAG="v${VERSION}"

# 1. Build a fresh universal, ad-hoc signed app bundle.
./build.sh

# 2. Stage the bundle plus an /Applications symlink for drag-to-install.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 3. Build a compressed disk image.
echo "==> Creating $DMG..."
rm -f "$DMG"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"

echo "==> Built ./$DMG"

if [ "${1:-}" != "publish" ]; then
  echo "Publish it with:  ./release.sh publish"
  exit 0
fi

# 4. Tag the release (skip if the tag already exists) and push it.
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "==> Tagging $TAG..."
  git tag "$TAG"
  git push origin "$TAG"
fi

# 5. Create or update the GitHub Release and upload the .dmg.
NOTES="Pokémon Mouse Follower ${VERSION}

macOS 13 (Ventura)+ · Apple Silicon / Intel universal.

## 설치
1. \`${DMG}\` 다운로드 후 열기
2. **Pokémon Mouse Follower** 아이콘을 **Applications** 폴더로 드래그
3. Launchpad/응용 프로그램에서 실행. ad-hoc 서명이라 처음엔 우클릭 → **열기** 한 번 필요

Xcode / 개발자 도구 없이 바로 실행됩니다."

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "==> Release $TAG exists; uploading asset..."
  gh release upload "$TAG" "$DMG" --clobber
else
  echo "==> Creating release $TAG..."
  gh release create "$TAG" "$DMG" \
    --title "Pokémon Mouse Follower ${VERSION}" \
    --notes "$NOTES"
fi

echo "==> Published: $(gh release view "$TAG" --json url --jq .url)"
