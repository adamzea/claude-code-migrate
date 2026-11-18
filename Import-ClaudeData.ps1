<#
  Import-ClaudeData.ps1  -  run on the NEW computer

  Merges an export made by Export-ClaudeData.ps1 into this computer WITHOUT
  losing anything on either side:
    - .claude folder:   copies sessions/files that are missing here; for a
                        session that exists in both, keeps the longer copy;
                        genuine conflicts keep this computer's copy and set the
                        other aside for review.
    - history.jsonl:    combined line by line, duplicates removed, sorted by time.
    - .claude.json:     adds projects missing here and fills in missing settings
                        (e.g. SSH trust approvals). This computer's login,
                        plugins and preferences are kept.
    - Desktop sidebar:  adds sessions missing here; sessions you deleted on this
                        computer are not brought back.

  Everything it touches is backed up first.

  Usage (Claude fully quit, including from the system tray):
    powershell -ExecutionPolicy Bypass -File .\Import-ClaudeData.ps1 -Source "\\SERVER\Share\ClaudeExport-OLDPC-20261118-1000"
  Without -Source it uses the newest ClaudeExport-* folder in -ShareRoot
  (default: your Desktop), e.g. -ShareRoot "\\SERVER\Share".
  Add -Yes to skip the confirmation prompt.
#>
param(
    [string]$Source,
    [string]$ShareRoot = [Environment]::GetFolderPath('Desktop'),
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# This script needs Windows PowerShell 5.1 (for a case-sensitive JSON parser).
if ($PSVersionTable.PSEdition -eq 'Core') {
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Source)    { $fwd += @('-Source', $Source) }
    if ($PSBoundParameters.ContainsKey('ShareRoot')) { $fwd += @('-ShareRoot', $ShareRoot) }
    if ($Yes)       { $fwd += '-Yes' }
    & powershell.exe @fwd
    exit $LASTEXITCODE
}

$Stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupDir = Join-Path $env:USERPROFILE "claude-import-backup-$Stamp"
$Conflicts = Join-Path $BackupDir 'conflicts-from-other-computer'
$LogFile   = Join-Path $BackupDir 'import.log'

function Say($m) {
    Write-Host $m
    if (Test-Path -LiteralPath $BackupDir) { Add-Content -LiteralPath $LogFile -Value $m }
}

# --- Locate source ---------------------------------------------------------
if (-not $Source) {
    $latest = Get-ChildItem -LiteralPath $ShareRoot -Directory -Filter 'ClaudeExport-*' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw "No -Source given and no ClaudeExport-* folder found in $ShareRoot." }
    $Source = $latest.FullName
}
if (-not (Test-Path -LiteralPath $Source)) { throw "Source not found: $Source" }

$SrcClaude  = Join-Path $Source '.claude'
$SrcJson    = Join-Path $Source '.claude.json'
$SrcSidebar = Join-Path $Source 'claude-code-sessions'

$DstClaude = Join-Path $env:USERPROFILE '.claude'
$DstJson   = Join-Path $env:USERPROFILE '.claude.json'

$sidebarCandidates = Get-ChildItem $env:APPDATA, $env:LOCALAPPDATA -Directory -Recurse -Depth 4 -Filter 'claude-code-sessions' -ErrorAction SilentlyContinue
$DstSidebar = $null
if ($sidebarCandidates) {
    $DstSidebar = ($sidebarCandidates | Sort-Object {
        $f = Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($f) { $f.LastWriteTime } else { [datetime]::MinValue }
    } -Descending | Select-Object -First 1).FullName
}

# --- Safety checks ---------------------------------------------------------
$running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^claude$' }
if ($running) {
    throw "Claude is still running. Quit Claude Desktop (including from the system tray) and any Claude Code terminals, then run again."
}

Write-Host "Import from: $Source"
Write-Host "Into:"
Write-Host "  $DstClaude"
Write-Host "  $DstJson"
Write-Host ("  " + $(if ($DstSidebar) { $DstSidebar } else { '(no Claude Desktop sidebar folder found - open Claude Desktop once, quit it, and re-run to include sidebar sessions)' }))
Write-Host "Backup will go to: $BackupDir"
if (-not $Yes) {
    $ans = Read-Host "Continue? (Y/N)"
    if ($ans -notmatch '^[Yy]') { Write-Host "Cancelled. Nothing changed."; return }
}

# --- Backup ----------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
Say "Backing up..."
if (Test-Path -LiteralPath $DstClaude) {
    robocopy $DstClaude (Join-Path $BackupDir '.claude') /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Backup of .claude failed (robocopy exit $LASTEXITCODE). Nothing was changed." }
}
if (Test-Path -LiteralPath $DstJson) { Copy-Item -LiteralPath $DstJson -Destination (Join-Path $BackupDir '.claude.json') }
if ($DstSidebar) {
    robocopy $DstSidebar (Join-Path $BackupDir 'claude-code-sessions') /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Backup of sidebar sessions failed (robocopy exit $LASTEXITCODE). Nothing was changed." }
}
Say "Backup done."

$sha = [System.Security.Cryptography.SHA256]::Create()
function Get-Sha([byte[]]$bytes, [int]$len) { [BitConverter]::ToString($sha.ComputeHash($bytes, 0, $len)) }
function Test-IsPrefix([byte[]]$short, [byte[]]$long) {
    if ($short.Length -gt $long.Length) { return $false }
    return (Get-Sha $short $short.Length) -eq (Get-Sha $long $short.Length)
}

# --- 1. .claude folder -----------------------------------------------------
$added = 0; $same = 0; $keptLocal = 0; $tookLonger = 0; $conflicted = 0
if (Test-Path -LiteralPath $SrcClaude) {
    Say ""
    Say "Merging .claude folder..."
    if (-not (Test-Path -LiteralPath $DstClaude)) { New-Item -ItemType Directory -Path $DstClaude | Out-Null }
    $srcRoot = (Resolve-Path -LiteralPath $SrcClaude).ProviderPath.TrimEnd('\')
    $skip = @('.credentials.json', 'history.jsonl')

    Get-ChildItem -LiteralPath $SrcClaude -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($srcRoot.Length).TrimStart('\')
        if ($skip -contains $rel) { return }
        $target = Join-Path $DstClaude $rel

        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $target
            $script:added++; return
        }

        $srcBytes = [IO.File]::ReadAllBytes($_.FullName)
        $dstBytes = [IO.File]::ReadAllBytes($target)
        if ($srcBytes.Length -eq $dstBytes.Length -and (Get-Sha $srcBytes $srcBytes.Length) -eq (Get-Sha $dstBytes $dstBytes.Length)) {
            $script:same++; return
        }

        if ($rel -like '*.jsonl') {
            if (Test-IsPrefix $srcBytes $dstBytes) { $script:keptLocal++; return }
            if (Test-IsPrefix $dstBytes $srcBytes) {
                Copy-Item -LiteralPath $_.FullName -Destination $target -Force
                $script:tookLonger++; Say "  Took longer copy: $rel"; return
            }
        }

        $cTarget = Join-Path $Conflicts $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $cTarget) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $cTarget
        $script:conflicted++; Say "  CONFLICT (kept this computer's, other set aside): $rel"
    }

    # history.jsonl
    $hSrc = Join-Path $SrcClaude 'history.jsonl'
    $hDst = Join-Path $DstClaude 'history.jsonl'
    if (Test-Path -LiteralPath $hSrc) {
        $lines = New-Object System.Collections.Generic.List[string]
        $seen  = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($f in @($hDst, $hSrc)) {
            if (Test-Path -LiteralPath $f) {
                foreach ($l in [IO.File]::ReadAllLines($f)) { if ($l.Trim() -and $seen.Add($l)) { $lines.Add($l) } }
            }
        }
        $sorted = $lines | Sort-Object -Property @{ Expression = {
            try { $j = $_ | ConvertFrom-Json; if ($j.timestamp) { [double]$j.timestamp } else { 0 } } catch { 0 }
        } }
        [IO.File]::WriteAllLines($hDst, [string[]]$sorted, (New-Object System.Text.UTF8Encoding $false))
        Say "  history.jsonl: $($lines.Count) unique entries."
    }
} else {
    Say "No .claude folder in export - skipped."
}

# --- 2. .claude.json -------------------------------------------------------
$projAdded = @(); $projFilled = 0
if (Test-Path -LiteralPath $SrcJson) {
    Say ""
    Say "Merging .claude.json..."
    if (-not (Test-Path -LiteralPath $DstJson)) {
        Copy-Item -LiteralPath $SrcJson -Destination $DstJson
        Say "  No .claude.json here - copied the other computer's."
    } else {
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $ser.RecursionLimit = 1000
        $dst = $ser.DeserializeObject([IO.File]::ReadAllText($DstJson))
        $src = $ser.DeserializeObject([IO.File]::ReadAllText($SrcJson))

        if ($src.ContainsKey('projects')) {
            if (-not $dst.ContainsKey('projects')) { $dst['projects'] = New-Object 'System.Collections.Generic.Dictionary[string,object]' }
            $dp = $dst['projects']; $sp = $src['projects']
            foreach ($k in @($sp.Keys)) {
                if (-not $dp.ContainsKey($k)) { $dp[$k] = $sp[$k]; $projAdded += $k; continue }
                $dEntry = $dp[$k]; $sEntry = $sp[$k]
                if ($dEntry -is [System.Collections.Generic.IDictionary[string,object]] -and $sEntry -is [System.Collections.Generic.IDictionary[string,object]]) {
                    foreach ($fk in @($sEntry.Keys)) {
                        if (-not $dEntry.ContainsKey($fk)) { $dEntry[$fk] = $sEntry[$fk]; $projFilled++ }
                    }
                }
            }
        }
        $out = $ser.Serialize($dst)
        $null = $ser.DeserializeObject($out)   # sanity check: output parses
        [IO.File]::WriteAllText($DstJson, $out, (New-Object System.Text.UTF8Encoding $false))
        foreach ($p in $projAdded) { Say "  + project: $p" }
        Say "  $($projAdded.Count) projects added, $projFilled missing settings filled in."
    }
} else {
    Say "No .claude.json in export - skipped."
}

# --- 3. Claude Desktop sidebar ---------------------------------------------
$sbAdded = @(); $sbAlready = 0; $sbDeleted = 0
if ((Test-Path -LiteralPath $SrcSidebar) -and $DstSidebar) {
    Say ""
    Say "Merging Claude Desktop sidebar..."
    $sbRoot = (Resolve-Path -LiteralPath $SrcSidebar).ProviderPath.TrimEnd('\')
    Get-ChildItem -LiteralPath $SrcSidebar -Recurse -File -Filter 'local_*.json' | ForEach-Object {
        if ($_.Name -notmatch '^local_(.+)\.json$') { return }
        $id = $Matches[1]
        $rel = $_.FullName.Substring($sbRoot.Length).TrimStart('\')
        $target = Join-Path $DstSidebar $rel
        $marker = Join-Path (Split-Path $target) "deleted_$id"
        if (Test-Path -LiteralPath $target) { $script:sbAlready++; return }
        if (Test-Path -LiteralPath $marker) { $script:sbDeleted++; return }

        $label = '(no title)'
        try {
            $j = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
            foreach ($p in 'title', 'name', 'summary') { if ($j.PSObject.Properties[$p] -and $j.$p) { $label = [string]$j.$p; break } }
        } catch { }

        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $target
        $script:sbAdded += $label
    }
    foreach ($l in $sbAdded) { Say "  + $l" }
    Say "  $($sbAdded.Count) sidebar sessions added, $sbAlready already here, $sbDeleted deleted here (not restored)."
} elseif (Test-Path -LiteralPath $SrcSidebar) {
    Say "Sidebar sessions in export, but no Claude Desktop sidebar folder on this computer - skipped."
}

# --- Summary ---------------------------------------------------------------
Say ""
Say "=== Import complete ==="
Say ".claude: $added new files, $same identical, $keptLocal kept (this copy longer), $tookLonger took longer copy, $conflicted conflicts"
Say ".claude.json: $($projAdded.Count) projects added"
Say "Sidebar: $($sbAdded.Count) sessions added"
Say ""
Say "Backup of everything changed: $BackupDir"
if ($conflicted -gt 0) { Say "Review conflicts in: $Conflicts" }
Say "Start Claude Desktop and check the sidebar."
