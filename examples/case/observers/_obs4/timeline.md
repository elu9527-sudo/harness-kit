# 观测时间线 · observer #4

被观测系统：`D:\work\price-watch-demo`（三角色流水线 + harness 度量层）
观测方式：只读。每轮跑 `audit.ps1` / `trigger.ps1` / `status.ps1` / `verify-ledger.ps1`，比对 `events.jsonl` 新增记录，核对磁盘 mtime + sha256。

---

## 轮 1 — 2026-11-07 15:38:00 ~ 15:41:00

**台账 seq 区间**：1–526（本轮起点 max seq=526）
**命令输出**：

- `verify-ledger.ps1` → `[OK] 526 records, chain intact, head=29718a66bf6b`（exit 0）
- `audit.ps1` → exit 1，FAULTS 2，WARNINGS 10，C10 harness digest = `ba23b820f02b`
- `trigger.ps1` → exit 3，`Hermes needed: 13 item(s)`
- `status.ps1` → exit 0，NEXT=3.1.3（L2），无 `verify_failed`

**观察到的事实**：

1. 台账 526 条，`actor×event` 分布：
   `script/tool_use` 324、`hook/tool_use` 140、`script/anchor` 35、`verify/verify` 18、
   `human/contract_change` 3、`human/anchor` 2、`human/gate` 2、`claude/contract_change` 1、
   `hermes/anchor` 1。
   → 526 条里只有 **1 条 hermes 记录**；`deviate` / `skip` / `blocker_open` / `blocker_close` 四条事件类型从未被写过（audit C3 已报）。
2. audit FAULTS 两条都是 C7 drift，其中 `0.1 docs/变更记录.md` 是本轮新出现的（上一轮观测者只报了 `2.0.2 contracts/ip_provider_interface.py`）。
3. 台账最后一条是 seq 526（`07:33:08Z` seal-harness），之后到 15:41 之间台账停顿约 8 分钟。

**本轮新发现**（详见 report.md O4-01）：

`07:00:29Z–07:01:23Z` 这 54 秒内三个文件被改，台账一条记录都没有：

| 文件 | 磁盘 mtime（本地） | 磁盘 sha256 前 12 | 台账最后记录 |
|---|---|---|---|
| `04-采集系统架构.md` | 15:00:29 | `510b34d9e19f` | **从未有过任何 data.file 记录** |
| `contracts/ip_provider_interface.py` | 15:01:00 | `3ad13fcd2810` | seq 43 `949a5cd58bbe` |
| `docs/变更记录.md` | 15:01:23 | `c99dff5b596d` | seq 507 `7f3a4bbce438` |

对 `contracts/ip_provider_interface.py` 做了字节级复算：取磁盘文件前 74 行 + 结尾换行，
UTF-8 = **3341 字节**，sha256 = `949a5cd58bbeafd6fad0cb5d11e633f06c41095743952f816c5b16d40c51bb3b`
—— 与 seq 43 记录的 digest **逐字节吻合**。磁盘现状 5678 字节 = 原 74 行 + 末尾追加 33 行注释块（+2337 B）。
`docs/变更记录.md` 在同一时刻写下的「文档补记」条目自己承认了这件事：
「② `contracts/ip_provider_interface.py` 末尾追加 31 行注释块（3341 B → 5678 B，+2337 B，上方 74 行原文逐字未动）」。

三份证据产物同时漏记同一个写入：
- PostToolUse 台账：`07:33Z` 之前该文件最后一条是 seq 43（`02:59:19Z`），此后无 tool_use；
- PreToolUse 快照清单 `docs/_snap/3.1.2/_manifest.json`：只列 4 个文件（`scripts/init_db.py`、`docs/变更记录.md`、`providers/direct.py`、`ip_factory.py`），**没有**该契约文件；
- finish-step 生成的 `docs/_diff/3.1.2/`：**没有**该契约文件的 diff。
（只有 audit C7 因为它在 2.0.1 的 `generates` 里、有历史 digest 可比，才抓到这条。）

4. 步边界无记录：`.harness/local.json` mtime = `15:01:36`（`current_step` 由 3.1.2 推进到 3.1.3），
   但台账在 `07:01:35Z`（seq 510，finish-step 自己调 append-event 产生的 verify）之后、
   到 `07:40:31Z`（seq 527）之前，没有任何"本步结束"的事件。读源码确认 `finish-step.ps1` L221 只调
   `status.ps1 -SyncStep` 改 local.json，**不落任何事件**。

---

## 轮 2 — 2026-11-07 15:41:00 ~ 15:52:00

**台账 seq 区间**：527–528（本轮新增 2 条，实测已开始推进 3.1.3）

- seq 527 `07:40:31Z` step=3.1.3 actor=hook tool_use Bash：读三份契约的 `__all__` / 抽象方法（`importlib` + `inspect`）
- seq 528 `07:41:16Z` step=3.1.3 actor=hook tool_use Write `scripts/check_interface_impl.py`，sha `9e5695c6c28b`，`before_sha256=""`（新建）

**观察到的事实**：

1. **3.1.3 是 L2 且从未签 gate（trigger T7 本轮仍在报），但编码 agent 已经开始写它的交付物**。
   `scripts/check_interface_impl.py` 是 3.1.3 唯一的 `generates`。也就是说 T7 那条
   「sign it BEFORE the step starts, not after」被事实违反了 —— 规则报了 41 分钟，没人处理，工作照常开始。
2. `docs/_snap/3.1.3/_manifest.json` 已在 15:41 之后出现（本轮的 PreToolUse 快照生效），
   即 3.1.3 的写入**有**快照 —— 与 3.1.2 那两次漏记形成对照。
3. 台账在 15:41:16 之后本轮未再增长（截至 15:52 采样）。

---

## 轮 3 — 2026-11-07 15:43:00 ~ 15:47:39（台账 529–563）

**台账 seq 区间**：529–563（新增 35 条，全部集中在 `07:41:44Z`–`07:46:45Z`）

- `seq 529–533`（07:41:44–07:42:01）连续 5 次改写 `scripts/check_interface_impl.py`（Write 后接 4 次 Edit）
- `seq 534`（07:42:10）运行该脚本，`seq 535` grep，`seq 536–539` 再改 4 次
- `seq 540 / 541`（07:43:20 / 07:43:38）两次用 `<<'EOF'` heredoc 跑合成契约+合成实现的自测（agent 在验证自己的检查脚本"能变红"）
- `seq 542`（07:43:57）依赖面/违禁能力扫描 + 运行前后文件集 diff（无副作用检查）
- `seq 545`（07:45:00）`Edit docs/变更记录.md`，`before_sha256=7f3a4bbce438` ← **见 O4-13，这个 before 是错的**
- `seq 547`（07:45:28）agent 自己在 `ls -la --time-style` 几个文件（`contracts/ip_provider_interface.py`、`04-采集系统架构.md`、`.harness/local.json`）——它也在查同一个漂移
- `seq 548–563`（07:46:41–07:46:45）`seal-harness` 重新 seal 17 个文件，harness digest `ba23b820f02b` → `5d5bcb21115f`

**本轮关键事实**：

1. **被观测系统在观测期间被修改**：`sign-gate.ps1`（15:45:10）、`trigger.ps1`（15:46:00）。
   新 `trigger.ps1` 626 行（原 561 行），新增规则 **T11_accepted_modified**，注释原文点名
   「Two guards, both added after observer #4 found 2 of 13 hits were noise」——
   即我在 15:45 发给父 agent 的两条判断（T3 全局白名单盲区、T4 两条误报）在 1 分钟内被落成代码。
   实测效果：两条 `T4_rework` 消失；`T11` 抓到一条此前几十轮都没人报的真实案例
   （`scripts/init_db.py belongs to 3.1.1, modified under step 3.1.2`）。
2. **但 T11 抓不到触发它的那件事本身**：`contracts/ip_provider_interface.py` 的那次改写台账里连一条
   `tool_use` 都没有，T11 遍历的是 `tool_use` 记录 → 实测本轮 T11 只出 `scripts/init_db.py` 一条。
3. **快照与台账互相矛盾**（新缺陷 O4-13）：
   `docs/_snap/3.1.3/docs__变更记录.md.before` 实测 sha256 = `c99dff5b596d`（= 15:01:23 那个未记录版本），
   而 `seq 545` 的 `before_sha256` = `7f3a4bbce438`（= seq 507 那个更早的版本）。
   同一次写入的两份 before 证据给出两个不同答案。
4. **C7 的 FAULT 自动消失**（新缺陷 O4-14）：`audit` FAULTS 由 2 条降为 1 条，
   `0.1 docs/变更记录.md` 那条被 `seq 545` 的一次普通编辑"洗掉"；
   `status` 的 HISTORICAL GAPS 同步由 8 条降为 7 条。台账中该文件历史从此读作
   `7f3a4bbce438 → bee3fe648e36`，`c99dff5b` 这个版本永久消失。

---

## 轮 4 — 15:47:54 ~ 15:48:44（复核）

- `verify-ledger`：`[OK] 563 records, chain intact, head=a05ff4a64168`
- `audit`：exit 1，FAULTS 1（只剩 C7 2.0.2），WARNINGS 10，C10 `5d5bcb21115f`
- `trigger`：exit 3，12 条（T4 两条消失、T11 一条新增、T7 3.1.3 仍在）
- `status`：NEXT 3.1.3，DONE 12 个，HISTORICAL GAPS 7 条
- 项目 `derive/` 与 `harness-kit/templates/derive/` 的 11 个脚本 digest **全部一致**（无双写分叉）
- 附带核对：`.harness/**` 在 `docs/_snap` 与 `docs/_diff` 里**没有任何条目**，harness 自身的改动不可 diff（O4-15）

---

## 轮 5 — 15:53:39（台账 564–582）

**台账 seq 区间**：564–582

- `seq 564`（07:49:17Z）**第一条 gate**：`{"level":"L2","status":"approved","by":"elu9527-sudo","why":"y y"}`
  → `sign-gate.ps1` 上线后首次使用（也可能仍是手打 JSON，无法从记录区分）；
  时间是 3.1.3 交付物落盘（`seq 528`，07:41:16Z）之后 8 分 1 秒。见 O4-16。
- `seq 565`（07:49:44Z）`verify 3.1.3` → **exit 1，`RESULT FAIL 22`**，`stdout_tail` 是 GBK 乱码
- `seq 566`（07:52:05Z）同一条 verify → **exit 1，`RESULT FAIL 22`**，`stdout_tail` 已是正常中文
  （15:52:00 的 `append-event.ps1` 改动把子进程 `PYTHONIOENCODING` 钉成 utf-8，5 秒后生效）
- `seq 567–582`（07:52:17–07:52:23）`seal-harness` 再跑一次，digest `5d5bcb21115f` → `12b40103c2ee`；
  这一批里 `append-event.ps1` 与 `verify.ps1` 的 digest 又变了
- 3.1.3 **尚未关闭**：`.harness/local.json` mtime 仍是 `15:01:36`，`docs/_diff/3.1.3/` 目录还不存在

**本轮关键事实**：

1. `T7_risk_L2 3.1.3` 在 `seq 564` 之后消失 —— L2 风险门被 `"y y"` 关闭。
2. 3.1.3 的验收是**红的**（22 条 FAIL），失败原因是契约层与实现层不同形；
   而 15:01:00 那次未记录的契约追加，内容正是"差异登记"注释（"IpLease 的九字段是目标形状；本期落地快照是 Egress 的三字段"）。
   → 用**注释**登记差异，机器读不到，下一步的自检脚本照样红。这条因果链把 O4-01 的代价具体化了。

---

## 轮 6 — 15:54:27（audit/trigger 复核）

- `audit`：FAULTS **2**：`C5 3.1.3 latest verify FAILED - this is a counter-proof` + `C7 2.0.2`
  （3.1.3 是本台账里第一条"当前步骤直接红"的 FAULT）
- `trigger`：11 条（T7 3.1.3 消失；T7 2.0.2 仍在，已挂 3h57m）
- `C5` 与 `status` 对 `1.1` 给出矛盾结论（C5=pass，status=verify_mismatch）→ 新缺陷 O4-17
- `status` 12 个 `[x]` 里 5 个同时被标 `done_without_evidence` → 新缺陷 O4-18
- `Test-RealTest` 复读：仍是 `if ($Command -notmatch 'pytest|unittest|nose2?|tox') { return $true }`
  → **18 条 verify 记录里 `real_test` 恒为 true，0 条命令含 pytest**，三态里 real_test 这一支从未起过作用

---

## 轮 7 — 16:00:53（台账 583–598）

- `seq 583–598`（`08:00:00Z`–`08:00:04Z`）第 4 次 `seal-harness`，harness digest `12b40103c2ee` → `872430c5cc6a`
- 本批 seal 里有 **4 个脚本的 digest 变了**：

  | 文件 | s511 | s548 | s567 | s583 |
  |---|---|---|---|---|
  | `append-event.ps1` | 8ff7b98a | 8ff7b98a | 47ca7bf9 | **89d2494538** |
  | `audit.ps1` | 71eb26b1 | 71eb26b1 | 71eb26b1 | **43a60b4b66** |
  | `sign-gate.ps1` | ed083667 | 8488c44b | 8488c44b | **bce529952e** |
  | `trigger.ps1` | b38fae41 | 3197a2dd | 3197a2dd | **7a59fc3026** |

- `local.json` 仍是 `3.1.3`（mtime 15:01:36），`docs/_diff/3.1.3/` 仍不存在 → 3.1.3 未关闭
- 08:00:00 这个整点时刻值得记一笔：seal 恰好落在整点，可能是人工卡点，也可能是巧合（无法从台账区分）

## 轮 8 — 16:01:24 / 16:01:35（复核新规则的实际效果）

**逐个验证我在上一封消息里报的缺陷是否被修**：

| 我报的 | 新版实现 | 实测 |
|---|---|---|
| sign-gate 不校验原因质量 | `sign-gate.ps1` L207-209：`if ($squashed.Length -lt 6) { distinct chars == 1 → "repeated single character" }` | 已加 |
| 取消 = exit 0 与成功同码 | L305 附近改 `exit 130`，注释「exit 0 for "declined" is indistinguishable from "signed" to any caller that only checks the code」 | 已改 |
| C5 不比对"跑的命令 vs 声明的命令" | `audit.ps1` L312-329 新增 `mismatch` 态，注释直接引用我举的 `python -c "import yaml"` vs `pip check` 例子 | 已改，实测 `C5 1.1=mismatch` |
| T2b 被 `$alreadyReported` 永久关闭 | 新版 `trigger.ps1` 已无该标识 | 已改 |
| `real_test` 恒真 | `Test-RealTest` 重写，注释「Observer #4 measured the result: 18 verify events, zero of them containing 'pytest'」 | 已重写（但**已写入的 18 条历史记录无法追溯重判**） |
| gate 晚于开工 | 新增 `T12_gate_after_the_fact` | 已加，且一次性证明**三次 gate 全部是事后追认** |

**新规则 T12 的输出（这是本报告里最有力的量化结论之一）**：

```
T12_gate_after_the_fact 3.1.1  gate recorded 06:20:25 but first event of this step is 06:16:48
T12_gate_after_the_fact 3.1.2  gate recorded 06:49:09 but first event of this step is 06:27:25
T12_gate_after_the_fact 3.1.3  gate recorded 07:49:17 but first event of this step is 07:40:31
```

→ 本项目历史上**每一次** L2 签字都发生在该步开工之后。"人签字关卡"从未真正起过前置作用。

**本轮 trigger 变成 14 条**（11 + T12 三条）。即"告警数在涨"，但涨的三条是**新发现的真事实**，不是噪声。

---

## 轮 9 — 16:06:29（静止观测）

**台账无新事件**：`last_at = 2026-11-07T08:00:04Z`，`events.jsonl` mtime = `16:00:04`，
即采样时刻已静止 **6 分 25 秒**。`max seq = 598`，`local.json` mtime 仍是 `15:01:36`。

**这段时间"没有在干活"和"干了但没记"的区分**：
- 能确定没有 Claude Code 写入：`events.jsonl` 的 mtime 未动，而 hook 每次 PostToolUse 都会写台账（O4-11 那条 3 秒超时才可能丢，且不连续）。
- 可以确定 3.1.3 **没有被关闭**：`docs/_diff/3.1.3/` 目录始终不存在，而 `finish-step.ps1` L103 一定会 `New-Item -ItemType Directory -Force` 建它。
- 因此这是"流程停住/人在别处"，不是"干了没记"。**但请注意**：这个判断只有在"hook 一定会写"成立时才有效——
  而 O4-11 说明这个前提在锁竞争下会失效（3 秒放弃且静默）。所以严格说，我只能说"没有可观测的活动"，不能说"没有活动"。

---

## 轮 10 — 16:16:41（台账 599–643，本轮出现本报告最重要的复现）

**台账 seq 区间**：599–643

- `seq 599–614`（`08:07:29Z`–`08:07:34Z`）第 5 次 seal，digest `872430c5cc6a` → `7f81d9021df6`
- `seq 615–630`（`08:07:56Z`–`08:08:01Z`）**第 6 次 seal，距上一次只隔 27 秒**，digest → `1e279f368a07`
  （27 秒内两次 seal，说明有人在两次之间又改了 harness 并立刻重新 seal；这次连"改了什么"的线索都没有，见 O4-15）
- `seq 631`（`08:13:32Z`）agent `grep -n "" contracts/ip_provider_interface.py | sed -n '76,107p'` —— 在读契约的注释块
- `seq 632–643`（`08:14:24Z`–`08:16:33Z`）3.1.3 继续：Write + 6 次 Edit `check_interface_impl.py`，中间穿插 3 次运行

**本轮关键事实（→ O4-22）**：

`audit` 的 FAULTS 由 2 条变为 **3 条**，新增/变化两条都是 C7 dpift，而且都是**第二次未记录写入**：

```
x C7 0.1   docs/变更记录.md on disk (4dcf036de57e) does not match the ledger (bee3fe648e36) - a write happened that no event records
x C7 2.0.2 contracts/ip_provider_interface.py on disk (271f1188dcc2) does not match the ledger (949a5cd58bbe) - a write happened that no event records
```

- `contracts/ip_provider_interface.py`：5678 B → **6402 B**，mtime `16:15:31`
- `docs/变更记录.md`：38042 B → **41851 B**，mtime `16:15:53`
- 这两次写入落在 `seq 637`（`08:15:27Z`）与 `seq 638`（`08:15:34Z`）之间、以及 `seq 639`（`08:15:46Z`）与
  `seq 640`（`08:15:57Z`）之间 —— **hook 在前后 4–7 秒都在正常落盘**，所以这次不可能是"抢锁超时丢记录"，
  只能是另一个不在 PostToolUse 覆盖范围内的写入方。
- 写入内容：契约里**插入**（不是追加）8 行，末尾一句自我授权：
  「`scripts/check_interface_impl.py` 的 `IP_PROVIDER_ANCHOR` 逐条对应本节，本节是豁免口径的唯一事实来源；改本节必须同步改该常量。」
- 变更记录新增 `### 步骤 3.1.2（文档补记 2）`，自述"5678 B → 6402 B，+724 B"。

---

## 轮 11 — 16:17:51（台账 644–650）

- `seq 644`（08:16:52Z）运行 `check_interface_impl.py`
- `seq 645`（08:16:56Z）`wc -l docs/变更记录.md && tail -3 docs/变更记录.md` —— **被 hook 记录的 agent 在读那份它没有写过的变更记录**
- `seq 646`（08:17:05Z）`grep -n "" contracts/ip_provider_interface.py` —— 同样在读契约
- `seq 647 / 649 / 650` 继续 Edit `check_interface_impl.py`
- `local.json` 仍是 `3.1.3`（mtime 15:01:36），`docs/_diff/3.1.3/` 仍不存在 → **3.1.3 全程未关闭**

**这段的观测价值**：`seq 645/646` 证明两个写入方在同一个工作流里协作——
被 hook 记录的 agent 正在读另一个（不被记录的）写入方刚刚改过的文件。
也就是说"谁改了什么"在系统里不是缺失，而是**一半有一半没有**，这比全都没有更难排查。

---

（观测在此结束，见 report.md 尾部「观测结束」）