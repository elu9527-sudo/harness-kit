#!/usr/bin/env node
/**
 * Claude Code PreToolUse hook -> keep a "before" copy of every file about to be
 * mutated, so finish-step.ps1 can produce a real line-level diff.
 *
 * Why this must be PreToolUse: PostToolUse runs after the write, so the previous
 * content is already gone. Without a before-copy there is no way to diff, and
 * "grep -c instead of line-level diff" comes back.
 *
 * Layout:
 *   docs/_snap/<step>/<path with / -> __>.before
 *
 * finish-step.ps1 later diffs each .before against the current file and writes
 * docs/_diff/<step>/<name>.diff.
 *
 * Never blocks an in-tree write; always exits 0 for those. The one exception is
 * a write outside the project root, which is refused (exit 2). See the note at
 * isUnderRoot.
 */

import { readFileSync, existsSync, statSync, mkdirSync, copyFileSync, writeFileSync, renameSync, readdirSync, appendFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join, isAbsolute, relative, sep } from 'node:path';

function findRoot(start) {
  if (!start) return null;
  let dir = start;
  for (let i = 0; i < 40; i++) {
    if (existsSync(join(dir, '.harness', 'local.json')) || existsSync(join(dir, 'events.jsonl'))) return dir;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

function safeName(rel) {
  return rel.split('/').join('__');
}

/**
 * True only when `abs` is genuinely inside `root`.
 *
 * Without this guard an absolute path on another drive (the agent writes a
 * scratch script to C:/Users/.../AppData/Local/Temp/) makes relative() retreat
 * into '../../..' segments. safeName() then joins them with '__' and the result
 * still carries the drive colon: 'C:__Users__...'. Windows refuses that as a
 * filename, so the snapshot lands as a 0-byte file named "C" - and finish-step
 * later reads that manifest entry as a deleted file. The hook governs what is
 * inside the project; a path outside it is somebody else's business.
 */
function isUnderRoot(root, abs) {
  const rel = relative(root, abs);
  if (rel === '') return false;
  if (isAbsolute(rel)) return false;
  return !rel.startsWith('..');
}

function sha256File(absP) {
  try { const h = createHash('sha256'); h.update(readFileSync(absP)); return h.digest('hex'); } catch { return null; }
}

// Bash-window forensic manifest (observer #6, O5-06 escalation): Bash writes
// have no PreToolUse file_path, so historically they left NO before-image at
// all - two file versions were lost permanently (seq 854, seq 896). This runs
// before every Bash call: snapshot the whole project's source-file hashes,
// diff against the PREVIOUS bash boundary, append the movement to
// .harness/local/prebash-diff.jsonl, store the new state. Coverage between two
// bash calls is now bounded by REAL endpoints instead of a 10-minute sweep
// window - a drift found later can be compared against `before` here.
// Hard budgets: 300 files / 2 MiB each / fixed extension set. Oversize ->
// truncated:true recorded honestly, never a silent partial lie.
function bashManifest(payload) {
  const root = findRoot(payload?.cwd ?? process.cwd());
  if (!root) return;
  const localDir = join(root, '.harness', 'local');
  if (!existsSync(localDir)) mkdirSync(localDir, { recursive: true });
  const statePath = join(localDir, 'prebash-state.json');
  const diffPath = join(localDir, 'prebash-diff.jsonl');
  const EXTS = new Set(['.py', '.js', '.mjs', '.ts', '.sql', '.yaml', '.yml', '.json', '.md', '.toml', '.cfg', '.ini', '.txt', '.ps1', '.sh']);
  const SKIP = new Set(['node_modules', '.venv', 'venv', '__pycache__', '.git', 'dist', 'build', '.harness', '_snap']);
  const files = {}; let count = 0; let truncated = false;
  const walk = (dir, rel) => {
    if (truncated || count >= 300) { truncated = true; return; }
    let ents; try { ents = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      if (truncated || count >= 300) { truncated = true; break; }
      if (e.name.startsWith('.')) continue;
      const absP = join(dir, e.name);
      const relP = rel ? rel + '/' + e.name : e.name;
      if (e.isDirectory()) { if (SKIP.has(e.name)) continue; walk(absP, relP); continue; }
      if (!e.isFile()) continue;
      const dot = e.name.lastIndexOf('.');
      if (dot < 0 || !EXTS.has(e.name.slice(dot).toLowerCase())) continue;
      let st; try { st = statSync(absP); } catch { continue; }
      if (st.size > 2 * 1024 * 1024) continue;
      const h = sha256File(absP);
      if (h) { files[relP] = h; count++; }
    }
  };
  walk(root, '');
  let prev = {};
  try { prev = JSON.parse(readFileSync(statePath, 'utf8')).files ?? {}; } catch { /* first boundary */ }
  const now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  const diffs = [];
  for (const [k, v] of Object.entries(files)) {
    if (prev[k] !== v) diffs.push({ file: k, before: prev[k] ?? null, after: v });
  }
  for (const [k, o] of Object.entries(prev)) {
    if (!(k in files)) diffs.push({ file: k, before: o, after: null });
  }
  if (diffs.length > 0 && Object.keys(prev).length > 0) {
    // The FIRST boundary silently establishes the baseline - writing 259
    // "null -> after" rows would flood the diff log with non-events and teach
    // the next reader to ignore it. Only real movements between two boundaries
    // get recorded.
    appendFileSync(diffPath, diffs.map((d) => JSON.stringify({ at: now, ...d })).join('\n') + '\n');
  }
  const tmp = statePath + '.tmp-' + process.pid;
  writeFileSync(tmp, JSON.stringify({ at: now, count, truncated, files }));
  renameSync(tmp, statePath);
}

function main(raw) {
  if (!raw.trim()) return;
  let payload;
  try { payload = JSON.parse(raw); } catch { return; }

  const tool = payload?.tool_name ?? '';
  if (tool === 'Bash') {
    try { bashManifest(payload); } catch { /* never block the agent */ }
    return;
  }
  // only tools that write to a known path
  const isMcp = tool.startsWith('mcp__');
  if (!isMcp && !['Write', 'Edit', 'MultiEdit', 'NotebookEdit'].includes(tool)) return;

  // The path key is per-tool, and reading only `file_path` meant two registered
  // channels produced NO before-image at all: NotebookEdit carries
  // `notebook_path`, and every MCP file tool (windows-mcp FileSystem, desktop
  // FileSystem) carries `path`/`filePath`. The matcher said "covered" and the
  // disk got nothing - the single worst shape of a false safety net.
  const toolInput = payload?.tool_input ?? {};
  const filePath = toolInput.file_path ?? toolInput.notebook_path ?? toolInput.path ?? toolInput.filePath ?? '';
  if (!filePath) return;

  const root = findRoot(payload?.cwd ?? process.cwd());
  if (!root) return;

  const abs = isAbsolute(filePath) ? filePath : join(root, filePath);
  // A write outside the project is refused, not merely ignored. Returning
  // silently was the wrong call: the agent developed a stable habit of writing
  // its self-check scripts to %TEMP% (2.0.3, 2.0.4, 2.0.5 - every step), so
  // those steps were "verified" by code nobody could review, re-run, or find
  // again. T3_out_of_scope caught it every single time and nothing changed,
  // because a warning that fires on every run is training, not feedback.
  // A scratch script belongs in the project - scripts/ or a tests/ file - where
  // it survives the step it was written for.
  if (!isUnderRoot(root, abs)) {
    // An MCP tool is opaque: the same `path` may be a read, a listing, or a
    // write. We cannot tell, so it must never be blocked - blocking a read is a
    // self-inflicted outage, and a hook that can break the agent gets removed
    // within a day, taking the safe channels with it. Consequence, stated
    // plainly: out-of-root MCP writes get no before-image and are invisible to
    // this hook. First-party writers still refuse.
    if (isMcp) return;
    process.stderr.write(
      '[harness] refused: write outside the project root\n' +
      '  path : ' + abs + '\n' +
      '  root : ' + root + '\n' +
      'Put the script inside the project (scripts/ or tests/) so it can be\n' +
      'reviewed and re-run. A check under %TEMP% or /tmp cannot be audited and\n' +
      'leaves this step depending on a file that is already gone.\n'
    );
    process.exit(2);
  }
  // nothing to snapshot if the file does not exist yet (a create)
  if (!existsSync(abs) || !statSync(abs).isFile()) return;

  let step = 'unknown';
  try {
    const local = JSON.parse(readFileSync(join(root, '.harness', 'local.json'), 'utf8'));
    if (local.current_step) step = String(local.current_step);
  } catch { /* keep default */ }

  let rel = filePath;
  try { rel = relative(root, abs).split(sep).join('/'); } catch { /* keep raw */ }

  const snapDir = join(root, 'docs', '_snap', step);
  const snapPath = join(snapDir, safeName(rel) + '.before');

  try {
    mkdirSync(snapDir, { recursive: true });
    // keep only the FIRST before-image for a given file within a step;
    // later edits in the same step must diff against the step's starting state
    if (!existsSync(snapPath)) {
      copyFileSync(abs, snapPath);
    }
    // .before.sha = digest of the file AS IT IS RIGHT NOW, immediately before
    // this write. Observed 2026-11-07: a parallel process edited the contract
    // file twice outside PostToolUse coverage, so "the ledger's last recorded
    // digest" reported a before-state that had not been on disk for minutes -
    // one event then carries two contradictory before-evidence (ledger field vs
    // step snapshot). The truth is whatever is on disk at this instant, measured
    // here; post-tool prefers it over both. Overwritten on every PreToolUse -
    // unlike .before, which deliberately keeps the step's first image for diffs.
    const preHash = createHash('sha256').update(readFileSync(abs)).digest('hex');
    writeFileSync(join(snapDir, safeName(rel) + '.before.sha'), preHash + '\n', 'utf8');
    // also record which step/tool first touched it, for finish-step's report
    const manifest = join(snapDir, '_manifest.json');
    let m = {};
    if (existsSync(manifest)) {
      try { m = JSON.parse(readFileSync(manifest, 'utf8')); } catch { m = {}; }
    }
    if (!m[rel]) {
      m[rel] = { first_tool: tool, at: new Date().toISOString(), before: safeName(rel) + '.before' };
      writeFileSync(manifest, JSON.stringify(m, null, 2), 'utf8');
    }
  } catch { /* never block */ }
}

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { raw += c; });
process.stdin.on('error', () => process.exit(0));
process.stdin.on('end', () => {
  try { main(raw); } catch { /* never block */ }
  process.exit(0);
});
