$urls = @(
  'https://a09091-aca-obo.purpleground-0b1004e3.polandcentral.azurecontainerapps.io/api/health',
  'https://a09091-aca-s2s.mangobush-3324b337.polandcentral.azurecontainerapps.io/api/health'
)
$o=@()
foreach($u in $urls){
  for($i=1;$i -le 10;$i++){
    try { $r=Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 30; $o += "$u try$i => $($r.StatusCode)"; if($r.StatusCode -eq 200){break} }
    catch { $o += "$u try$i => ERR $($_.Exception.Response.StatusCode.value__)" }
  }
}
$o | Set-Content -Encoding utf8 "$env:TEMP\warm.txt"
