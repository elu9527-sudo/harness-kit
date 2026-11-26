<#
.SYNOPSIS
  Decide whether Hermes needs to run. Pure script, no LLM judgement.

.DESCRIPTION
  Hermes does not maintain every step. It runs only when one of T1-T13 fires.

    T1 deviate         any 'deviate' event
    T2 contract        any 'contract_change' event, or project.json sha drifted from baseline
    T2b_bad_hash       a contract_change whose digests are not real 64-hex values
    T2c_unsigned       contract changes carrying no approved_by
    T3 out_of_scope    a tool_use wrote a path not listed in any stage.generates
    T4 rework          a step was written again after its verify had already passed
    T5 skip            any 'skip' event
    T5b_orphan_step    a decision event attached to a step absent from profile.stages
    T6 blocker_stale   a blocker_open still open and spanning more than 2 steps
    T7 risk_L2         an L2 stage exists with no 'gate' record
    T16 stale_gate     a gate's recorded contract sha != current contract (stale Mandate; re-sign)
    T8 chain_broken    verify-ledger reports a broken chain
    T9 contract_no_handoff
                       a contract/config-producing stage is complete and the ledger
                       holds no decision event for it
    T10 running_ahead  a stage's products are on disk, it has no passing verify, and
                       a LATER stage's products are on disk too
    T11 accepted_modified  a file owned by an ALREADY-VERIFIED stage was written
                       under a different step with no contract_change covering it
    T12 gate_after_the_fact  a gate recorded after the step's first event -
                       ratification, not authorisation
    T13 unrecorded_write  sweep saw the disk move past the ledger and nobody has
                       explained that file since
    T14 green_no_artifact_change  a FAIL->PASS flip where the stage's declared
                       products never moved (no recorded write, every product
                       unchanged at verdict time) - the green came from the
                       paper or the world, not from this stage's code

  Exit codes:
    0  nothing to do
    3  Hermes must run (matches the "human/gate required" convention)
    2  inputs missing

.EXAMPLE
  pwsh -File trigger.ps1 -Root D:\proj
  pwsh -File trigger.ps1 -Root D:\proj -Json
#>
[CmdletBinding()]
param(
    # Same defaulting rule as status.ps1 and audit.ps1. Using (Get-Location) made
    # this script silently report "not needed" with exit 0 whenever it was run
    # from outside the project - a check that answers "up" for an input it never
    # read, which is the exact failure the self-audit layer exists to prevent.
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),
    [switch] $Json,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$projectPath = Join-Path (Join-Path $Root '.harness') 'project.json'
$eventsPath  = Join-Path $Root 'events.jsonl'
$localPath   = Join-Path (Join-Path $Root '.harness') 'local.json'

$triggers = [System.Collections.Generic.List[object]]::new()

function P { param($o,[string]$n) if ($null -eq $o) { return $null }; $p = $o.PSObject.Properties[$n]; if ($null -eq $p) { return $null }; return $p.Value }
$script:seenOrphan = @{}

function Add-Trigger {
    param([string] $Code, [string] $Detail, [string] $Step = '')
    $triggers.Add([pscustomobject]@{ code = $Code; step = $Step; detail = $Detail })
}

# ---------- load ----------
$profile = $null
if (Test-Path -LiteralPath $projectPath -PathType Leaf) {
    try { $profile = Get-Content -LiteralPath $projectPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $profile = $null }
}

$events = Read-EventLog -Path $eventsPath

# Files a contract_change event explicitly covers. Collected in a pass of its own
# rather than inline in the main loop: a contract_change can be recorded after the
# write it authorises, and a single-pass check would then convict the very write
# that was legitimately renegotiated.
$contractChangeFiles = [System.Collections.Generic.HashSet[string]]::new()
foreach ($ePre in $events) {
    if ([string]$ePre.event -ne 'contract_change') { continue }
    $dPre = $ePre.PSObject.Properties['data']
    if ($null -eq $dPre) { continue }
    $fPre = $dPre.Value.PSObject.Properties['file']
    if ($null -ne $fPre -and -not [string]::IsNullOrWhiteSpace([string]$fPre.Value)) {
        [void]$contractChangeFiles.Add((([string]$fPre.Value) -replace '\\', '/'))
    }
}

# ---------- helpers ----------
function Get-StepOrder {
    param([string] $Step)
    # three-part ids ("2.0.1") are used by this project; two-part ids still work
    if ($Step -match '^(\d+)\.(\d+)\.(\d+)$') { return ([int]$Matches[1] * 1000000 + [int]$Matches[2] * 1000 + [int]$Matches[3]) }
    if ($Step -match '^(\d+)\.(\d+)$')       { return ([int]$Matches[1] * 1000000 + [int]$Matches[2] * 1000) }
    return 999999999
}

$allGenerates = @()
$stageIds = @()
$generatesByStep = @{}
if ($null -ne $profile) {
    $sp = $profile.PSObject.Properties['stages']
    if ($null -ne $sp) {
        foreach ($s in @($sp.Value)) {
            $sid0 = [string]$s.id
            $stageIds += $sid0
            $gp = $s.PSObject.Properties['generates']
            if ($null -ne $gp) {
                $gen0 = @($gp.Value | ForEach-Object { ([string]$_ -replace '\\', '/') })
                $allGenerates += $gen0
                $generatesByStep[$sid0] = $gen0
            }
        }
    }
}
$allGenerates = @($allGenerates | ForEach-Object { ($_ -replace '\\', '/') })

# ---------- T1 / T2 / T5 : direct decision events ----------
$verifyPassed    = @{}
$t2Agg           = @{}
$seenOutOfScope  = @{}
$seenRework      = @{}
$blockerOpen     = @{}
$gateSeen        = @{}
$gateAt          = @{}
$gateContract    = @{}   # T16: step -> contract sha recorded at gate time (Mandate revalidation)
$earliestAt      = @{}
$stepsWithEvents = @{}
$maxStep         = 0
$unsignedCount   = 0
$unsignedStep    = ''
$unsignedExample = ''
# T14 state: each step's newest verify verdict, and a counter of recorded writes
# to that step's declared products since that verify. A FAIL->PASS flip with
# zero writes and all-unchanged products means the green came from something
# OTHER than this stage's code moving - usually the paper (contract/anchor/
# exemption changed elsewhere), which is exactly how 3.1.3 passed on 11-07.
$lastVerdict  = @{}
$writesSince  = @{}

foreach ($e in $events) {
    if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
    $ev  = [string]$e.event
    $stp = [string]$e.step
    $order = Get-StepOrder -Step $stp
    if ($order -lt 999999 -and $order -gt $maxStep) { $maxStep = $order }
    $dp = $e.PSObject.Properties['data']
    $d  = if ($null -ne $dp) { $dp.Value } else { $null }
    # earliest event for the step, any kind - used to tell a front gate from
    # a rubber stamp applied after the fact
    if ($stp -ne '' -and -not $earliestAt.ContainsKey($stp)) { $earliestAt[$stp] = $e.at }
    # A seal record is a harness file being pinned, not progress on a stage.
    # Counting it as "this stage produced events" made T7 announce that 3.1.1
    # had "ran" seconds after a seal, when nothing had started yet - the same
    # "something was recorded != this thing happened" confusion that T9 had to
    # be narrowed for. Sealing must be inert with respect to stage state.
    $isSealRecord = ($ev -eq 'tool_use' -and $null -ne $d -and $null -ne $d.PSObject.Properties['tool'] -and [string]$d.tool -eq 'seal')
    if (-not $isSealRecord -and $ev -eq 'anchor' -and $null -ne $d) {
        $nmS = $d.PSObject.Properties['name']
        if ($null -ne $nmS -and [string]$nmS.Value -eq 'harness') { $isSealRecord = $true }
    }
    # "This stage ran" means it wrote one of ITS OWN declared products.
    #   - A shell command is not evidence: after finish-step advances current_step
    #     the agent is still running acceptance commands for the step it just
    #     closed, and those get stamped with the NEW step.
    #   - Nor is any file: those same closing minutes also edit the PREVIOUS
    #     step's files (init_db.py fixups, a line appended to 变更记录). Counting
    #     any file made T7 announce that 3.1.2 had "run" while price_watch/pool/
    #     did not exist at all, which is the exact confusion between "something
    #     was touched" and "this stage started" that this rule keeps hitting.
    # Statement-form assignment, NOT `$x = if (...) {...} else { @() }`: an if
    # EXPRESSION emits its value through the output stream, where an empty array
    # unrolls to nothing and the variable becomes $null. Under Set-StrictMode +
    # ErrorAction Stop the next `.Count` then kills the whole script. That is how
    # trigger died on 2026-11-09 08:16 for 103 minutes across the entire 4.1-5.3
    # window (observer #6, 14 repros): the else-branch was the first thing the
    # real ledger ever walked. Keep this shape everywhere in the kit.
    $ownGen = @()
    if ($generatesByStep.ContainsKey($stp)) { $ownGen = @($generatesByStep[$stp]) }
    $fileRel = ''
    if ($ev -eq 'tool_use' -and $null -ne $d) {
        $fProp = $d.PSObject.Properties['file']
        if ($null -ne $fProp -and [string]$fProp.Value -ne '') { $fileRel = ([string]$fProp.Value -replace '\\', '/') }
    }
    $isFileWork = ($fileRel -ne '' -and $ownGen -contains $fileRel)
    if ($stp -ne '' -and -not $isSealRecord -and $isFileWork) { $stepsWithEvents[$stp] = $true }

    switch ($ev) {
        'deviate' {
            $what = if ($null -ne $d -and $null -ne $d.PSObject.Properties['what']) { [string]$d.what } else { '(no detail)' }
            $alt  = if ($null -ne $d -and $null -ne $d.PSObject.Properties['alternatives']) { (@($d.alternatives) -join ' / ') } else { '' }
            Add-Trigger -Code 'T1_deviate' -Step $stp -Detail ("$what" + $(if ($alt) { "  (alternatives: $alt)" } else { '' }))
        }
        'skip' {
            $why = if ($null -ne $d -and $null -ne $d.PSObject.Properties['why']) { [string]$d.why } else { '(no reason)' }
            Add-Trigger -Code 'T5_skip' -Step $stp -Detail $why
        }
        'contract_change' {
            $file = if ($null -ne $d -and $null -ne $d.PSObject.Properties['file']) { [string]$d.file } else { 'unknown' }
            $why  = if ($null -ne $d -and $null -ne $d.PSObject.Properties['why'])  { [string]$d.why }  else { '' }
            # Aggregated per step after the loop. Two legitimate changes to the
            # same contract on the same step are one fact ("this step renegotiated
            # twice"), not two alerts - the old per-event emission made a correct
            # history look like a chronic problem and diluted the real ones.
            if (-not $t2Agg.ContainsKey($stp)) { $t2Agg[$stp] = [System.Collections.Generic.List[string]]::new() }
            $t2Agg[$stp].Add(($file + $(if ($why) { " - $why" } else { '' })))
            # T2b: before/after must be real 64-hex digests, not placeholders
            $bs = if ($null -ne $d -and $null -ne $d.PSObject.Properties['before_sha256']) { [string]$d.before_sha256 } else { '' }
            $as = if ($null -ne $d -and $null -ne $d.PSObject.Properties['after_sha256'])  { [string]$d.after_sha256 }  else { '' }
            if (($bs -notmatch '^[0-9a-f]{64}$') -or ($as -notmatch '^[0-9a-f]{64}$')) {
                Add-Trigger -Code 'T2b_bad_hash' -Step $stp -Detail "contract_change digests are not 64-hex (before='$bs' after='$as') -> CANNOT ESTABLISH"
            }
            # T2c: the signature belongs ON the change, not on a separate ticket.
            # strong_migrations gates unsafe migrations this way - the override
            # (`safety_assured`) sits at the call site, so it shows up in review and
            # one approval cannot silently cover every later change. A global
            # "was anything ever gated?" check is exactly the failure this avoids.
            $approved = if ($null -ne $d -and $null -ne $d.PSObject.Properties['approved_by']) { [string]$d.approved_by } else { '' }
            if ($approved -notin @('human', 'owner')) {
                $unsignedCount++
                $unsignedStep = $stp
                if (-not $unsignedExample) { $unsignedExample = $file }
            }
        }
        'verify' {
            # A passing verify is this step's boundary. step_end used to mark it,
            # but nothing ever wrote step_end, so T3/T4 - which hung off it - could
            # never fire. The boundary is now the event that actually exists.
            if ($null -ne $d) {
                $ex = if ($null -ne $d.PSObject.Properties['exit']) { [int]$d.exit } else { 1 }
                $tr = ($null -ne $d.PSObject.Properties['trivial']) -and [bool]$d.trivial
                if ($ex -eq 0 -and -not $tr) { $verifyPassed[$stp] = $true }

                # T14: FAIL -> PASS with the stage's own artifacts untouched.
                # Requires the products field (added 2026-11-07): records without
                # it are exempt by construction - the ledger cannot retroactively
                # prove what a verify did not snapshot.
                $prevV = if ($lastVerdict.ContainsKey($stp)) { $lastVerdict[$stp] } else { $null }
                if ($ex -eq 0 -and -not $tr -and $null -ne $prevV -and [int]$prevV.exit -ne 0) {
                    $ppP = $d.PSObject.Properties['products']
                    # statement form: else { @() } through an if-expression unrolls
                    # to $null and .Count under StrictMode killed trigger on 11-09
                    $prodsT = @()
                    if ($null -ne $ppP) { $prodsT = @($ppP.Value) }
                    $wnT = if ($writesSince.ContainsKey($stp)) { [int]$writesSince[$stp] } else { 0 }
                    # classify product movement; "exam paper" = the file that
                    # GRADES this step (naming convention or the verify command
                    # runs it). Observer #6 semantic hole: when the grader is a
                    # product, "the paper moved" masquerades as "the code moved"
                    # and T14 falls silent forever for that step class. Now the
                    # paper-only case gets its own code instead of amnesty.
                    $cmdAll = ''
                    $cpT = $d.PSObject.Properties['command']
                    if ($null -ne $cpT) { $cmdAll = [string]$cpT.Value }
                    $ckP = $d.PSObject.Properties['checks']
                    if ($null -ne $ckP) { $cmdAll += ' ' + ((@(foreach ($ck in @($ckP.Value)) { [string]$ck.cmd })) -join ' ') }
                    $moved = @($prodsT | Where-Object { [string]$_.state -ne 'unchanged' })
                    $examOnly = ($moved.Count -gt 0)
                    $movedList = ''
                    foreach ($mv in $moved) {
                        $bn = Split-Path ([string]$mv.file) -Leaf
                        $isExam = ($bn -match '^(check|test_|verify_|conftest)' -or $bn -match 'selftest|_check' -or ($cmdAll -ne '' -and $cmdAll.Contains($bn)))
                        if (-not $isExam) { $examOnly = $false }
                        $movedList += "$($mv.file)($($mv.state)) "
                    }
                    $allUnchanged = ($prodsT.Count -gt 0) -and ($moved.Count -eq 0)
                    if ($allUnchanged -and $wnT -eq 0) {
                        Add-Trigger -Code 'T14_green_no_artifact_change' -Step $stp -Detail (
                            'verify flipped FAIL(seq {0})->PASS(seq {1}) with no recorded write to this stage''s declared products and every product unchanged at verdict time - the green came from the world or the paper moving, not from this stage''s code' -f [int]$prevV.seq, [int]$e.seq)
                    }
                    elseif ($examOnly) {
                        # no $wnT guard here on purpose: the exam change IS usually
                        # recorded. T14b accuses nothing about logging - it says the
                        # green rests entirely on the grader having moved, business
                        # artifacts untouched, which only a renegotiated contract
                        # (+ human signature) may authorize.
                        Add-Trigger -Code 'T14b_green_exam_only_change' -Step $stp -Detail (
                            'verify flipped FAIL(seq {0})->PASS(seq {1}) and the ONLY declared product that moved is the grader itself ({2}) - no business artifact changed. This green grades what the paper now allows; it is legal only with a contract_change + human signature (loosening rule), never by comment self-authorization' -f [int]$prevV.seq, [int]$e.seq, $movedList.Trim())
                    }
                }
                # T15: the verdict moved the world. 875 was a re-verify that ran
                # init_db.py --migrate and wrote data/price_watch.db while the
                # ledger still said "products unchanged" - universe_changed is
                # that blind spot closed; the ledger now carries the diff.
                $upP = $d.PSObject.Properties['universe_changed']
                if ($null -ne $upP) {
                    $uList = @($upP.Value)
                    if ($uList.Count -gt 0) {
                        $uTop = (($uList | Select-Object -First 5 | ForEach-Object { "$($_.file)($($_.state))" }) -join ', ')
                        Add-Trigger -Code 'T15_universe_moved' -Step $stp -Detail (
                            'this verify changed {0} UNDECLARED file(s) during the run: {1} - the verdict is not just grading code, it moved the world (db migrations, caches, generated state). Declare it in generates, make it hermetic, or record why the world-change is intended' -f $uList.Count, $uTop)
                    }
                }
                $lastVerdict[$stp] = @{ exit = $ex; seq = [int]$e.seq }
                $writesSince[$stp] = 0
            }
        }
        'tool_use' {
            # T3 and T4 ask about the AGENT's behaviour - scope creep and rework.
            # tool_use now also carries the harness describing itself: one record
            # per file from seal-harness, plus maintenance notes. Those are not
            # agent actions, and by the end of one session 252 of 371 records were
            # them. A record without observed_by predates the field, and the only
            # writer that existed then was the hook, so it is treated as hook.
            $observedBy = 'hook'
            if ($null -ne $d -and $null -ne $d.PSObject.Properties['observed_by']) {
                $observedBy = [string]$d.observed_by
            }
            elseif ($null -ne $d -and $null -ne $d.PSObject.Properties['tool']) {
                # Records written before observed_by existed still carry the tool
                # names the harness uses for its own notes. Without this the 252
                # historical seal records are read as agent writes and T3 stays
                # at ~370 no matter what the agent did.
                $selfTools = @('seal', 'maintenance', 'manual')
                if ([string]$d.tool -in $selfTools) { $observedBy = 'script' }
            }
            $f = if ($null -ne $d -and $null -ne $d.PSObject.Properties['file']) { [string]$d.file } else { '' }
            # O5-01 (observer #5): T11/T4 used to sit BEHIND the hook-only filter,
            # so every hermes/human/script record was invisible to them. Hard
            # evidence: seq 740 (actor=hermes, observed_by=script) modified
            # scripts/check_interface_impl.py - the sole generates AND the verify
            # body of step 3.1.3 - AFTER 3.1.3 verified (734/735) and closed
            # (step_advance 736), and T11 stayed silent all session. "Whose write"
            # changes severity; it does not change the fact that a graded artifact
            # moved after grading. These two rules therefore run for EVERY writer.
            # Pure registration/archive rows are exempt - they declare a state,
            # they are not an act of modification:
            $tool251 = ''
            if ($null -ne $d -and $null -ne $d.PSObject.Properties['tool']) { $tool251 = [string]$d.tool }
            if ($tool251 -notin @('seal', 'maintenance', 'baseline')) {
                # T14 bookkeeping: a recorded write to a stage's declared product
                # means its code actually moved. The 3.1.3 pattern (red 22 -> the
                # contract was reworded -> green, implementation never touched) is
                # only provable against this counter - hermes' registrations count
                # too (tool=manual), only archive rows are inert.
                if ($f -ne '') {
                    $pfW = ($f -replace '\\', '/')
                    foreach ($kw in @($generatesByStep.Keys)) {
                        if (@($generatesByStep[$kw]) -contains $pfW) {
                            $writesSince[$kw] = 1 + $(if ($writesSince.ContainsKey($kw)) { [int]$writesSince[$kw] } else { 0 })
                        }
                    }
                }
                # T4: touching a step after its verify already passed is rework
                # Two guards, both added after observer #4 found 2 of 13 hits were noise:
                #   - a record with no file is a shell command, not a write. L131
                #     already says "a shell command is not evidence" for T7; T4 has
                #     to agree, or running an acceptance command counts as rework.
                #   - the file has to belong to the step that is reworking it -
                #     otherwise it is T11's territory (or a mislabelled record).
                if ($f -ne '' -and $verifyPassed.ContainsKey($stp)) {
                    $pf4 = ($f -replace '\\', '/')
                    $ownsThis = ($generatesByStep.ContainsKey($stp)) -and ($generatesByStep[$stp] -contains $pf4)
                    if ($ownsThis) {
                        $key = "t4:$stp"
                        if (-not $seenRework.ContainsKey($key)) {
                            $seenRework[$key] = $true
                            Add-Trigger -Code 'T4_rework' -Step $stp -Detail "written again after its verify had already passed: $f"
                        }
                    }
                }
                # T11: modifying an artifact owned by a DIFFERENT step whose verify
                # already passed. T3 cannot see this: its whitelist is the UNION of
                # every stage's generates, so any owned file is always "in scope".
                # Covers every writer that recorded the write; a write with NO record
                # is invisible to all rules - that is hook coverage (C7/sweep is the
                # only detector for it), not rule logic. contract_change exempts:
                # renegotiation is the legitimate path for moving accepted output.
                if ($f -ne '') {
                    $pf11 = ($f -replace '\\', '/')
                    $owner11 = ''
                    foreach ($k11 in @($generatesByStep.Keys)) {
                        if (@($generatesByStep[$k11]) -contains $pf11) { $owner11 = [string]$k11; break }
                    }
                    if ($owner11 -ne '' -and $owner11 -ne [string]$stp -and $verifyPassed.ContainsKey($owner11)) {
                        if (-not $contractChangeFiles.Contains($pf11)) {
                            $key11 = "t11:$pf11"
                            if (-not $seenOutOfScope.ContainsKey($key11)) {
                                $seenOutOfScope[$key11] = $true
                                Add-Trigger -Code 'T11_accepted_modified' -Step $stp -Detail "$pf11 belongs to $owner11 (already verified), modified under step $stp with no contract_change"
                            }
                        }
                    }
                }
            }

            # T3 asks about the AGENT's behaviour specifically - scope creep.
            # Harness self-description (seal rows, step=harness) and human/hermes
            # registrations are in-scope-by-construction elsewhere; the 252-seal-rows
            # noise that once buried T3 hits is handled by path whitelist below too.
            if ($observedBy -ne 'hook') { break }

            # T3: a write outside every stage.generates
            if ($f -ne '') {
                $p = ($f -replace '\\', '/')
                if ($allGenerates.Count -gt 0 -and $allGenerates -notcontains $p) {
                    # ledger and diff bookkeeping are ours, not the agent's scope creep.
                    # .harness/ is the harness maintaining itself: no stage owns it, and
                    # seal-harness records those files deliberately. Reporting them as
                    # scope creep buried the real T3 hits under 14 lines of noise.
                    if ($p -notmatch '^(events\.jsonl|docs/_snap/|docs/_diff/|docs/变更记录\.md|\.harness/)') {
                        $key = "t3:$p"
                        if (-not $seenOutOfScope.ContainsKey($key)) {
                            $seenOutOfScope[$key] = $true
                            Add-Trigger -Code 'T3_out_of_scope' -Step $stp -Detail $p
                        }
                    }
                }
            }

        }
        'blocker_open' {
            if ($null -ne $d) { $blockerOpen[[string]$d.id] = $order }
        }
        'blocker_close' {
            if ($null -ne $d) { $blockerOpen.Remove([string]$d.id) }
        }
        'gate' {
            if ($null -ne $d) {
                $lvl = if ($null -ne $d.PSObject.Properties['level']) { [string]$d.level } else { 'L2' }
                # a gate clears only its own step; a global level key would let one
                # approval silently satisfy every later L2 stage
                $gateSeen[$stp] = $true
                $gateSeen["level:$lvl"] = $true
                if (-not $gateAt.ContainsKey($stp)) { $gateAt[$stp] = $e.at }
                # T16 (Mandate revalidation, borrowed from Super-agent): a gate is an
                # authorization scoped to the contract version it was signed under.
                # Legacy gates without contract_sha are exempt by construction.
                $cs = $d.PSObject.Properties['contract_sha']
                if ($null -ne $cs -and [string]$cs.Value -match '^[0-9a-f]{64}$') { $gateContract[$stp] = [string]$cs.Value }
            }
        }
    }

    # T5b: a decision attached to a step that does not exist in profile.stages
    # 'harness' is the deliberate non-stage used by seal records; treating it as
    # an orphan would make sealing report itself as a defect every time.
    #
    # 2026-11-17: install-time anchors carry their own pseudo-step on purpose
    # (genesis / policy / contract). They are the system talking about itself, not
    # a decision attached to a business step - flagging them meant every fresh
    # project opened with three "orphan" cards produced by its own installation.
    # The list stays explicit and short: a genuinely misspelled business step must
    # still be caught, so nothing here is a wildcard.
    $systemSteps = @('harness', 'genesis', 'policy', 'contract')
    if ([string](P $e 'kind') -eq 'decision' -and $stp -ne '' -and $systemSteps -notcontains $stp -and $stageIds.Count -gt 0 -and $stageIds -notcontains $stp) {
        $key = "orphan:$stp"
        if (-not $script:seenOrphan.ContainsKey($key)) {
            $script:seenOrphan[$key] = $true
            Add-Trigger -Code 'T5b_orphan_step' -Step $stp -Detail "decision '$ev' attached to step '$stp' which is not in profile.stages"
        }
    }
}

# ---------- T2 : contract changes, one line per step ----------
foreach ($k in ($t2Agg.Keys | Sort-Object)) {
    $items = @($t2Agg[$k])
    $uniq  = @($items | Select-Object -Unique)
    $detail = if ($items.Count -eq 1) { $uniq[0] + ' changed' }
              else { "$($items.Count) change(s): " + ($uniq -join '; ') }
    Add-Trigger -Code 'T2_contract' -Step $k -Detail $detail
}

# ---------- T6 : blocker open across more than 2 steps ----------
foreach ($id in $blockerOpen.Keys) {
    $spanSteps = [math]::Round(($maxStep - $blockerOpen[$id]) / 1000.0, 0)
    if ($spanSteps -gt 2) {
        Add-Trigger -Code 'T6_blocker' -Detail "blocker $id open for ~$spanSteps steps"
    }
    elseif (($maxStep - $blockerOpen[$id]) -gt 2000) {
        Add-Trigger -Code 'T6_blocker' -Detail "blocker $id still open"
    }
}

# ---------- T7 : L2 stage without gate ----------
# A stage that PASSED a verify has demonstrably run, even if its file writes are
# filed under a neighbouring step. 2.0.2's three contracts were written while
# current_step still said 2.0.1, so the own-products test alone would silence a
# genuine "L2 ran without a gate". A passing verify is the harder fact: it names
# the stage itself and a command that really executed.
foreach ($vpK in $verifyPassed.Keys) {
    if ($vpK -ne '') { $stepsWithEvents[$vpK] = $true }
}
# Two cases, and the second one is the one that matters:
#   1. an L2 stage that already produced events and has no gate - the backstop;
#   2. the stage status.ps1 is currently pointing at is L2 and has no gate - the
#      front gate. Without case 2 the rule can only speak after the irreversible
#      thing has been done, which is exactly backwards for a risk gate. 2.0.2 was
#      L2 and never gated; T7 reported it from 12:15 onward and nobody signed,
#      because a warning about a finished step is a postmortem, not a decision.
$curStageId = ''
if (Test-Path -LiteralPath $localPath -PathType Leaf) {
    try {
        $l7 = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $c7p = $l7.PSObject.Properties['current_step']
        if ($null -ne $c7p) { $curStageId = [string]$c7p.Value }
    }
    catch { }
}
if ($null -ne $profile) {
    $sp = $profile.PSObject.Properties['stages']
    if ($null -ne $sp) {
        foreach ($s in @($sp.Value)) {
            $rp = $s.PSObject.Properties['risk']
            $sid = [string]$s.id
            if ($null -ne $rp -and [string]$rp.Value -eq 'L2') {
                if ($stepsWithEvents.ContainsKey($sid) -and -not $gateSeen.ContainsKey($sid)) {
                    Add-Trigger -Code 'T7_risk_L2' -Step $sid -Detail "stage $sid is L2, ran, and has no gate record"
                }
                elseif ($sid -eq $curStageId -and -not $gateSeen.ContainsKey($sid)) {
                    Add-Trigger -Code 'T7_risk_L2' -Step $sid -Detail "stage $sid is L2 and is the stage status.ps1 is pointing at, but no gate is on record - sign it BEFORE the step starts, not after"
                }
            }
        }
    }
}

# ---------- T16 : a gate whose contract version no longer matches (stale Mandate) ----------
# Borrowed from Super-agent's revalidation-before-resume: an authorization accepted
# under an old policy must be re-checked against today's policy before it is relied
# on again. Here a gate records the contract sha it was signed under; if the contract
# has since changed, the gate no longer covers the current agreement and a human must
# re-sign. This replaces manual tracking of "which gates went stale". Legacy gates
# (no contract_sha) are exempt by construction, so history does not retro-alarm.
if ($gateContract.Count -gt 0 -and (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    $curSha16 = Get-FileSha256Hex -Path $projectPath
    foreach ($gk in @($gateContract.Keys)) {
        if ($gateContract[$gk] -ne $curSha16) {
            Add-Trigger -Code 'T16_stale_gate' -Step $gk -Detail "gate signed under contract $($gateContract[$gk].Substring(0,12)) but current contract is $($curSha16.Substring(0,12)) - the authorization predates the current agreement; re-sign before relying on it"
        }
    }
}

# ---------- T12 : a gate recorded only after its step had already started ----------
# T7 asks whether a gate EXISTS; it never asks when it landed. A signature after
# the step's first event ratifies rather than authorises - and because T7 keys on
# existence, that late signature also silences the warning that was right all
# along. Observed 2026-11-07: 3.1.3's artifact was written 07:41:16Z, the gate
# arrived 07:49:17Z carrying why="y y", and T7 went quiet for a two-character
# approval issued after the irreversible part was already done.
foreach ($g12 in @($gateAt.Keys | Sort-Object)) {
    if (-not $earliestAt.ContainsKey($g12)) { continue }
    $gAt12 = [datetime]$gateAt[$g12]
    $eAt12 = [datetime]$earliestAt[$g12]
    if ($gAt12 -gt $eAt12) {
        Add-Trigger -Code 'T12_gate_after_the_fact' -Step $g12 -Detail (
            'gate recorded {0} but first event of this step is {1} - it ratified a step that had already run; a front gate must precede the work' -f
            $gAt12.ToString('HH:mm:ss'), $eAt12.ToString('HH:mm:ss'))
    }
}

# ---------- T13 : a sweep observation nobody has explained yet ----------
# sweep records WHAT moved (machine fact); record-edit records WHO and WHY
# (human fact, appended after). For a file, if the newest ledger event touching
# it is the observation rather than a later registration, the change is still
# unexplained - and unlike C7's transient disagreement, this demand stays in
# the trigger list until somebody actually answers it.
$lastUW13 = @{}
$lastTU13 = @{}
foreach ($e13 in $events) {
    if ($null -ne $e13.PSObject.Properties['__parse_error']) { continue }
    $ev13 = [string]$e13.event
    if ($ev13 -ne 'unrecorded_write' -and $ev13 -ne 'tool_use') { continue }
    $d13 = $e13.PSObject.Properties['data']
    if ($null -eq $d13) { continue }
    $f13p = $d13.Value.PSObject.Properties['file']
    if ($null -eq $f13p) { continue }
    $f13 = ([string]$f13p.Value) -replace '\\', '/'
    if ($ev13 -eq 'unrecorded_write') {
        $lastUW13[$f13] = @{ seq = [int]$e13.seq; step = [string]$e13.step }
    }
    else {
        $lastTU13[$f13] = [int]$e13.seq
    }
}
foreach ($f13 in @($lastUW13.Keys | Sort-Object)) {
    if (-not $lastTU13.ContainsKey($f13) -or $lastUW13[$f13].seq -gt $lastTU13[$f13]) {
        Add-Trigger -Code 'T13_unrecorded_write' -Step $lastUW13[$f13].step -Detail "$f13 moved on disk without a record; sweep observed it and nobody has explained it yet - run record-edit.ps1 -File $f13"
    }
}

# ---------- T8 : chain integrity (only when a log exists) ----------
# A missing events.jsonl means "nothing has run yet", not "the chain is broken".
if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) {
    $script:noEventsYet = $true
}
else {
    $ledger = & (Join-Path $PSScriptRoot 'verify-ledger.ps1') -Path $eventsPath -Json -Quiet
    try { $ledgerObj = $ledger | ConvertFrom-Json } catch { $ledgerObj = $null }
    if ($null -eq $ledgerObj -or -not $ledgerObj.ok) {
        $detail = if ($null -ne $ledgerObj -and $null -ne $ledgerObj.issues -and @($ledgerObj.issues).Count -gt 0) {
            (@($ledgerObj.issues)[0].kind + ': ' + @($ledgerObj.issues)[0].detail)
        } else { 'ledger unreadable or broken' }
        Add-Trigger -Code 'T8_chain_broken' -Detail $detail
    }
}

# ---------- T2b : project.json sha drifted (baseline in local.json) ----------
# Only skip when a contract_change event actually covers project.json. The first
# version skipped whenever ANY contract_change existed anywhere (`$t2Agg.Count -gt 0`),
# and this ledger already had four, so the baseline comparison had never run once.
# A guard whose condition is "some unrelated thing happened" is a rule that is
# structurally dead: it reports nothing and its silence looks like health.
# 11-10 (sign-contract hole): the old check scanned $t2Agg's display strings
# ("$file - $why") with a substring regex, so a contract_change on ANY file
# whose free-text why merely mentioned "project.json" claimed coverage and
# silently killed this drift check. sign-contract makes non-project.json
# contract_change events routine (AGENTS.md, architecture docs), and their why
# texts are exactly the prose that names project.json - a latent suppression
# channel going live. Coverage is a fact about the file FIELD: test it exactly,
# against the normalized set collected at the top of this script.
$coversProjectJson = $contractChangeFiles.Contains('.harness/project.json')
if (-not $coversProjectJson -and (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    $projSha = Get-FileSha256Hex -Path $projectPath
    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        try {
            $local = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $bp = $local.PSObject.Properties['project_sha256']
            if ($null -ne $bp) {
                $baseline = [string]$bp.Value
                if ($baseline -ne '' -and $baseline -ne $projSha) {
                    Add-Trigger -Code 'T2_contract' -Detail 'project.json sha256 differs from baseline in local.json'
                }
            }
        }
        catch { }
    }
}

# ---------- T2c : contract changes nobody signed ----------
# Reported as a count, not one line per event. An unsigned change from months ago
# cannot be retro-fixed - the hash chain forbids editing it - so re-reporting it
# every run keeps the rule permanently red and trains everyone to ignore it. One
# line with the total still tells the truth, and it shrinks as new changes get
# signed. Per-change signing still matters: the rule fires the moment a NEW
# unsigned change appears.
if ($unsignedCount -gt 0) {
    Add-Trigger -Code 'T2c_unsigned_contract' -Step $unsignedStep -Detail "$unsignedCount contract change(s) on record carry no approved_by (e.g. '$unsignedExample') - a gate recorded elsewhere does not sign a change"
}

# ---------- T9 : contract layer closed with no handoff on record ----------
# The coach decides whether a step needs a documentation handoff, and that
# decision cannot be audited - it is one sentence in a chat. But the profile CAN
# say which stages produce files that other people must code against (contracts/,
# config/). When such a stage is done and the ledger holds no decision event for
# it, "the contract landed" is only an assertion. This is the hard half of the
# handoff rule; the coach's judgement is the soft half.
$contractStages = @()
if ($null -ne $profile) {
    $sp9 = $profile.PSObject.Properties['stages']
    if ($null -ne $sp9) {
        foreach ($s in @($sp9.Value)) {
            $gp9 = $s.PSObject.Properties['generates']
            if ($null -eq $gp9) { continue }
            foreach ($g in @($gp9.Value)) {
                if (([string]$g -replace '\\', '/') -match '^(contracts|config)/') {
                    $contractStages += [string]$s.id
                    break
                }
            }
        }
    }
}
$decisionSteps = @{}
foreach ($e in $events) {
    if ($null -ne $e.PSObject.Properties['__parse_error']) { continue }
    # Only events that actually acknowledge an agreement about THIS stage count.
    # Three shapes qualify:
    #   contract_change / deviate  - the agreement moved
    #   anchor                     - the agreement was checked and stands
    # The system-level anchors are excluded: `profile_baseline` and `harness`
    # record housekeeping about the harness itself, and accepting them once let a
    # stage with no handoff at all pass the check. "Something was recorded" is not
    # "this was recorded".
    $ev9 = [string](P $e 'event')
    $counts = $false
    if ($ev9 -eq 'contract_change' -or $ev9 -eq 'deviate') {
        $counts = $true
    }
    elseif ($ev9 -eq 'anchor') {
        $nm = ''
        $dp9 = $e.PSObject.Properties['data']
        if ($null -ne $dp9) {
            $np9 = $dp9.Value.PSObject.Properties['name']
            if ($null -ne $np9) { $nm = [string]$np9.Value }
        }
        if ($nm -ne '' -and $nm -notin @('profile_baseline', 'harness')) { $counts = $true }
    }
    if (-not $counts) { continue }
    $st9 = [string](P $e 'step')
    if ($st9 -ne '') { $decisionSteps[$st9] = $true }
}
foreach ($cid in $contractStages) {
    if ($decisionSteps.ContainsKey($cid)) { continue }
    $allThere = $true
    foreach ($s in @($profile.stages)) {
        if ([string]$s.id -ne $cid) { continue }
        $gp10 = $s.PSObject.Properties['generates']
        if ($null -ne $gp10) {
            foreach ($g in @($gp10.Value)) {
                $abs = if ([System.IO.Path]::IsPathRooted([string]$g)) { [string]$g } else { Join-Path $Root ([string]$g) }
                if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { $allThere = $false }
            }
        }
        break
    }
    if ($allThere) {
        Add-Trigger -Code 'T9_contract_no_handoff' -Step $cid -Detail 'this stage produces the files others must code against, those files exist, and the ledger holds no decision event for it - the agreement landed without a handoff'
    }
}

# ---------- T10 : a later stage ran while an earlier one was never verified ----------
# 2.0.4's collector_js.py landed at 13:36, main.py (2.0.5) at 13:47, and the
# ledger held ZERO verify events for 2.0.4 the whole time. Nothing fired:
#   - T4 needs a PASSED verify to call something rework, so it cannot see a stage
#     that never passed at all;
#   - T3 only catches paths no stage owns, and both files are owned;
#   - status only compares against current_step, which finish-step is the only
#     thing that moves - so the chain sat frozen at 2.0.4 while work moved on.
# The rule reads the disk rather than the event stream, because the event stream
# is exactly what was wrong: everything 2.0.5 did was filed under step 2.0.4.
# Scope is local: only stages at or after current_step. Earlier stages predate
# the evidence regime and re-reporting them forever is how a check gets ignored.
$curStep = ''
if (Test-Path -LiteralPath $localPath -PathType Leaf) {
    try {
        $localObj = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $csp = $localObj.PSObject.Properties['current_step']
        if ($null -ne $csp) { $curStep = [string]$csp.Value }
    }
    catch { }
}
$curOrder = Get-StepOrder -Step $curStep

$stageInfo = [System.Collections.Generic.List[object]]::new()
if ($null -ne $profile) {
    $tsp = $profile.PSObject.Properties['stages']
    if ($null -ne $tsp) {
        foreach ($s in @($tsp.Value)) {
            $gen = @()
            $gpT = $s.PSObject.Properties['generates']
            if ($null -ne $gpT) { $gen = @($gpT.Value | ForEach-Object { [string]($_ -replace '\\', '/') }) }
            $stageInfo.Add([pscustomobject]@{
                id    = [string]$s.id
                order = (Get-StepOrder -Step ([string]$s.id))
                gen   = $gen
            })
        }
    }
}

function Test-StageProductsOnDisk {
    param([object] $Stage)
    $n = 0
    foreach ($g in @($Stage.gen)) {
        if ($g -eq '') { continue }
        $n++
        $abs = if ([System.IO.Path]::IsPathRooted($g)) { $g } else { Join-Path $Root ($g -replace '/', '\') }
        if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { return $false }
    }
    return ($n -gt 0)
}

if ($stageInfo.Count -gt 0 -and $curOrder -lt 999999999) {
    $sortedStages = @($stageInfo | Sort-Object order)
    for ($i = 0; $i -lt $sortedStages.Count; $i++) {
        $s = $sortedStages[$i]
        if ($s.order -lt $curOrder) { continue }
        if ($s.gen.Count -eq 0) { continue }
        if ($verifyPassed.ContainsKey($s.id)) { continue }
        if (-not (Test-StageProductsOnDisk -Stage $s)) { continue }
        $ahead = @()
        for ($j = $i + 1; $j -lt $sortedStages.Count; $j++) {
            $t = $sortedStages[$j]
            if ($t.gen.Count -eq 0) { continue }
            if (Test-StageProductsOnDisk -Stage $t) { $ahead += $t.id }
        }
        if ($ahead.Count -gt 0) {
            Add-Trigger -Code 'T10_running_ahead' -Step $s.id -Detail ("its products are on disk, it has no passing verify, and " + ($ahead -join ', ') + " already have theirs - the evidence stopped, the work did not")
        }
    }
}

# ---------- output ----------
$need = $triggers.Count -gt 0
$result = [pscustomobject]@{
    needed   = $need
    count    = $triggers.Count
    triggers = $triggers.ToArray()
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
    if ($need) { exit 3 } else { exit 0 }
}

if (-not $Quiet) {
    Write-Host ''
    if (-not $need) {
        Write-Host 'Hermes: not needed (no trigger fired)' -ForegroundColor Green
        Write-Host ''
        exit 0
    }
    Write-Host "Hermes needed: $($triggers.Count) item(s)" -ForegroundColor Yellow
    foreach ($t in $triggers) {
        Write-Host ("  {0,-16} {1,-6} {2}" -f $t.code, $t.step, $t.detail) -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Scoped input for this run:' -ForegroundColor Cyan
    $steps = @($triggers | Where-Object { $_.step -ne '' } | ForEach-Object { $_.step } | Sort-Object -Unique)
    if ($steps.Count -gt 0) {
        Write-Host ("  read only: " + (($steps | ForEach-Object { "step $_ events + diff" }) -join ' | '))
    }
    else { Write-Host '  read only: the events named above' }
    Write-Host '  do NOT read the whole ledger'
    Write-Host ''
}

if ($need) { exit 3 } else { exit 0 }
