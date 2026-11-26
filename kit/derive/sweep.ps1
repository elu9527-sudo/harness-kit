<#
.SYNOPSIS
  etckeeper's idea for this ledger: do not trust writers to report themselves.
  A separate process compares disk against the ledger and records every
  disagreement as a fact.

.DESCRIPTION
  On 2026-11-07 a process running parallel to Claude Code modified
  contracts/ip_provider_interface.py and docs/变更记录.md TWICE inside gaps where
  the hook demonstrably recorded other writes (observer #4, O4-01/O4-22). The
  second insertion even declared itself "the single source of truth for
  exemptions". PostToolUse coverage cannot reach writers it does not own, and
  C7 could only ever report the disagreement TRANSIENTLY: any later legitimate
  write re-registers the digest and the historical anomaly vanishes from the
  ledger's memory (O4-14).

  etckeeper has solved the same class of problem on a million machines: nobody
  is trusted to remember a commit, so an hourly job snapshots everything
  regardless of provenance. This is that job, pointed at the ledger: disk sha
  vs last recorded sha, per covered file, TWICE with a settle delay (a torn read
  of a file being written is not a fact worth recording), and any stable
  disagreement becomes an `unrecorded_write` event - a machine observation with
  no explanation in it.

  Explaining stays human work: the audit and T13 keep asking until someone runs
  record-edit.ps1 for that file. Sweep never writes the tool_use digest itself,
  so it cannot launder its own findings the way a re-registering write launders
  C7's.

  Safe to run on a schedule; safe to run manually; safe to run while the agents
  work (shared create-exclusive lock, stability check, no-op guard).

.EXAMPLE
  pwsh -File .harness\derive\sweep.ps1                    # scan + record
.EXAMPLE
  pwsh -File .harness\derive\sweep.ps1 -DryRun            # show only

.OUTPUTS
  exit 0 no new findings (or all recorded)
  exit 1 could not record something
#>
[CmdletBinding()]
param(
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),

    # delay between the two stability reads; a file that changes between them is
    # mid-write by somebody and the next sweep round will catch the settled state
    [int] $SettleMs = 2000,

    [switch] $DryRun,
    # etckeeper's other half: the FIRST registration of files that predate the
    # hook. They are not drift - nobody wrote them unnoticed - they simply were
    # never baselined. -Baseline gives every no-previous-digest file its initial
    # tool_use record and leaves genuine disagreements for record-edit.
    [switch] $Baseline,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$eventsPath  = Join-Path $Root 'events.jsonl'
$profPath    = Join-Path $Root '.harness\project.json'
$appendPath  = Join-Path $PSScriptRoot 'append-event.ps1'

if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) {
    if (-not $Quiet) { Write-Host '[sweep] no ledger yet - nothing to compare against' -ForegroundColor Yellow }
    exit 0
}
if (-not (Test-Path -LiteralPath $appendPath -PathType Leaf)) {
    Write-Host "[FAIL] append-event.ps1 missing: $appendPath" -ForegroundColor Red
    exit 1
}

$events = @(Read-EventLog -Path $eventsPath)

# ------------------------------------------------ coverage set
# 1) every file the ledger has ever carried a digest for,
# 2) every file any stage declares it generates.
# The harness's own tree is deliberately NOT covered: its drift is seal's job
# (C7 'harness' + C10), and mixing the two would let sweep rewrite re-register
# harness edits as "unrecorded writes" every time the user deploys kit changes.
$excl = '^(\.harness/|events\.jsonl|docs/_snap/|docs/_diff/|__pycache__/|\.venv/|_vendor/|node_modules/|.*\.bak(-.*)?$)'
$tracked = @{}   # rel -> last recorded sha (tool_use data.sha256) + seq
foreach ($e in $events) {
    if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
    if ([string]$e.event -ne 'tool_use') { continue }
    $dp = $e.PSObject.Properties['data']; if ($null -eq $dp) { continue }
    $fp = $dp.Value.PSObject.Properties['file']
    $sp = $dp.Value.PSObject.Properties['sha256']
    if ($null -eq $fp -or $null -eq $sp) { continue }
    $rel = ([string]$fp.Value) -replace '\\', '/'
    if ($rel -match $excl) { continue }
    $shaV = [string]$sp.Value
    if ($shaV -notmatch '^[0-9a-f]{64}$') { continue }
    $sqp = $e.PSObject.Properties['seq']
    $tracked[$rel] = @{ sha = $shaV; seq = $(if ($null -ne $sqp) { [int]$sqp.Value } else { 0 }) }
}
$ownerOf = @{}
if (Test-Path -LiteralPath $profPath -PathType Leaf) {
    try {
        $prof = Get-Content -LiteralPath $profPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($st in @($prof.stages)) {
            $gp = $st.PSObject.Properties['generates']
            if ($null -eq $gp) { continue }
            foreach ($g in @($gp.Value)) {
                $rel = ([string]$g) -replace '\\', '/'
                if ($rel -match $excl) { continue }
                if (-not $tracked.ContainsKey($rel)) { $tracked[$rel] = $null }
                $ownerOf[$rel] = [string]$st.id
            }
        }
    }
    catch { }
}

# already-observed: the latest unrecorded_write per file and the disk sha it saw
$sweepSeen = @{}
foreach ($e in $events) {
    if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
    if ([string]$e.event -ne 'unrecorded_write') { continue }
    $dp = $e.PSObject.Properties['data']; if ($null -eq $dp) { continue }
    $fp = $dp.Value.PSObject.Properties['file']
    $sp = $dp.Value.PSObject.Properties['disk_sha256']
    if ($null -ne $fp -and $null -ne $sp) { $sweepSeen[[string]$fp.Value] = [string]$sp.Value }
}

# ------------------------------------------------ compare with settle
$findings = @()
$recorded = 0
$appendFailed = 0
foreach ($rel in @($tracked.Keys | Sort-Object)) {
    $abs = Join-Path $Root ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }   # absence is C6/C7's domain, not sweep's
    $h1 = Get-FileSha256Hex -Path $abs
    Start-Sleep -Milliseconds $SettleMs
    $h2 = Get-FileSha256Hex -Path $abs
    if ($h1 -ne $h2) { continue }                                          # mid-write; settle next round
    $rec = $tracked[$rel]
    $recSha = if ($null -ne $rec) { [string]$rec.sha } else { '' }
    if ($h1 -eq $recSha) { continue }                       # disk matches the last REGISTRATION - nothing observed
    # The already-observed guard stops round-N re-emitting round-(N-1)'s
    # identical unrecorded_write. -Baseline deliberately passes it through:
    # pre-hook files were "observed" first and need the REGISTRATION that
    # observation alone cannot give; after the baseline tool_use lands, the
    # equality check above ends the file's participation by itself.
    if (-not $Baseline -and [string]$sweepSeen[$rel] -eq $h1) { continue }
    $findings += [pscustomobject]@{
        file       = $rel
        disk       = $h1
        recorded   = $recSha
        recordedAt = $(if ($null -ne $rec) { $rec.seq } else { 0 })
        step       = $(if ($ownerOf.ContainsKey($rel)) { $ownerOf[$rel] } elseif ($null -ne $rec) { 'tracked' } else { 'unowned' })
        mtime      = (Get-Item -LiteralPath $abs).LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')
    }
}

if ($findings.Count -eq 0) {
    if (-not $Quiet) { Write-Host ("[sweep] {0} files covered, disk matches ledger" -f $tracked.Count) -ForegroundColor Green }
    if (-not $DryRun) {
        try {
            $hb = [ordered]@{ last_run = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); covered = $tracked.Count; findings = 0; recorded = 0 }
            [System.IO.File]::WriteAllText((Join-Path $Root '.harness\sweep-status.json'), (ConvertTo-Json -InputObject $hb -Compress), (New-Object System.Text.UTF8Encoding($false)))
        }
        catch { }
    }
    exit 0
}

foreach ($fd in $findings) {
    # genuine drift stays for a human; in -Baseline mode it was (or will be)
    # observed by a normal round - do not re-emit the same unrecorded_write here
    if ($Baseline -and $fd.recorded -ne '') { continue }
    if ($Baseline -and $fd.recorded -eq '') {
        Write-Host ("[sweep] baseline: {0}  (disk {1}...; never recorded - pre-hook file)" -f $fd.file, $fd.disk.Substring(0, 12)) -ForegroundColor DarkGray
    }
    else {
        Write-Host ("[sweep] unrecorded change: {0}  (disk {1}... vs last recorded {2}... @seq {3}; mtime {4})" -f `
            $fd.file, $fd.disk.Substring(0, 12), $(if ($fd.recorded) { $fd.recorded.Substring(0, 12) } else { '(none)' }), $fd.recordedAt, $fd.mtime) -ForegroundColor Yellow
    }
    if ($DryRun) { continue }
    $payload = [ordered]@{
        file                  = $fd.file
        disk_sha256           = $fd.disk
        last_recorded_sha256  = $fd.recorded
        last_recorded_seq     = $fd.recordedAt
        file_mtime            = $fd.mtime
        note                  = 'machine observation by sweep: disk no longer matches the ledger and no tool_use covers the change. Explaining it (who/why) is a human or hermes act - run record-edit.ps1'
    }
    $evt = 'unrecorded_write'
    if ($Baseline -and $fd.recorded -eq '') {
        # a baseline is a REGISTRATION (tool_use with a digest), not an
        # observation - after it, C7/T13 go quiet for that file because the
        # ledger finally knows what the file is
        $evt = 'tool_use'
        $payload = [ordered]@{
            file        = $fd.file
            tool        = 'baseline'
            observed_by = 'script'
            why         = 'initial registration of a pre-hook file by sweep -Baseline; its content at this moment is the accepted starting state'
        }
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-sweep-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    try {
        # O5-02: the tracked snapshot was read BEFORE ~1s-per-file settle passes;
        # a writer that legitimately registered the file in between would be
        # reported as a permanent unrecorded_write for a sha that is already in
        # the ledger (observed: seq 730 registered docs/变更记录.md at 16:52:23,
        # sweep appended a false observation of the SAME sha at 16:52:59).
        # Re-read this one file's newest ledger digest NOW; if the disagreement
        # evaporated, drop the finding before it becomes an uncorrectable fact.
        $freshLatest = ''
        foreach ($fl in [System.IO.File]::ReadLines($eventsPath, [System.Text.Encoding]::UTF8)) {
            if ($fl -notmatch '"event":"tool_use"') { continue }
            try { $fr = $fl | ConvertFrom-Json } catch { continue }
            # Properties guard, not bare property access: Bash tool_use rows carry no
            # data.file, and `$fr.data.file` under StrictMode would throw right HERE -
            # in the recheck that only runs when findings exist, i.e. the round the
            # patrol most needs to survive (same family as audit L469, caught 11-10).
            if ($null -eq $fr.data) { continue }
            $ffp = $fr.data.PSObject.Properties['file']
            if ($null -eq $ffp) { continue }
            if ((([string]$ffp.Value) -replace '\\', '/') -ne $fd.file) { continue }
            $sfp = $fr.data.PSObject.Properties['sha256']
            if ($null -eq $sfp) { continue }
            $frs = [string]$sfp.Value
            if ($frs -match '^[0-9a-f]{64}$') { $freshLatest = $frs }
        }
        if ($freshLatest -eq $fd.disk) { continue }
        [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $payload -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        & pwsh -NoProfile -File $appendPath -Root $Root -Event $evt -Step $fd.step -DataJsonFile $tmp -Quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("[sweep] FAILED to record {0} (append-event exit {1})" -f $fd.file, $LASTEXITCODE) -ForegroundColor Red
            # 2026-11-09 observer #6: this branch used to `exit 1` HERE - the
            # round that had findings (the ones most worth recording) lost its
            # heartbeat AND skipped every remaining file. Count, continue, exit
            # only after the heartbeat lands.
            $appendFailed++
        }
        else { $recorded++ }
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
if (-not $Quiet -and -not $DryRun) {
    Write-Host ("[sweep] {0} observation(s)/registration(s) written; unexplained changes stay in T13 until record-edit answers them" -f $recorded) -ForegroundColor Yellow
}
if (-not $DryRun) {
    try {
        $hb = [ordered]@{ last_run = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); covered = $tracked.Count; findings = $findings.Count; recorded = $recorded; failed = $appendFailed }
        [System.IO.File]::WriteAllText((Join-Path $Root '.harness\sweep-status.json'), (ConvertTo-Json -InputObject $hb -Compress), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}
if ($appendFailed -gt 0) { exit 1 }
exit 0