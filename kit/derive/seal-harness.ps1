<#
.SYNOPSIS
  Pin the current harness digest into the ledger, so a run can be reproduced.

.DESCRIPTION
  The harness edits itself. derive scripts, rules, contracts and hooks all live
  under .harness/ and are maintained outside the three-role loop, which means an
  edit there leaves no trace in events.jsonl. That is not theoretical: four derive
  scripts were modified in the middle of an observation window, after which the
  end-to-end was no longer reproducible and nobody could say from the ledger which
  version of the rules had actually been running.

  This pins the digest the way a lockfile pins dependency versions - same role as
  `package-lock.json`'s `integrity` field, which exists so that "what actually ran"
  is a checkable fact rather than an assumption.

  Sealing is deliberately manual. Auto-sealing on every edit would record whatever
  happened to be on disk, which is exactly the "overwrite the baseline" mistake
  AIDE warns about. Run this after you have reviewed and deployed a change.

  audit.ps1's C10 reports when the on-disk digest has no matching anchor here.

.PARAMETER Why
  One line describing the change being pinned. Ends up in the event.

.EXAMPLE
  pwsh -File seal-harness.ps1
  pwsh -File seal-harness.ps1 -Why "rewire T3/T4 onto tool_use; add audit.ps1"
#>
[CmdletBinding()]
param(
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),
    [string] $Why = 'harness digest pinned after review',
    # Escape hatch for a large harness where one event per file is too much
    # ledger noise. Off by default: the per-file records are what make C7 able
    # to see a harness edit at all.
    [switch] $SkipFileRecords,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$hRoot = Join-Path $Root '.harness'
if (-not (Test-Path -LiteralPath $hRoot)) {
    Write-Host "[FAIL] no .harness/ under $Root" -ForegroundColor Red
    exit 2
}

# One definition, shared with audit.ps1's C10 - two implementations of the same
# digest would drift and the seal would never match the check.
$digest = Get-HarnessDigest -ProjectRoot $Root
$hf = @($digest.files)
if ($hf.Count -eq 0) {
    Write-Host '[FAIL] no harness files found to digest' -ForegroundColor Red
    exit 2
}

$harnessSha = $digest.sha256

$payload = [ordered]@{
    name   = 'harness'
    value  = 'verified'
    sha256 = $harnessSha
    files  = $hf.Count
    why    = $Why
}
$json = ConvertTo-Json -InputObject $payload -Depth 4 -Compress

& (Join-Path $PSScriptRoot 'append-event.ps1') -Root $Root -Event anchor -Actor 'script' -Step 'harness' -DataJson $json -Quiet
$rc = $LASTEXITCODE

# Register every harness file individually as well, not just the tree digest.
#
# The whole-tree anchor answers "is this a harness I signed off on". It cannot
# answer "did a file change since then" - and every harness change in this
# project so far arrived by copying a template into .harness/derive/, which is a
# Copy-Item: no Write tool call, no hook, no event. Four script rewrites on
# 13:37 and 13:38 left nothing behind, and C7 said 0 drifted because C7 walks
# stage.generates and no stage owns .harness/.
#
# With a per-file record, C7's ordinary refresh-only comparison covers the
# harness too: any edit after a seal shows up as drift until the next seal.
# Sealing therefore means "I reviewed this harness and I am vouching for THESE
# bytes", which is the same statement a lockfile integrity field makes.
if ($rc -eq 0 -and -not $SkipFileRecords) {
    foreach ($f in $hf) {
        $relF = [string]$f.id
        if ($relF -eq '') { continue }
        # Only project-relative entries can be recorded: data.file is resolved
        # against the project root, and the hook files live in the kit tree on a
        # different path entirely. Those still move the tree digest, so C10
        # covers them; this per-file record covers the copies inside .harness/.
        if ($relF -notlike '.harness/*') { continue }
        $fj = ConvertTo-Json -InputObject ([ordered]@{ file = $relF; tool = 'seal'; why = "pinned by seal-harness ($($Why))" }) -Depth 3 -Compress
        # -Step 'harness', not the default. Without it these records inherit
        # local.json's current_step and every downstream rule that asks "did this
        # stage produce events" answers yes for a stage nobody has touched.
        & (Join-Path $PSScriptRoot 'append-event.ps1') -Root $Root -Event tool_use -Actor 'script' -Step 'harness' -DataJson $fj -Quiet
        if ($LASTEXITCODE -ne 0) { $rc = $LASTEXITCODE; break }
    }
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host ("sealed harness  {0}  ({1} files)" -f $harnessSha.Substring(0, [Math]::Min(12, $harnessSha.Length)), $hf.Count) -ForegroundColor Green
    Write-Host "  audit C10 will now match this digest" -ForegroundColor DarkGray
    if (-not $SkipFileRecords) {
        Write-Host ("  C7 now tracks each of the {0} files individually" -f $hf.Count) -ForegroundColor DarkGray
    }
    Write-Host ''
}

if ($rc -ne 0) { exit $rc }
exit 0
