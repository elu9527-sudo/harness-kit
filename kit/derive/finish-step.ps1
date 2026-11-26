<#
.SYNOPSIS
  Close out one step: build line-level diffs, run the stage's verify, refresh status.

.DESCRIPTION
  This is the single command that ends a step. It replaces the three manual
  actions that were previously easy to skip:

    1. diff   - for every file the PreToolUse hook snapshotted into
                docs/_snap/<step>/, produce docs/_diff/<step>/<name>.diff using
                `git diff --no-index` (works without a git repository).
                This is the mechanism that makes "grep -c instead of a real
                line-level diff" impossible.
    2. verify - run profile.json's `verify` for this stage via append-event.ps1,
                which executes the command itself and records the real exit code.
    3. status - re-derive and print the project state.

  Deleted files are listed explicitly; they have no diff but are real facts.

  Exit codes:
    0  step closed, verify passed (or was skipped)
    1  verify failed (diff and events still written)
    2  bad input (no profile / unknown step)

.EXAMPLE
  pwsh -File finish-step.ps1
  pwsh -File finish-step.ps1 -Step 2.0.1
  pwsh -File finish-step.ps1 -SkipVerify
#>
[CmdletBinding()]
param(
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),
    [string] $Step = '',
    [switch] $SkipVerify,
    [switch] $Quiet,
    # -NoCommit: 关步后不自动 git 提交。项目不是 git 仓库时自动跳过，不需要这个开关。
    [switch] $NoCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$profilePath = Join-Path $Root '.harness\project.json'
$localPath   = Join-Path $Root '.harness\local.json'

# Out-of-tree paths must never enter this report. An older pre-tool.mjs - before
# it learned to refuse paths outside the project - wrote manifest entries and
# tool_use records for scratch files under C:/Users/.../Temp/. Left unfiltered
# they show up as "new" and, worse, as "deleted", which claims the project lost
# files it never had.
function Test-PathInRoot {
    param([string] $ProjectRoot, [string] $P)
    if ([string]::IsNullOrWhiteSpace($P)) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($P)) { return $true }
    $norm = ($P -replace '/', '\')
    $root = $ProjectRoot.TrimEnd('\') + '\'
    return $norm.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
}

if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    Write-Host "[FAIL] project.json not found: $profilePath" -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------- resolve step
if ([string]::IsNullOrWhiteSpace($Step) -and (Test-Path -LiteralPath $localPath -PathType Leaf)) {
    try {
        $local = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sp = $local.PSObject.Properties['current_step']
        if ($null -ne $sp) { $Step = [string]$sp.Value }
    }
    catch { }
}
if ([string]::IsNullOrWhiteSpace($Step)) {
    Write-Host "[FAIL] no step given and local.json has no current_step" -ForegroundColor Red
    exit 2
}

$profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$stage = $null
$sp = $profile.PSObject.Properties['stages']
if ($null -ne $sp) {
    foreach ($s in @($sp.Value)) { if ([string]$s.id -eq $Step) { $stage = $s; break } }
}
if ($null -eq $stage) {
    Write-Host "[FAIL] step '$Step' not found in project.json" -ForegroundColor Red
    exit 2
}

$snapDir = Join-Path (Join-Path $Root 'docs\_snap') $Step
$diffDir = Join-Path (Join-Path $Root 'docs\_diff') $Step

if (-not $Quiet) {
    Write-Host ''
    Write-Host "finish step $Step" -ForegroundColor Cyan
}

# ---------------------------------------------------------------- 1. diffs
$changed = 0; $deleted = @(); $added = @()
$manifestPath = Join-Path $snapDir '_manifest.json'

# 本步「拥有」的文件，来自 project.json 的 generates。只在本步自己的 before 图
# 找不到时，才用它去别的步目录里认领——这是 2026-11-18 那次归因错位的补救。
# 事件与哈希都在，错的只是 step 标签：插步 1.2.1 是在 current_step 已被推到 1.3
# 之后做的，PreToolUse 按 current_step 落盘，于是 before 图进了 docs/_snap/1.3/。
# 历史事件不能改（账本 append-only），所以这里按路径显式认领，并把来源步打在
# 屏幕上——认领必须看得见，否则就是拿别人的 before 图冒充自己的 diff。
$mine = @()
$gp = $stage.PSObject.Properties['generates']
if ($null -ne $gp) { $mine = @($gp.Value | ForEach-Object { ([string]$_).Replace('\', '/') }) }

$entries = [System.Collections.Generic.List[object]]::new()
$manifestFrom = $null

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $manifest.PSObject.Properties) {
        $entries.Add(@{ rel = [string]$prop.Name; before = (Join-Path $snapDir ([string]$prop.Value.before)) })
    }
    $manifestFrom = $Step
}
elseif ($mine.Count -gt 0) {
    $snapRoot = Join-Path $Root 'docs\_snap'
    foreach ($d in @(Get-ChildItem -LiteralPath $snapRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        if ([string]$d.Name -eq $Step) { continue }
        $m2 = Join-Path $d.FullName '_manifest.json'
        if (-not (Test-Path -LiteralPath $m2 -PathType Leaf)) { continue }
        $o2 = Get-Content -LiteralPath $m2 -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $o2.PSObject.Properties) {
            $relN = ([string]$prop.Name).Replace('\', '/')
            if ($mine -notcontains $relN) { continue }
            $b2 = Join-Path $d.FullName ([string]$prop.Value.before)
            if (-not (Test-Path -LiteralPath $b2 -PathType Leaf)) { continue }
            $entries.Add(@{ rel = [string]$prop.Name; before = $b2 })
        }
    }
    if ($entries.Count -gt 0 -and -not $Quiet) {
        Write-Host ("  [MANIFEST] 本步没有自己的 before 图，按 generates 从别步认领 {0} 个: {1}" -f `
            $entries.Count, (($entries | ForEach-Object { $_.rel }) -join ', ')) -ForegroundColor Yellow
        Write-Host "             来源不是本步 -> diff 只覆盖本步 generates 里的路径" -ForegroundColor DarkGray
    }
}
# 认领态：diff 与 added 都要按同一口径放宽，否则「改了但没新文件」会被读成 0 变更。
$adopted = ($entries.Count -gt 0) -and -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)

if ($entries.Count -gt 0) {
    New-Item -ItemType Directory -Force -Path $diffDir | Out-Null

    foreach ($en in $entries) {
        $rel     = $en.rel
        if (-not (Test-PathInRoot -ProjectRoot $Root -P $rel)) { continue }
        $before  = $en.before
        # A manifest entry whose before-image does not exist is a broken record,
        # not a deletion. Older hooks wrote exactly this for paths they could not
        # encode (a drive-letter path collapsed into a 0-byte file named "C").
        if (-not (Test-Path -LiteralPath $before -PathType Leaf)) { continue }
        $current = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $Root $rel }

        if (-not (Test-Path -LiteralPath $current -PathType Leaf)) {
            $deleted += $rel
            continue
        }

        $safe = ($rel -replace '[\\/]', '__')
        $diffFile = Join-Path $diffDir "$safe.diff"

        # run from the project root with relative paths so the diff header is readable
        $beforeRel  = $before.Replace($Root + '\', '').Replace('\', '/')
        $currentRel = $current.Replace($Root + '\', '').Replace('\', '/')

        # git diff --no-index works outside a repository; exit 1 means "differences found"
        # core.quotepath=false: without it git octal-escapes non-ASCII paths, so a
        # diff for 变更记录.md is emitted as "\345\217\230..." and the header
        # rewrite below (which matches the literal rel path) silently fails to
        # apply - leaving the diff pointing at a _snap/ file that nobody has.
        $out = & git -c core.quotepath=false -C $Root diff --no-index --src-prefix=a/ --dst-prefix=b/ -- $beforeRel $currentRel 2>&1
        $rc = $LASTEXITCODE
        if ($rc -eq 0) { continue }      # identical
        if ($rc -gt 1) {
            Write-Host "  [warn] git diff failed for $rel (exit $rc)" -ForegroundColor Yellow
            continue
        }
        # strip git's CRLF warnings and rewrite the snapshot path to the real path,
        # otherwise the diff header names a file that does not exist
        $text = ($out | Out-String)
        $text = ($text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*warning:' }) -join "`n"
        $text = $text.Replace("a/$beforeRel", "a/$rel").Replace("b/$currentRel", "b/$rel")
        $text | Set-Content -LiteralPath $diffFile -Encoding UTF8
        $changed++
    }
}

# files written this step that had no before-image (created new)
$eventsPath = Join-Path $Root 'events.jsonl'
$adoptedEv = 0
if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
    foreach ($e in (Read-EventLog -Path $eventsPath)) {
        if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
        if ([string]$e.event -ne 'tool_use') { continue }
        $dp = $e.PSObject.Properties['data']; if ($null -eq $dp) { continue }
        $f  = $dp.Value.PSObject.Properties['file']
        $b  = $dp.Value.PSObject.Properties['before_sha256']
        if ($null -eq $f) { continue }
        $fp = [string]$f.Value
        if ($fp -like '.harness/*') { continue }   # harness 自身不是本步产出
        if (-not (Test-PathInRoot -ProjectRoot $Root -P $fp)) { continue }
        # 只算本步的写。旧版扫全量 tool_use，于是把 0.1/0.2 时代留下的 kit 文件、甚至
        # 隔离区副本都列成"这步 new 了 48 个文件"——报告读起来像造假，实际是没按步过滤。
        # 认领态（本步没自己的 before 图）改成按 generates 认领：标签错了，路径不会错。
        if ([string]$e.step -ne $Step) {
            if (-not $adopted) { continue }
            if ($mine.Count -eq 0 -or ($mine -notcontains $fp.Replace('\', '/'))) { continue }
            $adoptedEv++
        }
        if ($null -ne $b -and [string]$b.Value -eq '') { $added += $fp }
    }
}
$added = @($added | Sort-Object -Unique)
if ($adoptedEv -gt 0 -and -not $Quiet) {
    Write-Host ("  [MANIFEST] added 另按 generates 认领了 {0} 条别的步标签的写事件" -f $adoptedEv) -ForegroundColor Yellow
}

if (-not $Quiet) {
    $showDir = $diffDir.Replace($Root + '\', '')
    Write-Host ("  diff     {0} changed -> {1}" -f $changed, $showDir)
    if ($added.Count   -gt 0) { Write-Host ("           new:     {0}" -f ($added -join ', ')) }
    if ($deleted.Count -gt 0) { Write-Host ("           deleted: {0}" -f ($deleted -join ', ')) -ForegroundColor Yellow }
    if ($adopted) {
        Write-Host ("           (before 图从别步认领；无 before 图的新文件按 generates 认领)") -ForegroundColor DarkGray
    }
    elseif (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Write-Host ''
        Write-Host "  [WARN] no snapshot manifest for step $Step" -ForegroundColor Yellow
        Write-Host "         PreToolUse captured nothing. Either no file was edited," -ForegroundColor Yellow
        Write-Host "         or the hook did not run (check cwd and hook config)." -ForegroundColor Yellow
        Write-Host "         An empty diff here does NOT mean 'nothing changed'." -ForegroundColor Yellow
    }
    elseif ($changed -eq 0 -and $added.Count -eq 0 -and $deleted.Count -eq 0) {
        Write-Host "           (manifest exists but no differences)" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------- 2. verify
$verifyCmds = @()
$vp = $stage.PSObject.Properties['verify']
if ($null -ne $vp) {
    $verifyCmds = @($vp.Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$riskProp = $stage.PSObject.Properties['risk']
$risk = if ($null -ne $riskProp) { [string]$riskProp.Value } else { 'L1' }

$verifyExit = $null
# 给第 4 节（git 提交）用的两条事实：这次 verify 的判词与账本序号。
# 判词进 commit message，seq 让「账本 ↔ git」能互查——双轨没有这条索引就是负担。
$verdictOut = 'SKIP'
$verifySeq  = ''
if ($SkipVerify) {
    if (-not $Quiet) { Write-Host "  verify   skipped (-SkipVerify)" -ForegroundColor DarkGray }
}
elseif ($verifyCmds.Count -eq 0) {
    if (-not $Quiet) { Write-Host "  verify   (stage declares none)" -ForegroundColor DarkGray }
}
else {
    if (-not $Quiet) { foreach ($vc in $verifyCmds) { Write-Host "  verify   $vc" } }
    & (Join-Path $PSScriptRoot 'append-event.ps1') -Root $Root -Step $Step -Cmd $verifyCmds -Quiet
    $verifyExit = $LASTEXITCODE
    # append-event 的退出码分不出 VOID；只认 exit 就可能在"建立不了任何东西"的验证上
    # 照常关步骤、推进 current_step（2026-11-17：1.1 的 30 个用例被判 real_test=false →
    # verify 三态是 VOID，而这一步差点被关掉）。回读事件、按同一口径判。
    $vv = $null
    try {
        foreach ($e in (Read-EventLog -Path (Join-Path $Root 'events.jsonl'))) {
            if ([string]$e.event -eq 'verify' -and [string]$e.data.target -eq $Step) { $vv = $e }
        }
    } catch { }
    if ($null -ne $vv) {
        $dvx = 0; $dvt = $false; $dvr = $false
        $px = $vv.data.PSObject.Properties['exit'];      if ($null -ne $px) { $dvx = [int]$px.Value }
        $pt = $vv.data.PSObject.Properties['trivial'];   if ($null -ne $pt) { $dvt = [bool]$pt.Value }
        $pr = $vv.data.PSObject.Properties['real_test']; if ($null -ne $pr) { $dvr = [bool]$pr.Value }
        $verdict = if ($dvx -ne 0) { 'FAIL' } elseif ($dvt -or -not $dvr) { 'VOID' } else { 'PASS' }
        $verdictOut = $verdict
        $sq = $vv.PSObject.Properties['seq']
        if ($null -ne $sq) { $verifySeq = [string]$sq.Value }
        if ($verdict -ne 'PASS') {
            Write-Host ''
            Write-Host ("  [REFUSED] verify verdict = {0} - this step cannot be closed" -f $verdict) -ForegroundColor Red
            Write-Host ("            exit={0} trivial={1} real_test={2}" -f $dvx, $dvt, $dvr) -ForegroundColor Yellow
            if ($verdict -eq 'VOID') {
                Write-Host '            VOID 的意思是"这条命令无法因为本项目的缺陷而失败"。' -ForegroundColor Yellow
                Write-Host '            处置：把 stage 的 verify 换成真跑用例的命令（test 运行器 / 断言脚本），' -ForegroundColor Yellow
                Write-Host '            用 stage-edit.ps1 -Step <id> -Verify "..." 改（免签）。' -ForegroundColor Yellow
            }
            Write-Host ''
            exit 3
        }
    }
    if (-not $Quiet) {
        $colour = if ($verifyExit -eq 0) { 'Green' } else { 'Red' }
        Write-Host ("           exit={0}" -f $verifyExit) -ForegroundColor $colour
    }
}

# ---------------------------------------------------------------- 3. status + step sync
# -SyncStep is NOT optional here. The PostToolUse hook stamps every event with
# local.json's current_step; if nothing ever advances that value, all later work
# is filed against the stage we just finished (observed: 50 of 54 events
# attached to 2.0.1 while the project had moved on). A ledger whose stage column
# is wrong is not a weaker ledger - it is a misleading one, and every downstream
# rule that keys on `step` inherits the error.
#
# project_sha256 is deliberately NOT resynced here. Silently accepting a new
# baseline would let a weakened verify command become "the new normal" with
# nobody noticing. That drift stays a warning, cleared by a human running
# validate-profile -SyncBaseline after actually reviewing the change.
# The step key every downstream rule joins on is written HERE and nowhere
# else - until now that write left no event at all, so the ledger filed work
# against stages that had already closed (O4-02; seq 117's anchor recorded the
# same pollution on 2.0.4->2.0.5). Read the old value, let SyncStep move it,
# then record the handover itself. JSON is built with ConvertTo-Json and passed
# as a FILE - the argv lesson from sign-gate applies to script writers too.
$beforeStep = ''
$localJsonPath = Join-Path $Root '.harness\local.json'
if (Test-Path -LiteralPath $localJsonPath -PathType Leaf) {
    try {
        $lj = Get-Content -LiteralPath $localJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $beforeStep = [string]$lj.PSObject.Properties['current_step'].Value
    } catch { }
}
& (Join-Path $PSScriptRoot 'status.ps1') -Root $Root -SyncStep -Quiet:$Quiet
$afterStep = ''
if (Test-Path -LiteralPath $localJsonPath -PathType Leaf) {
    try {
        $lj2 = Get-Content -LiteralPath $localJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $afterStep = [string]$lj2.PSObject.Properties['current_step'].Value
    } catch { }
}
if ($afterStep -ne '' -and $afterStep -ne $beforeStep) {
    $advTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-stepadv-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    try {
        $advJson = ConvertTo-Json -InputObject ([ordered]@{ from = $beforeStep; to = $afterStep; closed_by = $Step }) -Compress
        [System.IO.File]::WriteAllText($advTmp, $advJson, (New-Object System.Text.UTF8Encoding($false)))
        & (Join-Path $PSScriptRoot 'append-event.ps1') -Root $Root -Event step_advance -Step $afterStep -DataJsonFile $advTmp -Quiet
    }
    finally {
        Remove-Item -LiteralPath $advTmp -Force -ErrorAction SilentlyContinue
    }
}

# 删除也是决定（2026-11-25）：这一步删掉了哪些文件，落进账本。
# 有了这条记录，被删掉的 generates 就不再是"缺文件"的疑似漏产，而是"后续步骤的决定"——
# status 拿它当 supersede 锚点。没有它，2.0.40 删掉 2.0.18 的 os_runner 只能显示成缺失。
if ($deleted.Count -gt 0) {
    $ownerOf = @{}
    foreach ($st in @($profile.stages)) {
        foreach ($g in @($st.generates)) { $ownerOf[([string]$g).Replace('\', '/')] = [string]$st.id }
    }
    foreach ($rel in $deleted) {
        $relN = ([string]$rel).Replace('\', '/')
        $own = if ($ownerOf.ContainsKey($relN)) { $ownerOf[$relN] } else { '' }
        $delTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-del-{0}.json" -f ([guid]::NewGuid().ToString('N')))
        try {
            $dJson = ConvertTo-Json -InputObject ([ordered]@{ file = $relN; owner = $own }) -Compress
            [System.IO.File]::WriteAllText($delTmp, $dJson, (New-Object System.Text.UTF8Encoding($false)))
            & (Join-Path $PSScriptRoot 'append-event.ps1') -Root $Root -Event file_removed -Step $Step -DataJsonFile $delTmp -Quiet
        }
        catch {
            Write-Host ("  [warn] file_removed 记录失败（{0}）: {1}" -f $relN, $_.Exception.Message) -ForegroundColor Yellow
        }
        finally {
            Remove-Item -LiteralPath $delTmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------- 3B. 回读：账到底动没动
# 2026-11-25：2.0.17 之后 30 个步骤每一步都报成功，但 status 一直判 done 不往前走
# （契约里一条前向引用 + 一个被删掉的死阶段把 cursor 钉住）。没人关步时回头看一眼，
# 漏洞就活了 30 步。这里回读一次：关完必须真的变成 done，否则大声说清是哪一条挡的。
try {
    $sj2 = & (Join-Path $PSScriptRoot 'status.ps1') -Root $Root -Json 2>&1 | Out-String
    $so2 = $sj2 | ConvertFrom-Json
    $me = @($so2.artifacts | Where-Object { [string]$_.id -eq $Step }) | Select-Object -First 1
    if ($null -ne $me) {
        if ([string]$me.status -ne 'done') {
            Write-Host ''
            Write-Host ("  [MISMATCH] step {0} 已关，但 status 仍判 {1} - 账没往前走" -f $Step, $me.status) -ForegroundColor Red
            $miss = @($me.missing | Where-Object { $_ })
            if ($miss.Count -gt 0) { Write-Host ("             generates 缺: {0}" -f ($miss -join ', ')) -ForegroundColor Yellow }
            Write-Host '             下一个人看 status 会以为这步没做。修契约（stage-edit）或补 verify。' -ForegroundColor Yellow
        }
        elseif (-not $Quiet) {
            Write-Host ("  ledger   {0} = done（回读确认）" -f $Step) -ForegroundColor DarkGray
        }
    }
}
catch { }

# ---------------------------------------------------------------- 4. git（可选提交）
# 关步即提交：一个 step 一个 commit，message 带 ledger seq，让「账本 ↔ git」双向可查。
# 三条硬纪律（2026-11-19）：
#   1) 提交失败只 warn，不 abort —— finish-step 的职责是关步记账，不能被远端/git 状态绑住。
#   2) 身份用 worker（vibe-worker），不用操作者的 git 身份 —— 归属与凭据分离。
#   3) --no-verify：门在账本这边（verify 三态 + canary），不在 git hook 那边。
# message 写文件用 -F 传，不走 -m 参数：中文经 argv 会被代码页转坏。同 sign-gate 的 argv 教训。
if (-not $NoCommit) {
    $isRepo = $false
    try {
        $null = & git -C $Root rev-parse --is-inside-work-tree 2>&1
        $isRepo = ($LASTEXITCODE -eq 0)
    }
    catch { }
    if (-not $isRepo) {
        if (-not $Quiet) { Write-Host '  git      not a repository (skipped)' -ForegroundColor DarkGray }
    }
    else {
        # 保护（2026-11-19）：profiles/ 是浏览器持久 profile（cookie / Login Data，本项目实测
        # 192MB）。若它没被 .gitignore 覆盖，`add -A` 会把它永久写进仓库历史 —— 那时再删也删不干净。
        # 宁可不提交（warn），也不把登录数据推上公司 GitLab。
        $profilesOk = $true
        if (Test-Path -LiteralPath (Join-Path $Root 'profiles')) {
            $null = & git -C $Root check-ignore -q 'profiles/' 2>&1
            $profilesOk = ($LASTEXITCODE -eq 0)
        }
        if (-not $profilesOk) {
            Write-Host '  [warn] profiles/ 未被 .gitignore 覆盖 - 跳过提交（先补：profiles/ config.toml .env）' -ForegroundColor Yellow
        }
        else {
        $short = [string]$stage.goal
        $cut = $short.IndexOfAny([char[]]@([char]0xFF08, [char]0xFF1A))
        if ($cut -gt 0) { $short = $short.Substring(0, $cut) }
        if ($short.Length -gt 28) { $short = $short.Substring(0, 28) + '…' }
        $seqTxt = if ($verifySeq) { $verifySeq } else { '-' }
        $msg = 'step {0} · seq {1} · {2} · {3}' -f $Step, $seqTxt, $verdictOut, $short
        $msgFile = Join-Path $Root ('.harness\local\commitmsg-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path $msgFile -Parent) | Out-Null
            [System.IO.File]::WriteAllText($msgFile, $msg + "`n", (New-Object System.Text.UTF8Encoding($false)))
            $null = & git -C $Root add -A 2>&1
            $staged = @(& git -C $Root status --porcelain 2>&1 | Where-Object { $_ -and ([string]$_).Trim() -ne '' })
            if ($staged.Count -eq 0) {
                if (-not $Quiet) { Write-Host '  git      nothing to commit' -ForegroundColor DarkGray }
            }
            else {
                $out = & git -C $Root -c user.name=vibe-worker -c user.email=worker@vibe.local commit --no-verify -F $msgFile 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $head = (& git -C $Root rev-parse --short HEAD 2>&1 | Select-Object -First 1)
                    if (-not $Quiet) { Write-Host ("  git      committed {0}  {1}" -f $head, $msg) -ForegroundColor DarkGray }
                }
                else {
                    $first = (@($out | Out-String) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                    Write-Host ("  [warn] git commit failed (step 仍已关闭): {0}" -f $first) -ForegroundColor Yellow
                }
            }
        }
        catch {
            Write-Host ("  [warn] git commit threw (step 仍已关闭): {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
        finally {
            Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
        }
        }
    }
}

if ($null -ne $verifyExit -and $verifyExit -ne 0) { exit 1 }
exit 0
