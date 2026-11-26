<#
.SYNOPSIS
  P2 双层 eval（借 SA C1）：层1 确定性 verify + 层2 模型评审清单校验。只读。
.DESCRIPTION
  层1: 该 step 最新台账 verify 的三态判定成立（exit=0 且非 trivial 且 real_test）。层2: -ReviewFile JSON 含
  design_checked/boundary_checked/tests_real/honest 全 true（模型自审产物，脚本校验其完整）。
  两层都过才 REVIEW pass。批处理: 可一次传多个 -Step 逗号分隔。
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot | Split-Path -Parent),
      [string]$Step = '', [string]$ReviewFile = '')
Set-StrictMode -Version Latest
. "$PSScriptRoot\_common.ps1"
$ev = Read-EventLog -Path (Join-Path $Root 'events.jsonl')
# 层1 必须用与 verify.ps1 相同的三态口径：exit=0 还不够，
# trivial（echo/exit 0 之类）和 real_test=false 的 verify 建立不了任何东西。
# 2026-11-17：旧版只看 exit，于是 verify 判 VOID 的同一条记录在这里被读成 pass=True，
# 两个工具对同一步给出相反结论——这种矛盾比两边都错更糟，人不知道该信谁。
$lastVerdict = @{}
foreach ($e in $ev) {
    if ([string]$e.event -ne 'verify') { continue }
    $d = $e.data
    $vx = 0; $vt = $false; $vr = $false
    $px = $d.PSObject.Properties['exit'];      if ($null -ne $px) { $vx = [int]$px.Value }
    $pt = $d.PSObject.Properties['trivial'];   if ($null -ne $pt) { $vt = [bool]$pt.Value }
    $pr = $d.PSObject.Properties['real_test']; if ($null -ne $pr) { $vr = [bool]$pr.Value }
    $lastVerdict[[string]$d.target] = ($vx -eq 0 -and -not $vt -and $vr)
}
$layer2 = $false
if ($ReviewFile -and (Test-Path $ReviewFile)) {
  try {
    $r = Get-Content $ReviewFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $layer2 = ($r.design_checked -eq $true) -and ($r.boundary_checked -eq $true) -and ($r.tests_real -eq $true) -and ($r.honest -eq $true)
  } catch { $layer2 = $false }
}
$all = $true
foreach ($s in ($Step -split ',')) {
  $s = $s.Trim(); if (-not $s) { continue }
  $l1 = ($lastVerdict.ContainsKey($s) -and $lastVerdict[$s])
  $ok = $l1 -and $layer2
  if (-not $ok) { $all = $false }
  Write-Output ("REVIEW {0} layer1={1} layer2={2} pass={3}" -f $s, $l1, $layer2, $ok)
}
if ($all) { Write-Output '  双层 eval 通过' } else { Write-Output '  双层 eval 未过 - 不报 ready' }