$g = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
$hdr = @{ Authorization = "Bearer $g"; ConsistencyLevel = 'eventual' }
$o = @()
# Find agent/user objects related to a09091 DW
$uri = 'https://graph.microsoft.com/v1.0/users?$filter=' + [uri]::EscapeDataString("startswith(displayName,'a09091')") + '&$select=id,displayName,userPrincipalName,accountEnabled&$count=true&$top=50'
$u = Invoke-RestMethod -Uri $uri -Headers $hdr
$o += "=== users startswith a09091 (count=$($u.value.Count)) ==="
$u.value | ForEach-Object { $o += "$($_.displayName) | $($_.userPrincipalName) | enabled=$($_.accountEnabled) | id=$($_.id)" }
$o | Set-Content -Encoding utf8 "$env:TEMP\dw_users.txt"
