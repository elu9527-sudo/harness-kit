# 任务契约 · task.schema.md

教练每一步产出这一份，人转发给编码 agent。**教练不写任何文件。**

## 前置

给出这一步之前必须先跑：

```
pwsh -File .harness/derive/status.ps1 -Root <项目>
```

`NEXT` 是这一步的 id。**不许自己决定下一步是什么**；如果 `status` 报 `NO READY STAGE`，停下来问人。

## 结构（四层，缺一层就退回去重写）

```markdown
## 步骤 <id>：<goal>
risk: <L0|L1|L2>          ← 从 profile.json 的 stage.risk 取，不许自估
verify: <命令>             ← 从 profile.json 的 stage.verify 取
generates: <文件清单>       ← 从 profile.json 的 stage.generates 取

### 第 1 层 · 人类指令
请帮我 <一句话>：

输出文件：
1. <路径>
2. <路径>

<文件 1> 要求：
1. …
2. …

边界约束：
- 只允许新建/修改上面列出的文件
- 不要动 <禁止碰的路径>
- 不要顺手重构、修无关 bug、升级依赖、改配置
- 如需超出范围，先停下来问
- 收尾：在交接卡里填 deviations / uncertainty / residual

### 第 2 层 · 应产出
- 预期文件清单
- 关键结构示意
- 与前置步骤的衔接点

### 第 3 层 · 验证
命令：<从 profile 取，不许自己编>
预期：exit 0
不合格的验证（会自动判红）：
- `echo` / `exit 0` / `python -c "pass"` 类不可能失败的写法
- 指向不存在或 body 为空的测试
- 只数行数不比值的写法（如 `grep -c`）

### 第 4 层 · 要点
- 为什么这样做
- 常见坑
```

## 硬规则

| 规则 | 理由 |
|---|---|
| `id` / `risk` / `verify` / `generates` 全部来自 `profile.json` | 教练不产生契约，只取用 |
| 第 3 层必须给**可失败**的命令 | 不可失败的检查不算证据 |
| 一次只给一步，等结果再给下一步 | 现状已如此，保留 |
| 不写文件、不执行命令 | 教练的 `edit` / `terminal` 权限必须关闭 |

## 交接卡（附在指令尾部，让编码 agent 填）

见 `handoff.schema.md`。教练不需要生成它，只需要在指令末尾写一句：

> 收尾请按 `.harness/contracts/handoff.schema.md` 输出交接卡。
