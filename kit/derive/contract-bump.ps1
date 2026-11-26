<#
.SYNOPSIS
  contract 版本+stale+通知（P0，借 SA policy 版本/通知受影响不取消）。人跑 -Yes。
.DESCRIPTION
  设计变更拍板后：contract_version+1；用 impact 图把受影响 stage 标 stale；
  备份 project.json；打印 NOTIFY 波及清单。不静默取消任何 stage。
  仍须人另跑 append-event contract_change + 签（本脚本只改版本/stale，不代签）。
  习惯不变：人读 NOTIFY + 按 y。
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot | Split-Path -Parent),
      [string]$Files = '', [string]$Step = '', [switch]$Yes, [switch]$DryRun)
Set-StrictMode -Version Latest
. "$PSScriptRoot\_common.ps1"
$profPath = Join-Path $Root '.harness\project.json'
$raw = Get-Content -LiteralPath $profPath -Raw -Encoding UTF8
$proj = $raw | ConvertFrom-Json
# impact
$tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ("impact-{0}.json" -f [guid]::NewGuid().ToString('N'))
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'impact.ps1') -Root $Root -Files $Files -Step $Step -Out $tmpOut | Out-Null
$imp = Get-Content -LiteralPath $tmpOut -Raw -Encoding UTF8 | ConvertFrom-Json
Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
$affected = @($imp.affected)
$verProp = $proj.PSObject.Properties['contract_version']
$oldVer = if ($verProp) { [int]$verProp.Value } else { 0 }
$newVer = $oldVer + 1
Write-Output ("CONTRACT v{0} -> v{1}; affected={2}" -f $oldVer, $newVer, ($affected -join ','))
if ($DryRun) { Write-Output '[dry-run] nothing written.'; exit 0 }
# 2026-11-17：不再要 -Yes。它干的是"算波及面 + 标 stale + 打印 NOTIFY"——这是陈述事实，
# 不是征求同意。改主意只需要被记下来，不需要被批准；签字留给"承诺"(stage-add) 与不可逆动作。
# backup
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
Copy-Item -LiteralPath $profPath -Destination "$profPath.bak-$ts" -Force
# apply
if ($verProp) { $verProp.Value = $newVer } else { Add-Member -InputObject $proj -NotePropertyName contract_version -NotePropertyValue $newVer }
foreach ($st in $proj.stages) {
  if ($affected -contains [string]$st.id) {
    $sp = $st.PSObject.Properties['stale']
    if ($sp) { $sp.Value = $true } else { Add-Member -InputObject $st -NotePropertyName stale -NotePropertyValue $true }
    $rp = $st.PSObject.Properties['stale_reason']
    $reason = "contract v$newVer"
    if ($rp) { $rp.Value = $reason } else { Add-Member -InputObject $st -NotePropertyName stale_reason -NotePropertyValue $reason }
  }
}
[System.IO.File]::WriteAllText($profPath, (ConvertTo-Json $proj -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("[bumped] contract v{0}; stale={1}; backup .bak-{2}" -f $newVer, ($affected -join ','), $ts)
Write-Output '[NOTIFY] 波及步骤已标 stale，重跑 verify 即恢复；不需要签字，也不需要另跑 contract_change。'