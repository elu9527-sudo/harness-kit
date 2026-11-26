<#
.SYNOPSIS
  Derive the real hook coverage from the host configuration and record it into
  the ledger as the hook-coverage anchor. Nobody types the verdict.

.DESCRIPTION
  The question this answers, once, for every project: "is the safety net on this
  machine actually attached, and to what exactly?"

  It cannot be answered by assertion. An agent that writes
  -DataJson {"name":"hook-coverage","value":"full"} is recording a belief; the
  only thing that makes the claim checkable is that a script measured it. That is
  why this is a derive script and not a documented one-liner: it reads
  ~\.claude\settings.json, resolves each registered hook command to a real file,
  hashes those bytes, compares them with the bytes seal-harness pinned into
  .harness\hooks\, and tests the matcher against every channel we claim to cover -
  including NotebookEdit (different tool_input key) and mcp__.* (no pre-image
  possible, by design).

  Channel: this is the sanctioned write path, identical to seal-harness.ps1 in the
  same directory (see ledger seq 2-35, actor=script). The agent never supplies a
  JSON literal and never touches events.jsonl: the payload is computed here, held
  in a temp file, and handed to append-event.ps1 -DataJsonFile - which exists
  precisely because `pwsh -File ... -DataJson '{"a":"b"}'` loses the quotes on
  re-parse. Two problems, one mechanism: no literal to misquote, and no
  self-asserted content to trust.

  Verdict:
    full      every claimed channel is registered, the executing bytes exist and
              match the pinned bytes. (MCP still has no pre-image - see limits.)
    degraded  declared, listed in data.gaps, and this is a recorded fact rather
              than a silent hole. Exit 0: an honest degradation is not a fault.
    fault     a channel we claim is registered but is NOT reachable: hook file
              missing, bytes drifted from the pin, guard absent (which would make
              the deny rules prompt-only again), or the matcher does not cover a
              first-party writer. Exit 1.

.PARAMETER Root
  Project root. Defaults to the nearest ancestor containing .harness\local.json.

.PARAMETER HookHome
  Where the executing hook bytes are supposed to live.
  Default %USERPROFILE%\.claude\hooks\harness.

.PARAMETER DryRun
  Print the verdict, write the report, do not append to the ledger.

.EXAMPLE
  pwsh -File .harness\derive\hook-coverage.ps1
#>
[CmdletBinding()]
param(
    [string] $Root = '',
    [string] $HookHome = '',
    [switch] $DryRun,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$FIRST_PARTY = @('Write', 'Edit', 'MultiEdit')
$ALL_WRITERS = @('Write', 'Edit', 'MultiEdit', 'NotebookEdit')

# What each phase must contain, by file name. guard.ps1 is the one that makes the
# deny rules host-enforced; its absence is a fault, not a degradation, because a
# prompt-only deny is exactly the hole this whole check exists to close.
$EXPECTED = [ordered]@{
    PreToolUse  = @('guard.ps1', 'pre-tool.mjs')
    PostToolUse = @('post-tool.mjs')
}

if ([string]::IsNullOrWhiteSpace($Root)) {
    $d = $PSScriptRoot
    if ([string]::IsNullOrEmpty($d)) { $d = (Get-Location).Path }
    while (-not [string]::IsNullOrEmpty($d) -and -not (Test-Path -LiteralPath (Join-Path $d '.harness\local.json'))) {
        $p = Split-Path $d -Parent
        if ([string]::IsNullOrEmpty($p) -or $p -eq $d) { break }
        $d = $p
    }
    $Root = $d
}
if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "project root not found: $Root" }
$Root = (Resolve-Path -LiteralPath $Root).Path

if ([string]::IsNullOrWhiteSpace($HookHome)) { $HookHome = Join-Path $env:USERPROFILE '.claude\hooks\harness' }
$HookHomeResolved = if (Test-Path -LiteralPath $HookHome) { (Resolve-Path -LiteralPath $HookHome).Path } else { $HookHome }

function Get-Sha { param([string] $p)
    if ([string]::IsNullOrWhiteSpace($p) -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
}

# A matcher is a regex alternation over tool names. Test the way the host does:
# every alternative is tried against the tool name, not against a fixed table.
function Test-Matcher { param([string] $matcher, [string] $tool, [bool] $mcpSample = $false)
    if ([string]::IsNullOrWhiteSpace($matcher)) { return $false }
    $name = if ($mcpSample) { 'mcp__probe__FileSystem' } else { $tool }
    foreach ($alt in ($matcher -split '\|')) {
        $a = $alt.Trim()
        if ([string]::IsNullOrEmpty($a)) { continue }
        try { if ([regex]::IsMatch($name, $a)) { return $true } } catch { }
    }
    return $false
}

function Get-HookPath { param([string] $command)
    if ([string]::IsNullOrWhiteSpace($command)) { return '' }
    $m = [regex]::Match($command, '["'']([^"'']*?\.(?:mjs|js|ps1))["'']')
    if ($m.Success) { return $m.Groups[1].Value }
    $m2 = [regex]::Match($command, '(?<![-\w])([A-Za-z]:[\\/][^"''\s]*?\.(?:mjs|js|ps1)|/[^"''\s]*?\.(?:mjs|js|ps1))')
    if ($m2.Success) { return $m2.Groups[1].Value }
    return ''
}

# ---------------------------------------------------------------- read host config
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$phases = [ordered]@{}
$settingsRead = 'ok'
$settings = $null
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    $settingsRead = 'no-settings-file'
} else {
    try { $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $settingsRead = 'unparseable-settings' }
}

foreach ($phase in @('PreToolUse', 'PostToolUse')) {
    $matchers = @()
    $paths = @()
    if ($null -ne $settings -and $settings.PSObject.Properties['hooks'] -and $settings.hooks.PSObject.Properties[$phase]) {
        foreach ($entry in @($settings.hooks.PSObject.Properties[$phase].Value)) {
            if ($null -eq $entry) { continue }
            $cmds = @($entry.hooks | ForEach-Object { [string]$_.command }) -join ' '
            if ($cmds -notmatch '(pre|post)-tool\.mjs|harness\\guard\.ps1') { continue }   # somebody else's hook
            $matchers += [string]$entry.matcher
            foreach ($c in @($entry.hooks | ForEach-Object { [string]$_.command })) {
                if ($c -match '(pre|post)-tool\.mjs|guard\.ps1') { $paths += (Get-HookPath $c) }
            }
        }
    }
    $phases[$phase] = [pscustomobject]@{
        registered = ($paths.Count -gt 0)
        matcher    = ($matchers -join ' ;; ')
        paths      = @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

# ---------------------------------------------------------------- classify bytes
$gaps = @()
$faults = @()
$limits = @()
$bytes = [ordered]@{}

foreach ($phase in @('PreToolUse', 'PostToolUse')) {
    $p = $phases[$phase]
    $tag = if ($phase -eq 'PreToolUse') { 'pre' } else { 'post' }
    $bytes[$tag] = [ordered]@{}
    foreach ($want in $EXPECTED[$phase]) {
        # [System.IO.Path]::GetFileName, not Split-Path -LiteralPath -Leaf:
        # -Leaf belongs to the Path parameter set and cannot be combined with
        # -LiteralPath, so the whole check died with a parameter-set error the
        # first time it ran against a real settings file.
        $exePath = @($p.paths | Where-Object { [System.IO.Path]::GetFileName($_) -eq $want }) | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($exePath)) { $exePath = '' }
        $exeSha = Get-Sha $exePath
        $pinSha = Get-Sha (Join-Path $Root ('.harness\hooks\' + $want))
        $bytes[$tag][$want] = [ordered]@{ executing = $exePath; executing_sha256 = $exeSha; pinned_sha256 = $pinSha }
        if ([string]::IsNullOrWhiteSpace($exePath)) {
            # guard.ps1 missing = 第八条 deny 回到"只写在提示词里"; a missing post/pre
            # hook = the ledger stops growing while still looking authoritative.
            if ($want -eq 'guard.ps1') { $faults += 'no-guard (deny would be prompt-only)' }
            else { $faults += ('hook-missing:' + $tag) }
            $gaps += ('not-registered:' + $tag + ':' + $want)
            continue
        }
        if ([string]::IsNullOrWhiteSpace($exeSha)) { $faults += ('hook-missing:' + $tag + ':' + $want); $gaps += ('hook-missing:' + $tag + ':' + $want); continue }
        if ($exeSha -ne $pinSha) {
            # Executing bytes are not the bytes seal-harness pinned. Either the hook
            # changed without re-seal, or the pinned copy was lost. Both mean the
            # ledger's description of the safety net no longer describes the machine.
            $faults += ('pin-mismatch:' + $tag + ':' + $want)
            $gaps += ('pin-mismatch:' + $tag + ':' + $want)
        }
    }
    if (-not $p.registered) { $gaps += ('not-registered:' + $tag) }
}

$preSha = [string]$bytes['pre']['pre-tool.mjs'].executing_sha256
$postSha = [string]$bytes['post']['post-tool.mjs'].executing_sha256
$guardSha = [string]$bytes['pre']['guard.ps1'].executing_sha256

# ---------------------------------------------------------------- classify channels
foreach ($phase in @('PreToolUse', 'PostToolUse')) {
    $p = $phases[$phase]
    $tag = if ($phase -eq 'PreToolUse') { 'pre' } else { 'post' }
    if (-not $p.registered) { continue }
    $mcp = Test-Matcher $p.matcher 'mcp' $true
    foreach ($t in $ALL_WRITERS) {
        if (-not (Test-Matcher $p.matcher $t)) { $faults += ('missing-channel:' + $tag + ':' + $t) }
    }
    if ($phase -eq 'PostToolUse') {
        if (-not (Test-Matcher $p.matcher 'Bash')) { $gaps += 'no-auto-ledger:bash' }
        if (-not $mcp) { $gaps += 'no-auto-ledger:mcp' }
    } else {
        if (-not (Test-Matcher $p.matcher 'Bash')) { $gaps += 'no-bash-boundary:bash' }
        if (-not $mcp) { $limits += 'no-pre-image:mcp (matched, but pre records nothing for an opaque tool)' }
    }
}

if (-not $phases['PreToolUse'].registered -and -not $phases['PostToolUse'].registered) {
    $gaps += 'no-host-hooks'
}

# Permanent, structural limits. Recorded every run so a reader of the ledger six
# months from now cannot mistake "no before_sha256" for "nobody was watching".
$limits += 'no-pre-image:mcp (opaque tool: path may be a read; pre observes, never blocks)'
$limits += 'no-image:out-of-root-mcp (path outside project: not imaged, not blocked)'

$gaps = @($gaps | Select-Object -Unique | Sort-Object)
$faults = @($faults | Select-Object -Unique | Sort-Object)
$limits = @($limits | Select-Object -Unique)

$value = if ($gaps.Count -gt 0 -or $faults.Count -gt 0) { 'degraded' } else { 'full' }
$status = if ($faults.Count -gt 0) { 'fault' } elseif ($gaps.Count -gt 0) { 'degraded' } else { 'full' }

# ---------------------------------------------------------------- report + anchor
$report = [ordered]@{
    at            = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    host          = 'claude-code'
    settings      = $settingsPath
    settings_read = $settingsRead
    hook_home     = $HookHomeResolved
    value         = $value
    status        = $status
    matcher       = [ordered]@{ pre = $phases['PreToolUse'].matcher; post = $phases['PostToolUse'].matcher }
    bytes         = $bytes
    gaps          = $gaps
    faults        = $faults
    limits        = $limits
    channels      = [ordered]@{
        first_party = $FIRST_PARTY
        notebooks   = @('NotebookEdit')
        shell       = @('Bash')
        mcp         = 'observe-only on pre, recorded on post'
        deny        = 'guard.ps1 (host-enforced, exit 2)'
    }
}

$localDir = Join-Path $Root '.harness\local'
if (-not (Test-Path -LiteralPath $localDir)) { New-Item -ItemType Directory -Force -Path $localDir | Out-Null }
$reportPath = Join-Path $localDir 'hook-coverage.json'
[System.IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

function Short12 { param([string] $h) if ([string]::IsNullOrWhiteSpace($h)) { 'MISSING     ' } else { $h.Substring(0, 12) } }

if (-not $Quiet) {
    Write-Host ''
    Write-Host ("hook coverage: {0}" -f $status.ToUpper())
    Write-Host ("  pre    {0}" -f $(if ($phases['PreToolUse'].matcher) { $phases['PreToolUse'].matcher } else { '(none)' }))
    Write-Host ("  post   {0}" -f $(if ($phases['PostToolUse'].matcher) { $phases['PostToolUse'].matcher } else { '(none)' }))
    foreach ($tag in @('pre', 'post')) {
        foreach ($k in $bytes[$tag].Keys) {
            Write-Host ("  bytes  {0,-13} {1}  vs pinned {2}" -f $k, (Short12 $bytes[$tag][$k].executing_sha256), (Short12 $bytes[$tag][$k].pinned_sha256))
        }
    }
    if ($gaps.Count -gt 0) { Write-Host ("  gaps   {0}" -f ($gaps -join ' ')) -ForegroundColor Yellow }
    if ($faults.Count -gt 0) { Write-Host ("  FAULTS {0}" -f ($faults -join ' ')) -ForegroundColor Red }
    foreach ($l in $limits) { Write-Host ("  limit  {0}" -f $l) }
    Write-Host ("  report {0}" -f $reportPath)
}

# Idempotent: an unchanged measurement does not need a second record. The ledger
# records facts that changed, not that a cron fired.
$appendPath = Join-Path $Root '.harness\derive\append-event.ps1'
$eventsPath = Join-Path $Root 'events.jsonl'
$already = $false
if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
    $lastCoverage = $null
    foreach ($line in (Get-Content -LiteralPath $eventsPath -Encoding UTF8)) {
        if ($line -match '"name":"hook-coverage"') { try { $lastCoverage = $line | ConvertFrom-Json } catch { } }
    }
    if ($null -ne $lastCoverage) {
        $d = $lastCoverage.data
        # Matchers count too: after the duplicate-registration incident the bytes
        # and verdict were identical while the matcher went from four copies to
        # one. Comparing only value+digests would have left the old, wrong
        # matcher standing as the recorded truth of the safety net.
        if ([string]$d.value -eq $value -and
            [string]$d.pre_sha256 -eq $preSha -and
            [string]$d.post_sha256 -eq $postSha -and
            [string]$d.guard_sha256 -eq $guardSha -and
            [string]$d.pre_matcher -eq [string]$phases['PreToolUse'].matcher -and
            [string]$d.post_matcher -eq [string]$phases['PostToolUse'].matcher) { $already = $true }
    }
}

$seqNote = 'unchanged'
if ($DryRun) {
    $seqNote = 'dry-run'
} elseif ($already) {
    $seqNote = 'unchanged (no new record)'
} elseif (-not (Test-Path -LiteralPath $appendPath -PathType Leaf)) {
    throw "append-event.ps1 missing at $appendPath"
} else {
    $why = switch ($status) {
        'full'     { 'claude-code hooks registered, executing bytes identical to the pinned bytes; guard + pre + post attached; every first-party writer and NotebookEdit covered. MCP is observe-only on the pre side by design.' }
        'degraded' { 'coverage measured lower than full: ' + (($gaps + $faults) -join ' ') }
        default    { 'coverage measured' }
    }
    $payload = [ordered]@{
        name         = 'hook-coverage'
        value        = $value
        host         = 'claude-code'
        hook_home    = $HookHomeResolved
        guard_sha256 = $guardSha
        pre_sha256   = $preSha
        post_sha256  = $postSha
        pre_matcher  = [string]$phases['PreToolUse'].matcher
        post_matcher = [string]$phases['PostToolUse'].matcher
        gaps         = $gaps
        faults       = $faults
        limits       = $limits
        validated_by = 'hook-coverage.ps1 (derived from host settings + file digests, not asserted)'
        report       = '.harness/local/hook-coverage.json'
        why          = $why
    }
    $jf = Join-Path $localDir ('hook-coverage-' + [guid]::NewGuid().ToString('N') + '.json')
    [System.IO.File]::WriteAllText($jf, ($payload | ConvertTo-Json -Compress -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    try {
        & pwsh -NoProfile -File $appendPath -Root $Root -Event anchor -Step harness -Actor script -DataJsonFile $jf -Quiet | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "append-event exit $LASTEXITCODE" }
    }
    finally { Remove-Item -LiteralPath $jf -Force -ErrorAction SilentlyContinue }
    $tail = (Get-Content -LiteralPath $eventsPath -Tail 1 -Encoding UTF8 | ConvertFrom-Json)
    $seqNote = ('seq ' + [string]$tail.seq)
}

if (-not $Quiet) { Write-Host ("  anchor {0}" -f $seqNote) -ForegroundColor Cyan }
else { Write-Host ("hook-coverage: {0} {1} {2}" -f $status, $seqNote, ($gaps -join ' ')) }

if ($faults.Count -gt 0) {
    Write-Host '  -> a channel we claim is registered is not reachable; fix before trusting the ledger' -ForegroundColor Red
    exit 1
}
exit 0