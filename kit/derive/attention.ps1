<#
.SYNOPSIS
  [v0.8 supplement] Attention layer over the existing trigger queue.
  Implements the Super-agent panel principle: "show only what needs a person;
  a healthy state takes no space." It does NOT modify or weaken any detector.
  trigger.ps1 still computes everything; this is a read-only projection plus an
  append-only human acknowledgment ledger that collapses acknowledged items.

.DESCRIPTION
  Tiers the trigger queue into:
    NEEDS YOU   - actionable codes that always require a human (never auto-collapsed)
    REVIEWABLE  - historical/replay-shaped findings; shown compactly until acknowledged
    COLLAPSED   - acknowledged findings (count only)
  Acknowledging is a human act (-Ack / -AckReviewable) recorded in
  .harness/local/attention-ack.jsonl (append-only). It is a VIEW change, not a
  rule change: the underlying trigger output is untouched and still exit-3.

  Skeleton invariants preserved: ledger-as-fact, human-signs-irreversible,
  capability-boundary, detectors-recompute. This script only reduces noise.

.EXAMPLE
  pwsh -File attention.ps1                 # tiered view
  pwsh -File attention.ps1 -AckReviewable  # human: collapse the historical set once
  pwsh -File attention.ps1 -Ack T3_out_of_scope -Step 2.0.1 -Key <sha12>
#>
[CmdletBinding()]
param(
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),
    [switch] $AckReviewable,
    [string] $Ack = '',
    [string] $Step = '',
    [string] $Key = '',
    [switch] $Quiet
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Codes that ALWAYS need a human; never suggested for bulk ack, never auto-collapsed.
$actionable = @('T13_unrecorded_write','T14_green_no_artifact_change','T14b_exam_only','T15_universe_moved',
                'T10_running_ahead','T8_chain_broken','T4_rework','C7_drift','C10_harness','T16_stale_gate')

$ackPath = Join-Path $Root '.harness\local\attention-ack.jsonl'
$acks = @{}
if (Test-Path -LiteralPath $ackPath -PathType Leaf) {
    foreach ($l in @(Get-Content -LiteralPath $ackPath -Encoding UTF8)) {
        if (-not $l.Trim()) { continue }
        try { $a = $l | ConvertFrom-Json } catch { continue }
        $acks[("$($a.code)|$($a.step)|$($a.key)")] = $true
        $acks[("$($a.code)|$($a.step)|*")] = $true   # step-level ack
    }
}

function Key-Of([string]$detail) {
    $b = [System.Text.Encoding]::UTF8.GetBytes($detail)
    $h = [System.Security.Cryptography.SHA256]::Create().ComputeHash($b)
    return ([BitConverter]::ToString($h) -replace '-','').Substring(0,12).ToLower()
}

# Run the UNMODIFIED trigger; parse its finding lines.
$trig = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'trigger.ps1') -Root $Root 2>&1 | Out-String
$open = [System.Collections.Generic.List[object]]::new()
$collapsed = 0
foreach ($line in ($trig -split "`r?`n")) {
    $m = [regex]::Match($line.Trim(), '^(T\d+[A-Za-z_]*|C\d+[A-Za-z_]*)\s+(\S+)\s*(.*)$')
    if (-not $m.Success) { continue }
    $code = $m.Groups[1].Value; $stp = $m.Groups[2].Value; $detail = $m.Groups[3].Value
    $k = Key-Of $detail
    if ($acks.ContainsKey("$code|$stp|$k") -or $acks.ContainsKey("$code|$stp|*")) { $collapsed++; continue }
    $isTemp = ($code -eq 'T3_out_of_scope') -and ($detail -match 'AppData/Local/Temp|/Temp/')
    $tier = if (($actionable -contains $code) -or (($code -eq 'T3_out_of_scope') -and -not $isTemp)) { 'NEEDS' } else { 'REVIEW' }
    $open.Add([pscustomobject]@{ code=$code; step=$stp; detail=$detail; key=$k; tier=$tier })
}

# P0: observe conflicts (living-spec / 立即纠错) join NEEDS YOU.
$obsPath = Join-Path $Root '.harness\local\observe-report.json'
if (Test-Path -LiteralPath $obsPath -PathType Leaf) {
    try {
        $obs = Get-Content -LiteralPath $obsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($c in @($obs.conflicts)) {
            $code = 'OBS_' + [string]$c.code
            $detail = ("{0} | 原话:{1} | 观测:{2} | {3}" -f $c.file, $c.original, $c.observed, $c.action)
            $k = Key-Of $detail
            if ($acks.ContainsKey("$code|$($c.step)|$k") -or $acks.ContainsKey("$code|$($c.step)|*")) { $collapsed++; continue }
            $open.Add([pscustomobject]@{ code=$code; step=[string]$c.step; detail=$detail; key=$k; tier='NEEDS' })
        }
    } catch { }
}

# Human ack actions (append-only).
if ($AckReviewable -or $Ack -ne '') {
    New-Item -ItemType Directory -Force -Path (Split-Path $ackPath) | Out-Null
    $targets = if ($AckReviewable) { @($open | Where-Object { $_.tier -eq 'REVIEW' }) } else {
        @([pscustomobject]@{ code=$Ack; step=$Step; key=$(if ($Key) { $Key } else { '*' }) })
    }
    foreach ($t in $targets) {
        $rec = [ordered]@{ code=$t.code; step=$t.step; key=$t.key; at=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); by='human' }
        Add-Content -LiteralPath $ackPath -Value (ConvertTo-Json $rec -Compress) -Encoding UTF8
    }
    if (-not $Quiet) { Write-Host ("[attention] acknowledged {0} item(s); they collapse on next run." -f $targets.Count) -ForegroundColor Green }
    exit 0
}

$needs = @($open | Where-Object { $_.tier -eq 'NEEDS' })
$review = @($open | Where-Object { $_.tier -eq 'REVIEW' })
if (-not $Quiet) {
    Write-Host ''
    Write-Host ("NEEDS YOU ({0}) - actionable, a human must act:" -f $needs.Count) -ForegroundColor $(if ($needs.Count) { 'Yellow' } else { 'Green' })
    foreach ($n in $needs) { Write-Host ("  {0}  {1}  {2}" -f $n.code, $n.step, $n.detail) }
    Write-Host ("REVIEWABLE ({0}) - historical/replay; run -AckReviewable to collapse once:" -f $review.Count) -ForegroundColor DarkGray
    foreach ($r in $review) { Write-Host ("  {0}  {1}  {2}" -f $r.code, $r.step, ($r.detail.Substring(0,[Math]::Min(70,$r.detail.Length)))) -ForegroundColor DarkGray }
    Write-Host ("COLLAPSED (acknowledged): {0}" -f $collapsed) -ForegroundColor DarkGray
    Write-Host '[attention] projection only (v0.8); trigger.ps1 unchanged and still authoritative.' -ForegroundColor DarkGray
}
exit 0
