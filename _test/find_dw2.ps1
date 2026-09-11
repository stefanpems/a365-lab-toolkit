$ErrorActionPreference='Continue'
$o=@()
$json = az rest --method GET --uri "https://graph.microsoft.com/v1.0/users?`$filter=startswith(displayName,'a09091')&`$select=id,displayName,userPrincipalName,accountEnabled,mail&`$top=50" --headers "ConsistencyLevel=eventual" 2>$env:TEMP\dw_err.txt
if($LASTEXITCODE -eq 0 -and $json){
  $d = $json | ConvertFrom-Json
  $o += "count=$($d.value.Count)"
  $d.value | ForEach-Object { $o += "$($_.displayName) | upn=$($_.userPrincipalName) | mail=$($_.mail) | enabled=$($_.accountEnabled) | id=$($_.id)" }
} else {
  $o += "az rest failed:"; $o += (Get-Content $env:TEMP\dw_err.txt -Raw)
}
$o | Set-Content -Encoding utf8 "$env:TEMP\dw_users.txt"
