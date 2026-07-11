# Build the Windows app from source (design/windows-port.md W1/W12).
#   .\build.ps1          -> builds .\build-win\PokemonMouseFollower\
#   .\build.ps1 run      -> builds, then launches it (console stays for logs)
#   .\build.ps1 dev      -> debug build + PMF_DEV=1 foreground run
#   .\build.ps1 ci       -> debug build only (console subsystem, no launch)
#   .\build.ps1 package  -> release build + zip + installer (needs Inno Setup)
#
# Prereqs: VS Build Tools 2022 (MSVC + Windows SDK) and the Swift toolchain
# (winget install Swift.Toolchain). See spike/windows-phase0/README.md.

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# Locate the Swift toolchain when it isn't on PATH yet (fresh install).
if (-not (Get-Command swiftc -ErrorAction SilentlyContinue)) {
    $toolchains = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Toolchains" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    $runtimes = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if (-not $toolchains -or -not $runtimes) {
        Write-Error "Swift toolchain not found. Install with: winget install Swift.Toolchain"
    }
    $env:Path = "$($toolchains[0].FullName)\usr\bin;$($runtimes[0].FullName)\usr\bin;" + $env:Path
    $platforms = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Platforms" -Directory | Sort-Object Name -Descending
    $env:SDKROOT = "$($platforms[0].FullName)\Windows.platform\Developer\SDKs\Windows.sdk\"
}

$mode = if ($args.Count -gt 0) { $args[0] } else { "" }

# Release packages must include the ROM-extracted effect sprites (never
# committed — rebuild with rom-extract\build_effects.py). Dev/CI builds may
# run without them (move effects just don't render).
if ($mode -eq "package" -and -not (Test-Path "gamedata\effects")) {
    Write-Error "gamedata\effects\ missing - run rom-extract\build_effects.py first (see gamedata\README.md)"
}

$appName = "PokemonMouseFollower"
$outDir = Join-Path $PSScriptRoot "build-win\$appName"

New-Item -ItemType Directory -Force $outDir | Out-Null

# Windows version source (W16) — independent of the macOS Info.plist version.
$version = (Select-String -Path "Sources\Core\Version.swift" -Pattern 'static let string = "([^"]+)"').Matches[0].Groups[1].Value
Write-Host "==> Version $version"

# Icon + VERSIONINFO + manifest resource (W17). rc.exe ships with the SDK.
$rcExe = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\rc.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
$resFile = $null
if ($rcExe) {
    if (-not (Test-Path "res\app.ico")) { & .\icon\make-ico.ps1 }
    $rcText = (Get-Content "res\PokemonMouseFollower.rc.in" -Raw) `
        -replace '@VERSION_COMMA@', ($version -replace '\.', ',') `
        -replace '@VERSION@', $version
    Set-Content -Path "res\PokemonMouseFollower.rc" -Value $rcText -Encoding ASCII
    $resFile = Join-Path $outDir "PokemonMouseFollower.res"
    & $rcExe.FullName /nologo /fo $resFile "res\PokemonMouseFollower.rc"
    if ($LASTEXITCODE -ne 0) { Write-Error "rc.exe failed" }
} else {
    Write-Warning "rc.exe not found - building without icon/version/manifest resources"
}

Write-Host "==> Compiling (Sources/Core + Sources/Windows)..."
$sources = Get-ChildItem -Recurse "Sources\Core", "Sources\Windows" -Filter *.swift | ForEach-Object FullName
$debugFlavor = $mode -eq "dev" -or $mode -eq "ci"
# [string[]] keeps += as array append (PS unwraps 1-element arrays otherwise).
[string[]]$swiftFlags = if ($debugFlavor) { @("-Onone", "-g") } else { @("-O") }
if ($resFile) { $swiftFlags += @("-Xlinker", $resFile) }
if (-not $debugFlavor) {
    # Release: GUI subsystem (no console window). Dev/CI keep the console for logs.
    $swiftFlags += @("-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup")
}
# Flags + sources go through a UTF-8 response file (non-ASCII paths survive)
# and the compiler runs under cmd-level redirection: PowerShell 5.1's own
# stderr pipe handling can deadlock a captured native command mid-build.
$rsp = Join-Path $outDir "sources.rsp"
$rspLines = @($swiftFlags) + @($sources) |
    ForEach-Object { '"' + ($_ -replace '\\', '/') + '"' }
# BOM-less UTF-8: the driver forwards the first token to the linker verbatim,
# and a BOM turns "-O" into an unknown input file.
[System.IO.File]::WriteAllLines($rsp, [string[]]$rspLines,
                                (New-Object System.Text.UTF8Encoding($false)))
$log = Join-Path $outDir "build-log.txt"
cmd /c "swiftc @`"$rsp`" -o `"$outDir\$appName.exe`" >`"$log`" 2>&1"
$exit = $LASTEXITCODE
Get-Content $log -ErrorAction SilentlyContinue | Write-Host
if ($exit -ne 0) { Write-Error "swiftc failed (exit $exit) — see $log" }

Write-Host "==> Bundling the Swift runtime DLLs..."
$runtimes = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
if ($runtimes) {
    Copy-Item "$($runtimes[0].FullName)\usr\bin\*.dll" $outDir -Force
} else {
    Write-Warning "Swift runtime not found - the exe will need the runtime on PATH"
}

Write-Host "==> Staging resources next to the exe..."
if (Test-Path "$outDir\characters") { Remove-Item -Recurse -Force "$outDir\characters" }
New-Item -ItemType Directory -Force "$outDir\characters" | Out-Null
Copy-Item -Recurse animations\* "$outDir\characters\"
if (Test-Path "$outDir\gamedata") { Remove-Item -Recurse -Force "$outDir\gamedata" }
Copy-Item -Recurse gamedata "$outDir\gamedata"
Get-ChildItem Localizable -Directory | ForEach-Object {
    if (Test-Path "$outDir\$($_.Name)") { Remove-Item -Recurse -Force "$outDir\$($_.Name)" }
    Copy-Item -Recurse $_.FullName "$outDir\$($_.Name)"
}

Write-Host "==> Built $outDir"

if ($mode -eq "run") {
    & "$outDir\$appName.exe"
} elseif ($mode -eq "dev") {
    $env:PMF_DEV = "1"
    & "$outDir\$appName.exe"
} elseif ($mode -eq "package") {
    Write-Host "==> Zipping portable build..."
    Remove-Item "$outDir\build-log.txt", "$outDir\build-err.txt", "$outDir\sources.rsp",
                "$outDir\$appName.lib", "$outDir\$appName.exp", "$outDir\$appName.res" -ErrorAction SilentlyContinue
    $zip = "build-win\PokemonMouseFollower-$version-windows.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path $outDir -DestinationPath $zip
    Write-Host "==> $zip"

    $iscc = Get-Command iscc -ErrorAction SilentlyContinue
    if (-not $iscc) {
        foreach ($p in "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
                       "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") {
            if (Test-Path $p) { $iscc = Get-Command $p; break }
        }
    }
    if ($iscc) {
        Write-Host "==> Building installer..."
        & $iscc.Source /Qp "/DMyAppVersion=$version" installer.iss
        if ($LASTEXITCODE -ne 0) { Write-Error "iscc failed" }
        Write-Host "==> build-win\PokemonMouseFollower-Setup.exe"
    } else {
        Write-Warning "Inno Setup (iscc) not found - skipped the installer. winget install JRSoftware.InnoSetup"
    }
}
