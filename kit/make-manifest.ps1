<#
.SYNOPSIS
  Regenerate MANIFEST.json for the portable kit. Run after ANY kit change,
  before zipping. The manifest is the reproducibility contract: every file the
  installer verifies by sha256 is listed here; MANIFEST.json itself is excluded
  (self-reference is meaningless).
#>
[CmdletBinding()]
param(
    [string] $KitDir = $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }),
    [string] $Version = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Version -eq '') { $Version = 'kit-v0.0-unversioned-' + (Get-Date).ToString('yyyyMMdd') }

# 一致性自检：kit 里存在多份副本的人格必须字节一致，否则升级时必然分叉。
# 曾经发生过：升级 coach-v3.6.0 只改了 prompts/coach.md，hermes-coach/SOUL.md 留在 v3.5.0。
$twins = @(
    @{ a = 'prompts/coach.md'; b = 'hermes-coach/SOUL.md' }
)
foreach ($t in $twins) {
    $pa = Join-Path $KitDir ($t.a -replace '/', '\')
    $pb = Join-Path $KitDir ($t.b -replace '/', '\')
    if ((Test-Path -LiteralPath $pa) -and (Test-Path -LiteralPath $pb)) {
        $ha = (Get-FileHash -LiteralPath $pa -Algorithm SHA256).Hash
        $hb = (Get-FileHash -LiteralPath $pb -Algorithm SHA256).Hash
        if ($ha -ne $hb) { throw "人格副本不一致：$($t.a) != $($t.b) —— 先同步再打包" }
    }
}

$files = [System.Collections.Generic.List[object]]::new()
foreach ($f in @(Get-ChildItem -LiteralPath $KitDir -Recurse -File | Where-Object {
            $_.Name -ne 'MANIFEST.json' -and
            $_.Extension -ne '.pyc' -and
            $_.FullName -notmatch '\\__pycache__\\'
        })) {
    $rel = $f.FullName.Substring($KitDir.Length + 1) -replace '\\', '/'
    $files.Add([pscustomobject]@{
        path    = $rel
        sha256  = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        bytes   = $f.Length
    })
}
$files = $files | Sort-Object path

$digestText = (($files | ForEach-Object { "$($_.path):$($_.sha256)" }) -join "`n")
$digest = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($digestText))) -Algorithm SHA256).Hash.ToLower()

$manifest = [ordered]@{
    kit_version     = $Version
    generated_at    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    file_count      = $files.Count
    manifest_sha256 = $digest
    windows_only    = $true
    files           = @($files)
}
$out = Join-Path $KitDir 'MANIFEST.json'
[System.IO.File]::WriteAllText($out, (ConvertTo-Json $manifest -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("MANIFEST written: {0} files  digest {1}  version {2}" -f $files.Count, $digest.Substring(0, 12), $Version)
