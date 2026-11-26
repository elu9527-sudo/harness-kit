# O6 时间线（2026-11-09，观测窗口 08:15:15→09:59:46 实测，本地时间；台账 at 字段为 UTC）

| 时刻 | 事实（可复核坐标） |
|---|---|
| 08:15:2x | 开局 canary **9/9**（旧 kit）；台账 776 条、head fc374bb049f7；audit 0 FAULT / 4 WARN；trigger **17 条**（含 `T11_accepted_modified 4.1 scripts/check_interface_impl.py … no contract_change`）；status NEXT=4.1（L1、5 产物）；sweep -DryRun 48 covered 无差异；定时任务 LastRun 08:12:00 Result 0；`sweep-status.json` 不存在 |
| 08:16:25–51 | 主 agent 落地 T14+心跳：改 `trigger.ps1`(08:16:25)、`audit.ps1`(08:16:37)、`sweep.ps1`(08:16:43)、`canary.ps1`(08:16:51)；**改动当时台账零事件**（777/778 只是 hook 的 Bash ls） |
| 08:18:38 | 人工 sweep 写出首颗心跳 `last_run 00:18:38Z covered48 findings0`（非定时任务产物） |
| 08:18:42–48 | 重 seal：seq 779 anchor + 780-797 共 18 条 seal tool_use；C10 2b04faf80b74→**7353781bb227**；trigger 7c019600→dc474d98、audit 3460b7e0→0d659f94、sweep 6391c883→434b8da2、canary 85ce47ae→1170aed4（before 全取台账上一值，无边车） |
| 08:18:51 | **trigger 第一次崩**：`The property 'Count' cannot be found on this object`（L241，StrictMode L55 + EAP Stop L56）；Hermes 队列由 17 条→0 条 |
| 08:20–08:22 | 806 Write account_pool.py、802-805 ip_pool.py（Write 无 before=新建，Edit 链完整 5ad4adf2） |
| 08:22:00 | 定时 tick **Result 1**，心跳未更新 → 巡逻失败且不留痕 |
| 08:23:45 | 我的 `sweep -DryRun`（从 System32 CWD、绝对路径）exit 0，报 3 条"unrecorded change"（__init__.py/scheduler.py/check_interface_impl.py）——实为与 hook 登记的撕裂读（812 08:24:05、813 08:24:24 随后落账） |
| 08:24:05 | **seq 812** hook Edit `price_watch/pool/__init__.py` f67f13d3→8c333705：追加导出 AccountPool/AccountLease/SqliteAccountPool（该文件属 3.1.2 产物，不在 4.1 generates） |
| 08:24:24–35 | **seq 813/814/815** hook Edit `scripts/check_interface_impl.py` ff54f049→5ce777d7→dbec3fb2→2d961ce1：+53 行 0 删除（可 diff，因 PreToolUse 有 .before）；新增 `ACCOUNT_POOL_ANCHOR{impl_classes:("SqliteAccountPool",)}`、`ANCHORED_INTERFACES["AccountPool"]=…`、`exempt_impls + ACCOUNT_POOL_ANCHOR["impl_classes"]`（A2 放行名单放宽）、新断言 D；注释自称"教练本轮授权""上面那行原样不动" |
| 08:25:31 | 4.1 前置补齐：816-819 tests/test_ip_pool.py、818-819 tests/test_account_pool.py |
| 08:25:58 | 溯源完成：before_sha256 三条来源（pre-tool 边车 `.before.sha`→用后即删；post-tool 回退台账尾→步骤首图→空串）；append-event L425-441 只做台账推算且 observed_by 缺省填 'script'；PreToolUse matcher 不含 Bash |
| 08:26:55 | 模板==部署（14/14 SAME）；harness-kit 在 seal 之外 |
| 08:28–08:33 | 827-843：Bash 直跑判卷器与 pytest；**831 内存 monkeypatch `db.load_schema=aligned`**（"内存补丁，不落盘"）；**838/839 `check_interface_impl.py > /tmp/i313.txt`**（出根产物）；841 hook Edit 变更记录.md |
| 08:32:00 | 定时 tick Result 0 → 心跳 08:33:10（耗时 70s；`last_run` 记的是写完时刻） |
| 08:41:32 | **846 verify 4.1 exit=1 FAIL** → audit FAULTS(2)：`C5 4.1 latest verify FAILED`（设计正确）+ `C7 0.1 docs/变更记录.md 4f7197b5 vs 7980d53f 无事件` |
| 08:40:26 / 08:41:03 | 844 verify **3.1.3 补账 exit=0**（跑的是被改过的 2d961ce1 判卷器）；845 verify 3.1.2 复验 exit=0 |
| 08:43:25 | **847 gate（actor=human, by=elu9527-sudo, level=L2, step=4.1）why 含 102 个 NUL/168 字符**，仅剩 `3.1.1 4.1 accounts cooldown_until schema version 4.2`；verify-ledger 仍 [OK] chain intact；T12 计数 3→4（事后签） |
| 08:44:59 | 848/849 hook Edit `config/schema.yaml` 5623f8ba→1d960ae2→ffbc1488：**version 1→2 + 新增 cooldown_until**（2.0.1 产物，跨边界，无 contract_change） |
| 08:45:23/46 → 08:45:49/52 | **854/855 hermes 写 04-采集系统架构.md（5db9ac29→0d47399f）与变更记录（7980d53f→4f7197b5）**：滞后 26s/6s；`docs/_snap/4.1` 无 04 的 .before → 字节级 before 图像缺失（第二次复发）；04 不在任何 generates → C7 结构上看不见它 |
| 08:45:41 | 我那次 audit 的 C7 FAULT 属瞬态（854/855 在 8 秒后落账）→ audit 无 settle 复读，误报把人指向 record-edit |
| 08:47–08:53 | 856-871：改 test_account_pool.py/account_pool.py；**857/859/864/867/871 Bash 直跑"阶段声明的那条 verify"**，台账最后 verify 仍是 846 FAIL；860 `TMP=$(mktemp -d)`；864/867 agent 手工 grep `xfail|skipif|pytest.skip` 与"不许改的文件是否被动过"mtime 自查 |
| 08:52:00 | Result 0 → 心跳 08:53:10 |
| 08:57:53 / 08:58:08 | **872、873 verify 4.1 exit=0**（23 passed，5 产物全 unchanged）；**874 step_advance 4.1→4.2**（closed_by 4.1）；875 verify **3.1.1 复验 exit=0，命令连跑两次 `init_db.py --migrate` 并写 data/price_watch.db（schema_migrations version=2 applied_at 08:58:17）** |
| 09:00–09:05 | 4.2 开工：876-882 utils.py/test_cooldown.py（4.2 generates 内，边界干净）；890/891 verify 4.2 exit=0；**892 step_advance 4.2→5.1** |
| 09:02:00 | 定时 tick **未写心跳**（09:12:49 复查心跳仍 08:53:10）→ 该轮巡逻失败且无痕 |
| 09:08:39/51 → 09:08:53 | **896/897 hermes 写 config/runtime.yaml（86440bac→81c795a9）与变更记录（4f7197b5→02e2dd00）**：runtime.yaml 属 **2.0.1** 产物，`docs/_snap/5.1` 无 runtime.yaml 的 .before → **86440bac 内容永久不可比对**；897 why 自陈"5.1 gap line: matcher has no test_matcher.py in 5.1 generates" |
| 09:09–09:16 | 5.1 开工：898-925 matcher.py/price_engine.py/comparator.py/test_price_engine.py/test_comparator.py；913-925 反复 Edit |
| 09:12:00 | 定时 tick **Result 1**；我 09:15:13 的 -DryRun 抓到 `tests/test_comparator.py disk 32a5844 vs @seq 919 47f8f228 mtime 09:16:16` → 该轮确有 finding 且未能登记（今日 unrecorded_write=0） |
| 09:22:00 | Result 0 → 心跳 09:23:24 |
| 09:23:26/43/44 | 930/931 verify 5.1 exit=0；**932 step_advance 5.1→5.2**；C5 新增 4.1/4.2/5.1=pass，"从未失败"步骤由 5→7 |
| 09:24:09 | trigger 第 11 次复现仍死（outage 68 分钟）；C4 T14=33、T11=829、T3=332 |
| 09:31:12 | 台账静默（932 后 7.5 分钟无事件，5.2 刚开）；kit 自 08:16 未再改；C10 仍 7353781bb227 |
| 09:33–09:39 | 5.2 开工：933-942 Write/Edit `price_watch/notifier.py`（6 次，链式 before 完整），941/942 间隔 53s（人/教练回合） |
| 09:40:16 → 09:40:20 | `docs/变更记录.md` disk 0ff5b7eb（mtime 09:40:16）→ **seq 943 hermes 登记**（obs=script，bef=02e2dd00，滞后 4s）——这一步走的是 **record-edit / append-event** |
| **09:40:22** | **事故点**：post-tool hook 尝试追加同一时刻的 tool_use，算出 seq 944 / self `8372c25565bf`，**追加失败但锚照样推进** → `checkpoint.json = {seq:944, head:8372c25565bf…, source:post-tool-hook}`，而 events.jsonl 尾部仍是 943（该分歧窗口约 51 秒，我未采样到） |
| 09:41:13 | **seq 944 = `deviate`（kind=decision, actor=claude）**：what 逐字写明"the hook advanced the checkpoint but its own record never landed"，cost 自陈"one tool_use row missing… only one attribution row"，alternatives 里拒绝回退锚（"erases the external anchor evidence, refused"）；`deviate` 事件类型**全库首次发射** |
| 09:42:00 | 我的 R13 捕到现场不一致：checkpoint `944/8372c255` vs `verify-ledger [OK] 944 records head=6b6ec2d9`（=当前 944 的 self）；C4 **T1=1**；audit 无 FAULT（分歧已被 deviate 的补号掩盖） |
| 09:42:46 | 复核：946 条、seq 严格 +1、**无重复 seq**；`8372c255` 全库仅出现 1 次（就在 944 的 what 文本里），`events.jsonl.bak-*` / `checkpoint.json.bak-*` 中 **0 次** → 幻影锚点无独立副本 |
| 09:43:15 | 根因定位（只读源码）：`post-tool.mjs` L252 在 L65-66 真正写入**之前**就把 `appendedRecord` 置值；L256 丢弃 `appendLocked` 的 true/false；L262 `if (appendedRecord)` 因此恒真 → 失败也推进锚。L30-32 注释还留着前科："two writers both produced **seq 474** on 2026-11-07" |
| 09:48:29 | 收工轮：953 条、链 [OK] head d3c9914a9e1b 与 checkpoint 重新一致；C3 8/11（never 只剩 skip/blocker_open/blocker_close）、C4 T14=34 T11=848；trigger **第 13 次仍死**（outage ≥92 分钟）；**收工 canary 11/11**；心跳 09:43:29（09:42 tick Result 0） |
| 09:55:33/43 → 09:55:44 | 5.2 收口：954/955 verify exit=0 → **956 step_advance 5.2→5.3**（端到端冒烟+本期验收） |
| 09:56:40 | **957 gate（actor=human, by=elu9527-sudo, level=L2, step=5.3）why 233 字符含 137 个 NUL**，仅 `data/price_watch.db / scan_runs/snapshots / Chrome / P0 / P3 / 04 / 10.3 / hermetic / tmp / fixture` 等拉丁片段存活 → D5 的**第二次**（窗口内人类签字 2/2 全毁）；gate 比 step 开工晚 56s → T12 4→5（长鸣，设计如此） |
| **09:59:21** | 我读到 checkpoint `{seq:958, head:e594487f2b43…, at:01:58:25Z}` —— 与台账尾部**一致**（958 条，verify-ledger [OK]） |
| **09:59:22** | **故障瞬间**：checkpoint 跳到 `{seq:959, head:0f29b076b9b1…, source:post-tool-hook}`，而该行从未落账（台账 max seq 仍 958）；`0f29b076` 在台账 0 次、在全部 `*.bak-*` 0 次 |
| 09:59:21 / 09:59:46 | audit 两遍均报 **FAULTS(1) `C1 truncation … records were removed from the tail; restore from events.jsonl.bak-*`** —— **D13 复发 + 误诊**（把锚说谎读成尾部删除；最新 bak 比尾部老 174 条，照做会截断真实台账）；本次**还没有人写 deviate**（全库 deviate 仍 1 条） |
| 09:59:46 | 收工复核：958 条、链 [OK]、seq 严格 +1 无重复；C3 8/11、C4 T1=1 T11=849 T12=5 T14=36；C5 新增 5.2=pass（"从未失败"步骤 8 个）；心跳 09:53:26；C10 未再漂移；trigger 第 14 次仍死（outage ≈103 分钟） |
| 09:48:29 | **收工 canary 11/11**（新 kit；与开局 9/9 差值 = T14 两条夹具） |

## 窗口内窗口级统计
- 轮数：**16 轮主采样**（08:15 / 08:18 / 08:20 / 08:22 / 08:23 / 08:25 / 08:34 / 08:45 / 08:53 / 09:02 / 09:12 / 09:24 / 09:31 / 09:42 / 09:48 / 09:59）＋ 10 次定点取证；案发密集期 1–3 分钟一次
- seq 范围：**776 → 958**（+182）；verify-ledger 全程 [OK]、head 与 checkpoint 除两次分歧（09:40:22–09:41:13 已自愈、09:59:22 收工前仍未自愈）外每轮一致；seq 单调、无重复、无 parse_fail
- 事件构成（777→958）：tool_use 148+（seal 18 / Bash ~52 / Edit ~57 / Write ~14）、verify 12、gate 2（**两条都被 NUL 损毁**）、**deviate 1（全库首次）**、step_advance 4、anchor 1、contract_change **0**、unrecorded_write **0**、skip/blocker 0
- 收口节奏：3.1.3 补账 08:40 → 4.1 收口 08:58 → 4.2 收口 09:05 → 5.1 收口 09:23 → 5.2 收口 09:55；5.3 已开工并被签 gate
- 定时任务：10 次 tick（08:12/22/32/42/52、09:02/12/22/32/42/52）→ 4 次未产心跳（08:12 无机制、08:22 Result 1、09:02 无心跳、09:12 Result 1），其余成功；心跳 `last_run` 记的是**写完时刻**（tick 起 +70~90s）
- **覆盖率声明与漏检**：08:15–09:59 覆盖到每一次 step_advance、每一次跨边界写与两次人类签字；**唯一漏检是 09:40:22 那次分歧的 51 秒现场**（09:42:00 追认到 aftermath）。教练侧输出本地无痕迹（N3），凡"教练是否授权 813-815 改判卷器"的判断只能依据人转发文本与被改文件内注释，报告中按证据等级标注，未当作事实。
