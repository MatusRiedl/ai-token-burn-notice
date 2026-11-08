# Regenerates assets\flame.ico from flame.ps1 (PNG-compressed entries, 16-256 px). Dev tool; the .ico is committed.
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'flame.ps1')
$ico = Join-Path $PSScriptRoot 'assets\flame.ico'
$outer = [System.Drawing.ColorTranslator]::FromHtml('#d97757')
$inner = [System.Drawing.ColorTranslator]::FromHtml('#f6c3a6')

$pngs = foreach ($size in 16, 24, 32, 48, 256) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    Draw-Flame $g ($size / 2) ($size / 2) ($size * 0.94) $outer $inner
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    , @($size, $ms.ToArray())
}

$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $out
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$pngs.Count)
$offset = 6 + 16 * $pngs.Count
foreach ($p in $pngs) {
    $s = if ($p[0] -ge 256) { 0 } else { $p[0] }
    $bw.Write([byte]$s); $bw.Write([byte]$s); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$p[1].Length); $bw.Write([uint32]$offset)
    $offset += $p[1].Length
}
foreach ($p in $pngs) { $bw.Write([byte[]]$p[1]) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($ico, $out.ToArray())
Get-Item $ico | Select-Object FullName, Length
