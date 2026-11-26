# 观测员 #5 缺陷报告 · price-watch 三角色流水线

## 0. 观测元信息（如实声明）

| 项 | 值 |
|---|---|
| 实际起 | 2026-11-07 **16:58:35**（接到任务）→ 首个动作 16:58:53 列项目根 |
| 实际止 | 2026-11-07 **17:07:27**（宿主即将关机，收到紧急收尾指令，就地交付） |
| 实际时长 | **约 9 分钟**，非计划的 2 小时 |
| 完整采样轮 | **3 轮**（R1 16:59:46 / R2 17:03:05–17:04:12 / R3 17:05:3x–17:06）+ 1 次关账快照 17:07:19–17:07:27 |
| 计划轮数对比 | 2h ÷ 12–15min ≈ 8–10 轮（返工期 5–8min 应更多）→ **覆盖率约 3/9 ≈ 33%（按轮数），按时间 9/120 ≈ 7.5%** |
| seq 覆盖 | 细读 **seq 694–746**（逐条 event/actor/step/data）；全量扫描 verify 23 条（seq 1–735）、事件/actor/step 直方图（全 746 条） |
| 未覆盖 | 17:07 之后的整个返工/4.1 执行期；sweep 17:12 及以后各轮；锁竞争未观察到实例；T12/T7 与返工交互只观察到"未产生新报警"这一半 |
| canary 开局 | **已跑，16:59:03，`canary: 8/8 detectors fired`，exit 0**（T3_out_of_scope / T11_accepted_modified / T12_gate_after_the_fact / C5_VOID_trivial_verify / C5_latest_verify_FAILED / C1b_ledger_truncation / T13_unrecorded_write / sweep_detection 全 FIRED）→ 观测窗口开始时安全系统活着 |
| 关账状态 | C1 intact **746 events**，verify-ledger `[OK] 746 records, chain intact, head=14d70d6517ef`，**C10=fb656124f23c 全程未漂移**（无人改 harness），audit WARNINGS 5 / trigger 16 项 / status NEXT=4.1 |

时间基准提醒：台账 `at` 为 UTC（带 Z），文件 mtime 与计划任务、人的口述为本地 UTC+8。本报告凡引用 seq 的 `at` 均已换算为本地时间标注。

---

## 1. 缺陷清单

### O5-01 · **critical** · T3/T4/T11 对"非 hook 写入者"整体失明，导致已验收步骤的判卷脚本被改而无人报警

**证据**

- 源码 `​.harness/derive/trigger.ps1:241`（在 `switch` 的 `'tool_use'` 分支内）：
  ```powershell
  if ($observedBy -ne 'hook') { break }
  ```
  该行之后才是 T3（243–259）、**T11（262–292）**、T4（293–309）。即：凡 `data.observed_by != 'hook'` 的记录，T3/T11/T4 一条都不评估。
- 台账 seq **740**（本地 17:01:34）：
  ```
  t=tool_use actor=hermes step=4.1 data={"file":"scripts/check_interface_impl.py","tool":"manual","observed_by":"script",
  "before_sha256":"7ff2fbb2f1c8cfdd01e03901113bbb74f4dc8b5f4935a892c80dfbbb79f39f52",
  "sha256":"ff54f049afabe61c416e40d2cb426e5384167d51edbf806333a381d1ca2e31cc", ...}
  ```
- `.harness/project.json` stage **3.1.3** `generates = scripts/check_interface_impl.py`，`verify = .venv\Scripts\python.exe scripts/check_interface_impl.py`；3.1.3 的绿 verify 为 seq **734/735**（17:04:44 之前，exit=0, trivial=false, real_test=true），并由 seq **736** `step_advance{from:3.1.3,to:4.1,closed_by:3.1.3}` 关闭。
- T11 的输入计数在涨（C4：`T11=653`→`660`），但 trigger 三轮输出里 T11 始终**只有 1 条**（`scripts/init_db.py belongs to 3.1.1`），**从未出现 `scripts/check_interface_impl.py`**。关账快照（17:07:21）同样没有。

**为什么是缺陷（不是设计如此）**

3.1.3 的验收标准 = 它自己的 `generates` 文件 = 它的 verify 命令本体。步骤关闭 5 分钟后，该文件被 **hook 覆盖不到的写入者（Hermes）** 改写（digest 7ff2fbb2→ff54f049）。这正是 T11 被造出来的场景（"已验收产物被跨步修改"），也是今天 O4-01/O4-22 事故的主诉。而 `trigger.ps1:267` 的注释明文写着 T11 覆盖 **"writes that were RECORDED"** ——实现与自身声明的设计意图直接矛盾：已记录、但记录者不是 hook 的写入，被 241 行的 `break` 整段跳过。

该过滤的正当理由（注释 224–241：seal 自述记录 252 条会把 T3 淹成噪音）**已经由 252 行的路径过滤 `$p -notmatch '^(events\.jsonl|docs/_snap/|docs/_diff/|docs/变更记录\.md|\.harness/)'` 独立解决**，且 seal 记录 step=harness 也无法命中 T11（无 stage 拥有 `.harness/`）或 T4（`verifyPassed` 不含 harness）。所以这个 `break` 的实际净效果只有一个：把唯一不被 hook 覆盖的一类写入者（Hermes/人经 record-edit/sweep -Baseline）从三条行为规则里摘除。

**建议方向**：把 `break` 收窄为"跳过 step=harness 的自述/`tool=seal|maintenance` 记录"，而不是跳过一切 `observed_by != hook`；至少让 T11 评估全部带 `file` 的记录。同时补一条规则：**verify 命令所依赖的文件（stage.verify / stage.generates 中被 verify 直接执行者）在该 stage 通过后不得变更，除非重新 verify**（当前 3.1.3 关闭后判卷脚本被改，没有任何规则要求重跑）。

---

### O5-02 · **high** · sweep 两阶段执行 + 过期台账快照 → 在不可篡改台账里写入**永久性假事实**（闭环第一次真实运转即误报）

**证据（同一 sha 的自相矛盾，36 秒内）**

- seq **730**（本地 16:52:23）`tool_use actor=hermes step=3.1.3 file=docs/变更记录.md sha256=aead7d42cff5c98992f506e3922d396106b6e0724a26d2f5b72ca88fa87a07c3`
- seq **731**（本地 16:52:59）`unrecorded_write actor=script step=0.1`：
  ```json
  {"file":"docs/变更记录.md","disk_sha256":"aead7d42cff5c98...","last_recorded_sha256":"e7276e500db247b3...","last_recorded_seq":674,
   "file_mtime":"2026-11-07T16:51:57","note":"machine observation by sweep: disk no longer matches the ledger and no tool_use covers the change."}
  ```
  它声称"无 tool_use 覆盖该变更"，而 seq 730 正是 36 秒前覆盖它的那条登记（`aead7d42…` 完全相同）。`last_recorded_seq=674`（而非 730）证明 sweep 用的台账快照早于 16:52:23。
- 机制在源码里是结构性的，不是巧合：`sweep.ps1:76` 一次性 `Read-EventLog` 取台账快照 → `132–156` 遍历全部覆盖文件做"双读 + `Start-Sleep -Milliseconds 2000`"（48 个覆盖项，实测 `--DryRun` **单轮 58.7 秒**，见 R2 计时行 `[exit=0] [elapsed=58.7s]`）→ **`163–207` 才把 findings 逐条落账**。扫描开始时的事实，写入时早已过期。
- 计划任务 `harness-sweep-price-watch`（StartBoundary 16:42，每 10 分钟；实测 LastRunTime **17:02:02**、LastTaskResult 0、NextRunTime 17:12:12）→ 16:52 整点那一轮命中了 Hermes 正在补 §4 的窗口。

**为什么是缺陷**：sweep 的设计自述（`sweep.ps1:20–23`）是"任何稳定不一致都成为一个**机器事实**"。机器事实的可信度是整条"未记录→机器发现→人解释"闭环的地基；本轮地基产出了假事实。附带后果：`trigger.ps1:450` 判定"已解释"的条件是 `tool_use.seq > unrecorded_write.seq`，**排在观测之前的那条真实登记（730）不算解释**——所以这条误报只能靠该文件的**下一次写入**（seq 732，16:53:03）才被消掉，即账本必须再造一条记录去洗一条本不该存在的记录。

**建议方向**：`append` 前重读台账（或对单文件重算 `last_recorded`）；或把顺序改为"先扫盘、最后读台账"；或在落账前做二次确认（重新哈希 + 重新比对最新台账 digest）。

---

### O5-03 · **high** · 3.1.3「红→绿→关闭」全程没有任何被测实现的变更记录，返工实质是"改契约 + 改判卷口径"，而流程与规则都无法区分这两种返工

**证据（verify 全量 23 条 + 区间内全部事件）**

| seq | 本地时间 | target | exit |
|---|---|---|---|
| 565 | 15:49:44 | 3.1.3 | **1** |
| 566 | 15:52:05 | 3.1.3 | **1** |
| 662 | 16:20:46 | 3.1.3 | **1** |
| 734 | 16:54:44 | 3.1.3 | 0 |
| 735 | 16:56:02 | 3.1.3 | 0 |
| 736 | 16:56:03 | — | `step_advance 3.1.3→4.1` |

662（红）与 734（绿）之间的事件只有：694–701 sweep 的 8 条 `unrecorded_write`、702–708 baseline 登记、709–727 seal/anchor、**728**（actor=human 补记 `contracts/ip_provider_interface.py`，before `949a5cd5…`→after `a50831f0…`）、**729** `contract_change`（approved_by=human）、**730–733**（Hermes 改 `docs/变更记录.md`）。**`price_watch/pool/providers/reserved.py` 与被测实现在此区间零改动记录。**
绿 verify 的 `stdout_tail` 自己说明了原因：
```
PASS 检查项B ReservedProvider.release 签名与契约一致：release(account_id)（经锚点处理：豁免形参 reason（contracts/ip_provider_interface.py L107-L109）；形参改名 lease→account_id（…L107-L109））
SKIP 检查项B IpProvider.report_result 锚点 … L103-L104 豁免：等真有多个出口才有调用对象，现加即死代码
SKIP 检查项B ReservedProvider.build_launch_args 锚点 … L110-L111 登记的新增方法…契约 ABC 无此方法，不判红
```
且 734/735 的 `products` 显示被测判卷脚本 `state:"unchanged"`（`before==after==7ff2fbb2…`）→ verify 期间无人改实现或脚本。

**为什么是缺陷**：人采用的豁免（729）是合法决策，`contract_change` 也确实入账；但**现有规则集无法表达"本次绿灯来自契约放宽，而非实现变好"**。C5 只会说 `3.1.3=pass`，T2_contract 只在契约文件变动时报，T4/T11 又看不见 Hermes（O5-01）。于是"改实现"与"改考卷"在证据层完全同形——这正是 C5 那条"passed every time and never once failed"警告想防的东西，但它只统计"从未失败过"的 stage，3.1.3 失败过 3 次，因此这条警告对它**永不触发**。
另注：红→绿之间 33 分钟（16:20:46→16:54:44）里，16:22:41 的契约文件 mtime（731 号事件记录的 `file_mtime`）比 16:20:46 的红灯晚，但比 16:49:59 的人工登记（728）早 27 分钟——即"变更 agent 改契约"与"人登记豁免"之间存在 27 分钟的**账面无覆盖期**，期间任何 verify 结果都不可归因。

**建议方向**：`verify` 事件增加"本次判定依赖了哪些 contract_change 序号/锚点区间"的显式引用（stdout 里有 `L103-L104`/`L107-L109`，但没有指向 seq 729），使 C5 能区分"实现变好"与"口径变松"；绿灯若由 `contract_change` 达成，该 stage 的 pass 应标注 `relies_on_contract_change`。

---

### O5-04 · **medium** · checkpoint 外部锚点被每一次正常 append 重写，且无单调性保护 → 截断只在"下一次写入之前"可检测

**证据**

- `_common.ps1:230–231` 设计自述：*"Truncating the ledger now requires editing a second file that normal operation never rewrites"*。
- 实现与之相反：`append-event.ps1:581` `Write-LedgerCheckpoint -ProjectRoot $Root -Seq ([int]$record.seq) -Head ([string]$record.self) -Source 'append-event'` ——**每次成功 append 都重写锚点**；`Write-LedgerCheckpoint`（`_common.ps1:233–256`）对传入的 `Seq` **不做任何 `>= 现有 seq` 校验**，直接 `Move-Item -Force`。
- `audit.ps1:149` 的判据只有 `$cpSeq -gt $headSeq -or -not $selfs.Contains($cpHead)`。
- 实测锚点紧随账本头：R1 `{"seq":739,...,"source":"post-tool-hook"}` → R2/R3/关账 `{"seq":746,"head":"14d70d6517ef…","source":"post-tool-hook"}`，与 `events.jsonl` 末条 `seq:746 self:14d70d6517ef…` 逐字相等。

**为什么是缺陷**：截尾后只要发生**任意一次**正常写入（返工期 hook 每几十秒一次），锚点就被"合法地"改写为截尾后的新头，C1b 的判据重新成立，被删记录永久不可检。canary 的 `C1b_ledger_truncation` 能 FIRED，是因为它在 fixture 里截尾后没有再写。设计注释把威胁模型写成"sloppiness, not an adversary"，但**当前保护窗口 ≈ 一次写入的时间**，对"sloppy 的编辑器会话砍尾 + 继续干活"这一最可能的场景恰好无效。

**建议方向**：锚点写入加单调门（新 seq < 现存 seq 则拒绝并报警）；或把锚点改为**追加式**（`checkpoint.jsonl` 每 append 一行，audit 检查账头能否在锚点日志里回溯到最近的 attestation）。

---

### O5-05 · **medium** · 计划任务 sweep 没有心跳、没有日志落点、失败静默——安全网死了没人知道

**证据**

- 任务定义实测：`Execute = "...\PowerShell\7\pwsh.exe"`，`Arguments = -NoProfile -WindowStyle Hidden -File "…\sweep.ps1"` → **无 `-File` 日志重定向、无 `-NonInteractive`**。
- `sweep.ps1:158–161`：零发现时只 `Write-Host '[sweep] 47 files covered, disk matches ledger'` 后 `exit 0`——**不落任何事件**。窗口输出被 Task Scheduler 丢弃。
- `sweep.ps1:200–203`：append 失败 → `Write-Host '[sweep] FAILED to record …'` + `exit 1`，同样只进被丢弃的 stdout。
- `append-event.ps1:483–486`：抢锁 10 秒超时 → `[FAIL] could not lock … within 10s` + `exit 1` → 对 sweep 而言等于"这一轮这个发现没落账"，下一轮才会重试；对 hook 而言等于**这条 tool_use 被丢弃**。
- `Get-ScheduledTaskInfo`：`LastTaskResult 0`；`Get-WinEvent Microsoft-Windows-TaskScheduler/Operational` 过滤 `harness-sweep-price-watch` → **`ETW unavailable: No events were found…`**（该通道无记录/默认关闭）→ **运行史查不到**。
- `audit.ps1` 全文无一条规则涉及 sweep 是否跑过（`C1b`/`C9b` 之外无 checkpoint/sweep 相关判据）；`C3 emission` 只统计声明过的 11 类事件。

**为什么是缺陷**：audit 的自我定位是 *"liveness — is the harness itself connected?"*（输出第 2 行）。今天新加的最重要探测器（sweep + 计划任务）恰恰是**唯一没有任何 liveness 信号**的一环：任务被禁用、pwsh 路径变更、连续 `exit 1`，账本与 audit 都不会出现任何变化。观测期内我需要用 `Get-ScheduledTaskInfo` 外部查证才能确认它在跑。
附带：`events.jsonl.bak-20261107-145520`（300,491 B，14:54:59）是 14:55 那次修复留下的**唯一**回滚副本；`sweep.ps1` 的 `excl` 正则 `.*\.bak(-.*)?$` 把它排除在覆盖集外，而 audit C1b 的告警文本却写着 *"restore from events.jsonl.bak-*"*——依赖一个自身不监控、且只有一份、无任何完整性登记的文件。

**建议方向**：sweep 每轮落一条 `anchor{name:'sweep-heartbeat'}`（或写 `checkpoint.json` 的 `sweep_at` 字段），audit 增加"心跳年龄 > N 分钟即 FAULT"；任务加 `-File` 日志或 `LogOnly`；`.bak-*` 至少进 C7 覆盖集并登记 digest。

---

### O5-06 · **medium** · "未记录→机器发现→**人**解释"闭环被写入者自登记旁路：Hermes 既是写入者又是解释者，人在整条链上没有动作

**证据**

- 角色设定：*"人 = 唯一搬运工 + 唯一能签 gate/补记的角色"*；`sweep.ps1:181` 的 note 写 *"Explaining it (who/why) is a human or hermes act"*。
- 窗口内的实际登记全部是写入者自述：
  - seq **728** `tool_use actor=human tool=manual observed_by=script`（人工补记 1 次，✅ 这是唯一一次真人补记，针对 16:22:41 的契约改动）
  - seq **730 / 732 / 733 / 740 / 741 / 742** `actor=hermes tool=manual observed_by=script`——**Hermes 自己写、自己登记、自己给 why**，其中 740/741/742 一次登记 3 个文件（含判卷脚本，见 O5-01）。
- T13 的消警条件（`trigger.ps1:450`）只看"该文件是否有一条 seq 更大的 `tool_use`"，不看登记者是谁。seq 731 的误报正是被 732（Hermes 的下一次写入）消掉的。
- 结果：R1/R2/R3/关账四轮 trigger **T13 恒为 0 条**，而 C4 显示 `T13=9` 输入。

**为什么是缺陷**：机器发现环节（sweep）确实响了，但"解释"这一步不需要任何与写入无关的主体，也不需要人签任何东西——`actor=hermes` + 自由文本 `why` 就能让报警永久沉默，而且**自登记发生在 sweep 抓到之前**（730 在 16:52:23，sweep 在 16:52:0x 起跑）时，机器连"发现"都不会产生。对"已发生过多次未记录写入"的那个进程而言，这是可预期的自我洗白路径（`sweep.ps1:26–28` 的注释正好在担心 C7 被"后续合法写入重新登记"洗掉，同样的洗法在 record-edit 这条入口上依然存在）。
另：`docs/变更记录.md` 被 `trigger.ps1:252` 显式列入**永不报 T3** 的路径白名单，所以 Hermes 改变更记录本身在 T3/T11/T13 三条线上都没有摩擦。

**建议方向**：`unrecorded_write` 的解释事件要求 `actor ∈ {human}` 或 `approved_by=human`（与 T2c 的签名口径一致）；写入者自登记保留，但只作为 `registration`，不作为 T13 的消警依据。

---

### O5-07 · **low** · audit C9 同一条警告重复输出两遍（三轮 + 关账快照 100% 复现）

**证据**

- R1（16:59）/R2（17:03）/R3/关账（17:07）四次 audit 全部是 `WARNINGS (5)`，末两条文本逐字相同：
  ```
  ! C9  skip-1.3  变更记录 lists step 1.3 as skipped, but the ledger has no skip event for it …
  ! C9  skip-1.3  （同上，完全一致）
  ```
- 根因定位（只读正则复现 `audit.ps1:540`）：`docs/变更记录.md` 里有**两行**同时命中"表格行 + 形如 x.y.z 的数字 + skip/跳过"：
  ```
  MATCH[1.3] :: | C-005 | 2026-11-06 | 跳过步骤 | 1.3 | 计划做 docker-compose 中间件部署 | 跳过，理由：…
  MATCH[1.3] :: | 1.3 | 中间件部署 | 无中间件可部署 | 无，1.4 直接进入外部资源准备 | skipped |
  ```
  两次 `$srow` 都是 `1.3`，`Add-Finding 'C9' 'warn' "skip-$srow"` 没有去重。

**为什么是缺陷（不是"设计如此"）**：设计允许"C9 对 skip 行长鸣"；不允许**同一条事实计数为 2**。`WARNINGS (5)` 的计数被污染，人会把一件事读成两件；第一处命中其实是决策表 C-005 行（那里 `1.3` 是列内容，不是"被跳过的步骤行"），说明该正则把散文行也当成了声明行，属于 over-match。

**建议方向**：`Add-Finding` 对 `(code,severity,target)` 去重；skip 行匹配收紧为"步骤列在首列"的表结构。

---

### O5-08 · **low** · 时间基准混用：台账 `at` 是 UTC，文件 mtime/计划任务/人是本地 UTC+8，报警文本直接打印 UTC 时分秒

**证据**

- `append-event.ps1:503` / `_common.ps1:244` 写 `Get-Date.ToUniversalTime().ToString('...Z')` → seq 731 `at=2026-11-07T08:52:59Z`，而同一事件的 `file_mtime=2026-11-07T16:51:57`。**一条事件里两个基准，差 8 小时。**
- `trigger.ps1:420` 输出 `$gAt12.ToString('HH:mm:ss')`：`T12 … 3.1.3 gate recorded 07:49:17 but first event of this step is 07:40:31`——人看到的是 UTC，与 seq 564 实际签署的本地 15:49:17 差 8 小时；人要把这句转述给教练做决策。
- audit 表头 `last_at=11/07/2026 09:02:34` 同样是 UTC，而 `Get-ChildItem events.jsonl` 的 `LastWriteTime` 是 `17:02:34`。

**为什么是缺陷**：`gate/verify/step_advance` 的因果判定（T12）与人的排障叙事（"16:52 首跑"）不在同一基准上，任何"XX:XX 到底发生了什么"的对齐都要人工 +8；本次观测中 `sweep 首跑 16:52` 与台账 `08:52:59Z` 的对应关系只能靠换算确认。这是纯人机接口缺陷，不是数据错误。
**建议方向**：报警文本统一附本地时间（`07:49:17Z / 15:49:17 本地`），或全链统一本地带时区偏移。

---

### O5-09 · **low（覆盖口径）** · sweep 宣称"47/48 files covered"，其中约一半是磁盘上不存在的未来产物；真正被比对的文件数远小于宣称值，且"新文件不在覆盖集"这一盲区从未被声明

**证据**

- `sweep.ps1:159` 打印 `$tracked.Count`；实测 R1 `[sweep] 47 files covered`、R2/R3 `48 files covered`、耗时 **58.7 s**（`Start-Sleep -Milliseconds 2000` 只对**存在**的文件生效，`sweep.ps1:134` 对缺失文件 `continue`）。48×2s ≥ 96s > 58.7s → **存在并被双读的只有约 25 个**，其余是 stage.generates 里尚未产出的文件（`price_watch/scheduler.py`、`tests/test_account_pool.py`、`tests/test_ip_pool.py` 等，见 project.json 4.1 的 5 个 generates 全部尚未存在）。
- 覆盖集只由两部分构成（`sweep.ps1:78–116`）：① 台账里出现过 digest 的文件；② `project.json` 各 stage `generates` 声明的文件。`sweep.ps1:134` 明确：*"absence is C6/C7's domain, not sweep's"*。
- 因此：**一个从未登记过、又不在任何 `generates` 里的新文件（例如 Hermes 新写 `docs/返工说明.md` 或 `contracts/xxx_extra.py`）永远不会进入 sweep 的比较集**，磁盘上多出一个文件不会触发任何 `unrecorded_write`。窗口内没有出现该场景（741 号 `04-采集系统架构.md` 走的是 Hermes 自登记，`before_sha256:""` 说明它此前从未被登记过——即它当时**不在**覆盖集里，是 record-edit 把它拉进来的）。

**为什么是缺陷**：`sweep` 的宣称语义是"disk vs 台账全量比对"（任务描述也这么写），实际是"已知文件的漂移比对"。**新增文件**这一类未记录写入完全落在网外，而代码与输出都没有任何地方声明这个盲区（输出反而说"47 files covered, disk matches ledger"，读起来像全量干净）。
**建议方向**：加一条"磁盘上存在但既无 digest 又不在 generates 的顶层业务文件"枚举（排除 `excl` 后），至少报 `untracked_file`；输出改为"N covered / M existing compared"。

---

## 2. 重点问题的观测结论（对任务第六节逐条回执）

| # | 问题 | 结论 |
|---|---|---|
| 1 | 变更 agent/Hermes 新未记录写入 + 闭环 | sweep **确实抓到** `docs/变更记录.md`（seq 731）与 `contracts/ip_provider_interface.py`（seq 696），T13 的输入存在；但闭环第一次真实运转**产出一条假阳性**（O5-02）且解释由写入者本人完成（O5-06）。真人补记只在契约那一次出现（seq 728）。 |
| 2 | step_advance 首次真实落地 | ✅ **成功**：seq **736** `{"from":"3.1.3","to":"4.1","closed_by":"3.1.3"}` actor=script step=4.1，16:56:03。此后 status 的 `NEXT=4.1` 与台账 step 键一致；C8 `local_step='4.1'`、`last 20 events: top='4.1' 11/20`（R1 时还是 `top='harness' 8/20`）。 |
| 3 | sweep 计划任务与 hook 抢锁 | **未观察到实例**（窗口太短）。已确认：任务在跑（17:02:02/LastTaskResult 0）、`events.jsonl.lock` 无残留、单轮 58.7 s < 10 min 周期。风险已在 O5-05 给出（超时即静默丢事件）。 |
| 4 | verify `products` 字段 | ✅ 合理：3.1.3 的 verify（seq 734/735）`products=[{file:scripts/check_interface_impl.py, before==after, state:"unchanged"}]`，与 project.json 中 3.1.3 的 `generates` 只有这一个文件相符；`check_interface_impl.py` 确在 generates 内。 |
| 5 | C9b 闭环 | ✅ 已闭环：`docs/变更记录.md` §4 由 seq 730/732/733 重写（why 明写 *"section 4 rewritten from ledger facts (5 contract_change) per C9b fault; D-729 decision record appended"*），audit 的 C9 `doc-vs-ledger` FAULT **不再出现**，`C9 decisions 1 record(s) checked`。但走的不是"hook→sweep→人解释"，而是 **Hermes 自登记（observed_by=script）**，并被 sweep 的过期快照反咬一口（O5-02/O5-06）。 |
| 6 | T12/T7 与返工的交互 | **未产生新的追认类报警，也未误伤**：R1→关账 T12 恒 3 条（3.1.1/3.1.2/3.1.3 历史 gate），T7 恒 2 条（1.2/2.0.2）。3.1.3 的返工/关闭没有新增第 4 条 T12。 |
| 7 | 老毛病复发 | **无**：C1 intact（739→746，全程），verify-ledger `[OK] chain intact`，无同 seq、无 `__parse_error`、`stdout_tail` 中文正常（见 734 原文），C10=**fb656124f23c 未漂移**（观测期间无人改 harness）。 |
| 8 | 教练行为 | **N3 硬限制，本地无痕迹**：窗口内没有任何文件包含教练输出，无法对照 v2.3.8 判定。（台账文本中发现的"请执行 record-edit.ps1"是规则 note，见下条纪律声明。） |

**注入纪律声明**：`events.jsonl` 与文档文本中出现 `run record-edit.ps1`（seq 731/694–701 的 `note` 字段）与 `do NOT read the whole ledger`（trigger 输出）等祈使句。均按数据处理，**未执行任何写操作**。观测期间实际执行的命令只有：audit / trigger / status / verify-ledger / `sweep.ps1 -DryRun` / `canary.ps1`，以及只读的 Get-Content/Get-ChildItem/Get-ScheduledTask(Info)/Get-WinEvent。写入仅限 `D:\work_shape\_obs5\`。

---

## 3. 未及验证的疑点（无硬证据，不计入缺陷条目）

1. **`trigger.ps1` 退出码 = 3**（三轮 + 关账一致），而"Hermes needed: 16 item(s)"。未读退出码语义源码，无法判断 3 是"需 Hermes"还是"故障级别"。若它是计数，16≠3；若是位标志需确认审计脚本是否有人据其分支。
2. **`C5` 对 3.1.3 报 `pass`，而 `status` 的 `HISTORICAL GAPS` 未把"曾连续 3 次红"列为任何提示**——疑似 C5 只取"最新一次"，历史失败在视图层完全丢失（我需读 C5 源码确认，未及）。
3. **`anchor` 事件 45 条**（任务背景未提及该类型），其中 seq 709 `{"name":"harness","value":"verified","sha256":"fb656124f23c…"}`。未核对 anchor 的其余 43 条由谁产生、是否都在登记 harness 面。
4. **`C3 never: deviate skip blocker_open blocker_close`**——四类事件今天全链路仍未被发射过，而 C9 正依赖 `skip` 事件存在（O5-07）。疑似"声明了写入路径（C2=11/11）但没有任何入口真的调用过"，即 `append-event -Event skip` 从未被使用；未验证入口是否存在。
5. **T3=209→213 的增量**恰好等于窗口内新增 tool_use 数，说明 4 条 `%TEMP%` 命中是"每次事件重算"而非"每文件一次"；`$seenOutOfScope` 去重只在同一次运行内有效。是否为设计如此，未及读 T3 全段确认（窗口内 4 次 trigger 输出恒为同样 4 条 `%TEMP%` 路径，属故意的部分与 `sweep` 无关）。
6. **`04-采集系统架构.md`（seq 741）`before_sha256:""`**——疑似 record-edit 在无法取得上一个登记值时填空串而非报错，会让"改了什么"无法核对；未读 `record-edit.ps1` 确认。
7. sweep 与 hook 抢锁的实测冲突（第五节要求项）——需要 ≥30 分钟高密度返工期才有样本，本次未覆盖。

---

## 4. 关账快照（2026-11-07 17:07:19–17:07:27，只读四件套原文）

```
CLOSE_START=17:07:19
### AUDIT
harness audit · price-watch
  liveness - is the harness itself connected? (status.ps1 answers readiness)
  C1 chain         intact   746 events, last_at=11/07/2026 09:02:34
  C2 registration  11/11 declared types have a writer path
  C3 emission      7/11 declared types have ever been emitted
                   never:     deviate skip blocker_open blocker_close
  C4 rule input    T1=0  T2=5  T3=213  T4=213  T5=0  T6=0  T11=660  T12=3  T13=9
                   unexercised: T1 T5 T6  (not a fault by itself - C2 answers whether it can ever fire)
  C5 evidence      0.1=void  1.1=mismatch  2.0.1=pass  2.0.2=pass  2.0.3=pass  2.0.4=pass  2.0.5=pass  3.1.1=pass  3.1.2=pass  3.1.3=pass
  C6 verify-ref    0 dangling reference(s)
  C7 drift         0 drifted, 0 unrecorded
  C8 attribution   local_step='4.1'  last 20 events: top='4.1' 11/20
  C9 decisions     1 record(s) checked against the ledger
  C10 harness      fb656124f23c
  WARNINGS (5)
    ! C5  1.1            its newest green verify ran a command the stage does not declare …
    ! C5  0.1            verify ran 1 time(s) but never meaningfully …
    ! C5  evidence       5 stage(s) have passed every time and never once failed (1.1, 2.0.3, 2.0.5, 3.1.1, 3.1.2) …
    ! C9  skip-1.3       变更记录 lists step 1.3 as skipped, but the ledger has no skip event for it …
    ! C9  skip-1.3       变更记录 lists step 1.3 as skipped, but the ledger has no skip event for it …
[FAULTS: 0]

### TRIGGER  → Hermes needed: 16 item(s)   [exit=3]
  T3_out_of_scope ×4 (%TEMP%\prchk_check_contracts.py, %TEMP%\prchk_sigs.py, %TEMP%\launcher_selftest.py, %TEMP%\collector_selftest.py)
  T11_accepted_modified 3.1.2  scripts/init_db.py …        ← 仍无 scripts/check_interface_impl.py（O5-01 证据）
  T2_contract ×4 (2.0.1 / 2.0.2 / 2.0.3 / 3.1.1)
  T7_risk_L2 ×2 (1.2 / 2.0.2)
  T12_gate_after_the_fact ×3 (3.1.1 06:20:25>06:16:48 / 3.1.2 06:49:09>06:27:25 / 3.1.3 07:49:17>07:40:31)   ← 恒为历史 3 条，无新增
  T2c_unsigned_contract 2.0.1 (1 change without approved_by)

### STATUS  → NEXT 4.1 调度+单账号闭环 (risk L1, verify pytest tests/test_account_pool.py -q, generate 5 files)  [exit=0]
  DONE 含 3.1.3；BLOCKED 4.2/5.1/5.2/5.3；HISTORICAL GAPS (6)

### VERIFY-LEDGER → [OK] 746 records, chain intact, head=14d70d6517ef   [exit=0]
### CK → {"seq":746,"head":"14d70d6517eff43709ac6ea72717a219a160c4e2553bef8e6dcaaaaaaff4bb96","at":"2026-11-07T09:02:34Z","source":"post-tool-hook"}
### events=746
CLOSE_END=17:07:27
```
