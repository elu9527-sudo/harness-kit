# INSTALL-AGENT.md — 给接手安装工作的 agent 的提示词

> 安装入口与可粘贴提示词见包根的 `INSTALL.md`（以它为准；本文只讲本角色细节）。

你是安装执行者与记录者，不是修改者。本包的可复现性契约从你读这份文件开始生效。

本文件安装后同时存在于**目标项目的 `.harness\INSTALL-AGENT.md`**。以项目里那份为准——
kit 里的这份是母本，两者哈希不一致说明有人改过其中一份，那本身就是一条要上报的事实。

## 硬性边界（违反任何一条 = 停止并如实上报）

1. 只写本地文件。不开网络请求、不 `git commit/push`、不安装任何依赖。
2. 安装只通过 `kit\bootstrap.ps1`（或它调用的 `kit\install.ps1`）完成。**不许手工拷贝脚本、不许"顺手修一个脚本来让安装过去"**——包里每个字节都被 MANIFEST 钉死，你改它 = 制造一个不可复现的分支。
3. 你的运行结果必须写进目标项目的新账本（genesis 由安装器自己写，你不需要代写），口头"装好了"不构成安装。
4. 路径含空格/中文一律走 `-ConfigFile`（UTF-8 JSON），不要拼进 argv。
   `-ProjectRoot D:\x\y V2.0` 会被解析成两个参数，报
   "A positional parameter cannot be found that accepts argument 'V2.0'"。

## 前置检查

- `pwsh --version` ≥ 7；Windows（本包 Windows-tested，Linux 未验证，若对方要求 Linux 先声明降级）。
- 目标目录存在且**未曾安装**（`.harness\derive` 已存在 → 停止上报，绝不覆盖已装机项目——那会在它自己的账本外改写它的 harness）。

## 步骤

1. **运行安装器**（一条命令装完，含清空旧状态）：

   ```
   pwsh -File "<kit>\bootstrap.ps1" -ConfigFile "D:\work_shape\kit-boot.json"
   ```

   `kit-boot.json` 是 UTF-8 JSON，argv 里只有一个 ASCII 路径：

   ```json
   { "project_root": "D:\\work\\price-watch V2.0", "by": "Author", "reset": true }
   ```

   `reset:true` = 删掉目标里旧的 `.harness\`、`events.jsonl`、`.harness-anchor.json`、
   `AGENTS.harness.md`、`docs\_snap\`、`docs\_diff\` 再装。业务文件不动。
   **调试期的清空不写任何记录**——新账本第一行就是本次 genesis。

   `bootstrap.ps1` 内部调 `install.ps1`，后者自行完成：文件哈希核对 → 部署
   `derive\ hooks\(guard+pre+post) contracts\ rules\ PROMPT PROMPT-coding.md INSTALL-AGENT.md`
   → 把 hook 执行字节装到 `%USERPROFILE%\.claude\hooks\harness\` 并合并 `settings.json`
   → 空契约与账本初始化 → genesis 记录 → `.harness-anchor.json` 见证文件 → 首封锚
   → canary 故障注入 → 空账 audit → **ready 步（建 `docs\ scripts\ tests\`、写 `.gitignore`、
   生成 `AGENTS.harness.md`）** → 计划任务（尽力而为）。

2. **验收六件套**（输出里必须有这些行，缺一 = 安装失败，原样上报 FAILED 行）：

   ```
   manifest      : N/N files verified  digest …
   genesis       : seq 1 anchor …
   witness       : .harness-anchor.json
   canary        : all detectors FIRED
   audit         : exit 0 on empty ledger
   sweep task    : registered
   ready         : dirs [...]  gitignore [written|kept existing]  agents [AGENTS.harness.md + anchor]
   ```

   `DEGRADED` 必须原样上报，不许吞掉。

3. **hook 覆盖：测量，不是声明**

   ```
   pwsh -File "<目标>\.harness\derive\hook-coverage.ps1"
   ```

   它读 `~\.claude\settings.json`、解析每条 hook 命令的真实文件、算 sha256、与
   `.harness\hooks\` 的钉值比对、把 matcher 逐通道试（Write/Edit/MultiEdit/NotebookEdit/
   Bash/mcp__.*），然后**自算自记**一条 `anchor event=hook-coverage`。

   **不要自己手写这条 anchor。** 你声明的覆盖度是信念，它量出来的才是事实。
   两者都能进账本，但只有后者能被下一个读账本的人复核。

   判定三档：
   - `full`：所有通道注册且执行字节与钉值一致。
   - `degraded`（exit 0）：如实降级，已在 `gaps` 里列明失去什么。**这不是失败，不许美化。**
   - `fault`（exit 1）：声称注册了但够不到——文件缺失 / 字节漂移 / matcher 没盖住第一方写入。
     必须修好再继续。

   已知且不可消除的限制（每次测量都会写进 `limits`，不是你在道歉）：
   - `no-pre-image:mcp` —— MCP 工具不透明，同一个 `path` 可能是读，拦截一次读就是自伤。
     pre 侧只观察，post 侧照常落账并打 `via:"mcp"`。
   - `no-image:out-of-root-mcp` —— 项目外的 MCP 写无写前图像、不进 pre 边界。

4. **没有 Claude Code 的宿主 = 诚实降级**

   没有 Pre/PostToolUse 机制 = 没有写前图像与自动落账。安全网降级为 sweep 轮询（10min）
   + `record-edit.ps1` 补账 + 手动 trigger/audit。照样跑步骤 3，它会记 `degraded` +
   `no-host-hooks`。本包不提供未验证的通用 hook 模板，不接受"看起来能接"。

5. **教练接入**：`.harness\PROMPT` 由 install 部署，与 kit `prompts\PROMPT`（= `prompts\coach.md`）
   同源。交给对方放进教练 agent 槽时核对哈希；不一致先查是谁改的，别直接覆盖。
   教练首读清单包含：项目根存在 `AGENTS.md` 且其引用的 `agent.md` 实际在场
   （policy\ 里有母本，**v1.1 是修订草案、生效时间未定**——需对方人类评审后声明生效，
   并把裁定结果落 contract_change；Apifox、test 分支推送等条款属项目特异，逐条裁）。

6. **请教练填契约**：空 `project.json` 的 stages/generates/verify 由教练按业务写，contract_change 入链。安装者代填契约 = 平行事实，禁止。

## 失败行为

- install 某步 FAILED：停止，报步骤号 + 原样 FAILED 行。**不清空目标目录重试超过一次**，第二次仍败就交人工。
- canary 报 DEAD：环境与安全网不匹配——这是安装器最有价值的输出，宁可安装失败也不要带着死网开工。
- `hook-coverage` 报 fault：先查 `%USERPROFILE%\.claude\hooks\harness\` 是否真有那两个文件；
  重跑 `hook-install.ps1` 可原地修复。修完必须重 seal（执行字节变了，钉值过期）。
- 想让某个脚本"改进一下"：先在自己的账本里记录改动意图，改后必跑 canary 全套 + 重 seal。你已被 genesis 锚定，你的改动会被 C7/C10 追踪——这是特性，不是冒犯。

## 完成后向人类汇报

六件套原文 + `sweep task` 行 + `ready` 行 + `hook-coverage` 的 status 与 gaps 原文 + 一句：
「下一步等教练按 INSTALL-AGENT 步骤 6 填契约，你的第一条 L2 gate 将由 sign-gate -WhyFile 通道签署」。

汇报里不要复述你"认为"的覆盖度，抄 `hook-coverage.ps1` 的输出。