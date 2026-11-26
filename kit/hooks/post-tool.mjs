#!/usr/bin/env node
/**
 * Claude Code PostToolUse hook -> append one fact per tool call into events.jsonl.
 *
 * Same contract as post-tool.ps1, but ~11x faster to start (48ms vs 527ms).
 *
 * Reads the hook payload from stdin ASYNCHRONOUSLY (process.stdin events).
 * Using readFileSync(0) breaks on Windows when the parent spawns us with a
 * pipe — it silently yields an empty string. That failure mode is fatal here
 * (the hook would log nothing and still exit 0), so stdin is always read via
 * the stream API.
 *
 * Locates the project root by walking up from payload.cwd until it finds
 * '.harness/local.json' or an existing 'events.jsonl'. Exits 0 silently when
 * no harness root is found — safe to install globally.
 *
 * Event shape:
 *   {"v":1,"seq":N,"at":"...","step":"1.5","kind":"routine","actor":"hook",
 *    "event":"tool_use","data":{tool,file?,sha256?,before_sha256?,cmd?,trivial?},
 *    "prev":"...","self":"..."}
 *
 * self = sha256(canonicalJson(record without self))
 */

import { createHash } from 'node:crypto';
import { readFileSync, existsSync, statSync, openSync, writeSync, closeSync, unlinkSync, writeFileSync, renameSync, appendFileSync } from 'node:fs';
import { dirname, join, isAbsolute, relative, sep } from 'node:path';

// ---------------------------------------------------------------- append lock
// The lock must cover the tail read as well as the write. Computing seq/prev
// from state read outside the lock is exactly how two writers both produced
// seq 474 on 2026-11-07: each read 473, then each wrote 474.
// The hook must never block the agent for long, so this retries for ~3s and then
// gives up: a missed tool_use is recoverable (the file digest still moves and C7
// reports the drift), whereas a frozen agent is not.
function appendLocked(eventsPath, makeLine) {
  const lockPath = eventsPath + '.lock';
  for (let attempt = 0; attempt < 30; attempt++) {
    let fd;
    try {
      fd = openSync(lockPath, 'wx');
    } catch {
      try {
        const st = statSync(lockPath);
        if (Date.now() - st.mtimeMs > 60000) { try { unlinkSync(lockPath); } catch {} }
      } catch { /* lock vanished between calls - just retry */ }
      const until = Date.now() + 100;
      while (Date.now() < until) { /* spin briefly */ }
      continue;
    }
    try {
      let lastSeq = 0;
      let lastSelf = '';
      if (existsSync(eventsPath)) {
        const body = readFileSync(eventsPath, 'utf8');
        for (const l of body.split('\n')) {
          if (!l.trim()) continue;
          let rec;
          try { rec = JSON.parse(l); } catch { continue; }
          if (typeof rec.seq === 'number') lastSeq = rec.seq;
          if (typeof rec.self === 'string') lastSelf = rec.self;
        }
      }
      const line = makeLine(lastSeq, lastSelf);
      const out = openSync(eventsPath, 'a');
      try { writeSync(out, line); } finally { closeSync(out); }
      return true;
    } catch {
      return false;
    } finally {
      closeSync(fd);
      try { unlinkSync(lockPath); } catch {}
    }
  }
  return false;
}

// ---------------------------------------------------------------- canonical json
function canonical(v) {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') return Number.isInteger(v) ? String(v) : String(v);
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(canonical).join(',') + ']';
  if (typeof v === 'object') {
    return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + canonical(v[k])).join(',') + '}';
  }
  return JSON.stringify(v);
}

const sha256 = s => createHash('sha256').update(s, 'utf8').digest('hex');

const safeName = rel => rel.split('/').join('__');

function sha256File(p) {
  try {
    if (!existsSync(p) || !statSync(p).isFile()) return '';
    return createHash('sha256').update(readFileSync(p)).digest('hex');
  } catch { return ''; }
}

// ---------------------------------------------------------------- trivial commands
// A command that exits 0 whatever the code does. Piped commands are NOT trivial:
// the downstream command may check something.
function isTrivialCommand(cmd) {
  if (!cmd) return false;
  const c = cmd.trim();
  if (c.includes('|')) return false;

  const segments = c.split(/&&|\|\||;/).map(s => s.trim()).filter(Boolean);
  if (segments.length === 0) return false;

  const patterns = [
    /^(true|:)$/,
    /^exit\s+0$/,
    /^cmd(\.exe)?\s*\/c\s+exit\s+0$/i,
    /^echo\b/i,
    /^printf\b/i,
    /^Write-Output\b/i,
    /^Write-Host\b/i,
    /^cd\s+\S+$/,
    /^python(\d|\.\d+)?\s+-c\s+["']?\s*pass\s*["']?$/,
    /^python(\d|\.\d+)?\s+-c\s+["']?\s*print\(.*\)\s*["']?$/,
    /^python(\d|\.\d+)?\s+-c\s+["']?\s*(import\s+sys\s*;\s*)?sys\.exit\(0\)\s*["']?$/,
  ];
  return segments.every(seg => patterns.some(re => re.test(seg)));
}

// ---------------------------------------------------------------- locate root
function findRoot(start) {
  if (!start) return null;
  let dir = start;
  for (let i = 0; i < 40; i++) {
    if (existsSync(join(dir, '.harness', 'local.json')) || existsSync(join(dir, 'events.jsonl'))) {
      return dir;
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

// ---------------------------------------------------------------- main
function main(raw) {
  if (!raw.trim()) return;

  let payload;
  try { payload = JSON.parse(raw); } catch { return; }

  const toolName = payload?.tool_name ?? '';
  if (!toolName) return;

  const toolInput = payload?.tool_input ?? {};
  // Same per-tool path key problem as pre-tool: NotebookEdit -> notebook_path,
  // MCP file tools -> path/filePath. Without these the post hook silently
  // recorded nothing for two registered channels.
  const filePath = toolInput.file_path ?? toolInput.notebook_path ?? toolInput.path ?? toolInput.filePath ?? '';
  const command = toolInput.command ?? '';
  if (!filePath && !command) return;

  const root = findRoot(payload?.cwd ?? process.cwd());
  if (!root) return;

  const eventsPath = join(root, 'events.jsonl');
  const localPath = join(root, '.harness', 'local.json');

  let currentStep = 'unknown';
  try {
    if (existsSync(localPath)) {
      const local = JSON.parse(readFileSync(localPath, 'utf8'));
      if (local.current_step) currentStep = String(local.current_step);
    }
  } catch { /* keep default */ }

  let lastSeq = 0;
  let lastSelf = '';
  // Last digest the ledger recorded for each path. This is the only honest source
  // for "the state of the file before THIS write" - see the before_sha256 note below.
  const lastShaByFile = new Map();

  try {
    if (existsSync(eventsPath)) {
      const body = readFileSync(eventsPath, 'utf8');
      for (const line of body.split('\n')) {
        if (!line.trim()) continue;
        let rec;
        try { rec = JSON.parse(line); } catch { continue; }
        if (typeof rec.seq === 'number') lastSeq = rec.seq;
        if (typeof rec.self === 'string') lastSelf = rec.self;
        if (rec?.event === 'tool_use' && rec?.data && typeof rec.data.file === 'string'
            && typeof rec.data.sha256 === 'string' && rec.data.sha256) {
          lastShaByFile.set(rec.data.file, rec.data.sha256);
        }
      }
    }
  } catch { /* start a fresh chain */ }

  const data = { tool: toolName, observed_by: 'hook' };
  // MCP writes are recorded but carry no pre-image (the tool is opaque, see
  // pre-tool). Tagging the transport lets a detector tell "no before_sha256
  // because nobody looked" apart from "because this channel cannot look".
  if (toolName.startsWith('mcp__')) data.via = 'mcp';

  if (filePath) {
    const abs = isAbsolute(filePath) ? filePath : join(root, filePath);
    let rel = filePath;
    try { rel = relative(root, abs).split(sep).join('/'); } catch { /* keep raw */ }
    data.file = rel;
    data.sha256 = sha256File(abs);
    // `before_sha256` means "the digest of the file as it was before THIS write".
    // Sources in trust order (2026-11-07 rewrote this twice):
    //   1. the PreToolUse sidecar - the actual bytes on disk moments before this
    //      write. A parallel process edited this very contract file outside hook
    //      coverage, so the ledger-tail answer ("7f3a4bbc") had not described the
    //      disk for minutes; the event then carried two contradictory before-
    //      evidence fields (ledger said 7f3a4bbc, the step snapshot said c99dff5b).
    //      Only a measurement taken at the pre-write instant can be called a before.
    //   2. the ledger's last recorded digest for this path (pre-tool sidecar absent:
    //      hook installed later, or a step advance raced between pre and post).
    //   3. the step snapshot's image - the step-starting state, correct input for
    //      a step diff, wrong for the second write of one step (obs3 D5), kept only
    //      as a last resort for files that predate the hook.
    const snapPath = join(root, 'docs', '_snap', currentStep, safeName(rel) + '.before');
    const sidecarPath = snapPath + '.sha';
    if (existsSync(sidecarPath)) {
      try {
        const sb = readFileSync(sidecarPath, 'utf8').trim();
        if (/^[0-9a-f]{64}$/.test(sb)) {
          data.before_sha256 = sb;
          try { unlinkSync(sidecarPath); } catch { /* stale copies are harmless */ }
        }
      } catch { /* fall through to the ledger answer */ }
    }
    if (!data.before_sha256 && lastShaByFile.has(rel)) {
      data.before_sha256 = lastShaByFile.get(rel);
    }
    if (!data.before_sha256) {
      data.before_sha256 = existsSync(snapPath) ? sha256File(snapPath) : '';
    }
  } else if (command) {
    data.cmd = command;
    data.trivial = isTrivialCommand(command);
  }

  const buildLine = (lastSeq, lastSelf) => {
    const record = {
      v: 1,
      seq: lastSeq + 1,
      at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
      step: currentStep,
      kind: 'routine',
      actor: 'hook',
      event: 'tool_use',
      data,
      prev: lastSelf,
    };
    record.self = sha256(canonical(record));
    appendedRecord = record;
    return JSON.stringify(record) + '\n';
  };
  let appendedRecord = null;
  // appendLocked returns true ONLY if the line actually hit disk. The 2026-11-09
  // incident: the old code advanced the checkpoint whenever `appendedRecord` was
  // set, but that flag was assigned at LINE CONSTRUCTION time, before the write;
  // a failed append still moved the anchor to a seq/hash that never landed
  // (observed twice: 944/8372c255 and 959/0f29b076, both phantom). Respect the
  // return value, and anchor to what the ledger TAIL actually contains.
  const appended = appendLocked(eventsPath, buildLine);
  // Advance the external anchor (see _common.ps1 for the reasoning). The hook
  // is the highest-frequency writer; if only the PowerShell side advanced the
  // checkpoint, a truncation inside a hook-only stretch would go unnoticed.
  // A failed checkpoint write is NOT an error: nothing here may ever disturb
  // the agent's tool call.
  if (appended && appendedRecord) {
    try {
      // Re-read the real tail; never anchor to a constructed-but-unwritten row.
      let tailRec = null;
      const body = readFileSync(eventsPath, 'utf8');
      const lines = body.split('\n');
      for (let i = lines.length - 1; i >= 0; i--) {
        if (!lines[i].trim()) continue;
        try { tailRec = JSON.parse(lines[i]); } catch { tailRec = null; }
        break;
      }
      if (tailRec && typeof tailRec.seq === 'number' && typeof tailRec.self === 'string') {
        const cpPath = join(root, '.harness', 'checkpoint.json');
        // monotonic gate, same invariant as Write-LedgerCheckpoint on the PS side
        // (O5-04): never move backwards, never overwrite a seq with a different
        // hash - that is precisely the phantom-anchor shape.
        let cur = null;
        try { cur = JSON.parse(readFileSync(cpPath, 'utf8')); } catch {}
        const ok = !cur
          || (tailRec.seq > cur.seq)
          || (tailRec.seq === cur.seq && tailRec.self === cur.head);
        if (ok) {
          const tmp = cpPath + '.tmp-' + process.pid;
          writeFileSync(tmp, JSON.stringify({
            seq: tailRec.seq, head: tailRec.self,
            at: tailRec.at, source: 'post-tool-hook',
          }));
          renameSync(tmp, cpPath);
          // rolling history so a future divergence is diagnosable instead of
          // inviting a blind restore-from-backup (backups can predate 174 records).
          try {
            appendFileSync(cpPath.replace('checkpoint.json', 'checkpoint.history.jsonl'),
              JSON.stringify({ seq: tailRec.seq, head: tailRec.self, at: tailRec.at, src: 'hook' }) + '\n');
          } catch {}
        }
      }
    } catch { /* lag is tolerated by design */ }
  }
}

// ---------------------------------------------------------------- stdin (stream, not sync)
let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { raw += chunk; });
process.stdin.on('error', () => { process.exit(0); });
process.stdin.on('end', () => {
  try { main(raw); } catch { /* never block the agent */ }
  process.exit(0);
});
