# 观测员 #5 · 采样时间线

实际窗口 **16:58:35 → 17:07:27**（约 9 分钟）。原计划 2 小时 / 8–10 轮，因宿主关机指令提前终止；下表为全部真实采样点。所有 `at` 为本地时间（台账内为 UTC，差 8 小时）。

| 时刻 | 动作 / 轮次 | 关键读数 | 变化与新增 |
|---|---|---|---|
| 16:58:35 | 接单 | — | 窗口起点 |
| 16:58:53 | 只读列项目根 + `.harness` 递归 | `events.jsonl` 497,177 B @16:56:03；`checkpoint.json` 137 B @16:56:03；存在 `events.jsonl.bak-20261107-145520` 300,491 B；harness 源码最后修改 16:42:10（sweep.ps1） | 基线文件系统状态 |
| **16:59:03** | **canary 演习（开工必跑）** | `canary: 8/8 detectors fired`，exit 0：T3_out_of_scope / T11_accepted_modified / T12_gate_after_the_fact / C5_VOID_trivial_verify / C5_latest_verify_FAILED / C1b_ledger_truncation / T13_unrecorded_write / sweep_detection **全 FIRED** | 观测窗口开始时安全系统活着 |
| **16:59:46 → 17:00** | **R1 全量采样**（audit / trigger / status / verify-ledger / sweep -DryRun） | C1 intact **739** events `last_at=08:59:21Z`(=16:59:21)；C4 `T1=0 T2=5 T3=209 T4=209 T5=0 T6=0 T11=653 T12=3 T13=9`；C5 `3.1.3=pass`；C7 0/0；C8 `local_step='4.1' top='harness' 8/20`；C9 `1 record`；**C10=fb656124f23c**；WARNINGS **5**（含 C9 skip-1.3 **两遍**）；trigger **16 项 / exit=3**，**T13 0 条**、T11 仅 init_db.py；status NEXT=4.1、3.1.3 已 DONE；verify-ledger `[OK] 739 head=3bc1caa90cad`；sweep -DryRun `47 files covered, disk matches ledger`；checkpoint `{seq:739, source:"post-tool-hook"}` | 三个疑点成形：T13=9 输入却 0 报警 / C9 重复 / 3.1.3 已关闭（早于预期） |
| 17:00–17:02 | 只读全量直方图 + 定向读取 seq 694–746 | `TOTAL=739`；类型分布 tool_use 653 / anchor 45 / verify 23 / **unrecorded_write 9** / contract_change 5 / gate 3 / **step_advance 1**；actor：script 492 / hook 209 / verify 23 / human 9 / hermes 4 / claude 2；step：harness 387 / 3.1.3 76 / … 4.1 4 | **发现 seq 736 step_advance(3.1.3→4.1) @16:56:03**、**seq 731 假阳性 unrecorded_write @16:52:59**、seq 740–742 Hermes 改判卷脚本 @17:01 |
| 17:02–17:03 | 只读 verify 全表（23 条） | 3.1.3：565 exit=1 / 566 exit=1 / 662 exit=1 / **734 exit=0 / 735 exit=0**；所有 verify `products.count=1`；3.1.3 products `before==after unchanged` | 确认"红→绿之间无实现改动记录"（O5-03） |
| **17:03:05 → 17:04:12** | **R2 全量采样（加计时）** | C1 intact **746**；T3 209→**213**、T11 653→**660**；C8 `top='4.1' 11/20`；WARNINGS 仍 5（C9 仍两遍）；trigger 仍 16 项，**T11 未出现 check_interface_impl.py**；sweep -DryRun `48 files covered` **elapsed=58.7s**；audit 2.7s / trigger 2.7s / status 0.8s / verify-ledger 2.2s；checkpoint `{seq:746, head=14d70d6517ef, 09:02:34Z, post-tool-hook}`；末 3 条为 seq 744/745/746 hook Bash（Claude Code 正在 4.1 现场执行） | sweep 单轮 58.7s → 证实扫描窗口≈1 分钟，O5-02 竞态机制成立 |
| 17:04–17:05 | 读 project.json stage 定义 | `3.1.3 generates = scripts/check_interface_impl.py`（唯一），verify = 该脚本；`3.1.2 generates` 4 个；`4.1 generates` 5 个；三 stage `depends_on` 全空 | 判卷脚本＝该 stage 的验收本体（O5-01 关键前提） |
| **17:05:29** | **计划任务只读查证** | `harness-sweep-price-watch` State=**Ready**，LastRunTime **17:02:02**，NextRunTime **17:12:12**，LastTaskResult **0**，MissedRuns 0；Action：`pwsh -NoProfile -WindowStyle Hidden -File …\sweep.ps1`（**无日志重定向 / 无 -NonInteractive**）；`events.jsonl.lock` **无残留** | O5-05：无心跳、失败静默；O5-02：16:52 那一轮对应 seq 731 |
| 17:05:3x–17:06 | **R3 全量采样** + ETW 运行史 + 变更记录.md 只读正则 | R3 events=**746**（无增长→17:02–17:06 流水线静默）；`Microsoft-Windows-TaskScheduler/Operational` 过滤该任务 → **查不到事件**；skip-1.3 双命中根因复现：C-005 决策表行 + `|1.3|…|skipped|` 行（O5-07） | sweep 运行史不可审计 |
| **17:07:19 → 17:07:27** | **关账快照（只读四件套）** | C1 intact **746** `last_at=09:02:34Z`；C4 T3=213 T11=660 T13=9；C10=**fb656124f23c** 未漂移；WARNINGS 5（C9 仍两遍）；trigger 16 项 / exit=3（T12 仍 3 条、T7 仍 2 条、**T11 仍无 check_interface_impl.py**）；status NEXT=4.1；verify-ledger `[OK] 746 chain intact head=14d70d6517ef`；checkpoint 与账本末条 self 逐字一致 | 观测结束，交付 |

## 静默/活跃判断

- 16:56:03 → 17:02:34 之间账本从 736 → 746（+10），其中 hook 7 条（Claude Code 4.1 现场探测）、hermes 3 条（17:01:34–37 自登记 3 文件）。
- 17:02:34 → 17:07:27（约 5 分钟）**账本零增长**：hook 侧进入读/思考阶段，或人在整理给教练的 status/verify 明细。故未触发 5–8 分钟加密节奏之外的额外轮次。
- 观测期间**未出现**：链断、同 seq、`__parse_error`、乱码、C10 漂移、T12 新增、sweep/hook 抢锁失败。

## 读过的源码（判断依据）

`_common.ps1`（全 326 行）、`sweep.ps1`（全 211 行）、`append-event.ps1`（457–536 + checkpoint/lock/validate 命中段）、`trigger.ps1`（200–259、255–309、420–464、T11/T13 语义段）、`audit.ps1`（128–159 C1b、C9/C9b 命中段 485–543）、`project.json` stage 3.1.2/3.1.3/4.1、`docs/变更记录.md`（只读正则）。
