# harness-kit 便携包 · v0.5 (2026-11-26)

三方 vibecoding 流水线（教练 / 编码 agent / 文档 agent，人做中继）的账本式安全网骨架。
本包是 price-watch 项目 1058+ 条实账、6 轮观测、15 项 canary 场景换来的形态。

## 复现性三层（本包的核心承诺与明确不承诺）

| 层 | 内容 | 保证 |
|---|---|---|
| 🟢 确定层 | derive 脚本、hooks、PROMPT 基线、安装器 | **同版本 pwsh7+node 的 Windows 上逐字节可复现**：MANIFEST.json 钉死全部哈希，install 第 1 步机器核对，canary/audit/genesis 四件套是验收断言不是感受 |
| 🟡 agent 层 | INSTALL-AGENT.md（给接手 agent 的提示词） | 按提示词执行即得同一终态；done 判定全部机器可验 |
| 🔴 政策层 | policy\AGENTS.md + agent.md、coach 卡 | **不保证**。是裁定起点：v1.1 标注草案生效待定；教练行为跨 LLM 依赖人中继观测。包里不给这一层任何假承诺 |

## 明确限制（写在这里而不是藏在问题里）

- **Windows-only**（Linux 理论可跑、未测；计划任务/console 编码为 Windows 形状）
- **单用户单机**：账本锁是同盘 create-exclusive，两台机器并发追加 = 断链。多 agent 可以，多人不行（多用户前向兼容：actor 实名 + 锚推远端裸 git，见二期）
- **hook 全功能仅 Claude Code**：其他宿主诚实降级为 sweep 轮询 + record-edit 补账（不提供未验证的通用 hook 模板）
- 依赖仅 pwsh 7 + node，零外部安装

## 目录

```
kit\
├─ MANIFEST.json          make-manifest.ps1 生成；install 第 1 步的依据
├─ install.ps1            幂等安装器：核对→部署→初始化→genesis→封锚→canary→audit→四件套
├─ make-manifest.ps1      改完任何 kit 文件后重新生成 MANIFEST（版本号必填）
├─ INSTALL-AGENT.md       给对方 agent 的提示词（边界/步骤/验收/失败行为/落账义务）
├─ derive\                14 个安全网脚本（append-event/trigger/audit/sweep/canary/verify/…）
├─ hooks\                 pre/post-tool.mjs + settings 片段 + 降级说明
├─ prompts\               coach.md + coding.md（人格母本；coach.md 与 hermes-coach\SOUL.md 必须字节一致）
├─ policy\                AGENTS.md + agent.md（v1.1 草案母本，生效须对方人类评审）
├─ checks\                size_gate.py 结构红线报告（只提示不阻断）+ 它的反证
└─ examples\              契约样例（stage/generates/verify/risk 的形状）
```

## 给接手"再优化"的人

你装上的第一秒起就在账里：genesis 记录钉死了你安装的字节，之后你改任何脚本，
C7 抓替换、C10 抓未锚定的 harness、T13 抓无解释的写入、canary 抓你写死的检测器。
price-watch 项目里发生过的每一起事故（含安全网自身死亡 103 分钟那起）都已变成
场景钉进 canary。**先 15/15，再动手；改完重 seal；结论走你自己项目的账，
回流走 contract_change，不靠聊天。**

## 用法（人类 30 秒版）

把 kit\ 整个目录给对方，让对方的 agent 读 `INSTALL-AGENT.md` 干活；
或自己跑：`pwsh -File kit\install.ps1 -ProjectRoot D:\新项目 -By "名字"`。

## checks\ · 结构红线报告（只提示，不阻断）

扫全树 .py，报四类：文件/函数/嵌套超限（OVER）、老文件涨 ≥80 行（GREW）、
函数体重复（DUP，只报本步新产生的）、位置参数偏多（HINT）。

三条设计约束，改之前先读：

- **永不阻断**：任何情况 `exit 0`，不进 PASS/FAIL、不进 verify 的判据。
- **不需要人响应**：不要求写豁免、不要求跑额外命令、不要求清理历史。
- **报告长度有上界**：每类明细封顶 8 条按超出量降序，存量重复只留计数。

阈值来自实测（CPython 标准库 758 个 .py 的分布 + 本项目 105 次提交的涨幅分布），
不是拍的：400 行 ≈ 本项目 p95；60 行/函数与 Go `funlen` 默认一致；GREW 的 80 行 ≈ p90。

装到项目的 `tests\size_gate.py`，需要时 `python tests\size_gate.py`。
`size_gate_selftest.py` 是它的 26 条反证（不部署），改完 size_gate 必须重跑它。
