<#
.SYNOPSIS
  P1 凭据隔离（借 SA environment.ts）：为 worker 子命令剥离敏感 env + 专用 git 身份。
.DESCRIPTION
  -Run '<cmd>' 在 sanitized 环境里跑：移除名含 KEY/TOKEN/SECRET/PASSWORD 的变量，
  设 GIT_AUTHOR/COMMITTER 为 worker 专用身份（不用操作者身份）。-Print 只列剥离清单。
  不改父进程 env；不写账本。
#>
param([string]$Run = '', [switch]$Print)
Set-StrictMode -Version Latest
$secretPat = 'KEY|TOKEN|SECRET|PASSWORD'
$stripped = @()
$clean = @{}
foreach ($kv in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
  $k = [string]$kv.Key
  if ($k -match $secretPat) { $stripped += $k; continue }
  $clean[$k] = [string]$kv.Value
}
$clean['GIT_AUTHOR_NAME'] = 'vibe-worker'; $clean['GIT_AUTHOR_EMAIL'] = 'worker@vibe.local'
$clean['GIT_COMMITTER_NAME'] = 'vibe-worker'; $clean['GIT_COMMITTER_EMAIL'] = 'worker@vibe.local'
if ($Print) { Write-Output ("stripped: {0}" -f ($stripped -join ',')); Write-Output 'git identity: vibe-worker <worker@vibe.local>'; exit 0 }
if (-not $Run) { Write-Output '[FAIL] -Run or -Print required'; exit 2 }
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'pwsh'; $psi.Arguments = '-NoProfile -Command ' + $Run
$psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
foreach ($k in $clean.Keys) { $psi.EnvironmentVariables[$k] = $clean[$k] }
foreach ($k in $stripped) { if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) } }
$p = [System.Diagnostics.Process]::Start($psi)
$out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
Write-Output $out; if ($err) { Write-Output $err }
exit $p.ExitCode