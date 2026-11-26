<#
.SYNOPSIS
  改一条还在计划里的步骤：直接生效，不问 y，账本记一条 plan_edit。

.DESCRIPTION
  为什么需要它：改一个字也要走 contract-bump（版本+1、备份、下游全标 stale）+ 再跑
  contract_change + 人签，代价远大于收益。而 stage-add 只能追加（代码里是 Add），
  改不了已有步骤——于是"改主意"变成了这套流程里最贵的一件事。

  这里的取舍（2026-11-17 定）：
    · 改还没发生的事，不需要被批准，只需要被记下来
    · 所以不问 y，直接生效，账本追加 plan_edit（旧值→新值，自动写，不用人编理由）
    · 不动 contract_version、不波及下游——因为那些步骤的产出还没变
    · 只有该步骤已经验收（stale/done）时，才把它自己标 stale 并提示重跑 verify

  决策模型只用来"提示"，不用来"决定"：
    问它 intent(tighten/same/loosen) 与 touch_done，命中就打印提醒；不拦截、不签字。
    模型不可用就退回静态判断（verify 文本变短/变弱 → 视作 loosen）。
    记账与写入永远是脚本做的——事实核对不交给概率模型。

  agent 不该跑这个脚本：它改的是计划，计划属于人。

.EXAMPLE
  pwsh -File stage-edit.ps1 -Step 0.5 -Verify "node --test extension/test/collector.test.mjs"
  pwsh -File stage-edit.ps1 -Step 0.5 -Goal "新的目标" -Risk L2
#>
[CmdletBinding()]
param(
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),
    [string] $Step = '',
    [string] $Goal = '',
    [string] $Verify = '',
    [string] $Generates = '',
    [string] $Requires = '',
    [string] $Risk = '',
    [switch] $DryRun,
    [switch] $NoModel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$profPath = Join-Path $Root '.harness\project.json'
if (-not (Test-Path -LiteralPath $profPath -PathType Leaf)) { Write-Host "[FAIL] no project.json" -ForegroundColor Red; exit 2 }
if ([string]::IsNullOrWhiteSpace($Step)) { Write-Host '[FAIL] -Step required' -ForegroundColor Red; exit 2 }

$raw = Get-Content -LiteralPath $profPath -Raw -Encoding UTF8
$proj = $raw | ConvertFrom-Json
$stage = $null
foreach ($s in @($proj.stages)) { if ([string]$s.id -eq $Step) { $stage = $s; break } }
if ($null -eq $stage) { Write-Host "[FAIL] stage '$Step' not in contract - use stage-add for new stages" -ForegroundColor Red; exit 2 }

function Get-F { param($o, [string]$n) $p = $o.PSObject.Properties[$n]; if ($null -ne $p) { $p.Value } else { $null } }
# verify 可能是字符串或数组；统一按 " ;; " 拼，和 verify.ps1 的记录口径一致。
function AsText { param($v) if ($null -eq $v) { '' } elseif ($v -is [array]) { ($v | ForEach-Object { [string]$_ }) -join ' ;; ' } else { [string]$v } }
$oldVerify = AsText (Get-F $stage 'verify')
$oldGoal = [string](Get-F $stage 'goal')
$oldRisk = [string](Get-F $stage 'risk')
$isDone = ($null -ne (Get-F $stage 'stale')) -or ((Get-F $stage 'done') -eq $true)

# ---------------------------------------------------------------- 组装变更
$changes = [ordered]@{}
if (-not [string]::IsNullOrWhiteSpace($Goal) -and $Goal -ne $oldGoal) { $changes['goal'] = @($oldGoal, $Goal) }
if (-not [string]::IsNullOrWhiteSpace($Verify) -and $Verify -ne $oldVerify) { $changes['verify'] = @($oldVerify, $Verify) }
if (-not [string]::IsNullOrWhiteSpace($Risk) -and $Risk -ne $oldRisk) { $changes['risk'] = @($oldRisk, $Risk) }
if (-not [string]::IsNullOrWhiteSpace($Generates)) { $changes['generates'] = @((($stage.PSObject.Properties['generates'].Value) -join ', '), $Generates) }
if (-not [string]::IsNullOrWhiteSpace($Requires)) { $changes['requires'] = @((($stage.PSObject.Properties['requires'].Value) -join ', '), $Requires) }

if ($changes.Count -eq 0) {
    Write-Host ("stage {0} - nothing to change (pass -Goal/-Verify/-Generates/-Requires/-Risk)" -f $Step) -ForegroundColor Yellow
    Write-Host ("  goal   : {0}" -f $oldGoal)
    Write-Host ("  verify : {0}" -f $oldVerify)
    exit 0
}

Write-Host ''
Write-Host ("stage {0}" -f $Step) -ForegroundColor Cyan
foreach ($k in $changes.Keys) {
    Write-Host ("  {0,-10} - {1}" -f $k, $changes[$k][0])
    Write-Host ("  {0,-10} + {1}" -f '', $changes[$k][1])
}

# ---------------------------------------------------------------- 决策模型：只提示
$hint = @()
if (-not $NoModel -and $changes.Contains('verify')) {
    $endpoint = if ($env:DECISION_ENDPOINT) { $env:DECISION_ENDPOINT } else { 'https://api.example.com/compatible-mode/v1/systemone' }
    $model = if ($env:DECISION_MODEL) { $env:DECISION_MODEL } else { 'decision-model-preview' }
    $key = $env:DECISION_API_KEY
    if ([string]::IsNullOrWhiteSpace($key)) { $key = 'sk-ws-H.YLLMYMM.Si7r.MEUCIA_krvhA5PdlXeSFPAnytnsDD_b2ZU42CL-WEctjA3LEAiEAm4R32pXIy_-tbBb8GSkG5p0kvXA4yNdcQghde6ML4AY' }
    $payload = @{
        model     = $model
        state     = ("步骤 $Step 的验收命令要改。`n旧: " + $changes['verify'][0] + "`n新: " + $changes['verify'][1] + "`n该步骤已验收: " + $(if ($isDone) { '是' } else { '否' }))
        questions = @{
            intent     = @{ type = 'choice'
                            instructions = '这次改动相对旧的是收紧还是放宽'
                            criteria     = @{ tighten = '新命令检查得更多更严'; same = '等价替换，强度不变'; loosen = '新命令检查得更少更松' } }
            touch_done = @{ type = 'noul'
                            instructions = '这次改动是否改变了已经验收过的结论'
                            criteria     = @{ 'true' = '会让已有的 PASS 记录不再代表当前门槛'; 'false' = '不影响已有结论' } }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    try {
        $r = Invoke-RestMethod -Uri $endpoint -Method Post -TimeoutSec 12 -Body $payload -Headers @{ 'Authorization' = "Bearer $key"; 'content-type' = 'application/json' }
        $intent = [string]$r.answers.intent.choice
        $touch = $r.answers.touch_done
        if ($intent -eq 'loosen') { $hint += ('模型判断：放宽（置信度 {0:N2}）——已有 PASS 记录不再代表新门槛' -f [double]$r.answers.intent.confidence) }
        if ($null -ne $touch -and [bool]$touch.value) { $hint += '模型判断：触及已验收结论' }
    }
    catch {
        # fail-soft：模型不可用时退回静态判断，绝不阻断。
        $o = [string]$changes['verify'][0]; $n = [string]$changes['verify'][1]
        if ($isDone) { $hint += '模型不可用；静态判断：该步骤已验收，按触及已验收处理' }
        if ($n.Length -lt $o.Length -and $o.Length -gt 0) { $hint += '模型不可用；静态判断：新命令更短，可能放宽' }
    }
}

# ---------------------------------------------------------------- 落盘
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($k in $changes.Keys) {
    $v = $changes[$k][1]
    switch ($k) {
        'goal' { $stage | Add-Member -NotePropertyName goal -NotePropertyValue $v -Force }
        'verify' { $stage | Add-Member -NotePropertyName verify -NotePropertyValue $v -Force }
        'risk' { $stage | Add-Member -NotePropertyName risk -NotePropertyValue $v -Force }
        'generates' { $stage | Add-Member -NotePropertyName generates -NotePropertyValue @($v -split ',' | ForEach-Object { $_.Trim() }) -Force }
        'requires' { $stage | Add-Member -NotePropertyName requires -NotePropertyValue @($v -split ',' | ForEach-Object { $_.Trim() }) -Force }
    }
}

# 已验收的步骤被改：只把这一步标 stale（不波及下游），并在提示里说出来。
if ($isDone) {
    $stage | Add-Member -NotePropertyName stale -NotePropertyValue $true -Force
    $stage | Add-Member -NotePropertyName stale_reason -NotePropertyValue ("plan edit " + $ts) -Force
    $hint += ("已把 $Step 标 stale —— 重跑一次 verify.ps1 -Step $Step 即可清除")
}

if ($DryRun) { Write-Host ''; Write-Host '[dry-run] nothing written.'; exit 0 }

Copy-Item -LiteralPath $profPath -Destination "$profPath.bak-$ts" -Force
[System.IO.File]::WriteAllText($profPath, (ConvertTo-Json $proj -Depth 12), (New-Object System.Text.UTF8Encoding($false)))

# 账本：一条 plan_edit，旧值→新值自动写，不用人编理由。
$payloadFile = Join-Path $env:TEMP ('plan-edit-' + [guid]::NewGuid().ToString('N') + '.json')
$data = [ordered]@{
    tool        = 'plan_edit'
    observed_by = 'stage-edit'
    step        = $Step
    fields      = @($changes.Keys)
    changes     = @{}
    note        = 'plan edit, applied without signature'
}
foreach ($k in $changes.Keys) { $data.changes[$k] = @{ before = $changes[$k][0]; after = $changes[$k][1] } }
[System.IO.File]::WriteAllText($payloadFile, (ConvertTo-Json $data -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($false)))
try {
    # 用 plan_edit 事件：改计划既不是"偏离"(deviate，会冒 T1 卡)，也不是普通写
    # (tool_use 要求 data.file)。它是一条例行记录——谁改了哪个字段、旧值→新值。
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'append-event.ps1') -Root $Root -Event plan_edit -Step $Step -Actor human -DataJsonFile $payloadFile -Quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host ("  [WARN] plan_edit 未入账（append-event exit {0}）；改动已生效，但账本没有这条" -f $LASTEXITCODE) -ForegroundColor Yellow }
} finally { Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue }

Write-Host ''
foreach ($h in $hint) { Write-Host ("  [提示] " + $h) -ForegroundColor Yellow }
Write-Host ("  已生效；备份 .bak-{0}" -f $ts) -ForegroundColor Green
Write-Host ''
exit 0