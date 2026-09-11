$ErrorActionPreference='Continue'
$o=@()
# Single query param (no '&') so az.cmd doesn't split the URL; filter client-side.
$json = az rest --method GET --uri 'https://graph.microsoft.com/v1.0/users?$top=999' 2>$env:TEMP\dw_err.txt
if($LASTEXITCODE -eq 0 -and $json){
  $d = $json | ConvertFrom-Json
  $hits = $d.value | Where-Object { $_.displayName -like 'a09091*' -or $_.userPrincipalName -like 'a09091*' -or $_.displayName -like '*ACA-DW*' -or $_.displayName -like '*FH-DW*' }
  $o += "total=$($d.value.Count) hits=$($hits.Count)"
  $hits | ForEach-Object { $o += "$($_.displayName) | upn=$($_.userPrincipalName) | mail=$($_.mail) | enabled=$($_.accountEnabled) | id=$($_.id)" }
} else {
  $o += "az rest failed:"; $o += (Get-Content $env:TEMP\dw_err.txt -Raw)
}
$o | Set-Content -Encoding utf8 "$env:TEMP\dw_users.txt"
