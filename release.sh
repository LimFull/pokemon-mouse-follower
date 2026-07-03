#!/bin/bash
set -euo pipefail

# Package PokemonMouseFollower.app into a .dmg and (optionally) publish a GitHub Release.
#   ./release.sh            -> builds .app, then ./PokemonMouseFollower-<version>.dmg
#   ./release.sh publish    -> also creates tag v<version> and uploads the .dmg to a GitHub Release
#
# If a "Developer ID Application" certificate is present, the app + dmg are
# Developer ID signed (hardened runtime) and notarized+stapled, so they open
# with no Gatekeeper warning. Otherwise it falls back to the ad-hoc signature
# from build.sh (works, but shows the "unidentified developer" prompt once).
#
# Notarization also needs a stored notarytool profile named below. Create it once:
#   xcrun notarytool store-credentials "PMF_NOTARY" \
#     --apple-id "<apple-id-email>" --team-id FNR6P532UM --password "<app-specific-password>"

cd "$(dirname "$0")"

APP_NAME="PokemonMouseFollower"
BUNDLE="${APP_NAME}.app"
VOL_NAME="Pokémon Mouse Follower"
NOTARY_PROFILE="PMF_NOTARY"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="${APP_NAME}-${VERSION}.dmg"
STABLE_DMG="${APP_NAME}.dmg"   # version-less copy for a stable /releases/latest/download/ link
TAG="v${VERSION}"

# 1. Build a fresh universal app bundle (build.sh ad-hoc signs it).
./build.sh

# 2. If a Developer ID cert is available, re-sign + notarize + staple the app.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
          | grep -o 'Developer ID Application: [^"]*' | head -1 || true)
NOTARIZED=0
if [ -n "$SIGN_ID" ]; then
  echo "==> Developer ID signing ($SIGN_ID) with hardened runtime..."
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$BUNDLE"

  echo "==> Notarizing app (this can take a minute)..."
  APP_ZIP=$(mktemp -u).zip
  ditto -c -k --keepParent "$BUNDLE" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$APP_ZIP"
  xcrun stapler staple "$BUNDLE"
  NOTARIZED=1
else
  echo "==> No Developer ID cert found; keeping ad-hoc signature (Gatekeeper prompt on first open)."
fi

# 3. Stage the bundle plus an /Applications symlink for drag-to-install.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 4. Build a compressed disk image.
echo "==> Creating $DMG..."
rm -f "$DMG"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"

# 5. Notarize + staple the dmg itself so the download opens cleanly too.
if [ "$NOTARIZED" = 1 ]; then
  echo "==> Notarizing dmg..."
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "==> Verifying..."
  spctl -a -vv "$BUNDLE" || true          # expect: accepted, source=Notarized Developer ID
  xcrun stapler validate "$DMG" || true
fi

# Version-less copy (already notarized/stapled if the original is) so the site can
# link to a stable .../releases/latest/download/PokemonMouseFollower.dmg URL.
cp -f "$DMG" "$STABLE_DMG"

echo "==> Built ./$DMG (and ./$STABLE_DMG)"

if [ "${1:-}" != "publish" ]; then
  echo "Publish it with:  ./release.sh publish"
  exit 0
fi

# 6. Tag the release (skip if the tag already exists) and push it.
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "==> Tagging $TAG..."
  git tag "$TAG"
  git push origin "$TAG"
fi

# 7. Release notes: clean when notarized, Gatekeeper workaround when ad-hoc.
INSTALL="## 설치
1. \`${DMG}\` 다운로드 후 열기
2. **Pokémon Mouse Follower** 아이콘을 **Applications** 폴더로 드래그
3. Launchpad / 응용 프로그램에서 실행"

if [ "$NOTARIZED" = 1 ]; then
  NOTES="Pokémon Mouse Follower ${VERSION}

macOS 13 (Ventura)+ · Apple Silicon / Intel universal.
Apple Developer 서명 + 공증(notarized) 완료 — Gatekeeper 경고 없이 바로 실행됩니다.

${INSTALL}"
else
  NOTES="Pokémon Mouse Follower ${VERSION}

macOS 13 (Ventura)+ · Apple Silicon / Intel universal. Xcode / 개발자 도구 없이 바로 실행됩니다.

${INSTALL}

## ⚠️ 처음 실행 시 (Gatekeeper 경고)
Apple 공증(notarization)을 받지 않은 ad-hoc 서명 앱이라, 처음 열 때 macOS Gatekeeper가 차단합니다. **악성 앱이라서가 아니라 서명 방식 때문**이며, 한 번만 허용하면 이후엔 그냥 실행됩니다.

- **macOS 13\\~14 (Ventura / Sonoma):** 응용 프로그램에서 앱을 **우클릭 → 열기 → 열기**. (더블클릭이 아니라 우클릭이어야 허용 버튼이 뜹니다.)
- **macOS 15 (Sequoia) 이상:** 우클릭이 안 통할 수 있습니다. 한 번 실행을 시도해 차단 경고를 띄운 뒤 **시스템 설정 → 개인정보 보호 및 보안** 맨 아래의 **\"확인 없이 열기 / Open Anyway\"** 를 누르세요.
- \"손상되었기 때문에 열 수 없습니다\" 라고 나오면 (다운로드 격리 속성 때문) 터미널에서:
  \`\`\`
  xattr -dr com.apple.quarantine /Applications/PokemonMouseFollower.app
  \`\`\`"
fi

# 8. Create or update the GitHub Release and upload the .dmg.
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "==> Release $TAG exists; uploading assets..."
  gh release upload "$TAG" "$DMG" "$STABLE_DMG" --clobber
else
  echo "==> Creating release $TAG..."
  gh release create "$TAG" "$DMG" "$STABLE_DMG" \
    --title "Pokémon Mouse Follower ${VERSION}" \
    --notes "$NOTES"
fi

echo "==> Published: $(gh release view "$TAG" --json url --jq .url)"
