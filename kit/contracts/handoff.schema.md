# 交接卡 · handoff.schema.md

编码 agent 每步结束输出这一份。**它不是报告，是给下一个角色的输入。**

## 五个字段

```yaml
step: 1.5
produced:                        # 必填。产出物，每条带证据指针
  - "file:scripts/start_chrome.ps1:79 行，三参数 + CDP 轮询 + exit 2 超时"
  - "cmd:pytest tests/test_launcher.py:5 passed, exit 0"
decisions:                       # 必填。关键选择与理由
  - "why: 用 Start-Process 而非 & 调用，因为需要拿 PID 做超时清理"
deviations:                      # 必填，可为空数组。偏离原计划的地方
  - what: "原计划用 9335 端口"
    why: "被遗留 Chrome 占用"
    cost: "需另约端口，文档要改"
    alternatives: ["复用 9335", "改用 9340", "换启动方式"]
uncertainty:                     # 必填，可为空。我认为可能错的地方
  - "超时分支（exit 2）未实测，只走了 500ms×15s 的轮询路径"
residual:                        # 必填，可为空。知道没做、谁负责
  - "真实账号未就位，P2 才能验证登录态"
```

## 两条约束

### 约束一：`produced` 必须是指针串，不是叙述

格式：`<type>:<path>:<summary>` 或 `<type>:<cmd>:<result>`

| 合格 | 不合格 |
|---|---|
| `file:scripts/x.ps1:79 行` | "完成了脚本" |
| `cmd:pytest:5 passed, exit 0` | "测试通过" |
| `diff:docs/_diff/1.5.diff:新增 3 文件` | "改了一些文件" |

被 `is_trivial` 判为不可失败的命令**不算证据**（`echo`、`exit 0`、`python -c "pass"` 等）。

### 约束二：不填状态类字段

以下一律不写，由脚本算：

| 不许写 | 谁算 |
|---|---|
| `done: true` | `status.ps1`（看文件是否存在） |
| `health: green` | `status.ps1` 的 anomalies |
| `session: 3` | `events.jsonl` 的 `seq` |
| `change_id: C-005` | `events.jsonl` 的 `seq` |
| `verified: true` | `verify-ledger.ps1` + 五值锚点 |

**理由**：这五项是"意见"，不是"事实"。它们过去全部由 agent 声明，所以全部出过错。

## 谁读它

| 角色 | 读什么 |
|---|---|
| 人 | `deviations` + `uncertainty` + `residual`（三行，判断能不能继续） |
| Hermes | **只在 `trigger.ps1` 命中时**读全部五字段 |
| 脚本 | 不读交接卡，读 `events.jsonl` |

交接卡是**沟通物**，不是事实源。事实源永远是 `events.jsonl`。
