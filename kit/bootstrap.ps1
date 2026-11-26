<#
.SYNOPSIS
  One command to put a whole harness on a project: wipe what is there (when asked)
  and install from this kit.

.DESCRIPTION
  The human's interface is a sentence. Their agent's interface is this:

      pwsh -File bootstrap.ps1 -ConfigFile D:\work_shape\kit-boot.json

  Why a JSON file instead of parameters: `-ProjectRoot "D:\work\price-watch V2.0"`
  loses on two different fronts at once. A space splits the value into two
  positional arguments ("A positional parameter cannot be found that accepts
  argument 'V2.0'"), and a non-ASCII path can arrive mangled through the child
  process's code page. One ASCII path token in argv, everything else inside a
  UTF-8 file, and neither trap can fire.

  kit-boot.json:
      { "project_root": "D:\\work\\price-watch V2.0",
        "by": "Author",
        "reset": true }

  reset:true means "this is a fresh start, delete the harness state first". It
  removes .harness/, events.jsonl, .harness-anchor.json, AGENTS.harness.md, and
  the docs/_snap + docs/_diff scratch. Business files are never touched, and no
  record of the deletion is written anywhere - a debug cycle does not deserve an
  entry in the project's history.

  Exit codes mirror install.ps1: 0 installed, 1 a step failed, 2 bad arguments.

.PARAMETER ConfigFile
  Path to the UTF-8 JSON described above. Preferred over passing parameters.

.PARAMETER ProjectRoot
  Direct target path. Ignored when -ConfigFile is given.

.PARAMETER By
  Installer identity recorded in the genesis event.

.PARAMETER Reset
  Delete existing harness state before installing.

.EXAMPLE
  pwsh -File bootstrap.ps1 -ConfigFile D:\work_shape\kit-boot.json
#>
[CmdletBinding()]
param(
    [string] $ConfigFile = '',
    [string] $ProjectRoot = '',
    [string] $By = '',
    [switch] $Reset,
    [switch] $SkipScheduledTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$KitDir = $PSScriptRoot

function Say { param([string] $m) Write-Host $m }
function Die { param([string] $m) Write-Host ("[bootstrap] {0}" -f $m) -ForegroundColor Red; exit 2 }

# ---------------------------------------------------------------- config
if (-not [string]::IsNullOrWhiteSpace($ConfigFile)) {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { Die "ConfigFile not found: $ConfigFile" }
    $cfg = $null
    try { $cfg = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Die "ConfigFile is not valid JSON: $($_.Exception.Message)" }
    if ($cfg.PSObject.Properties['project_root']) { $ProjectRoot = [string]$cfg.project_root }
    if ($cfg.PSObject.Properties['by'] -and -not [string]::IsNullOrWhiteSpace([string]$cfg.by)) { $By = [string]$cfg.by }
    if ($cfg.PSObject.Properties['reset'] -and [bool]$cfg.reset) { $Reset = $true }
    if ($cfg.PSObject.Properties['skip_scheduled_task'] -and [bool]$cfg.skip_scheduled_task) { $SkipScheduledTask = $true }
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { Die "no project_root (pass -ConfigFile or -ProjectRoot)" }
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { Die "project root does not exist: $ProjectRoot" }
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

$installer = Join-Path $KitDir 'install.ps1'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { Die "install.ps1 missing next to bootstrap.ps1 ($installer)" }

# ---------------------------------------------------------------- reset
$harnessDirs = @('.harness')
$harnessFiles = @('events.jsonl', '.harness-anchor.json', 'AGENTS.harness.md', '.harness-install.lock')
$scratch = @('docs\_snap', 'docs\_diff')

$hasState = $false
foreach ($p in $harnessDirs + $harnessFiles) {
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot $p)) { $hasState = $true; break }
}

if ($hasState -and -not $Reset) {
    Die ("target already has harness state ({0}). This installer will not overwrite it silently - pass -Reset (or `"reset`": true` in the config) to start fresh." -f $ProjectRoot)
}

if ($Reset) {
    $removed = @()
    foreach ($d in $harnessDirs) {
        $p = Join-Path $ProjectRoot $d
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force; $removed += $d + '\' }
    }
    foreach ($f in $harnessFiles) {
        $p = Join-Path $ProjectRoot $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; $removed += $f }
    }
    foreach ($s in $scratch) {
        $p = Join-Path $ProjectRoot $s
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force; $removed += $s + '\' }
    }
    if ($removed.Count -gt 0) { Say ("[bootstrap] reset: removed {0}" -f ($removed -join ', ')) }
    else { Say '[bootstrap] reset: nothing to remove (already clean)' }
}

# ---------------------------------------------------------------- install
$installArgs = @('-NoProfile', '-File', $installer, '-ProjectRoot', $ProjectRoot)
if (-not [string]::IsNullOrWhiteSpace($By)) { $installArgs += @('-By', $By) }
if ($SkipScheduledTask) { $installArgs += '-SkipScheduledTask' }

& pwsh @installArgs
$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Host ("[bootstrap] install.ps1 exit {0} - project is NOT ready" -f $code) -ForegroundColor Red
    exit $code
}

Say ''
Say '[bootstrap] done. 三条下一步：'
Say '  1) pwsh -File .harness\derive\hook-coverage.ps1'
Say '  2) coach 出阶段草案 -> pwsh -File .harness\derive\stage-add.ps1 -Paste   (按 y)'
Say '  3) coding agent 读 .harness\INSTALL-AGENT.md，提示词 .harness\PROMPT-coding.md'
exit 0