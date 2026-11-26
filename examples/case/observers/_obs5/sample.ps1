param([string]$Tag='x')
$root='D:\work\price-watch-demo'
Set-Location $root
[Console]::OutputEncoding=[Text.Encoding]::UTF8
$w = "D:\work_shape\_obs5\raw"
New-Item -ItemType Directory -Force -Path $w | Out-Null
$round = Join-Path $w "round_$Tag.txt"
"=== ROUND $Tag  start=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') ===" | Set-Content -Path $round -Encoding UTF8

foreach($job in @('audit','trigger','status','verify-ledger','sweepDry')){
  "`n--- $job ---" | Add-Content -Path $round -Encoding UTF8
  $t0=Get-Date
  switch($job){
    'audit'        { $o = pwsh -NoProfile -File .harness\derive\audit.ps1 2>&1 }
    'trigger'      { $o = pwsh -NoProfile -File .harness\derive\trigger.ps1 2>&1 }
    'status'       { $o = pwsh -NoProfile -File .harness\derive\status.ps1 2>&1 }
    'verify-ledger'{ $o = pwsh -NoProfile -File .harness\derive\verify-ledger.ps1 2>&1 }
    'sweepDry'     { $o = pwsh -NoProfile -File .harness\derive\sweep.ps1 -DryRun 2>&1 }
  }
  $code=$LASTEXITCODE
  ($o | Out-String -Width 250) | Add-Content -Path $round -Encoding UTF8
  ("[exit={0}] [elapsed={1:N1}s]" -f $code,((Get-Date)-$t0).TotalSeconds) | Add-Content -Path $round -Encoding UTF8
}

$ck = Get-Content "$root\.harness\checkpoint.json" -Raw
"`n--- checkpoint.json ---`n$ck" | Add-Content -Path $round -Encoding UTF8
$li = @(Get-Content "$root\events.jsonl" -Encoding UTF8 | Where-Object {$_ -match '\S'})
"`n--- ledger events: $($li.Count) ; last3 ---" | Add-Content -Path $round -Encoding UTF8
($li | Select-Object -Last 3) | Add-Content -Path $round -Encoding UTF8
"`nEND=$(Get-Date -Format 'HH:mm:ss.fff')" | Add-Content -Path $round -Encoding UTF8
Write-Output "ROUND $Tag DONE events=$($li.Count)"
