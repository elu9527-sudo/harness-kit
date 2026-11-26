# Harness Kit · 设计

版本 0.2 · 2026-11-07

> **0.2 变更**（由一次完整端到端的独立观测驱动）
> - 新增 ⑦ **自检层** `audit.ps1`：把"harness 自己还连着吗"变成可算的检查
> - 新增 P4/P5：声明须与实现同构；审计只读、发现与修复分离
> - **废除 `step_start` / `step_end`**：`step_end` 从来没有写入者，却让 T3/T4 白挂着
> - T3/T4 改挂 `tool_use`；`verify` 结论由两读改为**三读**（pass / FAIL / VOID）
> - `pre-tool.mjs` 增加 root 守卫：项目外的绝对路径不再落成 0 字节垃圾快照

## 0. 一句话

三个 LLM 角色不变，把跨角色的事实、校验、状态挪进一个零依赖的确定性内核，人仍是唯一通道。内核还要能自检——**否则没人知道它是不是真的接上了**。

## 1. 三条原则

| # | 原则 | 一句话理由 |
|---|---|---|
| P1 | 事实由机器产生，意见由人产生 | 机器记的流水和 LLM 写的决策是两种东西，混在一个文件里两边都会失真 |
| P2 | 状态是重算的，不是记录的 | 记录的状态会被改，重算的状态改不了 |
| P3 | 每层必须能演示"错误输入下会红" | 不能演示的约束等于不存在 |
| P4 | 声明必须与实现同构 | 文档说有、代码没有的东西，比根本没有更危险：它让人以为这里有人管 |
| P5 | 审计只读，发现与修复分离 | 会动手的审计，就是一个新的不被监督的写入者 |

## 2. 架构

```
                ┌────────────────────────────┐
                │  人（唯一通道，不自动化）      │
                └────────────────────────────┘
                   │ 指令     │ 交接卡  │ 按需维护
                   ▼          ▼         ▼
             ┌────────┐ ┌────────┐ ┌────────┐
             │ 教练    │ │ Claude │ │ Hermes │
             │ LLM    │ │ LLM+工具│ │ LLM    │
             └────────┘ └────────┘ └────────┘
                   │          │         │
                   │          │hook 无感 │
                   ▼          ▼         ▼
        ╔═══════════════════════════════════════════╗
        ║  确定性内核 · 零 LLM · 零第三方依赖           ║
        ║  ① 契约  ② 事实  ③ 证据  ④ 验证  ⑤ 派生  ⑥ 闸门 ║
        ╚═══════════════════════════════════════════╝
                             │
                             ▼
                   .harness/  +  events.jsonl
```

agent 的 token 成本为 0：内核靠 hook 与脚本运行，agent 不读不写。

---

## 3. 六层

### ① 契约层 · `profile.json`

**设计**：每个步骤声明它产出哪些文件、依赖哪些步骤、怎么验收、什么风险等级。

**规则**
- `generates` 全集存在 → `done`
- `requires` 全 `done` → `ready`，否则 `blocked`
- 按 profile 顺序取第一个 `ready` 作为下一步

**出处**：OpenSpec `schemas/spec-driven/schema.yaml`、`docs/agent-contract.md:60-61`

**思考**："下一步是什么"不该由 LLM 决定，应由"哪些文件还没有"决定。

### ② 事实层 · `events.jsonl`

**设计**：append-only，每行带 `prev`/`self` 哈希链，`seq` 单调递增。

**规则**
- 写入只走 CLI/hook，agent 不得直接编辑
- `self = sha256(canonical_json(记录去掉 self))`
- `prev` = 上一条的 `self`，第一条为 `""`

**出处**：seekmemory `store/ledger.py:11-28,88-104`（hash 链与 `verify()`）；BMAD `skills/bmad/scripts/memlog.py`（append-only 写入器，Windows 用 `FILE_APPEND_DATA`）

**思考**：台账被偷偷加行的唯一解药是让"加行"这件事留下痕迹。

### ③ 证据层 · `cited-source`

**设计**：任何"这个文件是那样"的断言都带 `{path, sha256}`，校验时重读重算。

**规则**
- `tool_use.data.sha256` = 写完时的文件哈希
- `tool_use.data.before_sha256` = 写前的哈希，`""` 表示新建
- 校验时比对磁盘现值；不一致即 `drifted`

**出处**：rivet `schemas/common.yaml:86`、`rivet-core/src/cited_source.rs`

**思考**：没有 git 时，"文件内容等于某哈希"是唯一不依赖第三方的事实锚点。

### ④ 验证层 · `is_trivial` / `real_test`

**设计**：验收命令必须可能失败，且必须指向真实存在、body 非空的测试。

**规则**
- `trivial=true` 的命令（`true`/`:`/`exit 0`/`echo`/`printf`/`python -c "pass"`/`cd X` 及它们的 `&& || ;` 链）不算证据
- `real_test=true` 要求在源码中找到该测试且 body 非空
- `verify` 事件必须 `exit=0 且 trivial=false 且 real_test=true` 才算通过

**出处**：autoharness `runs.py:is_trivial()`；rivet `verification_evidence.rs`（"empty body is not evidence"）

**思考**：绿灯有两种假的——不可能失败的检查，和指向不存在的测试。两者都 exit 0。

### ⑤ 派生层 · `status.ps1`

**设计**：从 `profile.json` + 文件系统重算状态，不落盘、不读台账。

**规则**
- 状态只有四值：`done` / `ready` / `blocked` / `skipped`
- 台账只用于 `anomalies`，不用于产生状态
- `anomalies` 三类：`done without evidence`、`drifted`、`ready but blocked`

**出处**：OpenSpec `status --json`（首个 `ready` 即下一步）；spec-kitty `status/views.py:288-316`、`reducer.py:435-449`（陈旧才刷新、内容相同不写）；fak `sessionview/model.go:187-191`（守恒不变量）

**思考**：状态视图一旦落盘就会腐化；每次重算的成本是一次文件存在性检查。

### ⑥ 闸门层 · `trigger.ps1`

**设计**：Hermes 不每步出现，只在触发规则命中时出现；触发由脚本判定。

**规则**：见第 8 节 T1–T10。

**出处**：autonomous-sdlc `templates/governance/risk-policy.yaml`（`pattern → risk → approval_required`）；sarathi-sdlc `docs/approval-gates.md`（五值锚点、`CANNOT ESTABLISH`）；BMAD `tools/ticket-tree-rules.md:31-39`（`Status | Written by` 写权矩阵）；soleur `check-adr-ordinals.sh`（单一权威序号）

**思考**：昨晚"六事件"漏触发，根因是它由 LLM 判断。人能看懂的条件，脚本就能判。

### ⑦ 自检层 · `audit.ps1`

**设计**：前六层都在回答"项目怎么样了"。没有一层回答"**这个 harness 自己还连着吗**"。一个项目可以状态完美、阶段照常推进，同时一半的安全规则从未被触发过——因为它们的输入事件根本没有写入者。整轮端到端跑完，T3/T4/T5/T6 全是死的，没有任何东西发出声音。

`audit.ps1` 只读、不修、不写任何文件。它把"接通了没有"变成九个可算的检查：

| # | 检查 | 问的问题 |
|---|---|---|
| C1 | chain | 哈希链完整吗 |
| C2 | registration | 每种声明的事件，**有代码路径能写它吗** |
| C3 | emission | 每种声明的事件，**真的出现过吗**；反过来，日志里有没有设计未定义的类型 |
| C4 | rule input | 每条触发规则的输入事件被发过几次 |
| C5 | evidence | 每个阶段最新一次 verify = `pass` / `FAIL` / `VOID` / `none` |
| C6 | verify-ref | verify 依赖的文件，**有人负责产出吗** |
| C7 | drift | 磁盘内容与台账记录一致吗 |
| C8 | attribution | 事件是不是都堆在一个 step 上 |
| C9 | decisions | 变更记录里的 `D-NNN`，在台账里真的存在吗；**一条 `D-NNN` 都没有时，这条检查等于没跑** |
| C10 | harness | 当前这套 harness 的摘要，被记录进台账过吗（**不匹配是 fault**） |
| — | 聚合 | 任一 fault → 整体失败；warn 不影响 |

**规则**
- **只读**。审计不得修正它发现的东西，否则它就成了新的不可信写入者。
- **registration ≠ emission**。能写 ≠ 写了。两个都要查，只查一个会漏掉一半。
- **双向比对**。既要查"声明了但没发"，也要查"发了但没声明"。`tool_use` 就是后者：它是日志里数量最多的事件，而设计文档里根本没有这个类型。
- **三态证据**。`exit!=0` 是**反证**；`exit==0 且 trivial` 是**无效**（证明不了任何事）；两者都不是"没有证据"。`echo ok` 当验收跑了整轮，就栽在把 VOID 当成 PASS。
- **worst-wins 聚合**（Spring Boot Actuator 的健康聚合原则）。一个 fault 让整体红；**不可读的输入报 `unknown`，绝不报 `up`**。
- **引用完整性**。verify 命令点名的文件，要么在盘上，要么在某个 stage 的 `generates` 里；否则没有任何人负责产出它，这条 verify 永远不可能通过。

**出处**：
- liveness / readiness 分离 —— Spring Boot Actuator health 端点与探针语义
- worst-wins 聚合 —— 同上，"最差状态优先"
- drift、只对比不修正 —— Terraform `plan -refresh-only`（`terraform refresh` 已被弃用，正因为它会顺手改状态）
- 基线必须经人工审查才能更新，且基线本身也要防篡改 —— AIDE / Tripwire 文件完整性监控的工作流（"更新基线前必须人工审查报告，不能发现变化后直接覆盖数据库"）
- 规则未覆盖即未验证 —— OPA `opa test -coverage`
- registration ≠ emission —— OpenTelemetry 遥测覆盖门禁（"emission, not just registration"）
- "检查从没失败过"值得怀疑 —— 变异测试（一套从不失败的测试，最可能什么都没断言）
- 图完整性自检 —— `git fsck`
- 每步必须有证据，且产出物必须符合该步声明的 artifact rules —— in-toto `link` metadata 与 `in-toto-verify`（"a threshold of link metadata files exists for each step"、"materials and products adhere to the artifact rules"）

**C9 与 C10 回答的是"记录本身可信吗"。**

C9 检查变更记录里的编号。Hermes 自己给决策编号，编错了没有任何东西能看出来——文字依然通顺、条理依然清楚。所以 `D-<seq>` 直接取自台账，跳号是正常的，跳号恰好证明它没被编造。Gerrit 对同一问题的解法是让 `commit-msg` hook 生成 Change-Id 而不是相信作者；这里 `seq` 已经存在，直接用它更省。

C10 检查这套 harness 自己。derive 脚本、规则、契约、hook 全在 `.harness/` 下，由三 agent 循环之外维护——**它们的改动不产生任何事件**。这不是假设：一次观测窗口里有四个 derive 脚本被修改，此后端到端再也复现不了，而台账里查不到当时跑的是哪一版规则。`seal-harness.ps1` 把当前摘要写成 `anchor`，角色等同 lockfile 的 `integrity` 字段。封存是手动的，理由和基线更新一样：自动封存等于记录"磁盘上碰巧是什么"。

C10 不匹配时是 **fault，不是 warn**。"当时跑的是哪一版规则"是复现这次运行的前提条件，不是风格偏好。它当了整整三轮的 warning，三轮的结局都一样：窗口中途 harness 被改、`audit` 依然 `ok=true`、报告里只能写一段免责声明。**一个关于"证据是否可复现"的检查，自己不能只警告。**

C9 的空集情形同理。这条检查验证的是变更记录里的 `D-<seq>` 是否真在台账里，而那份文件在宣布"只记 `D-NNN`"之后收到了 **0 条 `D-NNN` 标题**——检查从来没有输入，于是永远绿。`C9 0 record(s) checked` 一栏在三次报告里都读作"通过"，实际含义是"没跑"。空输入集上的通过不是通过，是没跑；这和一套全部 skip 的测试报告 green 是同一件事。

**思考**：文档描述的是"应该有的闭环"，代码实现的是"实际接上的部分"，两者之间没有任何东西在核对。**凭说明书验收系统，等于没验收。** 自检层的存在理由就是让这个差值变成可算的数字。

---

## 4. `events.jsonl`

```jsonl
{"v":1,"seq":1,"at":"2026-11-07T01:40:00Z","step":"1.5","kind":"routine","actor":"hook","event":"tool_use","data":{"file":"requirements.txt","sha256":"a1b2…","before_sha256":""},"prev":"","self":"c3d4…"}
```

| 字段 | 说明 |
|---|---|
| `v` | schema 版本，当前 1 |
| `seq` | 从 1 起，不跳号 |
| `at` | ISO 8601 UTC，带 `Z` |
| `step` | `"1.5"` |
| `kind` | `routine` \| `decision` |
| `actor` | `hook` \| `claude` \| `hermes` \| `human` |
| `event` | 见下 |
| `data` | 依 `event` |
| `prev` / `self` | 哈希链 |

**canonical_json**：key 字典序、无空格、UTF-8、不转义非 ASCII。

### 事件类型

`kind = routine`

| event | data | 写入者 |
|---|---|---|
| `tool_use` | `{file, sha256, before_sha256}` 或 `{cmd, trivial}` | PostToolUse hook（`post-tool.mjs`）；**hook 之外发生的写入用 `append-event.ps1 -Event tool_use` 补记** |
| `verify` | `{cmd, exit, trivial, real_test, duration_ms, target}` | `append-event.ps1`：**自己跑命令，不信自报** |

`tool_use` 有两个入口，这是有意为之。hook 只能看见经过 Claude Code 的写入；人用 IDE 手改、生成脚本改、harness 维护者改，全在它视野之外。只留一个入口的后果在第三次观测里非常具体：13:27:05 有人手改了 `docs/变更记录.md`，C7 报了 drift，唯一的处置办法是"删掉文件"或"忽略告警"，于是它一直亮着。

补记入口不放松任何要求：`sha256` 由脚本从磁盘算，`before_sha256` 从台账里该文件的最后一条记录取，`actor=script`，`kind=routine`。**补记是让链外的写入重新入链，不是让它免检。** 归档事件一律 `kind=routine` 也很关键——若记成 `decision`，一次普通编辑就能满足 T9 的交接判定。

`append-event.ps1` 执行 `verify` 前会 `Push-Location` 到项目根：profile 里的命令是按"人在项目根手打"的写法写的（`.venv\Scripts\python.exe ...`），相对解释器路径按当前目录解析，从别处调用会得到一个**假的 FAIL**——比没有检查更坏，那是一次没发生过的反证。

**`step_start` / `step_end` 已废除。**

废除理由不是"没实现就先删"，而是它们本来就不该存在：`step_end.writes[]` 是该 step 全部 `tool_use` 的聚合，按 P2 应当**重算而不是记录**。留着它们的代价是真实的——`trigger.ps1` 的 T3/T4 依赖 `step_end`，而没有任何代码写它，于是两条规则挂在那里从未触发，同时读文档的人以为返工和范围变化有检查。**规则引用一个不存在的事件，比没有这条规则更糟。**

step 的边界改由 `verify` 事件标记：一次验收就是一次边界。

`verify` 的结论必须三读，不能两读：

| 情形 | 判定 | 含义 |
|---|---|---|
| `exit != 0` | `FAIL` | 反证：检查跑了，代码不对 |
| `exit == 0` 且 `trivial=true` | `VOID` | 证明不了任何事：命令不可能失败 |
| `exit == 0` 且 `trivial=false` 且 `real_test=true` | `PASS` | 有效证据 |

把 `VOID` 当成 `PASS` 是 `echo ok` 混过一整轮验收的原因；把它当成 `FAIL` 又高估了它。


`kind = decision`（claude 填 / hermes 转写 / human 定）

| event | data | 谁 |
|---|---|---|
| `deviate` | `{what, why, cost, alternatives[]}` | claude |
| `skip` | `{step, why, impact, revisit}` | claude |
| `blocker_open` / `blocker_close` | `{id, why, since_step}` | claude |
| `contract_change` | `{file, before_sha256, after_sha256, why}` | claude |
| `gate` | `{level, status, by}` | human |
| `anchor` | `{name, value, why}`，value ∈ `verified/stale/unavailable/unknown/failed` | hermes |

`anchor` 是把"没有 git"和"git 干净"区分开的唯一手段。它同时承载**基线更新留痕**：`validate-profile -SyncBaseline` 会写一条 `name=profile_baseline` 的 anchor，带 `from` / `to` 两个摘要。规矩抄自 AIDE —— 基线只有在"接受变更"是一次明确且被记录的动作时才可信，否则谁能改文件，谁就能改"文件曾经长什么样"的记录，而这正是基线要堵的那个洞。

---

## 5. `profile.json`

```json
{
  "v": 1,
  "project": "price-watch",
  "stages": [
    {
      "id": "1.5",
      "goal": "Chrome 启动脚本 + CDP 验证",
      "generates": ["scripts/start_chrome.ps1"],
      "requires": ["1.2", "1.4"],
      "verify": "pwsh -File scripts/check-cdp.ps1",
      "risk": "L1"
    }
  ],
  "risk_policy": [
    { "pattern": "docs/**", "risk": "L0" },
    { "pattern": "**/*.md", "risk": "L0" },
    { "pattern": "src/**", "risk": "L1" },
    { "pattern": "**/auth/**", "risk": "L2" },
    { "pattern": "**/*.sql", "risk": "L2" }
  ]
}
```

换项目只改这个文件。

---

## 6. 文件布局

```
<项目>/
├── .harness/
│   ├── VERSION                 kit 版本锁
│   ├── PROFILE                 profile 名
│   ├── project.json            ★ 唯一项目相关
│   ├── local.json              .gitignore（含 current_step）
│   ├── contracts/{task,handoff}.schema.md
│   ├── rules/constitution.md
│   ├── hooks/{pre,post}-tool.mjs
│   └── derive/
│       ├── _common.ps1         规范化 JSON / sha256 / 读日志
│       ├── append-event.ps1    唯一的决策事件写入者；verify 自己跑命令
│       ├── verify-ledger.ps1   链完整性
│       ├── finish-step.ps1     收尾：diff + verify + status
│       ├── status.ps1          readiness —— 下一步是什么
│       ├── trigger.ps1         attention —— 要不要叫 Hermes
│       ├── audit.ps1           liveness —— harness 自己还连着吗
│       └── seal-harness.ps1    把当前 harness 摘要写进台账（lockfile 的角色）
├── events.jsonl                ★ 唯一事实源
├── docs/
│   ├── 变更记录.md              Hermes 写，只记决策
│   ├── _snap/                  hook 写
│   └── _diff/
└── AGENTS.md
```

---

## 7. 派生算法（`status.ps1`）

```
for stage in stages:
    if all(f exists for f in stage.generates) and newest_verify(stage) != fail:
        status = done
    elif all(peer.done for peer in stage.requires): status = ready
    else: status = blocked

next = 第一个 ready（按 profile 顺序）
complete = 全 done

anomalies:
    1. done 但 events 无 verify(exit=0, trivial=false, real_test=true)  → done_without_evidence
    2. 最新 verify exit≠0 → 该 stage 不判 done，退回 ready               → verify_failed（永远 blocking）
    3. done 但磁盘 sha256 ≠ events 最后记录                              → drifted
    4. ready 但 requires 里有 stage 未 done                              → 逻辑矛盾
```

`done` 的第一判据是文件存在，但**存在不等于对**：一条 exit≠0 的 verify 是反证，它把 stage 退回 `ready`，于是 `next` 重新指向那一步，而不是带着已知错误往前推。

`done` 的第一判据是文件存在，不是台账。`anomalies` 用来抓"文件在但没验证过"。

---

## 8. 触发规则（`trigger.ps1`）

| # | 触发 | 判定 |
|---|---|---|
| T1 | 设计偏离 | 任意 `deviate` 事件 |
| T2 | 契约变更 | `contract_change` 事件，或 `project.json` 的 sha256 变化 |
| T2c | 契约未签 | 某条 `contract_change` 的 `data.approved_by` 不是 `human` / `owner` |
| T3 | 范围变化 | `tool_use` 写入的路径不在该 step 的 `generates` 内 |
| T4 | 返工 | 已 `done` 的 step 在 `verify` 通过之后又被 `tool_use` 写 |
| T5 | 跳过 | 任意 `skip` 事件 |
| T6 | 阻塞积压 | `blocker_open` 未关闭且跨越 > 2 个 step |
| T7 | L2 风险 | 命中 `risk_policy` L2 且无 `gate` 记录 |
| T8 | 链断裂 | `verify-ledger.ps1` 失败 |
| T9 | 契约无交接 | 产出 `contracts/`、`config/` 的 stage 已 `done`，但台账里没有该 stage 的 `contract_change` / `deviate` |
| T10 | 越位推进 | 某 stage 的产物都在盘上、它自己**没有一次通过的 verify**，而**更靠后**的某 stage 产物也已在盘上 |

T3/T4 原先的定义依赖 `step_end`，那是唯一能让它们触发的输入，而 `step_end` 从未被任何代码写过。它们现在改挂 `tool_use`——一个真实存在、每步都有几十条的事件。**规则必须挂在能被触发的输入上，否则它只是装饰。**

T2c 的签核**写在变更事件本身上**，不是另开一张通行证。`strong_migrations` 拦危险迁移用的是同一招：绕过标记（`safety_assured`）留在调用点，所以 review 时看得见，一次批准也不会自动覆盖后面每一次变更。"只要历史上出现过任意一个 gate 就算签过" 是它明确要避免的错误——那正是本项目第一轮里"改 verify 让任务能推进"能溜过去的原因。

T9 补的是一个更隐蔽的洞。教练每一步都要判「要不要做文档交接」，而这个判断是聊天里的一句话，**不可审计**。脚本能做的是另一半、结构上的判定：凡是产出 `contracts/`、`config/` 这类"别人得照着写代码"的文件的 stage，一旦完成，台账里就必须留下承认该约定的决策事件。否则"契约定完了"只是聊天记录里的一个断言，两周后没人找得到，而后面每一步都建在这个未经确认的前提上。

判据必须收窄到 `contract_change` / `deviate`：第一版接受任意 `decision` 事件，结果一条 `profile_baseline` 的 anchor 就把"从未交接"的 stage 判成了已交接。**"有东西被记录了"不等于"这件事被记录了"。**

T10 是唯一一条**读磁盘而不是读事件流**的规则，因为它要抓的正是事件流本身出错的情形。第三次观测里，2.0.4 的产物 13:36 就在盘上，2.0.5 的产物 13:47 也在盘上，而台账里 2.0.4 的 `verify` 数是 **0**。三条既有规则全都没响：

- T4 需要一次**已通过**的 verify 才能把后续写入叫"返工"，它看不见"从来没通过"；
- T3 只抓不属于任何 stage 的路径，而这两个文件都有归属；
- `status` 只跟 `current_step` 比，而 `current_step` 只有 `finish-step` 能推进——于是链条钉在 2.0.4，活儿已经走到 2.0.5，每一步都合规。

判据用磁盘事实而非事件归属，是因为**归属字段正是坏掉的那个东西**：那段会话 `/clear` 之后，`local.json` 还停在 2.0.4，2.0.5 的 26 条记录全部被打上 `step=2.0.4`。若按事件判，一切自洽；按磁盘判，问题立刻现形。

作用域收在 `current_step` 及之后。更早的 stage 处于证据制度建立之前，永远重报它们是把检查变成噪音的老路。

**反证自己**：把 `main.py` 临时改名，T10 归 0；改回来，T10 回到 1。一条从未见过失败的检查，还没有被证明能失败。

每条规则的输入覆盖情况由 `audit.ps1` 的 C4 持续报告；`T1/T5/T6` 在正常流程里低频出现，它们的"未触发"是正常的，C4 只报计数不判错。

输出：

```
需要 Hermes 处理：2 项
  T1 deviate  step 1.6  原设计用 9335 → 改用 9340  (alternatives: 复用 / 换端口 / 换方案)
  T6 blocker  B-1       已经过 3 步未关闭
维护范围：只读 step 1.6 的 events + diff 路径
```

Hermes 的输入因此有界，没有"整篇"可读。

---

## 9. 读写矩阵

| 资源 | 教练 | Claude | Hermes | hook | 脚本 | 人 | 审计 |
|---|---|---|---|---|---|---|---|
| `project.json` | 读 | 读 | 读 | — | 读 | **写** | 读 |
| `events.jsonl` | 读 | 不写 | 读 | **写** | 读 | 不写 | 读 |
| `docs/变更记录.md` | 不写 | **不写** | **写** | — | 读 | 读 | 读 |
| `_snap/` `_diff/` | — | — | 读 | **写** | 读 | 读 | 读 |
| `constitution.md` | 读 | 读 | 读 | — | — | **写** | 读 |
| 源文件 | 不写 | **写** | 不写 | 读 | — | 写 | **只读** |
| `status` | 读 | 不读 | 不读 | — | **算** | 读 | — |
| `audit` | 读 | 不读 | 不读 | — | **算** | 读 | — |

三条硬边界：Claude 不写台账；Hermes 不改代码、不改状态、不宣布验收；教练不写任何文件（Trae 的 `edit` 必须关闭）。

**第四条边界（新增）：审计只读。** `audit.ps1` 不得修正它发现的问题。一旦审计会动手，它就成了一个新的、同样不被监督的写入者——而这正是它要抓的东西。发现与修复必须由不同角色承担。

---

## 10. 迁移

| 阶段 | 内容 | 验收 |
|---|---|---|
| A | `profile.json` + `events.jsonl` + `verify-ledger.ps1` | 手改一行 → `chain broken at seq N` |
| B | `status.ps1` + `trigger.ps1` | 跳步 → `blocked`；造一条 `deviate` → T1 命中 |
| C | `post-tool.ps1` 挂 Claude Code hook | 改一个文件 → events 多一条带 sha256 |
| D | 改 Hermes 提示词（五值 + 有界输入 + 只在触发点） | 造 `unavailable` 锚点，看它是否显式报 |
| E | 改教练提示词（读 status、产交接卡、不写文件） | 关掉 `edit` 后仍能给指令 |

每段可独立回退：脚本是独立文件，hook 可从 `settings.json` 摘掉。
