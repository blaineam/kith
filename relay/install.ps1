<#
  Haven relay — one-command setup for Windows (x86-64 and Arm64).

  Installs the `haven-relay.exe` static binary and registers a Scheduled Task so it
  RELAUNCHES AUTOMATICALLY ON EVERY LOGON/REBOOT — a true always-on circle mailbox, no
  window, no service account needed. Everything it stores is end-to-end sealed to your
  circle, so the relay can never read anything.

    # PowerShell (no admin needed):
    irm https://wemiller.com/apps/haven/relay/install.ps1 | iex
    # then, once, paste the link the app shows you:
    haven-relay run --link "haven-relay://circle#...."
    # it's now registered to start on every reboot.

  Re-run any time to update the binary.
#>
[CmdletBinding()]
param(
  [string]$Repo = $(if ($env:HAVEN_RELAY_REPO) { $env:HAVEN_RELAY_REPO } else { "blaineam/haven" }),
  [switch]$NoAutostart
)
$ErrorActionPreference = "Stop"

# ── Pick the right prebuilt for this machine's architecture ──────────────────────────────
$arch = $env:PROCESSOR_ARCHITECTURE
switch ($arch) {
  "AMD64" { $target = "x86_64-pc-windows-msvc" }
  "ARM64" { $target = "aarch64-pc-windows-msvc" }
  "x86"   { $target = "x86_64-pc-windows-msvc" }  # 32-bit shell on 64-bit Windows
  default { Write-Error "No prebuilt haven-relay for Windows/$arch. Build from source: cargo build --release -p haven-relay"; return }
}

$dir = Join-Path $env:LOCALAPPDATA "Haven"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$exe = Join-Path $dir "haven-relay.exe"
$url = "https://github.com/$Repo/releases/latest/download/haven-relay-$target.exe"

Write-Host "▸ Downloading haven-relay ($target)…"
try {
  Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
} catch {
  Write-Error "Could not download a prebuilt binary (no release asset yet for $target?).`n  Build from source:  cargo build --release -p haven-relay"
  return
}

# Put it on PATH for this user (so `haven-relay` works in new shells).
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$dir*") {
  [Environment]::SetEnvironmentVariable("Path", "$userPath;$dir", "User")
  $env:Path += ";$dir"
}

# ── Reboot survival: a Scheduled Task that runs the relay at every logon ──────────────────
if (-not $NoAutostart) {
  $taskName = "HavenRelay"
  schtasks /Delete /TN $taskName /F 2>$null | Out-Null
  # /sc onlogon → starts at logon (survives reboot); runs hidden; restarts handled by haven-relay itself.
  schtasks /Create /TN $taskName /TR "`"$exe`" run" /SC ONLOGON /RL LIMITED /F | Out-Null
  Write-Host "✓ Registered scheduled task '$taskName' — haven-relay starts on every logon/reboot."
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host "✓ Installed: $exe"
Write-Host ""
Write-Host "Make it your circle's mailbox in two steps:"
Write-Host "  1. In the Haven app:  You -> Relay -> add a relay. Copy the haven-relay:// link."
Write-Host "  2. Open a NEW PowerShell window and run once:"
Write-Host "       haven-relay run --link `"haven-relay://circle#....`""
Write-Host ""
Write-Host "After that it relaunches automatically on every reboot (Scheduled Task 'HavenRelay')."
Write-Host "  • Start it now without rebooting:   schtasks /Run /TN HavenRelay"
Write-Host "  • Stop auto-start:                  schtasks /Delete /TN HavenRelay /F"
Write-Host "The relay only ever moves ciphertext. It cannot read your circle's content."
Write-Host "═══════════════════════════════════════════════════════════════"
