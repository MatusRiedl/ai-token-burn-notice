# AI Burn Notice: tray icon. Hover: week % / today / past hour summary. Click: dark panel
# (weekly plan budget in 7 day slots; 1h, 6h, 24h, 7d, 30d totals, token mix, per-model share and estimated cost).
# Data comes from aggregate.js (reads ~/.claude/projects logs). Launch hidden via start.vbs; -show opens the panel.

# Single instance. Launching again (e.g. from the desktop shortcut) asks the running tray to open its panel.
# Snapshot runs may coexist with it.
$snapshot = $args -contains '-snapshot'
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\AIBurnNotice', [ref]$createdNew)
$showEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\AIBurnNotice.Show')
if (-not $createdNew -and -not $snapshot) { [void]$showEvent.Set(); exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Borderless, double-buffered form with Windows 11 rounded corners + dark frame.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class UsageForm : Form {
    public DateTime HiddenAt = DateTime.MinValue;
    // Hide when focus moves away. Done here, not in a PowerShell Deactivate handler:
    // that handler failed with "no Runspace available to run scripts in this thread".
    protected override void OnDeactivate(EventArgs e) { base.OnDeactivate(e); HiddenAt = DateTime.Now; Hide(); }
    // Log UI-thread exceptions instead of showing the .NET "Unhandled exception" dialog.
    public static void LogExceptionsTo(string path) {
        Application.ThreadException += (s, e) => {
            try { File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  exception: " + e.Exception.Message + Environment.NewLine); } catch { }
        };
    }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    public UsageForm() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        KeyPreview = true;
        TopMost = true;
    }
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        int round = 2; DwmSetWindowAttribute(Handle, 33, ref round, 4); // DWMWA_WINDOW_CORNER_PREFERENCE = ROUND
        int dark = 1;  DwmSetWindowAttribute(Handle, 20, ref dark, 4);  // DWMWA_USE_IMMERSIVE_DARK_MODE
    }
}
'@

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = if ($env:BURN_NOTICE_DATA) { $env:BURN_NOTICE_DATA } else { Join-Path $env:LOCALAPPDATA 'AIBurnNotice' }
[void](New-Item -ItemType Directory -Force -Path $dataDir)
$usageFile = Join-Path $dataDir 'usage.json'
$aggScript = Join-Path $here 'aggregate.js'
$calibFile = Join-Path $dataDir 'calibration.json'
$logFile = Join-Path $dataDir 'tray.log'
$iconFile = Join-Path $here 'assets\flame.ico'
$refreshMinutes = 5
# Start/stop lines, so an unexpected exit shows up as a start with no matching stop
function Write-Log([string]$m) { try { Add-Content -Path $logFile -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + "  $m") } catch {} }
# BURN_NOTICE_NOW (ISO time) pins the clock for README screenshots made from demo data
function Get-Now { if ($env:BURN_NOTICE_NOW) { [datetime]::Parse($env:BURN_NOTICE_NOW, [Globalization.CultureInfo]::InvariantCulture) } else { Get-Date } }

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
$node = if ($nodeCmd) { $nodeCmd.Source } else { 'C:\Program Files\nodejs\node.exe' }

# ---- Palette and type (warm dark theme) ----
function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
$col = @{
    side = C '#1f1f1e'; main = C '#1a1a19'; line = C '#2e2e2c'
    sel = C '#2d2d2b'; hover = C '#262625'; card = C '#222221'; track = C '#2f2f2d'
    text = C '#ececea'; text2 = C '#c2c0b6'; muted = C '#8e8c85'; accent = C '#d97757'; over = C '#e5534b'
}
$families = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object Name
$ff = if ($families -contains 'Segoe UI Variable Text') { 'Segoe UI Variable Text' } else { 'Segoe UI' }
$ffd = if ($families -contains 'Segoe UI Variable Display') { 'Segoe UI Variable Display' } else { 'Segoe UI' }
function F([string]$fam, [float]$px, [string]$style = 'Regular') {
    New-Object System.Drawing.Font($fam, $px, [System.Drawing.FontStyle]$style, [System.Drawing.GraphicsUnit]::Pixel)
}
$font = @{
    title = F $ffd 16 'Bold'; item = F $ff 14.5; small = F $ff 12.5; tiny = F $ff 11.5
    label = F $ff 12.5; big = F $ffd 38 'Bold'; bigUnit = F $ff 16; cost = F $ffd 26 'Bold'
    chipVal = F $ffd 17 'Bold'; row = F $ff 14; rowB = F $ff 14 'Bold'
}

function Format-Tokens([double]$n) {
    if ($n -ge 1e9) { return ('{0:0.00}B' -f ($n / 1e9)) }
    if ($n -ge 1e6) { return ('{0:0.0}M' -f ($n / 1e6)) }
    if ($n -ge 1e3) { return ('{0:0.0}k' -f ($n / 1e3)) }
    return ('{0:0}' -f $n)
}
$dot = [string][char]0x00B7
# opus-5-5 -> Opus 5.5, haiku-4-5 -> Haiku 4.5
function Format-Model([string]$m) {
    $p = $m -split '-'
    if ($p.Count -lt 2) { return $m }
    return (Get-Culture).TextInfo.ToTitleCase($p[0]) + ' ' + ($p[1..($p.Count - 1)] -join '.')
}
function Format-Cost($t) {
    $s = '$' + ('{0:N2}' -f [double]$t.cost)
    if ($t.unpriced) { $s += '*' }
    return $s
}
function Format-Span([TimeSpan]$ts) {
    if ($ts.TotalMinutes -lt 1) { return 'now' }
    if ($ts.TotalDays -ge 1) { return ('{0}d {1}h' -f [math]::Floor($ts.TotalDays), $ts.Hours) }
    if ($ts.TotalHours -ge 1) { return ('{0}h {1}m' -f $ts.Hours, $ts.Minutes) }
    return ('{0}m' -f $ts.Minutes)
}
$inv = [Globalization.CultureInfo]::InvariantCulture
function From-Ms($ms) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ms).LocalDateTime }
# Index of the day slot containing now (-1 once the week has rolled over before the next refresh)
function Get-TodayIndex($wk) {
    $now = Get-Now
    if ($now -ge (From-Ms $wk.end)) { return -1 }
    $ti = -1
    $days = @($wk.days)
    for ($i = 0; $i -lt $days.Count; $i++) { if ((From-Ms $days[$i].start) -le $now) { $ti = $i } }
    return $ti
}

# ---- Drawing helpers ----
function RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); return $p
}
function Fill-Round($g, $color, $x, $y, $w, $h, $r) {
    $b = New-Object System.Drawing.SolidBrush $color; $p = RoundRect $x $y $w $h $r
    $g.FillPath($b, $p); $b.Dispose(); $p.Dispose()
}
function Stroke-Round($g, $color, $x, $y, $w, $h, $r) {
    $pen = New-Object System.Drawing.Pen $color; $p = RoundRect $x $y $w $h $r
    $g.DrawPath($pen, $p); $pen.Dispose(); $p.Dispose()
}
$tfLeft = [System.Windows.Forms.TextFormatFlags]'NoPadding, SingleLine, NoPrefix'
$tfRight = [System.Windows.Forms.TextFormatFlags]'NoPadding, SingleLine, NoPrefix, Right'
function Text($g, [string]$s, $f, $color, [int]$x, [int]$y) {
    [System.Windows.Forms.TextRenderer]::DrawText($g, $s, $f, (New-Object System.Drawing.Point($x, $y)), $color, $tfLeft)
}
function TextR($g, [string]$s, $f, $color, [int]$right, [int]$y) {
    # Right-aligned so the text ends at x = $right
    [System.Windows.Forms.TextRenderer]::DrawText($g, $s, $f, (New-Object System.Drawing.Rectangle(($right - 400), $y, 400, 60)), $color, $tfRight)
}
function TextW([string]$s, $f) { [System.Windows.Forms.TextRenderer]::MeasureText($s, $f, (New-Object System.Drawing.Size(2000, 100)), $tfLeft).Width }

. (Join-Path $here 'flame.ps1')
$col.flame = C '#f6c3a6'

function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    Draw-Flame $g 16 16 30 $col.accent $col.flame
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# ---- State ----
$script:data = $null
$script:sel = -1         # -1 = weekly usage, 0.. = window index
$script:calErr = $false
$script:editing = $false   # % entry box open (Control.Visible reads false while the form is hidden)
$script:hover = $null
$script:hits = New-Object System.Collections.ArrayList
$script:proc = $null
$W = 780; $SIDE = 210

[UsageForm]::LogExceptionsTo($logFile)
$form = New-Object UsageForm
$form.Text = 'AI Burn Notice'
$form.BackColor = $col.main
$form.Size = New-Object System.Drawing.Size($W, 480)

function Add-Hit([int]$x, [int]$y, [int]$w, [int]$h, [string]$action) {
    [void]$script:hits.Add(@{ R = (New-Object System.Drawing.Rectangle($x, $y, $w, $h)); A = $action })
}

function Draw-UI($g) {
    $g.SmoothingMode = 'AntiAlias'
    $script:hits.Clear()
    $H = $form.ClientSize.Height
    $g.Clear($col.main)

    # Sidebar
    $b = New-Object System.Drawing.SolidBrush $col.side; $g.FillRectangle($b, 0, 0, $SIDE, $H); $b.Dispose()
    $pen = New-Object System.Drawing.Pen $col.line; $g.DrawLine($pen, $SIDE, 0, $SIDE, $H); $pen.Dispose()
    Draw-Flame $g 31 31 22 $col.accent $col.flame
    Text $g 'Burn Notice' $font.title $col.text 50 21

    Text $g 'Plan' $font.label $col.muted 22 70
    if ($script:sel -lt 0) { Fill-Round $g $col.sel 10 94 ($SIDE - 20) 38 9 }
    elseif ($script:hover -eq 'week') { Fill-Round $g $col.hover 10 94 ($SIDE - 20) 38 9 }
    Text $g 'Weekly usage' $font.item $(if ($script:sel -lt 0) { $col.text } else { $col.text2 }) 22 103
    $wk = if ($script:data) { $script:data.week } else { $null }
    if ($wk -and $null -ne $wk.pct) { TextR $g ('{0:0}%' -f [double]$wk.pct) $font.small $col.muted ($SIDE - 22) 105 }
    Add-Hit 10 94 ($SIDE - 20) 38 'week'

    Text $g 'Window' $font.label $col.muted 22 146
    $y = 170
    $wins = if ($script:data) { @($script:data.windows) } else { @() }
    for ($i = 0; $i -lt $wins.Count; $i++) {
        $wn = $wins[$i]; $act = "sel:$i"
        if ($i -eq $script:sel) { Fill-Round $g $col.sel 10 $y ($SIDE - 20) 38 9 }
        elseif ($script:hover -eq $act) { Fill-Round $g $col.hover 10 $y ($SIDE - 20) 38 9 }
        $tc = if ($i -eq $script:sel) { $col.text } else { $col.text2 }
        Text $g $wn.label $font.item $tc 22 ($y + 9)
        TextR $g (Format-Tokens $wn.totals.tokens) $font.small $col.muted ($SIDE - 22) ($y + 11)
        Add-Hit 10 $y ($SIDE - 20) 38 $act
        $y += 42
    }

    # Sidebar footer: refresh + status
    $ry = $H - 84
    if ($script:hover -eq 'refresh') { Fill-Round $g $col.hover 10 $ry ($SIDE - 20) 36 9 }
    $busy = $script:proc -and -not $script:proc.HasExited
    Text $g ($(if ($busy) { [char]0x21BB + '  Refreshing...' } else { [char]0x21BB + '  Refresh now' })) $font.item $col.text2 22 ($ry + 8)
    Add-Hit 10 $ry ($SIDE - 20) 36 'refresh'
    $upd = if ($script:data) { 'Updated ' + ([datetime]$script:data.generatedAt).ToLocalTime().ToString('HH:mm') + "  $dot  every $refreshMinutes min" } else { 'No data yet' }
    Text $g $upd $font.tiny $col.muted 22 ($H - 36)

    # Close button
    $cx = $W - 44
    if ($script:hover -eq 'close') { Fill-Round $g $col.hover $cx 12 30 30 8 }
    Text $g ([string][char]0x2715) $font.small $col.muted ($cx + 9) 19
    Add-Hit $cx 12 30 30 'close'

    if ($script:sel -lt 0) { Draw-Week $g $H; return }
    if (-not $wins.Count) { Text $g 'Collecting usage...' $font.item $col.muted ($SIDE + 32) 40; return }
    $win = $wins[[math]::Min($script:sel, $wins.Count - 1)]
    $t = $win.totals
    $x0 = $SIDE + 32; $x1 = $W - 32; $cw = $x1 - $x0

    # Headline
    Text $g $win.label $font.label $col.muted $x0 26
    $big = Format-Tokens $t.tokens
    Text $g $big $font.big $col.text ($x0 - 2) 46
    Text $g 'tokens' $font.bigUnit $col.text2 ($x0 + (TextW $big $font.big) - 18) 66
    TextR $g (Format-Cost $t) $font.cost $col.accent $x1 52
    TextR $g 'est. API cost' $font.tiny $col.muted $x1 88
    Text $g ('{0:N0} tokens' -f [double]$t.tokens) $font.tiny $col.muted $x0 98

    # Token mix cards
    $cards = @(@('Input', $t.input), @('Output', $t.output), @('Cache write', $t.cacheWrite), @('Cache read', $t.cacheRead))
    $gap = 10; $cwid = ($cw - 3 * $gap) / 4; $cy = 128
    for ($i = 0; $i -lt 4; $i++) {
        $cx = $x0 + $i * ($cwid + $gap)
        Fill-Round $g $col.card $cx $cy $cwid 62 10
        Stroke-Round $g $col.line $cx $cy $cwid 62 10
        Text $g $cards[$i][0] $font.tiny $col.muted ($cx + 14) ($cy + 11)
        Text $g (Format-Tokens $cards[$i][1]) $font.chipVal $col.text ($cx + 14) ($cy + 30)
    }

    # Per model
    Text $g 'By model' $font.label $col.muted $x0 214
    $y = 240
    if (-not $win.models -or @($win.models).Count -eq 0) { Text $g 'No usage in this window' $font.row $col.text2 $x0 $y }
    foreach ($m in @($win.models)) {
        $share = if ($t.tokens -gt 0) { $m.tokens / $t.tokens } else { 0 }
        Text $g (Format-Model $m.model) $font.row $col.text $x0 $y
        TextR $g (Format-Cost $m) $font.row $col.text $x1 $y
        $barW = $cw - 170
        Fill-Round $g $col.track $x0 ($y + 26) $barW 6 3
        if ($share -gt 0) { Fill-Round $g $col.accent $x0 ($y + 26) ([math]::Max(6.0, $barW * $share)) 6 3 }
        TextR $g ("{0}  $dot  {1:0.0}%" -f (Format-Tokens $m.tokens), (100 * $share)) $font.tiny $col.muted $x1 ($y + 21)
        $y += 50
    }

    $note = 'Cost = these tokens at API list prices (LiteLLM). Your Pro plan is flat-rate.'
    if ($t.unpriced) { $note += '  * = some models unpriced' }
    Text $g $note $font.tiny $col.muted $x0 ($H - 36)
}

# Weekly plan view: % of the weekly limit (estimated from one calibration reading), 7 slots of 100/7 %.
function Draw-Week($g, [int]$H) {
    $x0 = $SIDE + 32; $x1 = $W - 32; $cw = $x1 - $x0
    $wk = if ($script:data) { $script:data.week } else { $null }
    if (-not $wk) { Text $g 'Collecting usage...' $font.item $col.muted $x0 40; return }
    $slot = 100 / 7
    $now = Get-Now
    $ws = From-Ms $wk.start; $we = From-Ms $wk.end
    $elapsed = [math]::Min(1.0, [math]::Max(0.0, ($now - $ws).TotalHours / ($we - $ws).TotalHours))
    $days = @($wk.days)
    $ti = Get-TodayIndex $wk
    $cal = $wk.calibration
    $hasPct = $null -ne $wk.pct
    $pct = if ($hasPct) { [double]$wk.pct } else { 0 }
    $resetTxt = 'Resets ' + $we.ToString('ddd HH:mm', $inv) + "  $dot  in " + (Format-Span ($we - $now))

    # Headline
    Text $g ('This week  ' + $dot + '  ' + $ws.ToString('MMM d', $inv) + ' ' + [char]0x2013 + ' ' + $we.ToString('MMM d', $inv)) $font.label $col.muted $x0 26
    if ($hasPct) { $big = '{0:0.0}%' -f $pct; $unit = 'used' } else { $big = Format-Tokens $wk.totals.tokens; $unit = 'tokens' }
    Text $g $big $font.big $(if ($pct -ge 100) { $col.over } else { $col.text }) ($x0 - 2) 46
    Text $g $unit $font.bigUnit $col.text2 ($x0 + (TextW $big $font.big) - 18) 66
    TextR $g (Format-Cost $wk.totals) $font.cost $col.accent $x1 52
    TextR $g 'est. API cost' $font.tiny $col.muted $x1 88
    $sub = if ($hasPct) { (Format-Tokens $wk.totals.tokens) + " tokens  $dot  " + $resetTxt } else { $resetTxt }
    Text $g $sub $font.tiny $col.muted $x0 98

    # Week bar: one segment per day slot, filled to the week's %, marker = where the plan says you should be now
    $gap = 4; $segW = ($cw - 6 * $gap) / 7; $by = 126
    for ($i = 0; $i -lt 7; $i++) {
        $sx = $x0 + $i * ($segW + $gap)
        Fill-Round $g $col.track $sx $by $segW 10 4
        $f = [math]::Min(1.0, [math]::Max(0.0, ($pct - $i * $slot) / $slot))
        if ($f -gt 0) { Fill-Round $g $(if ($pct -ge 100) { $col.over } else { $col.accent }) $sx $by ([math]::Max(8.0, $segW * $f)) 10 4 }
        $lbl = $days[$i].label
        Text $g $lbl $font.tiny $(if ($i -eq $ti) { $col.text } else { $col.muted }) ([int]($sx + ($segW - (TextW $lbl $font.tiny)) / 2)) ($by + 17)
    }
    $k = [math]::Min(6.0, [math]::Floor($elapsed * 7))
    $mx = $x0 + $k * ($segW + $gap) + ($elapsed * 7 - $k) * $segW
    $pen = New-Object System.Drawing.Pen($col.text, 2); $g.DrawLine($pen, [float]$mx, [float]($by - 4), [float]$mx, [float]($by + 14)); $pen.Dispose()

    # Cards (or a calibration prompt)
    $cy = 172
    if ($hasPct) {
        $tu = if ($ti -ge 0) { [double]$days[$ti].pct } else { 0 }
        $delta = $pct - 100 * $elapsed
        $left = [math]::Max(0.0, 100 - $pct)
        $perDay = $left / [math]::Max(0.1, ($we - $now).TotalDays)
        $cards = @(
            @('Today', ('{0:0.0}%' -f $tu), ('of {0:0.0}%' -f $slot), $(if ($tu -gt $slot) { $col.over } else { $col.text })),
            @('Pace', ('{0:+0.0;-0.0;0.0}%' -f $delta), $(if ($delta -gt 0) { 'over plan' } else { 'under plan' }), $(if ($delta -gt 0) { $col.over } else { $col.text })),
            @('Left until reset', ('{0:0.0}%' -f $left), ('{0:0.0}%/day' -f $perDay), $col.text)
        )
        $cg = 10; $cwid = ($cw - 2 * $cg) / 3
        for ($i = 0; $i -lt 3; $i++) {
            $cx = $x0 + $i * ($cwid + $cg)
            Fill-Round $g $col.card $cx $cy $cwid 62 10
            Stroke-Round $g $col.line $cx $cy $cwid 62 10
            Text $g $cards[$i][0] $font.tiny $col.muted ($cx + 14) ($cy + 11)
            Text $g $cards[$i][1] $font.chipVal $cards[$i][3] ($cx + 14) ($cy + 30)
            Text $g $cards[$i][2] $font.tiny $col.muted ($cx + 14 + (TextW $cards[$i][1] $font.chipVal) + 4) ($cy + 36)
        }
    } else {
        Fill-Round $g $col.card $x0 $cy $cw 62 10
        Stroke-Round $g $col.line $x0 $cy $cw 62 10
        $msg = if ($cal) { 'No Claude Code usage was logged before that reading' } else { 'Enter your weekly % once to turn this into a budget' }
        Text $g $msg $font.row $col.text ($x0 + 16) ($cy + 12)
        Text $g ('Claude app ' + [char]0x203A + ' Settings ' + [char]0x203A + ' Usage, weekly limit (all models), then "Set weekly %" below') $font.tiny $col.muted ($x0 + 16) ($cy + 36)
    }

    # By day
    Text $g 'By day' $font.label $col.muted $x0 252
    TextR $g ('{0:0.00}% of the week per day' -f $slot) $font.tiny $col.muted $x1 254
    $bx = $x0 + 104; $bw = $cw - 104 - 124
    $maxCost = ($days | ForEach-Object { [double]$_.cost } | Measure-Object -Maximum).Maximum
    for ($i = 0; $i -lt $days.Count; $i++) {
        $d = $days[$i]; $yy = 278 + $i * 27
        $isToday = $i -eq $ti
        $future = $ti -ge 0 -and $i -gt $ti
        $dStart = From-Ms $d.start
        Text $g $d.label $(if ($isToday) { $font.rowB } else { $font.row }) $(if ($isToday) { $col.text } elseif ($future) { $col.muted } else { $col.text2 }) $x0 $yy
        Text $g $dStart.ToString('MMM d', $inv) $font.tiny $col.muted ($x0 + 44) ($yy + 2)
        Fill-Round $g $col.track $bx ($yy + 5) $bw 8 4
        $frac = if ($hasPct) { [double]$d.pct / $slot } elseif ($maxCost -gt 0) { [double]$d.cost / $maxCost } else { 0 }
        if (-not $future -and $frac -gt 0) {
            Fill-Round $g $(if ($hasPct -and $frac -gt 1) { $col.over } else { $col.accent }) $bx ($yy + 5) ([math]::Max(8.0, $bw * [math]::Min(1.0, $frac))) 8 4
        }
        if ($isToday -and $hasPct) {
            # How much of today's slot the plan allows by now
            $dEnd = if ($i -lt 6) { From-Ms $days[$i + 1].start } else { $we }
            $tx = $bx + $bw * ($now - $dStart).TotalHours / ($dEnd - $dStart).TotalHours
            $pen = New-Object System.Drawing.Pen($col.text, 2); $g.DrawLine($pen, [float]$tx, [float]($yy + 1), [float]$tx, [float]($yy + 17)); $pen.Dispose()
        }
        if ($future) { $val = if ($hasPct) { '{0:0.0}%' -f $slot } else { '' }; $vc = $col.muted }
        elseif ($hasPct) { $val = '{0:0.0}%' -f [double]$d.pct; $vc = if ($frac -gt 1) { $col.over } else { $col.text } }
        else { $val = '$' + ('{0:N2}' -f [double]$d.cost); $vc = $col.text }
        TextR $g $val $font.row $vc $x1 $yy
        if (-not $future) { TextR $g (Format-Tokens $d.tokens) $font.tiny $col.muted ($x1 - 62) ($yy + 2) }
    }

    # Calibration strip
    $sy = $H - 48
    if ($script:editing) {
        Fill-Round $g $col.card $x0 $sy $cw 34 9
        Stroke-Round $g $col.accent $x0 $sy $cw 34 9
        $lab = 'Weekly % from Settings ' + [char]0x203A + ' Usage:'
        Text $g $lab $font.small $col.text2 ($x0 + 14) ($sy + 9)
        $calBox.SetBounds(($x0 + 14 + (TextW $lab $font.small) + 10), ($sy + 8), 70, 20)
        if ($script:calErr) { TextR $g 'Enter a number from 1 to 100' $font.tiny $col.over ($x1 - 14) ($sy + 11) }
        else { TextR $g "Enter to save  $dot  Esc to cancel" $font.tiny $col.muted ($x1 - 14) ($sy + 11) }
    } else {
        $note = if ($cal) { 'Estimate from your {0}% reading on {1}' -f $cal.pct, (From-Ms $cal.at).ToString('MMM d HH:mm', $inv) } else { 'Not calibrated yet' }
        Text $g $note $font.tiny $col.muted $x0 ($sy + 11)
        $btn = if ($cal) { 'Update %' } else { 'Set weekly %' }
        $bwid = (TextW $btn $font.small) + 28
        Fill-Round $g $(if ($script:hover -eq 'calib') { $col.sel } else { $col.card }) ($x1 - $bwid) ($sy + 2) $bwid 30 9
        Stroke-Round $g $col.line ($x1 - $bwid) ($sy + 2) $bwid 30 9
        Text $g $btn $font.small $col.text ($x1 - $bwid + 14) ($sy + 9)
        Add-Hit ($x1 - $bwid) ($sy + 2) $bwid 30 'calib'
    }
}

# Inline % entry (a modal dialog would deactivate, and so hide, the panel)
$calBox = New-Object System.Windows.Forms.TextBox
$calBox.BorderStyle = 'None'
$calBox.BackColor = $col.card
$calBox.ForeColor = $col.text
$calBox.Font = $font.row
$calBox.MaxLength = 6
$calBox.Visible = $false
$form.Controls.Add($calBox)

function Start-Calibration {
    $script:calErr = $false
    $calBox.Text = ''
    $script:editing = $true
    $form.Refresh()   # paint once so Draw-Week positions the box before it shows
    $calBox.Visible = $true
    [void]$calBox.Focus()
}
function Stop-Calibration {
    if (-not $script:editing) { return }
    $calBox.Visible = $false; $script:editing = $false
    $form.Invalidate()
}
function Save-Calibration {
    $v = 0.0
    $txt = $calBox.Text.Trim().TrimEnd('%').Trim().Replace(',', '.')
    if (-not [double]::TryParse($txt, [Globalization.NumberStyles]::Float, $inv, [ref]$v) -or $v -le 0 -or $v -gt 100) {
        $script:calErr = $true; $form.Invalidate(); return
    }
    $json = '{"pct":' + $v.ToString($inv) + ',"at":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + '}'
    [System.IO.File]::WriteAllText($calibFile, $json)
    Stop-Calibration
    Start-Refresh
}
$calBox.add_KeyDown({ param($s, $e)
    if ($e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; Save-Calibration }
    elseif ($e.KeyCode -eq 'Escape') { $e.SuppressKeyPress = $true; Stop-Calibration }
})

$form.add_Paint({ param($s, $e) Draw-UI $e.Graphics })
$form.add_MouseMove({ param($s, $e)
    $hit = $script:hits | Where-Object { $_.R.Contains($e.Location) } | Select-Object -First 1
    $a = if ($hit) { $hit.A } else { $null }
    $form.Cursor = if ($a) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
    if ($a -ne $script:hover) { $script:hover = $a; $form.Invalidate() }
})
$form.add_MouseLeave({ if ($script:hover) { $script:hover = $null; $form.Invalidate() } })
$form.add_MouseClick({ param($s, $e)
    $hit = $script:hits | Where-Object { $_.R.Contains($e.Location) } | Select-Object -First 1
    if (-not $hit) { return }
    switch -Regex ($hit.A) {
        '^sel:(\d+)$' { Stop-Calibration; $script:sel = [int]$Matches[1]; $form.Invalidate() }
        '^week$' { $script:sel = -1; $form.Invalidate() }
        '^calib$' { Start-Calibration }
        '^refresh$' { Start-Refresh }
        '^close$' { $form.Hide() }
    }
})
# KeyPreview: Escape reaches the form first, so leave it to the % box while editing
$form.add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape' -and -not $script:editing) { $form.Hide() } })

function Load-Data {
    if (-not (Test-Path $usageFile)) { return }
    try { $script:data = Get-Content $usageFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
    # Fit height to the window with the most models
    $maxModels = ($script:data.windows | ForEach-Object { @($_.models).Count } | Measure-Object -Maximum).Maximum
    $form.ClientSize = New-Object System.Drawing.Size($W, [math]::Max(524, 240 + 50 * $maxModels + 56))

    $h = $script:data.windows | Where-Object key -eq '1h'
    $d = $script:data.windows | Where-Object key -eq '24h'
    $wk = $script:data.week
    $ti = if ($wk) { Get-TodayIndex $wk } else { -1 }
    if ($wk -and $null -ne $wk.pct -and $ti -ge 0) {
        $tip = "Week {0:0}% | today {1:0.0}% of {2:0.0}% | 1h {3}" -f [double]$wk.pct, [double]@($wk.days)[$ti].pct, (100 / 7), (Format-Tokens $h.totals.tokens)
    } else {
        $tip = "1h $(Format-Tokens $h.totals.tokens) $(Format-Cost $h.totals) | 24h $(Format-Tokens $d.totals.tokens) $(Format-Cost $d.totals)"
    }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $tray.Text = $tip
    $form.Invalidate()
}

# ---- Background refresh (node runs hidden; poll for exit so the UI never blocks) ----
function Start-Refresh {
    if ($script:proc -and -not $script:proc.HasExited) { return }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node
    $psi.Arguments = "`"$aggScript`""
    $psi.WorkingDirectory = $here
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    try { $script:proc = [System.Diagnostics.Process]::Start($psi) } catch { $tray.Text = 'AI Burn Notice: node not found' }
    $form.Invalidate()
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$tray.Text = 'AI Burn Notice: loading...'
$tray.Visible = $true

function Show-Detail {
    Stop-Calibration   # an edit left open when the panel lost focus
    Load-Data
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(($wa.Right - $form.Width - 12), ($wa.Bottom - $form.Height - 12))
    $form.Show(); $form.Activate()
}

$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'AI Burn Notice.lnk'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $menu.Items.Add('Show usage')
$miRefresh = $menu.Items.Add('Refresh now')
$miStartup = New-Object System.Windows.Forms.ToolStripMenuItem('Start with Windows')
$miStartup.Checked = Test-Path $startupLnk
[void]$menu.Items.Add($miStartup)
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Exit')
$tray.ContextMenuStrip = $menu

$miShow.add_Click({ Show-Detail })
$miRefresh.add_Click({ Start-Refresh })
$miStartup.add_Click({
    if (Test-Path $startupLnk) { Remove-Item $startupLnk -Force }
    else {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($startupLnk)
        $lnk.TargetPath = "$env:WINDIR\System32\wscript.exe"
        $lnk.Arguments = "`"$(Join-Path $here 'start.vbs')`""
        $lnk.WorkingDirectory = $here
        if (Test-Path $iconFile) { $lnk.IconLocation = "$iconFile,0" }
        $lnk.Save()
    }
    $miStartup.Checked = Test-Path $startupLnk
})
# Clicking the icon deactivates (hides) the open window first; don't immediately reopen it.
$tray.add_MouseClick({ param($s, $e)
    if ($e.Button -ne 'Left') { return }
    if ($form.Visible) { $form.Hide() }
    elseif (((Get-Date) - $form.HiddenAt).TotalMilliseconds -gt 400) { Show-Detail }
})

$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 300
$poll.add_Tick({
    if ($script:proc -and $script:proc.HasExited) { $script:proc.Dispose(); $script:proc = $null; Load-Data }
    if ($showEvent.WaitOne(0)) { Show-Detail }
})
$poll.Start()

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $refreshMinutes * 60 * 1000
$timer.add_Tick({ Start-Refresh })
$timer.Start()

$miExit.add_Click({
    Write-Log 'exit from menu'
    $timer.Stop(); $poll.Stop()
    $tray.Visible = $false; $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

Load-Data
# Dev aid: tray.ps1 -snapshot out.png [windowIndex|-1] [-editing]  renders the panel to a PNG and exits.
if ($snapshot) {
    $si = [array]::IndexOf($args, '-snapshot')
    if ($args.Count -gt $si + 2 -and $args[$si + 2] -ne '-editing') { $script:sel = [int]$args[$si + 2] }
    if ($args -contains '-editing') { Start-Calibration; $calBox.Text = '42' }
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save($args[$si + 1], [System.Drawing.Imaging.ImageFormat]::Png)
    $tray.Visible = $false; $tray.Dispose()
    if ($createdNew) { $mutex.ReleaseMutex() }
    exit
}
Write-Log "start (pid $PID)"
if ($args -contains '-show') { [void]$showEvent.Set() }
Start-Refresh
try { [System.Windows.Forms.Application]::Run() } catch { Write-Log "crash: $_" }
Write-Log 'stopped'
$mutex.ReleaseMutex()
