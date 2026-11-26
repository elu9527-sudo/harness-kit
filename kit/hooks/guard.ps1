# PreToolUse · 第一级：只挡"不可逆"的两类，其余交给 decision-guard 判。
#
# 为什么收窄（2026-11-17 改）：原来把"改治理面"和"任何 Remove-Item -Recurse -Force"
# 都硬挡，结果 agent 清理自己产生的临时目录也被拒——挡得比需要更死，而真正需要
# 硬挡的只有"判错了没有第二次"的动作。按这个标准留两类：
#
#   1) 现实世界的不可逆破坏：format / shutdown / taskkill / del /s / 项目外递归删除
#   2) 伪造证据：任何对 events.jsonl、checkpoint.history 的写
#      —— 账本是事实源，一旦能被悄悄改写，之后所有推断都不可信，无法回滚。
#
# 其余（改 derive/contracts/PROMPT/project.json 等"项目内可逆但越权"的动作）下放给
# decision-guard：让它判 allow/ask/deny。那些动作判错可以改回来，C7 也会抓到 hash 变化。
#
# 已知限制，写在这里免得被当成万无一失：本文件是字符串匹配，`rm -r -f`、变量拼接、
# 脚本包装都能绕过。它防手滑，不防蓄意。真正的防线是环境层（无管理员权限、不可逆
# 动作有备份、盘根不可写）。
$ErrorActionPreference = 'Stop'
try { $in = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }
$tool = [string]$in.tool_name
if ([string]::IsNullOrWhiteSpace($tool)) { exit 0 }
$ti = $in.tool_input
if ($null -eq $ti) { $ti = [pscustomobject]@{} }
function Block([string]$msg) { [Console]::Error.WriteLine("[guard] $msg"); exit 2 }

$cwd = [string]$in.cwd
if ([string]::IsNullOrWhiteSpace($cwd)) { $cwd = (Get-Location).Path }

# 项目内"可清理"的 scratch 目录：递归删除这些不算破坏。
$scratch = @('.harness\worktrees', '.harness\local', 'docs\_snap', 'docs\_diff', '.harness\cache')

if ($tool -eq 'Bash') {
    $cmd = [string]$ti.command

    # 1) 现实世界不可逆动作：一律挡，不问模型。
    if ($cmd -match '\b(format\s+[a-z]:|shutdown|Stop-Computer|taskkill|del\s+/s)\b') {
        Block "irreversible system command blocked: $cmd"
    }

    # 2) 伪造证据：账本只能由 append-event 写。
    #    判 '>' 之前先剥掉 fd 重定向（2026-11-25）：`git add events.jsonl 2>&1` 里的 `>` 不是写账本，
    #    却让"改一个提交的作者"这种无害操作被挡（编码只能停下来问）。真正的 `> events.jsonl` 照样挡。
    if ($cmd -match 'events\.jsonl|checkpoint\.history') {
        $probe = [regex]::Replace($cmd, '\d?>\s*&\s*\d|\d?>\s*nul\b', '')
        if ($probe -match '>|Set-Content|Add-Content|Out-File|\brm\b|\bdel\b') {
            Block 'ledger write via shell blocked (the chain has no undo)'
        }
    }

    # 3) 递归删除：项目内 scratch 放行，其余一律挡。
    if ($cmd -match '(rm\s+-[a-zA-Z]*[rf]|Remove-Item[^|]*-Recurse)') {
        $inside = $false
        foreach ($s in $scratch) {
            if ($cmd -like ('*' + $s + '*')) { $inside = $true; break }
        }
        $looksAbsolute = $cmd -match '[A-Za-z]:\\|(^|\s)/(\s|$)'
        if (-not $inside -and $looksAbsolute) {
            Block "recursive delete outside the project's scratch area blocked: $cmd"
        }
        if (-not $inside -and -not $looksAbsolute) {
            # 相对路径的递归删除：无法判定目标，按不可逆处理。
            Block "recursive delete with an unresolvable target blocked: $cmd"
        }
    }
    exit 0
}

# 4) 第一方写工具与 MCP：只挡账本路径；治理面交给 decision-guard。
$fp = ''
foreach ($k in @('file_path', 'notebook_path', 'path', 'filePath')) {
    if ($ti.PSObject.Properties[$k] -and -not [string]::IsNullOrWhiteSpace([string]$ti.$k)) { $fp = [string]$ti.$k; break }
}
if ([string]::IsNullOrWhiteSpace($fp)) { exit 0 }
$fp = $fp.Replace('\', '/')
if ($fp -match 'events\.jsonl|checkpoint\.history') {
    Block 'direct ledger write blocked (the chain has no undo)'
}
exit 0