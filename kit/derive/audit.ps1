<#
.SYNOPSIS
  Audit harness WIRING, not project progress. Read-only: never writes anything.

.DESCRIPTION
  Three scripts answer three different questions. Keeping them apart matters:

      status.ps1    readiness   can the project advance to the next stage?
      trigger.ps1   attention   does anything need Hermes right now?
      audit.ps1     liveness    is the harness itself still connected?

  A project can be perfectly ready while the harness is structurally broken:
  files exist, stages advance, and half the safety rules never fire because
  their input events have no writer. Nothing in the kit used to notice that,
  which is why T3/T4/T5/T6 sat dead through a full end-to-end run.

  WHAT IS CHECKED, AND WHERE THE IDEA COMES FROM

  C1 chain       Hash chain intact. Same role as `git fsck`: verify the object
                 graph rather than trust that appends were well behaved.
                 (kit ② fact layer; seekmemory store/ledger.py)

  C2 registration Which event types can the writer actually produce? This is
                 the "registration" half of OpenTelemetry's rule that
                 *registration is not emission* - a declared signal that no
                 code path can emit is a lie told by the schema.

  C3 emission    Which event types have ever actually appeared? The "emission"
                 half. Also reports the reverse direction: types that appear in
                 the ledger but are absent from the design document. Drift goes
                 both ways and only checking one direction hides half of it.

  C4 rule input  For each trigger rule, how many times has its input event been
                 emitted? Same idea as `opa test -coverage`, which reports how
                 often each policy rule was actually exercised. This is COUNTING
                 only. A rule with zero input is not automatically broken - a
                 project that never deviated rightly has no T1. "Can it ever
                 fire" is C2's question. Conflating the two made T1/T5/T6 report
                 as faults forever on a healthy project.

  C5 evidence    Per stage: latest verify = pass | FAIL | VOID | none. These are
                 three different facts, not two. `FAIL` is a counter-proof (the
                 check ran and the code is wrong). `VOID` is proof of nothing
                 (it exited 0 because it cannot fail: `echo ok`, a trivial
                 command). `none` is a gap in provability. Collapsing VOID into
                 either PASS or FAIL is exactly how `echo ok` survived as
                 evidence for stage 0.1 through a whole run.
                 The premise is mutation testing: a check that has never been
                 seen to fail has not been shown to be able to fail. Its weaker
                 form - "verify declared but never once failed" - is a warning.

  C6 verify-ref  Every file a verify command names must exist. Same class of
                 defect as a dangling foreign key or a broken `$ref`: the plan
                 references something the world does not contain. Observed in
                 practice - three verify commands pointed at check-docs.ps1 /
                 check-ignore.ps1 / check-cdp.ps1, none of which were ever
                 written, and nobody found out until they blocked a step.

  C7 drift       Compare each generated file's digest with the digest last
                 recorded in the ledger. A mismatch means something wrote
                 without an event. This is Terraform's drift model, and it is
                 deliberately the refresh-only form: read reality, diff against
                 declaration, never correct. mtime is kept as a secondary hint
                 because a touched-but-identical file is not drift.

  C8 attribution If one step owns most events, `current_step` has stopped
                 advancing and events are being filed against the wrong stage.

  AGGREGATION: worst status wins, as in Spring Boot Actuator health. One fault
  makes the whole audit fail; warnings never do. Absence of a check is never
  reported as success - an unreadable input is `unknown`, not `up`.

  Exit codes:
    0  no faults (warnings allowed)
    1  at least one fault
    2  cannot read profile

.EXAMPLE
  pwsh -File audit.ps1
  pwsh -File audit.ps1 -Json
#>
[CmdletBinding()]
param(
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),
    [switch] $Json,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$eventsPath = Join-Path $Root 'events.jsonl'
$profPath   = Join-Path (Join-Path $Root '.harness') 'project.json'
$localPath  = Join-Path (Join-Path $Root '.harness') 'local.json'
$appendPath = Join-Path $PSScriptRoot 'append-event.ps1'
$finishPath = Join-Path $PSScriptRoot 'finish-step.ps1'
$hookPath   = Join-Path (Join-Path (Join-Path $Root '.harness') 'hooks') 'post-tool.mjs'

if (-not (Test-Path -LiteralPath $profPath -PathType Leaf)) {
    if ($Json) { [pscustomobject]@{ ok = $false; error = 'profile_missing' } | ConvertTo-Json -Depth 4 }
    elseif (-not $Quiet) { Write-Host "[FAIL] project.json not found: $profPath" -ForegroundColor Red }
    exit 2
}

$profile = Get-Content -LiteralPath $profPath -Raw -Encoding UTF8 | ConvertFrom-Json
$stages = @()
$sp = $profile.PSObject.Properties['stages']
if ($null -ne $sp) { $stages = @($sp.Value) }

$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param([string] $Check, [string] $Level, [string] $Subject, [string] $Detail)
    $findings.Add([pscustomobject]@{ check = $Check; level = $Level; subject = $Subject; detail = $Detail })
}

# ---------------------------------------------------------------- read ledger
$events = @()
$chainOk = $false
if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
    $events = @(Read-EventLog -Path $eventsPath)
    $ledger = & (Join-Path $PSScriptRoot 'verify-ledger.ps1') -Path $eventsPath -Json -Quiet
    try { $lo = $ledger | ConvertFrom-Json } catch { $lo = $null }
    $chainOk = ($null -ne $lo -and [bool]$lo.ok)
}
if (-not $chainOk) {
    Add-Finding 'C1' 'fault' 'events.jsonl' 'hash chain broken, unreadable, or missing - every later check can only be trusted partially'
}

# ---------------------------------------------------------------- C1b external anchor
# A hash chain proves nothing was changed or removed in the MIDDLE; it cannot
# see its own tail being cut. The checkpoint lives outside the ledger (written
# by append-event and the post-tool hook, see _common.ps1): if the ledger no
# longer contains the head the anchor attests, records were destroyed.
if ($chainOk -and $events.Count -gt 0) {
    $cp = Get-LedgerCheckpoint -ProjectRoot $Root
    if ($null -eq $cp) {
        Add-Finding 'C1' 'warn' 'checkpoint' 'no .harness/checkpoint.json - tail truncation of the ledger is currently undetectable (writers create it on the next successful append)'
    }
    else {
        $cpSeq = [int]$cp.seq
        $headSeq = [int]$events[-1].seq
        $selfs = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($e1 in $events) {
            $sp1 = $e1.PSObject.Properties['self']
            if ($null -ne $sp1) { [void]$selfs.Add([string]$sp1.Value) }
        }
        $cpHead = [string]$cp.head
        if ($cpSeq -gt $headSeq -or (-not $selfs.Contains($cpHead))) {
            # Was the attested head EVER real? The checkpoint history (written by
            # both sides after the 2026-11-09 phantom-anchor fix) distinguishes a
            # true tail truncation from a fabricated anchor. Do not print restore
            # advice unless the head appears in history - on 11-09 the bak files
            # predated the tail by 174 records, so "restore from bak" would have
            # truncated the live ledger back days. Never advise that blind.
            $histSeen = $false
            $histPath = Join-Path (Join-Path $Root '.harness') 'checkpoint.history.jsonl'
            if (Test-Path -LiteralPath $histPath) {
                foreach ($hl in @(Get-Content -LiteralPath $histPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                    if ($hl -and $hl.Contains($cpHead)) { $histSeen = $true; break }
                }
            }
            $advice = if ($histSeen) {
                'that head was previously attested in checkpoint history - records after it were REMOVED: identify the removing process, do not restore any backup newer-tail-wise without comparing all events after the divergence point'
            } else {
                'that head appears nowhere (not in the ledger, not in checkpoint history): the ANCHOR is fabricated (append failed after the anchor moved), the ledger is likely intact - verify the chain (C1 pass) and have the next successful append re-anchor it; NEVER restore from events.jsonl.bak-* unless history proves real removal'
            }
            Add-Finding 'C1' 'fault' 'truncation' ("ledger ENDS at seq {0} but the external checkpoint attests seq {1} (head {2}, written {3} by {4}) - {5}" -f $headSeq, $cpSeq, $cpHead.Substring(0, [Math]::Min(12, $cpHead.Length)), [string]$cp.at, [string]$cp.source, $advice)
        }
    }
}

# ---------------------------------------------------------------- C2/C3 registration vs emission
# The design document is the source of truth for which event types exist.
$DECLARED = @(
    'tool_use', 'verify',
    'deviate', 'skip', 'blocker_open', 'blocker_close',
    'contract_change', 'gate', 'anchor', 'step_advance', 'unrecorded_write',
    # 2026-11-17：改计划不再走 deviate（那会每次冒一张 T1 卡），也不走 tool_use
    # （它要求 data.file）。plan_edit 是独立的例行记录：谁改了哪一字段、旧值→新值。
    'plan_edit'
)

$registered = @()
if (Test-Path -LiteralPath $appendPath -PathType Leaf) {
    $src = Get-Content -LiteralPath $appendPath -Raw -Encoding UTF8
    $m = [regex]::Match($src, 'ValidateSet\(([^)]*)\)')
    if ($m.Success) {
        $registered = @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    }
}
# routine events come from the hook or finish-step, not from append-event
$routineWriters = @{}
foreach ($ev in @('tool_use')) {
    $writers = @()
    foreach ($p in @($hookPath, $finishPath)) {
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $body = Get-Content -LiteralPath $p -Raw -Encoding UTF8
            # Match the event name anywhere in the file. A strict `event: 'tool_use'`
            # pattern misses hooks that pass the name through a variable
            # (`event: kind`), which reported the busiest event in the ledger as
            # having no writer at all.
            if ($body -match [regex]::Escape($ev)) { $writers += (Split-Path $p -Leaf) }
        }
    }
    if ($writers.Count -gt 0) { $routineWriters[$ev] = @($writers) }
}

$observed = @{}
$stepCount = @{}
$stepSeq = [System.Collections.Generic.List[string]]::new()
$lastAt = $null
$lastSha = @{}
$hookAlive = @{}
foreach ($e in $events) {
    if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
    $ev = [string]$e.PSObject.Properties['event'].Value
    if ($ev -ne '') { $observed[$ev] = 1 + $(if ($observed.ContainsKey($ev)) { $observed[$ev] } else { 0 }) }
    $st = [string]$e.PSObject.Properties['step'].Value
    if ($st -ne '') {
        $stepCount[$st] = 1 + $(if ($stepCount.ContainsKey($st)) { $stepCount[$st] } else { 0 })
        $stepSeq.Add($st)
    }
    # Only tool_use proves the hook was running for this stage. verify events are
    # written by append-event directly and say nothing about hook coverage.
    if ($ev -eq 'tool_use' -and $st -ne '') { $hookAlive[$st] = $true }
    $ap = $e.PSObject.Properties['at']
    if ($null -ne $ap) { $lastAt = [string]$ap.Value }

    # collect recorded digests from both routine shapes
    $dp = $e.PSObject.Properties['data']
    if ($null -eq $dp) { continue }
    $d = $dp.Value
    if ($ev -eq 'tool_use') {
        $fp = $d.PSObject.Properties['file']
        $hp = $d.PSObject.Properties['sha256']
        if ($null -ne $fp -and $null -ne $hp -and [string]$hp.Value -ne '') {
            $lastSha[[string]$fp.Value] = [string]$hp.Value
        }
    }
}

# C2: can anything emit it?
$noWriter = @()
foreach ($ev in $DECLARED) {
    # Having appeared in the ledger IS proof that a writer exists - stronger than
    # any static scan. Only a type that has never been emitted needs its
    # reachability proven from code, otherwise a project without a hooks
    # directory (a fixture, a fresh install) reports its busiest events as
    # unwritable.
    if ($observed.ContainsKey($ev)) { continue }
    if ($routineWriters.ContainsKey($ev)) { continue }
    if ($ev -in $registered) { continue }
    $noWriter += $ev
}
foreach ($ev in $noWriter) {
    Add-Finding 'C2' 'fault' $ev 'declared in the design, but neither append-event nor any hook/finish-step path can emit it'
}

# C3: has anything emitted it? both directions.
$neverEmitted = @($DECLARED | Where-Object { -not $observed.ContainsKey($_) })
$undeclared  = @($observed.Keys | Where-Object { $_ -notin $DECLARED } | Sort-Object)
foreach ($ev in $undeclared) {
    Add-Finding 'C3' 'warn' $ev "observed $($observed[$ev]) times but absent from the design document - the ledger is running ahead of the spec"
}

# ---------------------------------------------------------------- C4 rule input coverage
# Mirrors trigger.ps1's table. Keep in sync when rules change.
$RULES = [ordered]@{
    'T1' = @('deviate')
    'T2' = @('contract_change')
    'T3' = @('tool_use')
    'T4' = @('tool_use')
    'T5' = @('skip')
    'T6' = @('blocker_open', 'blocker_close')
    'T11' = @('tool_use')
    'T12' = @('gate')
    # the sweep's output feeds T13: without this line a whole detector class
    # could go silently unexercised, which is the exact blind spot C4 exists
    # to catch elsewhere
    'T13' = @('unrecorded_write')
    'T14' = @('verify')
'T14b' = @('verify')
'T15' = @('verify')
}
$ruleCoverage = [ordered]@{}
$deadRules = @()
# T3/T4 judge what the AGENT did, so their input count must exclude the harness
# describing itself. tool_use now has three writers (hook, maintenance note,
# seal's per-file records) and seal alone accounted for 252 of 371 records in one
# session: counting all of them read as "T3 is exercised 387 times" when the
# agent had made ~118 writes. A coverage number that mostly measures archiving
# says nothing about whether the rule has been exercised on real work.
# A record without observed_by predates the field, and the hook was the only
# writer then, so it counts as hook-observed.
$observedHookToolUse = 0
foreach ($e in $events) {
    if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
    if ([string]$e.PSObject.Properties['event'].Value -ne 'tool_use') { continue }
    $dp4 = $e.PSObject.Properties['data']
    $ob4 = 'hook'
    if ($null -ne $dp4) {
        if ($null -ne $dp4.Value.PSObject.Properties['observed_by']) {
            $ob4 = [string]$dp4.Value.observed_by
        }
        elseif ($null -ne $dp4.Value.PSObject.Properties['tool']) {
            if ([string]$dp4.Value.tool -in @('seal', 'maintenance', 'manual')) { $ob4 = 'script' }
        }
    }
    if ($ob4 -eq 'hook') { $observedHookToolUse++ }
}
foreach ($rule in $RULES.Keys) {
    $needs = @($RULES[$rule])
    $total = 0
    if ($rule -in @('T3', 'T4')) {
        $total = $observedHookToolUse
    }
    else {
        foreach ($n in $needs) { if ($observed.ContainsKey($n)) { $total += [int]$observed[$n] } }
    }
    $ruleCoverage[$rule] = $total
    if ($total -eq 0) { $deadRules += $rule }
}
# Counting only. A rule with zero input is not necessarily broken: a project that
# never deviated legitimately has no T1. "Can this rule EVER fire" is C2's job
# (does a writer path exist). Folding the two together made T1/T5/T6 report as
# faults forever on a perfectly healthy project.

# ---------------------------------------------------------------- C5 evidence three-state
$evState = @{}
$evFailCount = @{}
$evVoidCount = @{}
$evPassCount = @{}
$evCmd = @{}
foreach ($e in $events) {
    if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
    if ([string]$e.PSObject.Properties['event'].Value -ne 'verify') { continue }
    $dp = $e.PSObject.Properties['data']
    if ($null -eq $dp) { continue }
    $d = $dp.Value
    $tp = $d.PSObject.Properties['target']
    if ($null -eq $tp) { continue }
    $target = [string]$tp.Value
    if ($target -eq '') { continue }
    $cp = $d.PSObject.Properties['cmd']
    if ($null -ne $cp) { $evCmd[$target] = [string]$cp.Value }
    $exit = if ($null -ne $d.PSObject.Properties['exit']) { [int]$d.PSObject.Properties['exit'].Value } else { 1 }
    $triv = ($null -ne $d.PSObject.Properties['trivial']) -and [bool]$d.PSObject.Properties['trivial'].Value
    $real = ($null -ne $d.PSObject.Properties['real_test']) -and [bool]$d.PSObject.Properties['real_test'].Value
    # Three outcomes, not two. `exit != 0` is a counter-proof: the check ran and
    # the code is wrong. `exit == 0` with trivial=true is neither proof nor
    # counter-proof - it establishes nothing. Reporting that as 'fail' overstates
    # it; reporting it as 'pass' is a lie. It gets its own value.
    $verdict = if ($exit -ne 0) { 'fail' }
               elseif ($triv -or -not $real) { 'void' }
               else { 'pass' }
    $evState[$target] = $verdict
    if ($verdict -eq 'fail') { $evFailCount[$target] = 1 + $(if ($evFailCount.ContainsKey($target)) { $evFailCount[$target] } else { 0 }) }
    elseif ($verdict -eq 'void') { $evVoidCount[$target] = 1 + $(if ($evVoidCount.ContainsKey($target)) { $evVoidCount[$target] } else { 0 }) }
    else { $evPassCount[$target] = 1 + $(if ($evPassCount.ContainsKey($target)) { $evPassCount[$target] } else { 0 }) }
}
foreach ($s in $stages) {
    $id = [string]$s.id
    if ($evState.ContainsKey($id) -and $evState[$id] -eq 'fail') {
        Add-Finding 'C5' 'fault' $id 'latest verify FAILED - this is a counter-proof, not a missing citation'
    }
    # A pass is only evidence for THIS stage if it ran THIS stage's declared
    # acceptance command. Observer #4 caught C5 calling 1.1 'pass' while the
    # record ran `python -c "import yaml"` and the profile declares
    # `pip check` - status called the same evidence verify_mismatch. Two
    # views, two answers: the "three views, three answers" failure this
    # harness was built to kill, reproduced inside the audit layer. Same
    # join separator as status/append-event or nothing ever matches.
    if ($evState.ContainsKey($id) -and $evState[$id] -eq 'pass') {
        $vp5 = $s.PSObject.Properties['verify']
        $declared5 = ''
        if ($null -ne $vp5) {
            $parts5 = @(@($vp5.Value) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $declared5 = ($parts5 -join ' ;; ')
        }
        $ran5 = if ($evCmd.ContainsKey($id)) { [string]$evCmd[$id] } else { '' }
        if ($declared5 -ne '' -and $ran5 -ne $declared5) {
            $evState[$id] = 'mismatch'
            Add-Finding 'C5' 'warn' $id "its newest green verify ran a command the stage does not declare (ran '$ran5', declared '$declared5') - a pass for someone else's acceptance is not evidence here"
        }
    }
}
foreach ($id in $evVoidCount.Keys) {
    # 只要之后有过一次"能失败且通过"的 verify，这条就不再成立。
    # 2026-11-17：1.1 先 VOID 两次、修好判据后 PASS（seq 842），但这里仍按历史计数告警，
    # 等于告诉人"这步永远建立不了任何东西"——告警说的是过去，人读到的是现在。
    if ($evState.ContainsKey($id) -and $evState[$id] -eq 'pass') { continue }
    Add-Finding 'C5' 'warn' $id "verify ran $($evVoidCount[$id]) time(s) but never meaningfully - a command that cannot fail establishes nothing"
}
# mutation-testing's weak form: a check never seen to fail has not been shown
# it can fail. Warn only - a young stage legitimately has no failures yet.
#
# Reported as ONE line covering every such stage, not one line per stage. The
# condition is not a defect in any particular stage; it is a standing property
# of a young project, and it arrives one line per stage for as long as the
# project is young. Left per-stage it buries the findings that do change - the
# previous run already had 3 of these out of 11 warnings. Same reasoning as
# T2c: a permanent condition deserves a permanent single line that shrinks,
# not a stream that grows.
$youngPass = @()
foreach ($id in $evPassCount.Keys) {
    if (-not $evFailCount.ContainsKey($id) -and -not $evVoidCount.ContainsKey($id)) { $youngPass += $id }
}
if ($youngPass.Count -gt 0) {
    $youngSorted = @($youngPass | Sort-Object)
    Add-Finding 'C5' 'warn' 'evidence' ("{0} stage(s) have passed every time and never once failed ({1}) - cannot yet distinguish 'correct' from 'unable to fail'; this warning disappears per stage as soon as that stage produces a real failure" -f $youngPass.Count, ($youngSorted -join ', '))
}

# ---------------------------------------------------------------- C6 verify references exist
# A verify command legitimately names files that do not exist yet: it runs at
# the END of its own stage, so `main.py` appearing in 2.0.5's verify is correct
# while 2.0.5 is pending. The defect is narrower than "file missing". The
# dependency is unowned when the cited path is neither on disk nor listed in any
# stage's `generates` - nobody is on the hook to produce it, so that verify can
# never pass no matter how much work gets done.
$planned = @{}
foreach ($s in $stages) {
    $gp = $s.PSObject.Properties['generates']
    if ($null -eq $gp) { continue }
    foreach ($g in @($gp.Value)) { $planned[([string]$g -replace '\\', '/')] = $true }
}

$missingRefs = @()
$unownedRefs = @()
foreach ($s in $stages) {
    $vp = $s.PSObject.Properties['verify']
    if ($null -eq $vp) { continue }
    $cmd = [string]$vp.Value
    if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
    foreach ($m in [regex]::Matches($cmd, '[A-Za-z0-9_\-\.\\/]+\.(?:py|ps1|mjs|psm1)')) {
        $token = $m.Value
        if ($token -match '^\.venv') { continue }
        $abs = if ([System.IO.Path]::IsPathRooted($token)) { $token } else { Join-Path $Root $token }
        if (Test-Path -LiteralPath $abs -PathType Leaf) { continue }
        $norm = ($token -replace '\\', '/')
        if ($planned.ContainsKey($norm)) { continue }
        $unownedRefs += [pscustomobject]@{ step = [string]$s.id; token = $token }
        $missingRefs += [pscustomobject]@{ step = [string]$s.id; token = $token }
    }
}
foreach ($r in $unownedRefs) {
    Add-Finding 'C6' 'fault' $r.step "verify depends on '$($r.token)': absent from disk AND from every stage's generates - no stage is responsible for producing it, so this verify can never pass"
}

# ---------------------------------------------------------------- C7 drift (refresh-only)
$drifted = 0
$unlogged = @()
foreach ($s in $stages) {
    $gp = $s.PSObject.Properties['generates']
    if ($null -eq $gp) { continue }
    foreach ($g in @($gp.Value)) {
        # 11-13 fix: ledger digests (hook/record-edit) are stored with forward
        # slashes; generates may use backslashes. Normalize before the lastSha
        # lookup or a recorded write reads as "unrecorded" (slash mismatch).
        $rel = ([string]$g) -replace '\\', '/'
        $abs = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $Root $rel }
        if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }
        $now = Get-FileSha256Hex -Path $abs
        if ($lastSha.ContainsKey($rel)) {
            if ($now -ne $lastSha[$rel]) {
                # 08:45:41 lesson (observer #6): audit snapshotted the ledger, a hook
                # then finished its append 8 seconds later, and C7 shouted FAULT over a
                # write that WAS being recorded - right at the instant of reading. Before
                # accusing, wait one beat and re-check BOTH the file and the fresh ledger
                # tail for a newer digest of this exact file (same shape as sweep's O5-02
                # recheck). A drift that survives that is real; one that resolves is a
                # timing seam and must not command the human into a duplicate record-edit.
                Start-Sleep -Milliseconds 400
                $now2 = Get-FileSha256Hex -Path $abs
                $tailLatest = ''
                foreach ($tl in [System.IO.File]::ReadLines($eventsPath, [System.Text.Encoding]::UTF8)) {
                    if ($tl -notmatch '"sha256"') { continue }
                    try { $tr2 = $tl | ConvertFrom-Json } catch { continue }
                    # PSObject.Properties guard: deviate/tool_use records without a
                    # data.file field made the bare `$tr2.data.file` test THROW under
                    # StrictMode - this recheck (written to fix C7's torn-read) died on
                    # its own new deviate the first day. Property existence is not a
                    # property access.
                    if ($null -eq $tr2.data) { continue }
                    $fpp = $tr2.data.PSObject.Properties['file']
                    if ($null -eq $fpp) { continue }
                    if ((([string]$fpp.Value) -replace '\\', '/') -ne $rel) { continue }
                    $spp = $tr2.data.PSObject.Properties['sha256']
                    if ($null -eq $spp) { continue }
                    $ts2 = [string]$spp.Value
                    if ($ts2 -match '^[0-9a-f]{64}$') { $tailLatest = $ts2 }
                }
                if ($tailLatest -eq $now2) {
                    Add-Finding 'C7' 'warn' ([string]$s.id) "$rel resolved during the audit window (fresh tail carries its digest) - recording was in flight, no action"
                    continue
                }
                $drifted++
                $rec = [string]$lastSha[$rel]
                Add-Finding 'C7' 'fault' ([string]$s.id) ("$rel on disk ($($now2.Substring(0,[Math]::Min(12,$now2.Length)))) does not match the ledger ($($rec.Substring(0,[Math]::Min(12,$rec.Length)))) - a write happened that no event records; explain it: pwsh -File .harness\derive\record-edit.ps1 -File $rel")
            }
        }
        else {
            $unlogged += [pscustomobject]@{ step = [string]$s.id; path = $rel }
        }
    }
}
foreach ($u in $unlogged) {
    # Severity depends on whether the harness was watching this stage at the time.
    # If the stage already produced verify events, the hook was demonstrably alive
    # for it - so a file with no recorded digest is an unlogged write, not a
    # pre-hook artefact. Without this split every project carries a permanent
    # fault for files created before the hook was installed.
    if ($hookAlive.ContainsKey($u.step)) {
        Add-Finding 'C7' 'fault' $u.step "$($u.path) exists with no digest in the ledger, and this stage already has verify events - the hook was alive here, so this write went unrecorded"
    }
    else {
        Add-Finding 'C7' 'warn' $u.step "$($u.path) exists but the ledger has no digest for it - presence is not provenance (predates the hook)"
    }
}

# ---------------------------------------------------------------- C8 attribution
# C8 is REPORTED, not judged. A step legitimately owns most recent events while
# you are working on it; and because the hook stamps every event with local_step,
# "event step" and "local_step" are equal by construction, so no arithmetic over
# the ledger can tell a frozen current_step from a busy one. The old version
# warned on the all-time fraction, which never decayed: 50 events misfiled once
# stayed 50 forever and the warning outlived the bug. Numbers here, no verdict.
$WIN = 20
$recentCount = @{}
$recentTotal = 0
if ($stepSeq.Count -gt 0) {
    $start = [Math]::Max(0, $stepSeq.Count - $WIN)
    for ($i = $start; $i -lt $stepSeq.Count; $i++) {
        $s7 = $stepSeq[$i]
        $recentCount[$s7] = 1 + $(if ($recentCount.ContainsKey($s7)) { $recentCount[$s7] } else { 0 })
        $recentTotal++
    }
}
$topStep = ''
$topCount = 0
if ($recentCount.Count -gt 0) {
    $top = $recentCount.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1
    $topStep = [string]$top.Key
    $topCount = [int]$top.Value
}

# ---------------------------------------------------------------- C9 decision records
# Hermes numbers its own entries. If a number is invented rather than taken from
# seq, nothing downstream can tell - the record still reads plausibly. So check
# every D-NNN against the ledger. Gerrit solves the same problem by having a hook
# generate the Change-Id instead of trusting the author; here seq already exists,
# so D-<seq> is the cheapest correct answer. Gaps are expected and healthy.
$seqSet = @{}
foreach ($e in $events) {
    if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
    $sq0 = $e.PSObject.Properties['seq']
    if ($null -ne $sq0) { $seqSet[[int]$sq0.Value] = $true }
}
$mdPath = Join-Path $Root 'docs\变更记录.md'
$dCount = 0
if (Test-Path -LiteralPath $mdPath -PathType Leaf) {
    $md = Get-Content -LiteralPath $mdPath -Raw -Encoding UTF8
    $seenD = @{}
    foreach ($m in [regex]::Matches($md, '(?m)^#{2,3}\s*D-(\d+)\b')) {
        $dn = [int]$m.Groups[1].Value
        if ($seenD.ContainsKey($dn)) { continue }
        $seenD[$dn] = $true
        $dCount++
        if (-not $seqSet.ContainsKey($dn)) {
            Add-Finding 'C9' 'fault' "D-$dn" "decision record cites seq $dn, which is not in the ledger - the number was invented, not derived"
        }
    }
}
# A check with an empty input set has not passed - it has not run. The file
# announced a D-<seq> regime and then received zero such headings, so C9 kept
# reporting clean while the numbering scheme it validates was never used once.
# Same trap as a test suite that skips everything and reports green.
if (Test-Path -LiteralPath $mdPath -PathType Leaf) {
    $mdLen = (Get-Item -LiteralPath $mdPath).Length
    if ($dCount -eq 0 -and $mdLen -gt 200) {
        Add-Finding 'C9' 'warn' 'decisions' "变更记录.md is $mdLen bytes and contains no D-<seq> heading - C9 had nothing to check, so its passing proves nothing (a check with an empty input set has not passed, it has not run)"
    }
}

# C9b - the document and the ledger must cross-check each other, or they are
# two parallel streams of fact that can contradict forever (observer #4,
# O4-20/21): §4 of 变更记录 still claimed 「未发生任何变更」 while §2 of the SAME
# file admitted two contract edits, and §3 carried a real skip (1.3) that the
# ledger - the only place T5 can ever look - had never seen as an event.
if (Test-Path -LiteralPath $mdPath -PathType Leaf) {
    $ccEvents = 0
    $skipEventSteps = @{}
    foreach ($e in $events) {
        if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
        $evn = [string]$e.event
        if ($evn -eq 'contract_change') { $ccEvents++ }
        elseif ($evn -eq 'skip') { $skipEventSteps[[string]$e.step] = $true }
    }
    if ($md -match '未发生任何变更' -and $ccEvents -gt 0) {
        Add-Finding 'C9' 'fault' 'doc-vs-ledger' "变更记录 claims 「未发生任何变更」 while the ledger holds $ccEvents contract_change event(s) - one of the two is fiction; update the document (Hermes) or investigate the events"
    }
    $seenSkip9 = @{}
    foreach ($mr in [regex]::Matches($md, '(?m)^\|[^\r\n]*?(\d+(?:\.\d+)+)[^\r\n]*?(?:skipped?|跳过)[^\r\n]*?\|')) {
        $srow = $mr.Groups[1].Value
        # O5-07: one step can hit several rows/prose cells; the demand is per-step,
        # not per-match - the same warning printing twice teaches people to
        # multiply-ignore it
        if ($skipEventSteps.ContainsKey($srow) -or $seenSkip9.ContainsKey($srow)) { continue }
        $seenSkip9[$srow] = $true
        Add-Finding 'C9' 'warn' "skip-$srow" "变更记录 lists step $srow as skipped, but the ledger has no skip event for it - T5_skip never fired and can never fire for this row: the only recorded skip in project history lived in prose"
    }
}

# ---------------------------------------------------------------- C11 sweep heartbeat
# O5-05: a safety net that quietly stopped running is worse than none - people
# assume it is catching things. The scheduled task is the only writer of the
# heartbeat file; audit never writes, it only asks "was the patroller seen
# recently?". Stale is a warning, not a fault: the machine being powered off is
# a legitimate reason.
$swPath = Join-Path $Root '.harness\sweep-status.json'
if (-not (Test-Path -LiteralPath $swPath -PathType Leaf)) {
    Add-Finding 'C11' 'warn' 'sweep' 'no sweep heartbeat (.harness/sweep-status.json) - the disk-vs-ledger patroller has never reported in; is the scheduled task installed and running?'
}
else {
    try {
        $swj = Get-Content -LiteralPath $swPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $swAt = [datetime]$swj.last_run
        $swAgeMin = [int]((Get-Date).ToUniversalTime() - $swAt.ToUniversalTime()).TotalMinutes
        if ($swAgeMin -gt 45) {
            Add-Finding 'C11' 'warn' 'sweep' "last patrol was ${swAgeMin} minutes ago (heartbeat: covered=$($swj.covered) findings=$($swj.findings) recorded=$($swj.recorded)) - scheduled task may be dead or the machine was off; unrecorded writes go unnoticed until it runs again"
        }
    }
    catch {
        Add-Finding 'C11' 'warn' 'sweep' 'heartbeat file unreadable'
    }
}

# ---------------------------------------------------------------- C12 sealed illegibility
# The hash chain guarantees the record was not edited AFTER signing; it cannot
# tell the human what they signed. seq 847 (4.1 gate) and seq 957 (5.3 gate)
# landed as 60% NUL - a destroyed stdin became an unchallengeable approval, and
# no existing rule noticed because chain math is indifferent to sense. A control
# character inside any recorded reason is a FAULT: the approval it carries has
# no readable basis and must be re-signed through the fixed stdin path.
# REAL schema (learned the hard way on 11-09: the first cut scanned gate.reason
# and shrugged at real data): every recorded human/agent rationale lives in
# data.why. Scan why, plus reason/gate.reason defensively for any writer that
# ever grows a different shape.
$nulSeqs = @()
foreach ($e12 in $events) {
    if ($null -eq $e12.data) { continue }
    $cands = @()
    foreach ($pn in 'why', 'reason') {
        $p = $e12.data.PSObject.Properties[$pn]
        if ($null -ne $p -and $null -ne $p.Value) { $cands += [string]$p.Value }
    }
    $gp = $e12.data.PSObject.Properties['gate']
    if ($null -ne $gp -and $null -ne $gp.Value) {
        foreach ($pn in 'why', 'reason') {
            $rp = $gp.Value.PSObject.Properties[$pn]
            if ($null -ne $rp -and $null -ne $rp.Value) { $cands += [string]$rp.Value }
        }
    }
    foreach ($rsn in $cands) {
        if ($rsn -match "[\u0000-\u0008\u000B\u000C\u000E-\u001F]") {
            $nulSeqs += [pscustomobject]@{ seq = [int]$e12.seq; step = [string]$e12.step; ev = [string]$e12.event }
            break
        }
    }
}
if ($nulSeqs.Count -gt 0) {
    # Remediation outranks accusation: once a LATER legible gate for the same
    # step exists, the decision basis is restored by a subsequent record and
    # the broken one becomes a permanent historical WARNING (same policy as
    # T7/T12). A missing gate anywhere still leaves this a FAULT - the audit
    # must be able to reach exit 0 after the human does the right thing,
    # or the incentive is to stop re-signing at all.
    $unremedied = @()
    foreach ($n12 in $nulSeqs) {
        $covered = $false
        if ($n12.ev -eq 'gate') {
            foreach ($l12 in $events) {
                if ([int]$l12.seq -le $n12.seq) { continue }
                if ([string]$l12.event -ne 'gate') { continue }
                if ([string]$l12.step -ne $n12.step) { continue }
                $lw = $null
                if ($null -ne $l12.data) { $lwp = $l12.data.PSObject.Properties['why']; if ($null -ne $lwp) { $lw = [string]$lwp.Value } }
                if ($null -ne $lw -and $lw -notmatch "[\u0000-\u0008\u000B\u000C\u000E-\u001F]" -and $lw.Trim() -ne '') { $covered = $true; break }
            }
        }
        if (-not $covered) { $unremedied += $n12 }
    }
    $seqList = (($nulSeqs | ForEach-Object { [string]$_.seq }) -join ',')
    $remList = (($unremedied | ForEach-Object { [string]$_.seq }) -join ',')
    if ($unremedied.Count -gt 0) {
        Add-Finding 'C12' 'fault' 'sealed_illegible' ("recorded reasons contain control characters at seq $seqList - unreadable human basis, sealed by the chain. Re-sign each step's gate through sign-gate (console broke CJK twice; use -WhyFile with a UTF-8 file). Steps still WITHOUT a later legible gate: $remList")
    }
    else {
        Add-Finding 'C12' 'warn' 'sealed_illegible' ("control-character reasons at seq $seqList remain in the chain as destroyed signatures - every affected step has since been re-signed legibly; kept as a permanent historical warning")
    }
}

# ---------------------------------------------------------------- C10 harness self-digest
# The harness edits itself. Without a record, "which harness was running during
# this run" is unknowable - precisely what happened when four derive scripts were
# modified mid-observation and the end-to-end stopped being reproducible. Same
# role as a lockfile: the digest of what actually ran must be pinnable to a point
# in the ledger, and pinning it stays a deliberate act.
$harnessSha = ''
$digest = Get-HarnessDigest -ProjectRoot $Root
$hf = @($digest.files)
if ($hf.Count -gt 0) {
    $harnessSha = $digest.sha256
    $sealed = $false
    foreach ($e in $events) {
        if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
        if ([string]$e.PSObject.Properties['event'].Value -ne 'anchor') { continue }
        $dp3 = $e.PSObject.Properties['data']
        if ($null -eq $dp3) { continue }
        $sh3 = $dp3.Value.PSObject.Properties['sha256']
        if ($null -ne $sh3 -and [string]$sh3.Value -eq $harnessSha) { $sealed = $true; break }
    }
    if (-not $sealed) {
        $short = $harnessSha.Substring(0, [Math]::Min(12, $harnessSha.Length))
        # fault, not warn. "Which rules were running" is a precondition for
        # reproducing the run at all, not a style preference. It was a warn for
        # three observation rounds and every round ended with the harness being
        # edited mid-window and the audit still reporting ok=true.
        Add-Finding 'C10' 'fault' 'harness' "harness digest $short has no matching anchor in the ledger - this exact harness has never been recorded, so a run cannot be reproduced from events alone (run scripts\seal-harness.ps1 after reviewing)"
    }
}


# ---------------------------------------------------------------- C7b harness drift
# C7 above walks stage.generates. No stage owns .harness/, so a harness edit was
# invisible to it: four derive scripts were rewritten on 13:37/13:38 by copying
# kit templates into place - a Copy-Item, not a Write tool call - and C7 reported
# "0 drifted" throughout. C10 notices, but only as "this tree matches no sealed
# anchor", which conflates "someone edited it just now" with "it was never
# sealed at all" - and the first question an observer asks is which one happened.
# seal-harness now records every file inside .harness/, so the ordinary
# refresh-only comparison that covers the delivery tree covers the harness too.
foreach ($hfe in @($hf)) {
    $rel = [string]$hfe.id
    if ($rel -eq '' -or $rel -notlike '.harness/*') { continue }
    $abs = [string]$hfe.path
    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }
    if (-not $lastSha.ContainsKey($rel)) { continue }
    $now = Get-FileSha256Hex -Path $abs
    if ($now -eq $lastSha[$rel]) { continue }
    $a = $now.Substring(0, [Math]::Min(12, $now.Length))
    $b = [string]$lastSha[$rel]
    $b = $b.Substring(0, [Math]::Min(12, $b.Length))
    Add-Finding 'C7' 'fault' 'harness' "$rel was replaced after the last seal (now $a, sealed $b) - copying into .harness/ never reaches the hook, so this edit is invisible without this check; review and re-seal"
}

# ---------------------------------------------------------------- local.json position
$localStep = ''
if (Test-Path -LiteralPath $localPath -PathType Leaf) {
    try {
        $lo2 = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $pp = $lo2.PSObject.Properties['current_step']
        if ($null -ne $pp) { $localStep = [string]$pp.Value }
    }
    catch { }
}

# ---------------------------------------------------------------- aggregate: worst wins
$faults = @($findings | Where-Object { $_.level -eq 'fault' })
$warns  = @($findings | Where-Object { $_.level -eq 'warn' })

$result = [pscustomobject]@{
    ok           = ($faults.Count -eq 0)
    position     = 'liveness'
    events       = $events.Count
    chain_ok     = $chainOk
    last_event_at = $lastAt
    local_step   = $localStep
    harness_sha  = $harnessSha
    decisions    = $dCount
    registered   = @($registered | Sort-Object)
    declared     = @($DECLARED)
    emitted      = @($observed.Keys | Sort-Object)
    never_emitted = $neverEmitted
    undeclared   = $undeclared
    no_writer    = $noWriter
    rule_coverage = $ruleCoverage
    dead_rules   = $deadRules
    verify_state = $evState
    findings     = $findings.ToArray()
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
    exit $(if ($faults.Count -gt 0) { 1 } else { 0 })
}

if (-not $Quiet) {
    $projName = if ($null -ne $profile.PSObject.Properties['project']) { $profile.project } else { 'unnamed' }
    Write-Host ''
    Write-Host "harness audit · $projName" -ForegroundColor Cyan
    Write-Host "  liveness - is the harness itself connected? (status.ps1 answers readiness)" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ("  C1 chain         {0}   {1} events, last_at={2}" -f $(if ($chainOk) { 'intact' } else { 'BROKEN' }), $events.Count, $lastAt) `
        -ForegroundColor $(if ($chainOk) { 'DarkGray' } else { 'Red' })
    Write-Host ("  C2 registration  {0}/{1} declared types have a writer path" -f ($DECLARED.Count - $noWriter.Count), $DECLARED.Count) -ForegroundColor DarkGray
    Write-Host ("  C3 emission      {0}/{1} declared types have ever been emitted" -f ($DECLARED.Count - $neverEmitted.Count), $DECLARED.Count) -ForegroundColor DarkGray
    if ($neverEmitted.Count -gt 0) { Write-Host ("                   never:     {0}" -f ($neverEmitted -join ' ')) -ForegroundColor DarkGray }
    if ($undeclared.Count -gt 0) {
        Write-Host ("                   undeclared: {0}" -f (($undeclared | ForEach-Object { "$_($($observed[$_]))" }) -join ' ')) -ForegroundColor Yellow
    }
    $covText = ($RULES.Keys | ForEach-Object { "$_=$($ruleCoverage[$_])" }) -join '  '
    Write-Host ("  C4 rule input    {0}" -f $covText) -ForegroundColor DarkGray
    if ($deadRules.Count -gt 0) { Write-Host ("                   unexercised: {0}  (not a fault by itself - C2 answers whether it can ever fire)" -f ($deadRules -join ' ')) -ForegroundColor DarkGray }
    $evText = @($evState.Keys | Sort-Object | ForEach-Object { "$_=$($evState[$_])" }) -join '  '
    Write-Host ("  C5 evidence      {0}" -f $(if ($evText) { $evText } else { '(no verify events)' })) -ForegroundColor DarkGray
    Write-Host ("  C6 verify-ref    {0} dangling reference(s)" -f $missingRefs.Count) -ForegroundColor DarkGray
    Write-Host ("  C7 drift         {0} drifted, {1} unrecorded" -f $drifted, $unlogged.Count) -ForegroundColor DarkGray
    Write-Host ("  C8 attribution   local_step='{0}'  last {1} events: top='{2}' {3}/{1}" -f $localStep, $recentTotal, $topStep, $topCount) -ForegroundColor DarkGray
    Write-Host ("  C9 decisions     {0} record(s) checked against the ledger" -f $dCount) -ForegroundColor DarkGray
    if ($harnessSha) {
        Write-Host ("  C10 harness      {0}" -f $harnessSha.Substring(0, [Math]::Min(12, $harnessSha.Length))) -ForegroundColor DarkGray
    }

    if ($faults.Count -gt 0) {
        Write-Host ''
        Write-Host "  FAULTS ($($faults.Count)) - worst-status-wins: the audit fails" -ForegroundColor Red
        foreach ($f in $faults) {
            Write-Host ("    x {0}  {1,-14} {2}" -f $f.check, $f.subject, $f.detail) -ForegroundColor Red
        }
    }
    if ($warns.Count -gt 0) {
        Write-Host ''
        Write-Host "  WARNINGS ($($warns.Count))" -ForegroundColor Yellow
        foreach ($f in $warns) {
            Write-Host ("    ! {0}  {1,-14} {2}" -f $f.check, $f.subject, $f.detail) -ForegroundColor Yellow
        }
    }
    if ($faults.Count -eq 0 -and $warns.Count -eq 0) {
        Write-Host ''
        Write-Host '  clean - no structural findings' -ForegroundColor Green
    }
    Write-Host ''
}

exit $(if ($faults.Count -gt 0) { 1 } else { 0 })
