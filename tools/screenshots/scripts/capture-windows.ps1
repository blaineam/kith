<#
.SYNOPSIS
  capture-windows.ps1 — launch the Haven Tauri desktop app on Windows and
  capture its window to raw PNGs under tools\screenshots\raw\windows\.

.DESCRIPTION
  This script runs ON A WINDOWS MACHINE (or a `windows-latest` CI runner). It:
    1. Launches the built Tauri release binary (or an already-installed Haven).
    2. Finds the Haven top-level window by process / window title.
    3. Captures the window client area to a PNG via .NET System.Drawing.
    4. Repeats per scene, pausing for in-app navigation where needed.

  It cannot run on macOS/Linux — it is provided correct + documented for the
  user to run on Windows. After capture, run `node src/cli.js frame` (cross-
  platform) to produce the framed Microsoft Store marketing images.

.PARAMETER ExePath
  Path to the Haven desktop executable. Defaults to the Tauri release build at
  desktop\src-tauri\target\release\haven.exe (adjust to your binary name).

.PARAMETER WindowTitle
  The window title to capture. Defaults to "Haven".

.PARAMETER Interactive
  When $true (default), pauses before scenes that need an in-app tap so you can
  navigate, then press ENTER to capture. Set $false for tabs-only / CI.

.EXAMPLE
  .\capture-windows.ps1
.EXAMPLE
  .\capture-windows.ps1 -ExePath "C:\Program Files\Haven\Haven.exe" -Interactive:$false
#>

[CmdletBinding()]
param(
  [string]$ExePath = "$PSScriptRoot\..\..\..\desktop\src-tauri\target\release\haven.exe",
  [string]$WindowTitle = "Haven",
  [bool]$Interactive = $true,
  [int]$SettleSeconds = 3
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$OutDir = Join-Path (Resolve-Path "$PSScriptRoot\..").Path "raw\windows"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ── Win32 interop: locate window + read its rectangle ───────────────────────
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

function Get-HavenWindow {
  param([string]$Title)
  # Match by main window title first, then by process name 'haven'.
  $proc = Get-Process | Where-Object {
    $_.MainWindowTitle -eq $Title -or $_.ProcessName -ieq 'haven'
  } | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  return $proc
}

function Capture-Window {
  param([System.Diagnostics.Process]$Proc, [string]$Name)
  $h = $Proc.MainWindowHandle
  [Win32]::ShowWindow($h, 9) | Out-Null   # SW_RESTORE
  [Win32]::SetForegroundWindow($h) | Out-Null
  Start-Sleep -Milliseconds 400

  $rect = New-Object Win32+RECT
  [Win32]::GetWindowRect($h, [ref]$rect) | Out-Null
  $width  = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  if ($width -le 0 -or $height -le 0) { throw "Bad window rect for $Name" }

  $bmp = New-Object System.Drawing.Bitmap $width, $height
  $gfx = [System.Drawing.Graphics]::FromImage($bmp)
  $gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
  $path = Join-Path $OutDir "$Name.png"
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $gfx.Dispose(); $bmp.Dispose()
  Write-Host "  OK $Name.png  ($width x $height)"
}

function Pause-ForTap {
  param([string]$Msg)
  if (-not $Interactive) { Write-Host "  SKIP interactive scene: $Msg"; return $false }
  Write-Host "  TODO (manual): $Msg"
  $ans = Read-Host "      ...then press ENTER to capture (or type s to skip)"
  return ($ans -ne 's')
}

# ── Launch the app ──────────────────────────────────────────────────────────
$running = Get-HavenWindow -Title $WindowTitle
if (-not $running) {
  if (-not (Test-Path $ExePath)) {
    throw "Haven exe not found at '$ExePath'. Build it (cargo tauri build) or pass -ExePath, or launch the installed app first."
  }
  Write-Host "Launching $ExePath ..."
  # Demo mode: the desktop app reads a HAVEN_DEMO env flag (mirror of the Android
  # demo intent). Adjust to the desktop app's actual demo switch if different.
  $env:HAVEN_DEMO = "1"
  Start-Process -FilePath $ExePath
  Start-Sleep -Seconds $SettleSeconds
}

$proc = $null
for ($i = 0; $i -lt 20 -and -not $proc; $i++) {
  $proc = Get-HavenWindow -Title $WindowTitle
  if (-not $proc) { Start-Sleep -Milliseconds 500 }
}
if (-not $proc) { throw "Could not find the Haven window titled '$WindowTitle'." }
Write-Host "Found window: '$($proc.MainWindowTitle)' (PID $($proc.Id))"
Write-Host "Output: $OutDir`n"

# ── Scenes ───────────────────────────────────────────────────────────────────
# The desktop UI is a single window; navigation is in-app, so most scenes need a
# click. We capture the default view tab-free, then pause for the rest. These
# match the windows-* entries in screens.json.

Write-Host "* feed (default circle view)"
Start-Sleep -Seconds 1
Capture-Window -Proc $proc -Name "feed"

Write-Host "* call (group video + screen share)"
# TODO HOOK: click into the demo group call before capturing.
if (Pause-ForTap "open the demo group video call") { Capture-Window -Proc $proc -Name "call" }

Write-Host "* messages (open a DM thread)"
# TODO HOOK: open the seeded DM conversation.
if (Pause-ForTap "open the seeded DM conversation") { Capture-Window -Proc $proc -Name "messages" }

Write-Host "`nDone. Raw screenshots in: $OutDir"
Write-Host "Next (any OS): node src/cli.js frame --platform windows"
