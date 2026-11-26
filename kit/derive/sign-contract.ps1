<#
.SYNOPSIS
  Land a human-signed contract_change for files OTHER than .harness/project.json.

.DESCRIPTION
  stage-add / validate-profile already own the project.json signature path.
  Everything else (AGENTS.md, 04, contracts/**) had no way for the human to say
  "I reviewed this diff and accept it" - record-edit proves WHO wrote and WHAT
  changed, but a write note is not an approval. This script adds the approval:
  one contract_change event with approved_by=human, pinned to hashes.

  Provenance rule (the whole point): before_sha256 comes ONLY from the ledger -
  the most recent tool_use record for this file (its data.before_sha256 = the
  digest the last recorded write superseded). -BeforeSha is a cross-check, never
  a source; an empty ledger before_sha256 is "no provenance", not "from zero".
  The reason text comes ONLY from a UTF-8 file (-WhyFile): argv has destroyed
  Chinese on this machine twice (11-07), so there is no inline -Why by design.

  Workflow: edit the file by hand -> record-edit.ps1 (write enters ledger) ->
  this script (human signs before..after).

.PARAMETER Root
  Project root. Default: two levels up from $PSScriptRoot.

.PARAMETER File
  Project-relative path of the file being signed. Required.

.PARAMETER WhyFile
  Path of a UTF-8 text file holding the human's reason. Required.

.PARAMETER BeforeSha
  Optional. Cross-check only; must equal the ledger's before_sha256.

.EXAMPLE
  pwsh -File .harness\derive\sign-contract.ps1 -File AGENTS.md -WhyFile .harness\local\why.txt -DryRun
  pwsh -File .harness\derive\sign-contract.ps1 -File AGENTS.md -WhyFile .harness\local\why.txt

.OUTPUTS
  exit 0 signed (or dry-run / cancelled)
  exit 1 ledger append failed / stdin redirected (same rule as stage-add)
  exit 2 bad arguments / precondition missing (file, ledger record, reason)
#>
[CmdletBinding()]
param(
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),
    [string] $File = '',
    [string] $WhyFile = '',
    [string] $BeforeSha = '',
    [switch] $DryRun,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

# ---------------------------------------------------------------- 2: -File required
$fileNorm = ([string]$File).Trim() -replace '\\', '/'
if ($fileNorm -eq '') {
    Write-Host '[FAIL] -File 必填' -ForegroundColor Red
    exit 2
}

# resolve to absolute, then to the project-relative forward-slash form the
# ledger uses (same normalisation as record-edit, or every join misses)
$absFile = if ([System.IO.Path]::IsPathRooted($fileNorm)) {
    [System.IO.Path]::GetFullPath($fileNorm)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $Root $fileNorm))
}
$rel = try { [System.IO.Path]::GetRelativePath($Root, $absFile).Replace('\', '/') } catch { $fileNorm }

# ---------------------------------------------------------------- 3: project.json is not ours
if ($rel -eq '.harness/project.json') {
    Write-Host '[FAIL] project.json 的契约变更走 validate-profile.ps1 -SyncBaseline -Accept 或 stage-add.ps1' -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------- 4: file must exist
if (-not (Test-Path -LiteralPath $absFile -PathType Leaf)) {
    Write-Host "[FAIL] 文件不存在: $absFile" -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------- 5/6: reason via file channel only
$whyNorm = ([string]$WhyFile).Trim()
if ($whyNorm -eq '') {
    Write-Host '[FAIL] -WhyFile 必填（理由必须走文件通道，argv 会毁中文）' -ForegroundColor Red
    exit 2
}
$whyAbs = if ([System.IO.Path]::IsPathRooted($whyNorm)) {
    [System.IO.Path]::GetFullPath($whyNorm)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $Root $whyNorm))
}
# guard BEFORE reading: a missing why file must die with exit 2 here,
# not as an uncaught Get-Content terminating error (that would exit 1 and
# make the probe step on the wrong code)
if (-not (Test-Path -LiteralPath $whyAbs -PathType Leaf)) {
    Write-Host "[FAIL] 理由文件不存在: $whyAbs" -ForegroundColor Red
    Write-Host '       用编辑器写理由后另存为 UTF-8，再把路径传给 -WhyFile。' -ForegroundColor DarkGray
    exit 2
}

# ---------------------------------------------------------------- 7: after = disk now
$afterSha = Get-FileSha256Hex -Path $absFile

# ---------------------------------------------------------------- 8: before = ledger ONLY
$eventsPath = Join-Path $Root 'events.jsonl'
$ledgerBefore = $null
$recs = @(Read-EventLog -Path $eventsPath)
# REVERSE scan: the MOST RECENT tool_use for this file wins (spec: 倒序找最近一条)
for ($i = $recs.Count - 1; $i -ge 0; $i--) {
    $e0 = $recs[$i]
    if ($null -ne $e0.PSObject.Properties['__parse_error']) { continue }
    if ($null -eq $e0.PSObject.Properties['event']) { continue }
    if ([string]$e0.event -ne 'tool_use') { continue }
    $d0 = $e0.PSObject.Properties['data']
    if ($null -eq $d0 -or $null -eq $d0.Value) { continue }
    $f0 = $d0.Value.PSObject.Properties['file']
    if ($null -eq $f0) { continue }
    if (([string]$f0.Value).Trim().Replace('\', '/') -ne $rel) { continue }
    # most recent wins; take its before_sha256 (missing property = '' = no provenance)
    $b0 = $d0.Value.PSObject.Properties['before_sha256']
    $ledgerBefore = $(if ($null -ne $b0) { ([string]$b0.Value).Trim() } else { '' })
    break
}
if ($null -eq $ledgerBefore -or $ledgerBefore -eq '') {
    Write-Host '[FAIL] 账本里没有这个文件的写入记录' -ForegroundColor Red
    Write-Host "[HINT] 先跑 pwsh -File .harness\derive\record-edit.ps1 -File $rel" -ForegroundColor Yellow
    exit 2
}

# ---------------------------------------------------------------- 9: -BeforeSha is a check, not a source
if (-not [string]::IsNullOrWhiteSpace($BeforeSha)) {
    $bs = ([string]$BeforeSha).Trim()
    if ($bs -cnotmatch '^[0-9a-f]{64}$') {
        Write-Host '[FAIL] -BeforeSha 必须匹配 ^[0-9a-f]{64}$（64 位小写十六进制）' -ForegroundColor Red
        exit 2
    }
    if ($bs -ne $ledgerBefore) {
        Write-Host "[FAIL] -BeforeSha 与账本不一致（账本=$($ledgerBefore)，你给=$($bs)），账本是唯一来源" -ForegroundColor Red
        exit 2
    }
}

$before12 = if ($ledgerBefore.Length -ge 12) { $ledgerBefore.Substring(0, 12) } else { $ledgerBefore }
$after12  = if ($afterSha.Length -ge 12) { $afterSha.Substring(0, 12) } else { $afterSha }

# ---------------------------------------------------------------- 10: reason from file
$whyRaw = [string](Get-Content -LiteralPath $whyAbs -Raw -Encoding UTF8)
$whyText = ((@($whyRaw -split "`r?`n") | ForEach-Object { $_.Trim() }) -join ' ').Trim()
# no extra rules beyond Get-ReasonProblem's own set (empty / control chars /
# no letters / too short / repeated single character) - deliberately no
# history comparison here
$problem = Get-ReasonProblem -Text $whyText
if ($problem -ne '') {
    Write-Host "[FAIL] 理由不合格：$problem" -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------- 11: preview + human confirm
if (-not $Quiet) {
    Write-Host ''
    Write-Host '[sign-contract] 预览 ─────────────────────────' -ForegroundColor DarkGray
    Write-Host ("  file   : {0}" -f $rel)
    Write-Host ("  before : {0}" -f $before12)
    Write-Host ("  after  : {0}" -f $after12)
    Write-Host ("  why    : {0}" -f $(if ($whyText.Length -gt 120) { $whyText.Substring(0, 120) } else { $whyText }))
    Write-Host '  ───────────────────────────────────────────' -ForegroundColor DarkGray
}

if ($DryRun) {
    Write-Host '[dry-run] 校验通过，未落账。' -ForegroundColor Yellow
    exit 0
}

if ([Console]::IsInputRedirected) {
    Write-Host '[FAIL] stdin 被重定向 - 拒绝让管道代替人签署契约（同 sign-gate 规则）' -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host '确认落一条 contract_change（approved_by=human）？[y/N] ' -ForegroundColor Yellow -NoNewline
$ans = [Console]::In.ReadLine()
if ($null -eq $ans -or ($ans.Trim() -notmatch '^(y|yes|是|确认)$')) { Write-Host '已取消，未落账。' -ForegroundColor Gray; exit 0 }

# ---------------------------------------------------------------- 12: land the event
$data = [ordered]@{
    file          = $rel
    before_sha256 = $ledgerBefore
    after_sha256  = $afterSha
    why           = $whyText
    approved_by   = 'human'
    approved_at   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$jsonText = ConvertTo-Json -InputObject $data -Depth 4 -Compress
# JSON goes through a temp FILE, never -DataJson argv (pwsh -File re-parses the
# child command line and eats quotes/CJK - see append-event's DataJsonFile note)
$tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) ('sign-contract-' + [guid]::NewGuid().ToString('N') + '.json')
$code = 1
try {
    [System.IO.File]::WriteAllText($tmpPath, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'append-event.ps1') -Root $Root -Event contract_change -Actor human -DataJsonFile $tmpPath -Quiet
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
}
if ($code -ne 0) {
    Write-Host "[FAIL] contract_change 入账失败（append-event exit $code）" -ForegroundColor Red
    exit 1
}

Write-Host ("[sign-contract] OK {0} {1}..{2}" -f $rel, $before12, $after12) -ForegroundColor Green
exit 0
