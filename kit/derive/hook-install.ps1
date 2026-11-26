<#
.SYNOPSIS
  Install the harness hooks into a location that cannot move, and register them
  in the user-level ~\.claude\settings.json.

.DESCRIPTION
  Why this exists at all: the first live install executed the hooks straight out
  of D:\work_shape\harness-kit\templates\hooks\. That works exactly until someone
  renames, moves or deletes the kit - then settings.json still points at a path
  that no longer exists, every hook exits non-zero, Claude Code ignores it, and
  the agent keeps working with a ledger that has silently stopped growing.
  A safety net that fails open and quiet is worse than no net: the ledger still
  looks authoritative.

  So: one copy in %USERPROFILE%\.claude\hooks\harness\, outside every project and
  outside the kit. Project .harness\hooks\ keeps the *pinned reference* bytes
  (what seal-harness recorded); hook-coverage.ps1 compares the two, so the
  executing bytes and the recorded bytes are checked for identity instead of
  assumed to match.

  Three hooks, two roles:
    guard.ps1     PreToolUse  - decides yes/no (exit 2 blocks). Rules live in the
                                host, not in a prompt: a prompt only binds an agent
                                that chooses to read it.
    pre-tool.mjs  PreToolUse  - keeps the before-image / bash boundary.
    post-tool.mjs PostToolUse - writes the ledger record.

  Idempotent twice over: it replaces any stale harness entry (kit path, project
  path, old matcher) instead of adding a second, and when the computed settings
  are identical to what is already on disk it writes nothing and makes no backup -
  otherwise every install self-test would litter .bak files.
  Never touches settings.json 'env' or any key this script does not own.

.PARAMETER Root
  Project root. Defaults to the nearest ancestor containing .harness\local.json.

.PARAMETER HookHome
  Stable hook directory. Default %USERPROFILE%\.claude\hooks\harness.

.PARAMETER Quiet
  Print only the verdict line.
#>
[CmdletBinding()]
param(
    [string] $Root = '',
    [string] $HookHome = '',
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Say { param([string] $m) if (-not $Quiet) { Write-Host $m } }

if ([string]::IsNullOrWhiteSpace($Root)) {
    $d = (Get-Location).Path
    while (-not [string]::IsNullOrEmpty($d) -and -not (Test-Path -LiteralPath (Join-Path $d '.harness\local.json'))) {
        $p = Split-Path $d -Parent
        if ([string]::IsNullOrEmpty($p) -or $p -eq $d) { break }
        $d = $p
    }
    $Root = $d
}
if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "project root not found: $Root" }
$Root = (Resolve-Path -LiteralPath $Root).Path

$srcDir = Join-Path $Root '.harness\hooks'
if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) { throw "no $srcDir - run install.ps1 first" }

if ([string]::IsNullOrWhiteSpace($HookHome)) { $HookHome = Join-Path $env:USERPROFILE '.claude\hooks\harness' }
New-Item -ItemType Directory -Force -Path $HookHome | Out-Null
$HookHome = (Resolve-Path -LiteralPath $HookHome).Path

# ---------------------------------------------------------------- 1 copy bytes
$deployed = @()
foreach ($n in @('guard.ps1', 'decision-guard.ps1', 'pre-tool.mjs', 'post-tool.mjs')) {
    $s = Join-Path $srcDir $n
    if (-not (Test-Path -LiteralPath $s -PathType Leaf)) { throw "missing hook source $s" }
    $d = Join-Path $HookHome $n
    Copy-Item -LiteralPath $s -Destination $d -Force
    $h = (Get-FileHash -LiteralPath $d -Algorithm SHA256).Hash.ToLower()
    $deployed += [pscustomobject]@{ name = $n; path = $d; sha256 = $h }
    Say ("  hook  {0}  {1}" -f $h.Substring(0, 12), $n)
}

# ---------------------------------------------------------------- 2 merge settings
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
if (-not (Test-Path -LiteralPath (Split-Path $settingsPath -Parent))) {
    New-Item -ItemType Directory -Force -Path (Split-Path $settingsPath -Parent) | Out-Null
}
$settings = $null
$oldNorm = ''
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $rawText = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($rawText)) {
        try {
            $settings = $rawText | ConvertFrom-Json
            $oldNorm = ($settings | ConvertTo-Json -Depth 20)
        } catch { $settings = $null }
    }
}
if ($null -eq $settings) { $settings = [pscustomobject]@{} }

if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
}

# Matcher set: every first-party file writer + NotebookEdit + any MCP tool.
#   - NotebookEdit used a different tool_input key and produced nothing until
#     this fix; the matcher had been claiming it for weeks.
#   - mcp__.* is observe-only on the pre side (see pre-tool.mjs): recorded, never
#     blocked there, because an opaque tool's `path` may be a read. guard.ps1 does
#     still block MCP writes into the ledger / governance surface - that one is
#     unambiguous.
$phases = [ordered]@{
    PreToolUse  = @{ matcher = 'Write|Edit|MultiEdit|NotebookEdit|Bash|mcp__.*'; scripts = @('guard.ps1', 'decision-guard.ps1', 'pre-tool.mjs') }
    PostToolUse = @{ matcher = 'Write|Edit|MultiEdit|NotebookEdit|Bash|mcp__.*'; scripts = @('post-tool.mjs') }
}

foreach ($phase in $phases.Keys) {
    $spec = $phases[$phase]
    $hookList = @()
    foreach ($s in $spec.scripts) {
        $full = Join-Path $HookHome $s
        $cmd = if ($s -like '*.ps1') { 'pwsh -NoProfile -File "' + $full + '"' } else { 'node "' + $full + '"' }
        $hookList += [pscustomobject]@{ type = 'command'; command = $cmd }
    }
    $entry = [pscustomobject]@{ matcher = $spec.matcher; hooks = $hookList }

    # Replace, never duplicate. On 2026-11-17 two installers ran against one
    # target (two kit copies, two agents); each registered its own entry, so every
    # Write produced TWO ledger records and both pre hooks snapshotted the same
    # file. The filter therefore has to recognise a harness entry by ANY shape it
    # can take - host home, kit template, project copy, old or new name - not just
    # the exact path this script happens to write today.
    $existing = @()
    if ($settings.hooks.PSObject.Properties[$phase]) {
        $existing = @($settings.hooks.PSObject.Properties[$phase].Value) | Where-Object {
            # NOT `$null -ne $_` as a bare statement: a filter block's output is
            # the whole statement stream, so that leading boolean made every
            # element truthy and the dedupe silently did nothing - four entries
            # accumulated across two installers and nobody noticed. `return`
            # exits this iteration only.
            if ($null -eq $_) { return $false }
            $c = @($_.hooks | ForEach-Object { [string]$_.command }) -join ' '
            -not ($c -match '(pre|post)-tool\.mjs|guard\.ps1|hooks[\\/]harness')
        }
    }
    $settings.hooks | Add-Member -NotePropertyName $phase -NotePropertyValue (@($existing) + @($entry)) -Force
    Say ("  {0,-11} matcher={1}  hooks={2}" -f $phase, $spec.matcher, ($spec.scripts -join '+'))
}

$newText = ($settings | ConvertTo-Json -Depth 20)
if ($oldNorm -eq $newText) {
    Say '  settings unchanged (no write, no backup)'
} else {
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $bak = $settingsPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $settingsPath -Destination $bak -Force
        Say ("  backup  {0}" -f $bak)
    }
    [System.IO.File]::WriteAllText($settingsPath, $newText, (New-Object System.Text.UTF8Encoding($false)))
    Say ("  settings {0}" -f $settingsPath)
}

# Assert what actually landed instead of trusting the merge code: the dedupe bug
# above produced a settings.json that looked legitimate while registering four
# copies. A registration count is cheap; the cost of not checking it is a ledger
# that logs every write twice and two pre hooks imaging the same file.
$check = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$wrong = @()
foreach ($phase in $phases.Keys) {
    $n = @(@($check.hooks.PSObject.Properties[$phase].Value) | Where-Object {
        if ($null -eq $_) { return $false }
        $c = @($_.hooks | ForEach-Object { [string]$_.command }) -join ' '
        ($c -match '(pre|post)-tool\.mjs|guard\.ps1|hooks[\\/]harness')
    }).Count
    if ($n -ne 1) { $wrong += ('{0}={1}' -f $phase, $n) }
}
if ($wrong.Count -gt 0) {
    Write-Host ("hook-install: FAILED verification - harness entries per phase {0}, expected exactly 1. Remove every harness entry from settings.json and re-run." -f ($wrong -join ' ')) -ForegroundColor Red
    exit 1
}

$summary = ($deployed | ForEach-Object { $_.name + '=' + $_.sha256.Substring(0, 12) }) -join ' '
Write-Host ("hook-install: {0} -> {1}  ({2})" -f $Root, $HookHome, $summary)
exit 0