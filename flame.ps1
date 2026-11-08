# Flame mark, drawn from bezier curves in a 100x100 box. Shared by tray.ps1 and make-icon.ps1.
# Draw-Flame centres the flame on ($cx, $cy) and scales it to $size pixels tall.
function Draw-Flame($g, [float]$cx, [float]$cy, [float]$size, $outer, $inner) {
    $s = $size / 100
    $ox = $cx - 50 * $s; $oy = $cy - 50 * $s
    function Build([double[][]]$segs, [float]$ox, [float]$oy, [float]$s) {
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        foreach ($c in $segs) {
            $p.AddBezier(
                [float]($ox + $c[0] * $s), [float]($oy + $c[1] * $s), [float]($ox + $c[2] * $s), [float]($oy + $c[3] * $s),
                [float]($ox + $c[4] * $s), [float]($oy + $c[5] * $s), [float]($ox + $c[6] * $s), [float]($oy + $c[7] * $s))
        }
        $p.CloseFigure()
        return $p
    }
    $body = Build @(
        @(52, 0, 60, 25, 88, 38, 84, 66),
        @(84, 66, 82, 88, 66, 100, 50, 100),
        @(50, 100, 32, 100, 16, 88, 16, 66),
        @(16, 66, 16, 50, 26, 40, 34, 30),
        @(34, 30, 36, 42, 42, 46, 46, 48),
        @(46, 48, 40, 30, 44, 12, 52, 0)
    ) $ox $oy $s
    $core = Build @(
        @(50, 58, 56, 68, 66, 74, 64, 88),
        @(64, 88, 62, 95, 56, 98, 50, 98),
        @(50, 98, 44, 98, 38, 95, 36, 88),
        @(36, 88, 36, 76, 44, 70, 50, 58)
    ) $ox $oy $s
    $b = New-Object System.Drawing.SolidBrush $outer; $g.FillPath($b, $body); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush $inner; $g.FillPath($b, $core); $b.Dispose()
    $body.Dispose(); $core.Dispose()
}
