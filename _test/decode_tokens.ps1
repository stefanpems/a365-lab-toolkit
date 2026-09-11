# Decode az-minted tokens for the relevant resources and print key claims.
function Decode-Jwt([string]$Token){
  $p=$Token.Split('.')[1]; $p=$p.Replace('-','+').Replace('_','/')
  switch($p.Length % 4){2{$p+='=='}3{$p+='='}}
  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}
$o=@()
$targets = @(
  @{n='Mail(res ea9ffc3e)'; r='ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'},
  @{n='Foundry(ai.azure.com)'; r='https://ai.azure.com'}
)
foreach($t in $targets){
  $tok = az account get-access-token --resource $t.r --query accessToken -o tsv 2>$null
  if($tok){
    $j = Decode-Jwt $tok.Trim()
    $o += "[$($t.n)] aud=$($j.aud) appid=$($j.appid) scp=$($j.scp) roles=$($j.roles) upn=$($j.upn)"
  } else { $o += "[$($t.n)] NO TOKEN" }
}
# Try scope-based acquisition for Mail (specific scope) if supported
$o += "--- scope-based Mail ---"
$tok2 = az account get-access-token --scope "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1/McpServers.Mail.All" --query accessToken -o tsv 2>&1
if($LASTEXITCODE -eq 0 -and $tok2 -and $tok2 -notmatch 'ERROR'){ $j=Decode-Jwt ($tok2.Trim()); $o += "scope Mail: aud=$($j.aud) scp=$($j.scp)" } else { $o += "scope Mail FAILED: $tok2" }
$o | Set-Content -Encoding utf8 "$env:TEMP\tok_decode.txt"
