<#
.SYNOPSIS
  变更影响分析（P0，借 SA 通知受影响/不取消）。只读，不写账本。
.DESCRIPTION
  给定变更文件(-Files 'a,b')或变更 stage(-Step id)，用 generates/requires 图
  算出波及面：直接拥有这些文件的 stage + 传递依赖它们的下游 stage。
  输出 IMPACT affected=[ids]；写 .harness/local/impact-report.json。
  供 contract-bump 标 stale、教练出"波及清单"，变更一来即知影响，不靠记忆。
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot | Split-Path -Parent),
      [string]$Files = '', [string]$Step = '', [string]$Out = '')
Set-StrictMode -Version Latest
. "$PSScriptRoot\_common.ps1"
if (-not $Out) { $Out = Join-Path $Root '.harness\local\impact-report.json' }
$proj = Get-Content -LiteralPath (Join-Path $Root '.harness\project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$stages = @($proj.stages)
$changed = @{}
if ($Files) { foreach ($f in ($Files -split ',')) { $t=$f.Trim(); if($t){ $changed[$t.Replace('\','/')]=$true } } }
if ($Step) { foreach ($st in $stages) { if ([string]$st.id -eq $Step) { foreach ($g in $st.generates) { $changed[([string]$g).Replace('\','/')]=$true } } } }
# ownership + downstream
$affected = @{}
foreach ($st in $stages) { foreach ($g in $st.generates) { if ($changed.ContainsKey(([string]$g).Replace('\','/'))) { $affected[[string]$st.id]=$true } } }
$grow = $true
while ($grow) {
  $grow = $false
  foreach ($st in $stages) {
    if ($affected.ContainsKey([string]$st.id)) { continue }
    foreach ($r in $st.requires) { if ($affected.ContainsKey([string]$r)) { $affected[[string]$st.id]=$true; $grow=$true; break } }
  }
}
$list = @($affected.Keys | Sort-Object)
$report = [pscustomobject]@{ at=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); changed=@($changed.Keys); affected=$list }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
[System.IO.File]::WriteAllText($Out, (ConvertTo-Json $report -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("IMPACT affected={0}" -f ($list -join ','))
if ($list.Count -eq 0) { Write-Output '  无波及' }
Write-Output ("report: {0}" -f $Out)