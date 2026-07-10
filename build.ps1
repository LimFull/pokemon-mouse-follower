# Build the Windows app from source (design/windows-port.md W1/W12).
#   .\build.ps1          -> builds .\build-win\PokemonMouseFollower\
#   .\build.ps1 run      -> builds, then launches it (console stays for logs)
#   .\build.ps1 dev      -> debug build + PMF_DEV=1 foreground run
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
$appName = "PokemonMouseFollower"
$outDir = Join-Path $PSScriptRoot "build-win\$appName"

Write-Host "==> Compiling (Sources/Core + Sources/Windows)..."
New-Item -ItemType Directory -Force $outDir | Out-Null
$sources = Get-ChildItem -Recurse "Sources\Core", "Sources\Windows" -Filter *.swift | ForEach-Object FullName
$swiftFlags = if ($mode -eq "dev") { @("-Onone", "-g") } else { @("-O") }
# Sources go through a UTF-8 response file (non-ASCII paths survive) and the
# compiler runs under cmd-level redirection: PowerShell 5.1's own stderr pipe
# handling can deadlock a captured native command mid-build.
$rsp = Join-Path $outDir "sources.rsp"
$sources | ForEach-Object { '"' + ($_ -replace '\\', '/') + '"' } | Set-Content -Path $rsp -Encoding UTF8
$log = Join-Path $outDir "build-log.txt"
cmd /c "swiftc $($swiftFlags -join ' ') @`"$rsp`" -o `"$outDir\$appName.exe`" >`"$log`" 2>&1"
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
}
