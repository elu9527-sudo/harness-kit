<#
.SYNOPSIS
  行为流水（只读）：把 events.jsonl 最近 N 条读成"谁/干了什么"，观测两个 agent。
.DESCRIPTION
  actor: hook=Claude编码 / hermes|script=教练 / human=人 / verify=判卷。
  -Tail N 条数；-Actor 过滤(hook/hermes/human)；-Tool 过滤(Write/Edit/Bash)。
  不写任何东西。配合 attention(需要你) + observe(冲突) + audit(检测) 使用。
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot | Split-Path -Parent),
      [int]$Tail = 20, [string]$Actor = '', [string]$Tool = '')
Set-StrictMode -Version Latest
. "$PSScriptRoot\_common.ps1"
$ev = Read-EventLog -Path (Join-Path $Root 'events.jsonl')
$rows = @()
foreach ($e in $ev) {
  if ($e.PSObject.Properties['__parse_error']) { continue }
  $a = [string]$e.actor
  if ($Actor -and $a -ne $Actor) { continue }
  $evn = [string]$e.event; $d = $e.data; $sum = ''
  if ($evn -eq 'tool_use') {
    $t = [string]$d.tool
    if ($Tool -and $t -ne $Tool) { continue }
    if ($d.PSObject.Properties['file']) { $sum = "$t $($d.file)" }
    elseif ($d.PSObject.Properties['cmd']) { $c = [string]$d.cmd; $sum = "$t " + $c.Substring(0,[Math]::Min(60,$c.Length)) }
    else { $sum = $t }
  }
  elseif ($evn -eq 'verify') { $sum = "verify $($d.target) exit=$($d.exit)" }
  elseif ($evn -eq 'step_advance') { $sum = "finish-step $($e.step)" }
  elseif ($evn -eq 'gate') { $sum = "gate L$($d.level) $($e.step)" }
  elseif ($evn -eq 'contract_change') { $sum = "contract_change $($e.step)" }
  else { $sum = $evn }
  $rows += [pscustomobject]@{ seq=[int]$e.seq; at=([string]$e.at).Substring(11,8); actor=$a; step=[string]$e.step; sum=$sum }
}
$rows = @($rows | Select-Object -Last $Tail)
Write-Output ("── 行为流水 (last {0}) ──" -f $rows.Count)
foreach ($r in $rows) {
  $who = switch ($r.actor) { 'hook' {'编码'} 'hermes' {'教练'} 'script' {'教练'} 'human' {'人'} 'verify' {'判卷'} default {$r.actor} }
  Write-Output ("{0} {1} [{2}] {3}: {4}" -f $r.seq, $r.at, $r.step, $who, $r.sum)
}