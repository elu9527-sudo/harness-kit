<#
.SYNOPSIS
  Verify the append-only event log: schema, monotonic seq, per-record hash, prev-chain.

.DESCRIPTION
  Exit codes:
    0  chain intact
    1  chain broken (schema / seq / self / prev)
    2  log missing or empty (nothing to verify -> not a pass)

.EXAMPLE
  pwsh -File verify-ledger.ps1 -Path D:\proj\events.jsonl
#>
[CmdletBinding()]
param(
    [string] $Path = (Join-Path (Get-Location) 'events.jsonl'),
    [switch] $Json,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$REQUIRED = @('v', 'seq', 'at', 'step', 'kind', 'actor', 'event', 'data', 'prev', 'self')

function Get-Prop {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

$issues = [System.Collections.Generic.List[object]]::new()

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    $result = [pscustomobject]@{
        ok       = $false
        status   = 'missing'
        path     = $Path
        records  = 0
        head     = ''
        issues   = @([pscustomobject]@{ line = 0; seq = 0; kind = 'missing_file'; detail = "event log not found: $Path" })
    }
    if ($Json) { $result | ConvertTo-Json -Depth 6 } elseif (-not $Quiet) { Write-Host "[FAIL] event log not found: $Path" -ForegroundColor Red }
    exit 2
}

$records = Read-EventLog -Path $Path
if ($records.Count -eq 0) {
    $result = [pscustomobject]@{
        ok      = $false
        status  = 'empty'
        path    = $Path
        records = 0
        head    = ''
        issues  = @([pscustomobject]@{ line = 0; seq = 0; kind = 'empty_log'; detail = 'log exists but contains no records' })
    }
    if ($Json) { $result | ConvertTo-Json -Depth 6 } elseif (-not $Quiet) { Write-Host '[FAIL] event log is empty' -ForegroundColor Red }
    exit 2
}

$expectedSeq = 1
$prevSelf    = ''
$head        = ''

foreach ($rec in $records) {
    $line = Get-Prop $rec '__line'
    $seq  = $null

    if ($null -ne (Get-Prop $rec '__parse_error')) {
        $issues.Add([pscustomobject]@{ line = $line; seq = 0; kind = 'parse_error'; detail = (Get-Prop $rec '__parse_error') })
        continue
    }

    foreach ($field in $REQUIRED) {
        if ($null -eq (Get-Prop $rec $field)) {
            $issues.Add([pscustomobject]@{ line = $line; seq = (Get-Prop $rec 'seq'); kind = 'schema'; detail = "missing field '$field'" })
        }
    }

    $seq = Get-Prop $rec 'seq'
    if ($null -ne $seq) {
        if ([int]$seq -ne $expectedSeq) {
            $issues.Add([pscustomobject]@{ line = $line; seq = $seq; kind = 'seq_gap'; detail = "expected seq $expectedSeq, found $seq" })
        }
        $expectedSeq = [int]$seq + 1
    }

    $recordedSelf = [string](Get-Prop $rec 'self')
    $computedSelf = Get-EventRecordHash -Record $rec
    if ($recordedSelf -ne $computedSelf) {
        $issues.Add([pscustomobject]@{
            line = $line; seq = $seq; kind = 'self_mismatch'
            detail = "recorded=$recordedSelf computed=$computedSelf"
        })
    }

    $recordedPrev = [string](Get-Prop $rec 'prev')
    if ($recordedPrev -ne $prevSelf) {
        $issues.Add([pscustomobject]@{
            line = $line; seq = $seq; kind = 'prev_mismatch'
            detail = "recorded=$recordedPrev expected=$prevSelf"
        })
    }

    $prevSelf = $recordedSelf
    $head     = $recordedSelf
}

$ok = ($issues.Count -eq 0)
$result = [pscustomobject]@{
    ok      = $ok
    status  = if ($ok) { 'intact' } else { 'broken' }
    path    = $Path
    records = $records.Count
    head    = $head
    issues  = $issues.ToArray()
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
}
elseif (-not $Quiet) {
    if ($ok) {
        $short = if ($head.Length -ge 12) { $head.Substring(0, 12) } else { $head }
        Write-Host "[OK] $($records.Count) records, chain intact, head=$short" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] chain broken: $($issues.Count) issue(s)" -ForegroundColor Red
        foreach ($i in $issues) {
            Write-Host ("  line {0} (seq {1}) {2}: {3}" -f $i.line, $i.seq, $i.kind, $i.detail) -ForegroundColor Red
        }
    }
}

if ($ok) { exit 0 } else { exit 1 }
