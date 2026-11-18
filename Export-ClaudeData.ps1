<#
  Export-ClaudeData.ps1  -  run on the OLD computer

  Copies everything needed to move Claude Code / Claude Desktop projects and
  sessions to another computer into one export folder:
    - %USERPROFILE%\.claude         (session transcripts, history, settings)
    - %USERPROFILE%\.claude.json    (project list, trust approvals)
    - claude-code-sessions          (Claude Desktop sidebar entries)

  Your login (.credentials.json) is NOT exported; just sign in on the new computer.
  Nothing on this computer is changed.

  Usage (Claude fully quit, including from the system tray):
    powershell -ExecutionPolicy Bypass -File .\Export-ClaudeData.ps1
  or choose where the export goes:
    powershell -ExecutionPolicy Bypass -File .\Export-ClaudeData.ps1 -Dest "\\SERVER\Share\ClaudeExport"
  (Default destination: a ClaudeExport-<computer>-<date> folder on your Desktop.)
#>
param(
    [string]$Dest = (Join-Path ([Environment]::GetFolderPath('Desktop')) ("ClaudeExport-{0}-{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm')))
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say($m) { Write-Host $m }

# --- Safety check ----------------------------------------------------------
$running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^claude$' }
if ($running) {
    throw "Claude is still running. Quit Claude Desktop (including from the system tray) and any Claude Code terminals, then run again."
}

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Say "Exporting to: $Dest"
Say ""

# --- 1. .claude folder -----------------------------------------------------
$claudeDir = Join-Path $env:USERPROFILE '.claude'
if (Test-Path -LiteralPath $claudeDir) {
    Say "Copying .claude folder (this can take a minute)..."
    robocopy $claudeDir (Join-Path $Dest '.claude') /E /COPY:DAT /XF .credentials.json /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying .claude failed (robocopy exit $LASTEXITCODE)." }
    $nSessions = (Get-ChildItem (Join-Path $Dest '.claude\projects') -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue).Count
    Say "  done - $nSessions session transcripts."
} else {
    Say "  No .claude folder found - skipped."
}

# --- 2. .claude.json -------------------------------------------------------
$claudeJson = Join-Path $env:USERPROFILE '.claude.json'
if (Test-Path -LiteralPath $claudeJson) {
    Copy-Item -LiteralPath $claudeJson -Destination (Join-Path $Dest '.claude.json') -Force
    Say "Copied .claude.json"
} else {
    Say "No .claude.json found - skipped."
}

# --- 3. Claude Desktop sidebar sessions -----------------------------------
Say "Looking for Claude Desktop sidebar data..."
$candidates = Get-ChildItem $env:APPDATA, $env:LOCALAPPDATA -Directory -Recurse -Depth 4 -Filter 'claude-code-sessions' -ErrorAction SilentlyContinue
if ($candidates) {
    # If more than one, use the one with the most recently changed session file
    $best = $candidates | Sort-Object {
        $f = Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($f) { $f.LastWriteTime } else { [datetime]::MinValue }
    } -Descending | Select-Object -First 1
    Say "  found: $($best.FullName)"
    robocopy $best.FullName (Join-Path $Dest 'claude-code-sessions') /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying sidebar sessions failed (robocopy exit $LASTEXITCODE)." }
    $nSidebar = (Get-ChildItem (Join-Path $Dest 'claude-code-sessions') -Recurse -Filter 'local_*.json' -ErrorAction SilentlyContinue).Count
    Say "  done - $nSidebar sidebar sessions."
} else {
    Say "  No Claude Desktop sidebar data found - skipped."
}

# --- Manifest --------------------------------------------------------------
@"
Claude export from $env:COMPUTERNAME ($env:USERNAME) on $(Get-Date)
Source .claude:        $claudeDir
Source sidebar folder: $(if ($best) { $best.FullName } else { '(none)' })
"@ | Set-Content -Path (Join-Path $Dest 'export-info.txt') -Encoding UTF8

Say ""
Say "=== Export complete ==="
Say "Export folder: $Dest"
Say "On the new computer, run:"
Say "  powershell -ExecutionPolicy Bypass -File .\Import-ClaudeData.ps1 -Source `"$Dest`""
