# harness-kit

**A ledger-based safety net for multi-agent coding pipelines — where the ledger, not the agent, is the source of truth.**

一个三方协作（教练出卡判卡 / 编码执行 / 人做中继与签字）的防失控骨架。
不靠更长的提示词约束模型，靠一份可核对的账本。

---

## 它解决什么问题

让 AI 写代码，真正难的不是「写不出来」，是**你无法确认它做的是不是它说的事**：

- 它说「测试通过」——哪条命令、什么输出、能不能复现？
- 它说「这一步完成了」——判定依据是什么，还是它自己觉得？
- 它改了文件——谁允许的，签名了吗，还能回到上一状态吗？
- 换个会话继续——上一轮的结论还在吗，还是全靠人转述？

本包的回答是：**把所有可以变成事实的东西变成事实，剩下的一律当意见。**

---

## 三条核心主张

**1. 账本是唯一事实源**

`events.jsonl` 是 append-only 的哈希链（`seq` / `prev` / `self` 三字段自校验）。
状态、注意力、审计、下一张卡该做什么——全部从账本**派生**，没有一个 agent 可以声明。

> agent 过去全部声明过 `done: true` / `verified: true` / `health: green`，所以这些现在全部由脚本算。

**2. 只有人能签字**

`stage-add`（把一步写入计划）、L2/L3 的 `sign-gate`、以及最终的 `seal`，只有人能签。
`stage-edit` / verify / finish-step / 合并这些日常动作不需要签名——**签字只放在真正不可逆的地方**。

**3. 门只提示，不阻断**

结构红线（文件 ≤400 行 / 函数 ≤60 行 / 嵌套 ≤4 层）是一份**报告**，不是闸门：

- 任何情况退出码都是 `0`，不进 PASS/FAIL
- 老代码按上一步已验收状态做棘轮，只在原地变胖时提示
- 每类明细封顶 8 条，存量问题只留计数，**报告长度有上界**
- 不需要写豁免、不需要清理历史、不需要任何人多做一件事

> 硬限制会把模型逼到「凑数拆分」和反复请示。提示让它自己判断，人只看值得看的那几行。

---

## 包里有什么

| 目录 | 内容 |
|---|---|
| `kit/derive/` | 34 个安全网脚本：账本写入、校验、审计、状态派生、封锚、canary |
| `kit/hooks/` | Claude Code 的 pre/post tool hook + 决策守卫（非 Claude 宿主诚实降级为轮询补账） |
| `kit/contracts/` | 交接卡与任务卡的 schema |
| `kit/checks/` | 结构红线报告 `size_gate.py` + 它的 26 条反证 |
| `kit/prompts/` | 教练与编码两个角色的行为基线（人格母本） |
| `kit/policy/`、`kit/rules/` | 政策层草案与宪法。**这一层不承诺可复现**，是裁定起点不是保证 |
| `examples/` | 真实项目的完整实战案例：1334 条账本、6 轮独立观测、故障复盘 |

`ARCHITECTURE.md` 是整个机制的完整设计说明（为什么这样切、每条规则的来历、被删掉的设计和原因）。

---

## 快速开始

```powershell
# 需要 Windows + PowerShell 7 + Node
pwsh -File kit\install.ps1 -ProjectRoot D:\my-project -By "你的名字"
```

安装器会核对 MANIFEST 全部哈希、部署脚本与 hooks、初始化账本、写 genesis 锚、然后跑 canary 与审计。
**同版本环境下逐字节可复现**；对不上会在第 1 步就停，不会带着不确定继续。

也可以把 `kit\` 整个给一个 agent，让它读 `kit\INSTALL-AGENT.md` 自行安装。

---

## 已知限制（写在这里而不是藏在问题里）

- **Windows-only**（Linux 理论可跑、未实测）
- **单用户单机**：账本锁是同盘 create-exclusive，两台机器并发追加 = 断链
- **hook 全功能仅 Claude Code**：其他宿主降级为轮询 + 补账，不给未验证的通用模板
- 政策层（`policy/`）跨 LLM 不保证可复现，依赖人中继观测
- 依赖仅 pwsh 7 + node，零外部安装

---

## 它换来了什么

不是一个 PPT 方法论，是一个真实业务项目跑了 1000+ 步之后沉淀的形态：

- **1334 条实账**，含安全网自身死亡的那次事故
- **6 轮独立观测**：每轮由不知情的观察者从账本反推「这一步发生了什么」
- 每一起踩过的坑都变成了一个 canary 场景或一条检测器——**包括把并发写、断链、误签、无解释写入变红**

`examples/` 里的案例已脱敏（业务名、域名、品牌、路径全部替换），但**账本结构、检测器输出、故障时间线一字未改**。

---

## Attribution / 归属

这套设计是从一个真实项目的账本和事故里长出来的。**如果你在文章、论文、或别的项目文档里引用它，请注明来源。**

代码使用 MIT（见 `LICENSE`），你可以自由使用、修改、商用。我唯一请求的是下面这一句：

> Based on **harness-kit** by **elu9527-sudo** — https://github.com/elu9527-sudo/harness-kit

用 GitHub 的 "Cite this repository" 按钮可以直接拿到引用格式（见 `CITATION.cff`）。

---

## License

MIT © 2026 elu9527-sudo