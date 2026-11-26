<#
.SYNOPSIS
  analyze 前置闸（P0，借 spec-kit /analyze）。只读，不写账本。
.DESCRIPTION
  发卡前规格一致性检查：spec↔stage↔verify 跨产物一致性。
    dup_owner   : 同一文件被多个 stage 的 generates 声明（所有权冲突）
    dup_id      : stage id 重复
    bad_req     : requires 引用不存在的 stage
    void_verify : verify 为 VOID 判据(echo/exit0/python -c pass/空/grep -c)
    bad_risk    : risk 缺失或不在 L0/L1/L2
  输出 ANALYZE issues=N + 清单；写 .harness/local/analyze-report.json。
  教练发卡前必读；issues>0 → 修正草案再发，不教人绕脚本。
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot | Split-Path -Parent), [string]$Out = '')
Set-StrictMode -Version Latest
. "$PSScriptRoot\_common.ps1"
if (-not $Out) { $Out = Join-Path $Root '.harness\local\analyze-report.json' }
$proj = Get-Content -LiteralPath (Join-Path $Root '.harness\project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$stages = @($proj.stages)
$issues = [System.Collections.Generic.List[object]]::new()
$owner = @{}; $ids = @{}
foreach ($st in $stages) {
  $id = [string]$st.id
  if ($ids.ContainsKey($id)) { $issues.Add([pscustomobject]@{ code='dup_id'; step=$id; detail='stage id 重复' }) }
  $ids[$id] = $true
  foreach ($g in $st.generates) {
    $rel = ([string]$g).Replace('\','/')
    if ($owner.ContainsKey($rel)) { $issues.Add([pscustomobject]@{ code='dup_owner'; step=$id; detail="$rel 已被 $($owner[$rel]) 声明" }) }
    else { $owner[$rel] = $id }
  }
  foreach ($r in $st.requires) { if (-not $ids.ContainsKey([string]$r) -and -not ($stages | Where-Object { [string]$_.id -eq [string]$r })) { $issues.Add([pscustomobject]@{ code='bad_req'; step=$id; detail="requires 引用不存在: $r" }) } }
  $v = ([string]$st.verify).Trim()
  if ($v -eq '' -or $v -match '^\s*(echo|exit\s*0|grep\s+-c)' -or $v -match 'python\s+-c\s+["'']?\s*(pass|print)') { $issues.Add([pscustomobject]@{ code='void_verify'; step=$id; detail="verify 不可失败: $v" }) }
  $rk = [string]$st.risk
  if ($rk -notin @('L0','L1','L2')) { $issues.Add([pscustomobject]@{ code='bad_risk'; step=$id; detail="risk 缺失/非法: $rk" }) }
}
$report = [pscustomobject]@{ at=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); issues=$issues.Count; list=$issues }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
[System.IO.File]::WriteAllText($Out, (ConvertTo-Json $report -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("ANALYZE issues={0}" -f $issues.Count)
foreach ($i in $issues) { Write-Output ("  [{0}] {1} {2}" -f $i.code, $i.step, $i.detail) }
if ($issues.Count -eq 0) { Write-Output '  spec 一致 - 可发卡' }
Write-Output ("report: {0}" -f $Out)