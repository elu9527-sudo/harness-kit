# PreToolUse · 第二级判定：本地白名单先放，其余交给 decision 模型判。
#
# 位置说明：这一级占的就是 Claude Code 内置判定器的位置（auto 模式那颗脑子）。
# 内置那个换不了——它固定用"强制工具调用"问模型，而本机网关在 thinking 模式下
# 拒绝那种调用（实测 400），所以 auto 永远 "temporarily unavailable"。摘掉 auto
# （defaultMode=default），把 decision-model-preview 放进这一格：它专门做结构化
# 判定，回 allow/ask/deny + 概率 + 置信度，比内置的是/否更可解释。
#
# 分工（与 guard.ps1）：
#   guard.ps1           只挡不可逆：现实破坏 + 伪造证据（写 events.jsonl）
#   decision-guard.ps1  判"可逆但要不要问"：项目内未知命令、治理面写入
#
# 输出约定：exit 0 放行；exit 2 阻断（stderr 说明原因与解法）。
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 输出：直接给权限判定
# Claude Code 的 PreToolUse hook 支持回一个 JSON 决定（查过本机 CLI，字段确实存在：
# hookSpecificOutput.permissionDecision / permissionDecisionReason）。所以判定做完就
# 直接回"放行/拦/问"，不必再让权限层逐条问人——这就是"把 decision 放在 auto 的位置"
# 的真正落法：同一个座位，换一个更会判的脑子，而且不依赖那个坏掉的内置分类器。
function EmitDecision {
    param([string] $decision, [string] $reason)
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "decision-guard: $decision" }
    $obj = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = $decision; permissionDecisionReason = $reason } }
    Write-Output ($obj | ConvertTo-Json -Depth 5 -Compress)
    # 非放行的判定同时写 stderr：屏幕上看得到原因，canary 也能断言。
    if ($decision -ne 'allow') { [Console]::Error.WriteLine("[decision-guard] $reason") }
    exit 0
}
function Allow { param([string] $why) EmitDecision 'allow' $(if ($why) { $why } else { 'local allow-list' }) }
function Block { param([string] $msg) EmitDecision 'deny' $msg }

$raw = ''
try { $raw = [Console]::In.ReadToEnd() } catch { Allow }
if ([string]::IsNullOrWhiteSpace($raw)) { Allow }
try { $in = $raw | ConvertFrom-Json } catch { Allow }

$tool = [string]$in.tool_name
if ([string]::IsNullOrWhiteSpace($tool)) { Allow }
$ti = $in.tool_input
if ($null -eq $ti) { $ti = [pscustomobject]@{} }

# ---------------------------------------------------------------- 取路径（写工具）
$fp = ''
foreach ($k in @('file_path', 'notebook_path', 'path', 'filePath')) {
    if ($ti.PSObject.Properties[$k] -and -not [string]::IsNullOrWhiteSpace([string]$ti.$k)) { $fp = [string]$ti.$k; break }
}
$isWrite = $tool -in @('Write', 'Edit', 'MultiEdit', 'NotebookEdit') -or $tool -like 'mcp__*'

# ---------------------------------------------------------------- 本地白名单（零网络）
if ($isWrite) {
    # .harness/local 是机器本地状态（快照、报告、pending），不是治理面。
    if ($fp -match '\.harness[\\/]local[\\/]') { Allow }
    # 业务文件：不判（guard 已挡账本；记账由 post hook 完成）。
    if ($fp -notmatch '\.harness[\\/](derive|contracts|PROMPT|state\.json|project\.json|rules)') { Allow }
}

if ($tool -eq 'Bash') {
    $cmd = [string]$ti.command
    if ([string]::IsNullOrWhiteSpace($cmd)) { Allow }
    # 只读/查询/跑测试/项目脚本：直接放，零延迟。这类占绝大多数。
    $fast = @(
        '^\s*(ls|dir|pwd|cd|type|cat|head|tail|more|wc)\b',
        '^\s*(Get-Content|Get-ChildItem|Get-Item|Test-Path|Select-String|Measure-Object|Resolve-Path)\b',
        '^\s*(rg|grep|findstr|where)\b',
        '^\s*git\s+(status|diff|log|show|branch|remote|rev-parse)\b',
        '^\s*(node|python)\s+(--version|-v)\b',
        '^\s*(node\s+--test|python\s+scripts[\\/]check\.py)\b',
        '^\s*pwsh\s+(-NoProfile\s+)?-File\s+\.harness[\\/]derive[\\/]'
    )
    foreach ($p in $fast) { if ($cmd -match $p) { Allow } }
}

# ---------------------------------------------------------------- 模型判定
$endpoint = if ($env:DECISION_ENDPOINT) { $env:DECISION_ENDPOINT } else { 'https://api.example.com/compatible-mode/v1/systemone' }
$model = if ($env:DECISION_MODEL) { $env:DECISION_MODEL } else { 'decision-model-preview' }
$key = $env:DECISION_API_KEY
if ([string]::IsNullOrWhiteSpace($key)) { $key = 'sk-ws-H.YLLMYMM.Si7r.MEUCIA_krvhA5PdlXeSFPAnytnsDD_b2ZU42CL-WEctjA3LEAiEAm4R32pXIy_-tbBb8GSkG5p0kvXA4yNdcQghde6ML4AY' }

$step = 'unknown'
try {
    $lj = Join-Path ([string]$in.cwd) '.harness\local.json'
    if (Test-Path -LiteralPath $lj) { $step = [string](Get-Content -LiteralPath $lj -Raw | ConvertFrom-Json).current_step }
} catch { }

if ($isWrite) {
    $state = "动作: 写文件`n目标: $fp`n当前 step: $step`n项目: 开发流程的治理面是 .harness/derive|contracts|PROMPT|state.json|project.json|rules（只有维护者改），业务文件由编码 agent 改且会自动记账。"
    $instructions = '这次写入应该被怎样处理'
    $criteria = @{
        allow = '给业务文件补内容、写测试、写文档、或在 .harness/local 写快照与报告'
        ask   = '改治理面但属于合理维护：修派发脚本、更新提示词、改契约内容'
        deny  = '改账本 events.jsonl、伪造验证记录、把验收门槛调松、删掉防呆逻辑'
    }
} else {
    $state = "命令: $([string]$ti.command)`n工作目录: $([string]$in.cwd)`n当前 step: $step`n项目: 用账本记录每步产出的开发流程；不可逆命令与账本写入已由本地规则先行拦截。"
    $instructions = '这条 shell 命令现在应该被怎样处理'
    $criteria = @{
        allow = '只读查询、跑测试、版本检查、或在项目内生成/修改业务文件，安全且与当前 step 相关'
        ask   = '可能安全但影响范围不清：装依赖、联网下载、批量改文件、动 git 历史'
        deny  = '破坏性删除、格式化、关机、杀进程、直接写账本、改 .harness 治理面'
    }
}

$payload = @{
    model     = $model
    state     = $state
    questions = @{ act = @{ type = 'choice'; instructions = $instructions; criteria = $criteria } }
} | ConvertTo-Json -Depth 8 -Compress

function Fail-Open {
    param([string] $why)
    # 模型不可用时不放行也不卡死：回 ask，让人看一眼。
    # （早先版本是直接放行；现在既然能回 ask，就别把不确定悄悄当成安全。）
    EmitDecision 'ask' ("decision model unavailable ($why) - needs your call: $($fp)$([string]$ti.command)")
}

$resp = $null
try {
    $r = Invoke-RestMethod -Uri $endpoint -Method Post -TimeoutSec 12 -Body $payload `
        -Headers @{ 'Authorization' = "Bearer $key"; 'content-type' = 'application/json' }
    $resp = $r.answers.act
} catch { Fail-Open $_.Exception.Message }

if ($null -eq $resp) { Fail-Open 'no answer' }
$choice = [string]$resp.choice
$conf = [double]$resp.confidence
$what = if ($isWrite) { $fp } else { [string]$ti.command }

switch ($choice) {
    'allow' { EmitDecision 'allow' ("decision-model: allow (conf {0:N2})" -f $conf) }
    'deny'  { EmitDecision 'deny'  ("decision-model: deny (conf {0:N2}) - {1}" -f $conf, $what) }
    'ask'   {
        EmitDecision 'ask' ("decision-model: ask (conf {0:N2}) - needs your call: {1}`n  -> if it is fine, add a rule to .claude\settings.json permissions.allow" -f $conf, $what)
    }
    default { Fail-Open "unknown choice '$choice'" }
}