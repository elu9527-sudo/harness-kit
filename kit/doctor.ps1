<#
.SYNOPSIS
  便携包的"能开箱用吗"体检器。判词沿用账本那套三态。
.DESCRIPTION
  装得上 != 跑得动 != 用得上。doctor 只回答第三件事：这台机器现在还差什么。
  判词与 verify 同一口径：
    PASS  确实可用（跑出来的版本/内容，不是"文件存在"）
    VOID  装了但证明不了什么（Windows Store 的假 python、空 token、能起不能跑）
    FAIL  缺了，且会挡住下一步
  退出码：0 = 无 FAIL；2 = 有 FAIL（装不完整，别往下走）。

  为什么不自动装运行时：pwsh/python/node 的安装方式各机器不同，自动装是最容易
  把别人的环境搞坏的一步。doctor 只负责说清楚，装是人的决定。
.PARAMETER ProjectRoot
  可选。给了就顺带体检项目侧（.harness\project.json、events.jsonl、git）。
.EXAMPLE
  pwsh -File doctor.ps1
  pwsh -File doctor.ps1 -ProjectRoot "D:\my\project"
#>
[CmdletBinding()]
param(
    [string] $ProjectRoot = '',
    [string] $ClaudeHome = $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.claude' } else { '' }),
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row {
    param([string]$Name, [string]$Verdict, [string]$Detail)
    $rows.Add([pscustomobject]@{ name = $Name; verdict = $Verdict; detail = $Detail })
}

function Get-CmdVersion {
    param([string]$Exe, [string]$ArgList)
    try {
        $out = & $Exe $ArgList 2>&1 | Out-String
        return @{ ok = ($LASTEXITCODE -eq 0); text = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1) }
    }
    catch { return @{ ok = $false; text = $_.Exception.Message } }
}

# ---------------------------------------------------------------- pwsh
$pv = $PSVersionTable.PSVersion
$clr = [System.Environment]::Version
if ($pv.Major -lt 7) {
    Add-Row 'pwsh' 'FAIL' ("{0} — 需要 7.x（本套脚本用了 PS7 语法，5.1 会语法错）" -f $pv)
}
elseif ($pv.Major -eq 7 -and $pv.Minor -lt 4) {
    Add-Row 'pwsh' 'VOID' ("{0} — 能跑但没在 7.4 LTS 上验证过" -f $pv)
}
elseif ($clr.Major -ge 10) {
    # 2026-11-19 实测：PowerShell 7.6 preview 是 .NET 10 构建，在 Win10 19045 上
    # 起进程即 "Fatal error. Your Windows doesn't fully support CET"，所有 hook 全灭。
    Add-Row 'pwsh' 'VOID' ("{0} / .NET {1} — .NET 10 构建在旧版 Win10 上会 CET fatal，建议换 7.4 LTS" -f $pv, $clr)
}
else {
    Add-Row 'pwsh' 'PASS' ("{0} / .NET {1}" -f $pv, $clr)
}

# ---------------------------------------------------------------- 运行时
$py = Get-CmdVersion 'python' '--version'
if (-not $py.ok) { Add-Row 'python' 'FAIL' 'python 不在 PATH（verify 的判据依赖它）' }
elseif ($py.text -match 'was not found|Store|Microsoft') {
    Add-Row 'python' 'VOID' ("{0} — 疑似 Windows Store 别名，真跑会失败" -f $py.text)
}
else { Add-Row 'python' 'PASS' $py.text }

$nd = Get-CmdVersion 'node' '--version'
if (-not $nd.ok) { Add-Row 'node' 'FAIL' 'node 不在 PATH（extension/ 侧测试依赖它）' }
else { Add-Row 'node' 'PASS' $nd.text }

$gt = Get-CmdVersion 'git' '--version'
if (-not $gt.ok) { Add-Row 'git' 'FAIL' 'git 不在 PATH（关步自动提交、diff 依赖它）' }
else { Add-Row 'git' 'PASS' $gt.text }

# ---------------------------------------------------------------- Claude 侧
if (-not $ClaudeHome -or -not (Test-Path -LiteralPath $ClaudeHome)) {
    Add-Row 'claude-home' 'FAIL' ("{0} 不存在 — 先装 Claude Code，再跑 setup.ps1" -f $ClaudeHome)
}
else {
    Add-Row 'claude-home' 'PASS' $ClaudeHome
    $settingsPath = Join-Path $ClaudeHome 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        Add-Row 'claude-settings' 'FAIL' 'settings.json 不存在（env/hooks 都还没写）'
    }
    else {
        $sj = $null
        try { $sj = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if ($null -eq $sj) { Add-Row 'claude-settings' 'FAIL' 'settings.json 不是合法 JSON' }
        else {
            Add-Row 'claude-settings' 'PASS' '合法 JSON'
            # 凭据：只判"有没有"，绝不打印值
            $tok = ''
            if ($null -ne $sj.PSObject.Properties['env']) {
                $tp = $sj.env.PSObject.Properties['ANTHROPIC_AUTH_TOKEN']
                if ($null -ne $tp) { $tok = [string]$tp.Value }
            }
            if (-not $tok -and $env:ANTHROPIC_AUTH_TOKEN) { $tok = $env:ANTHROPIC_AUTH_TOKEN }
            if (-not $tok) { Add-Row 'auth' 'FAIL' 'ANTHROPIC_AUTH_TOKEN 未配置（用 setup.ps1 -AuthToken 或设环境变量）' }
            elseif ($tok.Length -lt 20) { Add-Row 'auth' 'VOID' ("token 只有 {0} 字符，像是占位符" -f $tok.Length) }
            else { Add-Row 'auth' 'PASS' ("已配置（{0}…{1}）" -f $tok.Substring(0, 6), $tok.Substring($tok.Length - 4)) }

            # hooks：数两相，缺一边就代表"只记不改"或"只改不记"
            $preN = 0; $postN = 0
            if ($null -ne $sj.PSObject.Properties['hooks']) {
                if ($null -ne $sj.hooks.PSObject.Properties['PreToolUse']) { $preN = @($sj.hooks.PreToolUse).Count }
                if ($null -ne $sj.hooks.PSObject.Properties['PostToolUse']) { $postN = @($sj.hooks.PostToolUse).Count }
            }
            if ($preN -eq 0 -and $postN -eq 0) { Add-Row 'hooks' 'FAIL' 'PreToolUse/PostToolUse 都没注册 — 写入不会被记账' }
            elseif ($preN -eq 0 -or $postN -eq 0) { Add-Row 'hooks' 'FAIL' ("Pre={0} Post={1} — 只有一半，before 图或落账会缺" -f $preN, $postN) }
            else { Add-Row 'hooks' 'PASS' ("Pre={0} Post={1}" -f $preN, $postN) }

            # 绝对路径写死的 hook 会在换机后静默失效。
            # 注意：不能拿原始 JSON 文本去比 $ClaudeHome —— 里面的反斜杠是双写的
            # （C:\\Users\\...），直接比必然假阳性。从解析后的对象里取命令再比。
            $cmds = @()
            $hk = $sj.PSObject.Properties['hooks']
            if ($null -ne $hk) {
                foreach ($ph in @('PreToolUse', 'PostToolUse')) {
                    $hp = $hk.Value.PSObject.Properties[$ph]
                    if ($null -eq $hp) { continue }
                    foreach ($grp in @($hp.Value)) {
                        $gp2 = $grp.PSObject.Properties['hooks']
                        if ($null -eq $gp2) { continue }
                        foreach ($h in @($gp2.Value)) {
                            $cp = $h.PSObject.Properties['command']
                            if ($null -ne $cp) { $cmds += [string]$cp.Value }
                        }
                    }
                }
            }
            if ($cmds.Count -gt 0) {
                $foreign = @()
                foreach ($c in $cmds) {
                    $m = [regex]::Match($c, '[A-Za-z]:\\[^"'']+')
                    if ($m.Success -and -not $m.Value.StartsWith($ClaudeHome, [System.StringComparison]::OrdinalIgnoreCase)) { $foreign += $c }
                }
                if ($foreign.Count -gt 0) { Add-Row 'hooks-path' 'VOID' ("{0}/{1} 条 hook 指向别的目录（换机会静默失效）" -f $foreign.Count, $cmds.Count) }
                else { Add-Row 'hooks-path' 'PASS' ("{0} 条 hook 全在本机 .claude 下" -f $cmds.Count) }
            }
        }
    }

    $cm = Join-Path $ClaudeHome 'CLAUDE.md'
    if (Test-Path -LiteralPath $cm) {
        $len = (Get-Item -LiteralPath $cm).Length
        if ($len -lt 500) { Add-Row 'persona' 'VOID' ("CLAUDE.md 只有 {0}B，像空壳" -f $len) }
        else { Add-Row 'persona' 'PASS' ("CLAUDE.md {0}B" -f $len) }
    }
    else { Add-Row 'persona' 'FAIL' 'CLAUDE.md 不存在（编码人格没装）' }
}

# ---------------------------------------------------------------- kit 自身
$maniPath = Join-Path $PSScriptRoot 'MANIFEST.json'
if (-not (Test-Path -LiteralPath $maniPath)) { Add-Row 'kit-manifest' 'FAIL' 'MANIFEST.json 缺失（这份便携包不完整）' }
else {
    $mani = Get-Content -LiteralPath $maniPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $bad = 0; $missing = 0
    foreach ($f in @($mani.files)) {
        $p = Join-Path $PSScriptRoot ([string]$f.path)
        if (-not (Test-Path -LiteralPath $p)) { $missing++; continue }
        $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
        if ($h -ne [string]$f.sha256) { $bad++ }
    }
    if ($missing -gt 0) { Add-Row 'kit-files' 'FAIL' ("{0} 个文件缺失" -f $missing) }
    elseif ($bad -gt 0) { Add-Row 'kit-files' 'VOID' ("{0} 个文件哈希不符（被改过或打包时损坏）" -f $bad) }
    else { Add-Row 'kit-files' 'PASS' ("{0} 个文件与清单一致" -f @($mani.files).Count) }
}

# ---------------------------------------------------------------- 项目侧（可选）
if ($ProjectRoot) {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) { Add-Row 'project' 'FAIL' ("{0} 不存在" -f $ProjectRoot) }
    else {
        $pj = Join-Path $ProjectRoot '.harness\project.json'
        if (-not (Test-Path -LiteralPath $pj)) { Add-Row 'project' 'FAIL' '.harness\project.json 不存在（先跑 install.ps1，再让教练出阶段草案）' }
        else { Add-Row 'project' 'PASS' 'project.json 存在' }
        $evp = Join-Path $ProjectRoot 'events.jsonl'
        if (-not (Test-Path -LiteralPath $evp)) { Add-Row 'ledger' 'FAIL' 'events.jsonl 不存在（账本没生成）' }
        else {
            $n = @(Get-Content -LiteralPath $evp -Encoding UTF8 | Where-Object { $_.Trim() }).Count
            if ($n -eq 0) { Add-Row 'ledger' 'VOID' 'events.jsonl 是空的（只有 genesis 之前的状态）' }
            else { Add-Row 'ledger' 'PASS' ("{0} 条事件" -f $n) }
        }
        $isRepo = $false
        try { $null = & git -C $ProjectRoot rev-parse --is-inside-work-tree 2>&1; $isRepo = ($LASTEXITCODE -eq 0) } catch { }
        if ($isRepo) {
            $gi = Join-Path $ProjectRoot '.gitignore'
            $proIgn = $true
            if ((Test-Path -LiteralPath (Join-Path $ProjectRoot 'profiles')) -and (Test-Path -LiteralPath $gi)) {
                $null = & git -C $ProjectRoot check-ignore -q 'profiles/' 2>&1
                $proIgn = ($LASTEXITCODE -eq 0)
            }
            elseif (Test-Path -LiteralPath (Join-Path $ProjectRoot 'profiles')) { $proIgn = $false }
            if ($proIgn) { Add-Row 'git-ignore' 'PASS' 'profiles/ 未被纳入版本控制' }
            else { Add-Row 'git-ignore' 'FAIL' 'profiles/ 未被 .gitignore 覆盖 — 提交会把浏览器 profile/登录态带进仓库' }
        }
        else { Add-Row 'git-repo' 'VOID' '不是 git 仓库（可选项；但 worktree 隔离不可用）' }
    }
}

# ---------------------------------------------------------------- 输出
if (-not $Quiet) {
    Write-Host ''
    Write-Host 'HARNESS DOCTOR' -ForegroundColor Cyan
    foreach ($r in $rows) {
        $c = switch ($r.verdict) { 'PASS' { 'Green' } 'VOID' { 'Yellow' } default { 'Red' } }
        Write-Host ("  [{0}] {1,-14} {2}" -f $r.verdict, $r.name, $r.detail) -ForegroundColor $c
    }
}
$fail = @($rows | Where-Object { $_.verdict -eq 'FAIL' })
$void = @($rows | Where-Object { $_.verdict -eq 'VOID' })
if (-not $Quiet) {
    Write-Host ''
    Write-Host ("verdict: {0} PASS / {1} VOID / {2} FAIL" -f (@($rows).Count - $fail.Count - $void.Count), $void.Count, $fail.Count)
    if ($fail.Count -gt 0) {
        Write-Host 'FAIL 未清零前不要往下走 —— 装了也跑不起来。' -ForegroundColor Red
    }
    else {
        Write-Host '无 FAIL。VOID 项是“装上了但证明不了什么”，自己判断要不要处理。' -ForegroundColor Green
    }
}
if ($fail.Count -gt 0) { exit 2 }
exit 0