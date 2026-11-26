<#
.SYNOPSIS
  [v0.8 supplement] Zero-LLM relay assistant. Removes the human's
  formatting/copying burden between coach and coding agent WITHOUT adding any
  autonomy over writes. It only formats and prepares paste blocks; a human still
  pastes and still signs. Inspired by Super-agent intake/assignments fast path
  (programmatic routing), but deliberately NOT auto-executing anything.

.DESCRIPTION
  -ToCoder -Card <file>   : coach card  -> clean paste block for the coding agent
  -ToCoach -Result <file> : coder output -> paste block back to the coach
  -Next                   : read ledger tail, print the newest business events as
                            a "relay ready" digest (event-driven prep, no LLM)

  Skeleton preserved: no write, no sign, no execute. Pure text projection.

.EXAMPLE
  pwsh -File relay.ps1 -ToCoder -Card card.md
  pwsh -File relay.ps1 -ToCoach -Result out.txt
  pwsh -File relay.ps1 -Next
#>
[CmdletBinding()]
param(
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),
    [switch] $ToCoder,
    [switch] $ToCoach,
    [switch] $Next,
    [string] $Card = '',
    [string] $Result = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Text([string]$p) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "file not found: $p" }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8)
}

if ($ToCoder) {
    $t = Read-Text $Card
    # drop coach self-attestation + relay meta; keep the actionable 4-layer body
    $lines = $t -split "`r?`n" | Where-Object { $_ -notmatch '^ROLE=coach' -and $_ -notmatch '执行完把结果' }
    Write-Host '```'
    Write-Host (($lines -join "`n").Trim())
    Write-Host '```'
    exit 0
}
if ($ToCoach) {
    $t = Read-Text $Result
    Write-Host '```'
    Write-Host ('编码 agent 执行结果（原文）：' + "`n" + $t.Trim())
    Write-Host '```'
    exit 0
}
if ($Next) {
    $ep = Join-Path $Root 'events.jsonl'
    if (-not (Test-Path $ep)) { Write-Host 'no ledger'; exit 0 }
    $tail = @(Get-Content -LiteralPath $ep -Encoding UTF8 -Tail 40)
    $biz = foreach ($l in $tail) {
        try { $j = $l | ConvertFrom-Json } catch { continue }
        if ($j.event -in @('verify','step_advance','contract_change','gate','deviate')) {
            $dp = $j.PSObject.Properties['data']; $d = ''
            if ($null -ne $dp) {
                foreach ($f in 'result','file','name') {
                    $fp = $dp.Value.PSObject.Properties[$f]
                    if ($null -ne $fp -and [string]$fp.Value) { $d = [string]$fp.Value; break }
                }
            }
            [pscustomobject]@{ seq=$j.seq; at=$j.at; ev=$j.event; step=$j.step; d=$d }
        }
    }
    Write-Host 'relay ready (newest business events, paste to coach as context):'
    foreach ($b in @($biz | Select-Object -Last 8)) { Write-Host ("  seq {0} {1} {2} {3} {4}" -f $b.seq,$b.at,$b.ev,$b.step,$b.d) }
    exit 0
}
Write-Host 'usage: -ToCoder -Card <f> | -ToCoach -Result <f> | -Next'
exit 0
