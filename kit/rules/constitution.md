# 宪法 · constitution.md

三个 agent 都读。这份文件定义权责边界，**优先级高于任何提示词**。
违反原则只能改上游（`profile.json` / 本文件），**不许在实际执行中稀释**。

---

## 第 1 条 · 三条硬边界

| 角色 | 可以 | 永远不可以 |
|---|---|---|
| 教练 | 读 `status`、产出四层指令、给风险分级 | **写任何文件**、执行任何命令 |
| 编码 agent | 改源文件、跑验收命令、填交接卡 | **写 `events.jsonl`**、**写 `docs/变更记录.md`**、声明完成 |
| 文档 agent | 追加 `docs/变更记录.md`、写 `anchor` | **改源文件**、改 `status`、宣布验收通过、执行 git 写 |

补充：教练的 `edit` / `terminal` 权限必须关闭。**有权限就一定会用**（已发生过一次）。

---

## 第 2 条 · 写权矩阵

| 资源 | 唯一写入者 | 其他人 |
|---|---|---|
| `events.jsonl` | `post-tool.ps1`（hook） | 只读 |
| `docs/变更记录.md` | 文档 agent（只追加） | 只读 |
| `.harness/project.json` | 人 | 只读 |
| `.harness/constitution.md` | 人 | 只读 |
| 源文件 | 编码 agent | 只读 |
| `status` | 脚本（不落盘） | 读 |

> **No one writes outside this table.** 越界即本次运行无效。

---

## 第 3 条 · 编号权

**唯一号源 = `events.jsonl` 的 `seq`**（单调递增，从 1 起，不跳号）。

- 教练**不得**在指令里指定编号
- 编码 agent **不得**自造编号（`C-005` 这类一律写 `pending`，由脚本回填）
- 文档 agent 引用编号时只能引用已存在的 `seq`
- 冲突检测：`verify-ledger.ps1` 报 `seq_gap` 即本次运行无效

理由：编号有两处副本时，一个引用会解析到两个对象（已实测）。

---

## 第 4 条 · 五值锚点

任何"我核验过了"的断言，必须落到五值之一：

| 值 | 含义 | 允许的后续动作 |
|---|---|---|
| `verified` | 重算哈希通过，且 reviewer ≠ author | 可进入下一步 |
| `stale` | 曾经 verified，但源已变 | 必须重验 |
| `unavailable` | 该锚点在本项目不可用（如无 git） | **必须显式记录**，不得静默 |
| `unknown` | 未观测 | 不得当作通过 |
| `failed` | 核验失败 | 阻塞 |

规则：

1. **缺失不等于通过。** 读不到证据时必须写 `unavailable` 或 `unknown`。
2. **`unavailable` 必须带 `why`**，且必须出现在维护报告里。
3. **权限读失败永不当 PASS。**
4. 证据缺失 ≠ 拒绝，也 ≠ 通过；它是第三种结论：**CANNOT ESTABLISH**。

---

## 第 5 条 · 完成与验收

1. `done` 的判据是 **`generates` 的文件全部存在，且最新一次 `verify` 不是反证**，由 `status.ps1` 算。
2. 文件存在不足以证明"做对了"——还需要 `verify` 事件满足 `exit=0 且 trivial=false 且 real_test=true`。
3. `verify` 的三种结论必须分开，不许合并：
   - `exit≠0` → **反证**：该 stage 退回 `ready`，anomaly 永远 `blocking`
   - `exit=0 且 trivial=true` → **无效证据**：证明不了任何事，但它也不是反证
   - `exit=0 且 trivial=false 且 real_test=true` → **证据**
4. **不可失败的检查不算检查**（`echo`、`exit 0`、`python -c "pass"` 等）。
5. **空测试体 / 注释体不算证据**。
6. 编码 agent 可以声明"我做了"，**不能声明"验收通过"**。
7. 文档 agent 只能记录"执行完成，待验收"，验收结论由人给。

---

## 第 6 条 · 本文件的修改

| 级别 | 内容 | 要求 |
|---|---|---|
| MAJOR | 删除或重定义已有条款 | 人明确同意 + 通知三个角色新开会话 |
| MINOR | 新增条款 | 人同意 |
| PATCH | 措辞修正 | 直接改 |

修改必须**同一次变更内**同步到 `task.schema.md` / `handoff.schema.md`，不允许只改宪法不改契约。

---

## 第 7 条 · 违规处理

**违反原则只能改上游契约，不许在执行中稀释。**

例：`verify` 命令跑不通时，正确做法是改 `profile.json` 的 `verify` 字段或修代码，**不是**把命令换成 `echo ok`，也不是在交接卡里写"已验证"。

违规的表现只有一个：`status.ps1` 的 `anomalies` 或 `trigger.ps1` 的 `T8_chain_broken` 变红。
