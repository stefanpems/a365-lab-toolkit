# Robust programmatic agent invocation harness for lab a09091.
# Auth strategy per target:
#   - Foundry agents (fh-*, fd-*): az delegated token for https://ai.azure.com (works headless as admin@).
#   - ACA agents / Mail / custom tokens: supplied via -MailToken / -TokensJson (from an MSAL flow).
param(
  [Parameter(Mandatory)][string]$Target,
  [Parameter(Mandatory)][string]$Message,
  [string]$OutFile,
  [string]$AuthToken,       # override Authorization bearer (raw JWT)
  [string]$MailToken,       # delegated Mail (ea9ffc3e) token for OBO
  [string]$TokensJson       # JSON map audience->token for custom OBO tools
)
$ErrorActionPreference = 'Stop'

function Get-AzToken([string]$Resource) {
  $t = az account get-access-token --resource $Resource --query accessToken -o tsv 2>$null
  if (-not $t) { throw "az could not mint a token for resource $Resource" }
  return $t.Trim()
}
function Invoke-Post([string]$Url, [hashtable]$Headers, [string]$Body) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $resp = Invoke-WebRequest -Uri $Url -Method POST -Headers $Headers -Body $Body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 180 -SkipHttpErrorCheck
  $sw.Stop()
  return [pscustomobject]@{ status = [int]$resp.StatusCode; body = $resp.Content; ms = $sw.ElapsedMilliseconds }
}
function Extract-ResponsesText($data) {
  if ($data.output_text) { return $data.output_text }
  $texts = @()
  foreach ($item in @($data.output)) { foreach ($c in @($item.content)) { if ($c.text) { $texts += $c.text } } }
  return ($texts -join "`n")
}

$ACA_OBO = 'https://a09091-aca-obo.purpleground-0b1004e3.polandcentral.azurecontainerapps.io'
$ACA_S2S = 'https://a09091-aca-s2s.mangobush-3324b337.polandcentral.azurecontainerapps.io'
$FH_OBO  = 'https://cog-d4s4rg74gv74k.services.ai.azure.com/api/projects/a09091/agents/a09091-FH-OBO/endpoint/protocols/invocations?api-version=v1'
$FH_S2S  = 'https://cog-d4s4rg74gv74k.services.ai.azure.com/api/projects/a09091/agents/a09091-FH-S2S/endpoint/protocols/openai/responses?api-version=v1'
$FD_ENDPOINT = 'https://cog-d4s4rg74gv74k.services.ai.azure.com/api/projects/a09091/openai/v1/responses'
$MAIL_RES = 'ea9ffc3e-8a23-4a7d-836d-234d7c7565c1'
$FOUNDRY_RES = 'https://ai.azure.com'

$result = [ordered]@{ target=$Target; message=$Message }
try {
  switch ($Target) {
    'aca-obo' {
      $auth = if ($AuthToken) { $AuthToken } elseif ($MailToken) { $MailToken } else { Get-AzToken $FOUNDRY_RES }
      $bodyObj = @{ message=$Message; history=@() }
      $tokens = @{}
      if ($MailToken) { $tokens[$MAIL_RES] = $MailToken }
      if ($TokensJson) { (ConvertFrom-Json $TokensJson).PSObject.Properties | ForEach-Object { $tokens[$_.Name] = $_.Value } }
      if ($tokens.Count) { $bodyObj.tokens = $tokens }
      $res = Invoke-Post "$ACA_OBO/chat" @{ Authorization="Bearer $auth" } (ConvertTo-Json $bodyObj -Depth 6 -Compress)
      $result.status = $res.status; $result.ms = $res.ms
      $result.reply = try { (ConvertFrom-Json $res.body).reply } catch { $res.body }
    }
    'aca-s2s' {
      $auth = if ($AuthToken) { $AuthToken } else { Get-AzToken 'api://7d2ac498-2784-46e0-8137-cbfbd66229ff' }
      $res = Invoke-Post "$ACA_S2S/chat" @{ Authorization="Bearer $auth" } (@{ message=$Message; history=@() } | ConvertTo-Json -Compress)
      $result.status = $res.status; $result.ms = $res.ms
      $result.reply = try { (ConvertFrom-Json $res.body).reply } catch { $res.body }
    }
    'fh-obo' {
      $ep = if ($AuthToken) { $AuthToken } else { Get-AzToken $FOUNDRY_RES }
      $sid = "obo-cli-" + ([guid]::NewGuid().ToString('N').Substring(0,8))
      $bodyObj = @{ message=$Message }
      if ($MailToken) { $bodyObj.mail_token = $MailToken }
      if ($TokensJson) { $tokens=@{}; (ConvertFrom-Json $TokensJson).PSObject.Properties | ForEach-Object { $tokens[$_.Name] = $_.Value }; $bodyObj.tokens = $tokens }
      $res = Invoke-Post "$FH_OBO&agent_session_id=$sid" @{ Authorization="Bearer $ep" } (ConvertTo-Json $bodyObj -Depth 6 -Compress)
      $result.status = $res.status; $result.ms = $res.ms
      $result.reply = try { $d=ConvertFrom-Json $res.body; ($d.response ?? $d.reply ?? $res.body) } catch { $res.body }
    }
    'fh-s2s' {
      $ep = if ($AuthToken) { $AuthToken } else { Get-AzToken $FOUNDRY_RES }
      $res = Invoke-Post $FH_S2S @{ Authorization="Bearer $ep" } (@{ input=$Message; stream=$false } | ConvertTo-Json -Compress)
      $result.status = $res.status; $result.ms = $res.ms
      $result.reply = try { Extract-ResponsesText (ConvertFrom-Json $res.body) } catch { $res.body }
    }
    { $_ -in 'fd-obo','fd-s2s' } {
      $ep = if ($AuthToken) { $AuthToken } else { Get-AzToken $FOUNDRY_RES }
      $name = if ($Target -eq 'fd-obo') { 'a09091-FD-OBO' } else { 'a09091-FD-S2S' }
      $bodyObj = @{ input=$Message; agent_reference=@{ name=$name; type='agent_reference' } }
      $si = @{}
      if ($MailToken) { $si.mail_token = "Bearer $MailToken" }
      if ($TokensJson) { (ConvertFrom-Json $TokensJson).PSObject.Properties | ForEach-Object { $si[$_.Name] = "Bearer $($_.Value)" } }
      if ($si.Count) { $bodyObj.structured_inputs = $si }
      $res = Invoke-Post $FD_ENDPOINT @{ Authorization="Bearer $ep" } (ConvertTo-Json $bodyObj -Depth 6 -Compress)
      $result.status = $res.status; $result.ms = $res.ms
      $result.reply = try { Extract-ResponsesText (ConvertFrom-Json $res.body) } catch { $res.body }
      $result.rawbody = $res.body
    }
    default { throw "unknown target $Target" }
  }
  $result.ok = ($result.status -ge 200 -and $result.status -lt 300)
} catch {
  $result.ok = $false
  $result.error = $_.Exception.Message
}
$json = $result | ConvertTo-Json -Depth 10
if ($OutFile) { $json | Set-Content -Encoding utf8 $OutFile }
Write-Output $json
