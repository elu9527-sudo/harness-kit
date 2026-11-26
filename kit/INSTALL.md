# INSTALL.md — 便携包的入口（人看这一页就够）

一包两用：**机器级**（hooks/settings/人格）+ **项目级**（.harness 骨架/契约/账本）。
先用 `setup.ps1` 把机器对齐，再用 `install.ps1` 装一个项目。两处都可 `-DryRun`。

## 三条命令

```powershell
# 0) 解压到任意目录，进到该目录
# 1) 机器级：hooks + settings + 人格 + 体检   （幂等，改任何文件前先 .bak-<ts>）
pwsh -File setup.ps1 -AuthToken sk-xxxx
#    重启 Claude Code —— env/hooks 只在新会话生效
# 2) 项目级
pwsh -File install.ps1 -ProjectRoot "D:\我的项目"
# 3) 验收：必须 0 FAIL 才算装成
pwsh -File doctor.ps1 -ProjectRoot "D:\我的项目"
```

路径含空格/中文时**一律走 `-ConfigFile`**（UTF-8 JSON），不要拼进 argv：
`-ProjectRoot D:\x\y V2.0` 会被解析成两个参数。

## 包里有什么

| | 内容 |
|---|---|
| 机器级 | `setup.ps1` `doctor.ps1` `hooks/`（guard/decision-guard/pre-tool/post-tool）`prompts/`（两份人格） |
| 项目级 | `install.ps1` `bootstrap.ps1` `derive/`（19 个脚本）`contracts/` `rules/` `policy/` `examples/` |
| 契约 | `MANIFEST.json` 60 个文件的 sha256，`doctor` 会逐个校验 |

## 包里没有什么（必须对方自给）

- **token** —— 只从 `-AuthToken` 或环境变量来，包内任何文件都不含密钥
- **pwsh 7.4+ / python / node / git** —— 自动装运行时是最容易搞坏别人环境的一步；`doctor` 只报缺什么
- **Hermes 本体与其运行时态** —— `state.db` / `checkpoints` / `sessions` 是各人的会话历史，不随包
- **项目契约**（`project.json` 的 stages）—— 必须由人出，`install.ps1` 只建空骨架

## 回滚

每个被改的文件都在原地留了 `.bak-<ts>`。要退：把 `.bak-*` 改回原名即可。
`setup.ps1 -DryRun` 会先列出"将要改哪些文件"，不写任何东西。

---

## 给接收方 agent 的可粘贴提示词

把下面整段交给执行安装的 agent（Claude Code / Hermes / 任何能跑命令的宿主）：

```
# 任务：安装 harness 便携包（你只装，不改）

包在 <解压目录>。目标项目在 <项目路径>。按顺序执行，每步贴原始输出：

1. pwsh -File setup.ps1 -AuthToken <token>        # 机器级；我没有 token 就停下来问我
2. pwsh -File install.ps1 -ProjectRoot "<项目路径>"
3. pwsh -File doctor.ps1 -ProjectRoot "<项目路径>"
4. 把 doctor 的完整输出贴给我，并明确说：FAIL 几条、VOID 几条

铁律（违反任何一条 = 停下并如实上报，不要自己想办法绕）
- 不许安装/升级任何运行时（pwsh/python/node/git）。缺就报缺，装是我的决定。
- 不许修改包里的任何文件（MANIFEST 钉死了每个字节；改了就是一个不可复现的分支）。
- 不许改已存在的 ~/.claude/CLAUDE.md、settings.json 的内容——setup 自带备份与合并策略，
  要覆盖只能用 -Force，而那要我点头。
- 不许 git commit / push，不许联网下载。
- setup.ps1 退出码非 0 就停：那是前置体检有 FAIL，装下去也跑不起来。
- 装完不要"顺手试跑一下项目"——第一步是让教练出阶段草案，不是跑代码。
```

## 角色补充

- 编码 agent 的详细边界：`INSTALL-AGENT.md`（以本文件为准）
- Hermes 教练档案：`hermes-coach/INSTALL-COACH.md`（以本文件为准；人格母本是 `prompts/coach.md`）