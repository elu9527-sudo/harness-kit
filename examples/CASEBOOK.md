# CASEBOOK · 这套安全网是怎么被现实打出来的

> 每一条 = 症状 → 根因 → 修复 → 钉进哪里（回归夹具/规则/条款）。
> 读这份文件的顺序建议：先读 canary.ps1 的场景名，再回来对号入座——每个场景背后都是一具尸体。

## 第一幕：写前快照之前（11-05 ~ 11-07）

**1. %TEMP% 判卷脚本（T3_out_of_scope 的出生）**
症状：2.0.3/2.0.4/2.0.5 每一步的自检脚本都写到 %TEMP%，步骤"验证通过"但判卷代码事后无人可寻。
根因：agent 的默认习惯是临时文件；警告只在跑 detector 时出现一次，没人看见。
修复：pre-tool 对越出项目根的写直接 `exit 2` **拒绝**（不是提醒）；T3 长鸣。
教训：*每轮都响的警告是训练，不是反馈。反馈必须阻断。*

**2. argv 双杀（sign-gate 的出生）**
症状：11-07 同一条 gate 命令连续失败两次。第一次 JSON 双引号在交互粘贴中消失；第二次 `-Why @('a','b')` 传给子 pwsh 时数组字面量不被求值，多余元素变成位置参数，**悄悄把 -Root 顶掉**。
根因：让人在命令行上手打机器语法；argv 边界会重新解析。
修复：sign-gate.ps1 —— 理由走 stdin，序列化在脚本内完成，过 argv 的只有一个临时文件 GUID。
教训：*病根不是引号，是「让人手打机器语法」。*

**3. "y y" gate（质量闸的出生）**
症状：人把确认键 `y` 误打进理由框，再按一次 y——两个字符签掉了 L2 风险，T7 从此静默，与两笔真签字在账上无法区分。
修复：Get-ReasonProblem（<6 实词/单字符重复拒绝）+ 拒绝与历史 gate 一字不差。
教训：*一个能被 typo 关掉的关卡是装饰品。*

## 第二幕：观测员时代（11-07 夜 ~ 11-08）

**4. hermes 改已验收步骤的判卷脚本（seq 740，O5-01）**
症状：3.1.3 已 PASS 收口后，文档 agent 改了判卷脚本 +53 行；T11（跨步改已验产物）沉默。
根因：T11 排在 `observed_by=hook` 过滤之后——非 hook 写入根本进不了检查。
**更严重的**：我在报告里宣称"已把 T11 移到过滤前"，实际没做。观测员 #5 拿 seq 740 对质，抓出的是**我的虚假声明**。
修复：T11/T4 移到过滤之前、对所有写入者生效（seal/maintenance 行豁免）；canary 新增 `T11_nonhook_writer` 专钉此洞。
教训：*检测器的代码位置就是它的语义。声称修了 ≠ 修了，只认台账。*

**5. sweep 复读旧快照写进永久假事实（O5-02）**
症状：seq 731 记录了一次 36 秒前已登记过的 sha。
根因：巡逻开头读账本快照，中途 59 秒双读稳定期里 hook 落了新账，append 用的还是旧快照。
修复：追加前逐文件对账本尾部做 fresh recheck；11-09 audit C7 的撕裂读误报（8 秒自愈却报 FAULT 并教人 record-edit）同型修复。
教训：*只读快照做长决策的安全网，必须在下笔前重读尾部。*

**6. 检查点无条件覆写（O5-04）**
症状：注释写着"单调"，代码无条件重写。
修复：Write-LedgerCheckpoint 单调门。
教训：*注释是愿望，代码是事实。审计器要审行为不审注释。*

## 第三幕：安全网自己死了（11-09 上午，观测员 #6 全部抓获）

**7. trigger 上线即死 103 分钟**
症状：08:16 我部署 T14 后，整个告警队列死亡；4.1→5.3 五个步骤在**零检测**状态下跑完；而 canary 报 11/11 全绿。
根因：`$x = if(...) {…} else { @() }` —— if 作为**表达式**赋值时，空数组被枚举流拆箱成 `$null`，StrictMode 下 `.Count` 即致命。真实台账第一站就是无 products 的历史翻转（2.0.1），而我全部夹具都带 products——**夹具全绿盖住了尸体**。
修复：6 处同款雷全部改语句形；canary 新增 `legacy_flip_survives_no_products`（历史翻转必须活）+ `dead_detector_detected`（检测器非零退出必须读成 DEAD，不许 FIRED 盖尸体）。
教训：*凡是被自己的夹具检验过的东西，一定会在真实数据的第一现场倒下。canary 必须包含"检测器死亡"本身的场景。*

**8. 幻影锚（post-tool.mjs）**
症状：checkpoint 两次指向从未落账的记录（944/8372c255、959/0f29b076）；audit C1 报截尾并建议"从 bak 恢复"——**最新 bak 比尾部老 174 条，照做等于把活账截回昨天**。
根因：`appendedRecord = record` 在构造行时赋值（写入之前），appendLocked 返回值被丢弃，Node 侧没有 PS 侧的单调门。
修复：只认 append 返回值、推进前回读账本真尾部、Node 侧补单调门、新增 checkpoint.history.jsonl 滚动副本、C1 文案改为"用 history 区分真截尾 vs 幻影锚，绝不盲目 restore"。
教训：*同一条不变量只在一侧实现，等于没有实现。给审计建议的文案本身要有危险性审查——错误的补救比故障更贵。*

**9. NUL 毁签（seq 847/957）与第三次现场复现**
症状：两条人类 gate 落账时 60% 是 NUL（102/168、137/233），中文全毁、链把它们**永久封缄成合法记录**；11-09 人重签时交互粘贴第三次毁损——被新上的控制字符闸门拦下（未落账）。
根因：console 层在字节进脚本之前就毁中文（UTF-16/编码嗅探缺失），且质量闸把 NUL 当字符数。
修复：Read-ReasonLines 读原始字节+BOM/NUL 嗅探；Get-ReasonProblem 拒绝控制字符；audit 新增 **C12**（已入链的毁签永久点名，同步骤后续合法签字可降级为 warn——补救优先于指控）；sign-gate 新增 **-WhyFile** 文件通道；教练卡 v2.3.9 把文件通道定为唯一签字正门。
教训：*哈希链保证不可改，不保证可读——「同意」的内容本身也需要审计。签字通道毁损三次才修对：argv、stdin 重定向、交互粘贴，三层各死过一次。*

**10. sweep「有发现的那轮最隐身」**
症状：08:22 与 09:12 两轮 Result 1 且无心跳——恰恰是发现了漂移、登记失败的那两轮。
根因：`exit 1` 在写心跳之前；且一次失败中断整轮巡逻。
修复：失败计数继续巡完，心跳带 `failed` 字段，exit 码挪到心跳之后。
教训：*安全网自己停摆必须有独立于它的信号（C11 心跳点名）。*

**11. 死锁补丁：注释自证授权（813-815）**
症状：教练的死锁补丁以"判卷脚本 +53 行、exempt_impls 实际放宽、schema version 1→2"落地，零 contract_change、零签字、零锚——授权只活在**被改判卷脚本自己的注释**里；补账 verify 用的就是改过的判卷器，判决早于文档 16 分钟。
修复：trigger 复活后队列 T11×5 全部点名（证据闭环）；教训写进 gen-agent-md 生成的项目政策（「源码注释自证授权 = 无效」）与教练卡；**规则本身待教练立项**：放宽必签的强制闸。
教训：*改考卷的人和考试是同一个人时，唯一防线是账本里那条 contract_change——注释不是授权。*

**12. 装机实测时我误创了一个文件（11-09 12:16）**
症状：测试 prebash manifest 时 `Add-Content` 指向不存在的路径，PowerShell 静默建了 28 字节垃圾文件。
处置：删除 + **deviate 自报入链**（该文件从未入账、不在任何 generates，删除=撤销实验）。
教训：*现场测试必须用显式存在的路径；Add-Content 自动建文件是陷阱；连维护者的失误也要走自报通道——这是系统文化，不是个人品德。*

**13. universe 开发自己的函数死法（11-09 下午，被新夹具当场抓）**
症状：给 verify 加「世界移动检测」时，canary 一次死 7 个场景。
根因：`Get-ProjectUniverse` scriptblock 的循环里裸调 `$dirs.Dequeue()`——Queue 弹元素会**把它 emit 进管道**，返回值变成「N 个泄漏数组 + 正主」的 object[]，`.map` 即炸。与 #7 同族：**PowerShell 里每个表达式都在发射**，任何不被赋值消费的调用都会污染返回。
修复：`[void]$dirs.Dequeue()`；死掉的 7 个场景全部复活（16/16）。
教训：这次的尸体是新夹具体系**第一次在没有观测员的情况下当场抓住开发中的 bug**——T15 fixture 一挂就暴露函数坏了，不用再等 103 分钟。

**14. T14b 的语义第一次被我写错**
症状：fixture 初版按「跨窗口改卷」设计，跑出来的是 T14 逻辑而非 T14b。
根因：products 的 state 是**窗口语义**（verify 运行期间字节动不动），tool_use 是**跨窗口**——「判卷脚本在自己被运行的那一刻改了自己」才是 T14b，「判卷脚本在两次判决之间被人改了并登记」是 T11/contract_change 的辖区。两个规则必须各管各的时间窗，否则互相赦免。
修复：fixture 改为 verify 命令运行时自改 check_exam.py；T14b 条件去掉 `$wnT -eq 0`（考卷改动通常有记录，T14b 指控的不是漏账，是「绿只靠考卷变软」）。
教训：给规则写反例夹具时，先把**时间窗语义**画清楚——这是 canary 里最便宜的深审。

**15. why 文本能杀判卷器（T2b 子串压制 · 11-10 · 唯一一条预毙案）**
症状：教练卡要建 sign-contract.ps1（给 project.json 以外的文件落人签契约的通道）。工具本身没问题——但按设计，从此会**常态化出现 file=AGENTS.md 的 contract_change**；而 trigger 的 project.json 覆盖检查是拿 `"file - why"` 拼接串做子串正则，只要自由文本的 why 里恰好出现 "project.json" 字样（给 AGENTS.md 写的理由几乎必然提到它），基线漂移检查就**静默闭嘴**。
根因：覆盖判定比的是给人看的显示字符串，不是 file 字段本身。现存 5 条 contract_change 里其实**已有**一条 file=contracts/ip_provider_interface.py 的（2.0.2 手打时代留下的）——它的 why 恰好没写 "project.json" 字样，才侥幸没触发。地雷一直埋着，sign-contract 只是把踩雷变成日常。
修复：$coversProjectJson 改为对归一化 file 集合的精确成员判定（trigger.ps1）；canary 加 t2b_exact_coverage 反例夹具（漂移必响 + 真覆盖必静双断言）。负向验证：同一夹具跑在旧代码上被压制（False），新代码上响（True）——漏洞是实弹证明的，不是推理出来的。
教训：**给事件加新来源之前，先预演"这个事件出现后每个既有检测器长什么样"**。豁免/压制判定永远只看机器字段，永不看自由文本——自由文本是人写的，人写的话不该有权关掉安全网。这是 15 案里唯一一条**落地前**抓到的：前 14 具尸体换来的嗅觉，第一次在埋雷引爆之前就把它挖了出来。

**16. v0.8 升级：借 Super-agent 的授权生命周期与注意力，松仪式不松边界（11-12）**
症状：人（操作者）认知负担重——每步人肉搬运卡片/输出、逐动作签字、历史警告永久重响训练忽略。有些"紧"是仪式不是边界。
根因：我们把"边界"和"仪式"混在一起收。边界（不可逆人签/防篡改/能力边界）该紧；仪式（逐次签字/搬运/重响）该下放给宿主程序。
修复（借鉴 DeepSeek Super-agent 原型，骨架四条不变）：
- **T16_stale_gate**（Mandate 重验）：gate 落账带 contract_sha；契约一变旧 gate 自动点名重签，替人肉记失效。legacy 无 sha 豁免（exemption-by-construction）。
- **attention.ps1**（面板哲学"只呈现需要人的"）：trigger 全量不变，投影分 NEEDS YOU / REVIEWABLE / COLLAPSED；历史项人 `-AckReviewable` 承认一次折叠。47 行队列→7 行需人。
- **relay.ps1**（intake/assignments 快路径）：零 LLM 格式化交接块，减搬运；不执行不签字。
- **coach v2.3.16**：预授权作用域（逐范围签代替逐动作签）+ observe 默认 + T16 提示重签。
教训：**边界交给宿主强制，仪式降到最少**。Super-agent 的授权文档（002）是我们纪律的形式化版本；我们缺它的授权生命周期，它缺我们的防篡改账本——互补。松绑本身走 contract_change（放宽必签），边界反而更清楚。

## 机制总表（尸体 → 钉子）

| 尸体 | 钉子（回归夹具） |
|---|---|
| %TEMP% 判卷 | canary T3_out_of_scope + pre-tool exit 2 |
| argv 双杀 | sign-gate 通道 + 教练卡「不教人手打 JSON」 |
| y y 签字 | Get-ReasonProblem + 重复拒绝 |
| 740 跨步改卷 | canary T11_nonhook_writer（O5-01 钉） |
| sweep 假事实 | O5-02 fresh tail recheck（audit C7 同型） |
| trigger 之死 | canary legacy_flip + dead_detector_detected |
| 幻影锚 | post-tool 四重修复 + checkpoint.history + C1 文案 |
| NUL 毁签 | C12 + 控制字符闸 + -WhyFile + 字节嗅探 |
| 心跳隐身 | sweep failed 计数 + C11 |
| 注释授权 | 队列 T11 证据链 + gen-agent-md 政策条款 + T14b_exam_only |
| 世界移动（875 写库） | universe_changed 字段 + T15_universe_moved 夹具 |
| 管道泄漏（Dequeue） | 新夹具体系自抓（#13） |
| why 文本压制 T2b（预毙） | canary t2b_exact_coverage + file 字段精确匹配 |
| 仪式过重/认知负担（v0.8） | T16_stale_gate + attention 分层 + relay 零LLM + coach 预授权/observe |

## 还没钉住的（诚实清单 · 11-09 晚更新）

- ~~T14 语义盲区~~：「考卷=产物」已拆出 **T14b_exam_only**（判卷器在绿判决窗口内自己动了 = 点名）；「世界移动」已上**最小盘模型 universe_changed**（undeclared 文件在判决期间动了 = 入账 + T15 点名）。**仍盲**：内存 monkeypatch / 运行时状态（任何盘像模型看不见）、products 字段上线前的历史翻转（按构造豁免）。
- ~~hermes/Bash 道无图像~~：Bash 边界图像已上线（pre-tool manifest + diff，170ms/259 文件实测）；**仍缺**：hermes 自有工具链无 hook，只有轮询窗口兜底；`runtime.yaml` 86440bac 一类的历史损失不可逆。
- 多用户并发：前向兼容只做了 actor 实名 + 锚历史副本。
