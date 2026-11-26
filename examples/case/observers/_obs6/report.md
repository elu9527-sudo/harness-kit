# O6 流程观测报告 · vibecoding 多 agent 项目（price-watch）

**观测者**：第 6 号流程观测员（只读，未执行任何写侧命令）
**窗口**：2026-11-09 **08:15:15 → 09:59:46**（实测 1h44m31s；本地时间，台账 `at` 为 UTC）
**轮数**：16 轮主采样 + 10 次定点取证（案发密集期采样密度提到 1–3 分钟，稀疏期回到 12–15 分钟）
**seq 范围**：**776 → 958**（+182 条；收工复核 09:59:46，`verify-ledger [OK] 958 records chain intact head=e594487f2b43`）
**canary**：开局 **9/9**（旧 kit，08:15:2x）→ T14 上线后 **11/11**（08:20:17–08:20:41，新 kit，含 `T14_green_no_change`/`T14_silent_on_real_fix`）→ **收工 11/11**（09:48:29，同一新 kit，11/11 与开局 9/9 之差就是 T14 两条）。
**覆盖声明**：08:15–09:59 覆盖到每一次 step_advance、每一次跨边界写、两次人类签字与两次锚点分歧；唯一漏检是 09:40:22 分歧的 51 秒现场（09:42:00 追认到 aftermath）。全部结论只建立在我能跑的 6 条只读命令 + 只读文件/时间戳/hash 上。教练输出本地无痕迹（N3 硬限制），凡涉及"教练是否授权"的判断只能依据人转发文本与被改文件内的注释，报告中已按证据等级标注。**未执行**：verify.ps1 / finish-step / append-event / record-edit / sign-gate / seal-harness / 非 -DryRun 的 sweep / status -SyncStep / 直跑 `python scripts/check_interface_impl.py`。

---

## 0. 一句话局面

窗口内这个系统把 **3.1.3 补账、4.1 交付+收口、4.2 收口、5.1 收口、5.2 收口、5.3 开工**全跑完了（08:22→09:55，4 个 step_advance），代价是**在 Hermes 工作队列整段瘫痪（≥103 分钟、14 次复现）的情况下完成的**：唯一会喊"判卷脚本被改""跨边界写""绿灯换了来源"的那个 detector 从上线第一分钟起就崩，而它崩的原因正是它新加的"历史豁免"分支。另外，外部锚 `checkpoint.json` 在 09:40:22 与 09:59:22 **两次被一条从未落账的记录推进**（D13）：第一次由 claude 在 09:41:13 补了一条全库首个 `deviate` 事件自述（"the hook advanced the checkpoint but its own record never landed"），**第二次到收工前没有任何记录**，而 audit 把它判成"尾部被删、去 bak 里恢复"——那个 bak 比当前尾部老 174 条。这条链上"丢一行 + 锚说谎 + 误诊指引"的组合，比 D1 更能说明这个系统的失败模式：**事实层链完好、判决照旧前进、而缺陷只在有人自愿写检讨时才存在。** 全程 seq 严格 +1、无重复 seq、无 parse_fail，**链完好与事实可辩护是两件事**。

---

## 1. 缺陷清单

### D1 · trigger.ps1 上线即崩，"历史豁免"分支就是崩溃分支 —— 严重度 Critical
**证据**
- 08:16:25 `trigger.ps1` 被改（mtime 17:11:00→08:16:25，sha 7c019600→dc474d987296，seq 792 事后追认）。
- 08:18:51 起连续 **13 次**复现同一错误（08:18:51 / 08:19:42 / 08:21:04 / 08:23:13 / 08:26:55 / 08:34:53 / 08:45:36 / 08:53:10 / 09:02:51 / 09:12:16 / 09:24:09 / 09:31:12 / 09:48:29）；**outage 08:16:25→09:48:29 ≥ 92 分钟**，收工时仍未修复：
  `trigger.ps1: The property 'Count' cannot be found on this object. Verify that the property exists.`
- 定位：`pwsh -Command "$ErrorActionPreference='Stop'; & trigger.ps1"` → `at trigger.ps1: line 241`。
- 源码：L239 `$prodsT = if ($null -ne $ppP) { @($ppP.Value) } else { @() }`，L241 `$allUnchanged = ($prodsT.Count -gt 0)`；脚本头 L55 `Set-StrictMode -Version Latest`、L56 `$ErrorActionPreference='Stop'`。
- 语义复现（不碰项目）：`$x = if($false){@('a')}else{@()}` → `$x` 为 **$null**；`.Count` on null THROWS 同一条消息；单元素分支退化成 PSCustomObject（`.Count` 侥幸=1）。
- 触发数据：真实台账上最早的 FAIL→PASS 翻转是 **2.0.1 seq25→35、2.0.2 seq54→64、2.0.4 seq120→121**，三条 verify 记录**都没有 products 字段**（products 于 11-07 才上线）。
- 对照设计意图：L233-235 注释明写"Requires the products field (added 2026-11-07): records without it are **exempt by construction**"。豁免分支写的却是 `@()`，语句式赋值把它变成 `$null`，再被 `.Count` 打死。**想豁免的历史记录，反而杀死了检测器。**
- 影响面：trigger 是"Hermes needed"唯一投递口。R1（旧 kit）17 条 → 新 kit **0 条输出**。窗口内 3.1.3 补账（844）、4.1 交付+收口（806-874）、4.2（876-892）、5.1（898-932）全部在无队列状态下发生。audit 侧 C4 显示 T14 输入 23→33、T11 688→829，说明**规则有料，投递器死了**。
- 反向验证：canary 11/11 全绿（08:20:41），因为夹具永远带 products，`T14_green_no_change`/`T14_silent_on_real_fix` 都走"有 products"路径 → **演练绿与生产死并存**；canary 的 `Add-Result` 只检查"码是否出现"，不检查 trigger 是否正常退出。
- 附带事实：真实台账上 3.1.3 的 662 FAIL→734 PASS 之间该步产物 `check_interface_impl.py` 零登记写入、products 全 unchanged → T14 **必然真阳性**（正是设计靶心"考卷变过"）。也就是说：历史三条翻转把脚本打死在 seq 35，导致后面这条真阳性也交不出去。

**为什么是缺陷**：不是"某条规则误报"，而是**整个建议层在案发时段为 0**，且失败方式是把错误打到 stderr、exit≠0，而 audit（另一条只读链）依旧报 0 FAULT——观测者/人只能靠"输出行数"发现它死了。
**建议方向**：① L239 改 `$prodsT = if ($null -ne $ppP) { @($ppP.Value) } else { @() }` → 用 `, @()` 或 `[object[]]` 显式装箱，并在 L241 前 `if ($null -eq $prodsT) { $prodsT = @() }`；② canary 增加一条**生产形状**夹具（无 products 的历史 FAIL→PASS 翻转），并把"detector 退出码非 0"本身算作 DEAD；③ 给 trigger/audit 加"脚本自身异常"外显（例如最外层 try/catch 打印 `[trigger died at line N]` 并非零退出，让 status/audit 能把它当事实报出来，而不是让"没有输出"看起来像"没有问题"）。

---

### D2 · hermes（无 hook）写入仍然没有 before 字节图像 —— 结构性缺陷，严重度 Critical（O5-06 复发并升级）
**证据（机制级，源码定位）**
- hook 路径有真 before：`pre-tool.mjs` 在 Write/Edit/MultiEdit/NotebookEdit 前写 `docs/_snap/<step>/<name>.before`（首图，留给 diff）与 `<name>.before.sha`（"这一刻"的边车）；`post-tool.mjs` L204-235 按 **边车 → 台账尾 → 步骤首图 → 空串** 取 `before_sha256`，并 `unlinkSync` 删边车（故全盘 `*.before.sha` = 0 个属正常，不是失灵——我最初误判过一次，已证伪）。
- **PreToolUse matcher 不含 Bash**；hermes 根本不走 hook。
- hermes 的登记走 `append-event.ps1` L425-441：`observed_by` 缺省填 `'script'`，`before_sha256` 只做**台账推算**（全表扫该 file 最后一条 tool_use 的 sha256）。
- 昨日样本（永久损失）：seq 740 `check_interface_impl.py` before=7ff2fbb2（来自 734/735 的 products 推算，**只有摘要，字节不可恢复**）；**seq 741 `04-采集系统架构.md` before_sha256=""**（该文档此前从未登记）；seq 742 变更记录 before=2b7ba32a。`docs/_snap/3.1.3/` 停在 11-07 15:45，即 17:01 那批 hermes 写**零字节快照**。
- 窗口内新复发 3 次（同一缺陷不是历史）：
  - **seq 854** hermes Edit `04-采集系统架构.md` 5db9ac29→0d47399f（disk mtime 08:45:23，登记 08:45:49，滞后 26s）；`docs/_snap/4.1/` **没有 04 文档的 .before** → 5db9ac29 与 0d47399f 两版之间**无法比对**（这是该文档第二次丢 before）。
  - **seq 896** hermes Edit `config/runtime.yaml` 86440bac→81c795a9（disk 09:08:39，登记 09:08:53，滞后 14s）；全项目 `*runtime.yaml*.before` **不存在** → **86440bac 内容永久不可恢复**。runtime.yaml 属 **2.0.1 产物**，被 5.1 期间的非 hook 写手改了。
  - **seq 855/897** 变更记录.md 两次 hermes 写（滞后 6s / 2s），before 均为台账推算值。
- 量化全台账：tool_use 690 条中 `file` 存在而 `before_sha256` 为空 **52 条**；`observed_by=script` 且 before 为空 **12 条**；带 `why` 的 475/690。
- 对照组（说明机制本身可用）：4.1 的 hook 写全都有 .before（`scripts__check_interface_impl.py.before` 25540B、mtime 11-07 17:00:54，实测 sha=ff54f049…与 seq 740 的 after 一致）→ 我能用 `git diff --no-index` 给出"53 insertions / 0 deletions"的硬 diff；对 hermes 写的 04/runtime.yaml 我做不到任何一条比对。
**为什么是缺陷**：系统里"谁在写"决定了"能不能被审计"。hook 覆盖 = 可 diff；hermes/Bash 覆盖 = 只有一条摘要推算，且推算的前提是该文件**曾经**被登记过（741 连摘要都没有）。同一个文件被两条通道交替写（变更记录.md 今天先 hook 841 后 hermes 855）时，before 语义在两种真值之间漂移。这不是"缺一个字段"，是**判卷依据与文档事实的可辩护性取决于写手身份**。
**建议方向**：① 给非 hook 写手一条强制的"写前落图"入口（把 `record-edit.ps1` 或一个 `snapshot-before` 只读前置做成 hermes 的登记前置条件：无 .before 即拒绝登记，而不是补一个可能为空的推算值）；② 把 PreToolUse 的"出根即 exit 2"策略扩到 **Bash**（见 D7）；③ 对 `04/03/01/02/AGENTS.md` 这类无 owner 的核心文档建立**基线首图**（sweep -Baseline 只给台账摘要，不给字节），并把它们纳入某个 stage 的 generates 让 C7 能看见；④ audit 增加一条"before_sha256 为空/为推算"的计数告警，让这类写作的比例可见。

---

### D3 · 死锁补丁的落账形态：改判卷器 + 改 schema + 改导出，零 contract_change、授权写在被判卷的脚本里 —— 严重度 High（二号问题答案）
**证据（全链，含内容 diff）**
- 08:24:05 **seq 812**：hook Edit `price_watch/pool/__init__.py`（属 3.1.2 产物，**不在 4.1 generates**）追加 3 个导出 + 2 个 import；注释自陈"教练本轮只授权追加上面三个名字，IpPool 不在这里导出"。→ 消掉 A1×2。
- 08:24:24-35 **seq 813/814/815**：hook Edit **`scripts/check_interface_impl.py`（3.1.3 的唯一 generates，同时也是 3.1.3 的 verify 命令本体）**。`git diff --no-index` 前后图像 = **+53 / -0**：新增 `ACCOUNT_POOL_ANCHOR = {impl_classes:("SqliteAccountPool",), exempt_*: 全空}`、`ANCHORED_INTERFACES["AccountPool"] = ACCOUNT_POOL_ANCHOR`、`exempt_impls = tuple(dict.fromkeys(exempt_impls + tuple(ACCOUNT_POOL_ANCHOR["impl_classes"])))`（注释："A2 放行名单 = IP 锚点 ∪ 账号池锚点的 impl_classes"）、新断言 `check_account_pool_subclass`。→ 消掉 B×1 的方式是**在判卷器里登记实现类并放宽 A2 放行名单**。
- 08:44:59 **seq 848/849**：hook Edit `config/schema.yaml`（属 **2.0.1** 产物）：`version: 1→2`、`accounts` 增加 `cooldown_until`（5 insert/1 delete）。→ 这就是 08:23 那次"内存 monkeypatch 才绿"所指向的世界改动，最终落到了别的 step 的产物上。
- **零 `contract_change`（今日 0 条，全台账仍 5 条）、零 `project.json` 变更**（mtime 11-07 14:26:14、sha 289a595ebd7d 全程未动 → "`__init__.py` 进 generates"根本没走 profile）、**零 `anchor` 事件**（今日仅 1 条 = harness seal；新增的 ACCOUNT_POOL_ANCHOR 字面量只活在脚本里）、**零 `validate-profile` 痕迹**、**零豁免决策落账**。
- 唯一的人类决策工件是 **seq 847 gate**，而它的 `why` 有 102/168 个 NUL（见 D5），level=L2 与 4.1 的 risk=L1 口径不一致（见 D10）。
- 落账时间差：判卷器 08:24:24 改完 → 08:40:26 就用来给 3.1.3 补账（844 exit=0）；变更记录.md 直到 08:33/08:45/09:08 才由 hook/hermes 陆续补文档，**"变更事实"晚于"据该变更得出的判决" 16 分钟**。
- 检测器本会报：R1 trigger 已把上一轮同类事件报成 `T11_accepted_modified 4.1 scripts/check_interface_impl.py … no contract_change`；窗口内 812/813-815/848-849/896 五次同类写发生在 trigger 死亡期间，**一条都没投递**。
**为什么是缺陷**：项目为此专门设计了 `contract_change` 事件 + `validate-profile.ps1` + C9（decision 对账台账）+ `T2c_unsigned_contract`；本次恰恰绕开全部四层，把授权降格成**被判卷脚本自己的注释**——自证式权威：需要被审计的对象携带了自己的审计豁免依据。教练侧本地无痕迹（N3）使这条注释无法被任何只读手段证实或证伪。这不是"有没有走文档"的口径问题，而是**判决依据的来源不可核对**。
**建议方向**：① 把"改动 verify 命令本体所指向的文件"设为高敏：凡 tool_use 命中某 step 的 `generates ∩ verify 目标`，无同期 `contract_change`/`gate` 即 **fault 级**（现 T11 只是 trigger 条目，且 trigger 会死）；② `anchor` 事件与脚本内锚点常量做**存在性对账**（脚本里有 `*_ANCHOR` 而台账无对应 anchor 记录 → fault），杜绝锚点活在代码里；③ 授权文本必须来自台账字段而非源码注释——`sign-gate` 生成的 `why` 与 gate 事件 id 应被变更记录引用，形成双向可查；④ `exempt_impls` 类"放行名单"变化应有专门的 `exempt_change` 事件类型（现 `deviate` 从未发射，C3 显示 4 类事件历史 0 次）。

---

### D4 · sweep 的"有发现那一轮"最容易人间蒸发：exit 1 早于写心跳 —— 严重度 High
**证据**
- 源码：`sweep.ps1` L224-226 `if ($LASTEXITCODE -ne 0) { Write-Host "[sweep] FAILED to record …"; exit 1 }`，而心跳写在 L160-165（无发现分支）与 L235-240（有发现分支）——**`exit 1` 位于两处心跳写之前**；L240 的 `catch { }` 还把写失败也吞掉。
- 台账/任务侧观测：
  - 08:12:00 tick Result **0**（旧 sweep，无心跳代码）→ 心跳文件不存在、台账无 sweep 事件（head 仍 776 直到 08:16:35）→ **跑过的巡逻在事实层完全不存在**。
  - 08:22:00 tick → Last Result **1**，心跳未写（08:23:13 复查仍无文件）。
  - 08:32/08:42/08:52 → Result 0，心跳 08:33:10 / 08:43:10 / 08:53:10。
  - 09:02:00 tick → 心跳**未更新**（09:12:49 复查仍 00:53:10Z）。
  - 09:12:00 tick → Last Result **1**；我 09:15:13 的 `-DryRun` 同时刻抓到 `tests/test_comparator.py disk 32a5844 vs @seq 919 47f8f228 mtime 09:16:16` → **那一轮确实有 finding 且没落地**（今日 `unrecorded_write` = 0 条，全台账仍 9 条且全是昨天的）。
  - 09:22:00 → Result 0，心跳 09:23:24（耗时 ~84s：48 文件 × SettleMs=2000 的两遍读）。
- 根因候选（源码级，未直接捕获文本）：`append-event.ps1` L465-486 用 `events.jsonl.lock` 独占创建锁，**100 次 × 100ms = 10 秒**即放弃 → `[FAIL] could not lock … exit 1`；窗口高峰期 hook 每几秒 append 一次、每次还要全表读+复核（L492、L543），10s 窗口很紧。附带风险：L475 对 **>60s 的锁**直接删除，慢而活的写手可能被抢锁，代码自己都预备了 `[WARN] another writer appended after this one`（L560）。
**为什么是缺陷**：C11 的设计注释写得很清楚——"a safety net that quietly stopped running is worse than none"。但心跳的实现恰恰把"发现了东西却记不下来"这一轮标成**不写心跳**，而 audit 的 C11 阈值是 45 分钟且只在"距上次成功心跳"上计时：**连续 3 轮失败的巡逻在前 45 分钟内看起来完全健康**。同时那批未落地的观察（磁盘与台账不一致）被丢弃，要等下一次成功巡逻重新发现——而它下一次发现时，可能已被 hook 事后登记（今日就是这么"自愈"的），于是**真实的窗口性盲区不留任何证据**。
**建议方向**：① 把心跳写成 **finally 语义**（先落 `last_run/attempt/findings/recording_failed`，再落结果），让"跑了但记不下"本身成为一条可见状态；② `exit 1` 前先 `recorded=…、error='append-event exit N'`；③ C11 除新鲜度外再比 `last_run` 与"任务应有 tick 序号"，或对 `schtasks /V` 的 Last Result 做只读采集（audit 已是只读脚本，读一个任务状态不算越界）；④ append-event 的锁等待窗口按写手类型分级（sweep 这种兜底者应更长而非更短），并把"另一写手插队"从 WARN 升级为 fault。

---

### D5 · 人的签字文本被 argv 通道毁成 NUL，并被哈希链永久封缄 —— 严重度 High
**证据**
- seq 847 原文（`at 2026-11-09T00:43:25Z`，step=4.1，kind=decision，actor=human，event=gate，level=L2，status=approved，by=elu9527-sudo）：
  `"why":"3.1.1 \u0000\u0000\u00004.1 \u0000×5 accounts \u0000 cooldown_until \u0000×12 accounts \u0000×6 schema version \u0000×46 … 4.2 \u0000×31"`
  → 实测 **168 字符含 102 个 NUL**；拉丁片段与空格外全部丢失（原文应为中文理由）。
- 全台账扫描：**仅此 1 条**记录含控制字符（决策类事件共 anchor 48 / contract_change 5 / gate 4）。
- 校验器代码：`_common.ps1` `Get-ReasonProblem`（L281-292）只判 empty / 全标点符号 / 重复单字符 / 少于 6 字符；`sign-gate.ps1` L181-184 调用它——NUL 不属于 `\s\p{P}\p{S}`，于是**102 个 NUL 被当成"字母"计入长度**，理由顺利通过质检。
- 同一函数下面的 `Read-ReasonLines` 注释是项目自陈的伤口："**The argv boundary destroyed both, twice, on 2026-11-07** — which is why humans type reasons at a prompt now instead of pasting JSON onto a command line"，并写明 zh-CN 控制台会把 UTF-8 按 GBK 解（`自检`→`鑷氳剼`）。缓解只做了一半（stdin 路径显式 UTF8），**argv 路径仍可达**，且 847 正是走 argv/粘贴那条进来的。
- `verify-ledger.ps1` 每轮 [OK]、`checkpoint.seq` 单调推进，**没有任何规则检查载荷的可打印性**（对 `u0000`/`\p{C}` 的全库 grep 无命中）。
**为什么是缺陷**：哈希链保证"这条记录没被改过"，不保证"这条记录能读"。gate 是唯一的人类签字工件；D3 已经说明本次窗口里它是**唯一**的人类决策落账——而它不可读。等于：**决策发生了、被密码学固化了、但内容永久失效**，且系统把这次签字记成 approved。
**建议方向**：① `Get-ReasonProblem` 增加 `[regex]::Matches($t,'[\p{C}]')` 与"非 ASCII 可打印比例"检查，命中即 `[FAIL]` 拒签（这是最低成本、且不改变其余语义的修法）；② 写入前对 `why` 做往返校验（`$s | ConvertTo-Json | ConvertFrom-Json` 后与原文比较）；③ 已封缄的 847 不宜改动（链不可变），建议追加一条**更正记录**（新 gate/decision 引用 847 的 self 并补齐可读理由），让"事后更正"成为正规范式而不是再次口头化；④ sign-gate 的 `-Why` 参数路径建议直接禁用（只保留交互 stdin），把注释里的教训变成代码里的约束。

---

### D6 · audit 的撕裂读产出瞬态 FAULT，指挥人去造多余记录 —— 严重度 Medium
**证据**
- 08:45:41 那次 audit 报 **`x C7 0.1 docs/变更记录.md on disk (4f7197b5c278) does not match the ledger (7980d53f5d2c) - a write happened that no event records; explain it: record-edit.ps1 -File docs/变更记录.md`**，且把它抬成 FAULT（"the audit fails"）。
- 8 秒后（08:45:49/52）seq 854/855 才落账；我 08:46:09 复查 disk==ledger MATCH=True；08:53/09:02/09:12/09:24 各轮 C7 均回到 `0 drifted, 0 unrecorded`。
- 同类撕裂在我 08:23:45 的 `sweep -DryRun` 里也出现（报 3 条"unrecorded change"，实际 812/813 随后登记）。
- 对照：`sweep.ps1` 明确为此做过两轮修复——L135-138 双读 settle、L203-221（注释 **O5-02**）"re-read this one file's newest ledger digest NOW; if the disagreement evaporated, drop the finding **before it becomes an uncorrectable fact**"。**audit 没有这套复读**，却把结论抬到 FAULT 级并附带"去跑 record-edit"的指令。
**为什么是缺陷**：这不是"audit 应该读盘"的问题（audit 只读是硬设计），而是**同一条竞态在两个只读脚本里享有不同待遇**：sweep 被要求先自证再落事实，audit 直接对人喊话。hermes 登记滞后本就是 5–40s（R1/R7/R9 实测 40/26/23/14/6s），任何一次 audit 撞进这个窗口都必然假响；而"跑 record-edit"会把一次**已被正确登记**的写再记一遍，制造第二条平行事实。
**建议方向**：① audit 的 C7 命中后做一次有界复读（1–2 次，间隔 2–3s，纯读，符合"audit 只读"），或降级为 "transient, re-check" 并附 ledger 最新 seq；② 把 hermes 的 `登记滞后` 做成显式指标（disk mtime → event at 的秒数），让"窗口内的未登记"有量纲而不是布尔；③ record-edit 在写前自检"该文件是否已有同 sha 的 tool_use"，把重复登记拒掉。

---

### D7 · 判卷/验收经 Bash 直跑不入台账，出根产物换通道复活 —— 严重度 Medium
**证据**
- 台账侧：今日 `verify` 仅 10 条；而 827-843、857-871 里 hook 记的全是 **Bash 命令文本**（无 exit、无 file、无 sha）。关键原文：
  - seq 831：`echo "### 1) 接口自检器（本轮授权的第 7 处改动）"; .venv/Scripts/python.exe scripts/check_interface_impl.py | tail -3; echo "exit=${PIPESTATUS[0]}"`，随后 `pytest …` 与 **`db.load_schema = aligned`（"内存补丁，不落盘"）**。
  - seq 838：`### 3.1.3 verify … python scripts/check_interface_impl.py > /tmp/i313.txt`；seq 839 再 `grep '^SKIP' /tmp/i313.txt`。
  - seq 859：`### 4.1 verify（阶段声明的那条）… pytest tests/test_account_pool.py -q`；864、867、871（"最终三件套"）反复同一条。
  - 846（08:41:32）FAIL 之后直到 872（08:57:53）才有新的**登记过的** verify PASS；中间 16 分钟里"阶段声明的那条 verify"被 console 复现 ≥4 次，事实层只有红色那一条。
  - seq 860：`TMP=$(mktemp -d)/v2.db` —— 又一份出根产物。
- 通道差异：`pre-tool.mjs` 对 Write/Edit **出根即 exit 2**，注释写得很硬（"the agent developed a stable habit of writing its self-check scripts to %TEMP% … those steps were 'verified' by code nobody could review"）。但 **PreToolUse matcher = `Write|Edit|MultiEdit|NotebookEdit`，不含 Bash** → 同一行为改成重定向/`mktemp` 就完全绕开，而 T3_out_of_scope 的输入是 tool_use 的 `file` 字段，Bash 记录没有 file → **不可见**。R1 trigger 里那 4 条 %TEMP 历史条从此不会再增，看起来像"问题已治"，实际是换了管道。
- 补偿性自证：864 用 `grep -rn "xfail\|skipif\|pytest.skip\|importorskip" tests/ || echo "零命中 ✓"`、867 用 mtime 列表自查"不许改的文件是否被动过"（列表里含本轮实际改过的 `pool/__init__.py`、`check_interface_impl.py`）。**这些本该是 harness 的规则，现在以不可复核的 console 文本存在。**
**为什么是缺陷**：C5 的设计立场是"pass for someone else's acceptance is not evidence here"、`echo ok` 判 void——同一标准下，一条**没进台账的绿色**更不能算证据。当前形态下，判决过程的可辩护性取决于它是否恰好被 `verify.ps1/finish-step` 执行；Bash 直跑既无 exit code 也无产物快照，还顺带把验证脚本挪出项目根。
**建议方向**：① PostToolUse 对 Bash 也做**产物级**取证：从命令文本抽取重定向/`mktemp` 目标路径，若出根即 fault（把 T3 的输入从 `file` 扩到"cmd 解析出的路径"）；② PreToolUse matcher 加 Bash，至少对"运行 step 的 verify 命令本体"做提示/拒绝，要求走 `verify.ps1`；③ audit 增加一条"声明的 verify 命令文本出现在 tool_use.cmd 中但同期无 verify 事件"的对账（现 C6 只查 verify 引用是否悬空，不查判决被口头复现了几次）；④ 831 那种 monkeypatch 型自测应要求落盘为 `tests/` 内文件（它现在既改世界又不留证）。

---

### D8 · T14 的两个语义盲区：产物=判卷器时永远沉默；"世界移动"没有模型 —— 严重度 Medium
**证据**
- 源码 L232-249：判定条件 = FAIL→PASS + `writesSince[step]==0` + products 全 unchanged。`writesSince` 统计的是"该 step 声明产物上的登记写入"（L287-298，注释明确"hermes' registrations count too (tool=manual), only archive rows are inert"）。
- 3.1.3 的 `generates = ["scripts/check_interface_impl.py"]`，而它同时是 verify 命令本体 → **改判卷器 = 该步"代码动了"** → T14 必然沉默。补账（844）之前判卷器刚被动过 3 次（813-815），因此即使 trigger 活着，844 这次转绿也不会被 T14 说一句话；能说话的只有 T11，而 T11 在 D1 里死了。
- 反例（正例，说明它没误报）：4.1 的 846 FAIL→872 PASS 之间有 850/851/852/856/858/862/863/866 八次产物写入 → T14 沉默正确。
- "世界移动"无模型：875 是 **3.1.1 的复验**，命令连跑两次 `init_db.py --migrate` 并**写 `data/price_watch.db`**（stdout 明载 `schema_migrations: version=2 applied_at=2026-11-09T08:58:17`，"跳过（已存在）11 个"）。台账只记 `exit=0/products unchanged`。同时 08:44 schema.yaml 的 version 1→2 也在动。T14 注释说"the green came from the world or the paper moving"，但**只有 paper（产物）被建模**，world（配置/数据库/环境）没有；products 的 unchanged 语义 = "verify 运行期间自身未变"，不是"自上次 FAIL 以来未变"。
**为什么是缺陷**：这是对 T14 上线质量的答案——**它没有产生误报（历史无 products 的三条本该豁免，3.1.3 那次本该真响），但它的判定模型对"产物即判卷器"的步骤天然失效，而 3.1.3 正是催生它的案例**。这不是实现 bug，是语义覆盖不足；叠加 D1（不投递）与 D7（判决不入台账），实际效果 = 无保护。
**建议方向**：① 对 `generates ∩ verify 目标` 的 step，把"判卷器被写"单独报成 fault，并用**同一步 verify 之间**的判卷器 sha 是否变化来判"考卷变没变"；② products 增记"相对上一次 FAIL 的基线 sha"，让 unchanged 有跨 verdict 语义；③ 引入"世界指纹"（schema version、DB 迁移版本、关键配置 sha）作为 verify 事件字段，使"世界动了"成为事实而不是推理；④ `verify` 命令应声明 `read_only` 或允许 harness 在复验前后做世界快照，否则**复验已收口步骤**这件事本身应该被警告（875 用改库的方式给 3.1.1 续了一条 pass 证据）。

---

### D9 · 观测层自身不在事实层之内（模板树与 hook 脚本无人封印） —— 严重度 Medium
**证据**
- 实际改动的四处脚本来自 `D:\work_shape\harness-kit\templates\derive\*`（mtime 08:16:25/37/43/51 与项目内 `.harness\derive\*` 逐一对齐），再由 Copy-Item 落入项目（14/14 sha 相同，mtime 保持源时间戳）。
- `seal-harness`/`Get-HarnessDigest` 的覆盖集是项目 `.harness/` 树（780-797 逐条列出 contracts/derive/PROMPT/rules）；**模板树与 `templates\hooks\pre-tool.mjs`、`post-tool.mjs`（mtime 11-07 16:23/16:34，sha bdc6bdb3231c / 618868b175c1）不在其中**，也不在任何 stage 的 generates 里。
- 窗口内实证：08:16:25–51 四次检测器改动**当时零事件**（777/778 只是 Bash ls），到 08:18:42 才被重 seal 以"台账上一值→当前值"的事后形式追认；这 2 分 17 秒里我跑出的 R1 结果由旧 kit 产生，且新旧混跑（我的 08:16 audit 用的是旧 audit.ps1，所以没有 C11 心跳告警——这点必须先说清，避免误报为"规则失灵"）。
- `sweep.ps1` L81-84 注释明确"the harness's own tree is deliberately NOT covered: its drift is seal's job"；`trigger.ps1` L357 也把 `.harness/` 排除在产物归属之外。
**为什么是缺陷**：设计意图是"漂移交给 seal"，但**改手是谁、为什么改，永远只有一个字符串**（`"pinned by seal-harness (harness digest pinned after review)"`，780-797 全部如此，包括 4 个真正被改过的文件）。也就是说：检测器代码的变更**没有 actor、没有独立 why、没有 before 字节、并且可以批量事后追认**——正是我在 hermes 身上指认的那组症状，出现在规则引擎自己身上。C10 的存在让"哪个 harness 在跑"可 pin，但 pin 的语义是"事后一致"，不是"改动可追溯"。
**建议方向**：① 把 `harness-kit` 模板树纳入一个显式 step（如 `harness`）的 generates，使其获得与项目产物同级的 C7/C10 待遇；② `seal-harness` 对**内容真变**的文件逐条生成 actor/why（区分"刷新摘要"与"代码变了"），并把 before 字节快照落到 `_snap/harness/`；③ hook 脚本（真正的观测层）至少进 seal 摘要列表——现在 `pre-tool/post-tool` 的任何改动对全部 detector 都不可见；④ audit 的 C10 建议同时打印"本次 digest 相对上次 sealed digest 变了几文件几行"。

---

### D10 · gate 的 level 与 profile 的 risk 口径不一致，无人对账 —— 严重度 Low–Medium
**证据**：seq 847 `level:"L2"`，而 `.harness/project.json` 的 `4.1.risk = "L1"`（status.ps1 也显示 `risk L1`）。`trigger.ps1` L374-382 对 gate 只做 `$gateSeen[$stp]=true` 与 `$gateSeen["level:$lvl"]=true`（存在性），T7（L447-454）只用 profile 的 risk；**没有任何规则比较两者**。
**为什么是缺陷**：L2 需要 gate、L1 不需要，这个不对称一旦被反向使用（给 L1 步骤签一个 L2 gate 当作"覆盖性授权"），系统不会说一句话；D3 里"补账时允许动 check"这类豁免如果将来靠 gate 承载，级别口径的错位就是它的藏身处。注意与 T12 区分：**T12 报"事后 gate"是故意的**（历史三条 3.1.1/3.1.2/3.1.3 长鸣属设计），窗口内它从 3→4 条（新增 847 在 4.1 开工后 27 分钟才签）**是正确反应，不算缺陷**。
**建议方向**：gate 事件与 profile.risk 做一条 `T7b_level_mismatch`；同时把"一个 gate 可否覆盖后续多步"显式化（现在 `$gateSeen["level:$lvl"]` 这个全局键的存在，恰好是 L377-378 注释警告过的形态）。

---

### D11 · 心跳文件自身是不可信锚 —— 严重度 Low
**证据**：`.harness/sweep-status.json`（08:18:38 首现 → 09:23:24 最新）位于 `.harness/` 下 → `sweep.ps1` L84 `$excl` 排除自身；seal 记录（780-797）不含它；`audit.ps1` L559-574 直接把它当"巡逻者来过"的证据，超 45 分钟才 warn，`catch` 只报 "unreadable"。字段 `last_run` 记的是**写完时刻**（09:22:00 tick → 09:23:24），C11 算出的"距上次巡逻 N 分钟"因此系统性偏小一个 sweep 时长（实测 70–96s）。
**为什么是缺陷**：一个没有任何完整性锚的自述文件，用来回答"兜底网还活着吗"这个信任问题；把它改旧（或写一个新鲜值）即可静音 C11 45 分钟。而它恰恰**在被排除的目录里**——被观测者写、观测者信、无人核对。
**建议方向**：心跳写入时在台账留一条 `anchor`（或让 C11 交叉核对 `checkpoint`/`Last Task Result`）；`last_run` 改为记录**开始**时刻并附 `duration_ms`；45 分钟阈值按"巡逻周期×N"从 profile 推导而不是硬编码。

---

### D12 · 快速收口把"从未失败的步骤"清单推高 —— 严重度 Low（观察项，非 bug）
**证据**：`C5 evidence` 警告在窗口内由 **5 个步骤 → 7 个**（1.1, 2.0.3, 2.0.5, 3.1.1, 3.1.2, **4.2, 5.1**）；4.2 与 5.1 各有 2 条 PASS（890/891、930/931）而无 FAIL。C3 仍是 7/11（`deviate/skip/blocker_open/blocker_close` 从未发射），C4 的 T1/T5/T6 仍为 0。step_advance 今日 3 次（874/892/932），平均每个 step 从首写到收口 ~15–25 分钟。
**为什么不是"设计 bug"**：这条警告本身是**故意的长鸣**（与 T12、C5 void 同源），报它是把它当量纲看——**61 分钟里新产生了 2 个"从未能失败"的证据面**，且 5.1 的产物 `price_watch/matcher.py` 被 897 的 hermes `why` 自己点名为"5.1 gap line: matcher has no test_matcher.py in 5.1 generates"（缺口已被写在台账里，但没人被要求处理）。
**建议方向**：给"从未失败"加时限/加一次故意变异演练（canary 的破坏变异范式），并把 897 这种自陈缺口升级成 blocker_open 事件（该类型存在但历史 0 次）。

### D13 · 外部锚被推进到一条从未落账的记录（09:40:22 丢记录事件），事后可验证性只存在于当事人自述里 —— 严重度 Critical
**证据**
- 09:42:00 采样发现两处不一致：`checkpoint.json` = `{seq:944, head:8372c25565bf…, at:01:40:22Z, source:post-tool-hook}`，而同一时刻 `verify-ledger.ps1` 打印 `[OK] 944 records, chain intact, head=6b6ec2d9ecd4`（6b6ec2d9 是 seq 944 **当前**那条 deviate 的 self）。
- seq 944 原文（kind=decision, actor=claude, event=**deviate**，09:41:13）：
  `what = "ledger tail record lost: checkpoint.json attests seq 944 (head 8372c25565bf, 2026-11-09T01:40:22Z, source=post-tool-hook) but events.jsonl ends at seq 943"`；
  `why = "concurrent write at 09:40 local: record-edit append and the post-tool hook append raced; the hook advanced the checkpoint but its own record never landed"`；
  `cost = "one tool_use row missing for that write; … no fact is lost, only one attribution row"`；
  `alternatives = ["restore from events.jsonl.bak-* … no copy exists", "roll checkpoint back to 943 - that erases the external anchor evidence, refused"]`。
- 根因（源码级，可复核）：`post-tool.mjs` L255-272
  `let appendedRecord = null;` → `appendLocked(eventsPath, buildLine);`（返回值 true/false **被丢弃**）→ `if (appendedRecord) { 写 checkpoint }`；
  而 `buildLine` 内部 **L252 `appendedRecord = record;` 发生在 L64**（`const line = makeLine(...)`），紧接着 L65-66 才 `openSync(eventsPath,'a')/writeSync`，失败走 L68 `catch { return false; }`。
  → **闭包先声明"我写了"，写操作随后失败被吞**，外层只看 `appendedRecord` 真值就推进锚点。锁语义：hook 重试 30×~100ms（≈3s，注释 L33-35 明写"give up: a missed tool_use is recoverable… whereas a frozen agent is not"），append-event 重试 100×100ms（10s）；两者同名 `events.jsonl.lock`，但 **append-event 写台账用 `FileShare::Read`（L515）**，Node 侧 `openSync(...,'a')` 在此期间可发生共享冲突 → 正是 L68 的吞异常分支。
- 后果链（全部实测）：seq 号被后来者**复用**——现在台账里的 944 是那条 deviate，而锚曾经宣称 944=8372c255；`8372c255` 在全库**只出现 1 次**（就在 deviate 的 `what` 文本里），`events.jsonl.bak-*`/`checkpoint.json.bak-*` 中 0 次（最新 bak 是 11-07 17:12，早于事发）→ **幻影锚点值除当事人叙述外无任何独立副本**。
- 现场窗口未被我捕到的原因（如实记）：分歧存续约 **51 秒**（09:40:22 推进 → 09:41:13 deviate 落账把 seq 号补齐），我上一轮采样是 09:31:12、下一轮 09:42:00，因此没有看到 C1b/containment 的 FAULT 现场；09:48:29 收工轮时 checkpoint 与 verify-ledger 已重新一致（953/d3c9914a9e1b）。
- 相关自陈：`append-event.ps1` L556-561 自己写着"two writers on one append-only file is how records get interleaved"，只给 WARN；L574-585 的锚点在 PS 侧有 O5-04 单调门（见 D15），Node 侧完全没有。
- 事件类型面首次被"事后补票"打开：C3 由 7/11 → **8/11**（`deviate` 首次发射），C4 T1 0→1、unexercised 由 T1/T5/T6 缩到 T5/T6。窗口 09:42 前 `deviate` 历史 0 次，说明**这类"我知道出了事、要不要记账"完全依赖当事人自愿**。
**为什么是缺陷**：`.harness/checkpoint.json` 是整个系统里唯一"在台账之外"的事实锚，C1b 的全部意义（canary 文案："deleted tail detected via external checkpoint / the ledger could be cut and stay self-consistent - checkpoint blind"）就是靠它。现在它会被**一次失败的写**推进：锚宣称的头部在链上不存在，且锚只存最新值——下一行落账就把分歧证据覆盖掉。**丢一条 attribution 行不是小事**：那一条正是"这次文件改动是被 hook 观测到的"这一事实本身；丢了它，该次改动只剩自登记，D2 的 before 图像问题就升级成"连有没有观测者都不记得了"。
**建议方向**：① `appendLocked` 返回 true 才允许推进锚点（把 L256 改成 `if (appendLocked(...))`，并把 `appendedRecord` 的赋值移到写成功之后）；② 锚点写入用与 PS 侧同一把单调/一致性门，并在推进前**复读台账尾部**确认 self 存在；③ 共享冲突要么把 append 也纳入锁内重试（当前锁只保护 seq/prev 计算与写入，失败即弃），要么承认"hook 可以丢行"并把它变成一条自动的 `blocker_open`/`deviate` 事件，而不是等 claude 手动补一条；④ 给 `checkpoint.json` 加历史环形副本（哪怕 20 条），让"锚曾宣称过什么"可复核——现在它是单值覆盖，分歧一旦自愈就永久只剩自述。

**D13 续 · 19 分钟后复发，且这次被 audit 误诊（收工前仍挂着）**
- 09:59:21 与 09:59:46 两次 audit 均报 **FAULTS(1)**：
  `x C1 truncation ledger ENDS at seq 958 but the external checkpoint attests seq 959 (head 0f29b076b9b1, written 11/09/2026 01:59:22 by post-tool-hook) - records were removed from the tail; restore from events.jsonl.bak-* and investigate`
- 实测：`checkpoint.json` 确为 `{seq:959, head:0f29b076b9b1…, source:post-tool-hook}`；台账 max seq = **958**；`0f29b076` 在台账出现 **0 次**、在全部 `*.bak-*` 出现 **0 次**；`deviate` 仍只有 1 条（09:40 那次），**这一次还没人记账**。
- 与 09:40 那次相比只多了一个事实：这次 C1b 在保护窗内被我采到。同一机制在 19 分钟内两次 → **并发写下的稳定行为，不是偶发**。
- **误诊成本**：C1 文案把"锚说谎"读成"尾部被人删了"，并指挥人去 `restore from events.jsonl.bak-*`——而最新 bak 是 11-07 17:12，比当前尾部还老 174 条。**照做会把真实台账截断回昨天。** 修法：①文案并列两种可能（尾部删除 / 锚被失败写推进）并要求 restore 前比对 bak 的 head 是否为现链前驱；②按 D13 修根因；③下一次 append 落地后这条 FAULT 会自动消失（锚被真 head 覆盖），**分歧证据随之蒸发**——与首次自愈路径完全一致，所以现在不修就等于让每次复发都只剩一条"某人有没有自愿写 deviate"的赌注。

---

### D14 · 人类签字通道的 NUL 损毁已复发（2/2），5.3 的 gate 只剩 137 个 NUL —— 严重度 High（D5 的复发确认）
**证据**
- seq 957（09:56:40Z，step=5.3，kind=decision，actor=human，event=gate，level=L2，status=approved，by=elu9527-sudo）：`why` **233 字符含 137 个 NUL**，存活片段仅 `5.3 / data/price_watch.db / scan_runs/snapshots / Chrome / P0 / P3 / 04 / 10.3 / hermetic / tmp / + / fixture`。
- 全库控制字符扫描（收工复核）：**恰好 2 条**，且**都是本窗口内的人类 gate** —— seq 847（102/168）、seq 957（137/233）。历史上另有 gate 3 条（11-07），未受影响的是更早的、走别的通道。
- 也就是说：**本窗口 2 次人类签字，2 次被毁**（100%），且两次都由 `Get-ReasonProblem` 放行（`sign-gate.ps1` L181-184）。
- 5.3 的 gate 在 step 开工（09:55:44，seq 956 step_advance）之后 **56 秒**才签 → T12 计数 4→5（这是故意的长鸣，不算缺陷，但说明签批节奏已固定为"先干再签"）。
**为什么是缺陷**：D5 里"argv 会毁中文"被项目自己在 `Read-ReasonLines` 注释里承认过（"destroyed both, twice"），缓解只做了 stdin 路径；窗口内人类签字通道 100% 复现，说明**这条路径今天就是坏的日常，而不是偶发**。5.3 是整个"端到端冒烟+本期验收"步骤，它的批准理由现在不可读。
**建议方向**：① `Get-ReasonProblem` 加 `[\p{C}]` 检查（命中即拒签，成本一行）；② sign-gate 的 `-Why` argv 参数路径直接禁用，只留交互 stdin；③ 对 847/957 各追加一条更正记录；④ 收工前把这两条 gate 的"意图"从人那里取回并落成 anchor/decision 文本，否则验收步骤的授权依据在事实层里是空的。

---

### D15 · 同一个锚不变量被两个写手实现成两种语义 —— 严重度 High
**证据**
- PowerShell 侧 `_common.ps1` `Write-LedgerCheckpoint`（O5-04 注释）："**monotone gate** … an unconditional rewrite let a racing/lagging writer move it **BACKWARD**, shrinking the protected window … **Never let the anchor go backwards**"，实现为 `if ($null -ne $existing -and [int]$existing.seq -ge $Seq) { return }`。
- Node hook 侧 `post-tool.mjs` L262-271：`writeFileSync(tmp, JSON.stringify({seq,head,at,source:'post-tool-hook'})); renameSync(tmp,cpPath)` —— **没有任何与 existing 的比较**，正是 O5-04 注释要禁掉的"unconditional rewrite"。
- 二者并发且都活跃：窗口内 checkpoint 的 `source` 交替出现 `post-tool-hook`（09:40:22、09:42:38→946/953 等）与 `append-event`（09:23:44、09:41:13 等），说明两条实现都在真实推进锚点。
- 注释里记录的"两次同 seq"前科就在同一处：`post-tool.mjs` L30-32 "Computing seq/prev from state read outside the lock is exactly how two writers both produced **seq 474** on 2026-11-07"。
**为什么是缺陷**：修复被做在了**其中一个写手**身上，而事故场景恰恰需要两个写手都受同一不变量约束；hook 是高频写手（注释自己说的"the hook is the highest-frequency writer"），也就是最容易把锚推回去的那一个。这不是风格问题——它决定了 C1b 的保护窗会不会在一次乱序 PostToolUse 之后**无声缩短**。
**建议方向**：① 把锚写入收敛成一个唯一入口（hook 调 `append-event.ps1` 或调一个 `advance-checkpoint` 的只参数化小脚本），删掉重复实现；② canary 增加一条"迟到/回退锚"夹具，把 O5-04 从注释变成被演练的规则。

---

## 2. 未及验证的疑点（猜测，单列）

1. **sweep 失败的直接原因仍未捕获文本**，但 D13/D15 把同类机制证实了：hook 与 append-event 共用 `events.jsonl.lock`，重试预算却是 3s vs 10s，且 append-event 持写句柄时用 `FileShare::Read`，Node 侧 `openSync(...,'a')` 可共享冲突——`exit 1` 只可能来自 L73 或 L224-226（append-event 非 0），后者最可能是 L483-486 的 10 秒锁超时。09:02 那轮的精确 Last Result 已被后续 tick 覆盖（Task Scheduler Operational 日志无可匹配事件），我没有直接文本证据。
2. **trigger 是否还有第二个崩点**。products 为单元素时 `@($ppP.Value)` 退化成 PSCustomObject，`.Count` 在 PS7 侥幸返回 1（实测）；若某步产物多于 1 个、或 JSON 数组被 `if{}` 语句式赋值以别的方式展开，L241 可能表现不同。修 L239 后需重跑全量台账确认。
3. **deviate 事件里那句"no fact is lost, only one attribution row"无法独立核对**。丢失的那条 tool_use 对应哪次文件写、该次写是否已被 seq 943（hermes 的 record-edit 登记）完整覆盖，我只能从文本推；`8372c255` 在全库仅 1 处自述、无备份副本（D13）。也就是说：**这条 deviate 的可信度完全建立在写它的人没有说谎。**
3. **教练是否真的授权了 813-815 这次判卷器改动**。唯一依据是被改文件里的注释（"按教练本轮授权只有 impl_classes 一项"）与人转发文本；N3 硬限制下无本地痕迹可证伪。若授权为真，缺陷在于**落账形态**（D3）；若授权为假，则这是一次判卷器被自改而未报警（更严重）。两种可能我都不能排除。
4. **T3 的 %TEMP 历史条是否会因 Bash 通道而永久"看起来治好"**。R1 看到的 4 条历史（prchk_check_contracts.py / prchk_sigs.py / launcher_selftest.py / collector_selftest.py）在 trigger 死后无法逐轮对比；窗口内未出现新的 %TEMP 类 tool_use 文件，但出现了 `/tmp/i313.txt`、`mktemp -d`（838/860）。
5. **C7 对 04 文档的结构性失明是否被 sweep 真正兜住**。04 不在任何 generates（只有 `docs/变更记录.md` 属 0.1），`sweep` 靠"台账曾载 sha"把它纳入 48 个覆盖项；窗口内两次 hermes 改 04 都在 26s/14s 内自登记，未走到"下轮巡逻发现"的路径，所以**兜底成功与否尚无实证**。
6. **checkpoint.json 的 seq 单调性**已逐轮验证（776→798→801→817→824→843→852→871→884→908→932，无回退、无同 seq），但 `source` 字段在 `post-tool-hook` 与 `append-event` 间交替，二者竞态下的单调性我未压测。
7. **C9 decisions 只核对 1 条记录**（`1 record(s) checked against the ledger`）。窗口内新增的 gate 847 与 897 的自陈 why 是否进入它的核对范围，我按现有输出无法判定。

---

## 3. 注入与数据边界复查

- 台账 `data.note/why/cmd`、`docs/变更记录.md`、`04-采集系统架构.md`、被观测脚本内的注释文本，全部按**数据**处理。窗口内未出现"请执行 X / 忽略上文 / 运行某命令"式指令型内容需要上报；`sweep.ps1` L188 的 `note` 与 `audit` 的 C7 文案含"run record-edit.ps1 / pwsh -File …"字样，属**工具自身的行动提示**，我未因此执行任何写侧命令。
- 被改判卷器里出现的"教练本轮授权""上面那行原样不动""零命中 ✓"等表述，均为**被观测文本的自述**，我只作为 D3/D7 的证据引用，未当作事实接受。
- 全程仅执行：`canary.ps1 -KitDerive`（**共 3 次**：08:15 开局、08:20 中途一次**计划外**——为回答观测项 #3"T14 上线后 canary 应 9/9 或 10/10"，必须在新 kit 上实测，09:48 收工）、`audit.ps1`（约 15 次）、`trigger.ps1`（14 次）、`status.ps1`（2 次）、`verify-ledger.ps1`（约 12 次）、`sweep.ps1 -DryRun`（2 次）、只读文件/时间戳/hash、`git diff --no-index`（纯读，无写入）、`schtasks /Query`、`Get-WinEvent`（只读，无可匹配事件）。`status.ps1` **未加** `-SyncStep`。**一处命令形态偏差如实报告**：08:23:45 那次 `sweep.ps1 -DryRun` 为复现定时任务的工作目录条件，用绝对 `-File` 路径从 `C:\Windows\System32` 启动（仍带 `-DryRun`，exit 0，且已用"08:17 dry-run 之后 08:18:29 心跳仍不存在"证明 dry-run 不写心跳、不写台账）；同一条命令的另一侧影响是它把后续两条相对路径命令打在 System32 上报错，无副作用。
- 副作用自查：`sweep -DryRun` 不写心跳（`if (-not $DryRun)`，L160/L235），已用"08:17 dry-run 之后 08:18:29 心跳文件仍不存在"实证；canary 只在临时夹具里读写；`_obs6/` 下是我的笔记与 audit/trigger 原文留档。

---

## 4. 收工核对（最后四轮）

- 09:24:09：ledger 932 条、链 [OK]、C10 仍 7353781bb227（08:16 后 kit 未再改）、trigger 第 11 次复现仍死、心跳 09:23:24（09:22 tick Result 0）。
- 09:31:12：ledger 932 条（09:23:44 后静默 ~7.5 分钟，5.2 刚开）、audit 0 FAULT / 4 WARN、C5 出现 4.1/4.2/5.1=pass。
- 09:42:00–09:43:15：**发现并追认 D13 丢记录事件**（checkpoint 944/8372c255 vs verify-ledger head 6b6ec2d9；deviate seq 944 全文；phantom hash 全库 1 次、备份 0 次）；根因定位到 `post-tool.mjs` L252/L255-262（D13）与 L262-271 缺单调门（D15）。
- 09:48:29（收工轮）：ledger **953 条**、`verify-ledger.ps1` `[OK] 953 records, chain intact, head=d3c9914a9e1b` 与 checkpoint **重新一致**（seq 单调、无重复 seq、无 parse_fail，946→953 全程 +1）；`C3 emission 8/11`（`deviate` 首次发射，never 只剩 skip/blocker_open/blocker_close）；`C4 T1=1 T3=349 T4=349 T11=848 T12=4 T13=9 T14=34`；audit 0 FAULT / 4 WARN；心跳 09:43:29（09:42 tick Result 0）；trigger **第 13 次仍死**；C10 未再漂移。
- 09:59:21–09:59:46（尾轮，两遍复核）：**故障瞬间被我采到**——09:59:21 读到的 checkpoint 还是 `{seq:958, head:e594487f2b43…}`（与台账尾部一致），**09:59:22 它跳到 `{seq:959, head:0f29b076b9b1…, source:post-tool-hook}`，而台账尾部仍是 958**（`verify-ledger [OK] 958 records, chain intact, head=e594487f2b43`）；audit 随即报 **FAULTS(1) = `C1 truncation`**（文案："ledger ENDS at seq 958 but the external checkpoint attests seq 959 … records were removed from the tail; restore from events.jsonl.bak-*"）。`0f29b076` 全库 **0 次**、全部 `*.bak-*` **0 次**、`deviate` 仍只 1 条 → **D13 复发、收工时未自愈、未有人记账**。其余：C3 8/11、C4 T1=1 T12=5 T14=36 T11=849；C5 新增 5.2=pass（"从未失败"步骤 7→8）；**seq 957 人类 gate 又一条 NUL 损毁（137/233）→ D14**；trigger **第 14 次仍死**（outage 08:16:25→09:59 ≈ **103 分钟**）；心跳 09:53:26（09:52 tick Result 0）；C10 全程未再漂移。
- 5.2 于 09:55:44 收口（954/955 verify exit=0 → 956 step_advance 5.2→5.3），5.3（端到端冒烟+本期验收）已开工并已被签 gate。
- **收工 canary：11/11**（09:48:29，新 kit；与开局 9/9 的差值恰为 T14 两条夹具）。
- seq 终值 **958**（开局 776，窗口内 +182）。

## 5. 如果只修三件事

1. **`post-tool.mjs`：写失败不许推进锚点**（L256 改 `if (appendLocked(...))`，把 `appendedRecord` 赋值移到写成功之后；锚加历史副本）——D13 是这条链上唯一"锚可以说谎"的缺陷，而且已经说过一次。
2. **`trigger.ps1` L239 的 `@()` 装箱**（一行）+ canary 增加"无 products 的历史翻转"夹具、并把"detector 非 0 退出"算作 DEAD —— 否则 T14/T11 在真实台账上永远是 0 投递（本窗口 92 分钟）。
3. **非 hook 写手的"写前落图"强制化**（无 `.before` 即拒绝登记）+ `Get-ReasonProblem` 加控制字符检查并对 seq 847 追加一条可读的更正记录 —— 今天 `runtime.yaml` 的 86440bac、04 文档的两版又永久了，而唯一的人类签字是 102 个 NUL。
