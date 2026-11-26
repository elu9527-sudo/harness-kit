<#
.SYNOPSIS
  P2 重启恢复（借 SA C5）：从账本重建"续做不重做"注记。只读。
.DESCRIPTION
  输出 RESUME：done=[step_advance]、active=最后有 tool_use 但未 advance 的 step、
  每个 step 的最新 verify。agent 重启先跑它，接着干，不重做已完成。
  （worktree 那一段随隔离区一起删除：写入现在只发生在活树，账本足以说明进度。）
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot | Split-Path -Parent))
Set-StrictMode -Version Latest
. "$PSScriptRoot\_common.ps1"
$ev = Read-EventLog -Path (Join-Path $Root 'events.jsonl')
$done = [ordered]@{}; $active = ''; $lastVerify = @{}
foreach ($e in $ev) {
  if ($e.PSObject.Properties['__parse_error']) { continue }
  $evn = [string]$e.event
  if ($evn -eq 'tool_use') { $active = [string]$e.step }
  elseif ($evn -eq 'verify') { $lastVerify[[string]$e.data.target] = [int]$e.data.exit }
}
# done 的口径只有一处：status.ps1（2026-11-20）。
# 旧版按 `step_advance` 的 $e.step 记 done，但那条事件是按「目标步」写的（-Step $afterStep），
# 于是 done 永远多算一步：recover 报 done=[…,2.0.3,2.0.4]，而 status 说 2.0.4 还是 READY 未验证。
# 用 recover 续做的会话会直接跳过 2.0.4 —— 两个工具对同一步给出相反结论，比都错更糟。
# 现在直接吃 status -Json 的 artifacts.status，不再自己推一遍。
$next = ''
try {
  $sj = & (Join-Path $PSScriptRoot 'status.ps1') -Root $Root -Json 2>&1 | Out-String
  $so = $sj | ConvertFrom-Json
  $np = $so.PSObject.Properties['next']; if ($null -ne $np -and $null -ne $np.Value) { $next = [string]$np.Value }
  foreach ($a in @($so.artifacts)) {
    if ([string]$a.status -eq 'done') { $done[[string]$a.id] = $true }
  }
}
catch { }
$activeStep = if ($done.Contains([string]$active)) { '' } else { $active }
Write-Output ("RESUME done=[{0}] active={1}" -f (($done.Keys) -join ','), $(if ($activeStep) { $activeStep } else { '(none)' }))
if ($next) { Write-Output ("  next {0}" -f $next) }
foreach ($k in ($lastVerify.Keys | Sort-Object)) { Write-Output ("  last_verify {0} exit={1}" -f $k, $lastVerify[$k]) }
Write-Output '  续做不重做: 从 active 接着干; done 的不重跑（口径与 status 一致）。'