# O6 观测原始记录（滚动）

被观测根：`D:\work\price-watch-demo`；观测者只读命令集（canary/audit/trigger/status/verify-ledger/sweep -DryRun）。
窗口：11-09 08:15 起。

## 基线（08:15:2x）
- 开局 canary：**9/9**（旧 kit：trigger 35477B/audit 35715B/sweep 11464B/canary 11475B，mtime 11-07 17:1x）
- events.jsonl 776 行，head fc374bb049f7，checkpoint seq=776 at 2026-11-07T09:12:20Z，sha(全文件)=0F4C6B37…
- audit：0 FAULTS / 4 WARNINGS（C5×3 + C9 skip-1.3）；C4 无 T14；C8 local_step='4.1'；C10 2b04faf80b74
- trigger：**17 条**，含 `T11_accepted_modified 4.1 scripts/check_interface_impl.py … modified under step 4.1 with no contract_change`（即 seq 740 那次判卷脚本改动）
- status：NEXT 4.1（risk L1，verify pytest tests/test_account_pool.py，generates 5 个）；HISTORICAL GAPS 6
- verify-ledger：[OK] 776 records chain intact；sweep -DryRun：48 files covered, disk matches ledger
- 定时任务 harness-sweep-price-watch：LastRun **08:12:00 Result 0**，每 10 分钟；sweep-status.json **不存在**
- 机器：LastBootUpTime 11-07 15:15:41（未重启，隔夜为睡眠/关机）；TaskScheduler  Operational 日志无可匹配事件

## 08:16:25–08:16:51 主 agent 改检测器（T14 + 心跳落地）
trigger.ps1 08:16:25、audit.ps1 08:16:37、sweep.ps1 08:16:43、canary.ps1 08:16:51；
改的**当时零事件**（777/778 只是 hook 的 Bash ls）；harness-kit templates\derive 同名文件同刻改，随后 Copy-Item 进项目（14/14 现在模板==部署，逐文件 sha 比对 SAME）。

## 08:18:38–08:18:48 重 seal（seq 779–797）
anchor harness（779）+ 18 条 seal tool_use；before 一律取"台账上一次记录值"，trigger 7c019600→dc474d98、audit 3460b7e0→0d659f94、sweep 6391c883→434b8da2、canary 85ce47ae→1170aed4。
C10 由 2b04faf80b74 → **7353781bb227** 并匹配，无 fault（符合"中途漂移与重新 seal 如实记录"）。

## 头号事实：trigger 上线即死（08:18:51 起，6 次复现）
`trigger.ps1: The property 'Count' cannot be found on this object.`
根因（源码级）：trigger.ps1 L239 `$prodsT = if ($null -ne $ppP) { @($ppP.Value) } else { @() }` → 语句式赋值下空数组被枚举成 **$null**；L241 `$prodsT.Count` 在 `Set-StrictMode -Version Latest`（L55）+ `$ErrorActionPreference='Stop'`（L56）下抛错，整个脚本中止。
语义错得很讽刺：L233-235 注释写明"没有 products 的记录**按构造豁免**"，而豁免分支正是崩溃分支。
真实台账上先撞的是**历史 FAIL→PASS 翻转**：2.0.1 seq25→35、2.0.2 54→64、2.0.4 120→121（三条都无 products 字段）；3.1.3 662→734 有 products(1)。
本地语义复现（不碰项目）：`$x = if($false){@('a')}else{@()}` → `$x -eq $null` 为 True；`.Count` on null THROWS 同一条消息；单元素分支 type=PSCustomObject，`.Count`=1 侥幸可用。
后果：Hermes 工作队列自 08:18:51 起为 0 条输出（原 17 条），T14/T11/T13 全部无法递交，而 4.1 写码正在发生。canary 11/11 全绿但抓不到（夹具永远带 products）。

## 心跳与巡逻
- 08:12:00 定时 sweep（旧脚本）Result 0 → 台账无事件、无心跳文件：**巡逻跑过而事实层无痕**
- 08:18:38 心跳出现（人工 sweep，非定时）：`{"last_run":"2026-01-09T00:18:38Z","covered":48,"findings":0,"recorded":0}` 实际 2026-11-09
- 08:22:00 定时 tick（新脚本）→ **Last Result 1**，心跳未更新；08:23:13 Status Ready / Next 08:32
- sweep.ps1 源码：exit 1 只可能 L73 或 **L224-226（append-event 失败即 exit 1）**；而心跳写在 L235-240（findings>0 分支）/L160-165（clean 分支）——**L226 的 exit 1 在写心跳之前**，出事的这一轮恰好不留心跳
- sweep `-DryRun` 不写心跳（L160/L235 `if (-not $DryRun)`），且 08:23:45 那次从 System32 CWD 跑通 exit 0 → 我的只读命令无副作用（08:17 与 08:18:29 两次证实文件缺失）
- sweep.ps1 `$excl` L84 **刻意排除 `.harness/`**（注释：harness 漂移归 seal/C7b/C10），所以主 agent 改检测器永远不会成为 unrecorded_write

## 头号缺陷正样本：hermes 写入无 before 图像（08:1x 溯源完成）
before_sha256 三条来源（源码级）：
1) hook Edit/Write：PreToolUse 写 `docs/_snap/<step>/<name>.before.sha` 边车（写下"这一刻"的真实摘要），PostToolUse 读后 **unlinkSync 删除**（故全盘 0 个 .before.sha 属正常，不是失灵）；缺失时回退 2) 台账尾部该路径最后 sha256；再退 3) 步骤首图 `…\.before` 的哈希；都无 → 空串（post-tool.mjs L204-235）
2) hermes/script 自登记：走 append-event L425-441，`observed_by` 缺省填 'script'，before 只做**台账推算**（扫全台账取该文件最后一条 tool_use 的 sha256），无边车、无快照
seq 740/741/742（11-07 17:01:34/35/37，actor=hermes，observed_by=script，同一 why）：
- 740 check_interface_impl.py before=7ff2fbb2（来自 734/735 verify.products 的台账推算）→ 有摘要、**无字节**（7ff2 内容永久不可比对）
- 741 04-采集系统架构.md **before_sha256=""**（该文档此前从未被登记过）→ 内容与摘要双失；文件 mtime 17:01:12，登记滞后 23s
- 742 docs/变更记录.md before=2b7ba32a（=733 的 after）；文件 mtime 17:01:32，滞后 5s
- 740 对应文件 mtime 17:00:54 → 登记滞后 **40s**
- 全台账 tool_use 690 条：`file` 存在但 before_sha256 为空 **52 条**（含 hook 首次创建与 702-708 基线登记、741）；带 observed_by=script 且空 before 12 条；before==after 的 no-op 图像 385 条（seal 类）
- `docs/_snap/` 各步骤首图机制自 2.0.1 起存在（27 文件），**3.1.3 目录停在 11-07 15:45**，即 seq 740 那批 hermes 写没有任何首图；4.1 目录 08:22-08:25 由 hook 正常填齐（含 __init__.py、check_interface_impl.py）
结论：缺陷不是"没有 before 机制"，而是 **before 机制只覆盖 hook 的 Write/Edit/MultiEdit/NotebookEdit**；PreToolUse matcher 不含 Bash，hermes 无 hook → 这两类写入永远只有（可能为空的）台账推算值。

## 二号问题答案（死锁补丁落账形态）——正在发生
08:23:08–08:26:55（actor=hook，step=4.1，observed_by=hook）：
- 806 Write price_watch/pool/account_pool.py（4.1 generates 内）
- 807-811,820 Write/Edit price_watch/scheduler.py
- **812 08:24:05 Edit price_watch/pool/__init__.py** f67f13d3→8c333705：新增导出 `AccountPool/AccountLease/SqliteAccountPool`（L32-34）+ `from contracts.account_pool_interface import …`（L40）+ `from price_watch.pool.account_pool import SqliteAccountPool`（L41）→ 满足 A1×2，**该文件不在 4.1 generates**
- **813/814/815 08:24:24-35 Edit scripts/check_interface_impl.py** ff54f049→5ce777d7→dbec3fb2→2d961ce1：新增 `ACCOUNT_POOL_ANCHOR{impl_classes:("SqliteAccountPool",)}`（L453）、`ANCHORED_INTERFACES["AccountPool"]=`（L465）、`exempt_impls + tuple(ACCOUNT_POOL_ANCHOR["impl_classes"])`（L326）、新断言 `check_account_pool_subclass`（L468）+ main() 调用（L497），源码注释自称"4.1 追加（上面那行原样不动）""ACCOUNT_POOL_ANCHOR 的字面内容按教练本轮授权只有 impl_classes 一项""本轮只加这一段 + main() 里那一句调用"
- **零 contract_change、零 project.json 变更**（.harness/project.json 仍 mtime 11-07 14:26:14 sha 289a595ebd7d → `__init__.py 进 generates` 没走 profile）、**零 gate、零 anchor（除 seal）、零 validate-profile 痕迹**；授权只以**被判卷脚本自己的注释**存在
- 818/819 tests/test_account_pool.py 已创建（4.1 verify 前置到位）；08:25:31 时点 test_account_pool.py 尚 ABSENT→08:25:43 出现
- 3.1.3 补账 verify 尚未发生（今日 verify=0）；docs/变更记录.md、04 文档今日未动（仍 11-07 17:01）
- 关键连锁：R1 trigger 正在报这条 T11（check.py 属已验证 3.1.3、在 4.1 下被改、无 contract_change），而 trigger 在改后 2 分钟死掉，2 分钟后同一违规第二次发生 → 检测器死在案发时刻

## 常规项
- 链：verify-ledger 776→798→806→824 全程 [OK]，checkpoint seq 单调（776/778/798/801/817/824），无同 seq/乱码/断链
- 今日事件构成（777 起，至 08:25）：tool_use 29 = seal 18 + Bash 6 + Edit 3 + Write 2；anchor 1（seal）
- 未出现：contract_change、gate、verify、skip、deviate、blocker；C3 仍是 7/11（deviate/skip/blocker_open/close 从未发射）
- T3 %TEMP 历史条：R1 4 条（prchk_check_contracts.py、prchk_sigs.py、launcher_selftest.py、collector_selftest.py）；trigger 死后再无输出可比
- C4 随账增长：T3 213→216→223，T11 688→709→716，T13 9，T12 3（历史三条长鸣，设计如此），T14 23（audit 计数，但 trigger 交不出）
- C7 0 drifted/0 unrecorded；C6 0 dangling；C9 1 record
- 根目录存在手工备份 events.jsonl.bak-20261107-{145520,170532,171204,171223}、checkpoint.json.bak-20261107-{170532,171204}（sweep 的 .bak 排除项覆盖）
- prompt-injection 复查：docs/变更记录.md 与 04 文档为数据；未见"请执行 X"类指令文本

## R6 08:34:53（843 条，链 OK）
- trigger 仍死（第 7 次复现，08:16:25 起 ≥18 分钟）
- 08:32:00 定时 tick **Result 0**，心跳更新 08:33:10（covered 48, findings 0）→ 心跳与定时巡逻已联通；08:22 那轮 Result 1 且无心跳（exit 1 在写心跳之前）
- C8 top 由 harness 19/20 → **4.1 20/20**
- 827-843 全是 hook Bash + 830 Edit account_pool.py + **841 Edit docs/变更记录.md**（bef=369cfb99=742 值 ✓，obs=hook）
- 831 命令原文（关键）：`.venv/Scripts/python.exe scripts/check_interface_impl.py | tail -3`（注释"本轮授权的第 7 处改动"）+ pytest 直跑"真实 schema.yaml，未对齐" + **内存 monkeypatch `db.load_schema = aligned`（"内存补丁，不落盘"）** 让 test_account_pool/test_ip_pool 变绿
- 838 命令原文：`### 3.1.3 verify … python scripts/check_interface_impl.py > /tmp/i313.txt`；839 `grep '^SKIP' /tmp/i313.txt`
  → **判卷脚本被 Bash 直跑，结果不入台账**（非 verify 事件）；证据文件落在 **/tmp（项目根之外）**：pre-tool.mjs 对 Write/Edit 出根即 exit 2 拒绝，但 **Bash 重定向不经 PreToolUse**，同一毛病换了条看不见的通道
- 837：agent 自写台账读取器按 `payload/ts/kind` 取字段（真实字段是 `data/at/kind`）→ 打印全空，ad-hoc 读台账重复实现且字段名错

## R7 08:45:36（852/853 条，链 OK）
- **补账发生**：844 verify step=3.1.3 exit=0（cmd=check_interface_impl.py，脚本已是 2d961ce1 即"被 4.1 改过的判卷器"）；845 verify step=3.1.2 exit=0（重验已收口步骤）；846 verify step=4.1 **exit=1 FAIL**
- audit 首次出 **FAULTS(2)**：`C5 4.1 latest verify FAILED`（设计正确，失败必须响）；`C7 0.1 docs/变更记录.md disk 4f7197b5 vs ledger 7980d53f 无事件记录`
  → 我随后在 08:46:09 复查：hermes 于 **08:45:49/52（seq 854/855）** 才登记 04 文档与变更记录 → **C7 那条 FAULT 是 08:45:41 读到未登记瞬间的撕裂读**；audit 无 sweep 式二次 settle/O5-02 复读，误报会指挥人去跑 record-edit 造出多余记录
- **847 gate（actor=human, by=elu9527-sudo, level=L2, step=4.1）why 字段被 NUL 吃掉**：168 字符里 **102 个 \u0000**，只剩 `3.1.1 4.1 accounts cooldown_until schema version 4.2` 等拉丁片段；全台账仅此 1 条控制字符记录；verify-ledger 依旧 [OK] chain intact → **签字理由被哈希链永久封缄成不可读**，且无任何规则检查载荷可打印性
- 4.1 风险位不一致：profile 4.1 risk=L1，847 gate 记 level=L2；trigger L374-382 只记"该 step 有 gate/该 level 有 gate"，T7 只用 profile risk → 等级口径错位无人判
- **854/855 hermes 写 04-采集系统架构.md + 变更记录.md（obs=script, tool=manual）**：
  - 04 文档 disk mtime 08:45:23 → 登记 08:45:49（滞后 26s）；变更记录 08:45:46 → 08:45:52（6s）
  - before_sha256=5db9ac29（台账推算）；**docs/_snap/4.1 里没有 04 文档的 .before** → 无字节快照；04 文档两次（11-07 17:01、11-09 08:45）都只有摘要、没有前一版内容 → **永久无法比对 hermes 对核心架构文档改了什么**
  - 04 文档不在任何 stage.generates（只有 docs/变更记录.md 属 0.1）→ **C7 结构上看不见 04**，唯一兜底是 sweep 10 分钟轮询（08:45:23 写 → 最长到 08:52 才可能被看见）
- _snap\4.1 新增 config__schema.yaml.before、docs__变更记录.md.before（hook 路径有字节 ✓）；04 无
- C4 计数：T3 261→267，T11 754→760，**T12 3→4**（新一条 gate-after-the-fact，对应 847 在 4.1 已开工后才签），**T14 23→26**
- schema.yaml 848/849 被 hook 改（5623f8ba→1d960ae2→ffbc1488），它属 2.0.1 产物 → 又一例跨边界写，detector 死着
- 3.1.3 verify 全史：565 FAIL / 566 FAIL / 662 FAIL（无 products）→ **734 PASS（products=check_interface_impl.py:unchanged）** → 735 PASS → 844 PASS
  → T14 的设计靶心正是 662→734：两次 PASS 之间该步唯一产物零写入、products 全 unchanged，**必然真响**；但脚本在 seq 35（2.0.1 历史翻转、无 products）就抛异常，**"历史豁免"分支自身把检测器打死，真阳性永远交不出去**

## R8 08:53:10（871 条，链 OK）
- trigger 仍死（第 9 次复现，outage 08:16:25→08:53+ ≈ 37 分钟）
- 心跳：08:52:00 tick → Result 0 → last_run 00:53:10（**记的是写完时刻**，C11 的"距上次巡逻 N 分钟"被 sweep 自身 60-96s 耗时污染）
- FAULTS(1) 只剩 C5 4.1=fail；R7 那条 C7 撕裂读 FAULT 自愈（854/855 已登记）→ 证实是 audit 无 settle 复读造成的瞬态误报
- 08:49:43 后 ledger 静默 3.5 分钟（C8 4.1 20/20）
- 846 之后**再无任何 verify 事件**（verify 总数 26，今日 3 条：844/845/846）；857/859/864/867/871 全是 Bash 直跑**阶段声明的那条 verify 命令**（"### 4.1 verify（阶段声明的那条）"、"最终三件套"），结果只活在 console
- 860 `TMP=$(mktemp -d)/v2.db` → 出根产物再例（Bash 通道不被 PreToolUse 管）
- 864/867 agent 手工自查"harness 该管的"：`grep xfail|skipif|pytest.skip|importorskip tests/`、"不许改的文件是否被动过"mtime 列表（列表里含本轮实际改过的 __init__.py 与 check_interface_impl.py）→ **补偿性自证走不可复核的 console 通道**
- 今日事件构成（777→871）：gate 1（847 NUL）、verify 3、contract_change 0、unrecorded_write 0、step_advance 0

## R9 09:02:51（884 条，链 OK）
- **4.1 收口**：872 08:57:53 verify exit=0（5 产物全 unchanged，23 passed）→ 873 08:58:08 同命令再 exit=0 → **874 08:58:08 step_advance 4.1→4.2（closed_by=4.1）**；875 08:58:18 **3.1.1 复验 exit=0（3 checks）**
- 872/873 间隔 15s 的两条同命令 PASS：一次 verify.ps1 + 一次 finish-step 自带 verify
- T14 对 4.1 应保持沉默（正例）：846 FAIL→872 PASS 之间对 4.1 产物有登记写入（850/851/852/856/858/862/863/866）→ writesSince>0；对 3.1.3 的 662 FAIL→734 PASS 则该步产物零登记写入 → **必为真阳性**，但 trigger 在 seq 35（2.0.1 历史翻转、无 products）即抛异常，正负都交不出
- **875 复验有副作用**：`init_db.py --migrate` 连跑两次并写 `data/price_watch.db`（schema_migrations version=2 applied_at 2026-11-09T08:58:17，"跳过（已存在）11 个"）→ 给已收口步骤"补证据"的命令本身改变更名世界；台账只记 exit=0，不记它写了库
- C5：4.1=fail → **4.1=pass**，FAULTS 归 0；C4 T3 283→292、T11 778→787、**T14 26→29**
- 心跳 08:53:10；09:02:00 tick 时 Status=Running / Last Result=267009(0x41301 正在运行)
- 4.2 立刻开工：876-882 Write/Edit price_watch/utils.py + tests/test_cooldown.py（均在 4.2 generates 内，边界这次是干净的）
- trigger 第 10 次复现仍死（08:16:25→09:02 = **46 分钟**），横跨 3.1.3 补账、4.1 交付+收口、__init__.py/判卷脚本/schema.yaml 三次跨边界写、人签的 NUL 乱码 gate
