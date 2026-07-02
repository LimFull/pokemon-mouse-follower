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

macOS 13 (Ventura)+ · Apple Silicon / Intel universal. Xcode / 개발자 도구 없이 바로 실행됩니다.

## 설치
1. \`${DMG}\` 다운로드 후 열기
2. **Pokémon Mouse Follower** 아이콘을 **Applications** 폴더로 드래그
3. Launchpad / 응용 프로그램에서 실행

## ⚠️ 처음 실행 시 (Gatekeeper 경고)
Apple 공증(notarization)을 받지 않은 ad-hoc 서명 앱이라, 처음 열 때 macOS Gatekeeper가 차단합니다. **악성 앱이라서가 아니라 서명 방식 때문**이며, 한 번만 허용하면 이후엔 그냥 실행됩니다.

- **macOS 13\\~14 (Ventura / Sonoma):** 응용 프로그램에서 앱을 **우클릭 → 열기 → 열기**. (더블클릭이 아니라 우클릭이어야 허용 버튼이 뜹니다.)
- **macOS 15 (Sequoia) 이상:** 우클릭이 안 통할 수 있습니다. 한 번 실행을 시도해 차단 경고를 띄운 뒤 **시스템 설정 → 개인정보 보호 및 보안** 맨 아래의 **\"확인 없이 열기 / Open Anyway\"** 를 누르세요.
- \"손상되었기 때문에 열 수 없습니다\" 라고 나오면 (다운로드 격리 속성 때문) 터미널에서:
  \`\`\`
  xattr -dr com.apple.quarantine /Applications/PokemonMouseFollower.app
  \`\`\`

경고 없이 실행되게 하려면 Apple Developer 서명 + 공증이 필요합니다 (향후 계획)."

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
