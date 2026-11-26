<#
.SYNOPSIS
  Derive project status from profile.json + filesystem. Never reads the ledger to decide state.

.DESCRIPTION
  States: done | ready | blocked
    done    = every file in generates exists
    ready   = not done, and every stage in requires is done
    blocked = not done, and some required stage is not done

  next = first ready stage in profile order.
  anomalies = places where the ledger and the filesystem disagree.

  Exit codes:
    0  profile parsed, status produced
    2  profile missing / unparsable

.EXAMPLE
  pwsh -File status.ps1 -Root D:\proj
  pwsh -File status.ps1 -Root D:\proj -Json
#>
[CmdletBinding()]
param(
    # default: when installed at <project>/.harness/derive/, walk up two levels to <project>
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),
    [switch] $Json,
    [switch] $Quiet,
    [switch] $SyncStep,
    # -Brief: DONE/BLOCKED 只列 id、READY 只给短名。默认输出的 96% 是已完成阶段的
    # goal 长句（实测 12 步 1475 字里 1420 字是 DONE 区），而教练看一眼 DONE 只需要
    # 知道「这几步完了」，不需要每一步当初的承诺原文。要原文去读交接卡/契约。
    [switch] $Brief
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$projectPath = Join-Path (Join-Path $Root '.harness') 'project.json'
$localPath   = Join-Path (Join-Path $Root '.harness') 'local.json'
$eventsPath  = Join-Path $Root 'events.jsonl'

if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    if ($Json) {
        [pscustomobject]@{ ok = $false; error = 'profile_missing'; path = $projectPath } | ConvertTo-Json -Depth 5
    }
    elseif (-not $Quiet) {
        Write-Host "[FAIL] profile not found: $projectPath" -ForegroundColor Red
    }
    exit 2
}

try {
    $profile = Get-Content -LiteralPath $projectPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    if ($Json) {
        [pscustomobject]@{ ok = $false; error = 'profile_invalid'; detail = $_.Exception.Message } | ConvertTo-Json -Depth 5
    }
    elseif (-not $Quiet) {
        Write-Host "[FAIL] profile invalid: $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 2
}

$stageProp = $profile.PSObject.Properties['stages']
    # statement form everywhere: an if-EXPRESSION emits through the output stream,
    # where @() unrolls to nothing -> variable becomes $null -> `.Count`/enumeration
    # behave wrong under StrictMode (same trap that killed trigger 2026-11-09).
    $stages = @()
    if ($null -ne $stageProp) { $stages = @($stageProp.Value) }
$projectName = if ($null -ne $profile.PSObject.Properties['project']) { [string]$profile.project } else { 'unnamed' }

# ---------- read the ledger once ----------
$events = Read-EventLog -Path $eventsPath

# Where the hook believes we are. Everything before it has been finished by a
# finish-step run (that is the only thing that advances it), so those stages are
# exempt from the "must be verified" rule below.
$localStep = ''
if (Test-Path -LiteralPath $localPath -PathType Leaf) {
    try {
        $loCur = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $pc = $loCur.PSObject.Properties['current_step']
        if ($null -ne $pc) { $localStep = [string]$pc.Value }
    }
    catch { }
}

function Get-StepOrder {
    param([string] $Step)
    if ($Step -match '^(\d+)\.(\d+)\.(\d+)$') { return ([int]$Matches[1] * 1000000 + [int]$Matches[2] * 1000 + [int]$Matches[3]) }
    if ($Step -match '^(\d+)\.(\d+)$')       { return ([int]$Matches[1] * 1000000 + [int]$Matches[2] * 1000) }
    return -1
}
$localOrder = Get-StepOrder -Step $localStep

# ---------- pass 0: newest verify verdict per stage (three-state) ----------
# exit != 0 is a counter-proof; exit == 0 with trivial=true refutes nothing but
# proves nothing either; only a meaningful pass is evidence. Collapsing VOID into
# PASS let `echo ok` stand as stage 0.1's acceptance through an entire run.
$verifyVerdict = @{}
$toolUseFiles = @{}
foreach ($e in $events) {
    if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
    $evName = [string]$e.event

    # Files the hook watched being written. Used to tell "built under observation"
    # from "predates the hook" - see the done rule in pass 2.
    if ($evName -eq 'tool_use') {
        $dpU = $e.PSObject.Properties['data']
        if ($null -ne $dpU) {
            $fpU = $dpU.Value.PSObject.Properties['file']
            if ($null -ne $fpU -and [string]$fpU.Value -ne '') { $toolUseFiles[[string]$fpU.Value] = $true }
        }
        continue
    }

    if ($evName -ne 'verify') { continue }
    $dp0 = $e.PSObject.Properties['data']
    if ($null -eq $dp0) { continue }
    $d0 = $dp0.Value
    $tp0 = $d0.PSObject.Properties['target']
    if ($null -eq $tp0) { continue }
    $tgt = [string]$tp0.Value
    if ($tgt -eq '') { continue }
    $ex0 = if ($null -ne $d0.PSObject.Properties['exit']) { [int]$d0.exit } else { 1 }
    $tr0 = ($null -ne $d0.PSObject.Properties['trivial']) -and [bool]$d0.trivial
    $re0 = ($null -ne $d0.PSObject.Properties['real_test']) -and [bool]$d0.real_test
    # last one wins: a later pass clears an earlier failure
    $verifyVerdict[$tgt] = if ($ex0 -ne 0) { 'fail' } elseif ($tr0 -or -not $re0) { 'void' } else { 'pass' }
}

# ---------- pass 1: does every generated file exist? ----------
$fileState = @{}
foreach ($s in $stages) {
    $id = [string]$s.id
    $genProp = $s.PSObject.Properties['generates']
    $gen = @()
    if ($null -ne $genProp) { $gen = @($genProp.Value) }

    $missing = @()
    $present = @()
    foreach ($g in $gen) {
        $abs = if ([System.IO.Path]::IsPathRooted($g)) { $g } else { Join-Path $Root $g }
        if (Test-Path -LiteralPath $abs -PathType Leaf) { $present += [string]$g } else { $missing += [string]$g }
    }
    $fileState[$id] = [pscustomobject]@{
        generates = @($gen)
        present   = $present
        missing   = $missing
        existsAll = ((@($missing).Count -eq 0) -and (@($gen).Count -gt 0))
        noFiles   = (@($gen).Count -eq 0)   # a stage that generates nothing cannot be 'done' by file presence
    }
}

# ---------- pass 2: resolve done / ready / blocked in profile order ----------
$status = @{}
$artifacts = [System.Collections.Generic.List[object]]::new()

# done-set：先一次性算完"哪些步有 PASS"，再判依赖。这样 done 与表序、与 cursor 全无关
# （2026-11-25）。之前 done 依赖评估顺序 + cursor，一步数据错就能把之后几十步全冻住。
$doneSet = @{}
foreach ($k in $verifyVerdict.Keys) {
    if ([string]$verifyVerdict[$k] -eq 'pass') { $doneSet[[string]$k] = $true }
}

# supersede 锚点：账本里"哪一步删了哪个文件"。删文件不是凭空蒸发，是某一步的决定——
# 用那条决定当锚点，就不需要给被取代的阶段加墓碑（2026-11-25）。
$removedBy = @{}
foreach ($e in $events) {
    if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
    if ([string]$e.event -ne 'file_removed') { continue }
    $dp2 = $e.PSObject.Properties['data']; if ($null -eq $dp2) { continue }
    $fp2 = $dp2.Value.PSObject.Properties['file']; if ($null -eq $fp2) { continue }
    $p2 = ([string]$fp2.Value).Replace('\', '/')
    if ($p2) { $removedBy[$p2] = [string]$e.step }
}

foreach ($s in $stages) {
    $id = [string]$s.id
    $fs = $fileState[$id]

    # `done` = 这一步有真实的 PASS 验收（2026-11-25 改口径）。
    # 旧口径要求「generates 里的文件今天还存在」+ 序数规则（cursor 之后的阶段一律不算 done）。
    # 两条都会在项目演进时误伤：2.0.40 把 2.0.18 的 os_driver/os_runner 删掉后，2.0.18 变成
    # 永远关不掉的死步；它的前向引用又把 cursor 钉在 2.0.18，序数规则随即把之后 30 个
    # **已经有 PASS** 的步骤全判成 blocked —— 活的做了、账不认，而 finish-step 每步都报成功。
    #
    # 新判据：有 PASS 就算 done，删文件不再撤销已完成（"它当时确实产出过"这件事由账本+diff+commit
    # 证明，不由今天的磁盘证明）。文件缺失仍在 missing 字段里显示，供人看，但不阻断。
    # 反证（最新 verify FAIL）仍然生效：verdict 不会是 pass，自然落回 ready，next 指回它。
    $verdict = if ($verifyVerdict.ContainsKey($id)) { $verifyVerdict[$id] } else { 'none' }
    $doneOk = ($verdict -eq 'pass')

    if ($doneOk) {
        $status[$id] = 'done'
    }
    else {
        $reqProp = $s.PSObject.Properties['requires']
        $req = @()
        if ($null -ne $reqProp) { $req = @($reqProp.Value) }
        $depsOk = $true
        $unmet  = @()
        foreach ($r in $req) {
            $rId = [string]$r
            # done 现在是**与顺序无关**的（只看该步自己的 PASS），所以依赖也按 done-set 判，
            # 不再读"评估到哪了"。这一改同时消灭两个历史坑：
            #   · 2026-11-23 之前的 lookahead：把"文件在"当成"验收过"（2.0.9 抢 NEXT）
            #   · 2026-11-23 之后的"未见到就算未满足"：前向引用（2.0.17 requires 2.0.18）
            #     被永久判 blocked，而 2.0.18 明明已经有 PASS
            if (-not $doneSet.ContainsKey($rId)) { $depsOk = $false; $unmet += $rId }
        }
        $status[$id] = if ($depsOk) { 'ready' } else { 'blocked' }
    }

    $riskProp = $s.PSObject.Properties['risk']
    # verify may be one command or a list; keep it as a list so the renderer
    # can print one line per command instead of jamming them together.
    # statement form - see note at $stages above.
    $verifyList = @()
    if ($null -ne $s.PSObject.Properties['verify']) {
        $verifyList = @(@($s.verify) | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
    }
    $artifacts.Add([pscustomobject]@{
        id        = $id
        goal      = if ($null -ne $s.PSObject.Properties['goal']) { [string]$s.goal } else { '' }
        status    = $status[$id]
        risk      = if ($null -ne $riskProp) { [string]$riskProp.Value } else { 'L1' }
        generates = $fs.generates
        missing   = $fs.missing
        verify    = $verifyList
        verify_state = $verdict
    })
}

$next = $null
# 「第一个 ready」按**版本序**取，不按数组序（2026-11-18）。
# 表序曾经是唯一约定，可 stage-add 早年是 append：插步 1.2.1 落到 1.5 后面，
# 于是 next 判成 1.3 → post-tool 按 1.3 打标 → before 图进 docs/_snap/1.3/ →
# finish-step 1.2.1 报「no snapshot manifest」。归因错位不该由「人记得把表排好」
# 来保证，所以这里改成按 id 的版本序；数组序只在同一步内还有意义。
# 非数字 id（contract/genesis 之类）排到末尾，不抢位置。
$ordered = @($artifacts | Sort-Object -Property @{ Expression = {
    $o = Get-StepOrder -Step ([string]$_.id)
    if ($o -lt 0) { [int]::MaxValue } else { $o }
} })
foreach ($a in $ordered) { if ($a.status -eq 'ready') { $next = $a.id; break } }
$complete = ($artifacts.Count -gt 0) -and (@($artifacts | Where-Object { $_.status -ne 'done' }).Count -eq 0)

# ---------- anomalies: ledger vs filesystem ----------
$anomalies = [System.Collections.Generic.List[object]]::new()

function Normalize-Cmd {
    param([string] $C)
    if ([string]::IsNullOrWhiteSpace($C)) { return '' }
    return (($C -replace '["'']', '' -replace '\s+', ' ').Trim().ToLower())
}

# declared verify per stage (from profile), used to bind evidence to the command.
# The join separator must match what append-event.ps1 writes into data.cmd, or
# every list-form verify reports verify_mismatch and its PASS silently stops
# counting - the evidence is there, the comparison just never matches.
# (Observed immediately after verify became a list: 3.1.1 had a real PASS at
# seq271 and status still called it done_without_evidence.)
$VERIFY_JOIN = ' ;; '
$stageVerify = @{}
foreach ($s in $stages) {
    $vp = $s.PSObject.Properties['verify']
    if ($null -ne $vp) {
        $parts = @(@($vp.Value) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $v = ($parts -join $VERIFY_JOIN)
        if (-not [string]::IsNullOrWhiteSpace($v)) { $stageVerify[[string]$s.id] = $v }
    }
}

# index: last known sha256 per path, and verify evidence per step
$lastSha         = @{}
$verified        = @{}
$verifiedMismatch = @{}
$openBlock       = @{}

foreach ($e in $events) {
    if ($null -ne $e.PSObject.Properties['__parse_error']) {
        $anomalies.Add([pscustomobject]@{ kind = 'parse_error'; step = ''; detail = "line $($e.__line): $($e.__parse_error)" })
        continue
    }
    $ev  = [string]$e.event
    $stp = [string]$e.step

    if ($ev -eq 'tool_use') {
        # the PostToolUse hook writes one tool_use per file mutation; this is the
        # only source of file digests (step_end was removed: nothing ever wrote it)
        $dataProp = $e.PSObject.Properties['data']
        if ($null -ne $dataProp) {
            $d = $dataProp.Value
            $fp = $d.PSObject.Properties['file']
            $hp = $d.PSObject.Properties['sha256']
            if ($null -ne $fp -and $null -ne $hp -and [string]$hp.Value -ne '') {
                $lastSha[[string]$fp.Value] = [string]$hp.Value
            }
        }
    }
    elseif ($ev -eq 'verify') {
        $dataProp = $e.PSObject.Properties['data']
        if ($null -ne $dataProp) {
            $d = $dataProp.Value
            $exitOk    = ($null -ne $d.PSObject.Properties['exit'])      -and ([int]$d.exit -eq 0)
            $trivProp  = $d.PSObject.Properties['trivial']
            $realProp  = $d.PSObject.Properties['real_test']
            $trivial   = ($null -ne $trivProp) -and [bool]$trivProp.Value
            $realTest  = ($null -ne $realProp) -and [bool]$realProp.Value
            $target    = if ($null -ne $d.PSObject.Properties['target']) { [string]$d.target } else { '' }
            $cmdProp   = $d.PSObject.Properties['cmd']
            $ranCmd    = if ($null -ne $cmdProp) { [string]$cmdProp.Value } else { '' }

            # evidence only counts if it came from the command the profile declares
            $declared = if ($stageVerify.ContainsKey($target)) { $stageVerify[$target] } else { '' }
            $cmdOk = $true
            if ($declared -ne '') { $cmdOk = ((Normalize-Cmd $ranCmd) -eq (Normalize-Cmd $declared)) }

            if ($exitOk -and -not $trivial -and $realTest -and $cmdOk) {
                $verified[$target] = $true
            }
            elseif ($exitOk -and -not $trivial -and $realTest -and -not $cmdOk) {
                $verifiedMismatch[$target] = [pscustomobject]@{ declared = $declared; ran = $ranCmd }
            }
        }
    }
    elseif ($ev -eq 'blocker_open') {
        $dataProp = $e.PSObject.Properties['data']
        if ($null -ne $dataProp) { $openBlock[[string]$dataProp.Value.id] = $stp }
    }
    elseif ($ev -eq 'blocker_close') {
        $dataProp = $e.PSObject.Properties['data']
        if ($null -ne $dataProp) { $openBlock.Remove([string]$dataProp.Value.id) }
    }
}

foreach ($k in $verifiedMismatch.Keys) {
    $mm = $verifiedMismatch[$k]
    $anomalies.Add([pscustomobject]@{
        kind = 'verify_mismatch'; step = $k
        detail = "evidence ran '$($mm.ran)' but profile declares '$($mm.declared)'"
    })
}

foreach ($a in $artifacts) {
    if ($a.verify_state -eq 'fail') {
        $anomalies.Add([pscustomobject]@{
            kind = 'verify_failed'; step = $a.id
            detail = 'newest verify exited non-zero - a counter-proof, not a missing citation'
        })
    }
    if ($a.status -eq 'done' -and -not $verified.ContainsKey($a.id)) {
        $why = if ($a.verify_state -eq 'void') {
            'verify only ever ran trivially (trivial=true) - a command that cannot fail proves nothing'
        } else {
            'all files exist but no passing verify(exit=0,trivial=false,real_test=true) in events'
        }
        $anomalies.Add([pscustomobject]@{
            kind = 'done_without_evidence'; step = $a.id; detail = $why
        })
    }
    if ($a.status -eq 'done') {
        foreach ($g in $a.generates) {
            $key = [string]$g
            if ($lastSha.ContainsKey($key)) {
                $abs = if ([System.IO.Path]::IsPathRooted($g)) { $g } else { Join-Path $Root $g }
                $now = Get-FileSha256Hex -Path $abs
                if ($now -ne $lastSha[$key]) {
                    $anomalies.Add([pscustomobject]@{
                        kind = 'drifted'; step = $a.id
                        detail = "$key sha256 differs from last recorded (recorded=$($lastSha[$key].Substring(0,[Math]::Min(12,$lastSha[$key].Length))) now=$($now.Substring(0,[Math]::Min(12,$now.Length))))"
                    })
                }
            }
        }
    }
    if ($a.status -eq 'ready' -and $openBlock.Count -gt 0) {
        $anomalies.Add([pscustomobject]@{
            kind = 'ready_with_blocker'; step = $a.id
            detail = "still open: $(($openBlock.Keys | Sort-Object) -join ', ')"
        })
    }
}

# ---------- severity: only anomalies on the CURRENT next stage are blocking ----------
# Everything attached to an already-done step is history: it affects provability,
# not whether the work exists. Without this split, a coach reading "don't proceed
# while anomalies exist" stalls forever on old gaps.
foreach ($x in $anomalies) {
    # A counter-proof blocks regardless of which stage it sits on: it says the
    # work is wrong, not merely uncited. Everything else blocks only on the
    # stage we are about to start.
    $sev = if ($x.kind -eq 'verify_failed') { 'blocking' }
           elseif ($null -ne $next -and [string]$x.step -eq [string]$next) { 'blocking' }
           else { 'historical' }
    $x | Add-Member -NotePropertyName severity -NotePropertyValue $sev -Force
}

# ---------- output ----------
$result = [pscustomobject]@{
    ok        = $true
    project   = $projectName
    next      = $next
    complete  = $complete
    artifacts = $artifacts.ToArray()
    anomalies = $anomalies.ToArray()
}

# ---------- optional: keep .harness/local.json current_step in sync ----------
# The post-tool hook stamps every event with local.json's current_step. If that
# value is stale, events get attached to the wrong step (observed in practice:
# a deviate about ports landed on step 1.2 instead of 1.5). Running status with
# -SyncStep keeps it aligned with the derived next stage.
if ($SyncStep -and $null -ne $next) {
    $localFile = Join-Path (Join-Path $Root '.harness') 'local.json'
    $localObj  = [ordered]@{}
    if (Test-Path -LiteralPath $localFile -PathType Leaf) {
        try {
            $existing = Get-Content -LiteralPath $localFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($pr in $existing.PSObject.Properties) { $localObj[$pr.Name] = $pr.Value }
        }
        catch { }
    }
    $localObj['current_step'] = $next
    $newJson = ConvertTo-Json -InputObject $localObj -Depth 6
    $oldJson = if (Test-Path -LiteralPath $localFile -PathType Leaf) {
        Get-Content -LiteralPath $localFile -Raw -Encoding UTF8
    } else { '' }
    # Rewriting identical bytes is not a no-op: it bumps mtime, which makes the
    # file look modified to every watcher and to drift analysis. The repo this
    # design draws on states the invariant as "refresh when stale, do not write
    # when identical" - honour it here rather than writing on every status call.
    if ($newJson.Trim() -ne $oldJson.Trim()) {
        $newJson | Set-Content -LiteralPath $localFile -Encoding UTF8
        if (-not $Quiet -and -not $Json) {
            Write-Host "  synced current_step -> $next" -ForegroundColor DarkGray
        }
    }
    elseif (-not $Quiet -and -not $Json) {
        Write-Host "  current_step already $next (no write)" -ForegroundColor DarkGray
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
    exit 0
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host "project: $projectName" -ForegroundColor Cyan

    if ($complete) {
        Write-Host '  COMPLETE - all stages done' -ForegroundColor Green
    }
    elseif ($null -ne $next) {
        $n = $artifacts | Where-Object { $_.id -eq $next } | Select-Object -First 1
        Write-Host "  NEXT  $next  $($n.goal)" -ForegroundColor Green
        if ($n.risk)    { Write-Host "        risk      $($n.risk)" }
        foreach ($vc in @($n.verify)) { Write-Host "        verify    $vc" }
        if ($n.missing) { Write-Host "        generate  $($n.missing -join ', ')" }
    }
    else {
        # An empty contract is not "blocked", it is "the coach has not written the
        # plan yet". Saying "everything is blocked" to a freshly installed project
        # reads as a broken install and sends the reader looking for a fault that
        # does not exist; the actionable next step belongs right here.
        $stageCount = @($profile.stages | Where-Object { $null -ne $_ }).Count
        if ($stageCount -eq 0) {
            Write-Host '  CONTRACT EMPTY - 契约里还没有阶段（安装已完成，等教练出草案）' -ForegroundColor Yellow
            Write-Host '        next     coach 出阶段草案，然后：' -ForegroundColor Yellow
            Write-Host '                 pwsh -File .harness\derive\stage-add.ps1 -Paste    (按 y 签)' -ForegroundColor Yellow
        }
        else {
            Write-Host '  NO READY STAGE - everything is blocked' -ForegroundColor Yellow
        }
    }

    Write-Host ''
    foreach ($g in ($artifacts | Group-Object status)) {
        Write-Host "  $($g.Name.ToUpper())" -ForegroundColor DarkGray
        if ($Brief -and $g.Name -ne 'ready') {
            # 非 ready 组只留 id：够了，问「到哪一步」的答案就在这一行。
            $ids = @($g.Group | Sort-Object -Property @{ Expression = {
                $o = Get-StepOrder -Step ([string]$_.id); if ($o -lt 0) { [int]::MaxValue } else { $o }
            } } | ForEach-Object { [string]$_.id })
            Write-Host ("    {0}  ({1})" -f ($ids -join ' '), $ids.Count)
            continue
        }
        foreach ($a in $g.Group) {
            $mark = switch ($a.status) {
                'done'    { '[x]' }
                'ready'   { '[>]' }
                'blocked' { '[ ]' }
                default   { '[?]' }
            }
            if ($Brief) {
                # 短名：在第一个「（」或「：」处截断。goal 的写法就是「名字（细节…）」，
                # 所以截断点天然是名字与解释的分界，不需要另存一个短名字段。
                $gl = [string]$a.goal
                $cut = $gl.IndexOfAny([char[]]@([char]0xFF08, [char]0xFF1A))
                $short = if ($cut -gt 0) { $gl.Substring(0, $cut) } else { $gl }
                if ($short.Length -gt 28) { $short = $short.Substring(0, 28) + '…' }
                Write-Host ("    {0} {1,-6} {2}" -f $mark, $a.id, $short)
                continue
            }
            Write-Host ("    {0} {1,-6} {2}" -f $mark, $a.id, $a.goal)
        }
    }

    # 缺失的 generates 分两种：账本里有删除记录 = 后续步骤的决定（superseded）；
    # 没有记录 = 真的不见了（ORPHAN，可能是 hook 之外的手删，或从来没建过）。
    if (-not $Quiet) {
        $supPaths = @(); $orphanPaths = @(); $bfCount = 0
        foreach ($a in $artifacts) {
            if ([string]$a.status -ne 'done') { continue }   # 没做完的步本来就没有文件，不算缺失
            foreach ($mp in @($a.missing)) {
                if (-not $mp) { continue }
                $pN = ([string]$mp).Replace('\', '/')
                if ($removedBy.ContainsKey($pN) -and $removedBy[$pN] -ne [string]$a.id) {
                    $who = $removedBy[$pN]
                    if ($who -eq 'backfill') { $supPaths += ("{0}<-回填" -f $pN); $bfCount++ }
                    else { $supPaths += ("{0}<-{1}" -f $pN, $who) }
                }
                else { $orphanPaths += ("{0}({1})" -f $pN, $a.id) }
            }
        }
        if ($supPaths.Count -gt 0 -or $orphanPaths.Count -gt 0) {
            Write-Host ''
            if ($supPaths.Count -gt 0) {
                Write-Host ("  superseded  {0} 条缺失有删除记录（其中 {2} 条为回填，非现场记录）: {1}" -f $supPaths.Count, ($supPaths -join ' '), $bfCount) -ForegroundColor DarkGray
            }
            if ($orphanPaths.Count -gt 0) {
                Write-Host ("  ORPHAN      {0} 条缺失且账本无删除记录: {1}" -f $orphanPaths.Count, ($orphanPaths -join ' ')) -ForegroundColor Yellow
            }
        }
    }

    $blocking   = @($anomalies | Where-Object { $_.severity -eq 'blocking' })
    $historical = @($anomalies | Where-Object { $_.severity -ne 'blocking' })

    if ($blocking.Count -gt 0) {
        Write-Host ''
        Write-Host "  BLOCKING ANOMALIES ($($blocking.Count)) - resolve before proceeding" -ForegroundColor Red
        foreach ($x in $blocking) {
            Write-Host ("    x {0,-22} {1,-6} {2}" -f $x.kind, $x.step, $x.detail) -ForegroundColor Red
        }
    }
    if ($historical.Count -gt 0) {
        Write-Host ''
        Write-Host "  HISTORICAL GAPS ($($historical.Count)) - reported only, do NOT block progress" -ForegroundColor DarkGray
        foreach ($x in $historical) {
            Write-Host ("    · {0,-22} {1,-6} {2}" -f $x.kind, $x.step, $x.detail) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}

exit 0
