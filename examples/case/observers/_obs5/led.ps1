param([int]$Tail=40,[string]$Filter='')
$root='D:\work\price-watch-demo'
$ev=@(Get-Content "$root\events.jsonl" -Encoding UTF8 | Where-Object {$_ -match '\S'} | ForEach-Object { try{ $_ | ConvertFrom-Json } catch { [pscustomobject]@{seq=-1;event='__PARSE_ERROR__';raw=$_} } })
"TOTAL=$($ev.Count)"
"--- event type histogram ---"
$ev | Group-Object event | Sort-Object Count -Descending | ForEach-Object { "{0,6}  {1}" -f $_.Count,$_.Name }
"--- actor histogram ---"
$ev | Group-Object actor | Sort-Object Count -Descending | ForEach-Object { "{0,6}  {1}" -f $_.Count,$_.Name }
"--- step histogram (top) ---"
$ev | Group-Object step | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object { "{0,6}  {1}" -f $_.Count,$_.Name }
if($Filter){
  "--- match: $Filter ---"
  $ev | Where-Object { ($_.event -match $Filter) -or ($_.actor -match $Filter) -or (($_.data | ConvertTo-Json -Compress -Depth 10) -match $Filter) } |
    ForEach-Object { "seq={0} t={1} actor={2} step={3} at={4} data={5}" -f $_.seq,$_.event,$_.actor,$_.step,$_.at,($_.data|ConvertTo-Json -Compress -Depth 8) }
}
"--- last $Tail ---"
$ev | Select-Object -Last $Tail | ForEach-Object { "seq={0} t={1} actor={2} step={3} at={4} data={5}" -f $_.seq,$_.event,$_.actor,$_.step,$_.at,($_.data|ConvertTo-Json -Compress -Depth 6) }
