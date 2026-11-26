<#
.SYNOPSIS
  便携包的机器级安装器：把 hooks / 人格 / settings 落到本机，再可选装一个项目。
.DESCRIPTION
  与 install.ps1 的分工：
    setup.ps1    机器级 —— Claude 侧的 hooks、settings.env、人格（CLAUDE.md）
    install.ps1  项目级 —— .harness/ 骨架、契约、账本、探针
  先 setup 再 install。setup 幂等：已存在的东西先备份再改，不静默覆盖别人的配置。

  凭据不进包：token 只从 -AuthToken 或已有环境读；包里任何文件都不含密钥。

.PARAMETER ProjectRoot
  可选。给了就在装完机器后顺手跑 install.ps1。
.EXAMPLE
  pwsh -File setup.ps1 -AuthToken sk-xxx
  pwsh -File setup.ps1 -AuthToken sk-xxx -ProjectRoot "D:\my\project"
  pwsh -File setup.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string] $AuthToken = '',
    [string] $AuthBaseUrl = 'https://token-plan.cn-beijing.maas.aliyuncs.com/apps/anthropic',
    [string] $Model = 'deepseek-v4.1-flash-1017',
    [string] $ClaudeHome = $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.claude' } else { '' }),
    [string] $ProjectRoot = '',
    [string] $HermesProfile = '',
    [switch] $Force,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$kit = $PSScriptRoot

function Say  { param([string]$m, [string]$c = 'Gray')    Write-Host $m -ForegroundColor $c }
function Ok   { param([string]$m)                          Say ("  ok    {0}" -f $m) 'Green' }
function Skip { param([string]$m)                          Say ("  skip  {0}" -f $m) 'DarkGray' }
function Warn { param([string]$m)                          Say ("  WARN  {0}" -f $m) 'Yellow' }

Say ''
Say 'HARNESS SETUP (machine side)' 'Cyan'
if ($DryRun) { Say '  [dry-run] 不会写任何文件' 'Yellow' }

# ---------------------------------------------------------------- 0. 前置体检
$doctor = Join-Path $kit 'doctor.ps1'
if (Test-Path -LiteralPath $doctor) {
    $out = & pwsh -NoProfile -File $doctor -ClaudeHome $ClaudeHome -Quiet 2>&1
    $dcode = $LASTEXITCODE
    if ($dcode -eq 2) {
        Say ''
        Say '前置体检有 FAIL —— 先解决再装，否则装了也跑不起来：' 'Red'
        pwsh -NoProfile -File $doctor -ClaudeHome $ClaudeHome 2>&1 | Select-String 'FAIL|VOID' | ForEach-Object { Say ("  " + $_.Line.Trim()) 'Red' }
        exit 2
    }
    Ok '前置体检无 FAIL'
}

if (-not $ClaudeHome -or -not (Test-Path -LiteralPath $ClaudeHome)) {
    Say ("[FAIL] Claude home 不存在：{0} —— 先装 Claude Code" -f $ClaudeHome) 'Red'
    exit 2
}

# ---------------------------------------------------------------- 1. hooks
$srcHooks = Join-Path $kit 'hooks'
$dstHooks = Join-Path $ClaudeHome 'hooks\harness'
if (-not (Test-Path -LiteralPath $srcHooks)) { Say '[FAIL] 便携包里没有 hooks/' 'Red'; exit 2 }
if ($DryRun) { Say ("  would copy hooks -> {0}" -f $dstHooks) 'Yellow' }
else {
    New-Item -ItemType Directory -Force -Path $dstHooks | Out-Null
    Get-ChildItem -LiteralPath $srcHooks -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dstHooks -Force }
    Ok ("hooks -> {0} ({1} 个文件)" -f $dstHooks, @(Get-ChildItem -LiteralPath $dstHooks -File).Count)
}

# ---------------------------------------------------------------- 2. settings.json
$settingsPath = Join-Path $ClaudeHome 'settings.json'
$exists = Test-Path -LiteralPath $settingsPath
$sj = if ($exists) { Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
if ($exists) {
    if ($DryRun) { Say '  would merge settings.json (backup first)' 'Yellow' }
    else { Copy-Item -LiteralPath $settingsPath -Destination ("{0}.bak-{1}" -f $settingsPath, $ts) -Force; Ok ("settings.json 已备份 .bak-{0}" -f $ts) }
}

# env：只在缺的时候写，不覆盖别人已有的（-Force 才覆盖）
$envObj = [ordered]@{}
$ep = $sj.PSObject.Properties['env']
if ($null -ne $ep -and $null -ne $ep.Value) {
    foreach ($p in $ep.Value.PSObject.Properties) { $envObj[$p.Name] = $p.Value }
}
$tokNow = if ($AuthToken) { $AuthToken } elseif ($envObj.Contains('ANTHROPIC_AUTH_TOKEN')) { [string]$envObj['ANTHROPIC_AUTH_TOKEN'] } elseif ($env:ANTHROPIC_AUTH_TOKEN) { $env:ANTHROPIC_AUTH_TOKEN } else { '' }
if (-not $tokNow) {
    Say '[FAIL] 没有 token：用 -AuthToken 传，或先设 $env:ANTHROPIC_AUTH_TOKEN' 'Red'
    Say '       便携包里故意不含密钥 —— 密钥永远是安装那一刻由人给。' 'Yellow'
    exit 2
}
$envObj['ANTHROPIC_AUTH_TOKEN'] = $tokNow
if (-not $envObj.Contains('ANTHROPIC_BASE_URL') -or $Force)   { $envObj['ANTHROPIC_BASE_URL'] = $AuthBaseUrl }
foreach ($k in @('ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL')) {
    if (-not $envObj.Contains($k) -or $Force) { $envObj[$k] = $Model }
}
Ok ("env: token {0}…{1}, model {2}" -f $tokNow.Substring(0, [Math]::Min(6, $tokNow.Length)), $tokNow.Substring([Math]::Max(0, $tokNow.Length - 4)), $envObj['ANTHROPIC_MODEL'])

# hooks：四条命令全部指向本机 $ClaudeHome（换机靠 setup 重算，不靠手改）
$hookCmds = @(
    @{ matcher = 'Write|Edit|MultiEdit|NotebookEdit|Bash|mcp__.*'; phase = 'PreToolUse'; cmd = @(
            ('pwsh -NoProfile -File "{0}\guard.ps1"' -f $dstHooks),
            ('pwsh -NoProfile -File "{0}\decision-guard.ps1"' -f $dstHooks),
            ('node "{0}\pre-tool.mjs"' -f $dstHooks)
        ) }
    @{ matcher = 'Write|Edit|MultiEdit|NotebookEdit|Bash|mcp__.*'; phase = 'PostToolUse'; cmd = @(
            ('node "{0}\post-tool.mjs"' -f $dstHooks)
        ) }
)
$hooksObj = [ordered]@{}
foreach ($h in $hookCmds) {
    $hooksObj[$h.phase] = @([ordered]@{
            matcher = $h.matcher
            hooks   = @($h.cmd | ForEach-Object { [ordered]@{ type = 'command'; command = $_ } })
        })
}
Ok ("hooks: Pre={0} Post={1}（全部指向本机 .claude）" -f @($hooksObj['PreToolUse']).Count, @($hooksObj['PostToolUse']).Count)

# permissions：只补两条，别把别人的 allow/deny 抹掉
$permObj = [ordered]@{}
$pp = $sj.PSObject.Properties['permissions']
if ($null -ne $pp -and $null -ne $pp.Value) {
    foreach ($p in $pp.Value.PSObject.Properties) { $permObj[$p.Name] = $p.Value }
}
$allow = @()
if ($permObj.Contains('allow')) { $allow = @($permObj['allow']) }
foreach ($rule in @('Bash(wsl:*)', 'Bash(wsl.exe:*)')) {
    if ($allow -notcontains $rule) { $allow += $rule }
}
$permObj['allow'] = $allow

$out = [ordered]@{}
foreach ($k in @($sj.PSObject.Properties.Name)) { if ($k -notin @('env', 'hooks', 'permissions')) { $out[$k] = $sj.$k } }
$out['env'] = $envObj
$out['hooks'] = $hooksObj
$out['permissions'] = $permObj
$json = $out | ConvertTo-Json -Depth 12

if ($DryRun) { Say ("  would write settings.json ({0} bytes)" -f $json.Length) 'Yellow' }
else {
    [System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Ok ("settings.json 已写（{0} bytes）" -f $json.Length)
}

# ---------------------------------------------------------------- 3. 人格
$personaSrc = Join-Path $kit 'prompts\coding.md'
$personaDst = Join-Path $ClaudeHome 'CLAUDE.md'
if (-not (Test-Path -LiteralPath $personaSrc)) { Warn 'prompts\coding.md 缺失，跳过人格安装' }
elseif ((Test-Path -LiteralPath $personaDst) -and -not $Force) {
    Warn 'CLAUDE.md 已存在，保留原样（要换成包里的用 -Force；两份合并需人工）'
}
elseif ($DryRun) { Say ("  would write {0}" -f $personaDst) 'Yellow' }
else {
    if (Test-Path -LiteralPath $personaDst) { Copy-Item -LiteralPath $personaDst -Destination ("{0}.bak-{1}" -f $personaDst, $ts) -Force }
    Copy-Item -LiteralPath $personaSrc -Destination $personaDst -Force
    Ok ("人格 -> {0}" -f $personaDst)
}

# ---------------------------------------------------------------- 4. Hermes（可选）
if ($HermesProfile) {
    $hs = Join-Path $kit 'prompts\coach.md'
    $hd = Join-Path $HermesProfile 'SOUL.md'
    if (-not (Test-Path -LiteralPath $HermesProfile)) { Warn ("Hermes profile 不存在：{0}（自己装好 Hermes 再接）" -f $HermesProfile) }
    elseif ((Test-Path -LiteralPath $hd) -and -not $Force) { Warn 'SOUL.md 已存在，保留原样（-Force 才覆盖）' }
    elseif ($DryRun) { Say ("  would write {0}" -f $hd) 'Yellow' }
    else {
        if (Test-Path -LiteralPath $hd) { Copy-Item -LiteralPath $hd -Destination ("{0}.bak-{1}" -f $hd, $ts) -Force }
        Copy-Item -LiteralPath $hs -Destination $hd -Force
        Ok ("教练人格 -> {0}" -f $hd)
        Warn 'Hermes 的运行时态（state.db / checkpoints / sessions / vault）不随包走 —— 那是各人的会话历史'
    }
}

# ---------------------------------------------------------------- 5. 项目（可选）
if ($ProjectRoot) {
    $installer = Join-Path $kit 'install.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { Warn 'install.ps1 缺失，跳过项目安装' }
    elseif ($DryRun) { Say ("  would run install.ps1 -ProjectRoot {0}" -f $ProjectRoot) 'Yellow' }
    else {
        & pwsh -NoProfile -File $installer -ProjectRoot $ProjectRoot
        if ($LASTEXITCODE -ne 0) { Say ("[FAIL] install.ps1 退出 {0}" -f $LASTEXITCODE) 'Red'; exit 1 }
        Ok '项目骨架已装'
    }
}

# ---------------------------------------------------------------- 6. 收尾体检
Say ''
if (-not $DryRun) {
    & pwsh -NoProfile -File $doctor -ClaudeHome $ClaudeHome -ProjectRoot $ProjectRoot
    if ($LASTEXITCODE -eq 2) { Say ''; Say '装完了但 doctor 仍有 FAIL —— 按上面逐条处理。' 'Red'; exit 2 }
}
Say ''
Say 'next:' 'Yellow'
Say '  1) 重启 Claude Code（env/hooks 只在新会话生效）'
Say '  2) 没有项目就：pwsh -File install.ps1 -ProjectRoot <路径>'
Say '  3) 然后让教练出阶段草案：stage-add.ps1 -Paste'
exit 0