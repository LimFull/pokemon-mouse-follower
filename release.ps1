# Package the Windows build and (optionally) publish it to a GitHub Release.
#   .\release.ps1            -> builds build-win\...-windows.zip + Setup.exe
#   .\release.ps1 publish    -> also creates tag v<version> and uploads both
#
# Windows counterpart of release.sh. Must run on a real Windows PC with the
# ROM-extracted effect sprites present (gamedata\effects\ — rebuild with
# rom-extract\build_effects.py); CI cannot build releases because those
# sprites are never committed (see gamedata\README.md).
#
# The Windows version lives in Sources\Core\Version.swift and is managed
# independently of the macOS version (Info.plist / release.sh). A release for
# one OS never affects the other: the site download buttons and both in-app
# updaters resolve the newest release that ships their platform's asset, and
# when both OSes use the same version number they share the vX.Y.Z tag.
#
# Requires the gh CLI logged in to an account with push access (LimFull).

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# The whole point of releasing from a real PC: the ROM-extracted sprites.
if (-not (Test-Path "gamedata\effects")) {
    Write-Error "gamedata\effects\ missing - run rom-extract\build_effects.py first (see gamedata\README.md)"
}

$version = (Select-String -Path "Sources\Core\Version.swift" -Pattern 'static let string = "([^"]+)"').Matches[0].Groups[1].Value
$tag = "v$version"

.\build.ps1 package

$zip = (Get-Item "build-win\PokemonMouseFollower-$version-windows.zip").FullName
$setup = (Get-Item "build-win\PokemonMouseFollower-Setup.exe").FullName

if ($args.Count -eq 0 -or $args[0] -ne "publish") {
    Write-Host "==> Built:"
    Write-Host "      $zip"
    Write-Host "      $setup"
    Write-Host "Publish with:  .\release.ps1 publish"
    exit 0
}

# Tag: the tag may already exist remotely (e.g. minted by the macOS release
# of the same version) — adopt it instead of creating a conflicting one.
cmd /c "git rev-parse -q --verify $tag >nul 2>nul"
if ($LASTEXITCODE -ne 0) {
    cmd /c "git fetch origin refs/tags/${tag}:refs/tags/${tag} >nul 2>nul"
}
cmd /c "git rev-parse -q --verify $tag >nul 2>nul"
if ($LASTEXITCODE -ne 0) {
    Write-Host "==> Tagging $tag..."
    git tag $tag
    git push origin $tag
    if ($LASTEXITCODE -ne 0) { Write-Error "git push failed" }
}

$notes = @'
Pokémon Mouse Follower {VERSION} (Windows)

Windows 10+ · x64.

## 설치
1. `PokemonMouseFollower-Setup.exe` 다운로드 후 실행 (무설치를 원하면 `-windows.zip`)
2. SmartScreen 경고가 뜨면 **추가 정보 → 실행**을 누르세요 — 코드 서명이 없어 뜨는 경고입니다
'@.Replace("{VERSION}", $version)

# Create or update the GitHub Release and upload both assets.
cmd /c "gh release view $tag >nul 2>nul"
if ($LASTEXITCODE -eq 0) {
    Write-Host "==> Release $tag exists; uploading assets..."
    gh release upload $tag $zip $setup --clobber
} else {
    Write-Host "==> Creating release $tag..."
    gh release create $tag $zip $setup --title "Pokémon Mouse Follower $version" --notes $notes
}
if ($LASTEXITCODE -ne 0) { Write-Error "gh release failed" }
Write-Host "==> Published: https://github.com/LimFull/pokemon-mouse-follower/releases/tag/$tag"
