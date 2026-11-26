<#
.SYNOPSIS
  Record a file write that no hook saw: IDE edits, Hermes, any process outside
  Claude Code's PostToolUse. One command, prose reason, no JSON.

.DESCRIPTION
  A file changing on disk with no event describing it is the most dangerous
  defect this harness has produced. It happened three times on 2026-11-07
  (observer #4, O4-01/O4-22): contracts/ip_provider_interface.py and
  docs/变更记录.md were modified by a writer running parallel to Claude Code,
  inside gaps where the hook demonstrably recorded other writes - so it is not
  lock loss, it is coverage. The second time, the inserted lines declared
  THEMSELVES "the single source of truth for exemptions" - authority over which
  contract mismatches may be waived, living in the one file the ledger cannot
  see. C7 could report the disagreement between disk and ledger, but nothing
  could tell anyone WHO wrote it or WHY.

  This script is that missing "who and why". It appends a tool_use record
  through append-event (lock, chain, post-write verify - all unchanged), with
  sha256 computed from the disk, observed_by=script, and a reason typed at a
  prompt in plain prose. After a manual edit, run one line here and the drift
  becomes a recorded, attributable fact instead of a fault nobody can explain.

  Contract files get a printed reminder: recording the write is NOT the same
  as renegotiating the contract. A contracts/** change also owes a
  contract_change event with approved_by, decided by the human, because a
  note in a file the ledger cannot see is not an acceptance criterion.

.EXAMPLE
  pwsh -File .harness\derive\record-edit.ps1 -File contracts/ip_provider_interface.py

.EXAMPLE
  pwsh -File .harness\derive\record-edit.ps1 -File docs/变更记录.md -Actor hermes -Why "补记 3.1.3 返工说明" -Yes

.OUTPUTS
  exit 0 recorded; exit 1 chain problem; exit 2 bad arguments
#>
[CmdletBinding()]
param(
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),

    # Project-relative (or absolute) path of the file that changed. Required.
    [string] $File = '',

    [ValidateSet('human', 'hermes', 'script')]
    [string] $Actor = 'human',

    # One-line reason for scripted use. Anything longer or containing quotes
    # goes through the interactive prompt: the argv boundary has already
    # destroyed two commands today.
    [string] $Why = '',

    [switch] $Yes,
    [switch] $DryRun,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$appendPath = Join-Path $Root '.harness\derive\append-event.ps1'
$profPath   = Join-Path $Root '.harness\project.json'

if (-not (Test-Path -LiteralPath $profPath -PathType Leaf)) {
    Write-Host "[FAIL] project.json not found: $profPath" -ForegroundColor Red
    exit 2
}
if (-not (Test-Path -LiteralPath $appendPath -PathType Leaf)) {
    Write-Host "[FAIL] append-event.ps1 not found: $appendPath" -ForegroundColor Red
    exit 2
}
if ([string]::IsNullOrWhiteSpace($File)) {
    Write-Host '[FAIL] -File is required: which file did you change?' -ForegroundColor Red
    exit 2
}

# normalise to a project-relative forward-slash path, the same form the hook
# writes - otherwise C7/status/T11 compare 'contracts\x.py' against
# 'contracts/x.py' and every join misses
$abs = if ([System.IO.Path]::IsPathRooted($File)) { $File } else { Join-Path $Root $File }
if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) {
    Write-Host "[FAIL] file not found on disk: $abs" -ForegroundColor Red
    exit 2
}
$rel = ''
try { $rel = [System.IO.Path]::GetRelativePath($Root, $abs).Replace('\', '/') } catch { $rel = ($File -replace '\\', '/') }
if ($rel.StartsWith('../')) {
    Write-Host "[FAIL] '$rel' is outside the project root - record what the project owns:" -ForegroundColor Red
    Write-Host "       Root: $Root" -ForegroundColor DarkGray
    exit 2
}

# refuse to record a write that did not actually move: if disk still equals the
# last recorded digest, this event would claim a change that never happened,
# and claiming false facts in the ledger is worse than an empty gap
$eventsPath = Join-Path $Root 'events.jsonl'
$nowSha = Get-FileSha256Hex -Path $abs
$lastRecSha = ''
if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
    foreach ($e0 in @(Read-EventLog -Path $eventsPath)) {
        if ($null -ne $e0.PSObject.Properties['__parse_error']) { continue }
        if ([string]$e0.event -ne 'tool_use') { continue }
        $d0 = $e0.PSObject.Properties['data']
        if ($null -eq $d0) { continue }
        $f0 = $d0.Value.PSObject.Properties['file']
        $s0 = $d0.Value.PSObject.Properties['sha256']
        if ($null -ne $f0 -and [string]$f0.Value -eq $rel -and $null -ne $s0) { $lastRecSha = [string]$s0.Value }
    }
}
if ($lastRecSha -eq $nowSha) {
    Write-Host ''
    Write-Host "[no-op] '$rel' on disk already IS the last recorded digest ($($nowSha.Substring(0,12)))" -ForegroundColor Yellow
    Write-Host '        nothing to record - a second identical event would make the ledger' -ForegroundColor DarkGray
    Write-Host '        claim a change that did not happen.' -ForegroundColor DarkGray
    exit 0
}

# ---------------------------------------------------------------- reason
$whyText = ([string]$Why).Trim()
if ([string]::IsNullOrWhiteSpace($whyText)) {
    Write-Host ''
    Write-Host ("[record-edit] {0}" -f $rel) -ForegroundColor Cyan
    Write-Host ("  actor : {0}" -f $Actor) -ForegroundColor DarkGray
    Write-Host ("  disk  : {0} bytes  sha {1}..." -f (Get-Item -LiteralPath $abs).Length, $nowSha.Substring(0, 12)) -ForegroundColor DarkGray
    Write-Host ("  ledger last: {0}" -f $(if ($lastRecSha) { $lastRecSha.Substring(0, 12) } else { '(never recorded)' })) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '这次改动的理由（不是 y/N；可多行，空行结束）：' -ForegroundColor Yellow

    $lines = Read-ReasonLines
    $whyText = (($lines | ForEach-Object { $_.Trim() }) -join ' ').Trim()
}

$problem = Get-ReasonProblem -Text $whyText
if ($problem -ne '') {
    Write-Host ''
    Write-Host ("[FAIL] 理由不合格：{0}" -f $problem) -ForegroundColor Red
    Write-Host '       这条记录存在的意义就是回答「这次没被 hook 看见的改动是谁、为什么」，' -ForegroundColor Yellow
    Write-Host '       理由空转，记录就只是一次带时间戳的沉默。' -ForegroundColor Yellow
    exit 2
}

$data = [ordered]@{
    file            = $rel
    tool            = 'manual'
    why             = $whyText
    # 11-10 fix: a backfill that lands no digest cannot pin WHAT was backfilled.
    # sweep's tracked set keys on tool_use data.sha256, so before this the
    # backfill never closed the disk-vs-ledger comparison, and any later tool
    # that needs the file's last recorded state (sign-contract style) found
    # nothing. before_sha256 = the last recorded digest this backfill supersedes
    # ('' = genuinely never recorded); sha256 = disk at backfill time.
    sha256          = $nowSha
    before_sha256   = $lastRecSha
}
$jsonText = ConvertTo-Json -InputObject $data -Depth 8 -Compress

if (-not $Quiet) {
    Write-Host ''
    Write-Host '  ── 将要补记 ─────────────────────────────' -ForegroundColor DarkGray
    Write-Host ("  file : {0}" -f $rel) -ForegroundColor DarkGray
    Write-Host ("  actor: {0}   (observed_by=script - 这条不进 T3/T4 对 agent 行为的判定)" -f $Actor) -ForegroundColor DarkGray
    Write-Host ("  why  : {0}" -f $whyText) -ForegroundColor Gray
    Write-Host '  ─────────────────────────────────────────' -ForegroundColor DarkGray
}

if ($rel -match '^contracts/') {
    Write-Host ''
    Write-Host '  [提醒] contracts/** 的改动不只是补记：改的是别人要照着做的约定。' -ForegroundColor Yellow
    Write-Host '         还需要 contract_change 事件 + 人签（教练的 T9 会核对）。' -ForegroundColor Yellow
    Write-Host '         尤其不要往契约文件里塞"本文件是某口径唯一事实来源"——' -ForegroundColor Yellow
    Write-Host '         2026-11-07 的豁免条款就写在唯一一个零记录的文件里。' -ForegroundColor Yellow
}

if ($DryRun) {
    Write-Host '[dry-run] nothing written.' -ForegroundColor Yellow
    exit 0
}

if (-not $Yes) {
    Write-Host ''
    Write-Host '确认补记？[y/N] ' -ForegroundColor Yellow -NoNewline
    if ([Console]::IsInputRedirected) {
        Write-Host '(stdin 已被占用 - 拒绝代为同意；脚本用法请加 -Yes)' -ForegroundColor Red
        exit 130
    }
    $ans = [Console]::In.ReadLine()
    if ($null -eq $ans -or $ans.Trim() -notmatch '^(y|yes|Y|YES|是|确认)$') {
        Write-Host '[cancel] 未写入。' -ForegroundColor Yellow
        exit 130
    }
}

$tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-record-{0}.json" -f ([guid]::NewGuid().ToString('N')))
$code = 2
# 补账要记在"这个文件属于哪一步"上，而不是"现在正处在哪一步"。
# 记错步骤的后果是真实的：T11 会把它读成"在别的步骤里改动了已验收产出"，
# 于是每一次正当补账都变成一张 NEEDS YOU 卡（本机曾一次冒出 11 条，全部来自补账）。
$ownerStep = ''
try {
    $pjPath = Join-Path $Root '.harness\project.json'
    if (Test-Path -LiteralPath $pjPath -PathType Leaf) {
        $pj = Get-Content -LiteralPath $pjPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($s in @($pj.stages)) {
            $hit = $false
            foreach ($g in @($s.generates)) {
                if (([string]$g -replace '\\', '/') -eq $rel) { $ownerStep = [string]$s.id; $hit = $true; break }
            }
            if ($hit) { break }
        }
    }
} catch { $ownerStep = '' }
$stepArgs = @()
if (-not [string]::IsNullOrWhiteSpace($ownerStep)) { $stepArgs = @('-Step', $ownerStep) }
try {
    [System.IO.File]::WriteAllText($tmpPath, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -File $appendPath -Root $Root -Event tool_use -Actor $Actor -DataJsonFile $tmpPath @stepArgs -Quiet
    $code = $LASTEXITCODE
}
finally {
    if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
}

if ($code -eq 0) {
    Write-Host ("[recorded] {0} <- {1}" -f $rel, $Actor) -ForegroundColor Green
    exit 0
}
Write-Host ("[FAIL] append-event 退出码 {0}，未记录" -f $code) -ForegroundColor Red
exit $code