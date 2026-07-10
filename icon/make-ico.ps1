# Build res/app.ico from icon/icon-1024.png (design/windows-port.md W17).
# ICO container with PNG-compressed entries (supported since Vista) at the
# sizes Windows actually samples for the shell, taskbar and tray.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$srcPath = Join-Path $PSScriptRoot "icon-1024.png"
$outPath = Join-Path $PSScriptRoot "..\res\app.ico"
New-Item -ItemType Directory -Force (Split-Path $outPath) | Out-Null

$sizes = 16, 20, 24, 32, 48, 64, 128, 256
$src = [System.Drawing.Image]::FromFile($srcPath)

$pngs = @()
foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($src, 0, 0, $s, $s)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $pngs += , @($s, $ms.ToArray())
}
$src.Dispose()

$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([UInt16]0)               # reserved
$w.Write([UInt16]1)               # type: icon
$w.Write([UInt16]$pngs.Count)     # image count
$offset = 6 + 16 * $pngs.Count
foreach ($entry in $pngs) {
    $s = $entry[0]; $data = $entry[1]
    $w.Write([Byte]($(if ($s -ge 256) { 0 } else { $s })))   # width (0 = 256)
    $w.Write([Byte]($(if ($s -ge 256) { 0 } else { $s })))   # height
    $w.Write([Byte]0)             # palette
    $w.Write([Byte]0)             # reserved
    $w.Write([UInt16]1)           # planes
    $w.Write([UInt16]32)          # bpp
    $w.Write([UInt32]$data.Length)
    $w.Write([UInt32]$offset)
    $offset += $data.Length
}
foreach ($entry in $pngs) { $w.Write($entry[1]) }
[System.IO.File]::WriteAllBytes($outPath, $out.ToArray())
Write-Host "wrote $outPath ($($out.Length) bytes, $($pngs.Count) sizes)"
