<#
.SYNOPSIS
  Shared helpers for harness-kit derive scripts. Zero third-party dependencies.
.DESCRIPTION
  Dot-source this file:
      . "$PSScriptRoot\_common.ps1"

  Provides:
    ConvertTo-CanonicalJson  - deterministic JSON (sorted keys, no whitespace, UTF-8)
    Get-Sha256Hex            - lowercase hex sha256 of a UTF-8 string
    Get-FileSha256Hex        - lowercase hex sha256 of a file's bytes ("" if missing)
    Read-EventLog            - parse events.jsonl into objects
    Get-EventRecordHash      - recompute the self hash of one record
#>

Set-StrictMode -Version Latest

function ConvertTo-CanonicalJson {
    param([Parameter(Mandatory)] $InputObject)

    if ($null -eq $InputObject) { return 'null' }

    $type = $InputObject.GetType()

    if ($InputObject -is [bool]) {
        if ($InputObject) { return 'true' } else { return 'false' }
    }
    if ($InputObject -is [string]) {
        return (ConvertTo-Json -InputObject $InputObject -Compress)
    }
    if ($InputObject -is [int] -or $InputObject -is [long] -or $InputObject -is [int16] -or
        $InputObject -is [byte] -or $InputObject -is [uint32] -or $InputObject -is [uint64]) {
        return ([string]$InputObject)
    }
    if ($InputObject -is [double] -or $InputObject -is [single] -or $InputObject -is [decimal]) {
        $d = [double]$InputObject
        if ($d -eq [math]::Floor($d) -and [math]::Abs($d) -lt 1e15) {
            return ([string]([long]$d))
        }
        return $d.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $keys = @($InputObject.Keys | Sort-Object -Property { [string]$_ } -CaseSensitive)
        $parts = foreach ($k in $keys) {
            $nameJson = ConvertTo-Json -InputObject ([string]$k) -Compress
            $valJson  = ConvertTo-CanonicalJson -InputObject $InputObject[$k]
            "$nameJson`:$valJson"
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in $InputObject) {
            ConvertTo-CanonicalJson -InputObject $item
        }
        return '[' + ($parts -join ',') + ']'
    }
    if ($InputObject -is [psobject]) {
        $props = @($InputObject.PSObject.Properties |
            Where-Object { $_.MemberType -in @('NoteProperty', 'Property') } |
            Sort-Object -Property Name -CaseSensitive)
        $parts = foreach ($p in $props) {
            $nameJson = ConvertTo-Json -InputObject $p.Name -Compress
            $valJson  = ConvertTo-CanonicalJson -InputObject $p.Value
            "$nameJson`:$valJson"
        }
        return '{' + ($parts -join ',') + '}'
    }

    return (ConvertTo-Json -InputObject $InputObject -Compress)
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash  = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($stream)
            return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
        }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

# ---------------------------------------------------------------- harness surface
function Get-HarnessSurface {
    <#
      Every file whose content changes the behaviour of the harness.

      Sealing only `.harness/` produced a green C10 while the two files that write
      every single event were never hashed at all: the Claude Code hooks live in
      the kit source tree, and their paths come from ~/.claude/settings.json. A
      digest that excludes the actual writers is not a lockfile, it is decoration.
      （人格已移出项目：教练在 coach111/SOUL.md，编码在 ~/.claude/CLAUDE.md，故不再纳入摘要。）
    #>
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $items = [System.Collections.Generic.List[object]]::new()

    $hRoot = Join-Path $ProjectRoot '.harness'
    if (Test-Path -LiteralPath $hRoot) {
        foreach ($pat in @('derive\*.ps1', 'rules\*.md', 'contracts\*.md', 'hooks\*.mjs', 'hooks\*.ps1')) {
            foreach ($f in @(Get-ChildItem -Path (Join-Path $hRoot $pat) -ErrorAction SilentlyContinue)) {
                $rel = $f.FullName
                if ($rel.StartsWith($ProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $rel = $rel.Substring($ProjectRoot.Length)
                }
                $rel = $rel.TrimStart('\').Replace('\', '/')
                $items.Add([pscustomobject]@{ id = $rel; path = $f.FullName })
            }
        }
        # 人格不在项目里了（2026-11-17 改）：教练人格在 coach111/SOUL.md，编码人格在
        # ~/.claude/CLAUDE.md。项目只留"这一步做什么"（project.json）与从账本派生的
        # AGENTS.harness.md。曾经把两份人格放进 .harness/，结果任何一端都读到另一端的人格
        # ——编码会话自报 ROLE=coach，按教练口吻出卡。人格属于 agent，不属于项目。
    }

    # Hooks the runtime actually invokes, wherever they live on this machine.
    $cfg = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (Test-Path -LiteralPath $cfg -PathType Leaf) {
        try {
            $j = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
            $hp = $j.PSObject.Properties['hooks']
            if ($null -ne $hp) {
                foreach ($evt in $hp.Value.PSObject.Properties) {
                    foreach ($grp in @($evt.Value)) {
                        $gp = $grp.PSObject.Properties['hooks']
                        if ($null -eq $gp) { continue }
                        foreach ($h in @($gp.Value)) {
                            $cp = $h.PSObject.Properties['command']
                            if ($null -eq $cp) { continue }
                            foreach ($m in [regex]::Matches([string]$cp.Value, '([A-Za-z]:\\[^"]+\.(?:mjs|js|ps1))')) {
                                $p2 = $m.Groups[1].Value
                                if (Test-Path -LiteralPath $p2 -PathType Leaf) {
                                    $items.Add([pscustomobject]@{ id = "external:$p2"; path = $p2 })
                                }
                            }
                        }
                    }
                }
            }
        }
        catch { }
    }

    return @($items | Sort-Object -Property id -Unique)
}

function Get-HarnessDigest {
    <# Single definition, shared by seal-harness and audit. Two implementations of
       the same digest would drift and the seal would never match the check. #>
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $files = @(Get-HarnessSurface -ProjectRoot $ProjectRoot)
    if ($files.Count -eq 0) {
        return [pscustomobject]@{ sha256 = ''; count = 0; files = @() }
    }
    $inner = ($files | ForEach-Object { "$($_.id)|$(Get-FileSha256Hex -Path $_.path)" }) -join "`n"
    return [pscustomobject]@{
        sha256 = (Get-Sha256Hex -Text $inner)
        count  = $files.Count
        files  = $files
    }
}

function Read-EventLog {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }

    $records = @()
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadLines($Path, [System.Text.Encoding]::UTF8)) {
        $lineNo++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = ConvertFrom-Json -InputObject $line
            Add-Member -InputObject $obj -NotePropertyName '__line' -NotePropertyValue $lineNo -Force
            Add-Member -InputObject $obj -NotePropertyName '__raw'  -NotePropertyValue $line   -Force
            $records += $obj
        }
        catch {
            $records += [pscustomobject]@{
                __line  = $lineNo
                __raw   = $line
                __parse_error = $_.Exception.Message
            }
        }
    }
    return $records
}

function Get-EventRecordHash {
    param([Parameter(Mandatory)] $Record)

    $props = [ordered]@{}
    foreach ($p in $Record.PSObject.Properties) {
        if ($p.Name -in @('self', '__line', '__raw', '__parse_error')) { continue }
        $props[$p.Name] = $p.Value
    }
    $canonical = ConvertTo-CanonicalJson -InputObject $props
    return Get-Sha256Hex -Text $canonical
}

# ---------------------------------------------------------------- ledger checkpoint
# Borrowed from Certificate Transparency's checkpoint idea, stripped of crypto.
# The hash chain proves no record was altered or removed from the MIDDLE. It is
# structurally blind to the cheapest forgery: delete the last N lines and the
# remaining chain is perfectly self-consistent. On this machine that attack
# currently costs one text-editor session.
# A log that trusts itself cannot detect its own truncation, so the anchor lives
# OUTSIDE the log: writers record (seq, head-self) in .harness/checkpoint.json,
# and the audit asks "does the ledger still contain that head, at least that
# deep?". Truncating the ledger now requires editing a second file that normal
# operation never rewrites - and sloppiness, not an adversary, is the threat
# model here; raising the bar to "deliberately forged both" is the whole win.
function Write-LedgerCheckpoint {
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [int] $Seq,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Head,
        [string] $Source = 'append-event'
    )
    $cpPath = Join-Path $ProjectRoot '.harness\checkpoint.json'
    # O5-04: monotone gate. The anchor's whole claim is "at least this deep, this
    # head existed"; an unconditional rewrite let a racing/lagging writer move it
    # BACKWARD, shrinking the protected window to "until the very next append"
    # (which the old comment contradicted). Never let the anchor go backwards.
    $existing = Get-LedgerCheckpoint -ProjectRoot $ProjectRoot
    if ($null -ne $existing -and [int]$existing.seq -ge $Seq) { return }
    $obj = [ordered]@{
        seq    = $Seq
        head   = $Head
        at     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        source = $Source
    }
    $tmp = "$cpPath.tmp-$PID"
    try {
        [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $obj -Compress),
            (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $cpPath -Force
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-LedgerCheckpoint {
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    $cpPath = Join-Path $ProjectRoot '.harness\checkpoint.json'
    if (-not (Test-Path -LiteralPath $cpPath -PathType Leaf)) { return $null }
    try {
        $cp = Get-Content -LiteralPath $cpPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $cp.PSObject.Properties['seq'] -or $null -eq $cp.PSObject.Properties['head']) { return $null }
        return $cp
    }
    catch { return $null }
}

# ---------------------------------------------------------------- human input helpers
# Shared by sign-gate and record-edit: both take prose from a person, and both
# failed the same way before - the reason box accepting the answer meant for the
# [y/N] prompt. A reason that short/repeated is not an explanation; whoever
# typed it was answering a different question than the one on screen.
function Get-ReasonProblem {
    param([string] $Text)
    $t = $Text.Trim()
    if ($t.Length -eq 0) { return 'empty' }
    # 2026-11-09 observer #6: two human gates landed in the chain as 60% NUL
    # bytes (seq 847: 102/168, seq 957: 137/233) because control characters
    # counted as "letters" above and the hash chain SEALED the illegibility.
    # A reason containing raw control characters is a destroyed signature, not
    # a signature; reject it so the human re-signs while still at the prompt.
    if ($t -match "[\u0000-\u0008\u000B\u000C\u000E-\u001F]") {
        return 'contains control characters - stdin encoding was destroyed before signing; re-run sign-gate and paste again'
    }
    $squashed = ($t -replace '[\s\p{P}\p{S}]', '')
    if ($squashed.Length -eq 0) { return 'no letters' }
    if ($squashed.Length -lt 6) {
        $distinct = @($squashed.ToCharArray() | Select-Object -Unique)
        if ($distinct.Count -eq 1) { return "repeated single character ('$squashed')" }
        return "too short ($($squashed.Length) chars, need at least 6)"
    }
    return ''
}

function Read-ReasonLines {
    # stdin here means CHARACTERS, not re-parsed argv tokens: quotes stay quotes,
    # newlines stay newlines. The argv boundary destroyed both, twice, on
    # 2026-11-07 - which is why humans type reasons at a prompt now instead of
    # pasting JSON onto a command line.
    $out = [System.Collections.Generic.List[string]]::new()
    $interactive = -not [Console]::IsInputRedirected

    if ($interactive) {
        while ($true) {
            Write-Host '  > ' -ForegroundColor DarkGray -NoNewline
            $ln = [Console]::In.ReadLine()
            if ($null -eq $ln) { break }
            if ($ln.Trim() -eq '') { break }
            $out.Add($ln)
        }
        return $out
    }

    # Redirected (pipe/file). Two separate byte-eating incidents on record:
    #  - zh-CN console decoding UTF-8 as GBK ('自检' arrived as mojibake, 11-07),
    #  - UTF-16LE pipes decoded as UTF-8 => every other byte is NUL and the
    #    reason lands as a skeleton of latin fragments (seq 847/957, observer
    #    #6 - and the hash chain SEALED it). So: read RAW BYTES, sniff the
    #    encoding, decode exactly once.
    $ms = New-Object System.IO.MemoryStream
    $stdin = [Console]::OpenStandardInput()
    $stdin.CopyTo($ms)
    $bytes = $ms.ToArray()
    $ms.Dispose()

    $text = $null
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    elseif ($bytes.Length -ge 4 -and $bytes[1] -eq 0 -and $bytes[3] -eq 0) {
        # BOM-less UTF-16LE heuristic: NUL on odd positions of the first two
        # code units (ASCII-leading CJK payloads look exactly like this).
        $text = [System.Text.Encoding]::Unicode.GetString($bytes)
    }
    else {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    foreach ($ln in ($text -replace "`r`n", "`n" -split "`n")) {
        if ($ln.Trim() -eq '') { break }
        $out.Add($ln)
    }
    return $out
}
