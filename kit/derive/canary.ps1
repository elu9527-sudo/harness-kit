<#
.SYNOPSIS
  Fault-injection drill for the harness itself: prove every detector can still
  fire. A check never seen to fail has not been shown able to fail.

.DESCRIPTION
  audit has been reporting the same two lines all day - "unexercised: T1 T5 T6"
  and "5 stages have passed every time and never once failed". Those warnings
  describe an untested safety system. Chaos Monkey's answer was not to argue
  about coverage but to inject failures on a schedule and watch the alarms;
  mutation testing's answer for assertions is the same move applied to tests.

  canary.ps1 is that move for this harness. Each scenario builds a throwaway
  fixture under %TEMP% (real append-event writes, so chains are real), injects
  exactly one defect, runs the detector, and asserts the specific code appears.
  The REAL project and its ledger are never opened for writing - every fixture
  path is absolute under the temp dir.

  Scenarios: T3 scope creep / T11 accepted output modified / T12 late gate /
  VOID trivial verify / C5 counter-proof / C1b tail truncation / T13 unexplained
  write / sweep detection. Run before every seal, or weekly.

.OUTPUTS
  exit 0 every detector fired when provoked
  exit 1 at least one detector is dead - a silent safety system
#>
[CmdletBinding()]
param(
    [string] $KitDerive = $(if ($PSScriptRoot) { $PSScriptRoot } else { '.' }),
    [switch] $Quiet,
    # install.ps1 runs the canary as step 6; scenario 15 executes install.ps1.
    # Without this switch they would recurse into each other forever.
    [switch] $SkipInstallSelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$results = [System.Collections.Generic.List[object]]::new()
$fixtures = @()

function New-Fixture {
    param([string] $Name)
    $dir = Join-Path $env:TEMP ("harness-canary-{0}-{1}" -f $Name, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    New-Item -ItemType Directory -Force -Path (Join-Path $dir '.harness\derive') | Out-Null
    Copy-Item -Path (Join-Path $KitDerive '*.ps1') -Destination (Join-Path $dir '.harness\derive') -Force
    $script:fixtures += $dir
    return $dir
}

function Run-Detector {
    param([string] $Dir, [string] $Script, [string] $Extra = '', [int] $ExpectExit = 0)
    $out = & pwsh -NoProfile -File (Join-Path $Dir ".harness\derive\$Script.ps1") -Root $Dir 2>&1 | Out-String
    # A detector that crashes IS a dead detector. On 2026-11-09 trigger aborted
    # on its first real-ledger input (StrictMode + `.Count` on an unrolled empty
    # array) for 103 minutes, yet every canary scenario still printed FIRED -
    # the fixtures never reached the crashing branch. Fold the exit code into
    # the returned text so ANY unexpected abort fails that scenario's match.
    if ($LASTEXITCODE -ne $ExpectExit) { $out = "DEAD_EXIT_$LASTEXITCODE`n$out" }
    return $out
}

function Add-Result {
    param([string] $What, [bool] $Ok, [string] $Detail)
    $results.Add([pscustomobject]@{ what = $What; ok = $Ok; detail = $Detail })
    $colour = if ($Ok) { 'Green' } else { 'Red' }
    $mark = if ($Ok) { 'FIRED ' } else { 'DEAD  ' }
    if (-not $Quiet) { Write-Host ("  [{0}] {1,-28} {2}" -f $mark, $What, $Detail) -ForegroundColor $colour }
}

function Seed-Project {
    param([string] $Dir, [string] $ProjectJson, [string] $CurrentStep = '1.1')
    $ProjectJson | Set-Content -LiteralPath (Join-Path $Dir '.harness\project.json') -Encoding UTF8 -NoNewline
    ('{"kit":"0.1","current_step":"' + $CurrentStep + '","project_sha256":""}') |
        Set-Content -LiteralPath (Join-Path $Dir '.harness\local.json') -Encoding UTF8 -NoNewline
}

function Append-Evt {
    param([string] $Dir, [string] $Event, [string] $Step, [hashtable] $Data, [string] $Cmd = '')
    $args1 = @('-NoProfile', '-File', (Join-Path $Dir '.harness\derive\append-event.ps1'), '-Root', $Dir, '-Event', $Event, '-Step', $Step, '-Quiet')
    if ($PSBoundParameters.ContainsKey('Data')) {
        $tmp = Join-Path $env:TEMP ("canary-ev-{0}.json" -f [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Data -Compress -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        $args1 += @('-DataJsonFile', $tmp)
    }
    if ($Cmd -ne '') { $args1 += @('-Cmd', $Cmd) }
    $null = & pwsh @args1 2>&1 | Out-String
    if ($PSBoundParameters.ContainsKey('Data')) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

$P2 = '{"stages":[{"id":"1.1","goal":"g1","generates":["a.py"],"verify":["cmd /c type a.py >nul"],"risk":"L1"},{"id":"1.2","goal":"g2","generates":["b.py"],"verify":["cmd /c exit 0"],"risk":"L2"}]}'

# ================================================================ scenarios
Write-Host ''
Write-Host 'canary drill - each fault is injected, the detector must react' -ForegroundColor Cyan
Write-Host ''

# --- 1. T3 scope creep ---------------------------------------------------
$d = New-Fixture 't3'
Seed-Project $d $P2
Set-Content -LiteralPath (Join-Path $d 'a.py') -Value 'print(1)' -Encoding UTF8
Append-Evt $d -Event tool_use -Step '1.1' -Data @{ file = 'random_outside.py'; sha256 = ('a' * 64); observed_by = 'hook'; tool = 'Write' }
$o = Run-Detector $d 'trigger'
Add-Result 'T3_out_of_scope' ($o -match 'T3_out_of_scope') $(if ($o -match 'T3_out_of_scope') { 'reported random_outside.py' } else { 'trigger stayed silent on an out-of-generates write' })

# --- 2. T11 accepted output modified ------------------------------------
$d = New-Fixture 't11'
Seed-Project $d $P2
Set-Content -LiteralPath (Join-Path $d 'a.py') -Value 'print(1)' -Encoding UTF8
Append-Evt $d -Event verify -Step '1.1' -Cmd 'cmd /c type a.py >nul'
Append-Evt $d -Event tool_use -Step '1.2' -Data @{ file = 'a.py'; sha256 = ('b' * 64); observed_by = 'hook'; tool = 'Edit' }
$o = Run-Detector $d 'trigger'
Add-Result 'T11_accepted_modified' ($o -match 'T11_accepted_modified') $(if ($o -match 'T11_accepted_modified') { 'reported a.py touched under 1.2 after 1.1 verified' } else { 'cross-step edit of a verified output went unreported' })

# --- 2b. T11 must see NON-hook writers (O5-01 regression nail) -----------
$d = New-Fixture 't11b'
Seed-Project $d $P2
Set-Content -LiteralPath (Join-Path $d 'a.py') -Value 'print(1)' -Encoding UTF8
Append-Evt $d -Event verify -Step '1.1' -Cmd 'cmd /c type a.py >nul'
Append-Evt $d -Event tool_use -Step '1.2' -Data @{ file = 'a.py'; sha256 = ('e' * 64); observed_by = 'script'; tool = 'manual'; actor_note = 'hermes-style registration of a post-acceptance edit' }
$o = Run-Detector $d 'trigger'
Add-Result 'T11_nonhook_writer' ($o -match 'T11_accepted_modified.*a\.py') $(if ($o -match 'T11_accepted_modified.*a\.py') { 'script-observed edit of verified output reported' } else { 'O5-01 REGRESSION: a hermes/human record editing verified output stays invisible' })

# --- 3. T12 gate after the fact -----------------------------------------
$d = New-Fixture 't12'
Seed-Project $d $P2
Set-Content -LiteralPath (Join-Path $d 'a.py') -Value 'print(1)' -Encoding UTF8
Append-Evt $d -Event tool_use -Step '1.1' -Data @{ file = 'a.py'; sha256 = ('c' * 64); observed_by = 'hook'; tool = 'Write' }
Start-Sleep -Milliseconds 1100
Append-Evt $d -Event gate -Step '1.1' -Data @{ level = 'L1'; status = 'approved'; by = 'canary'; why = 'gate deliberately recorded after the steps first event' }
$o = Run-Detector $d 'trigger'
Add-Result 'T12_gate_after_the_fact' ($o -match 'T12_gate_after_the_fact') $(if ($o -match 'T12_gate_after_the_fact') { 'late gate flagged' } else { 'a gate signed after the work looked like a front gate' })

# --- 4. VOID trivial verify ---------------------------------------------
$d = New-Fixture 'void'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["a.py"],"verify":["echo ok"],"risk":"L1"}]}'
Append-Evt $d -Event verify -Step '1.1' -Cmd 'echo ok'
$o = Run-Detector $d 'audit'
Add-Result 'C5_VOID_trivial_verify' ($o -match '1\.1=void') $(if ($o -match '1\.1=void') { 'echo ok judged void, not pass' } else { 'a command that cannot fail was accepted as evidence' })

# --- 5. C5 counter-proof --------------------------------------------------
$d = New-Fixture 'fail'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["a.py"],"verify":["cmd /c exit 7"],"risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 'a.py') -Value 'print(1)' -Encoding UTF8
Append-Evt $d -Event verify -Step '1.1' -Cmd 'cmd /c exit 7'
$o = Run-Detector $d 'audit'
Add-Result 'C5_latest_verify_FAILED' ($o -match 'latest verify FAILED') $(if ($o -match 'latest verify FAILED') { 'failing verify is a fault, not silence' } else { 'a red verify did not reach the fault list' })

# --- 6. C1b tail truncation ---------------------------------------------
$d = New-Fixture 'trunc'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":[],"verify":["cmd /c exit 0"],"risk":"L1"}]}'
Append-Evt $d -Event anchor -Step '1.1' -Data @{ name = 'canary'; value = 'seed'; why = 'checkpoint grows with each append' }
Append-Evt $d -Event anchor -Step '1.1' -Data @{ name = 'canary2'; value = 'seed2'; why = 'second record' }
Append-Evt $d -Event anchor -Step '1.1' -Data @{ name = 'canary3'; value = 'seed3'; why = 'third record' }
# checkpoint now attests the newest seq; cut the tail like an attacker would.
# The remaining chain stays perfectly self-consistent - which is the whole
# point: only the external anchor can see this.
$evPath = Join-Path $d 'events.jsonl'
$lines = @(Get-Content -LiteralPath $evPath -Encoding UTF8)
($lines[0..($lines.Count - 3)]) | Set-Content -LiteralPath $evPath -Encoding UTF8
$o = Run-Detector $d 'audit'
Add-Result 'C1b_ledger_truncation' ($o -match 'truncation') $(if ($o -match 'truncation') { 'deleted tail detected via external checkpoint' } else { 'the ledger could be cut and stay self-consistent - checkpoint blind' })

# --- 7. T13 unexplained write persists -----------------------------------
$d = New-Fixture 't13'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["w.py"],"verify":["cmd /c exit 0"],"risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 'w.py') -Value 'x' -Encoding UTF8
Append-Evt $d -Event unrecorded_write -Step '1.1' -Data @{ file = 'w.py'; disk_sha256 = ('d' * 64); last_recorded_sha256 = ''; note = 'injected observation' }
$o = Run-Detector $d 'trigger'
Add-Result 'T13_unrecorded_write' ($o -match 'T13_unrecorded_write') $(if ($o -match 'T13_unrecorded_write') { 'observation without explanation keeps demanding one' } else { 'sweep findings could sit unexplained with no alarm' })

# --- 9. T14 fires: FAIL -> PASS without any artifact movement -------------
$d = New-Fixture 't14pos'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["t.py"],"verify":["cmd /c exit 1"],"risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 't.py') -Value 'the same bytes throughout' -Encoding UTF8
Append-Evt $d -Event verify -Step '1.1' -Cmd 'cmd /c exit 1'
Append-Evt $d -Event verify -Step '1.1' -Cmd 'cmd /c type t.py >nul'
$o = Run-Detector $d 'trigger'
Add-Result 'T14_green_no_change' ($o -match 'T14_green_no_artifact_change') $(if ($o -match 'T14_green_no_artifact_change') { 'paper-moved green reported (the 3.1.3 pattern)' } else { 'a stage went green with its artifact untouched and nothing said so' })

# --- 10. T14 stays silent when the code actually moved --------------------
$d = New-Fixture 't14neg'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["t.py"],"verify":["cmd /c exit 1"],"risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 't.py') -Value 'broken' -Encoding UTF8
Append-Evt $d -Event verify -Step '1.1' -Cmd 'cmd /c exit 1'
Append-Evt $d -Event tool_use -Step '1.1' -Data @{ file = 't.py'; sha256 = (Get-FileHash (Join-Path $d 't.py') -Algorithm SHA256).Hash.ToLower(); observed_by = 'hook'; tool = 'Edit' }
Append-Evt $d -Event verify -Step '1.1' -Cmd 'cmd /c type t.py >nul'
$o = Run-Detector $d 'trigger'
Add-Result 'T14_silent_on_real_fix' (-not ($o -match 'T14_green_no_artifact_change')) $(if (-not ($o -match 'T14_green_no_artifact_change')) { 'fix-then-green does not accuse the paper' } else { 'O5-03 false-positive risk: a genuine fix reported as a loosened exam' })

# --- 8. sweep detects a drifting file ------------------------------------$d = New-Fixture 'sweep'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["s.py"],"verify":["cmd /c exit 0"],"risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 's.py') -Value 'original' -Encoding UTF8
Append-Evt $d -Event tool_use -Step '1.1' -Data @{ file = 's.py'; sha256 = (Get-FileHash (Join-Path $d 's.py') -Algorithm SHA256).Hash.ToLower(); observed_by = 'hook'; tool = 'Write' }
Set-Content -LiteralPath (Join-Path $d 's.py') -Value 'changed by an invisible hand' -Encoding UTF8
$o = & pwsh -NoProfile -File (Join-Path $d '.harness\derive\sweep.ps1') -Root $d -SettleMs 200 2>&1 | Out-String
Add-Result 'sweep_detection' ($o -match 'unrecorded change.*s\.py') $(if ($o -match 'unrecorded change.*s\.py') { 'disk-vs-ledger disagreement found and recorded' } else { 'a tracked file changed and sweep saw nothing' })

# --- 11. legacy records without the products field must NOT crash trigger ---
# The exact input that killed detection for 103 minutes on 2026-11-09: a FAIL ->
# PASS flip between records written before the products field existed. The empty
# branch of the T14 lookup unrolled to $null and `.Count` threw under StrictMode.
# Canary fixtures always carried products, so 11/11 lied. This scenario pins the
# shape: hand-written chain-less lines, trigger must survive AND stay T14-silent
# (no snapshot -> exempt by construction, never a guess).
$d = New-Fixture 'legacyflip'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["t.py"],"verify":["cmd /c exit 0"],"risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 't.py') -Value 'x' -Encoding UTF8
# chain-correct via the fixture's own _common (T8 recomputes self; dummy hashes
# would abort with exit 3 before T14's code path is ever reached).
. (Join-Path $d '.harness\derive\_common.ps1')
# genesis convention: the first record's prev is the EMPTY string (T8's
# expected= '' proves it); '0'*64 is a self hash failure, not a genesis.
$prevH = ''
$lines = ''
foreach ($pair in @(@{ sq = 1; cmd = 'cmd /c exit 1'; ex = 1 }, @{ sq = 2; cmd = 'cmd /c type t.py >nul'; ex = 0 })) {
    $rec = [ordered]@{ v = 1; seq = $pair.sq; at = '2026-11-05T00:00:00Z'; step = '1.1'; kind = 'routine'; actor = 'agent'; event = 'verify'; data = @{ command = $pair.cmd; exit = $pair.ex }; prev = $prevH }
    $rec.self = Get-Sha256Hex -Text (ConvertTo-CanonicalJson -InputObject $rec)
    $lines += (ConvertTo-Json $rec -Compress -Depth 6) + [Environment]::NewLine
    $prevH = [string]$rec.self
}
[System.IO.File]::AppendAllText((Join-Path $d 'events.jsonl'), $lines)
$o = Run-Detector $d 'trigger'
Add-Result 'legacy_flip_survives_no_products' (($o -notmatch 'DEAD_EXIT') -and ($o -notmatch 'T14_green_no_artifact_change')) $(if ($o -match 'DEAD_EXIT') { 'trigger ABORTED on a record without the products field - detection dies on real history' } elseif ($o -match 'T14_green_no_artifact_change') { 'fired on a pre-products flip it cannot prove - exemption-by-construction broken' } else { 'no-products history flips are exempt and harmless' })

# --- 12. a dead detector must read as DEAD ---------------------------------
# meta-check for the meta-check: if a detector exits non-zero, Run-Detector must
# inject DEAD_EXIT so no scenario can print FIRED over a crash.
$d = New-Fixture 'deadmeta'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["t.py"],"verify":["cmd /c exit 0"],"risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d '.harness\derive\crasher.ps1') -Value 'throw "boom"' -Encoding UTF8
$o = Run-Detector $d 'crasher'
Add-Result 'dead_detector_detected' ($o -match 'DEAD_EXIT') $(if ($o -match 'DEAD_EXIT') { 'non-zero exit folds into every assertion (no FIRED over a corpse)' } else { 'a crashing detector can still print FIRED - canary lies' })

# --- 13. C12 names sealed illegibility -------------------------------------
# seq 847/957 went into the chain as ~60% NUL and every existing rule shrugged:
# the chain verifies inalterability, not legibility. A control character in a
# recorded reason must surface as a C12 FAULT, not pass verify-ledger silently.
$d = New-Fixture 'nulgate'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["t.py"],"verify":["cmd /c exit 0"],"risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 't.py') -Value 'x' -Encoding UTF8
. (Join-Path $d '.harness\derive\_common.ps1')
$nulRec = [ordered]@{
    v = 1; seq = 1; at = '2026-11-09T00:00:00Z'; step = '1.1'; kind = 'routine'; actor = 'human'; event = 'gate'
    # REAL gate shape: data.{level,status,by,why}. The first fixture invented
    # gate.reason and C12 passed on a shape that exists nowhere - the same
    # fixture-vs-reality hole as O5-01. Pin reality.
    data = @{ level = 'L2'; status = 'approved'; by = 'human'; why = "ok$([char]0)碎$([char]0)片" }
    prev = ''
}
$nulRec.self = Get-Sha256Hex -Text (ConvertTo-CanonicalJson -InputObject $nulRec)
[System.IO.File]::AppendAllText((Join-Path $d 'events.jsonl'), ((ConvertTo-Json $nulRec -Compress -Depth 6) + [Environment]::NewLine))
$o = Run-Detector $d 'audit' -ExpectExit 1
Add-Result 'C12_sealed_illegible' ($o -match 'C12') $(if ($o -match 'C12') { 'a NUL-riddled recorded reason is a FAULT, not silent chain-valid consent' } else { 'destroyed human approvals seal clean - C12 is decoration' })

# --- 14. T15 fires: the verdict itself moved the world ----------------------
# 875 was a re-verify that ran init_db.py --migrate and WROTE the real db while
# products said "unchanged". universe_changed is the minimal world model:
# undeclared files the run touched must appear in the ledger and the queue.
$d = New-Fixture 't15world'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["a.py"],"verify":["pwsh -NoProfile -Command Set-Content-Path-widld.txt-Value-x"],"risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 'a.py') -Value 'quiet' -Encoding UTF8
Append-Evt $d -Event verify -Step '1.1' -Cmd 'pwsh -NoProfile -Command "Set-Content -Path widld.txt -Value x"'
$o = Run-Detector $d 'trigger'
$hasUni = ($o -match 'T15_universe_moved')
Add-Result 'T15_universe_moved' $hasUni $(if ($hasUni) { 'undeclared file written during verdict is named in the queue' } else { 'verify moved the world and the ledger stayed silent - the 875 blind spot is still open' })

# --- 14b. T14b fires when the ONLY thing that moved is the grader -----------
# products state is WINDOW semantics (did bytes move during the run), writesSince
# is cross-window. T14b's real shape: at the moment of the green verdict, the
# only declared product whose bytes moved is the grader itself, business code
# unmoved. Fixture: the verify command literally appends to its own checker.
$d = New-Fixture 't14bexam'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["check_exam.py","business.py"],"verify":["pwsh -NoProfile -Command exit 1"],"risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 'check_exam.py') -Value 'strict' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $d 'business.py') -Value 'unchanged business code' -Encoding UTF8
Append-Evt $d -Event verify -Step '1.1' -Cmd 'pwsh -NoProfile -Command "exit 1"'
Append-Evt $d -Event verify -Step '1.1' -Cmd 'pwsh -NoProfile -Command "Add-Content -Path check_exam.py -Value lenient; exit 0"'
$o = Run-Detector $d 'trigger'
$has14b = ($o -match 'T14b_green_exam_only_change')
Add-Result 'T14b_exam_only' $has14b $(if ($has14b) { 'FAIL->PASS whose only product movement is the grader itself is called out, not amnestied' } else { 'a green that softened its own paper slipped through as a normal fix' })

# --- 14c. the universe walk must SURVIVE its own truncation branch ----------
# 2026-11-10, found by the coach: `$trunc = true` (bare token) blew up only when
# the project crossed 400 counted files - every fixture was under budget, so the
# line executed for the first time on REAL data and took all verify ledgering
# down for 18 hours. This fixture goes over budget on purpose.
$d = New-Fixture 'uni400'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["a.py"],"verify":["pwsh -NoProfile -Command exit 0"],"risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 'a.py') -Value 'x' -Encoding UTF8
$many = Join-Path $d 'many'; New-Item -ItemType Directory -Force -Path $many | Out-Null
foreach ($i in 1..405) { [System.IO.File]::WriteAllText((Join-Path $many ('f{0:D3}.txt' -f $i)), 'pad') }
Append-Evt $d -Event verify -Step '1.1' -Cmd 'pwsh -NoProfile -Command exit 0'
$okAlive = Test-Path (Join-Path $d 'events.jsonl')
$verifyLanded = $false
if ($okAlive) { $verifyLanded = @((Get-Content (Join-Path $d 'events.jsonl') -Encoding UTF8) | Where-Object { $_ -match '"event":"verify"' }).Count -gt 0 }
$truncFlag = $false
if ($verifyLanded) { $vr = Get-Content (Join-Path $d 'events.jsonl') -Encoding UTF8 | Where-Object { $_ -match '"event":"verify"' } | Select-Object -Last 1 | ConvertFrom-Json; $truncFlag = [bool]$vr.data.universe_truncated }
Add-Result 'universe_truncation_survives' ($verifyLanded -and $truncFlag) $(if (-not $verifyLanded) { 'verify at 400+ files CRASHED the ledgering again - the 11-10 eighteen-hour hole is back' } elseif (-not $truncFlag) { 'truncated universe was NOT declared in the record - silent partial coverage, the O5-04 family' } else { 'over-budget project lands verify and declares universe_truncated honestly' })

# --- 19. stage-add gate: bad drafts rejected without touching disk, good -----
# drafts land with a contract_change. The 11-10 process fix: the human confirms
# a diff, never hand-types the contract. Trivial verify must be refused HERE.
$d = New-Fixture 'stageadd'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["a.py"],"verify":["pwsh -NoProfile -Command exit 1"],"risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 'a.py') -Value 'x' -Encoding UTF8
New-Item -ItemType Directory -Force -Path (Join-Path $d '.harness\local') | Out-Null
[System.IO.File]::WriteAllText((Join-Path $d '.harness\local\stage-draft.json'), '{"id":"2.0","goal":"g2","generates":["b.py"],"requires":["1.1"],"verify":["echo ok"],"risk":"L1"}', (New-Object System.Text.UTF8Encoding($false)))
& pwsh -NoProfile -File (Join-Path $d '.harness\derive\stage-add.ps1') -Root $d -Yes 2>&1 | Out-Null
$rejCode = $LASTEXITCODE
$untouched = ((Get-Content (Join-Path $d '.harness\project.json') -Raw) -match '"id":\s*"1\.1"') -and -not ((Get-Content (Join-Path $d '.harness\project.json') -Raw) -match '2\.0')
[System.IO.File]::WriteAllText((Join-Path $d '.harness\local\stage-draft.json'), '{"id":"2.0","goal":"g2","generates":["b.py"],"requires":["1.1"],"verify":["pytest -q tests/test_b.py"],"risk":"L1"}', (New-Object System.Text.UTF8Encoding($false)))
& pwsh -NoProfile -File (Join-Path $d '.harness\derive\stage-add.ps1') -Root $d -Yes 2>&1 | Out-Null
$accCode = $LASTEXITCODE
$ccLanded = @(Get-Content (Join-Path $d 'events.jsonl') -Encoding UTF8 | Where-Object { $_ -match '"event":"contract_change"' }).Count
Add-Result 'stage_add_gate' (($rejCode -eq 2) -and $untouched -and ($accCode -eq 0) -and ($ccLanded -gt 0)) $(if ($rejCode -ne 2) { 'trivial-verify draft was ACCEPTED - the contract gate is decoration' } elseif (-not $untouched) { 'a rejected draft still touched project.json - reject must mean untouched' } elseif ($accCode -ne 0) { 'valid draft refused or crashed' } elseif ($ccLanded -eq 0) { 'contract merged but no contract_change in the ledger - silent contract edit' } else { 'trivial verify rejected untouched; valid draft landed WITH its contract_change' })

# --- 21z. [P3] 关步即提交：commit message 带 step + ledger seq + worker 身份 -----------
# 2026-11-19：账本与 git 双轨，必须能互查。这条钉住三件：真的产生 commit、
# message 里有 `step <id> · seq`、提交者不是操作者身份（vibe-worker）。
# 另钉住"不是 git 仓库时静默跳过"——其余 fixture 全在非仓库目录，39 条能过就说明
# 这条分支不炸。
$dg = New-Fixture 'gitcommit'
Seed-Project $dg '{"stages":[{"id":"1.0","goal":"聚合站初筛（细节）","generates":["a.py"],"verify":"t","risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $dg 'a.py') -Value "print(1)`n" -Encoding UTF8
$null = & git -C $dg init -q 2>&1
$null = & git -C $dg -c user.name=seed -c user.email=seed@x add -A 2>&1
$null = & git -C $dg -c user.name=seed -c user.email=seed@x commit --no-verify -m 'seed' 2>&1
$gcOut = & pwsh -NoProfile -File (Join-Path $dg '.harness\derive\finish-step.ps1') -Root $dg -Step '1.0' -SkipVerify -Quiet 2>&1 | Out-String
$gcExit = $LASTEXITCODE
$gcLog = (& git -C $dg log -1 --format='%s|%an' 2>&1 | Out-String).Trim()
Add-Result 'finish_git_commit' (($gcExit -eq 0) -and ($gcLog -match 'step 1\.0 · seq') -and ($gcLog -match 'vibe-worker') -and ($gcLog -match '聚合站初筛')) ("last commit = " + $gcLog)

# --- 21z2. [P1] stage-edit -Generates 不许把 generates 写没 ---------------------
# 2026-11-19：旧写法 `@((Get-F $stage 'generates') -join ', ', $Generates)` 实际只产生
# 1 个元素（实测 r[0]=把三个串糊成一个、r[1]=$null），落盘时 $changes['generates'][1]
# 取到 $null → generates 被写成 ['']，即整张文件清单被抹掉。这条钉住「写完还是 N 条真路径」。
$null = & pwsh -NoProfile -File (Join-Path $dg '.harness\derive\stage-edit.ps1') -Root $dg -Step '1.0' -Generates 'x.py,y.py' -NoModel 2>&1
$geExit = $LASTEXITCODE
$pjG = Get-Content -LiteralPath (Join-Path $dg '.harness\project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$genNow = @($pjG.stages[0].generates)
Add-Result 'stage_edit_generates' (($geExit -eq 0) -and ($genNow.Count -eq 2) -and ($genNow[0] -eq 'x.py') -and ($genNow[1] -eq 'y.py')) ("generates = " + ($genNow -join ' , ') + "  (count $($genNow.Count))")

# --- 21z3. [P1] 指向表后位置的依赖，不许被"文件已存在"冒认成 done ---------------
# 2026-11-23 真伤：2.0.9 requires 2.0.10（2.0.10 在表里更靠后、且 generates 文件已存在），
# 旧 lookahead 把 2.0.10 当成 done → 2.0.9 判 READY 并抢走 NEXT，而 2.0.10 自己是 blocked。
# 文件在 ≠ 验收过。这条钉住：前向依赖未 done 时，依赖方必须 blocked。
$df = New-Fixture 'fwdreq'
Seed-Project $df '{"stages":[{"id":"1.0","goal":"a","generates":["b.py"],"requires":["1.1"],"verify":"t","risk":"L1"},{"id":"1.1","goal":"b","generates":["a.py"],"verify":"t","risk":"L1"}]}' '1.0'
Set-Content -LiteralPath (Join-Path $df 'a.py') -Value "y`n" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $df 'b.py') -Value "x`n" -Encoding UTF8
# 1.0 的 generates 是 b.py，1.1 的是 a.py：两个文件都存在（这正是旧 lookahead 的触发条件）
$jf = & pwsh -NoProfile -File (Join-Path $df '.harness\derive\status.ps1') -Root $df -Json 2>&1 | Out-String
try {
    $of = $jf | ConvertFrom-Json
    $s10 = [string](($of.artifacts | Where-Object { $_.id -eq '1.0' }).status)
    $nx = if ($null -ne $of.PSObject.Properties['next']) { [string]$of.next } else { '' }
    Add-Result 'status_forward_req' (($s10 -eq 'blocked') -and ($nx -eq '1.1')) ("1.0(requires 1.1) = $s10, next = $nx")
}
catch {
    Add-Result 'status_forward_req' $false ('status -Json 解析失败: ' + $_.Exception.Message)
}

# --- 21z4. [P1] 删掉 generates 的文件，不许撤销"已完成" ---------------------------
# 2026-11-25 真伤：2.0.40 删了 2.0.18 的 os_driver/os_runner → 2.0.18 永远 done 不了 →
# 顺着 requires 把之后 30 个**已有 PASS** 的步骤全判成 blocked。done 应该只认证据。
$dd = New-Fixture 'doneafterdel'
Seed-Project $dd '{"stages":[{"id":"1.0","goal":"a","generates":["a.py"],"verify":"python t.py","risk":"L1"}]}' '1.0'
Set-Content -LiteralPath (Join-Path $dd 't.py') -Value "import unittest`nclass T(unittest.TestCase):`n    def test_ok(self): self.assertTrue(True)`nif __name__ == '__main__':`n    unittest.main()`n" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $dd 'a.py') -Value "print(1)`n" -Encoding UTF8
$null = & pwsh -NoProfile -File (Join-Path $dd '.harness\derive\verify.ps1') -Root $dd -Step '1.0' 2>&1
Remove-Item -LiteralPath (Join-Path $dd 'a.py') -Force -ErrorAction SilentlyContinue
$jd = (& pwsh -NoProfile -File (Join-Path $dd '.harness\derive\status.ps1') -Root $dd -Json 2>&1 | Out-String) | ConvertFrom-Json
$dStat = [string](($jd.artifacts | Where-Object { $_.id -eq '1.0' }).status)
Add-Result 'status_done_after_delete' ($dStat -eq 'done') ("1.0 有 PASS 后删掉 a.py → status=$dStat（应 done）")

# --- 21z5. [P1] 关步后账没动，必须 MISMATCH 而不是静默成功 -----------------------
$dm = New-Fixture 'mismatch'
Seed-Project $dm '{"stages":[{"id":"1.0","goal":"a","generates":["a.py"],"requires":["9.9"],"verify":"t","risk":"L1"}]}' '1.0'
Set-Content -LiteralPath (Join-Path $dm 'a.py') -Value "print(1)`n" -Encoding UTF8
$om = & pwsh -NoProfile -File (Join-Path $dm '.harness\derive\finish-step.ps1') -Root $dm -Step '1.0' -SkipVerify 2>&1 | Out-String
Add-Result 'finish_mismatch' ($om -match '\[MISMATCH\]') $(if ($om -match '\[MISMATCH\]') { '关步后回读发现 status 不是 done，已大声报出' } else { '关步后账没动却静默成功 - 漏洞会活很多步' })

# --- 21z6. [P1] 删文件是"某一步的决定"，要留痕并当 supersede 锚点 ---------------
# 2026-11-25：2.0.40 删掉 2.0.18 的 os_runner 时，账本里没有任何"删了它"的记录，
# 于是只能显示成"缺文件"（ORPHAN）。现在 finish-step 会把删除写成 file_removed 事件，
# status 用它把"缺文件"翻译成"被哪一步取代"——不需要给阶段加墓碑。
$ds = New-Fixture 'supersede'
Seed-Project $ds '{"stages":[{"id":"1.0","goal":"a","generates":["a.py"],"verify":"python t.py","risk":"L1"},{"id":"1.1","goal":"b","generates":["b.py"],"verify":"python t.py","risk":"L1"}]}' '1.0'
Set-Content -LiteralPath (Join-Path $ds 't.py') -Value "import unittest`nclass T(unittest.TestCase):`n    def test_ok(self): self.assertTrue(True)`nif __name__ == '__main__':`n    unittest.main()`n" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $ds 'a.py') -Value "print(1)`n" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $ds 'b.py') -Value "print(2)`n" -Encoding UTF8
$null = & pwsh -NoProfile -File (Join-Path $ds '.harness\derive\verify.ps1') -Root $ds -Step '1.0' 2>&1
# 造 1.1 的 before 图（真环境里由 PreToolUse 落），再删掉 a.py：finish-step 应记 file_removed
$dsnap = Join-Path $ds 'docs\_snap\1.1'
New-Item -ItemType Directory -Force -Path $dsnap | Out-Null
Set-Content -LiteralPath (Join-Path $dsnap 'a.py.before') -Value "print(1)`n" -Encoding UTF8
'{ "a.py": { "first_tool": "Edit", "at": "2026-11-25T00:00:00.000Z", "before": "a.py.before" } }' | Set-Content -LiteralPath (Join-Path $dsnap '_manifest.json') -Encoding UTF8
Remove-Item -LiteralPath (Join-Path $ds 'a.py') -Force -ErrorAction SilentlyContinue
$null = & pwsh -NoProfile -File (Join-Path $ds '.harness\derive\finish-step.ps1') -Root $ds -Step '1.1' -SkipVerify -Quiet 2>&1
$oS = (& pwsh -NoProfile -File (Join-Path $ds '.harness\derive\status.ps1') -Root $ds 2>&1 | Out-String)
Add-Result 'supersede_anchor' (($oS -match 'superseded\s+1 条') -and ($oS -match 'a\.py<-1\.1') -and ($oS -notmatch 'ORPHAN')) $(if ($oS -match 'a\.py<-1\.1') { 'a.py 的消失被记成 1.1 的删除决定，不再报 ORPHAN' } else { '删除没有留痕 - 被删的 generates 只能显示成缺文件' })

# --- 19b. paste mode: fenced draft block via stdin, fences stripped ----------
Remove-Item (Join-Path $d '.harness\local\stage-draft.json') -Force -ErrorAction SilentlyContinue
$fenced = '```json' + "`n" + '{"id":"3.0","goal":"g3","generates":["c.py"],"requires":["1.1"],"verify":["pytest -q tests/test_c.py"],"risk":"L1"}' + "`n" + '```'
$pOut = $fenced | & pwsh -NoProfile -File (Join-Path $d '.harness\derive\stage-add.ps1') -Root $d -DryRun 2>&1 | Out-String
Add-Result 'stage_add_paste_fences' (($LASTEXITCODE -eq 0) -and ($pOut -match '3\.0') -and ($pOut -notmatch 'DEAD_EXIT')) $(if ($LASTEXITCODE -eq 0 -and $pOut -match '3\.0') { 'whole fenced block pastes clean - no file, no escaping, no tidying' } else { 'paste mode failed on markdown fences - the human is back to hand-editing: ' + (($pOut -split "`r?`n" | Select-Object -Last 1)) })

# --- 19c2. 插步插在父步之后，不是表尾 ---
# 2026-11-18：append 让 1.2.1 落到 1.5 后面，status 的 next 就判成 1.3、钩子按 1.3
# 打标、finish-step 1.2.1 找不到自己的 before 图。表序就是优先级，这条钉住位置。
$d = New-Fixture 'insertpos'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"a","generates":["a.py"],"verify":"t","risk":"L1"},{"id":"1.3","goal":"c","generates":["c.py"],"verify":"t","risk":"L1"}]}'
New-Item -ItemType Directory -Force -Path (Join-Path $d '.harness\local') | Out-Null
[System.IO.File]::WriteAllText((Join-Path $d '.harness\local\stage-draft.json'), '{"id":"1.1.1","goal":"b","generates":["b.py"],"requires":["1.1"],"verify":["pytest -q tests/test_b.py"],"risk":"L1"}', (New-Object System.Text.UTF8Encoding($false)))
& pwsh -NoProfile -File (Join-Path $d '.harness\derive\stage-add.ps1') -Root $d -Yes 2>&1 | Out-Null
$posExit = $LASTEXITCODE
$ids = @((Get-Content -LiteralPath (Join-Path $d '.harness\project.json') -Raw -Encoding UTF8 | ConvertFrom-Json).stages | ForEach-Object { [string]$_.id })
Add-Result 'stage_insert_position' (($posExit -eq 0) -and (($ids -join ',') -eq '1.1,1.1.1,1.3')) ("insert order = " + ($ids -join ','))

# --- 19c. T2b coverage must be the file FIELD, not a substring of the why ----
# sign-contract flow: a contract_change on AGENTS.md whose why prose mentions
# "project.json" must NOT suppress the project.json baseline-drift check. The
# old substring match let free text kill a live detector for as long as such
# an event existed anywhere in the ledger.
$d = New-Fixture 't2bsup'
Seed-Project $d $P2
Set-Content -LiteralPath (Join-Path $d 'a.py') -Value 'print(1)' -Encoding UTF8
# non-empty baseline that does NOT match the real project.json -> drift is real
$localP = Join-Path $d '.harness\local.json'
$localJ = Get-Content -LiteralPath $localP -Raw | ConvertFrom-Json
$localJ | Add-Member -NotePropertyName project_sha256 -NotePropertyValue ('0' * 63 + '1') -Force
$localJ | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $localP -Encoding UTF8 -NoNewline
Append-Evt $d -Event contract_change -Step 'contract' -Data @{ file = 'AGENTS.md'; before_sha256 = ('1' * 64); after_sha256 = ('2' * 64); why = 'doc aligned with stage-add paste flow; project.json is no longer hand-typed'; approved_by = 'human' }
$o = Run-Detector $d 'trigger'
$driftFired = $o -match 'sha256 differs from baseline'
# and legitimate coverage - a contract_change ON project.json - must still suppress it
Append-Evt $d -Event contract_change -Step 'contract' -Data @{ file = '.harness/project.json'; before_sha256 = ('0' * 63 + '1'); after_sha256 = ('3' * 64); why = 'baseline synced'; approved_by = 'human' }
$o2 = Run-Detector $d 'trigger'
$coveredSilent = -not ($o2 -match 'sha256 differs from baseline')
Add-Result 't2b_exact_coverage' ($driftFired -and $coveredSilent) $(if (-not $driftFired) { 'an AGENTS.md contract_change whose WHY mentions project.json silently killed the baseline drift check - substring suppression is live' } elseif (-not $coveredSilent) { 'a real project.json contract_change no longer suppresses the drift check - coverage test too strict' } else { 'why-prose cannot suppress; only a contract_change ON project.json covers it' })

# --- 19d. record-edit backfill must land digests: disk-vs-ledger must close ---
# 11-10: the backfill event carried no sha256/before_sha256. sweep's tracked set
# keys on tool_use data.sha256, so a backfill never updated the comparison base,
# and any later tool that needs the file's last RECORDED state (the sign-contract
# self-heal path: "run record-edit first, then before has a source") found
# nothing - the prescribed way out of exit 2 was itself a dead end.
$d = New-Fixture 'recdig'
Seed-Project $d $P2
Set-Content -LiteralPath (Join-Path $d 's.py') -Value 'A' -Encoding UTF8
& pwsh -NoProfile -File (Join-Path $d '.harness\derive\record-edit.ps1') -Root $d -File 's.py' -Why 'seed registration of pre-hook file' -Yes -Quiet 2>&1 | Out-Null
$re1 = $LASTEXITCODE
$shaA = (Get-FileHash (Join-Path $d 's.py') -Algorithm SHA256).Hash.ToLower()
$evs = @(Get-Content (Join-Path $d 'events.jsonl') -Encoding UTF8 | Where-Object { $_ -match '"tool":"manual"' })
$dig1 = ($evs.Count -ge 1) -and ($evs[-1] -match ('"sha256":"' + $shaA + '"')) -and ($evs[-1] -match '"before_sha256":""')
# rotate content; second backfill must chain before = the first recorded digest
Set-Content -LiteralPath (Join-Path $d 's.py') -Value 'B' -Encoding UTF8
$shaB = (Get-FileHash (Join-Path $d 's.py') -Algorithm SHA256).Hash.ToLower()
& pwsh -NoProfile -File (Join-Path $d '.harness\derive\record-edit.ps1') -Root $d -File 's.py' -Why 'rotate s.py content to B' -Yes -Quiet 2>&1 | Out-Null
$re2 = $LASTEXITCODE
$evs2 = @(Get-Content (Join-Path $d 'events.jsonl') -Encoding UTF8 | Where-Object { $_ -match '"tool":"manual"' })
$chained = ($evs2.Count -ge 2) -and ($evs2[-1] -match ('"sha256":"' + $shaB + '"')) -and ($evs2[-1] -match ('"before_sha256":"' + $shaA + '"'))
# with digests on record, sweep must find disk==ledger and stay silent
$oSw = Run-Detector $d 'sweep'
$sweepClosed = ($oSw -notmatch 'unrecorded change: s\.py') -and ($oSw -notmatch 'DEAD_EXIT')
Add-Result 'record_edit_lands_digest' (($re1 -eq 0) -and $dig1 -and ($re2 -eq 0) -and $chained -and $sweepClosed) $(if ($re1 -ne 0) { 'first backfill refused or crashed' } elseif (-not $dig1) { 'backfill landed without sha256/before chain - a recorded write that cannot pin WHAT was recorded' } elseif ($re2 -ne 0) { 'second backfill refused or crashed' } elseif (-not $chained) { 'second backfill did not chain before_sha256 to the prior recorded digest - the self-heal path for sign-contract style lookups is still dead' } elseif (-not $sweepClosed) { 'sweep still reports s.py as unrecorded after backfill - disk-vs-ledger never closes' } else { 'backfill lands sha256 + before chain; sweep converges and stays silent' })

# --- 19e. [BETA] attention layer tiers without weakening detection ----------
# Super-agent panel principle: show only what needs a person. A historical T3
# (Temp) must be REVIEWABLE and collapsible by human ack; a T13 must ALWAYS stay
# in NEEDS YOU. The underlying trigger must still report both (no weakening).
$d = New-Fixture 'attention'
Seed-Project $d $P2
Set-Content -LiteralPath (Join-Path $d 'a.py') -Value 'print(1)' -Encoding UTF8
Append-Evt $d -Event tool_use -Step '1.1' -Data @{ file = 'C:/Users/x/AppData/Local/Temp/old_selftest.py'; sha256 = ('a' * 64); observed_by = 'hook'; tool = 'Write' }
Append-Evt $d -Event unrecorded_write -Step '1.1' -Data @{ file = 's.py'; disk_sha256 = ('b' * 64); note = 'machine observation' }
$oA = Run-Detector $d 'attention'
$t13Needs = ($oA -match 'NEEDS YOU \(1\)') -and ($oA -match 'T13_unrecorded_write')
$t3Review = ($oA -match 'REVIEWABLE \(1\)') -and ($oA -match 'T3_out_of_scope')
# human acks the reviewable set once
& pwsh -NoProfile -File (Join-Path $d '.harness\derive\attention.ps1') -Root $d -AckReviewable -Quiet 2>&1 | Out-Null
$oB = Run-Detector $d 'attention'
$collapsed = ($oB -match 'COLLAPSED \(acknowledged\): 1') -and ($oB -notmatch 'REVIEWABLE \(1\)')
$stillNeeds = ($oB -match 'NEEDS YOU \(1\)') -and ($oB -match 'T13_unrecorded_write')
# trigger itself must STILL report both (projection did not weaken detection)
$oT = Run-Detector $d 'trigger'
$notWeakened = ($oT -match 'T13_unrecorded_write') -and ($oT -match 'T3_out_of_scope')
Add-Result 'attention_tiers_beta' ($t13Needs -and $t3Review -and $collapsed -and $stillNeeds -and $notWeakened) $(if (-not $notWeakened) { 'attention WEAKENED the trigger - forbidden' } elseif (-not $t13Needs) { 'T13 not in NEEDS YOU' } elseif (-not $t3Review) { 'historical T3 not REVIEWABLE' } elseif (-not $collapsed) { 'ack did not collapse the historical item' } elseif (-not $stillNeeds) { 'ack wrongly collapsed a T13' } else { 'historical collapses on ack; actionable stays; trigger untouched' })

# --- 19g. [v0.8] -Paste overrides a stale default draft; default use is loud ---
$d = New-Fixture 'stagepaste'
Seed-Project $d '{"stages":[{"id":"1.1","goal":"g","generates":["a.py"],"verify":["pwsh -NoProfile -Command exit 1"],"risk":"L1"}]}'
New-Item -ItemType Directory -Force -Path (Join-Path $d '.harness\local') | Out-Null
[System.IO.File]::WriteAllText((Join-Path $d '.harness\local\stage-draft.json'), '{"id":"9.0","goal":"stale","generates":["z.py"],"requires":["1.1"],"verify":["pytest -q tests/test_z.py"],"risk":"L1"}', (New-Object System.Text.UTF8Encoding($false)))
$oNo = & pwsh -NoProfile -File (Join-Path $d '.harness\derive\stage-add.ps1') -Root $d -DryRun 2>&1 | Out-String
$loud = ($oNo -match '9\.0') -and ($oNo -match '注意')
$fenced = '```json' + "`n" + '{"id":"3.0","goal":"g3","generates":["c.py"],"requires":["1.1"],"verify":["pytest -q tests/test_c.py"],"risk":"L1"}' + "`n" + '```'
$oYes = $fenced | & pwsh -NoProfile -File (Join-Path $d '.harness\derive\stage-add.ps1') -Root $d -Paste -DryRun 2>&1 | Out-String
$pasteWins = ($oYes -match '3\.0') -and (-not ($oYes -match '9\.0'))
Add-Result 'stage_paste_overrides_stale' ($loud -and $pasteWins) $(if (-not $loud) { 'default draft used silently - the 11-12 stale-file trap is back' } elseif (-not $pasteWins) { '-Paste did not override the stale default file' } else { 'default use is loud; -Paste wins over stale file' })

# --- 19f. T16 stale gate (Mandate revalidation): mismatch alarms, match/legacy silent ---
$d = New-Fixture 't16'
Seed-Project $d $P2
$realSha = (Get-FileHash -LiteralPath (Join-Path $d '.harness\project.json') -Algorithm SHA256).Hash.ToLower()
Append-Evt $d -Event gate -Step '1.2' -Data @{ level = 'L2'; contract_sha = ('1' * 64) }   # stale
Append-Evt $d -Event gate -Step '1.1' -Data @{ level = 'L2'; contract_sha = $realSha }      # current
Append-Evt $d -Event gate -Step '2.0' -Data @{ level = 'L2' }                               # legacy, exempt
$o16 = Run-Detector $d 'trigger'
$staleFires = $o16 -match 'T16_stale_gate\s+1\.2'
$matchSilent = -not ($o16 -match 'T16_stale_gate\s+1\.1')
$legacySilent = -not ($o16 -match 'T16_stale_gate\s+2\.0')
Add-Result 'T16_stale_gate' ($staleFires -and $matchSilent -and $legacySilent) $(if (-not $staleFires) { 'a gate signed under an old contract did not alarm - stale Mandate invisible' } elseif (-not $matchSilent) { 'a current-contract gate wrongly alarmed' } elseif (-not $legacySilent) { 'legacy gate without contract_sha retro-alarmed - exemption-by-construction broken' } else { 'stale gate alarms; current and legacy gates stay silent' })

# --- 20a. [P0] observe detects drift/missing/regression; attention surfaces OBS_* ---
$d = New-Fixture 'observe'
Seed-Project $d '{"stages":[{"id":"1.0","goal":"a","generates":["a.txt"],"verify":"check a","risk":"L1"},{"id":"2.0","goal":"b","generates":["b.txt"],"verify":"check b","risk":"L1"},{"id":"3.0","goal":"c","generates":["c.txt"],"verify":"check c","risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 'a.txt') -Value 'new' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $d 'c.txt') -Value 'ok' -Encoding UTF8
Append-Evt $d -Event tool_use -Step '1.0' -Data @{ file='a.txt'; sha256=('0'*64) }
Append-Evt $d -Event step_advance -Step '1.0' -Data @{}
Append-Evt $d -Event step_advance -Step '2.0' -Data @{}
Append-Evt $d -Event step_advance -Step '3.0' -Data @{}
Append-Evt $d -Event verify -Step '3.0' -Cmd 'cmd /c exit 1'
$oObs = Run-Detector $d 'observe'
$obsFires = ($oObs -match 'conflicts=3') -and ($oObs -match '\[drift\]') -and ($oObs -match '\[missing\]') -and ($oObs -match '\[regression\]')
$oAtt = Run-Detector $d 'attention'
$obsNeeds = ($oAtt -match 'OBS_drift') -and ($oAtt -match 'NEEDS YOU')
Add-Result 'observe_detects' ($obsFires -and $obsNeeds) $(if (-not $obsFires) { 'observe missed an injected conflict' } elseif (-not $obsNeeds) { 'observe conflict not in attention NEEDS YOU' } else { 'drift/missing/regression fire and surface as NEEDS YOU' })

# --- 20b. [P0] observe clean when disk==ledger and verify pass ---
$d = New-Fixture 'obsclean'
Seed-Project $d '{"stages":[{"id":"1.0","goal":"a","generates":["a.txt"],"verify":"check a","risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 'a.txt') -Value 'same' -Encoding UTF8
$sha = (Get-FileHash -LiteralPath (Join-Path $d 'a.txt') -Algorithm SHA256).Hash.ToLower()
Append-Evt $d -Event tool_use -Step '1.0' -Data @{ file='a.txt'; sha256=$sha }
Append-Evt $d -Event step_advance -Step '1.0' -Data @{}
Append-Evt $d -Event verify -Step '1.0' -Cmd 'cmd /c exit 0'
$oClean = Run-Detector $d 'observe'
Add-Result 'observe_clean' ($oClean -match 'conflicts=0') 'no false positive when reality matches spec'

# --- 20c. [P0] analyze flags dup_owner/void_verify/bad_risk ---
$d = New-Fixture 'analyze'
Seed-Project $d '{"stages":[{"id":"1.0","goal":"a","generates":["x.py"],"verify":"pytest -q t.py","risk":"L1"},{"id":"2.0","goal":"b","generates":["x.py"],"verify":"echo ok","risk":"L9"}]}'
$oAn = Run-Detector $d 'analyze'
$anFires = ($oAn -match 'dup_owner') -and ($oAn -match 'void_verify') -and ($oAn -match 'bad_risk')
Add-Result 'analyze_gate' $anFires 'spec-consistency gate flags ownership/void/risk defects'

# --- 20d. [P0] impact transitive downstream ---
$d = New-Fixture 'impact'
Seed-Project $d '{"stages":[{"id":"1.0","goal":"a","generates":["a.py"],"verify":"t","risk":"L1"},{"id":"2.0","goal":"b","generates":["b.py"],"requires":["1.0"],"verify":"t","risk":"L1"},{"id":"3.0","goal":"c","generates":["c.py"],"requires":["2.0"],"verify":"t","risk":"L1"}]}'
$oIm = & pwsh -NoProfile -File (Join-Path $d '.harness\derive\impact.ps1') -Root $d -Files 'a.py' 2>&1 | Out-String
$imOk = ($oIm -match '1\.0') -and ($oIm -match '2\.0') -and ($oIm -match '3\.0')
Add-Result 'impact_downstream' $imOk 'change to a.py propagates to 2.0 and 3.0'

# --- 20e. [P0] contract-bump version+stale+backup (human -Yes) ---
$d = New-Fixture 'bump'
Seed-Project $d '{"stages":[{"id":"1.0","goal":"a","generates":["a.py"],"verify":"t","risk":"L1"},{"id":"2.0","goal":"b","generates":["b.py"],"requires":["1.0"],"verify":"t","risk":"L1"}]}'
$oBump = & pwsh -NoProfile -File (Join-Path $d '.harness\derive\contract-bump.ps1') -Root $d -Files 'a.py' -Yes 2>&1 | Out-String
$pj = Get-Content -LiteralPath (Join-Path $d '.harness\project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$bumpOk = ($oBump -match 'v0 -> v1') -and ([int]$pj.contract_version -eq 1) -and ($pj.stages[0].stale -eq $true) -and ($pj.stages[1].stale -eq $true)
Add-Result 'contract_bump' $bumpOk 'version+1, affected stages stale, backup written'

# --- 21z. [P3] stage-edit：改计划免签，一条 plan_edit 入账 ---
# 2026-11-17 定：改还没发生的事不需要被批准，只需要被记下来。这条断的就是"没有 y"。
$d = New-Fixture 'stagedit'
Seed-Project $d '{"stages":[{"id":"1.0","goal":"old","generates":["a.py"],"verify":"t","risk":"L1"}]}'
$oSE = & pwsh -NoProfile -File (Join-Path $d '.harness\derive\stage-edit.ps1') -Root $d -Step '1.0' -Verify 'node --test x.mjs' -NoModel 2>&1 | Out-String
$edExit = $LASTEXITCODE
$pj2 = Get-Content -LiteralPath (Join-Path $d '.harness\project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$hasPlan = Select-String -LiteralPath (Join-Path $d 'events.jsonl') -Pattern 'plan edit, applied without signature' -Quiet
# --- 21y. [P3] finish-step 拒绝关闭 VOID 的步骤 ---
# 2026-11-17：1.1 的 30 个用例被判 real_test=false → verify 三态是 VOID，而旧版
# finish-step 只看 exit=0 就会照常关步、推进 current_step。这条钉住"不许关"。
$d = New-Fixture 'voidclose'
Seed-Project $d '{"stages":[{"id":"1.0","goal":"a","generates":["a.py"],"verify":"echo ok","risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 'a.py') -Value "print(1)`n" -Encoding UTF8
$oVC = & pwsh -NoProfile -File (Join-Path $d '.harness\derive\finish-step.ps1') -Root $d -Step '1.0' -Quiet 2>&1 | Out-String
$vcExit = $LASTEXITCODE
$vcLocal = Get-Content -LiteralPath (Join-Path $d '.harness\local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Result 'finish_refuses_void' (($vcExit -eq 3) -and ($oVC -match 'REFUSED') -and ([string]$vcLocal.current_step -ne 'done')) 'VOID verify cannot close a step (exit 3, current_step not advanced)'
Add-Result 'stage_edit_free' (($edExit -eq 0) -and ([string]$pj2.stages[0].verify -eq 'node --test x.mjs') -and $hasPlan -and ($oSE -match '已生效')) 'edit applies with no confirmation; one plan_edit lands in the ledger'

# --- 21y2. [P3] before 图落在别步目录时，按 generates 认领 ---
# 2026-11-18：插步 1.2.1 的活是在 current_step 已被推到 1.3 之后做的，PreToolUse 按
# current_step 落盘 → before 图进了 docs/_snap/1.3/ → finish-step 1.2.1 报
# 「no snapshot manifest」并把 diff 记成 0（真项目的 docs/_diff/1.2.1 至今不存在）。
# 事件与哈希都在，错的只是 step 标签。这条钉住：本步没有自己的 before 图时，按
# generates 从别步认领、写 diff、并把来源打在屏幕上（认领必须看得见）。
$d = New-Fixture 'snapadopt'
Seed-Project $d '{"stages":[{"id":"1.0","goal":"base","generates":["a.py"],"verify":"t","risk":"L1"},{"id":"1.0.1","goal":"insert","generates":["c.py"],"verify":"t","risk":"L1"},{"id":"1.1","goal":"next","generates":["b.py"],"verify":"t","risk":"L1"}]}' '1.1'
Set-Content -LiteralPath (Join-Path $d 'c.py') -Value "print('new')`n" -Encoding UTF8
$snapOther = Join-Path $d 'docs\_snap\1.1'
New-Item -ItemType Directory -Force -Path $snapOther | Out-Null
Set-Content -LiteralPath (Join-Path $snapOther 'c.py.before') -Value "print('old')`n" -Encoding UTF8
'{ "c.py": { "first_tool": "Edit", "at": "2026-11-18T01:00:00.000Z", "before": "c.py.before" } }' |
    Set-Content -LiteralPath (Join-Path $snapOther '_manifest.json') -Encoding UTF8
Append-Evt $d -Event tool_use -Step '1.1' -Data @{ file = 'c.py'; sha256 = ('a' * 64); before_sha256 = '' }
$oSF = & pwsh -NoProfile -File (Join-Path $d '.harness\derive\finish-step.ps1') -Root $d -Step '1.0.1' -SkipVerify 2>&1 | Out-String
$sfExit = $LASTEXITCODE
$sfDiff = Test-Path -LiteralPath (Join-Path $d 'docs\_diff\1.0.1\c.py.diff') -PathType Leaf
Add-Result 'finish_manifest_adopt' (($sfExit -eq 0) -and ($oSF -match 'MANIFEST') -and $sfDiff -and -not (Test-Path -LiteralPath (Join-Path $d 'docs\_snap\1.0.1'))) 'before-image filed under another step is adopted by generates (diff written, source printed)'

# --- 21a/21b 已移除：worktree + merge-gate（隔离区与合并门）---
# 这两个场景曾经验证"小 diff+证据齐自动合并 / 无证据必须人合"。2026-11-17 决定
# 把这两道门整个拿掉：它们防的是"无人看管时 agent 把大改动推上主线"，而这个项目是
# 单人 relay、每步都有人看；实际运行三轮的收益是 0，代价是 4 次卡点/绕行/死锁，
# 外加一个记账盲区——merge-gate 用 Copy-Item 落回活树，宿主 hook 看不见，于是
# 落地的代码没有 before/after、没有 diff、"谁批准的"也不在账本里。
# 拿掉之后写入只剩一条路（agent 直接改活树 -> hook 落账），账本从结构上不会缺。
# 场景数从 36 降到 34。少即是多：验证不了收益的机制，不要留在自检里假装有人测。

# --- 21c. [P1] worker-env strips secrets + worker git identity ---
$env:VIBE_SECRET = 'supersecretvalue'
$oW = & pwsh -NoProfile -File (Join-Path $KitDerive 'worker-env.ps1') -Run 'Write-Output $env:VIBE_SECRET; Write-Output $env:GIT_AUTHOR_NAME' 2>&1 | Out-String
Remove-Item Env:VIBE_SECRET -ErrorAction SilentlyContinue
Add-Result 'worker_env_strip' (($oW -notmatch 'supersecretvalue') -and ($oW -match 'vibe-worker')) 'secret stripped; worker git identity set'

# --- 21d. [P2] recover resumes active, not redo done ---
$d = New-Fixture 'recover'
Seed-Project $d '{"stages":[{"id":"1.0","goal":"a","generates":["a.py"],"verify":"python t.py","risk":"L1"},{"id":"2.0","goal":"b","generates":["b.py"],"verify":"t","risk":"L1"}]}'
Set-Content -LiteralPath (Join-Path $d 't.py') -Value "import unittest`nclass T(unittest.TestCase):`n    def test_ok(self): self.assertTrue(True)`nif __name__ == '__main__':`n    unittest.main()`n" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $d 'a.py') -Value "print(1)`n" -Encoding UTF8
$null = & pwsh -NoProfile -File (Join-Path $d '.harness\derive\verify.ps1') -Root $d -Step '1.0' 2>&1
Append-Evt $d -Event step_advance -Step '1.0' -Data @{}
Append-Evt $d -Event tool_use -Step '2.0' -Data @{ file='b.py'; sha256=('a'*64) }
$oR = Run-Detector $d 'recover'
# 2026-11-20：done 的口径交给 status（旧版按 step_advance 的 $e.step 记，多算下一步——
# 真账本上 recover 报 done=[…,2.0.4] 而 status 说 2.0.4 未验证）。所以这条 fixture
# 必须让 1.0 真的跑过 verify，否则它测的是旧语义。
Add-Result 'recover_resume' (($oR -match 'active=2\.0') -and ($oR -match 'done=\[1\.0\]')) 'recover 与 status 同口径：1.0 真验证过才算 done，active 指向 2.0'

# --- 21e. [P2] handoff-check good vs bad ---
$good = Join-Path $env:TEMP ('ho-good-'+[guid]::NewGuid().ToString('N')+'.md')
$bad  = Join-Path $env:TEMP ('ho-bad-'+[guid]::NewGuid().ToString('N')+'.md')
@'
step: 1.0
produced:
  - "cmd:pytest tests/t.py:5 passed, exit 0"
decisions:
  - "why: x"
deviations: []
uncertainty: []
residual: []
'@ | Set-Content $good -Encoding UTF8
'step: 1.0' | Set-Content $bad -Encoding UTF8
$oG = & pwsh -NoProfile -File (Join-Path $KitDerive 'handoff-check.ps1') -File $good 2>&1 | Out-String
$oB = & pwsh -NoProfile -File (Join-Path $KitDerive 'handoff-check.ps1') -File $bad 2>&1 | Out-String
Remove-Item $good,$bad -Force -ErrorAction SilentlyContinue
Add-Result 'handoff_check' (($oG -match 'problems=0') -and ($oB -match 'missing:produced')) 'good card passes; missing fields flagged'

# --- 21f. [P2] review two-layer ---
$d = New-Fixture 'review'
Seed-Project $d '{"stages":[{"id":"1.0","goal":"a","generates":["a.py"],"verify":"t","risk":"L1"}]}'
# 层1 现在用与 verify 相同的三态口径（exit=0 且非 trivial 且 real_test），
# 所以夹具必须喂一条"真能失败"的命令：有项目文件在场，python t.py 才算 real_test。
Set-Content -LiteralPath (Join-Path $d 't.py') -Value "print(1)`n" -Encoding UTF8
Append-Evt $d -Event verify -Step '1.0' -Cmd 'python t.py'
$rv = Join-Path $env:TEMP ('rv-'+[guid]::NewGuid().ToString('N')+'.json')
'{"design_checked":true,"boundary_checked":true,"tests_real":true,"honest":true}' | Set-Content $rv -Encoding UTF8
$oRv = & pwsh -NoProfile -File (Join-Path $d '.harness\derive\review.ps1') -Root $d -Step '1.0' -ReviewFile $rv 2>&1 | Out-String
$oRv2 = & pwsh -NoProfile -File (Join-Path $d '.harness\derive\review.ps1') -Root $d -Step '1.0' 2>&1 | Out-String
Remove-Item $rv -Force -ErrorAction SilentlyContinue
Add-Result 'review_two_layer' (($oRv -match 'pass=True') -and ($oRv2 -match 'pass=False')) 'layer1+layer2 pass; missing layer2 fails'

# --- 21g. [P3] guard blocks destructive + ledger write, allows normal ---
# Candidate order is the real deployment order: the stable host location first
# (that is the copy that actually runs), then the project's pinned reference copy,
# then the kit's own template. The old version fell back to a hardcoded absolute
# path inside another project - so this scenario silently depended on a directory
# nobody promised would still exist.
$guard = ''
foreach ($cand in @(
        (Join-Path $env:USERPROFILE '.claude\hooks\harness\guard.ps1'),
        (Join-Path $KitDerive '..\..\.harness\hooks\guard.ps1'),
        (Join-Path $KitDerive '..\hooks\guard.ps1')
    )) {
    if (Test-Path -LiteralPath $cand -PathType Leaf) { $guard = (Resolve-Path -LiteralPath $cand).Path; break }
}
if ([string]::IsNullOrWhiteSpace($guard)) { Add-Result 'guard_host' $false 'no guard.ps1 found in host home, project .harness\hooks, or kit hooks - deny is prompt-only' }
if (-not [string]::IsNullOrWhiteSpace($guard)) {
    '{"tool_name":"Bash","tool_input":{"command":"taskkill /F /IM x.exe"}}' | & pwsh -NoProfile -File $guard 2>&1 | Out-Null
    $g1 = $LASTEXITCODE
    '{"tool_name":"Write","tool_input":{"file_path":"D:/x/events.jsonl"}}' | & pwsh -NoProfile -File $guard 2>&1 | Out-Null
    $g2 = $LASTEXITCODE
    '{"tool_name":"Write","tool_input":{"file_path":"D:/x/scripts/ok.py"}}' | & pwsh -NoProfile -File $guard 2>&1 | Out-Null
    $g3 = $LASTEXITCODE
    '{"tool_name":"mcp__windows_mcp__FileSystem","tool_input":{"path":"D:/x/events.jsonl","mode":"write"}}' | & pwsh -NoProfile -File $guard 2>&1 | Out-Null
    $g6 = $LASTEXITCODE
    # 2026-11-17 收窄后：治理面写入不再由 guard 硬挡，而是下放给 decision-guard 判；
    # 但"项目内 scratch 的递归删除"必须放行——旧版把 agent 清理自己的临时目录也拒了。
    '{"tool_name":"Bash","cwd":"D:/x","tool_input":{"command":"Remove-Item -Recurse -Force .harness\\worktrees\\0.3\\x"}}' | & pwsh -NoProfile -File $guard 2>&1 | Out-Null
    $g7 = $LASTEXITCODE
    '{"tool_name":"Bash","cwd":"D:/x","tool_input":{"command":"Remove-Item -Recurse -Force C:\\Windows\\System32"}}' | & pwsh -NoProfile -File $guard 2>&1 | Out-Null
    $g8 = $LASTEXITCODE
    Add-Result 'guard_host' (($g1 -eq 2) -and ($g2 -eq 2) -and ($g3 -eq 0) -and ($g6 -eq 2) -and ($g7 -eq 0) -and ($g8 -eq 2)) `
        'irreversible (taskkill/ledger/mcp-ledger/out-of-tree rm) blocked (2); scratch rm + normal write allowed (0)'
}

# --- 21h. [P3] decision-guard：本地白名单零网络放行 + 模型不可用时 fail-open ---
$dg = ''
foreach ($cand in @(
        (Join-Path $env:USERPROFILE '.claude\hooks\harness\decision-guard.ps1'),
        (Join-Path $KitDerive '..\..\.harness\hooks\decision-guard.ps1'),
        (Join-Path $KitDerive '..\hooks\decision-guard.ps1')
    )) {
    if (Test-Path -LiteralPath $cand -PathType Leaf) { $dg = (Resolve-Path -LiteralPath $cand).Path; break }
}
if ([string]::IsNullOrWhiteSpace($dg)) {
    Add-Result 'decision_guard' $false 'no decision-guard.ps1 found - the classifier seat is empty'
}
else {
    '{"tool_name":"Bash","cwd":"D:/x","tool_input":{"command":"ls -la"}}' | & pwsh -NoProfile -File $dg 2>&1 | Out-Null
    $d1 = $LASTEXITCODE
    '{"tool_name":"Write","tool_input":{"file_path":"D:/x/client/a.py"}}' | & pwsh -NoProfile -File $dg 2>&1 | Out-Null
    $d2 = $LASTEXITCODE
    # 模型不可达时必须放行并留痕（fail-open），否则内置分类器那句"全停摆"会重演。
    $old = $env:DECISION_ENDPOINT
    $env:DECISION_ENDPOINT = 'http://127.0.0.1:1/none'
    $d3out = '{"tool_name":"Bash","cwd":"D:/x","tool_input":{"command":"some-unknown-tool --flag"}}' | & pwsh -NoProfile -File $dg 2>&1 | Out-String
    $d3 = $LASTEXITCODE
    if ($null -eq $old) { Remove-Item Env:DECISION_ENDPOINT -ErrorAction SilentlyContinue } else { $env:DECISION_ENDPOINT = $old }
    Add-Result 'decision_guard' (($d1 -eq 0) -and ($d2 -eq 0) -and ($d3 -eq 0) -and ($d3out -match 'unavailable')) `
        'fast-path allow (0) with no network; fail-open on unreachable model (0 + stderr note)'
}

# --- 15. install self-check: a fresh machine must reproduce acceptance -----
# Only meaningful from the kit tree (kit\install.ps1 next to derive\). It runs
# the whole installer into %TEMP% and asserts the four acceptance numbers.
# Deployed projects skip it silently - they have no kit\install.ps1 by design.
if (-not $SkipInstallSelfTest) {
    $kitInstall = Join-Path (Split-Path $KitDerive -Parent) 'install.ps1'
    if (Test-Path -LiteralPath $kitInstall -PathType Leaf) {
        $instDir = Join-Path $env:TEMP ('harness-install-selftest-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Force -Path $instDir | Out-Null
        $script:fixtures += $instDir
        $o = & pwsh -NoProfile -File $kitInstall -ProjectRoot $instDir -By 'canary-selftest' -SkipScheduledTask 2>&1 | Out-String
        $okInstall = ($LASTEXITCODE -eq 0) -and ($o -match 'ACCEPTANCE') -and ($o -match 'manifest      :') -and ($o -match 'genesis       :')
        Add-Result 'install_selftest' $okInstall $(if ($okInstall) { 'installer reproduces the full acceptance on a clean directory' } else { 'install.ps1 FAILED on a fresh dir - the portable package cannot be trusted: ' + (($o -split "`r?`n" | Where-Object { $_ -match 'FAILED' } | Select-Object -First 1)) })
    }
    elseif (-not $Quiet) {
        Write-Host '  [SKIPPED] install_selftest (deployed .harness tree has no kit\install.ps1 - by design)' -ForegroundColor DarkGray
    }
}

# ================================================================ cleanup + report
foreach ($f in $fixtures) {
    try { Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction Stop } catch { }
}

$dead = @($results | Where-Object { -not $_.ok })
Write-Host ''
Write-Host ("canary: {0}/{1} detectors fired" -f ($results.Count - $dead.Count), $results.Count) -ForegroundColor $(if ($dead.Count -eq 0) { 'Green' } else { 'Red' })
if ($dead.Count -gt 0) {
    Write-Host 'DEAD detectors - a safety system that does not react to a known fault is decoration:' -ForegroundColor Red
    foreach ($x in $dead) { Write-Host ("  x {0}: {1}" -f $x.what, $x.detail) -ForegroundColor Red }
    exit 1
}
exit 0