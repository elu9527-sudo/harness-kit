# INSTALL-COACH · Hermes 教练配置档案（profile distribution）

> 安装入口与可粘贴提示词见包根的 `INSTALL.md`（以它为准；本文只讲本角色细节）。

> 双 agent 拓扑（2026-11-11 定）：**教练 = Hermes 教练档案**（本目录即官方
> distribution 格式），**编码 = Claude Code**，文档 agent 退役。
> 教练档案能力面 = 读自由 + 写沙箱 + 签字/落账命令平台硬拒；
> 记忆只留会话底稿（可引用不可改写，SOUL 第 8B 条）。

## 两条安装路径（先跑判据，再选路）

```powershell
# 前置（两条通用）：config.yaml 里 terminal.cwd 占位改成项目绝对路径（distribution 是模板，cwd 是机器事实）

# 路径 A · 官方 profile 安装（目标机 default home 无共享 persona 时）
hermes profile install D:\work_shape\harness-kit\hermes-coach --alias
# 填 key：复制生成的 .env.EXAMPLE → .env，填 DEEPSEEK_API_KEY
# 启动：coach chat（别名命令自带）

# 路径 B · 独立 home（目标机 default home 有 identity_override/共享插件时——本机即此情形）
New-Item -ItemType Directory -Force D:\Hermes\coach-home, D:\Hermes\coach-scratch
Copy-Item hermes-coach\config.yaml,hermes-coach\SOUL.md,hermes-coach\distribution.yaml D:\Hermes\coach-home\
Copy-Item hermes-coach\env.example D:\Hermes\coach-home\.env   # 再填真实 key
# 启动：Hermes-Coach.cmd（内含 HERMES_HOME + HERMES_WRITE_SAFE_ROOT 两行，按机改路径）
```

**判据不是感觉，是 dump**：装完跑
`pwsh -File hermes-coach\verify-coach.ps1 -CoachHome <home> -ProjectRoot <项目>`
——T1 发一轮探针后解析 request dump 断言 system 装配：含教练 SOUL 且版本号 == 项目
`.harness/PROMPT`、**不含**任何共享 persona 段（`PRIME DIRECTIVE`）。哪条路干净用哪条。

## 为什么有路径 B（本机 0.23 自装版实测，三组 dump 为证，11-11）

正式注册的 profile（`profile create` + distribution 覆盖）会话装配实测 **60633B 且含
identity_override persona 段（PRIME DIRECTIVE@812）**——`--cli` classic 模式同样中招；
`coach gateway status` 自报 "via the default-profile multiplexer"：本 build 所有注册
profile 的会话由 default gateway 进程统一装配，`identity_override.md` 与全局插件从
**default home** 读取——profile 目录里没有该文件也躲不掉；`coach gateway start`
起不了对抗 authority（被 multiplex 吞并）。独立 HERMES_HOME 同探针实测 **30044B、
persona 段为零**。

结论：profile 是正统形态（别名/dashboard/desktop/Bot Mode 全可用），只要装配干净就该用
它；一旦被共享层污染，注册式 profile 反而是危险双轨（别名指向污染命令集），必须删干净，
退独立 home。判据永远以 verify-coach T1 为准。

## 防线清单（config.yaml 声明，两路径通用）

| 防线 | 机制 |
|---|---|
| 签字/落账/封锚/契约录入/账本 shell 触碰 | `approvals.deny` 7 条（在 yolo 之前生效，BLOCKED 后不许重试改写）：sign-gate／append-event／seal-harness／stage-add／validate-profile／record-edit／`*events.jsonl*` |
| 写盘范围 | 启动器 env `HERMES_WRITE_SAFE_ROOT=coach-scratch`（hard-deny 不走审批；agent 声称写成功以 file-mutation verifier 为准） |
| 身份纯净 | distribution SOUL = `prompts/coach.md` 唯一事实源；不装 plugins／refusal／fallback 换模型重试链（教练的岗位闸门本身就是拒绝输出，该链会把合法拒答当 malfunction 击穿角色） |
| 版本自证 | SOUL 第 0 条核对项目 `.harness/PROMPT` 的 PROMPT_VERSION |
| 误操作保险 | `checkpoints: enabled`（影子 git，before write_file 有账，恢复保留人手改） |
| 已知边界 | deny 是命令文本策略，不是解释器沙箱（官方 threat model 原文）——脚本包装的间接执行由第二层兜底：哈希链 + C7/C10 + 会话底稿对账 |

## SOUL 同步纪律

`prompts/coach.md` 是唯一事实源。改它之后必须同步两处：
`hermes-coach/SOUL.md`（distribution 拷贝）与运行中的 coach home `SOUL.md`；
MANIFEST 重生成会锁住 kit 内两份哈希一致，运行位由 verify-coach T1 的版本断言兜底。

## 路径 C · 桌面原生 profile（本机定稿，11-11 晚）

前提（一次性）：本机 Hermes 带 11-06 本地补丁（`agent/system_prompt.py` 的
identity_override 注入）。把查找顺序改为 **agent home 优先、env 兜底**：

```python
_home = str(_agent_home(agent) or "") or _os.environ.get("HERMES_HOME") or ""
```

效果：override 回归"每个 home 自己的事实"——主 profile（agent home=主 home）照旧读它，
研究环境行为不变；其余 profile 的 home 没有该文件，天然干净。改前留 .bak，改后重启
gateway（杀进程由桌面 watchdog 重拉）加载新代码。

装配（桌面 New Profile 建出 coachXXX 之后，三步）：
1. kit 的 `config.yaml` 实例化进 `profiles/coachXXX/`（api_key 填实、cwd 指项目）；
2. `SOUL.md` = `prompts/coach.md` 全文；
3. 桌面侧栏立即可用——不需要 Remote gateway / token / 独立 serve。

验证：`hermes -p coachXXX chat -q "只输出角色自证行"` → 首行
`ROLE=coach | VER=coach-v2.3.15 | STEP=… | PROFILE=…`，且行为无 persona 痕迹。
本机实测（coach111，11-11 17:0x）：通过，且教练经钉死的 terminal.cwd 自查契约，
自报 PROFILE=有。