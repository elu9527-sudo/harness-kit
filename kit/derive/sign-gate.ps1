<#
.SYNOPSIS
  Sign a gate. The human types their reason at a prompt, never JSON and never an
  escaped command line.

.DESCRIPTION
  append-event.ps1 -Event gate -DataJson '{...}' is the correct storage layer and
  stays as it is. But it puts machine syntax on the human's command line, and on
  2026-11-07 that step failed twice for two different reasons:

    1. inline JSON  -> Unexpected character encountered while parsing value: L.
                       Path 'level', line 1, position 7.
                       Cause: the double quotes were gone before argv was built.
                       An interactive-terminal paste strips them; a script-driven
                       call and ConvertFrom-Json both accept the same text.
    2. -Why @('a','b') -> the array literal is not evaluated when it is passed to
                       a child pwsh -File, so the extra elements became positional
                       arguments and $Root was silently replaced by a reason string.

  Both are the same defect: text crossing the argv boundary is re-parsed by
  something other than this script, and what arrives may not be what was typed.
  Escaping harder cannot fix that - the next paste breaks differently. So this
  script takes the reason from stdin, in-process, where a quote is a character
  and a newline is a newline. Then it serialises the record with ConvertTo-Json,
  which escapes everything by construction, and hands append-event a file path:
  one token crosses the boundary and it is a GUID.

  The gate's integrity is unchanged - the lock, the seq/prev/self chain and the
  post-write re-read all still happen in append-event. This script only removes
  the human from the serialisation step.

.PARAMETER Why
  Signed reason on one line, for scripts and one-liners. Omit it and you get an
  interactive prompt instead, which is the recommended path: quotes, braces,
  backslashes, CJK and multiple lines are all literal there.

.EXAMPLE
  # recommended: one command, then paste the reason
  pwsh -File .harness\derive\sign-gate.ps1 -Level L2

.EXAMPLE
  # one-line reason, no prompt
  pwsh -File .harness\derive\sign-gate.ps1 -Level L2 -Why "口径先定再写脚本"

.EXAMPLE
  # see exactly what would be recorded, write nothing
  pwsh -File .harness\derive\sign-gate.ps1 -Level L2 -Why "..." -DryRun

.OUTPUTS
  exit 0 signed and chain verified
  exit 1 chain verification failed after append
  exit 2 bad arguments / project.json missing / no reason given
#>
[CmdletBinding()]
param(
    [string] $Root = $(if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }),

    [ValidateSet('L1', 'L2', 'L3')]
    [string] $Level = 'L2',

    [ValidateSet('approved', 'rejected')]
    [string] $Status = 'approved',

    # Who is signing. Blank falls back to the git identity, then to 'human'.
    [string] $By = '',

    # Single string on purpose: an array literal cannot survive the argv boundary
    # of a child pwsh -File, which is exactly the bug this script exists to remove.
    # For anything longer or containing quotes, use the interactive prompt.
    [string] $Why = '',

    # 2026-11-09: even the INTERACTIVE prompt broke - a human paste of CJK came
    # back through [Console]::In.ReadLine() riddled with NUL (seq 847/957 shape,
    # caught only because the control-character check refused it). When the
    # console layer itself is the broken medium, the reason goes in a UTF-8 file
    # and this script reads it with BOM sniffing. One token still crosses argv.
    [string] $WhyFile = '',

    # Sign for a specific step instead of whatever .harness/local.json currently
    # says. Needed because finish-step can advance current_step while an earlier
    # L2 stage is still unsigned, and signing the newer step would clear the wrong
    # obligation without anyone noticing.
    [string] $Step = '',

    # Skip the confirm prompt. For scripts; a human signing a gate should read it.
    [switch] $Yes,

    # Print the record that would be appended and stop. No write, no lock.
    [switch] $DryRun,

    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$profPath   = Join-Path $Root '.harness\project.json'
$appendPath = Join-Path $Root '.harness\derive\append-event.ps1'

if (-not (Test-Path -LiteralPath $profPath -PathType Leaf)) {
    Write-Host "[FAIL] project.json not found: $profPath" -ForegroundColor Red
    Write-Host "       run this from the project root, or pass -Root explicitly" -ForegroundColor DarkGray
    exit 2
}
if (-not (Test-Path -LiteralPath $appendPath -PathType Leaf)) {
    Write-Host "[FAIL] append-event.ps1 not found: $appendPath" -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------- who is signing
if ([string]::IsNullOrWhiteSpace($By)) {
    try {
        $g = (& git -C $Root config user.name 2>$null | Select-Object -First 1)
        if (-not [string]::IsNullOrWhiteSpace($g)) { $By = ([string]$g).Trim() }
    }
    catch { }
}
if ([string]::IsNullOrWhiteSpace($By)) { $By = 'human' }

# ---------------------------------------------------------------- resolve step
$stepPreview = if (-not [string]::IsNullOrWhiteSpace($Step)) { $Step } else { 'unknown' }
if ([string]::IsNullOrWhiteSpace($Step)) {
    $localPath = Join-Path $Root '.harness\local.json'
    if (Test-Path -LiteralPath $localPath -PathType Leaf) {
        try {
            $local = Get-Content -LiteralPath $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $sp = $local.PSObject.Properties['current_step']
            if ($null -ne $sp -and -not [string]::IsNullOrWhiteSpace([string]$sp.Value)) {
                $stepPreview = [string]$sp.Value
            }
        }
        catch { }
    }
}

# ---------------------------------------------------------------- the reason
# Read-ReasonLines and Get-ReasonProblem live in _common.ps1 now - record-edit
# asks the same question and must reject the same non-answers.
#
# Read-Confirm stays local: only a gate has a safety prompt that redirected
# input must refuse to answer.

function Read-Confirm {
    param([string] $Prompt)
    Write-Host ''
    # Redirected input must not answer a safety question. The first version of this
    # function treated "no stdin left" as yes, so any piped or scripted call signed
    # the gate without a human ever seeing it - the one decision in this pipeline
    # that is supposed to require a person. Absence of an answer is not consent.
    if ([Console]::IsInputRedirected) {
        Write-Host $Prompt -ForegroundColor Yellow -NoNewline
        Write-Host '(stdin redirected - refusing to assume consent; pass -Yes to sign non-interactively)' -ForegroundColor Red
        return $false
    }
    Write-Host $Prompt -ForegroundColor Yellow -NoNewline
    $ans = [Console]::In.ReadLine()
    if ($null -eq $ans) { return $false }
    return ($ans.Trim() -match '^(y|yes|Y|YES|是|确认)$')
}

# ---------------------------------------------------------------- reason quality
# (Get-ReasonProblem is in _common.ps1 - shared with record-edit.)
# The first real signature through this script was `why:"y y"` on 2026-11-07:
# the reason prompt is `> ` and the confirm prompt is `[y/N]`, both on the same
# keyboard with no echo check, so "y" landed in the reason and then "y" again in
# the confirm. Two characters then cleared an L2 risk gate and T7_risk_L2 went
# quiet - indistinguishable from the two earlier gates whose reasons were full
# sentences. A gate whose reason can be typo'd shut is decoration.

$whyText = ([string]$Why).Trim()

if ($WhyFile -ne '' -and [string]::IsNullOrWhiteSpace($whyText)) {
    $absWhy = if ([System.IO.Path]::IsPathRooted($WhyFile)) { $WhyFile } else { Join-Path $Root $WhyFile }
    if (-not (Test-Path -LiteralPath $absWhy -PathType Leaf)) {
        Write-Host "[FAIL] 理由文件不存在: $absWhy" -ForegroundColor Red
        Write-Host '       用编辑器写理由后「另存为 UTF-8」，再重跑本命令' -ForegroundColor Yellow
        exit 2
    }
    # Get-Content -Encoding UTF8 honours a BOM and rejects nothing silently;
    # the control-character quality gate below still applies to file content.
    $fileTxt = Get-Content -LiteralPath $absWhy -Raw -Encoding UTF8
    $whyText = ((@($fileTxt -split "`r?`n") | ForEach-Object { ([string]$_).Trim() }) -join ' ').Trim()
}

# Also used by -DryRun: previewing the interactive path is how a human checks that
# their pasted text survives. EOF ends the loop, so a piped call cannot hang here.
if ([string]::IsNullOrWhiteSpace($whyText)) {
    Write-Host ''
    Write-Host ("[gate] {0} {1}  @ step {2}" -f $Level, $Status, $stepPreview) -ForegroundColor Cyan
    Write-Host ("       signer: {0}" -f $By) -ForegroundColor DarkGray
    Write-Host ''
    # Make it unmistakable that this box wants prose, not a keystroke answer.
    Write-Host '原因（这里是写理由，不是 y/N；可多行，单独一个空行结束）：' -ForegroundColor Yellow
    Write-Host '  ← 教练的 gate 卡里应有一行「建议原因」，直接粘贴即可；没有就自己写：接受了什么风险 / 为什么现在接受' -ForegroundColor DarkGray

    $lines = Read-ReasonLines
    $whyText = (($lines | ForEach-Object { $_.Trim() }) -join ' ').Trim()
}

$whyProblem = Get-ReasonProblem -Text $whyText
if ($whyProblem -ne '') {
    Write-Host ''
    Write-Host ("[FAIL] 原因不合格：{0}" -f $whyProblem) -ForegroundColor Red
    Write-Host '       你填的是：「' -NoNewline -ForegroundColor Red
    Write-Host ($whyText -replace '[\u0000-\u001F]', '·') -NoNewline -ForegroundColor Yellow
    Write-Host '」' -ForegroundColor Red
    if ($whyProblem -match 'control characters') {
        Write-Host '       中文在到达本脚本之前就被终端层毁掉了（不是你打错）。改用文件通道：' -ForegroundColor Yellow
        Write-Host '         1) 编辑器写理由 -> 另存为 UTF-8，例如 .harness\local\gate-why.txt' -ForegroundColor White
        Write-Host '         2) pwsh -File .harness\derive\sign-gate.ps1 -Level L2 -WhyFile .harness\local\gate-why.txt' -ForegroundColor White
    }
    Write-Host '       签一个不说清「接受了什么、为什么」的字关卡，几个月后没人能复原' -ForegroundColor Red
    Write-Host '       它当时挡的是什么，而这条记录事后改不了。' -ForegroundColor Red
    Write-Host '       请写清: 接受了什么风险 / 为什么现在可以接受。' -ForegroundColor Yellow
    exit 2
}

# A reason copied word-for-word from an earlier gate is not a decision about
# THIS step. Observed on 2026-11-07: the first signature through this script
# carried why="y y" - two keystrokes from the confirm prompt, arriving as a
# "reason" - and it silenced T7 for an L2 stage. Length checks alone cannot
# tell a pasted boilerplate from a real thought; equality with a recorded gate
# can. So identical wording to ANY earlier gate is refused: it is either the
# coach copy-pasting its own template or the human answering the wrong question.
$dupEventsPath = Join-Path $Root 'events.jsonl'
if (Test-Path -LiteralPath $dupEventsPath -PathType Leaf) {
    foreach ($g in @(Read-EventLog -Path $dupEventsPath)) {
        if ($null -ne $g.PSObject.Properties['__parse_error']) { continue }
        if ([string]$g.event -ne 'gate') { continue }
        $gdp = $g.PSObject.Properties['data']
        if ($null -eq $gdp) { continue }
        $gwp = $gdp.Value.PSObject.Properties['why']
        if ($null -eq $gwp) { continue }
        if (([string]$gwp.Value).Trim() -eq $whyText) {
            $gseq = [string]$g.seq
            $gstep = [string]$g.step
            Write-Host ''
            Write-Host ("[FAIL] 这条原因与 seq {0}（步 {1}）签过的一字不差。" -f $gseq, $gstep) -ForegroundColor Red
            Write-Host '       每一个 gate 批准的是各自那一步：复制旧 gate 的句子，要么这条' -ForegroundColor Yellow
            Write-Host '       本来就不针对当前步骤，要么你正在无意识地重复上一次的同意。' -ForegroundColor Yellow
            Write-Host '       请针对本步重写（写什么算合格：见上方提示）。' -ForegroundColor Yellow
            exit 2
        }
    }
}

# ---------------------------------------------------------------- what am I signing
# The step is resolved from .harness/local.json, which finish-step can move ahead
# while an older L2 stage is still unsigned - so "the current step" is not always
# the step a gate is being asked for. Reading the profile's risk for it turns that
# ambiguity into something visible before the write instead of after.
$stepRisk = ''
$stepGoal = ''
if (Test-Path -LiteralPath $profPath -PathType Leaf) {
    try {
        $prof = Get-Content -LiteralPath $profPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $st = @($prof.stages) | Where-Object { [string]$_.id -eq $stepPreview } | Select-Object -First 1
        if ($null -ne $st) {
            $rp = $st.PSObject.Properties['risk']
            if ($null -ne $rp) { $stepRisk = [string]$rp.Value }
            $gp2 = $st.PSObject.Properties['goal']
            if ($null -ne $gp2) { $stepGoal = [string]$gp2.Value }
        }
    }
    catch { }
}

# ---------------------------------------------------------------- build the record
# T16 / Mandate revalidation (v0.8, borrowed from Super-agent): pin the contract
# version this authorization is signed under, so a later contract change can flag
# the gate as stale instead of a human having to remember which gates went out of date.
$gateContractSha = ''
$gateProjPath = Join-Path $Root '.harness\project.json'
if (Test-Path -LiteralPath $gateProjPath -PathType Leaf) { $gateContractSha = Get-FileSha256Hex -Path $gateProjPath }
$data = [ordered]@{
    level        = $Level
    status       = $Status
    by           = $By
    why          = $whyText
    contract_sha = $gateContractSha
}
# Serialisation happens here, in-process. Quotes, backslashes and newlines in
# $whyText are escaped by the encoder, not by a human guessing at escape rules.
$jsonText = ConvertTo-Json -InputObject $data -Depth 8 -Compress

if (-not $Quiet) {
    Write-Host ''
    Write-Host '  ── 将要写入 ─────────────────────────────' -ForegroundColor DarkGray
    Write-Host ("  level : {0}" -f $Level)  -ForegroundColor DarkGray
    Write-Host ("  status: {0}" -f $Status) -ForegroundColor DarkGray
    Write-Host ("  by    : {0}" -f $By)     -ForegroundColor DarkGray
    Write-Host ("  step  : {0}{1}" -f $stepPreview, $(if ($stepRisk) { "   (risk=$stepRisk)" } else { '   (risk=未知，该 step 不在 profile 里)' })) -ForegroundColor $(if ($stepRisk -in @('L2','L3')) { 'Gray' } else { 'Yellow' })
    if ($stepGoal) { Write-Host ("          {0}" -f $stepGoal) -ForegroundColor DarkGray }
    Write-Host ("  why   : {0}" -f $whyText) -ForegroundColor Gray
    Write-Host '  ─────────────────────────────────────────' -ForegroundColor DarkGray
    if ($stepRisk -and $stepRisk -notin @('L2', 'L3')) {
        Write-Host ''
        Write-Host ("  [注意] 这一步的 risk 是 {0}，本来不需要 L2 字关卡。" -f $stepRisk) -ForegroundColor Yellow
        Write-Host '         如果你其实想签的是别的步（local.json 已经推进到下一步了），' -ForegroundColor Yellow
        Write-Host '         现在按 N 退出，改用 -Step 显式指定，别把字签在错的步上。' -ForegroundColor Yellow
    }
}

if ($DryRun) {
    Write-Host ''
    Write-Host '[dry-run] data as it would be stored:' -ForegroundColor Yellow
    Write-Host "  $jsonText" -ForegroundColor DarkGray
    Write-Host '[dry-run] nothing written.' -ForegroundColor Yellow
    exit 0
}

if (-not $Yes) {
    if (-not (Read-Confirm -Prompt '确认签名？[y/N] ')) {
        Write-Host ''
        Write-Host '[cancel] 未写入。' -ForegroundColor Yellow
        # exit 0 for "declined" is indistinguishable from "signed" to any caller
        # that only checks the code, and this is the one action where a caller
        # silently believing it succeeded is unacceptable. 130 = declined.
        exit 130
    }
}

# ---------------------------------------------------------------- hand off
# A file, not an inline argument: one GUID path crosses the process boundary.
# No BOM - a BOM-prefixed string is a classic silent ConvertFrom-Json failure.
$tmpPath = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-gate-{0}.json" -f ([guid]::NewGuid().ToString('N')))
$code = 2
try {
    [System.IO.File]::WriteAllText($tmpPath, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
    # -Actor human explicitly: this script may run on a person's behalf, and the
    # record still has to say a person signed it, because that is the claim.
    & pwsh -NoProfile -File $appendPath -Root $Root -Event gate -Actor human -Step $stepPreview -DataJsonFile $tmpPath -Quiet
    $code = $LASTEXITCODE
}
finally {
    if (Test-Path -LiteralPath $tmpPath) {
        Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
    }
}

if ($code -eq 0) {
    Write-Host ("[signed] {0} {1} by {2}" -f $Level, $Status, $By) -ForegroundColor Green
    exit 0
}

Write-Host ("[FAIL] sign-gate: append-event 退出码 {0}，字关卡未记录" -f $code) -ForegroundColor Red
exit $code