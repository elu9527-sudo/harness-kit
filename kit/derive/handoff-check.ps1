<#
.SYNOPSIS
  P2 文档链 handoff 校验：五字段齐全 + produced 是指针串 + 非 VOID。只读。
.DESCRIPTION
  -File <交接卡>。检查 step/produced/decisions/deviations/uncertainty/residual 六字段，
  produced 至少一条合格指针(file:/cmd:/diff:)，且不全为 trivial。输出 HANDOFF ok/问题。
#>
param([string]$File = '', [switch]$Brief)
Set-StrictMode -Version Latest
if (-not $File -or -not (Test-Path $File)) { Write-Output '[FAIL] -File required'; exit 2 }
$t = Get-Content $File -Raw -Encoding UTF8
$problems = @()
foreach ($f in @('step','produced','decisions','deviations','uncertainty','residual')) {
  if ($t -notmatch ("(?m)^\s*" + $f + "\s*:")) { $problems += "missing:$f" }
}
$ptr = [regex]::Matches($t, '(?m)^\s*-\s*"(file|cmd|diff):[^"]+"')
if ($ptr.Count -eq 0) { $problems += 'produced:no-pointer' }
$nonTrivial = 0
foreach ($m in $ptr) {
  $s = $m.Value -replace '^\s*-\s*"',''
  # trivial 只看命令本身(echo/exit0/pass)，不看结果里的 "exit 0"
  if ($s -notmatch '^(cmd|file|diff):\s*(echo\b|exit\s*0|python\s+-c\s+["'']?pass)') { $nonTrivial++ }
}
if ($ptr.Count -gt 0 -and $nonTrivial -eq 0) { $problems += 'produced:all-trivial' }
# 残项计数：uncertainty / residual 是给 coach 的输入，不是装饰。
# 只报数、不判归属——归属由人判；机器只保证它出现在「收线那一刻」的屏幕上。
$countSec = {
  param($name)
  $rx = [regex]("(?ms)^\s*" + $name + "\s*:\s*\r?\n(.*?)(?=^\s*[A-Za-z_]+\s*:|\z)")
  $m = $rx.Match($t)
  if (-not $m.Success) { return 0 }
  ([regex]::Matches($m.Groups[1].Value, '(?m)^\s*-\s+')).Count
}
$nRes = & $countSec 'residual'
$nUnc = & $countSec 'uncertainty'
# -Brief：把「只需知道有」的压成计数，把「要逐条判断」的给全文。
# 实测一张卡 8613 字，其中 produced/decisions/deviations 占 79%，而教练真正要
# 逐条处置的是 uncertainty + residual（1840 字）。默认输出给全卡；-Brief 只回
# 这两段原文 + 其余条数，读一张卡从 8.6k 降到约 2k。
if ($Brief) {
    $SecItems = {
        param($name)
        $rx = [regex]("(?ms)^\s*" + $name + "\s*:\s*\r?\n(.*?)(?=^\s*[A-Za-z_]+\s*:|\z)")
        $m = $rx.Match($t)
        if (-not $m.Success) { return @() }
        return @([regex]::Matches($m.Groups[1].Value, '(?m)^\s*-\s+.*') | ForEach-Object { $_.Value.Trim() })
    }
    $st = ([regex]::Match($t, '(?m)^\s*step\s*:\s*(.+)$')).Groups[1].Value.Trim()
    $kinds = @{}
    foreach ($p in [regex]::Matches($t, '(?m)^\s*-\s*"(file|cmd|diff):')) {
        $k = $p.Groups[1].Value
        $kinds[$k] = 1 + [int]$kinds[$k]
    }
    $uItems = @(& $SecItems 'uncertainty')
    $rItems = @(& $SecItems 'residual')
    $dItems = @(& $SecItems 'decisions')
    $vItems = @(& $SecItems 'deviations')
    $cnt = @([regex]::Matches($t, '(?m)^\s*-\s*"(file|cmd|diff):')).Count
    Write-Output ("HANDOFF step={0}  problems={1}" -f $st, $problems.Count)
    foreach ($p in $problems) { Write-Output "  $p" }
    $kindTxt = (@('file', 'cmd', 'diff') | ForEach-Object { "$_ $([int]$kinds[$_])" }) -join ' / '
    Write-Output ("  produced {0} ({1})   decisions {2}   deviations {3}   uncertainty {4}   residual {5}" -f `
         $cnt, $kindTxt, $dItems.Count, $vItems.Count, $uItems.Count, $rItems.Count)
    if ($uItems.Count -gt 0) {
        Write-Output "  -- uncertainty ($($uItems.Count)) --"
        $uItems | ForEach-Object { Write-Output "  $_" }
    }
    if ($rItems.Count -gt 0) {
        Write-Output "  -- residual ($($rItems.Count)) --"
        $rItems | ForEach-Object { Write-Output "  $_" }
    }
    Write-Output '  归 coach 的逐条处置（落文档/进契约/明说不做）后才算「做好了」'
    return
}

Write-Output ("HANDOFF problems={0}" -f $problems.Count)
foreach ($p in $problems) { Write-Output "  $p" }
if ($problems.Count -eq 0) { Write-Output '  交接卡合格 - 可作下游输入' }
Write-Output ("  残项 residual={0} uncertainty={1}  <- 归 coach 的逐条处置（落文档/进契约/明说不做）后才算「做好了」" -f $nRes, $nUnc)