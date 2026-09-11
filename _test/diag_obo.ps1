$b='https://a09091-aca-obo.purpleground-0b1004e3.polandcentral.azurecontainerapps.io'
$o=@()
$o += "--- health ---"
try{$r=Invoke-WebRequest "$b/api/health" -UseBasicParsing -TimeoutSec 40; $o += "$($r.StatusCode) $($r.Content)"}catch{$o += "status=$($_.Exception.Response.StatusCode.value__) ERR $($_.Exception.Message)"}
$o += "--- chat no-auth ---"
try{$r=Invoke-WebRequest "$b/chat" -Method POST -Body '{"message":"Hello!"}' -ContentType 'application/json' -UseBasicParsing -TimeoutSec 40; $o += "$($r.StatusCode) $($r.Content)"}catch{$o += "status=$($_.Exception.Response.StatusCode.value__) msg=$($_.Exception.Message)"}
$o | Set-Content -Encoding utf8 "$env:TEMP\obo_diag.txt"
