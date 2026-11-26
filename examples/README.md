# README-FULLCASE · 给帮忙优化的人

这个包不只是骨架，是**整套流程的完整案发现场**：便携包（portable/）+ price-watch 项目的真实账本、契约、政策文件 + 六轮观测员报告 + 事故编年史 + 架构全貌图。

## 阅读路线（按序，别跳）

1. `harness-全景-架构图.html` —— 浏览器打开，先看系统长什么样（四节：架构/落账流水/防伪/真实事件走查）
2. `CASEBOOK.md` —— 15 起事故的症状/根因/修复/钉子；每条修复都有对应的 canary 场景名
3. `case/observers/` —— 三份观测员报告（O4/O5/O6），**安全网的漏洞是它们抓的，包括抓维护者自己**
4. `case/price-watch/events.jsonl` —— 1300+ 条真实哈希链账本，`verify-ledger.ps1` 可验
5. `case/price-watch/AGENTS.harness.md` —— 从上面这份账本**派生**的项目政策（gen-agent-md.ps1 生成，每条款带事故证据）
6. `portable/` —— 骨架本体；装到你自己的项目：读 `portable/INSTALL-AGENT.md`

## 敏感性声明（重要）

- 账本含真实业务术语（某电商平台采集/账号池/风控相关）与本机路径。**账本不可脱敏**：哈希链的 self=sha256(内容)，改一个字节=断链=失去自证能力，包的价值就没了。转发包之前请先确认接收者可信范围。
- 账本里没有任何凭据/token/密码（签字理由经控制字符闸，敏感值从未入库）；如发现例外，报告给维护者而不是自行编辑账本。

## 优化规则（你从装机第一秒起就在账里）

1. **先跑全绿再动手**：`pwsh -File portable/derive/canary.ps1 -KitDerive portable/derive`（kit 树 21/21；装进项目后跑项目侧是 20/20，install_selftest 按设计跳过）——每个场景都是真实尸体的回归夹具，任何一个 DEAD 都说明你的环境跑不了这套安全网。
2. **改动必带夹具**：新检测器/新规则没有 canary 场景 = 按"死检测器"处理。trigger 上线即死 103 分钟而 canary 报全绿的教训在 CASEBOOK #7。
3. **改完重封锚**：`seal-harness.ps1` + `audit.ps1` exit 0。你改的每个脚本都会被 C7/C10 对照锚点——绕过它等于给自己制造 truncation 假象。
4. **在你的项目账本里工作**：用 install.ps1 装一个自己的沙箱项目，你的实验事件进你的账；结论回流走你账本里的 contract_change 记录，不靠聊天记录。
5. **PowerShell 雷区**（全部踩过，注释里有）：if-表达式赋 `@()` 拆箱成 `$null`（StrictMode 下 `.Count` 即死）；`Join-Path $a $b + '\' + $c` 的 `+` 被当位置参数；`pwsh -File` 丢引号且不评估数组字面量；zh-CN console 的 GBK/UTF-16 混流。
6. **不许做的事**：手工编辑 events.jsonl（哪怕"修一个错字"）；restore 任何 bak 来"修" checkpoint 分歧（先查 checkpoint.history.jsonl 区分真截尾和幻影锚，CASEBOOK #8）；给检测器加"静默失败"路径。

## 版本

- kit：v0.7.0（新增 hermes-coach/ 教练载体装配；v0.6.5 = CASEBOOK #15 预毙案修复）
- 教练卡：coach-v2.3.15（portable/prompts/）
- 案发现场：price-watch，2026-11-03 ~ 11-10，链头见 events.jsonl 末行
