<#
.SYNOPSIS
  Run one stage's declared verify and put the result IN THE LEDGER.

.DESCRIPTION
  finish-step does this too, plus diffs and the current_step advance. This script
  exists for the case that produced the worst evidence gap so far:

    someone wanted to check one stage, ran the command straight in a terminal,
    pasted the green into a chat, and the ledger never learned about it. The
    coach then acted on a green the ledger had never seen, while status kept
    answering "not verified". Three views, three answers, all defensible.

  The fix is not to forbid running commands. It is to make the accounting path
  shorter than the bypass: one line, no arguments needed, no command to memorise.

  It does NOT advance current_step. Advancing is a separate act (finish-step),
  because "it passed" and "this step is closed" are different claims and were
  being collapsed into one.

  Three outcomes, and the middle one is the one that matters:
    PASS  exit=0, not trivial, the declared command actually ran
    VOID  exit=0 but the command cannot fail (echo / --version / true) - proves
          nothing, and recording it as a pass is how stage 0.1 stood as evidence
    FAIL  exit!=0 - a counter-proof, not a pass

  Exit codes:
    0  PASS
    1  FAIL
    2  bad input (no profile / unknown step / stage declares no verify)
    3  VOID (recorded, but it establishes nothing)

.EXAMPLE
  pwsh -File verify.ps1
  pwsh -File verify.ps1 -Step 2.0.4
#>
[CmdletBinding()]
param(
    # Same defaulting rule as the other derive scripts: a script that answers
    # "up" for an input it never read is the failure the audit layer exists for.
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),
    [string] $Step = '',
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$profilePath = Join-Path $Root '.harness\project.json'
$localPath   = Join-Path $Root '.harness\local.json'
$eventsPath  = Join-Path $Root 'events.jsonl'

if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    Write-Host "[FAIL] project.json not found: $profilePath" -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------- resolve step
if ([string]::IsNullOrWhiteSpace($Step) -and (Test-Path -LiteralPath $localPath -PathType Leaf)) {
    try {
        $local = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sp = $local.PSObject.Properties['current_step']
        if ($null -ne $sp) { $Step = [string]$sp.Value }
    }
    catch { }
}
if ([string]::IsNullOrWhiteSpace($Step)) {
    Write-Host "[FAIL] no step given and local.json has no current_step" -ForegroundColor Red
    exit 2
}

$profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$stage = $null
$spp = $profile.PSObject.Properties['stages']
if ($null -ne $spp) {
    foreach ($s in @($spp.Value)) { if ([string]$s.id -eq $Step) { $stage = $s; break } }
}
if ($null -eq $stage) {
    Write-Host "[FAIL] step '$Step' not found in project.json" -ForegroundColor Red
    exit 2
}

# verify may be a single command or a list. The list form exists because real
# acceptance is several claims at once - "migrate exits 0", "running it again is
# a no-op", "the tables have the expected shape" - and a single string could only
# hold one of them. The others then lived in the coach's chat message and got run
# by hand, which is exactly how a step ends up "verified" with an empty ledger.
$verifyCmds = @()
$vp = $stage.PSObject.Properties['verify']
if ($null -ne $vp) {
    $verifyCmds = @($vp.Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
if ($verifyCmds.Count -eq 0) {
    Write-Host "[FAIL] stage $Step declares no verify - there is nothing to establish" -ForegroundColor Red
    exit 2
}
$verifyCmd = ($verifyCmds -join ' ;; ')

# ---------------------------------------------------------------- run + record
if (-not $Json) {
    Write-Host ''
    Write-Host "verify $Step" -ForegroundColor Cyan
    foreach ($vc in $verifyCmds) { Write-Host "  cmd    $vc" }
}

& (Join-Path $PSScriptRoot 'append-event.ps1') -Root $Root -Step $Step -Cmd $verifyCmds -Quiet
$appendExit = $LASTEXITCODE

if ($appendExit -eq 1) {
    # chain verification failed after append: the event may be there but the
    # ledger is broken, and a broken ledger is not a passing verify
    Write-Host "[FAIL] appended, but the ledger chain no longer verifies" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- read it back
# Deliberately re-read from the ledger instead of trusting what we just ran.
# The claim and the record are separate things; this rule exists because they
# were allowed to be the same thing.
$last = $null
if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
    foreach ($e in (Read-EventLog -Path $eventsPath)) {
        if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
        if ([string]$e.event -ne 'verify') { continue }
        if ([string]$e.step -ne $Step) { continue }
        $last = $e
    }
}

if ($null -eq $last) {
    Write-Host "[FAIL] no verify event for $Step reached the ledger" -ForegroundColor Red
    exit 2
}

$dp = $last.PSObject.Properties['data']
$ex = 1; $tr = $false; $real = $false; $dur = 0; $tail = ''
if ($null -ne $dp) {
    $dv = $dp.Value
    $px = $dv.PSObject.Properties['exit'];       if ($null -ne $px) { $ex   = [int]$px.Value }
    $pt = $dv.PSObject.Properties['trivial'];    if ($null -ne $pt) { $tr   = [bool]$pt.Value }
    $pr = $dv.PSObject.Properties['real_test'];  if ($null -ne $pr) { $real = [bool]$pr.Value }
    $pd = $dv.PSObject.Properties['duration_ms'];if ($null -ne $pd) { $dur  = [int]$pd.Value }
    $pw = $dv.PSObject.Properties['stdout_tail'];if ($null -ne $pw) { $tail = [string]$pw.Value }
}

$verdict = if ($ex -ne 0) { 'FAIL' } elseif ($tr -or -not $real) { 'VOID' } else { 'PASS' }
$seq = 0
$sqp = $last.PSObject.Properties['seq']
if ($null -ne $sqp) { $seq = [int]$sqp.Value }

if ($Json) {
    [pscustomobject]@{
        step    = $Step
        verdict = $verdict
        seq     = $seq
        exit    = $ex
        trivial = $tr
        real    = $real
        ms      = $dur
        cmd     = $verifyCmd
    } | ConvertTo-Json -Depth 4
}
else {
    $colour = switch ($verdict) { 'PASS' { 'Green' } 'VOID' { 'Yellow' } default { 'Red' } }
    Write-Host ("  result {0}  exit={1}  trivial={2}  {3} ms" -f $verdict, $ex, $tr, $dur) -ForegroundColor $colour
    if ($verdict -eq 'VOID') {
        Write-Host '         exit=0 but the command cannot fail - this establishes nothing' -ForegroundColor Yellow
    }
    # Show the output on anything that is not a pass. The record already carried it
    # (stdout_tail), but the screen did not, so a FAIL said only "exit=1" and the
    # only way to learn why was to re-run the command by hand - outside the harness,
    # which is the exact bypass this script was built to remove. A red line with no
    # reason is an invitation to go around the tool.
    if ($tail -and $verdict -ne 'PASS') {
        Write-Host ''
        Write-Host '  --- output (last ~1KB) ---' -ForegroundColor DarkGray
        foreach ($ln in ($tail -split "`r?`n")) {
            if ($ln.Trim() -ne '') { Write-Host "  $ln" -ForegroundColor Gray }
        }
        Write-Host '  --------------------------' -ForegroundColor DarkGray
    }
    Write-Host ("  ledger seq {0}  step {1}" -f $seq, $Step) -ForegroundColor DarkGray
    if ($ex -eq 0 -and $verdict -eq 'PASS') {
        Write-Host ''
        Write-Host "Next: close the step with  finish-step.ps1 -Step $Step" -ForegroundColor Cyan
    }
    Write-Host ''
}

switch ($verdict) {
    'PASS' { exit 0 }
    'VOID' { exit 3 }
    default { exit 1 }
}

