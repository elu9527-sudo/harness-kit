# hooks 接入说明

## Claude Code（唯一全功能宿主）

**不要手工改 `~\.claude\settings.json`。** 装的时候跑一次：

```
pwsh -File .harness\derive\hook-install.ps1
```

它做三件事，都是幂等的：

1. 把 `.harness\hooks\pre-tool.mjs` / `post-tool.mjs` 复制到
   `%USERPROFILE%\.claude\hooks\harness\`（**项目外、kit 外的固定位置**）。
2. 备份 `settings.json` 到 `settings.json.bak-<时间戳>`。
3. 合并 hooks 段：替换掉任何指向旧路径（kit 目录 / 项目目录）的旧条目，
   保留你自己注册的其它 hook，只写自己拥有的 key（`env` 一个字都不动）。

注册后的结构（路径为实际值，不是示例）：

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write|Edit|MultiEdit|NotebookEdit|Bash|mcp__.*",
        "hooks": [ { "type": "command",
                     "command": "node \"%USERPROFILE%\\.claude\\hooks\\harness\\pre-tool.mjs\"" } ] }
    ],
    "PostToolUse": [
      { "matcher": "Write|Edit|MultiEdit|NotebookEdit|Bash|mcp__.*",
        "hooks": [ { "type": "command",
                     "command": "node \"%USERPROFILE%\\.claude\\hooks\\harness\\post-tool.mjs\"" } ] }
    ]
  }
}
```

### 为什么固定位置在项目外

第一版直接从 `<kit>\templates\hooks\` 原地执行。kit 一改名/一搬走，
settings.json 里那条路径就悬空，hook 全部非零退出，Claude Code 静默忽略，
账本停止增长而**依然看起来权威**——这是最坏的一种失败：安全网失效且不报错。
现在执行字节在固定位置，项目里的 `.harness\hooks\` 只作为 seal 钉过的
参照副本，`hook-coverage.ps1` 比对两者是否同字节。

### 覆盖范围与已知限制

| 通道 | pre（写前图像） | post（自动落账） |
|---|---|---|
| Write / Edit / MultiEdit | 有 | 有 |
| NotebookEdit | 有（`notebook_path`） | 有（`notebook_path`） |
| Bash | 有（全项目哈希边界） | 有 |
| `mcp__*`（windows-mcp / agent-desktop 等） | **无**（工具不透明） | 有（带 `via:"mcp"`） |

`mcp__*` 的 pre 侧只观察不拦截：同一个 `path` 可能是读、可能是列目录，
拦截一次读就是自伤，而会被卸掉的 hook 会连带卸掉所有安全通道。
代价写清楚：**项目外的 MCP 写没有写前图像、不进 pre 边界**。

### 声明必须落账，不能只在对话里说

```
pwsh -File .harness\derive\hook-coverage.ps1
```

它读宿主 settings、解析每条命令的真实文件、算 sha256、和 `.harness\hooks\`
的钉值比对、把 matcher 拿去逐个通道试，然后**自算自记**一条
`anchor event=hook-coverage`（`-DataJsonFile`，`Actor=script`）。
覆盖判定不是谁声明出来的，是量出来的——包括这里写着的三条限制。

## 其他宿主（Codex / Cursor / Trae / 任意）——诚实降级

没有 Pre/PostToolUse 机制 = 没有写前图像与自动落账。
安全网降级为：sweep 轮询（10min）+ `record-edit.ps1` 补账 + 手动 trigger/audit。
降级事实必须落账：跑一次 `hook-coverage.ps1`，它会记 `value: degraded` 并列出
失去的能力（`no-host-hooks`）。不要发明未验证的通用 hook 模板——包里不给假承诺。