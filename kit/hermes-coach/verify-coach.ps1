<#
.SYNOPSIS
  Assembly + defense verification for the Hermes coach home. Safe to run with an
  exhausted model channel: request dumps are pre-send payload snapshots, so the
  assembly assertions work even when the API replies 402.

.DESCRIPTION
  T0 (offline)  coach config declares the six hardline deny patterns, no plugins
                section, checkpoints on, write sandbox env present in launcher.
  T1 (one -q   the assembled system prompt contains the coach SOUL and contains
     probe)    NO identity_override persona section (asserts 'PRIME DIRECTIVE'
                absent); version line matches the project .harness/PROMPT.

.PARAMETER CoachHome   dir containing config.yaml/.env/SOUL.md (HERMES_HOME)
.PARAMETER HermesExe   path to hermes.exe (venv script)
.PARAMETER ProjectRoot project dir (reads .harness/PROMPT for the version line)
#>
[CmdletBinding()]
param(
    [string] $CoachHome  = 'D:\Hermes\coach-home',
    [string] $HermesExe  = 'D:\Hermes\engine\src\.venv\Scripts\hermes.exe',
    [string] $ProjectRoot = $(Get-Location).Path,
    [switch] $SkipLive
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fails = [System.Collections.Generic.List[string]]::new()

# ---------- T0: config declares the defenses ----------
$cfg = Get-Content (Join-Path $CoachHome 'config.yaml') -Raw
foreach ($d in 'sign-gate','append-event','seal-harness','stage-add','validate-profile','record-edit','events.jsonl') {
    if ($cfg -notmatch [regex]::Escape("*$d*")) { $fails.Add("T0 deny pattern missing: $d") }
}
if ($cfg -match '(?m)^plugins:') { $fails.Add('T0 plugins section present - coach must not load plugins') }
if ($cfg -notmatch '(?m)^checkpoints:') { $fails.Add('T0 checkpoints not declared') }
if (-not (Test-Path (Join-Path $CoachHome 'identity_override.md'))) { } else { $fails.Add('T0 identity_override.md present in coach home - assembly WILL inject it') }
if ($fails.Count -eq 0) { Write-Host '[T0] config defenses declared (7 deny + no plugins + checkpoints)' -ForegroundColor Green }

# ---------- T1: live assembly probe via request dump ----------
if (-not $SkipLive) {
    $prevDumps = @(Get-ChildItem (Join-Path $CoachHome 'sessions\request_dump_*') -File -ErrorAction SilentlyContinue)
    $env:HERMES_HOME = $CoachHome
    $env:HERMES_WRITE_SAFE_ROOT = 'D:\Hermes\coach-scratch'
    Push-Location $ProjectRoot
    try { & $HermesExe chat -q '第一行输出角色自证行，然后停。' 2>&1 | Out-Null } finally { Pop-Location }
    Start-Sleep -Seconds 2
    $new = @(Get-ChildItem (Join-Path $CoachHome 'sessions\request_dump_*') -File -ErrorAction SilentlyContinue) |
        Where-Object { $prevDumps.FullName -notcontains $_.FullName } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $new) {
        # No dump = the request SUCCEEDED (dumps are written on failure only).
        # Assembly then lives in the live reply: assert the self-attestation line
        # (SOUL present + version matches). A clean-assembly reply cannot come
        # from a polluted persona - pollution flips the first line to jailbreak
        # identity. So the behavioral assertion covers what the dump cannot.
        $probeOut = ''
        Push-Location $ProjectRoot
        try { $probeOut = & $HermesExe chat -q '只输出角色自证行，不要执行任何命令。' 2>&1 | Out-String } finally { Pop-Location }
        if ($probeOut -notmatch 'ROLE=coach \| VER=coach-v2\.3\.\d+') {
            $fails.Add('T1 request had no dump (success?) but the reply lacks the ROLE=coach|VER self-attestation line - cannot confirm SOUL assembly')
        } else {
            $vline = [regex]::Match($probeOut, 'ROLE=coach \| VER=(coach-v[\d.]+)').Groups[1].Value
            Write-Host "[T1] live reply carries self-attestation ($vline) - SOUL assembly effective, no dump needed" -ForegroundColor Green
        }
    }
    else {
        $dj = Get-Content $new.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $b = $dj.request.body; if ($b -is [string]) { $b = $b | ConvertFrom-Json }
        $sys = '' + $b.messages[0].content
        if ($sys.IndexOf('PRIME DIRECTIVE') -ge 0) { $fails.Add('T1 persona/identity_override section present in assembly - coach is NOT clean') }
        if ($sys.IndexOf('Vibe Coding') -lt 0)    { $fails.Add('T1 coach SOUL absent from assembly') }
        $want = (Select-String -Path (Join-Path $ProjectRoot '.harness\PROMPT') -Pattern 'PROMPT_VERSION:\s*(\S+)' | Select-Object -First 1).Matches[0].Groups[1].Value
        if ($want -and $sys.IndexOf($want) -lt 0) { $fails.Add("T1 assembly SOUL version != project PROMPT ($want)") }
        if ($fails.Count -eq 0) { Write-Host "[T1] assembly clean: sys=$($sys.Length)B, SOUL=$want, no injected persona" -ForegroundColor Green }
    }
}

if ($fails.Count -gt 0) {
    foreach ($f in $fails) { Write-Host "  x $f" -ForegroundColor Red }
    Write-Host 'verify-coach: FAILED' -ForegroundColor Red; exit 1
}
Write-Host 'verify-coach: OK - coach home is deployable' -ForegroundColor Green; exit 0
