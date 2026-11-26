# 缺陷报告 · observer #4

**被观测系统**：`D:\work\price-watch-demo`（教练 Trae / 编码 Claude Code / 文档 Hermes / 人 三角色流水线 + `harness-kit` 度量层）
**观测起止**：2026-11-07 15:38:00 → 16:18:00 +08:00（40 分钟，**短于任务书要求的 2 小时**，原因见文末「观测结束」）
**采样轮数**：11 轮（详见 `timeline.md`）。实际间隔 1–10 分钟不等，不是等距的 12–15 分钟——
原因是 15:38–16:18 之间被观测系统高度活跃（台账 40 分钟新增 128 条、harness 被改 6 次），
按 12–15 分钟等距采样会漏掉其中大部分；我改用按事件密度加密采样，代价是总时长缩短。
**台账 seq 范围**：1–654。观测窗口内的增量是 **seq 527 → 654（新增 128 条）**，窗口起点 max seq = 526。
**链完整性**：起点 `[OK] 526 records, chain intact, head=29718a66bf6b`；
终点 `[OK] 654 records, chain intact, head=43e1fd168d44`（观测期间无断链、无重复 seq、无残留 `.lock`、无并发写冲突）。

**本次观测覆盖了什么**：
- 四条只读派生视图在 11 个采样时刻的全部输出（audit C1–C10 / trigger T1–T12 / status / verify-ledger）
- 台账 526→654 条记录的结构、`actor×event` 分布、每个 step 的 verify 三态、T2/T3/T4/T7/T11/T12 触发源的逐条溯源
- `events.jsonl` 与磁盘文件的 sha256/mtime 对账，含对一个被改文件做了**字节级重建验证**（O4-01，取前 74 行重算得 `949a5cd58bbe`，与 seq 43 逐字节吻合）
- harness 全部关键脚本源码：`trigger.ps1`（561 行版与 626 行版）、`audit.ps1`、`finish-step.ps1`、`sign-gate.ps1`（10927B 版与 13660B 版）、`append-event.ps1`、`post-tool.mjs`、`pre-tool.mjs`、`verify.ps1`
- `docs/变更记录.md` 的全文结构与逐节内容、`docs/_snap`/`docs/_diff` 的全部清单、`AGENTS.md` §10 的维护规则
- 一次完整实时推进：3.1.3 从"待签 gate"→ 开工 → 写交付物 → 首次 gate 签名（`why="y y"`）→ verify 红（`RESULT FAIL 22`）
- **两次未记录写入**（15:00–15:01 与 16:15:31/16:15:53），第二次是在 hook 明确活着的 4–7 秒间隙里发生的
- **被观测系统在观测期间对 harness 打了 6 次补丁并 seal 6 次**，我逐条复核了修复效果（附 D 状态矩阵）

**本次观测没有覆盖什么**（避免误读）：
- **没有执行 `sign-gate.ps1`、`verify.ps1`、`finish-step.ps1`、`append-event.ps1`、`seal-harness.ps1`，也没有跑 `status.ps1 -SyncStep`。**
  因此 O4-05 里关于 sign-gate 边界行为的结论**全部来自源码静态阅读**，已逐条标注（15:45 之后的版本又改过，静态结论以 13660B 版为准，仍未实测）。
- **没有观测到 3.1.3 关闭**。首次 verify（`seq 565`，07:49:44Z）红了之后，agent 又改了 12 次 `check_interface_impl.py`，
  但 `finish-step` 始终没跑（`docs/_diff/3.1.3/` 目录不存在，`local.json` mtime 停在 15:01:36）。
  所以 O4-02（步边界不落事件）在本次窗口内**只观测到 3.1.2→3.1.3 这一次实例**，没有再观测到第二次。
- 没有 Claude Code 的会话 transcript。台账里出现"某文件被改但无事件"时，**无法从台账本身判断是谁改的**——这本身就是 O4-01 的一部分，不是我偷懒。
- 教练（Trae）的输出按已知限制本地不留痕（obs#3 的 N3），本轮无从观测。
- 没有观测到 `deviate` / `blocker_open` / `blocker_close` 事件（全程 0 条），也没有观测到 Hermes 实际执行（台账只有 1 条 hermes 记录，在窗口之外）。

---

## O4-01 · critical · 契约文件被改 +2337 字节，台账/快照/差异三份证据产物同时漏记

**证据**

1. 磁盘与台账对不上（audit C7 已报，我独立复核为**真未记录写入**，不是路径规范化问题）：
   - 磁盘 `contracts/ip_provider_interface.py`：5678 字节，mtime `2026-11-07T15:01:00.635`，sha256 前缀 `3ad13fcd2810`
   - 台账最后一条记录：`seq 43`（`2026-11-07T02:59:19Z`），`Edit`，sha256 前缀 `949a5cd58bbe`
2. 字节级重建验证（这一步排除"规范化/编码差异"的可能）：
   取磁盘文件**前 74 行 + 结尾换行**，UTF-8 编码 = **3341 字节**，
   sha256 = `949a5cd58bbeafd6fad0cb5d11e633f06c41095743952f816c5b16d40c51bb3b` —— 与 seq 43 **逐字节完全一致**。
   → 磁盘现状 = 该 74 行原文 + 末尾追加 33 行注释块（75–107 行，+2337 字节）。
   → 结论：这是一次**纯追加**，与 `docs/变更记录.md` 里的自述完全吻合（见下）。文件本身没有其它改动。
3. 同窗口还有两次写入，同样零记录：

   | 文件 | mtime（本地） | sha256 前 12 | 台账最后记录 |
   |---|---|---|---|
   | `04-采集系统架构.md` | 15:00:29 | `510b34d9e19f` | **该文件在整个 526 条台账中从未有过任何 `data.file` 记录**（仅作为 Bash 命令字符串出现 10 次） |
   | `contracts/ip_provider_interface.py` | 15:01:00 | `3ad13fcd2810` | seq 43（`02:59:19Z`） |
   | `docs/变更记录.md` | 15:01:23 | `c99dff5b596d` | seq 507（`06:59:37Z`） |

4. 台账在这段窗口是**完全空白**：`seq 508` = `06:59:51Z`，下一条 `seq 509` = `07:01:25Z`。
   中间没有任何 `tool_use`——既没有 `Write`/`Edit`，也没有 `Bash`。
5. 三份独立的证据产物同时漏记同一个写入：
   - **PostToolUse 台账**：无记录（上条）；
   - **PreToolUse 快照清单** `docs/_snap/3.1.2/_manifest.json` 只列 4 个文件
     （`scripts/init_db.py`、`docs/变更记录.md`、`price_watch/pool/providers/direct.py`、`price_watch/pool/ip_factory.py`），
     **不含** `contracts/ip_provider_interface.py`，也不含 `04-采集系统架构.md`；
   - **finish-step 生成的差异** `docs/_diff/3.1.2/`：只有
     `docs__变更记录.md.diff`、`price_watch__pool__ip_factory.py.diff`、`price_watch__pool__providers__direct.py.diff`、`scripts__init_db.py.diff`，
     **没有**该契约文件的 diff，也没有 04 的 diff。
     （`finish-step.ps1` L105-146 只对 `_manifest.json` 里登记的文件出 diff，所以清单漏了 = diff 一定漏。）
6. 被测系统自己承认了这次写入。`docs/变更记录.md` 的「步骤 3.1.2（文档补记）」条目原文：
   > **修改的文件（均为纯追加）**：① `04-采集系统架构.md` §3.2 表尾新增 1 行 `R5a` + 1 个空行（仅此 2 行…）；
   > ② `contracts/ip_provider_interface.py` 末尾追加 31 行注释块（3341 B → 5678 B，+2337 B，上方 74 行原文逐字未动…）

   同时该条目还写「**未在预期清单内的操作**：无（未改 `price_watch/**`、`config/**` 其它契约文件…）」——
   即它把"改契约文件"排除在"预期清单外操作"之外，等于自己给自己开了豁免。

**为什么这是缺陷（而不是设计如此）**

- 项目第一原则是"日志是事实，任何 agent 说'我做完了'都不算证据"。这里的事实是：**一个契约文件被追加了 2337 字节，内容包括对契约与实现之间三处不同形的"差异登记"**（"IpLease 九字段是目标形状；本期落地快照是 Egress 的三字段"等），
  而台账里没有 `contract_change`、没有 `approved_by`、没有前后 digest、没有签名人。
- `contracts/**` 是本项目定义的"别人要照着写代码的层"。`trigger.ps1` 专门有 T2/T2b/T2c/T9 四条规则保护这一层，全部以 `contract_change` **事件**为输入。事件不存在，四条规则一起沉默。
- 后果不是"少一条日志"，而是**契约可以被单方面追溯修改并在事后宣布"这就是原意"**——这正是 T2c 注释里写要防的事（"a gate recorded elsewhere does not sign a change"）。
- 唯一抓到它的是 `audit` C7 的"磁盘 vs 台账 digest"比对。而 C7 的覆盖面只到 `project.json` 里各 stage 的 `generates`：`04-采集系统架构.md` 不在任何 stage 的 `generates` 里，所以 **04 被改了两次（15:00:29 的 R5a 追加，以及更早的历史）从头到尾没有任何机制发现**。

**建议方向**

1. 非 Claude Code 写入方（Hermes、人在编辑器里、任何 MCP 写入）需要一条落账路径：要么给 Hermes 装同样的 hook，要么在 `constitution.md` 里把"改完必须立刻 `append-event -Event contract_change`"变成硬性步骤，并由 audit 检查"diff 产物里出现的文件"与"台账里的 tool_use/contract_change"是否一一对应。
2. C7 的巡检范围应当独立于 `generates`：对 `contracts/**`、`.harness/project.json`、以及被 `AGENTS.md` 点名的权威文档（`04-采集系统架构.md` 等）做固定清单巡检，命中即 FAULT。
3. `finish-step` 的 diff 覆盖面有一个可检查的自我矛盾：manifest 漏了文件时它不会报警（L171 只在 manifest **完全不存在**时 WARN）。建议改成"本步台账里有 `tool_use` 的文件，若不在 manifest 里则 WARN"——这次事故正好会被这一条抓住。

---

## O4-02 · high · 步边界（唯一的状态迁移）不落任何事件

**证据**

- `.harness/local.json` mtime = `2026-11-07T15:01:36`，内容 `current_step: "3.1.3"`。
  即 3.1.2 在这一刻被关闭、下一步被置为 3.1.3。
- 台账在该时刻前后：`seq 509`（`07:01:25Z`，verify 3.1.2）、`seq 510`（`07:01:35Z`，verify 3.1.2），
  然后直接跳到 `seq 511`（`07:33:03Z`，seal anchor）。**没有任何"本步结束/签署/交接"事件。**
- 读源码确认机制：`finish-step.ps1` L221 是 `& status.ps1 -Root $Root -SyncStep -Quiet:$Quiet`，
  `status.ps1 -SyncStep` 负责写 `local.json`。`finish-step.ps1` 全文（224 行）只通过 `append-event.ps1 -Cmd` 产出**verify 事件**，自身不写任何事件。
- 已知旁证：`trigger.ps1` L187 的注释自己写着「step_end used to mark it, but nothing ever wrote step_end, so T3/T4 - which hung off it - could never fire」。也就是说作者知道"步边界没有事件"，并把规则改挂到 verify 上，但**没有补上边界事件本身**。

**为什么这是缺陷**

- 台账里 `step` 字段是全部下游规则的键：T3（越界）、T4（返工）、T5b（孤儿步骤）、T7（L2 无 gate）、C8（归属）、status（NEXT）。
  而这个键的取值来自 `local.json`，`local.json` 的唯一写者是不落事件的 `status -SyncStep`。
  → **规则依赖的字段，其变更历史不可审计。**
- 具体后果已经发生过一次并被记录在案：`seq 117` 的 human anchor 原文
  「local.json stayed 2.0.4 after finish-step at 13:39:38 … Every hook record therefore carried the stale step.
  Consequence: 2.0.4 collector_js.py has zero verify events in the ledger while 2.0.5 work is filed under it.」
  这证明"边界无事件 + step 字段滞后"已经真实污染过台账，而不是理论风险。
- 一个只读观测者（或未来的复盘者）无法只凭 `events.jsonl` 回答"3.1.2 是什么时候算完成的、谁认为它完成了、当时 diff 有没有人看过"。这直接违背"日志是事实，视图是投影"。

**建议方向**

`finish-step.ps1` 在推进 `current_step` 前后各写一条事件（例如 `event=anchor, data.name=step_end`，带 `from`/`to` 两个 step、verify 的 exit、diff 文件数、`why`），并让它成为 T3/T4 判定的权威边界，而不是靠 verify 事件反推。

---

## O4-03 · high ·【观测期间已被修复，但修复打偏了靶心】T3 用「全体 stage.generates 的并集」判越界 → 跨步改别人的文件永不触发

> **状态更新（15:46:00）**：`trigger.ps1` 在我报告后约 1 分钟内被改写并重新 seal
> （digest `b38fae412912` → `3197a2dd167a`，561 行 → 626 行，C10 `ba23b820f02b` → `5d5bcb21115f`）。
> 新增了 **T11_accepted_modified**（L251-277），注释原文：
> 「T3 is structurally blind to this: its whitelist is the UNION of every stage's generates,
> so any file any stage owns is always 'in scope' no matter which step is writing it.
> On 2026-11-07 that blind spot let 2.0.2's contract (contracts/ip_provider_interface.py) be rewritten
> under step 3.1.2 with no rule firing」。
> 实测 T11 立刻抓到一个此前不可见的真实案例：
> `T11_accepted_modified 3.1.2 scripts/init_db.py belongs to 3.1.1 (already verified), modified under step 3.1.2 with no contract_change`
> —— 这条是真缺陷，之前跑了几十轮没人报。
>
> **但 T11 对触发它的那件事本身依然沉默**：T11 的实现（L262-277）遍历的是 `tool_use` 记录，
> 而 `contracts/ip_provider_interface.py` 的那次改写**在台账里连一条 tool_use 都没有**（见 O4-01）。
> 实测本轮 trigger 输出里 T11 只出现 `scripts/init_db.py` 一条，**没有** `contracts/ip_provider_interface.py`。
> 也就是说：注释把它归因为"规则看不见有记录的东西"，而事实是"记录根本不存在"。
> 补规则不能替代补记录 —— O4-01 仍然是这里唯一的根因，且它现在多了一个后果（见 O4-13/O4-14）。

**证据**

- `trigger.ps1` L83-98：`$allGenerates += $gen0`，把**所有** stage 的 `generates` 累加成一个全局白名单。
- `trigger.ps1` L221：`if ($allGenerates.Count -gt 0 -and $allGenerates -notcontains $p)` —— 用全局并集判越界。
- `contracts/ip_provider_interface.py` 在 `2.0.1` 的 `generates` 里（`docs/_snap/2.0.1/_manifest.json` 含该条目可佐证它在 2.0.1 就被创建）。
  → 因此**在 3.1.2 名下改这个文件，永远不会被 T3 认为越界**。
- `trigger.ps1` L236：`if ($verifyPassed.ContainsKey($stp))` —— T4 只看事件自己的 `step`。事件记在 3.1.2（`local.json` 当时就是 3.1.2），
  → 也不会触发 2.0.1 的 T4。
- T2/T2c 只在存在 `contract_change` 事件时才有输入（L159-185）。没有事件 → 沉默。
- 实测结果：本轮 `trigger.ps1` 的 13 条里，**没有一条**与"3.1.2 改了 2.0.1 的契约文件"相关。审计只有 `audit` C7 抓到（且只抓到 digest 不符，不知道改了什么、谁改的）。

**为什么这是缺陷**

- 这与作者自己写在 L131-139 的洞察正面冲突：
  「Nor is any file: those same closing minutes also edit the PREVIOUS step's files (init_db.py fixups, a line appended to 变更记录)」——
  作者已经知道"收尾分钟会改上一步的文件"，把这个认知用在了 T7 的 `stepsWithEvents` 上，**却没有用在 T3 上**。
- T3 的设计意图（L197 注释："T3 and T4 ask about the AGENT's behaviour - scope creep and rework"）覆盖不到最主要的越界形态：跨步改别人的产物。
- 本次事故正是这个形态：契约属于 2.0.1，工作发生在 3.1.2，事实被三条规则同时放行。

**建议方向**

- T3 增加分支：写入路径属于 `stage X` 的 `generates` 而事件 `step` 是 `Y`（X≠Y）→ 报"跨步改动"。
- T4 的判定从"step 匹配 + 时间在 verify 之后"改成"写入路径属于该 step 的 `generates`，且该 step 的 verify 已通过"，并且**忽略 Bash 记录**（见 O4-04）。

---

## O4-04 · high ·【观测期间已被修复】T4_reworks 把"verify 之后的一条命令"当返工 —— 13 条告警里 2 条是误报

> **状态更新（15:46:00）**：同一批改动里 T4 加了双护栏（新版 `trigger.ps1` L278-297），注释直接点名了来源：
> 「Two guards, both added after observer #4 found 2 of 13 hits were noise:
> ① a record with no file is a shell command, not a write … running an acceptance command after passing counts as rework.
> ② the file has to belong to the step that is reworking it … seq 37-53 carry step=2.0.1 while writing contracts/*.py,
> which are 2.0.2's deliverables: that is a mislabelled record, not rework」。
> 实测：本轮 trigger 里两条 `T4_rework` 已全部消失（13 条 → 12 条，T11 补回 1 条）。
> 这条修复是正确的、完整的（`if ($f -ne '' -and ...) { $ownsThis = ... }` 两层条件都对得上根因）。
> 保留原文作为缺陷成因记录。

**证据**（逐条溯源，`trigger.ps1` 报了 `T4_rework 2.0.1` 和 `T4_rework 3.1.1`）

- **3.1.1 那条**：3.1.1 的首个 pass verify 在 `seq 271`。紧随其后的 `seq 272` 是一条 **Bash**（不是文件写入），
  T4 的分支（L235-242）不检查 `data.file` 是否存在，只要 `event=tool_use` 且 `observed_by=hook` 且 `$verifyPassed` 有这个 step 就算"written again"。
  → 因为 agent 在 verify 之后又跑了一条验收命令，就被记成"返工"。
- **2.0.1 那条**：2.0.1 的首个 pass verify 在 `seq 35`；此后仍然带 `step=2.0.1` 的 hook 记录是 `seq 37–53`。
  这 17 条里 `seq 38/39/40` 写的是 `contracts/provider_interface.py`、`contracts/ip_provider_interface.py`、`contracts/account_pool_interface.py`
  —— 这三份是 **2.0.2** 的交付物（`2.0.2` 的 goal 就是"三份接口契约"）。
  → 事实是"2.0.2 的活在 `local.json` 仍写着 2.0.1 时被干了"，不是"有人在返工 2.0.1"。
- 佐证作者已经承认过这类错记：`seq 117` 的 human anchor 记录 2.0.4→2.0.5 的同类污染（见 O4-02）。

**为什么这是缺陷**

- 这是"规则误报"，而误报的代价是训练人忽略告警：当前 `Hermes needed: 13 item(s)` 里，2 条 T4 是假的，
  6 条 T3 是永久无法处置的历史（见 O4-06）。**13 条里能真正推动动作的只剩少数几条**，人自然学会跳过。
- T4 的语义是 "written again"，但实现是 "recorded again"。作者在 T7 的 `stepsWithEvents` 上明确写过
  「A shell command is not evidence」，在 T4 上却按命令计数——同一份文件里两套标准。

**建议方向**

T4 至少加两个条件：① `data.file` 非空且在 profile 里被某个 stage 声明；② 该文件属于**当前事件 step 的** `generates`。③ 对 Bash 记录不计。

---

## O4-05 · high · 人类侧接口只修了一半：`sign-gate.ps1` 上线 16 分钟才被用上（唯一一次，`why` 是 `"y y"`），且只覆盖 9 条人工事件里的 2 条

> **状态更正（15:38→16:18）**：我最初的结论是"上线后 0 次使用"。15:49:17 出现了第一条 gate（`seq 564`），
> 所以更准确的说法是：**上线后 16 分钟被用上 1 次**。这条记录 `by="elu9527-sudo"`，
> 而 `sign-gate.ps1` L98-105 的 `-By` 回退链是"参数 → `git config user.name` → `'human'`"，
> 本项目不是 git 仓库但 `git -C <非仓库> config user.name` 会读全局配置 —— `elu9527-sudo` 很可能就是这台机器的全局 git user.name。
> 因此这条**很可能**确实是 sign-gate 产生的（无法完全排除手打 JSON，台账不区分）。
> 即便是，它产出的 `why` 是 `"y y"`（见 O4-16），**唯一一次使用就产出了一条不可复原的决策记录**。
> 下面第 1 条的"0 次"应以本段为准。

**证据**

1. **上线后没被用过**：台账 `event=gate` 只有 `seq 248`（`06:20:25Z`）和 `seq 409`（`06:49:09Z`），
   都早于 `sign-gate.ps1` 的落地时刻（`seq 519` 的 seal 记录时间 `07:33:06Z`；文件 mtime `15:32:16`）。
   观测期间台账从 526 增到 528，仍然没有 gate 事件。→ **上线 30 分钟，使用 0 次。**
2. **覆盖面只有 gate 一类**：`sign-gate.ps1` L249 硬编码 `-Event gate -Actor human`；
   L203-208 构造的 `data` 只有 `{level, status, by, why}` 四个字段。
3. **人本会话手写过的其它决策事件，全部仍要手打 JSON**：

   | seq | actor | event | 手打内容的难点 |
   |---|---|---|---|
   | 68 | human | contract_change | 需要 `before_sha256` / `after_sha256` 两个 64 位 hex + `approved_by` |
   | 69 | human | contract_change | 同上 |
   | 273 | human | contract_change | 同上 |
   | 71 | human | anchor | 自由结构 `{name,value,why}` |
   | 117 | human | anchor | 自由结构 + 长 `why` + `evidence` |

   → 9 条人工事件里，sign-gate 只覆盖 2 条（都是最简单的）。**最难手打、最需要转义保护的那 3 条 `contract_change`，一个字节都没被简化。**
4. **T2c 正在要求补签的正是这类**：`trigger.ps1` 报
   「T2c_unsigned_contract 2.0.1 1 contract change(s) on record carry no approved_by (e.g. '.harness/project.json')」。
   补签要么改历史（哈希链不允许），要么新写一条带 `approved_by` 的事件——同样得手打 JSON。
5. **它没被执行过就被 seal 了**：`seq 519` 把 `sign-gate.ps1` 以 `tool:"seal"`、`before_sha256:""`（新建文件）写进台账，
   并计入 C10 harness digest `ba23b820f02b`。按本项目自己的标准「一个从没被见过失败的检查，等于没被证明能失败」，
   这个专门用来消除"粘贴失败"的脚本，**从未被证明能跑通一次**。

**源码静态阅读得到的三条边界问题**（未实测，标注为静态推断）

- **取消 = 退出 0，与成功无法区分**：L232-237，`Read-Confirm` 返回假时打印 `[cancel] 未写入。` 然后 `exit 0`；
  成功签名在 L258-261 也是 `exit 0`。任何用退出码判断"签没签"的调用方都会把取消当成功。
  （`-DryRun` 也是 `exit 0`，L229，同一问题。）
- **`-Yes` + 重定向输入会静默放行**：L169-174，`[Console]::IsInputRedirected` 为真时 `Read-Confirm` **直接返回 true**，
  注释里写明"treated as yes"。即 `"原因" | pwsh -File sign-gate.ps1` 会跳过确认直接落账。对脚本友好，但一个手滑的管道就把确认环节去掉了。
- **签错 step 不会被拦住**：L108-119 只从 `local.json` 读 `current_step` 做**预览**；真正的 `step` 由 `append-event.ps1` 再从 `local.json` 取。
  两者同源所以预览不会说谎，但**如果 `local.json` 已经指向下一步而人想签的是上一步，gate 会静默落到错误的 step 上**，
  sign-gate 只显示、不让人确认 step。当前 `local.json` 已经是 `3.1.3`，而 `2.0.2` 那条 T7 还挂着——正是容易签错的时刻。
- （多行原因会被 `L192` 用空格拼成一行；`-Why` 走 argv 的 CJK/引号风险 docstring 自己已声明。）

**建议方向**

- 把 `contract_change` 和 `anchor` 也做成交互式：`before_sha256` / `after_sha256` 由脚本从磁盘和台账现算并回显让人核对，人只需要回答"改了什么、为什么"。
  `append-event.ps1` L272 已经会在 gate 缺 `-DataJson` 时打印正确用法，`sign-gate` 的交互化和它是同一个模式，可以复用。
- 退出码分三态：0=已签、4=取消、2=参数错。取消不应当是成功。
- 在 `seal-harness` 里加"新脚本必须有一次实测记录"的前置（例如 `-DryRun` 的自我断言），否则 C10 把一个没跑过的脚本钉成了"已复核"。

---

## O4-06 · medium · `trigger` 的队列没有窗口也没有"已处置"状态 → 13 条里 6 条是永久的死噪声

**证据**

- 本轮 `trigger.ps1` 的 13 条 T3/T2 噪声分布：
  - `T3_out_of_scope` 6 条全部来自 `2.0.1` / `2.0.3` 的 `%TEMP%` 自检脚本：
    `seq 41/45 prchk_check_contracts.py`、`seq 46 prchk_sigs.py`、`seq 78 launcher_selftest.py`、`seq 84/85 collector_selftest.py`
    （全部是 `observed_by` 字段出现之前的老记录）。
  - `T2_contract` 4 条来自历史 `contract_change` 事件（`seq 34/68/69/273` 的聚合）。
  - `T2c_unsigned_contract` 1 条来自 `seq 34`（actor=`claude`，无 `approved_by`）。
  - `T4_rework` 2 条是误报（见 O4-04）。
- `pre-tool.mjs` L82-92 已经把"写项目外路径"改成**硬拒绝**（`exit 2`），所以那 6 条 T3 **不可能再发生**，
  但它们会永久留在队列里——`trigger.ps1` 从全量台账推导，没有任何时间窗、没有 `acknowledged` 标记。
- 只有 1 条 `T3` 是真正可处置的：`seq 478 price_watch/pool/providers/__init__.py`，
  这个文件是包的标记文件、确实存在于磁盘，但 `3.1.2` 的 `generates` 里只写了 `providers/direct.py` 和 `providers/reserved.py`。
  → **规则没算错，是 profile 少声明了一个文件。**
- 作者自己写下过这条教训（`trigger.ps1` L372-378）：「re-reporting it every run keeps the rule permanently red and trains everyone to ignore it」，
  并对 T2c 做了"聚合成一条"的处理，但没有把同样的处理推广到 T3/T4。

**为什么这是缺陷**

`trigger` 的唯一消费者是 Hermes（文档 agent）。当 13 条里 8 条是历史噪声或误报时，Hermes 要么把噪声写进文档、要么学会忽略整份清单——
两种结果都让这个"声明与裁决分离"的设计失效。

**建议方向**

给每条 trigger 一个稳定的 key（已有 `$key` 机制）+ 一个 `ack` 事件类型（人签"这条我看过，不处置，理由是…"），
或至少按 `step >= current_step` 过滤历史（T10 已经这么做了，L464-465 注释写得很清楚："re-reporting them forever is how a check gets ignored"）。

---

## O4-07 · medium · T2b（profile 基线漂移）是结构性死代码：只要有历史 contract_change 就永久不检查

**证据**

- `trigger.ps1` L352-355：
  ```
  # skip when an explicit contract_change event already reported it
  $alreadyReported = $t2Agg.Count -gt 0
  if (-not $alreadyReported -and (Test-Path ...)) { ... 比对 local.json 的 project_sha256 ... }
  ```
  `$t2Agg` 是**全历史** contract_change 的聚合表。
- 本台账有 4 条 contract_change（`seq 34/68/69/273`），所以 `$t2Agg.Count > 0` 恒真 →
  **L355 之后的分支在本项目里永远不会执行**。
- 实测：`project.json` sha256 = `289a595ebd7d...`，`local.json` 的 baseline = `289a595ebd7d...`，当前一致。
  也就是说 `validate-profile -SyncBaseline` 维护的这个基线（`seq 55` 的 hermes anchor 就是在维护它）
  **被维护、但从不被比对**。
- 这条规则只在"一个从来没记录过任何 contract_change 的项目"上才会跑；而那种项目恰恰是不需要它的项目。

**为什么这是缺陷**

`finish-step.ps1` L217-220 明确写着这个基线存在的理由：
「project_sha256 is deliberately NOT resynced here. Silently accepting a new baseline would let a weakened verify command become 'the new normal' with nobody noticing.」
—— 一个用来防"悄悄削弱 verify 命令"的检查，被它自己的前置条件永久关闭了。
这会真实发生的场景：有人改 `project.json` 把某步的 `verify` 从 3 条改成 1 条、或把 `risk` 从 L2 改成 L1，不写 `contract_change`，
则 T2b 不说话（被跳过）、T2/T2c 不说话（无事件）、T3 不说话（`.harness/` 在 L226 被排除）、只有 audit C7 可能抓到
（如果 `project.json` 在某个 `generates` 里——它不在，所以 C7 也抓不到）。

**建议方向**

把 `$alreadyReported` 从"全局有没有过 contract_change"改成"**这次 digest 差异**有没有被某条 contract_change 的 `after_sha256` 覆盖"：
即比对 `project.json` 当前 sha 是否等于台账里**最后一条** contract_change 的 `after_sha256`，不等就报。这样既不重复报，也不会永久关闭。

---

## O4-08 · medium · C9 长期空转：文档承诺只记 `D-NNN` 决策，实际 0 条

**证据**

- `audit.ps1` 输出：`! C9 decisions  变更记录.md is 31875 bytes and contains no D-<seq> heading - C9 had nothing to check, so its passing proves nothing (a check with an empty input set has not passed, it has not run)`
- 独立复核：`Select-String 'D-\d{3}' docs/变更记录.md` → **0 命中**；`C9 0 record(s) checked against the ledger`。
- `docs/变更记录.md` 第 8 行自述：「本文件从 2026-11-07 起只记**决策**（`D-NNN`），流水由 hook 写入 `events.jsonl`。」
- 文件的实际结构是 `## 1. 变更记录表`（C-001 表格）、`## 2. 每步操作报告`（`### 步骤 X：…`），**没有 D-NNN 章节**。

**为什么这是缺陷**

文档自己声明了一种格式，audit 自己写下了"空输入集不算通过"这句话，然后把它降级成 WARNING 而不是 FAULT。
结果是一个**声明与实现互不约束**的循环：文档不按 D-NNN 写 → C9 没东西可查 → C9 不失败 → 没人被要求修正文档格式。
这正好落在本项目"检查必须能失败"的原则外面。

**建议方向**

要么把 C9 的输入定义改成实际存在的结构（例如 `## 4. 上游契约变更` 与台账 `contract_change` 事件对账），
要么把"本文件只记 D-NNN"这条承诺改成文档现状，并让 C9 在"声明了 D-NNN 却 0 条"时升为 FAULT。

---

## O4-09 · medium · 3.1.2 的 verify 只证明"能 import"，C5 判 pass 会高估验收强度

**证据**

- `project.json` 里 `3.1.2` 的 verify 是：
  `.venv\Scripts\python.exe scripts\check.py import price_watch.pool.ip_factory price_watch.pool.providers.direct price_watch.pool.providers.reserved`
- 台账 `seq 509` / `seq 510` 两条该命令的记录：`exit:0, trivial:false, real_test:true`，
  `stdout_tail` 是 3 行 `[ok] import: …`。
- `audit` C5 因此把它记为 `3.1.2=pass`。
- 但 `3.1.2` 的 goal 是"账号池 + IP 池 + 预留位"，其语义（`create_provider` 的 fail-fast、`build_proxy_args` 的唯一下发口、
  `Egress` 三字段、reserved 分支 raise NotImplementedError）**一条都没被这条命令断言**。
- 被测系统自己在 `docs/变更记录.md` 里承认：「① 本步断言全部跑过但**没有可重跑的落盘测试**（边界不许建 tests/），
  4.1 补测试时须把这 33 项固化」。即那 33 项断言是**内联执行的、不可复现的**。
- 另注：`seq 509` 与 `seq 510` 是同一命令相隔 10 秒的两次执行（一次可能是人跑的、一次是 `finish-step` 自己调的 L201），
  两条都记成一次独立的 pass——`status`/`audit` 不区分"重复执行"与"新的证据"。

**为什么这是缺陷**

三态判定的定义是 `PASS = exit=0 且 trivial=false 且 real_test=true`。这条命令确实不是 trivial（hook 的 `isTrivialCommand` 不会把它判 trivial），
所以从定义上它是 PASS。但"能 import 三个模块"对一个"实现了取用/回收语义"的步骤来说，是**极弱的断言**：
把三个文件写成空的 `def acquire(): pass` 也能 PASS。
按本项目"检查必须能失败"的标准，这条 verify 无法区分"实现正确"和"实现是空壳"。

**建议方向**

把 verify 的多断言能力真正用起来（`project.json` 的 `verify` 已经支持数组，3.1.1 就用了 3 条）；
或要求凡是 `risk: L2` 的 stage，verify 必须包含至少一条**行为断言**（不是 import），否则 C5 不给 pass、只给 `weak`。

---

## O4-10 · medium · L2 风险门形同虚设：3.1.3 未签 gate 已开工

**证据**

- 本轮 `trigger.ps1`：`T7_risk_L2 3.1.3  stage 3.1.3 is L2 and is the stage status.ps1 is pointing at, but no gate is on record - sign it BEFORE the step starts, not after`
- `status.ps1`：`NEXT 3.1.3 预留位自检脚本 / risk L2`
- 台账 `seq 528`（`07:41:16Z`）：`step=3.1.3`，`tool_use Write scripts/check_interface_impl.py`，`before_sha256=""`（新建）——
  这是 3.1.3 唯一的 `generates`，**已经落盘**。
- 同期 `2.0.2` 的 T7 从它 verify 通过（`seq 64`，`03:44:22Z`）至今约 **3 小时 57 分钟**无人签。

**为什么这是缺陷（流程层面，不是代码缺陷）**

T7 的注释写得很清楚这是"front gate"：`Without case 2 the rule can only speak after the irreversible thing has been done, which is exactly backwards for a risk gate.`
规则确实在"开始之前"就报了（15:00 起的每一轮都在报），**但没有任何机制阻止开工**：没有强制 `verify.ps1` / `hook` 在 gate 缺失时拒写。
于是 T7 = 一个只出声不阻截的门。这对本项目的意义是：**"人签字关卡"这个角色在事实上不存在**，只有一条被忽略的告警。
这条我按"观测到的事实"报告，不主张改法——但如果要让它有牙，需要在写 `generates` 时检查本 stage 是否有 gate。

---

## O4-11 · low · hook 与 append-event 对同一个锁有两种失败语义（一个静默、一个报错）

**证据**

- `post-tool.mjs` L36-76：抢 `events.jsonl.lock`（`openSync(lockPath,'wx')`）最多 30 次 × ~100ms ≈ 3 秒，
  失败后 `return false`；`main()` 的返回值无人检查；`process.stdin.on('end')` 里 `try{main()}catch{}` 然后 `process.exit(0)`。
  **没有任何"我丢了这条记录"的输出或计数。** 注释 L33-35 自己写着「a missed tool_use is recoverable (the file digest still moves and C7 reports the drift)」。
- `append-event.ps1` L360-379：同样的锁文件，最多 100 次重试，失败时
  `[FAIL] could not lock … within 10s - another writer looks stuck` 并走失败分支。
- 两份实现的重试预算也不同（3 秒 vs 10 秒），且 hook 侧还有一条 `60 秒` 的陈旧锁自动删除规则（L45）与 append-event 的 L369-371 逻辑各自独立。

**为什么这是缺陷**

台账的不变量是"没有记录 = 没发生"。现在"没有记录"有三种可能：没发生 / hook 抢锁超时丢了 / hook 因其它原因静默 return。
后两种都无法从台账区分，也没有任何计数器能暴露它们的存在。
O4-01 里那个 54 秒的空白窗口，**恰好符合"hook 丢了三条记录"的形态**（虽然我倾向于是非 hook 写入方，但从台账无法证明——这正是不变量被破坏的后果）。

**建议方向**

hook 抢锁失败时写一条降级记录（例如直接追加到 `.harness/hook-lost.log`，或写一条 `event=tool_use, data.degraded=true`），
并让 `audit` 增加 C11："本会话丢失计数 ≠ 0 → WARN"。同时把两侧的超时预算统一成一个常量。

---

## O4-12 · low · 文档自述与实际不符（次要，附在 O4-01 后）

`docs/变更记录.md` 的补记条目写"末尾追加 **31** 行注释块"，实际追加是**33** 行（75–107 行，其中 75 是空行、76–107 是注释块）。
字节数（3341→5678，+2337）是对的，行数差 2。说明这段自述是人工估的，不是机器数的——
在一个人工叙述驱动审计的系统里，这类小偏差会累积成"文档说 A、台账说 B"的常态。

---

## O4-13 · high · `before_sha256` 在漏记之后指向"两个版本之前"，同一条事件的两个 before 证据互相矛盾

**证据**（这是 O4-01 的直接后果，但它本身是一个独立缺陷）

- `post-tool.mjs` L204-221 定义 `data.before_sha256` 为"这次写入之前该文件的 digest"，取值来自
  `lastShaByFile`（= 台账里该路径**最后一条已记录**的 `sha256`）；台账里没有时才退到 `_snap` 快照。
- 台账 `seq 545`（`07:45:00Z`）：`Edit docs/变更记录.md`，
  `before_sha256 = 7f3a4bbce438...`（= `seq 507` 记录的版本）。
- 但磁盘上该文件在这次编辑之前的真实内容，是 `15:01:23` 那个**未被记录**的版本，
  sha256 = `c99dff5b596d...`。
- 同一时刻 PreToolUse 生成的 `docs/_snap/3.1.3/docs__变更记录.md.before`（31875 B，mtime 15:01:23）
  我实测其 sha256 = **`c99dff5b596d`** —— 即快照拿到的才是真的"之前"，台账字段拿到的是"两个版本之前"。
- 结果：**同一次写入的两份证据对"之前是什么"给出两个不同答案**
  （`data.before_sha256`=7f3a4bbce438 vs `_snap` 镜像=c99dff5b）。

**为什么这是缺陷**

`post-tool.mjs` L205-215 的注释明确说这个字段有两种早先的错误定义，都被改掉了，理由是
「On the second write of a file within one step it reported the pre-step image again, so the ledger claimed the same
before-digest twice and the individual change between them was unrecoverable (obs3 D5)」。
现在换成"取台账最后一条 digest"，**在漏记存在时退化成同一个病**：`7f3a4bbce438 → c99dff5b → bee3fe64` 三段变化，
台账只表示成 `7f3a4bbce438 → bee3fe64` 一段，中间那段（15:01:23，1500+ 字节的新增章节）在台账里**不留任何痕迹**。
"can I reconstruct what changed" 这个问题，在这个文件上答案是不能。

**建议方向**

`before_sha256` 不应从台账推导（台账可能缺记录），而应直接取 PreToolUse 写下的快照镜像的 digest ——
即 `sha256File(snapPath)`，而快照的第一张（`if (!existsSync(snapPath)) copyFileSync`，pre-tool.mjs L112-114）
恰好保存了"这一步开始时"的真实状态。现在的实现只在台账缺记录时才用它，正好把最可靠的证据放在了兜底位置。
若担心"同一步第二次写入"的问题（obs3 D5），可以两者都记：`before_sha256`（本次之前）+ `step_before_sha256`（本步开始前）。

---

## O4-14 · high · C7 的 FAULT 会被"下一次正常写入"自动洗掉，不留任何痕迹

**证据**

- 轮 1（15:38）`audit`：`FAULTS (2)`，含
  `C7 0.1 docs/变更记录.md on disk (c99dff5b596d) does not match the ledger (7f3a4bbce438) - a write happened that no event records`
- 轮 4（15:47）`audit`：`FAULTS (1)`，**0.1 那条已经消失**，`C7 drift 2 drifted → 1 drifted`。
- 消失的原因不是有人解释了这次写入，而是 `seq 545`（15:45 的一次**普通编辑**）把 digest 重新登记成 `bee3fe648e36`，
  于是"磁盘 vs 台账最后一条"重新相等。
- 同一时刻 `status.ps1` 的 `HISTORICAL GAPS` 从 8 条降到 7 条（`drifted 0.1` 那条也消失了）。
- 台账中该文件的历史从此读作 `7f3a4bbce438 → bee3fe648e36`，`c99dff5b` 这个人造的中间版本在台账里**永久不存在**。

**为什么这是缺陷**

C7 的文案宣称的是"a write happened that no event records"（一次没有任何事件记录的写入），
但它的实现（`audit.ps1` L368-383）只是"磁盘当前 digest ≠ 台账最后一条 digest"。
这是一个**瞬时不一致检测**，不是**未解释写入检测**。任何一次后续合法写入都会让它恢复绿色，
于是"曾经发生过一次无记录写入"这件事在系统里**没有任何持久表示**。
对一个自称"日志是事实"的系统，这是把一次证据链破损变成了不可见的历史。

**建议方向**

把"未解释写入"变成台账里的一个持久事实：C7 命中时不要只在屏幕上打印，而是落一条事件
（例如 `event=deviate, data.what="unrecorded write to X", data.before_ledger=..., data.actual=...`），
这样它会进 T1（deviate 触发器）并要求人处置；或者至少把命中记录追加到 `.harness/drift-log.jsonl` 并让 C7 读历史。
现在的行为等于：警报一响，下一次心跳就自动把它撤销。

---

## O4-15 · medium · harness 自身被改了什么，台账里只有 digest，没有内容、没有理由

**证据**

- 观测窗口内 harness 被改了：`trigger.ps1`（`15:46:00`）、`sign-gate.ps1`（`15:45:10`），
  并各触发一次 seal：`seq 558`（`3197a2dd167a`，前值 `b38fae412912`）、`seq 556`（`8488c44bfef0`，前值 `ed083667b164`）。
- 全台账 563 条里，`.harness/derive/*.ps1` 只有 `tool:"seal"` 的 tool_use，**没有任何 `Write`/`Edit` 记录**
  （`trigger.ps1` 一个文件就有 23 条 seal，涉及 12 个不同 digest，从 `c3cfe3b94d39` 到 `3197a2dd167a`）。
- 每条 seal 的 `why` 都是同一句模板文案：`"pinned by seal-harness (harness digest pinned after review)"`
  或 `"harness digest pinned after review"`。**"reviewed" 的是哪几行、为什么改，一句都没有。**
- `docs/_snap/` 与 `docs/_diff/` 里**没有任何 `.harness` 相关条目**（我全量搜索过），
  即 finish-step 的 diff 机制对 harness 自身不生效。
- 反证：C7b（`audit.ps1` L500-520）确实能发现"harness 在 seal 之后被替换"，但它只报 digest 变了并提示 "re-seal"，
  而 re-seal 一次就又干净了 —— 和 O4-14 是同一个病。

**为什么这是缺陷**

这个项目的交付物之一是"可复盘的证据链"。度量层本身的演进（触发规则从 561 行变成 626 行、新增一条会把历史判红的规则）
是不可复盘的：只有 12 个不透明的 digest。任何后来者问"T11 是什么时候、为什么加进来的、当时谁审的"，
台账答不上来。而 T11 这样的规则会直接改变历史判定（它让 3.1.2 从"没问题"变成"有一处接受产物被改"），
这类改动比业务代码的改动**更需要**留理由。

**建议方向**

seal 的 `why` 应强制由人填写，至少写清"改了哪几条规则、为什么"；或者让 `seal-harness.ps1` 在 seal 前把改动写成
`docs/_diff/harness/<digest>.diff`（它已经在用 `git diff --no-index`，对 harness 目录跑一次即可）。
另外 `T11` 这类"会让历史翻红"的规则上线时，应当同时落一条 `decision` 事件说明生效时间点，
否则历史台账在不同版本的 trigger 下会给出不同结论（本次已经发生了：同一份 563 条台账，15:38 版 trigger 报 13 条，15:48 版报 12 条但换了内容）。

## O4-16 · high · 第一次真正的 gate 签名，记下的理由是 `"y y"` —— 两个字符关掉了 L2 风险门

**证据**

- `seq 564`（`2026-11-07T07:49:17Z`），`step=3.1.3`，`kind=decision`，`actor=human`，`event=gate`，完整 `data`：
  ```json
  {"level":"L2","status":"approved","by":"elu9527-sudo","why":"y y"}
  ```
  这是本台账 **第 3 条 gate**，也是 `sign-gate.ps1` 上线（`07:33:06Z`）之后的**第一条**。
- 时序上它并不是"步前门"：
  - `07:41:16Z` `seq 528` `Write scripts/check_interface_impl.py` —— 该步唯一交付物已落盘
  - `07:41:44Z`–`07:43:05Z` `seq 529-539` 连续改写该文件
  - `07:49:17Z` `seq 564` **签 gate**（比交付物落盘晚 **8 分 1 秒**）
  - `07:49:44Z` `seq 565` 首次 verify → **exit 1，`RESULT FAIL 22`**
- 签名之后，`trigger.ps1` 里的 `T7_risk_L2 3.1.3` 立刻消失（15:48 版 12 条 → 15:53 版 11 条，少的正是这条）。
- `sign-gate.ps1` 与 `append-event.ps1` 都**不校验 `why` 的长度或内容**：
  sign-gate 只在 `IsNullOrWhiteSpace` 时拒绝（L195-200），`"y"` 或 `"y y"` 一律通过；
  append-event 的 gate 分支也没有任何质量检查（全文搜索无 `Length -lt` 类判断）。
- 反过来看，同一个 `why` 字段在历史 gate 里是有含义的：
  `seq 248` `"3.1.1 建 SQLite 全表 + init_db 迁移；库是本地文件，删掉可重建"`、
  `seq 409` `"账号池/IP池工厂接口会被4.x复用，确认按预留位设计"`。
  `"y y"` 与这两条不是一个东西，但系统无法区分。

**为什么这是缺陷**

`sign-gate.ps1` 的设计意图（其 docstring 第 6-30 行）是把人从"机器语法"里解放出来，
"so a pasted quote stays a quote"。它做到了。但它**只解决了转义问题，没有解决"这一栏要填什么"**：
签名记录的全部价值就在于几个月后能复原"当时接受了什么、为什么"（sign-gate 自己在空原因时的报错文案就是这么写的：
`签一个不说清「接受了什么、为什么」的字关卡，几个月后没人能复原它当时挡的是什么。`）。
现在这个字段被两个字母填满，而 T7 认为该 L2 步已被批准。
`"y y"` 极可能是把确认提示（`确认签名？[y/N]`）的回答误打进了原因输入（原因提示是 `> `，
两个提示紧挨着、都以键盘输入结束、都没有回显校验）。**无论人的本意是什么，这条记录都已经不可复原。**

**建议方向**

- 在 `sign-gate` 里对 `why` 做最低质量门槛：例如去空白后长度 < 8 或全部由单字符重复组成时重新提示，
  并在 `append-event` 的 gate 分支做同样的校验（不能只靠前端）。
- 把"原因"和"确认"两个提示在视觉上彻底分开（原因用多行块、确认要求输入 `yes` 而不是 `y`），
  或干脆去掉确认步（原因本身就是确认），减少两个相似输入框。
- 给 gate 记录加上"针对哪个产物/哪个 verify digest"的字段——参考 `seq 564` 之后 `seq 565` 就 FAIL 的事实，
  一条 gate 若绑定当时的 verify 结果，"批准了一个当即红掉的步"这件事在台账里就看得见。

---

## O4-17 · medium · 同一份证据，`audit` 判 pass、`status` 判 verify_mismatch —— 两个派生视图互相矛盾

**证据**

- `audit.ps1` C5：`1.1=pass`
- `status.ps1` HISTORICAL GAPS：
  `verify_mismatch  1.1  evidence ran '.venv\Scripts\python.exe -c "import yaml; print('yaml ok')"' but profile declares '.venv\Scripts\python.exe -m pip check'`
- 台账实证：`1.1` 只有一条 verify 记录 `seq 2`，`cmd = .venv\Scripts\python.exe -c "import yaml; print('yaml ok')"`，`exit 0`，`trivial=false` → 按三态定义是 PASS。
- 而 `project.json` 里 `1.1` 的 verify 是 `.venv\Scripts\python.exe -m pip check`。
  这条命令**从未在台账里出现过一次**。
- `audit.ps1` C5 的实现（源码注释 L59-71 已写明）只做"per stage: latest verify = pass|FAIL|VOID|none"，
  **不比对"跑的命令"与"声明的命令"**。

**为什么这是缺陷**

项目自己的声明是"三个视图，三个问题"，前提是它们**对同一事实不能给出不同答案**。
`verify.ps1` 的 docstring（L9-12）描述的正是这种病：
「someone wanted to check one stage, ran the command straight in a terminal, pasted the green into a chat,
and the ledger never learned about it. … Three views, three answers, all defensible.」
现在同样的三视图分裂以新的形式回来了：台账里的证据不是 profile 声明的验收命令，
而 C5 依旧给它 `pass`。这意味着**"某步验收通过"这个结论可以被一条与该步声明无关的命令产生**。
更糟的是这条命令（`import yaml; print('yaml ok')`）在语义上属于 `0.1` 那类"证明库能导入"，与 `1.1`（依赖清单）无关。

**建议方向**

C5 增加一条与 status 同源的比较：该 step 最新 verify 的 `cmd` 必须（规范化后）等于 profile 声明的 verify 列表之一；
不等时 C5 记为 `mismatch` 而不是 `pass`（status 已经算出这个结论了，只是没有传给 C5）。
两者应共用同一个判定函数，而不是各写一套。

---

## O4-18 · medium · 12 个 `[x] DONE` 里 5 个没有任何"可失败"的证据，`status` 同时打勾又标注无证据

**证据**（`status.ps1` 同一次输出里两段自相矛盾）

```
DONE
  [x] 0.0    harness 验证器 check.py
  [x] 0.1    文档入口重构（00 → AGENTS.md）
  [x] 1.1    虚拟环境与依赖清单
  [x] 1.2    凭据模板与 git 忽略规则
  [x] 1.4    Chrome 启动器 + CDP 验证
  ...
HISTORICAL GAPS (7) - reported only, do NOT block progress
  · done_without_evidence  0.0  all files exist but no passing verify…
  · done_without_evidence  0.1  verify only ever ran trivially (trivial=true)…
  · done_without_evidence  1.1  all files exist but no passing verify…
  · done_without_evidence  1.2  all files exist but no passing verify…
  · done_without_evidence  1.4  all files exist but no passing verify…
```

逐条核对台账：

| step | 台账 verify 记录 | 结论 |
|---|---|---|
| 0.0 | 0 条 | 无证据 |
| 0.1 | 1 条 `seq 1` = `echo ok`，`trivial=true` → VOID | 唯一证据是"不能失败的检查" |
| 1.1 | 1 条 `seq 2`，但命令不是声明的那条（见 O4-17） | 证据与声明不符 |
| 1.2 | 0 条 | 无证据 |
| 1.4 | 0 条 | 无证据 |

**为什么这是缺陷**

`[x]` 是一个裁决（"这步完成了"），而它在这里的判据是"文件在磁盘上"。
项目的第一原则是"执行者只能声称，只有脚本能出裁决"——但 `status.ps1` 的 `[x]` 恰恰是**用文件存在代替了裁决**。
同一屏里 `[x] 0.1` 与 `· done_without_evidence 0.1` 并列出现，读者只能挑一个相信。
这不是"历史遗留"，因为它一直在给下游提供错误前提：`T10` 用"products on disk + no passing verify"判断抢跑，
而 `status` 用"products on disk"判断完成——同一条事实，两种裁决，就藏在两个脚本里。
（我理解 `HISTORICAL GAPS` 的注释写了 "reported only, do NOT block progress"，那是**有意不阻塞**；
缺陷不是"不阻塞"，而是**`[x]` 这个符号没有携带"有证据/无证据"的区分**。）

**建议方向**

`[x]` 分两档：`[x]`（有 pass 的 verify）与 `[~]`（文件齐但无可失败证据），
让一行输出就能回答"这步到底凭什么算完成"。这条改动 0 风险，只是把已有的信息从下往上搬。

---

## O4-19 · low · 观测窗口内被观测系统被连续修改（记录在案，用于解释本报告的视图差异）

| 时刻 | 文件 | digest 变化 | 大小变化 | 我能看到的后果 |
|---|---|---|---|---|
| 15:45:10 | `sign-gate.ps1` | `ed083667b164` → `8488c44bfef0` | 10927 → 13660 B | 未知（无 diff、无 why） |
| 15:46:00 | `trigger.ps1` | `b38fae412912` → `3197a2dd167a` | 27218 → 31229 B | 新增 T11、T4 双护栏 |
| 15:51:14 | `verify.ps1` | `d14fc9bf2f22` → `42a5879699ab` | 7090 → 7950 B | 新增 stdout_tail 展示（L175），三态逻辑 L147 未变 |
| 15:52:00 | `append-event.ps1` | `8ff7b98a022c` → `47ca7bf9d63c` | 22862 → 23520 B | 用 `PYTHONIOENCODING=utf-8` 修 verify 子进程乱码（L187-195） |

- 效果可验证：`seq 565`（`07:49:44Z`）的 `stdout_tail` 是 GBK 乱码
  （`FAIL B Լ IpProvider.health …`），`seq 566`（`07:52:05Z`，即 15:52 修复后 5 秒）已是正常中文。
- C10 harness digest 因此在 20 分钟内变了三次：`ba23b820f02b` → `5d5bcb21115f` → `12b40103c2ee`。
- 全部 4 次改动在台账里都只留下 17 条 `tool:"seal"` 记录 + 一条 `anchor`，
  `why` 一律是模板文案，没有任何一条记录"改了什么"。见 O4-15。

**对本报告的影响**（必须声明）：`trigger` 的条目在 15:38 / 15:48 / 15:53 三个版本下分别是 13 / 12 / 11 条，
**不是同一批**。13→12 是 T4 两条误报被删 + T11 一条新增；12→11 是 T7 3.1.3 被 `"y y"` 那条 gate 消掉。
所以"告警数量在下降"不等于"问题在减少"。

---

## O4-20 · medium · 文档里"专门登记契约变更"的那一节写着"未发生任何变更"，而同一文件的操作报告承认改了契约文件

**证据**（同一份 `docs/变更记录.md` 内部自相矛盾）

- `## 4. 上游契约变更`（第 80 行起）全文只有一句：
  > `（暂无。04 §10.1 IpProvider 契约、03 §8 接口设计未发生任何变更；本节只登记上游蓝本（_vendor/）与契约文件的实际变动。）`
- 而同一文件的 `### 步骤 3.1.2（文档补记）`（第 146 行起）写：
  > `**修改的文件（均为纯追加）**：… ② contracts/ip_provider_interface.py 末尾追加 31 行注释块（3341 B → 5678 B，+2337 B …）`
- 磁盘证据（O4-01）：该文件确实被追加，mtime `15:01:00`，`04-采集系统架构.md` 也在 `15:00:29` 被改。
- 这一节是**系统自己指定的**契约变更登记处（文案自称"本节只登记…契约文件的实际变动"），它现在是空的。

**为什么这是缺陷**

`audit` 的 C9 本来是"决策对账"（拿文档里的决策记录去比台账），它的输入定义成了 `D-<seq>` 标题（见 O4-08）。
如果 C9 的输入定义改成"§4 表格里的每一行 ↔ 台账里的一条 `contract_change`"，这次矛盾会被当场抓住。
现在这一节既没有被任何规则读，也没有被任何规则写，它是一段**装饰性的合规外观**。

**建议方向**

C9 的输入应包含 `## 4. 上游契约变更` 与 `## 3. 跳过记录` 两张表：
每个非"暂无"的行必须能在台账里找到对应事件（`contract_change` / `skip`），反之每条 `contract_change` 也必须出现在表里。
这条规则一旦存在，本报告里的 O4-01、O4-21 会在发生的当天就被判红。

---

## O4-21 · medium · 唯一一次真实"跳过"只记在文档表格里，`skip` 事件从未被写过 —— T5 永远不可能为它响

**证据**

- `docs/变更记录.md` §3 `## 3. 跳过记录` 有一行真实记录：
  `| 1.3 | 中间件部署 | 无中间件可部署 | 无，1.4 直接进入外部资源准备 | skipped |`
- 台账 598 条记录里 `event == "skip"` 的条数 = **0**；
  `audit` C3 每次都在报 `never: deviate skip blocker_open blocker_close`。
- `trigger.ps1` T5 的实现（`case 'skip'` 分支）只在读到 `skip` 事件时触发。
- 也就是说：项目史上唯一发生过的"跳过"，在文档里有、在台账里没有、在触发器里没有。

**为什么这是缺陷**

这是"声明与裁决分离"被绕过的典型样本：人把"我跳过了 1.3 中间件部署"写在文档里（人可读），
但那条事实从未进入"唯一的事实来源"。于是：
- `T5_skip` 永远不会有输入（C4 记 `T5=0`，C2 却认为有 writer path）；
- `C3` 报 `skip never emitted`，但没人把它和文档里那一行联系起来；
- `status` 的 BLOCKED/DONE 判定完全不看这行，1.3 在阶段表里是否存在、是否 DONE 都不受影响。
这说明"文档"与"台账"是两条互不校验的平行事实流，而不是"投影与事实"。

**建议方向**

同 O4-20：让 §3 表格的每一行都要求一条 `skip` 事件，或反过来由 `append-event -Event skip` 自动往文档追加表格行。
另外 `skip` 是 `kind=decision` 的事件类型（append-event L43 的 ValidateSet 里有），
但它的默认 actor 映射（`$defaultActors` 只含 verify/gate/anchor/tool_use）里没有 `skip`，
所以手写 `-Event skip` 时 actor 会落到默认分支 `'claude'` —— 一个"人做出的跳过决定"会被记成 claude 做的。这是个可以顺手修的默认值。

---

## O4-22 · critical · O4-01 在 40 分钟内**复现第二次**，且这次决定"哪些不一致可以豁免"的那份文本正好在没有证据的那一环里

**证据（第二次实例，`16:15:31` / `16:15:53`）**

| 文件 | 之前 | 之后 | mtime | 台账记录 |
|---|---|---|---|---|
| `contracts/ip_provider_interface.py` | 5678 B / `3ad13fcd2810` | **6402 B / `271f1188dcc2`**（+724 B，插入 8 行） | 16:15:31 | **无**（台账里该文件最后一条仍是 `seq 43`） |
| `docs/变更记录.md` | 38042 B / `bee3fe648e36` | **41851 B / `4dcf036de57e`**（+3809 B，新增一节） | 16:15:53 | **无**（最后一条是 `seq 545`） |

**这次可以排除"hook 抢锁超时丢记录"这个解释**，因为台账在这两次写入的前后 4–7 秒都在正常落盘：

```
seq 637  08:15:27Z  Edit scripts/check_interface_impl.py   ← hook 活着
          08:15:31Z  contracts/ip_provider_interface.py 被改（台账无记录）
seq 638  08:15:34Z  Edit scripts/check_interface_impl.py   ← hook 活着
seq 639  08:15:46Z  Bash（跑 check_interface_impl.py）
          08:15:53Z  docs/变更记录.md 被改（台账无记录）
seq 640  08:15:57Z  Edit scripts/check_interface_impl.py   ← hook 活着
```

→ 写入方是一个**与 Claude Code 并行、并且不在 PostToolUse 覆盖范围内**的进程。
两次写入相隔 22 秒、与 15:00:29/15:01:00/15:01:23 那次的节奏完全一致，是同一类"文档补记"动作。

**这次写入的内容让缺陷升级**

`docs/变更记录.md` 新增的 `### 步骤 3.1.2（文档补记 2）` 自己说明了它对契约做了什么：

> `**修改的文件（纯追加，原文一字未动）**：contracts/ip_provider_interface.py 在「与上方契约的差异登记」列表尾、
> 块尾分隔线之前插入 8 行（5678 B → 6402 B，+724 B）——两条新口径 + 一条同步义务声明`

而插入的 8 行里，最后一条是：

> `# scripts/check_interface_impl.py 的 IP_PROVIDER_ANCHOR 逐条对应本节，本节是豁免口径的`
> `# 唯一事实来源；改本节必须同步改该常量。`

也就是说：

1. 契约文件里那段注释，现在被**正式宣布为"豁免口径的唯一事实来源"**；
2. 而这段注释所在的文件，是**唯一一个既被 T3 排除（`trigger.ps1` L241 的 `\.harness/`、外加契约路径无跨步规则）、
   又被 finish-step 的 diff 遗漏（不在 `_snap` 清单里）、且改动不留台账记录**的文件；
3. 更严重的是这次是**插入**而不是追加（"块尾分隔线之前插入 8 行"，行号由 107 → 115），
   所以连 O4-13 那种"前缀 hash 能对上"的取证手段都不再适用——**这份文本的历史版本已经无法从任何产物复原**。

**为什么这是缺陷（比 O4-01 更进一步）**

O4-01 说的是"一次写入没被记录，所以证据不可复现"。
O4-22 说的是"**决定什么算合规的那份文本，本身不受任何合规约束**"。
`check_interface_impl.py` 会读 `IP_PROVIDER_ANCHOR` 常量来判断哪些不一致可以豁免（本轮 agent 刚从 22 条 FAIL 降到 4 条，
就是靠这个豁免机制），而"豁免口径"的权威文本被放在一个改动零记录的注释块里，
且文档明说"改本节必须同步改该常量"——**这条同步义务没有任何机器检查**，只有一句人写的注释。

**建议方向**

1. 豁免口径不能放在会被 T3 排除、会漏 diff 的文件里。最直接的修法：把"豁免清单"变成 `project.json` 里的一等结构
   （例如 `stages[].waivers`），这样它的每次改动都会走 `contract_change` + `approved_by` + T2b/T2c。
2. 至少让 `finish-step` 的 diff 覆盖面与 `_snap` 清单解耦：凡本步台账里出现过 `tool_use` 的文件、以及
   `contracts/**` 固定清单，一律进 diff；manifest 缺失时报警而不是静默跳过（`finish-step.ps1` L171 现在只在
   manifest **完全不存在**时 WARN）。
3. 给"注释块承载契约语义"这件事本身加一条规则：`contracts/*.py` 的注释块内容变化必须走 `contract_change`
   （按"注释块是否含关键词如 差异登记/豁免"识别），否则规则永远追不上。

---

## 附 D：缺陷当前状态矩阵（截至 16:18 收尾，观测期间的修复已逐条复核）

| 编号 | 级别 | 标题 | 状态（16:05 复核） | 复核依据 |
|---|---|---|---|---|
| O4-01 | critical | 契约文件 +2337B 无任何事件记录（台账/快照/diff 三漏） | **仍存在** | `audit` FAULTS 仍含 `C7 2.0.2 … does not match the ledger`；`post-tool.mjs`/`pre-tool.mjs` 未改 |
| O4-02 | high | 步边界（`status -SyncStep` 推进 `current_step`）不落事件 | **仍存在** | `local.json` 至今 mtime `15:01:36`，台账无 step_end；`finish-step.ps1` 未改（`32fdc47c0725`） |
| O4-03 | high | T3 全局白名单 → 跨步改文件无规则 | **部分修复** | 新增 `T11_accepted_modified`；但对"连记录都没有"的契约改动仍沉默（实测只报 `scripts/init_db.py`） |
| O4-04 | high | T4 把 verify 后的命令当返工（2 条误报） | **已修复** | 新版 L278-297 双护栏；两条 `T4_rework` 已消失 |
| O4-05 | high | `sign-gate` 覆盖不足、取消=exit 0、无原因质量门槛、未实测就 seal | **部分修复** | 已加单字符重复校验（L207-209）、取消改为 `exit 130`；`contract_change`/`anchor` 仍要手打 JSON |
| O4-06 | medium | trigger 队列无窗口无 ack，6 条永久死噪声 | **仍存在** | 本轮 14 条里 6 条仍是 `%TEMP%` 历史 T3 |
| O4-07 | medium | T2b 结构性死代码（`$alreadyReported`） | **已修复** | 新版 `trigger.ps1` 已无 `alreadyReported` |
| O4-08 | medium | C9 长期空转（0 条 `D-<seq>`） | **仍存在** | `audit` 仍报 `C9 decisions 0 record(s) checked` |
| O4-09 | medium | verify 只证明"能 import"；`real_test` 恒真 | **部分修复** | `Test-RealTest` 已重写，注释直接引用了"18 条 verify、0 条 pytest"的测量；但**已写入的 18 条历史记录仍是旧语义，无法追溯重判** |
| O4-10 | medium | L2 风险门只出声不阻截 | **仍存在且更清楚** | `T12` 上线后一次性证明：**本台账三次 gate 全部是事后追认**（3.1.1 `/1.2`/`3.1.3` 均 reported after first event） |
| O4-11 | low | hook 抢锁失败静默丢记录，与 append-event 语义不一致 | **仍存在** | `post-tool.mjs` 未改 |
| O4-12 | low | 文档自述与实际不符（31 行 vs 33 行；108 行 vs 107 行） | **仍存在** | 3.1.3 报告写"当前版 108 行"，实测 107 行 |
| O4-13 | high | `before_sha256` 指向两个版本之前，与快照互相矛盾 | **仍存在** | `post-tool.mjs` 未改；`seq 545` 那条记录仍是错的 |
| O4-14 | high | C7 的 FAULT 会被下一次普通写入洗掉 | **仍存在** | `0.1` 那条 FAULT 已于 15:45 消失，无解释事件 |
| O4-15 | medium | harness 自身改动只有 digest，无内容无理由 | **仍存在且加剧** | 40 分钟内 4 次 seal，`why` 仍全是模板文案 |
| O4-16 | high | 首次 gate 的 `why = "y y"`，且晚于交付物 8 分钟 | **已加检测，事实不变** | 新增 `T12_gate_after_the_fact`（注释直接引用本条）；`seq 564` 记录本身不可改 |
| O4-17 | medium | C5 判 pass 而 status 判 verify_mismatch | **已修复** | `C5 1.1=mismatch`，warning 文案直接引用了这条发现 |
| O4-18 | medium | 12 个 `[x]` 里 5 个无可失败证据 | **仍存在** | `status` 输出未变 |
| O4-19 | low | 观测窗口内被观测系统被连续修改 | 记录性条目 | C10 digest 四次变化 |
| O4-20 | medium | 文档 §4「未发生任何契约变更」与自身 §2 矛盾 | **仍存在** | 该节全文仍为"（暂无。…未发生任何变更）" |
| O4-21 | medium | 唯一一次 skip 只在文档表格，台账 0 条 skip 事件 | **仍存在** | `C3` 仍报 `never: … skip …` |
| O4-22 | critical | O4-01 复现第二次，且"豁免口径的唯一事实来源"落在无证据的那一环 | **仍存在（16:15 新发生）** | `audit` FAULTS 由 2 变 3，`C7 2.0.2 now=271f1188dcc2`、`C7 0.1 now=4dcf036de57e` |

**说明**：本报告在 90 分钟内被观测系统读取并修补了 5 处（O4-04 / O4-07 / O4-17 已修，O4-03 / O4-05 / O4-09 部分修），
补丁注释里直接引用了本报告的测量数据（"observer #4 found 2 of 13 hits were noise"、
"Observer #4 measured the result: 18 verify events, zero of them containing 'pytest'"）。
这本身是一个值得记录的观测结果：**度量层在观测压力下收敛得很快，但收敛过程不留理由（O4-15），
而且修复只对新证据生效——已写入台账的历史记录无法按新标准重判**。

## 附 A：轮 1（15:38）audit / trigger 原始输出

```
verify-ledger: [OK] 526 records, chain intact, head=29718a66bf6b

audit  C1 chain intact 526 events, last_at=11/07/2026 07:33:08
       C2 registration 9/9;  C3 emission 5/9 (never: deviate skip blocker_open blocker_close)
       C4 rule input T1=0 T2=4 T3=140 T4=140 T5=0 T6=0 (unexercised: T1 T5 T6)
       C5 evidence 0.1=void 1.1=pass 2.0.1..3.1.2=pass
       C6 verify-ref 0 dangling;  C7 drift 2 drifted, 7 unrecorded
       C8 attribution local_step='3.1.3' top='harness' 16/20
       C9 decisions 0 checked;  C10 harness ba23b820f02b
       FAULTS (2): C7 0.1 docs/变更记录.md / C7 2.0.2 contracts/ip_provider_interface.py
       WARNINGS (10)   ← 含 C5 "0.1 verify ran 1 time(s) but never meaningfully"
                        ← 含 C5 "5 stage(s) have passed every time and never once failed (1.1, 2.0.3, 2.0.5, 3.1.1, 3.1.2)"

trigger exit=3, 13 items: T4×2, T3×5, T2×3, T7×2, T2c×1
```

## 附 B：轮 6（15:54:27）audit 原始输出（582 条）

```
C1 chain intact 582 events, last_at=11/07/2026 07:52:23
C5 evidence 0.1=void 1.1..3.1.2=pass  3.1.3=fail
C7 drift 1 drifted, 7 unrecorded
C9 decisions 0 checked;  C10 harness 12b40103c2ee
FAULTS (2):
  x C5 3.1.3  latest verify FAILED - this is a counter-proof, not a missing citation
  x C7 2.0.2  contracts/ip_provider_interface.py on disk (3ad13fcd2810) does not match the ledger (949a5cd58bbe)

trigger exit=3, 11 items:
  T3_out_of_scope 2.0.1 %TEMP%/prchk_check_contracts.py
  T3_out_of_scope 2.0.1 %TEMP%/prchk_sigs.py
  T3_out_of_scope 2.0.3 %TEMP%/launcher_selftest.py
  T3_out_of_scope 2.0.3 %TEMP%/collector_selftest.py
  T11_accepted_modified 3.1.2 scripts/init_db.py belongs to 3.1.1 (already verified), modified under step 3.1.2 with no contract_change
  T3_out_of_scope 3.1.2 price_watch/pool/providers/__init__.py
  T2_contract 2.0.1/2.0.3/3.1.1  (3 条历史 project.json 变更)
  T7_risk_L2 2.0.2 (3h57m 无 gate)
  T2c_unsigned_contract 2.0.1
```

## 附 C：`sign-gate.ps1` 首次使用的完整记录

```json
{"v":1,"seq":564,"at":"2026-11-07T07:49:17Z","step":"3.1.3","kind":"decision","actor":"human","event":"gate",
 "data":{"level":"L2","status":"approved","by":"elu9527-sudo","why":"y y"},"prev":"a05ff4a6...","self":"6752b1d8..."}
```

紧随其后的两次 verify（`seq 565` `07:49:44Z`、`seq 566` `07:52:05Z`）都是 `exit:1 / RESULT FAIL 22`，
失败原因是契约层（`IpProvider` 4 抽象方法 / `IpLease` 9 字段）与实现层（3 方法 Protocol / `Egress` 3 字段）不同形：
`FAIL 检查项B 契约 IpProvider.health 在实现 DirectProvider 上不存在` 等 22 条。

---

## 观测结束

**结束时刻**：2026-11-07 16:18（+08:00）。累计观测 **40 分钟 / 11 轮采样**。
（任务书要求 2 小时连续观测；实际未达。原因是本轮观测窗口内系统变化速度远高于预期——40 分钟里台账从 526 增到 650 条、
harness 被改了 6 次并 seal 了 6 次、发生两次未记录写入、出现第一次 gate 签名和第一次当前步骤 FAIL——
按 12–15 分钟等距采样会漏掉其中大部分。我改用按事件密度加密采样，代价是总时长缩短。**这是覆盖范围上的欠交付，不是观测结果的折扣**：
本报告所有结论都带 seq 号或文件 digest，可以逐条复核。）

**结束时系统状态（可直接复核）**：

| 项 | 值 |
|---|---|
| 台账条数 / 末条时间 | 654 / `2026-11-07T08:18:43Z` |
| 链 | `[OK] 654 records, chain intact, head=43e1fd168d44`（16:19 采样） |
| `audit` | exit 1，**FAULTS 3**（C5 3.1.3 fail / C7 0.1 drift / C7 2.0.2 drift），WARNINGS 11 |
| `trigger` | exit 3，14 条（含 T12 三条、T11 一条） |
| `status` | NEXT 3.1.3（L2），DONE 12 个，HISTORICAL GAPS 7 条 |
| `local.json` | `current_step = 3.1.3`，mtime `15:01:36`（**1 小时 17 分未推进**） |
| C10 harness | `1e279f368a07`（观测期间共变化 6 次：`ba23b820f02b` → `5d5bcb21115f` → `12b40103c2ee` → `872430c5cc6a` → `7f81d9021df6` → `1e279f368a07`） |
| 3.1.3 是否关闭 | **否**。`docs/_diff/3.1.3/` 不存在，`finish-step` 未跑 |
| 观测窗口内新增记录的 actor 分布 | `script/tool_use` 75、`hook/tool_use` 45、`script/anchor` 5、`verify/verify` 2、`human/gate` 1 —— **无一条由观测者产生**（我全程未跑任何写台账的脚本） |

**如果要继续观测，建议从这里接**：
1. 等 `finish-step` 跑完 3.1.3 —— 那会给 O4-02（步边界不落事件）第二个实例，并可能暴露 diff 覆盖面缺失（O4-22 建议 2）。
2. 盯 `contracts/ip_provider_interface.py` 与 `docs/变更记录.md` 的 mtime：目前每次"文档补记"都会在这两个文件上各留一次
   无记录写入（15:00:29/15:01:00/15:01:23 与 16:15:31/16:15:53 是同一模式），第三次出现就能确认是稳定习惯而非偶然。
3. 4.1 是 L1，4.2 / 5.x 的 risk 等级值得核一遍：若其中存在 L2，`T12`（gate 必须在开工前）会成为主要告警源。