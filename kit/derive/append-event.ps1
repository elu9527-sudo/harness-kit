<#
.SYNOPSIS
  Append a hash-chained event to events.jsonl. Two modes: run-and-record a verify,
  or record a decision event that other tooling can trigger on.

.DESCRIPTION
  This is the ONLY writer for decision events. Without it, trigger.ps1's T1/T5/T6/
  T7-b/contract/anchor rules can never fire, because nothing produces those events.

  Mode 1 - verify (default):
      append-event.ps1 -Event verify -Cmd "python -m pytest tests/x.py -q"
    Runs the command itself, records the real exit code. The executor cannot forge it.

  Mode 2 - decision (anything else):
      append-event.ps1 -Event deviate -DataJson '{"what":"...","why":"...","cost":"...","alternatives":["a","b"]}'
      append-event.ps1 -Event skip -Step 1.3 -DataJson '{"step":"1.3","why":"...","impact":"...","revisit":"..."}'
      append-event.ps1 -Event blocker_open -DataJson '{"id":"B-1","why":"..."}'
      append-event.ps1 -Event gate -DataJson '{"level":"L2","status":"approved","by":"human"}'
      append-event.ps1 -Event anchor -DataJson '{"name":"git","value":"unavailable","why":"no .git"}'
      append-event.ps1 -Event contract_change -DataJson '{"file":".harness/project.json","before_sha256":"...","after_sha256":"...","why":"..."}'
    In this mode -DataJson is copied into data verbatim after JSON validation.

  Actor is derived from the event type:
      verify          -> verify
      gate            -> human
      anchor          -> hermes
      everything else -> claude

  Exit codes:
    0  appended and chain verified (verify passed, or decision recorded)
    1  chain verification failed after append
    2  bad arguments / profile missing / invalid DataJson
    3  verify ran and failed (event still appended with exit=non-zero)

.EXAMPLE
  pwsh -File append-event.ps1 -Cmd ".venv\Scripts\python.exe -c 'import yaml'"
  pwsh -File append-event.ps1 -Event deviate -DataJson '{"what":"9335 被占","why":"遗留 Chrome","cost":"换端口","alternatives":["9340"]}'
#>
[CmdletBinding()]
param(
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),

    [ValidateSet('verify', 'tool_use', 'deviate', 'skip', 'blocker_open', 'blocker_close', 'contract_change', 'gate', 'anchor', 'step_advance', 'unrecorded_write', 'plan_edit', 'file_removed')]
    [string] $Event = 'verify',

    # Who produced this event. Defaults are derived from the event type, which is
    # right for the three roles but wrong for automation: a baseline anchor is
    # written by validate-profile, not by Hermes. Attributing a script's write to
    # a role makes the ledger confidently say something false about who acted.
    [ValidateSet('verify', 'claude', 'hermes', 'human', 'hook', 'script')]
    [string] $Actor = '',

    # A stage's verify is a LIST of commands, not one. Real acceptance is
    # "migrate exits 0" AND "running it again is a no-op" AND "the tables are
    # the expected shape" - three separate claims. With a single string the
    # profile could only hold one of them, so the other two lived in the coach's
    # chat message and were run by hand in a terminal, which is how a step ends
    # up "verified" with nothing in the ledger. Accepting an array puts all of
    # them where the evidence already lives.
    [string[]] $Cmd = @(),
    [string] $DataJson = '',
    # `pwsh -File script.ps1 -DataJson '{"a":"b"}'` does NOT deliver that string:
    # the child process re-parses the command line and the JSON's double quotes
    # are gone by the time the script sees it ("Unexpected character ... Path
    # 'level'"). That is a property of how PowerShell passes arguments to a new
    # process, not a bug in this script - but it is a trap that lands on whoever
    # is told to "just run this one line", which is exactly the audience for a
    # signature step. Writing the JSON to a file and passing the path sidesteps
    # the whole class: one path token, nothing to re-quote.
    [string] $DataJsonFile = '',
    [string] $Step = '',
    [int] $TimeoutSec = 600,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$eventsPath = Join-Path $Root 'events.jsonl'
$localPath  = Join-Path $Root '.harness\local.json'
$profPath   = Join-Path $Root '.harness\project.json'

if (-not (Test-Path -LiteralPath $profPath -PathType Leaf)) {
    Write-Host "[FAIL] project.json not found: $profPath" -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------- resolve step
if ([string]::IsNullOrWhiteSpace($Step)) {
    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        try {
            $local = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $sp = $local.PSObject.Properties['current_step']
            if ($null -ne $sp) { $Step = [string]$sp.Value }
        }
        catch { }
    }
    if ([string]::IsNullOrWhiteSpace($Step)) { $Step = 'unknown' }
}

# ---------------------------------------------------------------- trivial detection
function Test-TrivialCommand {
    param([string] $Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    $c = $Command.Trim()
    if ($c -match '\|') { return $false }
    $segments = @($c -split '&&|\|\||;' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 0) { return $false }
    $patterns = @(
        '^(true|:)$'
        '^exit\s+0$'
        '^cmd(\.exe)?\s*/c\s+exit\s+0$'
        '^echo\b'
        '^printf\b'
        '^Write-Output\b'
        '^Write-Host\b'
        '^cd\s+\S+$'
        '^python(\d|\.\d+)?\s+-c\s+["'']?\s*pass\s*["'']?$'
        '^python(\d|\.\d+)?\s+-c\s+["'']?\s*print\(.*\)\s*["'']?$'
        '^python(\d|\.\d+)?\s+-c\s+["'']?\s*(import\s+sys\s*;\s*)?sys\.exit\(0\)\s*["'']?$'
    )
    foreach ($seg in $segments) {
        $hit = $false
        foreach ($pat in $patterns) { if ($seg -match $pat) { $hit = $true; break } }
        if (-not $hit) { return $false }
    }
    return $true
}

function Test-RealTest {
    <#
      Can this command establish anything about THIS project?

      The previous version opened with:
          if ($Command -notmatch 'pytest|unittest|nose2?|tox') { return $true }
      so every command that was not a Python test runner was declared a real test
      without further inspection. Observer #4 measured the result: 18 verify events,
      zero of them containing 'pytest', so real_test was true every single time and
      had never once distinguished anything. PASS was therefore decided by `trivial`
      alone, and the third state in the three-state verdict was decorative.

      The question that actually matters is "does this command exercise project
      code?", not "does it use pytest". So: a project file that exists and is not
      empty, or an inline import of a module that exists in the project, or a
      tool-mode check known to fail on real problems. A bare --version or an
      existence probe cannot fail for any reason that has to do with this project,
      so it does not count.
    #>
    param([string] $Command, [string] $ProjectRoot)

    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    $c = $Command.Trim()

    # A file the command names, that lives in the project and has real content.
    # Token-split rather than a path charset regex: the first cut used
    # [A-Za-z0-9_\-\.\\/] and silently failed on every absolute Windows path
    # (the ':' matched none of it) and every CJK path component - which is most
    # of the paths in this very project.
    foreach ($tok in ($c -split '[\s"\x27]+')) {
        $rel = $tok.TrimEnd(':', ',', ';', ')', ']', '>').TrimStart('(', '[', '@')
        if ($rel -notmatch '\.(py|ps1|mjs|js|sh|cmd)$') { continue }
        if ($rel -match '^https?://') { continue }
        $abs = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $ProjectRoot $rel }
        if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }
        if ((Get-Item -LiteralPath $abs).Length -le 0) { continue }
        try {
            $body = Get-Content -LiteralPath $abs -Raw -Encoding UTF8
            $stripped = ($body -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and -not $_.StartsWith('#') }) -join ''
            if ($stripped.Length -gt 0) { return $true }
        }
        catch { }
    }

    # Inline code that imports a module the project actually ships. `import yaml`
    # is a dependency probe - it says the venv has a wheel, not that our code works
    # - so the module has to resolve inside the project tree.
    foreach ($m in [regex]::Matches($c, '(?:^|\s|-c\s+["'']?)(?:import|from)\s+([A-Za-z_][A-Za-z0-9_\.]*)')) {
        $mod = $m.Groups[1].Value
        $head = ($mod -split '\.')[0]
        $asFile = Join-Path $ProjectRoot ("$head.py")
        $asDir  = Join-Path $ProjectRoot $head
        if ((Test-Path -LiteralPath $asFile -PathType Leaf) -or (Test-Path -LiteralPath $asDir -PathType Container)) {
            return $true
        }
    }

    # Tool-mode checks that fail on real defects rather than merely reporting a
    # version. pip check validates the installed dependency graph, which a broken
    # requirements.lock genuinely fails.
    if ($c -match '-m\s+(pip\s+check|pipenv|poetry\s+check|mypy|flake8|pylint|ruff|bandit)') { return $true }

    # 测试运行器：跑的是项目里的用例，本来就会红。
    # 2026-11-17 补：`python -m unittest driver.test_adapter` 这种形态之前掉进了
    # "查不到项目文件、又不是 -m pip check" 的空档，被判 real_test=false → verify 永久
    # VOID，连 30 个用例全绿也建立不了任何东西。把运行器本身认出来，比去猜它跑了哪个
    # 文件更稳（模块名不是路径，模块名带点、也不一定对应当前目录）。
    if ($c -match '-m\s+(unittest|pytest|doctest|nose2?|tox)\b') { return $true }
    if ($c -match '(^|\s)(pytest|py\.test|tox)\b') { return $true }
    if ($c -match '\bnode\s+--test\b|\bnpm\s+(run\s+)?test\b|\bnpx\s+(jest|vitest|mocha)\b') { return $true }
    if ($c -match '\bgo\s+test\b|\bcargo\s+test\b|\bdotnet\s+test\b|\bmvn\s+test\b') { return $true }

    # `--version` / `--help` / bare interpreter: cannot fail for a reason that has
    # anything to do with this project.
    if ($c -match '(--version|--help|-V\b|-h\b)\s*$') { return $false }

    return $false
}

# ---------------------------------------------------------------- tail state
# Deliberately NOT read here any more. The tail must be read inside the write
# lock: a value read before acquiring it can already be stale, which is exactly
# how two writers produced the same seq. See the append section below.

# ---------------------------------------------------------------- build the event
# PowerShell variable names are case-insensitive, so $ACTOR, $Actor and $actor
# are ONE variable. A local $ACTOR hashtable silently overwrites the -Actor
# parameter and trips its ValidateSet at call time. Keep every name distinct.
$defaultActors = @{
    verify = 'verify'; gate = 'human'; anchor = 'hermes'; tool_use = 'script'
    # the step key that every downstream rule joins on had exactly one writer,
    # and it was invisible: finish-step advanced local.json while the ledger kept
    # filing later work under the finished stage. step_advance makes the handover
    # itself an auditable fact (observer #4 O4-02).
    step_advance = 'script'
    # the sweep's own observation: a machine fact ("disk moved without a record"),
    # never an explanation - explaining stays a human/hermes act via record-edit
    unrecorded_write = 'script'
}
$actorValue = if (-not [string]::IsNullOrWhiteSpace($Actor)) { $Actor }
              elseif ($defaultActors.ContainsKey($Event)) { $defaultActors[$Event] }
              else { 'claude' }
# tool_use is routine by nature even when a person or a script writes it. Filing
# a file write as a 'decision' would let it satisfy rules that look for decisions
# (T9 handoff), i.e. an ordinary edit would silently close a handoff obligation.
$kind  = if ($Event -in @('verify', 'tool_use', 'step_advance', 'unrecorded_write', 'plan_edit', 'file_removed')) { 'routine' } else { 'decision' }

$data    = $null
$exitCode = $null

if ($Event -eq 'verify') {
    $CmdList = @($Cmd | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($CmdList.Count -eq 0) {
        Write-Host '[FAIL] -Event verify requires -Cmd' -ForegroundColor Red
        exit 2
    }

    # Every command in the list must pass. Stops at the first failure: if the
    # primary acceptance fails, the follow-up checks are measuring a broken
    # environment and their verdicts would be noise dressed as evidence.
    # trivial/real_test are about the WHOLE list: it is only trivial if every
    # command is incapable of failing, and it is a real test if any command is.
    # in-toto's link attestation binds a command to materials (inputs before)
    # and products (outputs after) - "exit 0" alone says nothing about WHICH
    # bytes the verdict was about. Snapshot the stage's declared generates both
    # sides of the run, so a PASS in the ledger also proves what the artifacts
    # were at the moment of adjudication. Cap 40 files; a hash of a missing file
    # is '' and reads as absent.
    $genFiles = @()
    try {
        $profV = Get-Content -LiteralPath $profPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $stgV = @($profV.stages) | Where-Object { [string]$_.id -eq $Step } | Select-Object -First 1
        if ($null -ne $stgV -and $null -ne $stgV.PSObject.Properties['generates']) {
            $genFiles = @($stgV.generates | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 40)
        }
    }
    catch { }
    $beforeSha = @{}
    foreach ($g in $genFiles) {
        $gp = if ([System.IO.Path]::IsPathRooted($g)) { $g } else { Join-Path $Root $g }
        $beforeSha[$g] = Get-FileSha256Hex -Path $gp
    }

    # ---- universe snapshot (minimal "world model", observer #6 items 875/831) ----
    # products only covers declared generates. On 875 the re-verify of 3.1.1 ran
    # `init_db.py --migrate` twice and WROTE data/price_watch.db - the verdict
    # moved the world while the ledger said "products unchanged". Snapshot the
    # whole project source space before and after the run; anything the stage
    # did not declare but moved anyway lands in data.universe_changed. Budgets
    # mirror the node pre-tool manifest (same extension set, same skip dirs).
    $GetUniverse = {
        param([string] $R)
        $exts = @('.py','.js','.mjs','.ts','.sql','.yaml','.yml','.json','.md','.toml','.cfg','.ini','.txt','.ps1','.sh')
        $skip = @('node_modules','.venv','venv','__pycache__','.git','dist','build','.harness','_snap')
        $map = @{}
        $trunc = $false
        $dirs  = [System.Collections.Generic.Queue[object]]::new()
        $dirs.Enqueue(@('', $R))
        $n = 0
        while ($dirs.Count -gt 0) {
            $top = $dirs.Peek()
            # Dequeue EMITS the element; without [void] every iteration leaks an
            # array into the pipeline and the function's return value arrives as
            # an object[] that has no .map - the exact death this fixture caught.
            [void]$dirs.Dequeue()
            $relD = [string]$top[0]; $absD = [string]$top[1]
            if ($n -ge 400) { $trunc = $true; break }
            $ents = $null
            try { $ents = @(Get-ChildItem -LiteralPath $absD -Force -ErrorAction Stop) } catch { continue }
            foreach ($it in $ents) {
                # $true/$false, never bare true/false: inside a statement block a
                # bare token is a COMMAND lookup - the same 400-boundary branch cost
                # all stages their verify ledgering for 18h (coach found it 11-10;
                # canary fixtures were always under budget, so it never executed).
                if ($n -ge 400) { $trunc = $true; break }
                if ($it.PSIsContainer) {
                    if ($skip -contains $it.Name) { continue }
                    if ($relD.Split('/').Count -ge 8) { $trunc = $true; continue }
                    $dirs.Enqueue(@(($relD + '/' + $it.Name).TrimStart('/'), $it.FullName))
                    continue
                }
                $dot = $it.Name.LastIndexOf('.')
                if ($dot -lt 0) { continue }
                if ($exts -notcontains $it.Extension.ToLowerInvariant()) { continue }
                if ($it.Length -gt 2MB) { continue }
                $relP = ($relD + '/' + $it.Name).TrimStart('/')
                $map[$relP] = Get-FileSha256Hex -Path $it.FullName
                $n++
            }
        }
        return [pscustomobject]@{ map = $map; truncated = $trunc }
    }
    $uniB = & $GetUniverse $Root

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = 0
    $checks   = @()
    $failedAt = -1
    $output   = ''
    # On a zh-CN Windows host Python's stdout defaults to gbk while this shell decodes
    # captured native output as utf-8, so every verify of a Chinese project recorded
    # its stdout_tail as mojibake - the reason was in the ledger, just unreadable,
    # which is the same as not recording it. Pin the child to utf-8 so both ends
    # agree. PYTHONIOENCODING only affects Python; other verifies are untouched.
    $prevPyIO = $env:PYTHONIOENCODING
    Push-Location -LiteralPath $Root
    try {
        $env:PYTHONIOENCODING = 'utf-8'
        for ($ci = 0; $ci -lt $CmdList.Count; $ci++) {
            $one = $CmdList[$ci]
            if (-not $Quiet) { Write-Host ("`n[run {0}/{1}] {2}" -f ($ci + 1), $CmdList.Count, $one) -ForegroundColor Cyan }
            $out1 = ''
            $ec1  = 0
            try {
                $out1 = & pwsh -NoProfile -Command $one 2>&1 | Out-String
                $ec1  = $LASTEXITCODE
            }
            catch {
                $out1 = $_.Exception.Message
                $ec1  = 1
            }
            $checks += [pscustomobject]@{ cmd = $one; exit = $ec1 }
            $output += $out1
            if ($ec1 -ne 0) { $exitCode = $ec1; $failedAt = $ci; break }
        }
    }
    finally {
        Pop-Location
        if ($null -eq $prevPyIO) { Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue }
        else { $env:PYTHONIOENCODING = $prevPyIO }
    }
    $sw.Stop()
    $uniA = & $GetUniverse $Root
    # diff the universe, minus what products already explains (declared generates)
    $uniChanged = [System.Collections.Generic.List[object]]::new()
    $genSet = @{}
    foreach ($g in $genFiles) { $genSet[(($g -replace '\\', '/').TrimStart('/'))] = $true }
    $allKeys = @($uniB.map.Keys) + @($uniA.map.Keys) | Sort-Object -Unique
    foreach ($k in $allKeys) {
        if ($genSet.ContainsKey([string]$k)) { continue }
        $b0 = [string]$uniB.map[$k]; $a0 = [string]$uniA.map[$k]
        if ($b0 -eq $a0) { continue }
        $uniChanged.Add([pscustomobject]@{
            file   = [string]$k
            before = $b0
            after  = $a0
            state  = $(if ($b0 -eq '') { 'created' } elseif ($a0 -eq '') { 'removed' } else { 'modified' })
        })
    }
    $uniOut = @($uniChanged | Select-Object -First 20)
    $uniTrunc = ($uniChanged.Count -gt 20) -or $uniB.truncated -or $uniA.truncated

    $trivial  = $true
    $realTest = $false
    foreach ($one in $CmdList) {
        if (-not (Test-TrivialCommand -Command $one)) { $trivial = $false }
        if (Test-RealTest -Command $one -ProjectRoot $Root) { $realTest = $true }
    }

    if (-not $Quiet) {
        $tail = ($output -split "`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 8) -join "`n"
        if ($tail) { Write-Host $tail -ForegroundColor DarkGray }
        foreach ($c in $checks) {
            $colour = if ($c.exit -eq 0) { 'DarkGray' } else { 'Red' }
            Write-Host ("  [{0}] {1}" -f $c.exit, $c.cmd) -ForegroundColor $colour
        }
        Write-Host ("[exit] {0}   {1}/{2} checks   trivial={3}  real_test={4}  {5}ms" -f $exitCode, $checks.Count, $CmdList.Count, $trivial, $realTest, [int]$sw.ElapsedMilliseconds) `
            -ForegroundColor $(if ($exitCode -eq 0 -and -not $trivial -and $realTest) { 'Green' } else { 'Yellow' })
    }

    # 全量输出落盘，账本只留指针。分层理由（2026-11-17 定）：
    #   · 账本要能一屏看完 -> 只放摘要（命令、exit、耗时、products 的 sha）
    #   · 半年后还要能复盘 -> 全量必须留着，而磁盘几乎不要钱
    #   · 指针让两者连起来：事件里一条 stdout_ref，指向 docs/_verify/<step>/ 下的文件
    # stdout_tail 仍然保留 1KB——不装文件也能立刻看到为什么红。
    $stdoutRef = ''
    try {
        $safeStep = ($Step -replace '[^\w\.\-]', '_')
        if ([string]::IsNullOrWhiteSpace($safeStep)) { $safeStep = 'unknown' }
        $vdir = Join-Path (Join-Path $Root 'docs\_verify') $safeStep
        New-Item -ItemType Directory -Force -Path $vdir | Out-Null
        $vname = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.log'
        [System.IO.File]::WriteAllText((Join-Path $vdir $vname), $output, (New-Object System.Text.UTF8Encoding($false)))
        $stdoutRef = 'docs/_verify/' + $safeStep + '/' + $vname
    }
    catch { $stdoutRef = '' }

    $data = [ordered]@{
        cmd         = ($CmdList -join ' ;; ')
        exit        = $exitCode
        trivial     = $trivial
        real_test   = $realTest
        duration_ms = [int]$sw.ElapsedMilliseconds
        target      = $Step
        checks      = @($checks)
        checks_run  = $checks.Count
        checks_total= $CmdList.Count
        failed_at   = $failedAt
        # 全量输出的落点（可能为空：写盘失败不该让验证本身失败）
        stdout_ref  = $stdoutRef
        # Keep the last ~1KB of output. Without it a FAIL records only its exit
        # code, and a red verify becomes unexplainable after the fact: on
        # 14:06:38 there is a verify at exit=1 whose cause (a relative
        # interpreter path resolved against the wrong cwd) could only be
        # reconstructed from file timestamps, not from the ledger. Evidence you
        # cannot re-read is not much better than no evidence.
        stdout_tail = $(if ($output.Length -gt 1024) { $output.Substring($output.Length - 1024) } else { $output })
        # what the declared outputs actually were at verdict time (see the
        # in-toto-style snapshot above); [] when the stage declares no generates
        products = @(foreach ($g in $genFiles) {
            $gp = if ([System.IO.Path]::IsPathRooted($g)) { $g } else { Join-Path $Root $g }
            $af = Get-FileSha256Hex -Path $gp
            $bf = [string]$beforeSha[$g]
            $st = if ($bf -eq '' -and $af -ne '') { 'created' }
                  elseif ($bf -ne '' -and $af -eq '') { 'removed' }
                  elseif ($bf -eq $af) { 'unchanged' }
                  else { 'modified' }
            [pscustomobject]@{ file = ($g -replace '\\', '/'); before = $bf; after = $af; state = $st }
        })
        # undeclared files the verdict itself moved (world changes; [] = world quiet)
        universe_changed = $uniOut
        universe_truncated = [bool]$uniTrunc
    }
}
else {
    if (-not [string]::IsNullOrWhiteSpace($DataJsonFile)) {
        if (-not (Test-Path -LiteralPath $DataJsonFile -PathType Leaf)) {
            Write-Host "[FAIL] -DataJsonFile not found: $DataJsonFile" -ForegroundColor Red
            exit 2
        }
        $DataJson = (Get-Content -LiteralPath $DataJsonFile -Raw -Encoding UTF8)
    }
    if ([string]::IsNullOrWhiteSpace($DataJson)) {
        Write-Host "[FAIL] -Event $Event requires -DataJson or -DataJsonFile" -ForegroundColor Red
        exit 2
    }
    try { $parsed = $DataJson | ConvertFrom-Json }
    catch {
        Write-Host "[FAIL] -DataJson is not valid JSON: $($_.Exception.Message)" -ForegroundColor Red
        # The parse error alone sends people to the JSON looking for a typo, and the
        # JSON is usually fine: the token lost its quotes on the way from a clipboard
        # into argv. Say that, and name the way out, instead of letting the human
        # retype the same line and fail identically.
        Write-Host ''
        Write-Host 'This is usually not your JSON. PowerShell re-parses arguments when it' -ForegroundColor Yellow
        Write-Host 'starts a child process, and an interactive paste can strip the double' -ForegroundColor Yellow
        Write-Host 'quotes before this script ever sees them. Two ways that avoid it:' -ForegroundColor Yellow
        Write-Host ''
        if ($Event -eq 'gate') {
            Write-Host '  pwsh -File .harness\derive\sign-gate.ps1 -Level L2 -Why "your reason"' -ForegroundColor Green
            Write-Host '  ^ signs a gate with no JSON at all (quotes/CJK/newlines all safe)' -ForegroundColor DarkGray
            Write-Host ''
        }
        Write-Host '  put the JSON in a file and pass the path:' -ForegroundColor Green
        Write-Host '  pwsh -File .harness\derive\append-event.ps1 -Event '$Event' -DataJsonFile .\gate.json' -ForegroundColor Green
        Write-Host ("  received: {0}" -f $DataJson) -ForegroundColor DarkGray
        exit 2
    }
    if ($parsed -isnot [psobject]) {
        Write-Host '[FAIL] -DataJson must be a JSON object' -ForegroundColor Red
        exit 2
    }
    $data = [ordered]@{}
    foreach ($p in $parsed.PSObject.Properties) { $data[$p.Name] = $p.Value }

    # tool_use exists here for writes that the PostToolUse hook cannot see: a
    # person editing in an IDE, a generator script, a harness maintenance edit.
    # Without this path the only options were "delete the file" or "ignore the
    # C7 drift warning", and the observed history shows which one wins - the
    # human write to 变更记录.md at 13:27:05 was simply never recorded.
    # The digest is computed from disk rather than taken on trust, and the
    # before-image is taken from the ledger, so a hand-recorded write carries the
    # same facts a hook-recorded one does.
    if ($Event -eq 'tool_use') {
        if (-not $data.Contains('file') -or [string]::IsNullOrWhiteSpace([string]$data['file'])) {
            Write-Host '[FAIL] -Event tool_use requires data.file' -ForegroundColor Red
            exit 2
        }
        $fp = Join-Path $Root ([string]$data['file'])
        if (-not $data.Contains('sha256') -or [string]$data['sha256'] -notmatch '^[0-9a-f]{64}$') {
            if (-not (Test-Path -LiteralPath $fp -PathType Leaf)) {
                Write-Host ("[FAIL] -Event tool_use: '{0}' does not exist and no sha256 was given" -f $data['file']) -ForegroundColor Red
                exit 2
            }
            $data['sha256'] = Get-FileSha256Hex -Path $fp
        }
        if (-not $data.Contains('tool')) { $data['tool'] = 'manual' }
        # Who observed this write. tool_use started as a record of what the agent
        # did (written by the PostToolUse hook). It now has three writers - the
        # hook, a maintenance note from a person, and one record per harness file
        # from seal-harness - and by the end of this session 252 of 371 tool_use
        # records were the harness describing itself. Rules that read tool_use as
        # "agent behaviour" (T3 scope creep, T4 rework, C4 rule coverage) were
        # therefore mostly measuring the harness, not the work.
        # The field lets a rule say which it means instead of inferring it from
        # the tool name.
        if (-not $data.Contains('observed_by')) { $data['observed_by'] = 'script' }
        if (-not $data.Contains('before_sha256')) {
            $prevSha = ''
            $evPathT = Join-Path $Root 'events.jsonl'
            if (Test-Path -LiteralPath $evPathT -PathType Leaf) {
                foreach ($e0 in (Read-EventLog -Path $evPathT)) {
                    if ($null -ne $e0.PSObject.Properties['__parse_error']) { continue }
                    if ([string]$e0.event -ne 'tool_use') { continue }
                    $d0 = $e0.PSObject.Properties['data']; if ($null -eq $d0) { continue }
                    $f0 = $d0.Value.PSObject.Properties['file']
                    $s0 = $d0.Value.PSObject.Properties['sha256']
                    if ($null -ne $f0 -and [string]$f0.Value -eq [string]$data['file'] -and $null -ne $s0) {
                        $prevSha = [string]$s0.Value
                    }
                }
            }
            $data['before_sha256'] = $prevSha
        }
    }

    # skip events carry their own step; keep top-level step aligned with it
    if ($Event -eq 'skip' -and $data.Contains('step') -and -not [string]::IsNullOrWhiteSpace([string]$data['step'])) {
        if (-not $Quiet) { Write-Host "[note] skip event: using data.step='$($data['step'])' as the event step" -ForegroundColor DarkGray }
        $Step = [string]$data['step']
    }

    if (-not $Quiet) {
        Write-Host "`n[record] $Event @ step $Step" -ForegroundColor Cyan
        foreach ($k in $data.Keys) { Write-Host ("  {0}: {1}" -f $k, $data[$k]) -ForegroundColor DarkGray }
    }
}

# ---------------------------------------------------------------- append under a lock
# read-tail / compute-hash / append is not atomic. The PostToolUse hook fires
# while a person may also be running append-event, and on 2026-11-07 two of those
# both read seq 473 and both wrote 474: two records with the same seq, a broken
# chain, and a repair that had to rewrite five records. No amount of verification
# catches that after the fact - the write itself has to be serialised.
# A create-exclusive lock file is crude and portable, which is what this needs.
# A lock older than 60s is debris from a killed process and is cleared.
$lockPath = "$eventsPath.lock"
$lockStream = $null
for ($lockTry = 0; $lockTry -lt 100; $lockTry++) {
    try {
        $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        break
    }
    catch {
        try {
            $li = Get-Item -LiteralPath $lockPath -ErrorAction Stop
            if ($li.LastWriteTime -lt (Get-Date).AddSeconds(-60)) {
                Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch { }
        Start-Sleep -Milliseconds 100
    }
}
if ($null -eq $lockStream) {
    Write-Host "[FAIL] could not lock $lockPath within 10s - another writer looks stuck (delete the .lock file if nothing else is appending)" -ForegroundColor Red
    exit 1
}

try {
    $lastSeq = 0
    $lastSelf = ''
    if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
        foreach ($lineT in [System.IO.File]::ReadLines($eventsPath, [System.Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($lineT)) { continue }
            try { $rT = $lineT | ConvertFrom-Json } catch { continue }
            $sqT = $rT.PSObject.Properties['seq'];  if ($null -ne $sqT) { $lastSeq = [int]$sqT.Value }
            $sfT = $rT.PSObject.Properties['self']; if ($null -ne $sfT) { $lastSelf = [string]$sfT.Value }
        }
    }

    $record = [ordered]@{
        v     = 1
        seq   = ($lastSeq + 1)
        at    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        step  = $Step
        kind  = $kind
        actor = $actorValue
        event = $Event
        data  = $data
        prev  = $lastSelf
    }
    $self = Get-Sha256Hex -Text (ConvertTo-CanonicalJson -InputObject $record)
    $record['self'] = $self
    $line = ConvertTo-Json -InputObject $record -Depth 12 -Compress

    $fs = [System.IO.FileStream]::new($eventsPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + "`n")
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
    }
    finally { $fs.Dispose() }
}
finally {
    $lockStream.Dispose()
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}

if (-not $Quiet) { Write-Host "[append] seq=$($record.seq) event=$Event -> $eventsPath" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- verify the write
# Checks the record just written, NOT the whole ledger.
#   - Re-hashing all records on every write was slow (each of the 16 seal writes
#     re-hashed the entire chain) and, worse, wrong: it reported "seq 2 self
#     mismatch" for a ledger that verify-ledger.ps1 called intact one second
#     later. A self-check that cries wolf about old records teaches people to
#     ignore the only line standing between a corrupted write and a silent one.
#   - Full-chain verification stays verify-ledger.ps1's job, where it belongs and
#     where it is not competing with an in-flight append.
# What this can prove is narrower and actually useful: the bytes just written are
# readable, self-consistent, chained to the previous head, and still last in file.
$tail = $null
try {
    $allTail = Read-EventLog -Path $eventsPath
    if ($allTail.Count -gt 0) { $tail = $allTail[$allTail.Count - 1] }
}
catch { }

if ($null -eq $tail) {
    Write-Host '[FAIL] wrote an event but the ledger now reads as empty' -ForegroundColor Red
    exit 1
}
if ($null -ne $tail.PSObject.Properties['__parse_error']) {
    Write-Host "[FAIL] the last line of the ledger does not parse: $($tail.__parse_error)" -ForegroundColor Red
    exit 1
}
if ([int]$tail.seq -ne [int]$record.seq) {
    # Not a failure of this write - it landed, and something else landed after it.
    # But two writers on one append-only file is how records get interleaved, so
    # it must be visible rather than silently tolerated.
    Write-Host ("[WARN] another writer appended after this one (mine seq {0}, file now ends at seq {1}) - consider serialising writers" -f $record.seq, $tail.seq) -ForegroundColor Yellow
}
else {
    $tailHash = Get-EventRecordHash -Record $tail
    if ([string]$tail.self -ne $tailHash) {
        Write-Host ("[FAIL] the record just written does not verify: recorded {0}, computed {1}" -f $tail.self, $tailHash) -ForegroundColor Red
        exit 1
    }
    if ([string]$tail.prev -ne [string]$record.prev) {
        Write-Host ("[FAIL] prev chain broken: recorded '{0}', expected '{1}'" -f $tail.prev, $record.prev) -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------- checkpoint
# Anchor our own verified record OUTSIDE the ledger (see _common.ps1). Only on
# the success path: a checkpoint would attest "up to seq N was whole at T", and
# that claim must itself rest on a verified write. Lag behind hook-only appends
# is fine - the audit rule is containment (head still present, depth >= seq),
# not equality.
try {
    Write-LedgerCheckpoint -ProjectRoot $Root -Seq ([int]$record.seq) -Head ([string]$record.self) -Source 'append-event'
}
catch {
    Write-Host "[WARN] event appended but the checkpoint was not updated: $($_.Exception.Message)" -ForegroundColor Yellow
}

if ($Event -eq 'verify' -and $exitCode -ne 0) { exit 3 }
exit 0
