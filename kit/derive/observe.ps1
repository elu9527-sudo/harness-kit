<#
.SYNOPSIS
  观测-冲突扫描（P0 — living spec / 立即纠错回路）。只读，不写账本。
.DESCRIPTION
  对照「最初说的」(project.json stages) vs「现实」(磁盘+台账)，产出 CONFLICT 纠错卡：
    harness_wiped   : 项目根有 install 锚，但 .harness/ 或 events.jsonl 不在了 → 纠错(严重)
    harness_replaced: 有锚且账本在，但 seq1 的 self 与锚不符（账本被重建过）  → 纠错(严重)
    missing   : 已 done 的 stage，其 generates 文件在磁盘不存在        → 纠错(收紧,免签)
    drift     : generates 文件磁盘 sha != 台账最新记录 sha(未补记的写) → 纠错(收紧,免签)
    regression: 已 done 的 stage 最新 verify exit != 0                → 纠错(收紧,免签)
  每张卡带: 原话(goal/verify) vs 观测事实 + 处置建议。放宽/改方向才需人按 y。
  报告写 .harness/local/observe-report.json；与上次相同则报 "no new conflicts"（省力去重）。

  为什么第一条检查是 harness 自身：2026-11-17 那次，整个 .harness/ 加 events.jsonl
  在一次 robocopy 式镜像里消失了，而 observe 当时还在正常输出 "no conflicts -
  最初说的与现实一致"——因为它的世界只剩下业务文件，账本为空就等于没问题。
  证据不能只存放在可能被删掉的东西里面：.harness-anchor.json 放在项目根，
  它记得"这里曾经装过一套 harness、genesis 是哪个哈希"。.harness 没了，
  锚还在，于是"没有账本"从"看起来正常"变成"明确异常"。
.EXAMPLE
  pwsh -NoProfile -File .harness/derive/observe.ps1 -Root <项目>
#>
param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot | Split-Path -Parent),
  [string]$Out  = ''
)
Set-StrictMode -Version Latest
. "$PSScriptRoot\_common.ps1"

if (-not $Out) { $Out = Join-Path $Root '.harness\local\observe-report.json' }
$harnessPath = Join-Path $Root '.harness'
$localPath   = Join-Path $harnessPath 'local.json'
$eventsPath  = Join-Path $Root 'events.jsonl'
$anchorPath  = Join-Path $Root '.harness-anchor.json'

$conflicts = [System.Collections.Generic.List[object]]::new()

# ---- 0. harness 自身完整性（先于一切：没有账本的"没问题"不算没问题）----
$anchor = $null
if (Test-Path -LiteralPath $anchorPath -PathType Leaf) {
  try { $anchor = Get-Content -LiteralPath $anchorPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $anchor = $null }
}
if ($null -ne $anchor) {
  $genesisWanted = [string]$anchor.genesis_self
  if (-not (Test-Path -LiteralPath $harnessPath -PathType Container) -or -not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) {
    $conflicts.Add([pscustomobject]@{ code='harness_wiped'; step='harness'; file='.harness';
      original=("install 锚: installed_at={0} by={1} genesis={2}" -f [string]$anchor.installed_at, [string]$anchor.by, $genesisWanted.Substring(0,[Math]::Min(12,$genesisWanted.Length)));
      observed=("磁盘: .harness={0} events.jsonl={1}" -f (Test-Path -LiteralPath $harnessPath), (Test-Path -LiteralPath $eventsPath));
      action='纠错(严重): 重装 harness，并把这次丢失作为 deviate/anchor 记进新账本' })
  }
  else {
    $firstSelf = ''
    foreach ($line in (Get-Content -LiteralPath $eventsPath -Encoding UTF8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $r = $line | ConvertFrom-Json } catch { continue }
      if ([int]$r.seq -eq 1) { $firstSelf = [string]$r.self; break }
    }
    if (-not [string]::IsNullOrWhiteSpace($genesisWanted) -and $firstSelf -ne $genesisWanted) {
      $conflicts.Add([pscustomobject]@{ code='harness_replaced'; step='harness'; file='events.jsonl';
        original=("install 锚记录的 genesis self={0}" -f $genesisWanted.Substring(0,12));
        observed=("账本 seq1 self={0}" -f $(if ($firstSelf) { $firstSelf.Substring(0,12) } else { '(空/不可解析)' }));
        action='纠错(严重): 账本被重建过——原历史不可恢复，在 deviate 里如实记录丢失范围' })
    }
  }
}

# ---- 1. 契约 vs 现实 ----
if (-not (Test-Path -LiteralPath (Join-Path $harnessPath 'project.json') -PathType Leaf)) {
  $report0 = [pscustomobject]@{ at=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); count=$conflicts.Count; conflicts=$conflicts }
  $json0 = ConvertTo-Json -InputObject $report0 -Depth 6
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
  [System.IO.File]::WriteAllText($Out, $json0, (New-Object System.Text.UTF8Encoding($false)))
  Write-Output ("OBSERVE conflicts={0}" -f $conflicts.Count)
  foreach ($c in $conflicts) {
    Write-Output ("  [{0}] {1} {2}" -f $c.code, $c.step, $c.file)
    Write-Output ("     原话: {0}" -f $c.original)
    Write-Output ("     观测: {0}" -f $c.observed)
    Write-Output ("     处置: {0}" -f $c.action)
  }
  if ($null -eq $anchor) { Write-Output '  注意: 项目根也没有 .harness-anchor.json - 这套 harness 从未在此安装过，或锚也被删了' }
  Write-Output ("report: {0}" -f $Out)
  exit 0
}

$proj = Get-Content -LiteralPath (Join-Path $harnessPath 'project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$events = Read-EventLog -Path $eventsPath

# ---- 台账投影 ----
$latestSha = @{}; $lastWriteSeq = @{}; $doneSeq = @{}; $latestVerify = @{}
foreach ($e in $events) {
  if ($e.PSObject.Properties['__parse_error']) { continue }
  $ev = [string]$e.event
  if ($ev -eq 'tool_use') {
    $d = $e.data
    if ($d -and $d.PSObject.Properties['file'] -and $d.PSObject.Properties['sha256']) {
      $f = ([string]$d.file).Replace('\','/')
      $latestSha[$f] = [string]$d.sha256
      $lastWriteSeq[$f] = [int]$e.seq
    }
  }
  elseif ($ev -eq 'step_advance') { $doneSeq[[string]$e.step] = [int]$e.seq }
  elseif ($ev -eq 'verify') {
    $t = [string]$e.data.target
    if ($t) { $latestVerify[$t] = [int]$e.data.exit }
  }
}

# ---- 冲突扫描 ----
foreach ($st in $proj.stages) {
  $id = [string]$st.id
  if (-not $doneSeq.ContainsKey($id)) { continue }   # 只观测已 done 的
  foreach ($g in $st.generates) {
    $rel = ([string]$g).Replace('\','/')
    $abs = Join-Path $Root ($rel.Replace('/','\'))
    $disk = Get-FileSha256Hex -Path $abs
    if ($disk -eq '') {
      $conflicts.Add([pscustomobject]@{ code='missing'; step=$id; file=$rel;
        original="generates 声明产出 $rel"; observed='磁盘不存在'; action='纠错(收紧,免签): 补齐或更新 spec' })
    }
    elseif ($latestSha.ContainsKey($rel) -and $latestSha[$rel] -ne '' -and $disk -ne $latestSha[$rel]) {
      $conflicts.Add([pscustomobject]@{ code='drift'; step=$id; file=$rel;
        original="台账 sha=$($latestSha[$rel].Substring(0,8))"; observed="磁盘 sha=$($disk.Substring(0,8)) (未补记)"; action='纠错(收紧,免签): record-edit 补记' })
    }
  }
  if ($latestVerify.ContainsKey($id) -and $latestVerify[$id] -ne 0) {
    $conflicts.Add([pscustomobject]@{ code='regression'; step=$id; file='';
      original="stage $id 已 done, 应 PASS"; observed="最新 verify exit=$($latestVerify[$id])"; action='纠错(收紧,免签): 返工到 PASS' })
  }
}

# ---- 报告 + 去重 ----
$report = [pscustomobject]@{ at=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); count=$conflicts.Count; conflicts=$conflicts }
$json = ConvertTo-Json -InputObject $report -Depth 6
$prev = ''
if (Test-Path -LiteralPath $Out -PathType Leaf) { $prev = Get-Content -LiteralPath $Out -Raw -Encoding UTF8 }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
[System.IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Output ("OBSERVE conflicts={0}" -f $conflicts.Count)
if ($conflicts.Count -eq 0) { Write-Output '  no conflicts - 最初说的与现实一致'; }
else {
  foreach ($c in $conflicts) {
    Write-Output ("  [{0}] {1} {2}" -f $c.code, $c.step, $c.file)
    Write-Output ("     原话: {0}" -f $c.original)
    Write-Output ("     观测: {0}" -f $c.observed)
    Write-Output ("     处置: {0}" -f $c.action)
  }
  if ($prev -eq $json) { Write-Output '  (与上次报告相同 - 无新增冲突)' }
}
Write-Output ("report: {0}" -f $Out)