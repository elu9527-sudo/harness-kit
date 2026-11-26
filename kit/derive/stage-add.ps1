<#
.SYNOPSIS
  Land stage drafts into the contract WITHOUT making the human type JSON.
  The coach produces a pasteable draft block; the human saves it as a file;
  this script validates, merges, records the contract_change, and shows the
  diff before anything touches disk.

.DESCRIPTION
  Splitting drafting / entering / confirming (the 11-10 process fix):
    drafting    coach or doc-agent  -> a fenced JSON block, never retyped
    entering    THIS SCRIPT         -> schema checks, ownership checks, merge
    confirming  the human           -> reads the diff, presses y. verify/risk
                                       remain the human's responsibility; only
                                       the typing moved to the machine.
  This is the contract-side application of the lesson behind sign-gate: three
  recorded incidents (11-07 argv double-kill, the NUL destroyed signatures,
  "y y") share one root cause - making a human hand-type machine syntax.

  Rejects (exit 2, no disk write, no ledger entry):
    - missing fields / duplicate ids (existing or within the batch)
    - risk not explicitly L1/L2/L3
    - generates colliding with an existing stage's ownership
    - verify containing commands that cannot fail (echo / exit 0 / true /
      python -c pass / grep -c) - the same trivial rules as append-event's
      Test-TrivialCommand, kept inline to avoid dot-sourcing a script with
      side effects; if the two lists ever diverge, append-event's is canonical
    - requires pointing at ids that exist nowhere

.PARAMETER Draft
  Path of the draft file (single stage object or array of them).
  Default .harness\local\stage-draft.json.

.EXAMPLE
  pwsh -File .harness\derive\stage-add.ps1              # interactive confirm
  pwsh -File .harness\derive\stage-add.ps1 -DryRun      # validate + preview
  pwsh -File .harness\derive\stage-add.ps1 -Yes         # unattended (scripts)

.OUTPUTS
  exit 0 merged + contract_change landed
  exit 1 write/ledger failure
  exit 2 validation rejects / bad arguments
#>
[CmdletBinding()]
param(
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),
    [string] $Draft = '',
    [string] $ApprovedBy = 'human',
    [switch] $Yes,
    [switch] $DryRun,
    [switch] $Paste   # force stdin paste mode even if a default draft file exists
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$profPath = Join-Path $Root '.harness\project.json'
$draftPath = ''
if ($Draft -ne '') {
    $draftPath = if ([System.IO.Path]::IsPathRooted($Draft)) { $Draft } else { Join-Path $Root $Draft }
    if (-not (Test-Path -LiteralPath $draftPath -PathType Leaf)) {
        Write-Host "[FAIL] 指定的草案文件不存在: $draftPath" -ForegroundColor Red
        exit 2
    }
} else {
    # default file first (coach flow / scripts), fall back to PASTE MODE only
    # when nothing was ever written there - never silently ignore a draft file.
    # 11-12 fix: a leftover default file used to SILENTLY swallow an interactive
    # paste (user pasted 8.3/8.4, script landed stale 7.1). Now: -Paste forces
    # stdin; using the default file prints a loud notice naming it, so a stale
    # draft can never masquerade as the user's paste unnoticed.
    $defaultDraft = Join-Path $Root '.harness\local\stage-draft.json'
    if ($Paste) {
        $draftPath = ''   # explicit paste wins over any leftover file
    } elseif (Test-Path -LiteralPath $defaultDraft -PathType Leaf) {
        $draftPath = $defaultDraft
        $firstId = ''
        try { $o = (Get-Content -LiteralPath $defaultDraft -Raw -Encoding UTF8 | ConvertFrom-Json); $firstId = [string](@($o)[0].id) } catch { }
        Write-Host "[stage-add] 注意：检测到默认草案文件 stage-draft.json（首条 id='$firstId'），将使用它而非粘贴。" -ForegroundColor Yellow
        Write-Host "[stage-add] 如要粘贴教练的新草案：按 N 取消，删除该文件，或加 -Paste 重跑。" -ForegroundColor Yellow
    }
}
$draftRaw = ''
if ($draftPath -ne '') {
    $draftRaw = [System.IO.File]::ReadAllText($draftPath, [System.Text.Encoding]::UTF8)
} else {
    # PASTE MODE (11-10 user demand): no file to create, no argv to survive.
    # Run the script, paste the coach's WHOLE draft block verbatim - fence
    # lines and indentation included, fences are stripped below - end with one
    # blank line. Multi-line content never crosses argv, the same boundary that
    # killed the 11-07 gate commands. Control characters are refused at read
    # time: a destroyed paste must die HERE, not become contract bytes.
    Write-Host '[stage-add] 粘贴模式：把教练的草案块整块粘进来（``` 围栏和换行照粘），空行结束。建议用桌面 PowerShell 7 快捷方式（5.1 宿主可能毁中文）。' -ForegroundColor Cyan
    $plines = Read-ReasonLines
    $draftRaw = ($plines -join "`n")
    if ($draftRaw -match "[\u0000-\u0008\u000B\u000C\u000E-\u001F]") {
        Write-Host '[FAIL] 粘贴内容含控制字符 - 宿主毁了这个粘贴，契约未动。换 pwsh 7 窗口重贴。' -ForegroundColor Red
        exit 2
    }
}
# strip markdown fences anywhere: ```json / ``` lines dropped, content kept
$kept = [System.Collections.Generic.List[string]]::new()
foreach ($ln in ($draftRaw -split "`r?`n")) {
    if ($ln.Trim() -match '^```') { continue }
    $kept.Add($ln)
}
$draftRaw = ($kept -join "`n").Trim()
if ($draftRaw -eq '') { Write-Host '[FAIL] 空草案（粘贴为空或文件为空）' -ForegroundColor Red; exit 2 }
if (-not (Test-Path -LiteralPath $profPath -PathType Leaf)) {
    Write-Host "[FAIL] 契约不存在: $profPath" -ForegroundColor Red
    exit 2
}

# $draftRaw was built above (file read or paste + fence strip) - do NOT re-read
# $draftPath here: in paste mode it is empty and ReadAllText would throw.
try { $draftObj = $draftRaw | ConvertFrom-Json }
catch {
    Write-Host '[FAIL] 草案不是合法 JSON - 检查粘贴是否截断/多带了别的东西。契约未动。' -ForegroundColor Red
    exit 2
}
# statement form - never `$x = if (...) { @() } else {...}` (unrolls to $null)
$newStages = @()
if ($draftObj -is [array]) { $newStages = @($draftObj) } else { $newStages = @($draftObj) }
if ($newStages.Count -eq 0) { Write-Host '[FAIL] 草案是空列表' -ForegroundColor Red; exit 2 }

$profile = [System.IO.File]::ReadAllText($profPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$existing = @()
$ep = $profile.PSObject.Properties['stages']
if ($null -ne $ep) { $existing = @($ep.Value) }

# ---------------------------------------------------------------- validation
$errs = [System.Collections.Generic.List[string]]::new()
$existingIds = [System.Collections.Generic.HashSet[string]]::new()
$existingGen = @{}
foreach ($s in $existing) {
    $sid = [string]$s.id
    [void]$existingIds.Add($sid)
    $gp = $s.PSObject.Properties['generates']
    if ($null -ne $gp) { foreach ($g in @($gp.Value)) { $existingGen[(($g -replace '\\', '/'))] = $sid } }
}
$batchIds = [System.Collections.Generic.HashSet[string]]::new()

$needFields = @('id', 'goal', 'generates', 'requires', 'verify', 'risk')
$idx = 0
foreach ($ns in $newStages) {
    $idx++
    $tag = if ($null -ne $ns.PSObject.Properties['id']) { "[草案 $idx $([string]$ns.id)]" } else { "[草案 $idx]" }
    foreach ($f in $needFields) {
        if ($null -eq $ns.PSObject.Properties[$f]) { $errs.Add("$tag 缺字段 $f") }
    }
    $sid = [string]$ns.id
    if ($sid -eq '') { $errs.Add("$tag id 为空") ; continue }
    if ($existingIds.Contains($sid)) { $errs.Add("$tag id '$sid' 与既有 stage 撞号") }
    if ($batchIds.Contains($sid))   { $errs.Add("$tag id '$sid' 与本批次前一条撞号") }
    [void]$batchIds.Add($sid)

    $risk = [string]$ns.risk
    if ($risk -notin @('L1', 'L2', 'L3')) { $errs.Add("$tag risk='$risk' 必须显式为 L1/L2/L3（不填不算 L1）") }

    $genArr = @($ns.generates)
    if ($genArr.Count -eq 0) { $errs.Add("$tag generates 为空——status 无法用文件判据收口（noFiles）") }
    foreach ($g in $genArr) {
        $gRel = ($g -replace '\\', '/')
        if ($existingGen.ContainsKey($gRel)) { $errs.Add("$tag generates '$gRel' 侵犯 $existingGen[$gRel] 的所有权——被改的既有文件走 record-edit，不进新 stage 的 generates") }
    }

    $vArr = @()
    $vp = $ns.PSObject.Properties['verify']
    if ($null -ne $vp) { $vArr = @($vp.Value) }
    if ($vArr.Count -eq 0) { $errs.Add("$tag verify 为空——没有能失败的命令就没有证据") }
    foreach ($v in $vArr) {
        $vs = [string]$v
        # inline trivial rules (append-event's Test-TrivialCommand is canonical)
        if ($vs -match '(^|\s)(echo|Write-Host|Write-Output)\s' -or $vs -match '(^|\s)exit\s+0(\s|$)' -or
            $vs -match '(^|\s)true(\s|$)' -or $vs -match "python\s+(-\w+\s+)*-c\s+['`"]?\s*pass" -or
            $vs -match '\bgrep\s+-c\b') {
            $errs.Add("$tag verify 含不可能失败的命令: $vs（判 trivial，不算证据）")
        }
    }

    foreach ($r in @($ns.requires)) {
        $rs = [string]$r
        if (-not $existingIds.Contains($rs) -and -not $batchIds.Contains($rs)) {
            $errs.Add("$tag requires '$rs' 在契约和批次里都不存在")
        }
    }
}
if ($errs.Count -gt 0) {
    Write-Host '[REJECT] 草案不合格，未写盘、未入账（烂草案留在草稿区不算事故）：' -ForegroundColor Red
    foreach ($e in $errs) { Write-Host "  x $e" -ForegroundColor Red }
    exit 2
}

# ---------------------------------------------------------------- preview
$beforeSha = Get-FileSha256Hex -Path $profPath
Write-Host ''
Write-Host ('[stage-add] 契约现 {0} 个 stage: {1}' -f $existing.Count, (($existing | ForEach-Object { [string]$_.id }) -join ' ')) -ForegroundColor Cyan
Write-Host ('            将新增 {0} 个:' -f $newStages.Count) -ForegroundColor Green
foreach ($ns in $newStages) {
    Write-Host ('  + {0}  [{1}] {2}' -f [string]$ns.id, [string]$ns.risk, [string]$ns.goal)
    Write-Host ('      generates: {0}' -f ((@($ns.generates) -join ', '))) -ForegroundColor DarkGray
    Write-Host ('      verify   : {0}' -f ((@($ns.verify) -join ' ;; '))) -ForegroundColor DarkGray
}
if ($DryRun) { Write-Host '[dry-run] 校验通过，未写盘。' -ForegroundColor Yellow; exit 0 }

# ---------------------------------------------------------------- confirm
if (-not $Yes) {
    if ([Console]::IsInputRedirected) {
        Write-Host '[FAIL] stdin 被重定向 - 拒绝让管道代替人确认契约（同 sign-gate 规则）' -ForegroundColor Red
        exit 1
    }
    Write-Host ''
    Write-Host '确认把以上 stage 写入契约并落 contract_change？[y/N] ' -ForegroundColor Yellow -NoNewline
    $ans = [Console]::In.ReadLine()
    if ($null -eq $ans -or ($ans.Trim() -notmatch '^(y|yes|是|确认)$')) { Write-Host '已取消，未动契约。' -ForegroundColor Gray; exit 0 }
}

# ---------------------------------------------------------------- merge + atomic write
# 插步（x.y.z）必须插在它的父步之后，不能 append 到表尾（2026-11-18）。
# 表序就是优先级：1.2.1 曾落到 1.5 后面 → status 的 next 判成 1.3 → post-tool 按
# 1.3 打标 → finish-step 1.2.1 找不到自己的 before 图。合成键只在「同层」比较：
# 1.2.1 的键 = 1*1000000 + 2*1000 + 1，正好落在 1.2 与 1.3 之间。
function Get-StageKey([string]$Id) {
    $p = @($Id -split '\.')
    if ($p.Count -eq 1) { $n = 0; if ([int]::TryParse($p[0], [ref]$n)) { return $n * 1000000 } ; return [int]::MaxValue }
    if ($p.Count -eq 2) { $a = 0; $b = 0; if ([int]::TryParse($p[0], [ref]$a) -and [int]::TryParse($p[1], [ref]$b)) { return $a * 1000000 + $b * 1000 } ; return [int]::MaxValue }
    $a = 0; $b = 0; $c = 0
    if ([int]::TryParse($p[0], [ref]$a) -and [int]::TryParse($p[1], [ref]$b) -and [int]::TryParse($p[2], [ref]$c)) { return $a * 1000000 + $b * 1000 + $c }
    return [int]::MaxValue
}
$merged = [System.Collections.Generic.List[object]]::new()
foreach ($s in $existing) { $merged.Add($s) }
foreach ($ns in $newStages) {
    $nk = Get-StageKey ([string]$ns.id)
    $at = $merged.Count
    for ($i = 0; $i -lt $merged.Count; $i++) {
        if ((Get-StageKey ([string]$merged[$i].id)) -gt $nk) { $at = $i; break }
    }
    $merged.Insert($at, $ns)
    Write-Host ("            位置: {0} -> 表内第 {1} 位（父步之后）" -f $ns.id, $at) -ForegroundColor DarkGray
}
if ($null -ne $profile.PSObject.Properties['stages']) {
    $profile.stages = $merged
} else {
    $profile | Add-Member -NotePropertyName stages -NotePropertyValue $merged
}
$json = ConvertTo-Json $profile -Depth 12
[System.IO.File]::WriteAllText($profPath, $json, (New-Object System.Text.UTF8Encoding($false)))
$afterSha = Get-FileSha256Hex -Path $profPath
# single-generation disk backup; the real insurance is the hash chain
[System.IO.File]::Copy($profPath, (Join-Path $Root '.harness\local\project.json.prev'), $true)

# ---------------------------------------------------------------- ledger
$ids = (($newStages | ForEach-Object { [string]$_.id }) -join ',')
$draftSha = if ($draftPath -ne '') {
    Get-FileSha256Hex -Path $draftPath
} else {
    # paste mode: hash the pasted content itself, so the ledger pins WHAT was
    # approved even though it lived only in a clipboard and a console buffer
    (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($draftRaw))) -Algorithm SHA256).Hash.ToLower()
}
$data = @{
    file           = '.harness/project.json'
    before_sha256  = $beforeSha
    after_sha256   = $afterSha
    why            = "stage-add: landed [$ids] from validated draft (draft sha $draftSha); typing by machine, verify/risk confirmed by the human at the keyboard"
    approved_by    = $ApprovedBy
    approved_at    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
} | ConvertTo-Json -Compress -Depth 4
$tmp = Join-Path $env:TEMP ('sa-' + [guid]::NewGuid().ToString('N') + '.json')
[System.IO.File]::WriteAllText($tmp, $data, (New-Object System.Text.UTF8Encoding($false)))
try {
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'append-event.ps1') -Root $Root -Event contract_change -Step contract -Actor 'human' -DataJsonFile $tmp -Quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] 契约已写盘但 contract_change 入账失败（exit $LASTEXITCODE）- 立即人工补账，否则 C7/C10 把你当入侵者" -ForegroundColor Yellow
        exit 1
    }
}
finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

# 11-12: consume the default draft once landed so a stale file can never shadow
# the next paste. Only touch the default path, never a user-specified -Draft.
$defaultDraft2 = Join-Path $Root '.harness\local\stage-draft.json'
if ($draftPath -ne '' -and $draftPath -eq $defaultDraft2) {
    Remove-Item -LiteralPath $defaultDraft2 -Force -ErrorAction SilentlyContinue
}

Write-Host '[stage-add] OK - 契约已合并并落账。下一步：' -ForegroundColor Green
Write-Host '  pwsh -File .harness\derive\status.ps1   （NEXT 应指向新 stage）' -ForegroundColor White
exit 0
