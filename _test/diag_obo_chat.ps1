$b='https://a09091-aca-obo.purpleground-0b1004e3.polandcentral.azurecontainerapps.io'
$o=@()
$tok = (az account get-access-token --resource "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1" --query accessToken -o tsv 2>$null).Trim()
$o += "token len=$($tok.Length)"
$sw=[Diagnostics.Stopwatch]::StartNew()
try {
  $r = Invoke-WebRequest "$b/chat" -Method POST -Headers @{ Authorization="Bearer $tok" } -Body '{"message":"Hello!","history":[]}' -ContentType 'application/json' -UseBasicParsing -TimeoutSec 180 -SkipHttpErrorCheck
  $sw.Stop()
  $o += "elapsedMs=$($sw.ElapsedMilliseconds) status=$($r.StatusCode)"
  $o += "body=$($r.Content)"
} catch {
  $sw.Stop()
  $o += "elapsedMs=$($sw.ElapsedMilliseconds) EXC status=$($_.Exception.Response.StatusCode.value__) msg=$($_.Exception.Message)"
}
$o | Set-Content -Encoding utf8 "$env:TEMP\obo_chat.txt"
