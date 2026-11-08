# Creates the "AI Burn Notice" desktop shortcut (and, with -Startup, a Start-with-Windows shortcut).
# Run:  powershell -ExecutionPolicy Bypass -File install.ps1 [-Startup] [-Uninstall]
param([switch]$Startup, [switch]$Uninstall)

$here = $PSScriptRoot
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'AI Burn Notice.lnk'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'AI Burn Notice.lnk'

if ($Uninstall) {
    foreach ($l in $desktopLnk, $startupLnk) { if (Test-Path $l) { Remove-Item $l -Force; "removed $l" } }
    return
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Warning 'Node.js was not found on PATH. Install it from https://nodejs.org (the usage scan needs it).'
}

function New-Shortcut([string]$path, [string]$extraArgs) {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($path)
    $lnk.TargetPath = "$env:WINDIR\System32\wscript.exe"
    $lnk.Arguments = ("`"{0}`" {1}" -f (Join-Path $here 'start.vbs'), $extraArgs).Trim()
    $lnk.WorkingDirectory = $here
    $lnk.IconLocation = (Join-Path $here 'assets\flame.ico') + ',0'
    $lnk.Description = 'AI Burn Notice: Claude Code token usage in your tray'
    $lnk.Save()
    "created $path"
}

New-Shortcut $desktopLnk '-show'
if ($Startup) { New-Shortcut $startupLnk '' }
Start-Process $desktopLnk
