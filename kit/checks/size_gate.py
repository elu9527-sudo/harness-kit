"""结构红线报告：文件 ≤400 行 / 函数 ≤60 行 / 嵌套 ≤4 层。

只提示，不阻断 —— 任何时候退出码都是 0，永远不卡死。
行数按「非空行」计，注释计入（注释是资产，不该被压）。
老代码不会因为超限被拦：超了就标 OVER，比上一步肥了标 GREW，都由人判断。
搬迁不设限：搬走的代码换了文件不算新增，报告不因此拦人。
豁免照样认（# size-waiver），但只作为标注显示，不参与任何判定。

用法：
    python tests/size_gate.py            # 人看
    python tests/size_gate.py --json     # 机器读
    python -m unittest tests.size_gate   # 挂在测试里，永不失败
"""

from __future__ import annotations

import ast
import json
import os
import re
import subprocess
import sys
import unittest
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MAX_FILE_LINES = 400
MAX_FUNC_LINES = 60
MAX_DEPTH = 4

# 仅提示，不阻断。只数位置参数：keyword-only 是 Python 的正确写法，不是坏味道。
MAX_POSITIONAL = 5
MAX_LEADING_ALIASES = 8

# 函数体重复的最小行数；只影响提示噪音，不影响通过。
MIN_DUP_BODY = 8

# 每类明细的上限；超出折叠成计数。这样报告长度永远不会随债务增长。
LIMIT_DETAIL = 8

# 老文件要涨这么多行才提示 GREW；小幅波动是正常改动，报了只是噪音。
MIN_GREW_LINES = 80

EXCLUDE_DIRS = {
    ".git", ".harness", ".venv", "venv", "node_modules", "__pycache__",
    ".mypy_cache", ".pytest_cache", "build", "dist", "profiles", "vendor", "docs",
}

NESTING = tuple(
    t for t in (
        ast.If, ast.For, ast.AsyncFor, ast.While, ast.Try,
        ast.With, ast.AsyncWith, getattr(ast, "Match", None),
    ) if t is not None
)

WAIVER_RE = re.compile(r"^\s*#\s*size-waiver(?:\(([^)]*)\))?\s*:\s*(.*)$")
FUNC_TYPES = (ast.FunctionDef, ast.AsyncFunctionDef)


# ---------------------------------------------------------------- 采集

def iter_sources():
    """产出 (绝对路径, 相对路径/正斜杠)。"""
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDE_DIRS)
        for name in sorted(filenames):
            if name.endswith(".py"):
                full = os.path.join(dirpath, name)
                yield full, os.path.relpath(full, ROOT).replace(os.sep, "/")


def count_lines(text):
    return sum(1 for line in text.splitlines() if line.strip())


def walk_funcs(tree):
    """按定义顺序产出 (限定名, 节点)；限定名用于与基线对齐。"""
    found = []

    def visit(node, prefix):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, FUNC_TYPES):
                qual = prefix + child.name
                found.append((qual, child))
                visit(child, qual + ".")
            elif isinstance(child, ast.ClassDef):
                visit(child, prefix + child.name + ".")
            else:
                visit(child, prefix)

    visit(tree, "")
    return found


def func_length(node):
    return (node.end_lineno or node.lineno) - node.lineno + 1


def nest_depth(node):
    """if/for/while/try/with/match 的嵌套层数；不含三元表达式。"""
    best = 0
    stack = [(node, 0)]
    while stack:
        cur, depth = stack.pop()
        if depth > best:
            best = depth
        for child in ast.iter_child_nodes(cur):
            stack.append((child, depth + (1 if isinstance(child, NESTING) else 0)))
    return best


def positional_count(node):
    args = node.args
    total = len(args.posonlyargs) + len(args.args)
    if args.args and args.args[0].arg in ("self", "cls"):
        total -= 1
    return max(total, 0)


def leading_alias_count(node):
    """函数体开头连续 `x = 参数` 的条数——硬拆指纹。"""
    body = list(node.body)
    if (body and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)):
        body = body[1:]
    args = node.args
    names = {a.arg for a in list(args.posonlyargs) + list(args.args) + list(args.kwonlyargs)}
    count = 0
    for stmt in body:
        if not (isinstance(stmt, ast.Assign) and len(stmt.targets) == 1
                and isinstance(stmt.targets[0], ast.Name)
                and isinstance(stmt.value, ast.Name)
                and stmt.value.id in names):
            break
        count += 1
    return count


# ---------------------------------------------------------------- 基线

def head_blobs(paths):
    """一次 git cat-file --batch 取回基线内容；HEAD 里不存在的路径不出现在结果中。"""
    if not paths:
        return {}
    request = "".join("HEAD:%s\n" % p for p in paths).encode("utf-8")
    try:
        proc = subprocess.run(
            ["git", "cat-file", "--batch"], cwd=ROOT, input=request,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
    except (OSError, ValueError):
        return {}
    if proc.returncode != 0:
        return {}
    data = proc.stdout
    blobs = {}
    pos = 0
    for path in paths:
        end = data.find(b"\n", pos)
        if end < 0:
            break
        header = data[pos:end].split()
        pos = end + 1
        if header and header[-1] == b"missing":
            continue
        if len(header) == 3 and header[1] == b"blob":
            size = int(header[2])
            blobs[path] = data[pos:pos + size]
            pos += size + 1
    return blobs


def head_func_index(head_text):
    if head_text is None:
        return {}
    try:
        tree = ast.parse(head_text)
    except SyntaxError:
        return {}
    index = {}
    for qual, node in walk_funcs(tree):
        index.setdefault(qual, []).append(node)
    return index


# ---------------------------------------------------------------- 豁免（只标注）

def parse_waivers(text):
    """{行号: (到期步, 理由)}。必须独占一行注释，文档里的示例不会被当成真豁免。"""
    found = {}
    for number, line in enumerate(text.splitlines(), 1):
        match = WAIVER_RE.match(line)
        if match:
            found[number] = ((match.group(1) or "").strip(), match.group(2).strip())
    return found


def resolve_waivers(text, tree):
    """[(行号, 作用域, 到期步, 理由)]；只用于显示，不参与判定。"""
    raw = parse_waivers(text)
    if not raw:
        return []
    spans = []
    for qual, node in walk_funcs(tree):
        start = min([node.lineno] + [d.lineno for d in getattr(node, "decorator_list", [])])
        spans.append((start, node.end_lineno or node.lineno, qual))
    out = []
    for line, (due, reason) in raw.items():
        best = None
        for start, end, qual in spans:
            if start <= line <= end and (best is None or end - start < best[1] - best[0]):
                best = (start, end, qual)
        scope = best[2] if best else "文件"
        out.append((line, scope, due, reason))
    return out


# ---------------------------------------------------------------- 判定

def finding(kind, path, line, what, actual, limit):
    return {"kind": kind, "path": path, "line": line,
            "what": what, "actual": actual, "limit": limit}


def body_fingerprint(node):
    """函数体（跳过 docstring）的规范化文本与行数，用于找搬家后没删的旧址。"""
    body = list(node.body)
    if (body and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)):
        body = body[1:]
    parts = []
    for stmt in body:
        try:
            parts.append(ast.unparse(stmt))
        except (AttributeError, ValueError):
            return None, 0
    lines = [line.strip() for line in "\n".join(parts).splitlines() if line.strip()]
    return "\n".join(lines), len(lines)


def find_duplicates(bodies, head_counts, findings):
    """函数体相同的多处定义 —— 搬迁最常见的错误是搬了却没删旧址。

    只报「本步新增的重复」：本步份数 > HEAD 份数才算新增。存量重复沉默，只计数。
    """
    groups = {}
    for path, line, qual, size, digest in bodies:
        if size >= MIN_DUP_BODY and digest:
            groups.setdefault(digest, []).append((path, line, qual, size))
    existing = 0
    for digest, members in groups.items():
        if len(members) < 2:
            continue
        if len(members) <= head_counts.get(digest, 0):
            existing += 1
            continue
        path, line, qual, size = members[0]
        shown = ", ".join("%s:%d" % (m[0], m[1]) for m in members[1:3])
        if len(members) > 3:
            shown += " +%d" % (len(members) - 3)
        findings.append(finding("dup", path, line,
                                "%s ≡ %s" % (qual, shown), size, 1))
    return existing


def func_hints(rel, qual, node):
    out = []
    pos = positional_count(node)
    if pos > MAX_POSITIONAL:
        out.append(finding("hint_pos", rel, node.lineno,
                           "%s 位置参数偏多" % qual, pos, MAX_POSITIONAL))
    aliases = leading_alias_count(node)
    if aliases >= MAX_LEADING_ALIASES:
        out.append(finding("hint_alias", rel, node.lineno,
                           "%s 开头连搬参数" % qual, aliases, MAX_LEADING_ALIASES))
    return out


def scan_func(rel, qual, node, head, findings):
    """只报绝对值超限与嵌套变深；函数变长必然体现为文件 GREW，不重复报。"""
    length, depth = func_length(node), nest_depth(node)
    if length > MAX_FUNC_LINES:
        findings.append(finding("func_over", rel, node.lineno,
                                "%s 建议 ≤%d 行" % (qual, MAX_FUNC_LINES),
                                length, MAX_FUNC_LINES))
    head_depth = nest_depth(head) if head else None
    if head_depth is not None and depth > head_depth:
        findings.append(finding("depth_grew", rel, node.lineno,
                                "%s 嵌套变深（上一步 %d 层）" % (qual, head_depth),
                                depth, head_depth))
    elif depth > MAX_DEPTH:
        findings.append(finding("depth_over", rel, node.lineno,
                                "%s 建议 ≤%d 层" % (qual, MAX_DEPTH),
                                depth, MAX_DEPTH))
    findings.extend(func_hints(rel, qual, node))


def scan_file(rel, text, blob, findings, *, bodies):
    """量一个文件，把观察写进 findings、把函数体指纹写进 bodies。返回函数个数。"""
    try:
        tree = ast.parse(text)
    except SyntaxError as exc:
        findings.append(finding("note", rel, exc.lineno or 0, "语法错误，无法计量", 0, 0))
        return 0
    head_text = blob.decode("utf-8", "replace") if blob is not None else None
    head_lines = count_lines(head_text) if head_text is not None else None
    lines = count_lines(text)
    if head_lines is not None and lines >= head_lines + MIN_GREW_LINES:
        findings.append(finding("file_grew", rel, 0,
                                "比上一步肥了（上一步 %d 行）" % head_lines,
                                lines, head_lines))
    elif lines > MAX_FILE_LINES:
        findings.append(finding("file_over", rel, 0,
                                "建议 ≤%d 行" % MAX_FILE_LINES, lines, MAX_FILE_LINES))
    for line, scope, due, reason in resolve_waivers(text, tree):
        label = "文件级" if scope == "文件" else "函数 %s" % scope
        if due:
            label += "（到期 %s）" % due
        findings.append(finding("waiver", rel, line, "%s：%s" % (label, reason), 0, 0))
    index = head_func_index(head_text)
    seen = {}
    for qual, node in walk_funcs(tree):
        order = seen.get(qual, 0)
        seen[qual] = order + 1
        heads = index.get(qual) or []
        scan_func(rel, qual, node, heads[order] if order < len(heads) else None, findings)
        digest, size = body_fingerprint(node)
        bodies.append((rel, node.lineno, qual, size, digest))
    return len(seen)


def scan():
    """返回 dict：findings / files / funcs / baseline。"""
    sources = list(iter_sources())
    blobs = head_blobs([rel for _, rel in sources])
    findings, bodies, funcs = [], [], 0
    for full, rel in sources:
        try:
            with open(full, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as exc:
            findings.append(finding("note", rel, 0, "读不到：%s" % exc, 0, 0))
            continue
        funcs += scan_file(rel, text, blobs.get(rel), findings, bodies=bodies)
    existing = find_duplicates(bodies, head_body_counts(blobs), findings)
    return {"findings": findings, "files": len(sources), "funcs": funcs,
            "baseline": bool(blobs), "dup_existing": existing}


def head_body_counts(blobs):
    """HEAD 里每个函数体指纹出现了几次，用来区分「本步新增的重复」和「存量重复」。"""
    counts = Counter()
    for blob in blobs.values():
        try:
            tree = ast.parse(blob.decode("utf-8", "replace"))
        except (SyntaxError, ValueError):
            continue
        for _qual, node in walk_funcs(tree):
            digest, size = body_fingerprint(node)
            if digest and size >= MIN_DUP_BODY:
                counts[digest] += 1
    return counts


# ---------------------------------------------------------------- 输出

PREFIX = {
    "file_grew": "GREW", "file_over": "OVER",
    "func_over": "OVER", "depth_grew": "GREW", "depth_over": "OVER",
    "hint_pos": "HINT", "hint_alias": "HINT", "dup": "DUP",
    "waiver": "WAIVED", "note": "NOTE",
}
ORDER = ["file_grew", "file_over", "func_over", "depth_grew",
         "depth_over", "hint_pos", "hint_alias", "dup", "waiver", "note"]


def describe(item):
    head = item["path"]
    if item["line"]:
        head += ":%d" % item["line"]
    if item["kind"] == "dup":
        return "%-7s %-48s %s（%d 行）" % (PREFIX["dup"], head, item["what"], item["actual"])
    if item["kind"] in ("waiver", "note"):
        return "%-7s %-48s %s" % (PREFIX[item["kind"]], head, item["what"])
    return "%-7s %-48s %-30s %s > %s" % (PREFIX[item["kind"]], head,
                                         item["what"], item["actual"], item["limit"])


def report(result):
    items = result["findings"]
    lines = ["结构红线（只提示，不阻断）：文件 ≤%d / 函数 ≤%d / 嵌套 ≤%d（非空行，含注释）；"
             "GREW 只在涨 ≥%d 行时提示"
             % (MAX_FILE_LINES, MAX_FUNC_LINES, MAX_DEPTH, MIN_GREW_LINES)]
    if not result["baseline"]:
        lines.append("NOTE    读不到 git HEAD 基线，GREW 不可用，只报超限")
    for kind in ORDER:
        group = sorted((i for i in items if i["kind"] == kind),
                       key=lambda i: -i["actual"])
        lines.extend(describe(item) for item in group[:LIMIT_DETAIL])
        if len(group) > LIMIT_DETAIL:
            lines.append("        … 另有 %d 条同类（按超出量降序，只列前 %d）"
                         % (len(group) - LIMIT_DETAIL, LIMIT_DETAIL))
    count = {kind: sum(1 for item in items if item["kind"] == kind) for kind in ORDER}
    old = result.get("dup_existing") or 0
    lines.append(
        "扫描 %d 文件 / %d 函数 | 超限 %d 文件 %d 函数 | 比上一步肥 %d | 重复 %d%s | 豁免 %d | 提示 %d"
        % (result["files"], result["funcs"], count["file_over"],
           count["func_over"] + count["depth_over"],
           count["file_grew"] + count["depth_grew"],
           count["dup"], ("（另存量 %d，不再提示）" % old) if old else "",
           count["waiver"], count["hint_pos"] + count["hint_alias"]))
    return "\n".join(lines)


def main(argv):
    result = scan()
    if "--json" in argv:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(report(result))
    return 0  # 永不阻断


class TestFileSize(unittest.TestCase):
    """挂进测试只为让报告出现在输出里；恒不失败。"""

    def test_report_is_informational(self):
        result = scan()
        print(report(result))
        self.assertIsInstance(result["findings"], list)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))