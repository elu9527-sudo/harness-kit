"""反证：结构红线是警告级 —— 该报的要报到，且永远不阻断。"""
import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import size_gate as t

CASES = []


def run(args, cwd):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True)


def repo(files, commit_it=True):
    d = tempfile.mkdtemp(prefix="sizegate-")
    run(["git", "init", "-q"], d)
    for name, lines in files.items():
        write(d, name, lines)
    if commit_it:
        run(["git", "add", "-A"], d)
        run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base"], d)
    return d


def write(d, name, lines):
    path = os.path.join(d, name)
    os.makedirs(os.path.dirname(path) or d, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def body(name, n, indent="    "):
    out = ["def %s(x):" % name, indent + '"""文档"""']
    for i in range(max(n - 3, 0)):
        out.append("%sx = x + %d" % (indent, i))
    out.append(indent + "return x")
    return out


def deep(name, levels):
    out = ["def %s(x):" % name]
    for i in range(levels):
        out.append("    " * (i + 1) + "if x:")
    out.append("    " * (levels + 1) + "return 1")
    out.append("    return 0")
    return out


def kinds(d):
    t.ROOT = d
    return {i["kind"] for i in t.scan()["findings"]}


def case(name, files, mutate, expect, commit_it=True):
    d = repo(files, commit_it)
    try:
        if mutate:
            mutate(d)
        got = kinds(d)
        ok = got == set(expect)
        CASES.append((name, sorted(got), sorted(expect), "OK" if ok else "MISMATCH"))
    finally:
        shutil.rmtree(d, ignore_errors=True)


FILLER = ["N%d = 1" % i for i in range(900)]

case("干净代码", {"a.py": ["def f(x):", "    return x"]}, None, [])
case("新文件 450 行", {"a.py": ["def f(x):", "    return x"]},
     lambda d: write(d, "big.py", FILLER[:450]), ["file_over"])
case("老文件 500→501", {"legacy.py": FILLER[:500]},
     lambda d: write(d, "legacy.py", FILLER[:501]), ["file_over"])
case("老文件 500 不动", {"legacy.py": FILLER[:500]}, None, ["file_over"])
case("老文件 300→379（+79 低于门槛 80）", {"legacy.py": FILLER[:300]},
     lambda d: write(d, "legacy.py", FILLER[:379]), [])
case("老文件 300→380（+80 到门槛）", {"legacy.py": FILLER[:300]},
     lambda d: write(d, "legacy.py", FILLER[:380]), ["file_grew"])

# 纯搬迁：1000 行拆成 300 + 700，一个字没改
def pure_move(d):
    write(d, "legacy.py", FILLER[:300])
    write(d, "moved.py", FILLER[:700])
case("纯搬迁 1000→300+700", {"legacy.py": FILLER}, pure_move, ["file_over"])

case("新函数 70 行", {"a.py": ["def f(x):", "    return x"]},
     lambda d: write(d, "b.py", body("huge", 70)), ["func_over"])
case("新函数 58 行", {"a.py": ["def f(x):", "    return x"]},
     lambda d: write(d, "b.py", body("ok", 58)), [])
case("老函数 40→65（涨 25 未到门槛，但超限）", {"legacy.py": body("grow", 40)},
     lambda d: write(d, "legacy.py", body("grow", 65)), ["func_over"])
case("老函数 40 不动", {"legacy.py": body("grow", 40)}, None, [])

# 既有 189 行函数整体搬到新文件：只提示，绝不阻断
def move_big_fn(d):
    write(d, "legacy.py", ["X = 1"])
    write(d, "moved.py", body("huge", 189))
case("既有 189 行函数搬到新文件", {"legacy.py": body("huge", 189)},
     move_big_fn, ["func_over"])

case("新函数嵌套 5 层", {"a.py": ["def f(x):", "    return x"]},
     lambda d: write(d, "b.py", deep("d5", 5)), ["depth_over"])
case("新函数嵌套 4 层", {"a.py": ["def f(x):", "    return x"]},
     lambda d: write(d, "b.py", deep("d4", 4)), [])
case("老函数嵌套 6 层不动", {"legacy.py": deep("d6", 6)}, None, ["depth_over"])
case("老函数嵌套 6→7", {"legacy.py": deep("d6", 6)},
     lambda d: write(d, "legacy.py", deep("d6", 7)),
     ["depth_grew"])


def waived(d):
    write(d, "legacy.py", ["# size-waiver(2.0.60): 与 2.0.60 的拆分合并处理"]
          + FILLER[:500] + ["EXTRA = 1"])
case("豁免被识别", {"legacy.py": FILLER[:500]}, waived, ["file_over", "waiver"])


def inline(d):
    write(d, "big.py", ["X = 1  # size-waiver: 独占一行的才算"] + FILLER[:450])
case("行内豁免不算", {"a.py": ["def f(x):", "    return x"]}, inline, ["file_over"])

case("无基线", {"a.py": ["def f(x):", "    return x"]}, None, [], commit_it=False)

# ---- 搬迁残留：函数体完全相同
DUP_BODY = body("dupme", 12)
case("搬家没删旧址 → DUP", {"a.py": DUP_BODY},
     lambda d: write(d, "b.py", DUP_BODY), ["dup"])
case("纯搬迁（旧址已删）→ 不报 DUP", {"a.py": DUP_BODY},
     lambda d: (write(d, "a.py", ["X = 1"]), write(d, "b.py", DUP_BODY)), [])
case("短函数重复不报", {"a.py": ["def f(x):", "    return x"]},
     lambda d: write(d, "b.py", ["def f(x):", "    return x"]), [])
case("函数体改了就不算重复", {"a.py": DUP_BODY},
     lambda d: write(d, "b.py", body("dupme", 12)[:-1] + ["    return x + 1"]), [])

# 存量重复：HEAD 里本来就有两份 → 沉默，只留计数
d = repo({"a.py": DUP_BODY, "b.py": DUP_BODY})
try:
    t.ROOT = d
    res = t.scan()
finally:
    shutil.rmtree(d, ignore_errors=True)
quiet = not any(i["kind"] == "dup" for i in res["findings"])
CASES.append(("存量重复沉默（只计数）", ["dup=%d" % sum(1 for i in res["findings"] if i["kind"] == "dup"),
                                   "存量=%d" % res["dup_existing"]],
              ["dup=0", "存量=1"], "OK" if quiet and res["dup_existing"] == 1 else "MISMATCH"))

# 明细封顶：12 个超限文件 → 只列 8 条 + 折叠一行
d = repo({"a.py": ["def f(x):", "    return x"]})
try:
    for i in range(12):
        write(d, "m%02d.py" % i, FILLER[:450])
    t.ROOT = d
    text = t.report(t.scan())
finally:
    shutil.rmtree(d, ignore_errors=True)
over = text.count("OVER   ")
capped = "另有 4 条同类" in text
CASES.append(("明细封顶 8 条", ["OVER=%d" % over, "已折叠" if capped else "未折叠"],
              ["OVER=8", "已折叠"], "OK" if over == 8 and capped else "MISMATCH"))

# 退出码：即便一地超限，也必须返回 0
d = repo({"huge.py": FILLER})
try:
    t.ROOT = d
    with contextlib.redirect_stdout(io.StringIO()):
        code = t.main([])
finally:
    shutil.rmtree(d, ignore_errors=True)
CASES.append(("退出码恒为 0", [str(code)], ["0"], "OK" if code == 0 else "MISMATCH"))

print("%-26s %-22s %-22s %s" % ("场景", "实测", "期望", "判定"))
print("-" * 82)
bad = 0
for name, got, want, verdict in CASES:
    if verdict != "OK":
        bad += 1
    print("%-26s %-22s %-22s %s" % (name, ",".join(got) or "-", ",".join(want) or "-", verdict))
print("-" * 82)
print("反证 %d/%d 通过" % (len(CASES) - bad, len(CASES)))
sys.exit(1 if bad else 0)