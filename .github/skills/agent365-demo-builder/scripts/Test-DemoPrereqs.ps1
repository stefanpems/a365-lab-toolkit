#requires -Version 7.0
<#
.SYNOPSIS
  READ-ONLY prerequisite gate of a demo environment: license seats (the gate), tenant facts that have an API,
  workstation tools, and the MANUAL checks with precise instructions. Report: generated/<prefix>/demo/prereqs-report.md.
.DESCRIPTION
  Seats needed come from pack.json (personas[].licenses + agents[].instance.licenses); seats already held by existing
  demo people are subtracted. Exit code 1 when the license gate fails. Changes nothing.
  Reference: docs/demo-environment-prerequisites.md.
.EXAMPLE
  pwsh -File .\Test-DemoPrereqs.ps1 -Prefix cts2
#>
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(Mandatory)][string]$Prefix)
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$cfg = Read-DemoConfig $Prefix
$pack = Get-DemoPack $cfg.pack
$L = Get-DemoLocale -Locale $cfg.locale -Pack $cfg.pack
$rows = [System.Collections.Generic.List[object]]::new()
function Add-R([string]$Area, [string]$Check, [string]$Status, [string]$Detail, [string]$Fix = '') {
    $rows.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix })
}
# --- tenant context -------------------------------------------------------------------------------------------
$tenantOk = $true
try { Assert-DemoTenant $cfg; Add-R 'Tenant' 'az context' 'OK' "tenant $($cfg.tenantId), subscription $($cfg.subscriptionId)" }
catch { $tenantOk = $false; Add-R 'Tenant' 'az context' 'KO' $_.Exception.Message "az login --tenant $($cfg.tenantId)" }

# --- license gate ---------------------------------------------------------------------------------------------
# Seats per license role: every persona holding it (leavers included: they exist until their permanent deletion)
# plus every AI-teammate instance. Teams is not needed when the Copilot SKU already carries the TEAMS1 plan.
$need = [ordered]@{}
foreach ($r in $pack.licenseRoles.Keys) { $need[$r] = 0 }
foreach ($p in $pack.personas) { foreach ($r in @($p.licenses)) { $need[$r]++ } }
foreach ($a in $pack.agents | Where-Object { $_.instance }) { foreach ($r in @($a.instance.licenses)) { $need[$r]++ } }
$gateOk = $true
if ($tenantOk) {
    $skus = @(Invoke-DemoGraph GET 'https://graph.microsoft.com/v1.0/subscribedSkus' -All)
    $copilotSku = $skus | Where-Object { $_.skuPartNumber -eq $cfg.licenseSkus.copilotUser } | Select-Object -First 1
    $copilotHasTeams = $copilotSku -and @($copilotSku.servicePlans.servicePlanName) -contains 'TEAMS1'
    # seats already held by existing demo people (a re-run must not count them twice)
    $held = @{}
    foreach ($p in $pack.personas) {
        $upn = "$(Get-DemoPersonaAlias $L $p.key)@$($cfg.domain)"
        $u = Invoke-DemoGraph GET "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($upn))?`$select=assignedLicenses" -NoThrow
        if ($u -and -not $u.PSObject.Properties['error']) { foreach ($lic in @($u.assignedLicenses)) { $k = [string]($lic.skuId); if ($k) { $held[$k] = 1 + [int]$held[$k] } } }
    }
    foreach ($r in $need.Keys) {
        $part = [string]$cfg.licenseSkus[$r]
        $n = [int]$need[$r]
        if ($r -eq 'teams' -and $copilotHasTeams) { Add-R 'License gate' "$r ($part)" 'OK' "not needed: $($cfg.licenseSkus.copilotUser) includes Teams"; continue }
        $s = $skus | Where-Object { $_.skuPartNumber -eq $part } | Select-Object -First 1
        if (-not $s) { $gateOk = $false; Add-R 'License gate' "$r ($part)" 'KO' "SKU not in the tenant; $n seat(s) needed" 'buy it, or set another SKU with New-DemoConfig.ps1 -CopilotSku/-TeamsSku/-FrontierSku'; continue }
        $free = [int]$s.prepaidUnits.enabled - [int]$s.consumedUnits
        $already = [int]$held[[string]($s.skuId)]
        $missing = [Math]::Max(0, $n - $already)
        $st = if ($free -ge $missing) { 'OK' } else { $gateOk = $false; 'KO' }
        Add-R 'License gate' "$r ($part)" $st "needed $n, already held by demo people $already, still to assign $missing, free $free of $($s.prepaidUnits.enabled)" $(if ($st -eq 'KO') { 'free seats with the License Reclaimer agent (it removes licenses without deleting users)' })
        $plans = @($s.servicePlans.servicePlanName)
        $miss = @($pack.licenseRoles[$r].evidenceServicePlans | Where-Object { $plans -notcontains $_ })
        if ($miss.Count) { Add-R 'License gate' "$r service plans" 'WARN' "missing in $($part): $($miss -join ', ')" 'check that this SKU really gives the capability (docs section 1)' }
    }
    $spare = $skus | Where-Object { $_.skuPartNumber -eq $cfg.licenseSkus.copilotUser } | Select-Object -First 1
    if ($spare) { Add-R 'License gate' 'spare Copilot seat for the resets' $(if (([int]$spare.prepaidUnits.enabled - [int]$spare.consumedUnits) -ge 1) { 'OK' } else { 'WARN' }) 'one free seat is used for about 10 minutes by every reset of D5 / D8 (temporary leaver)' }
}
else { $gateOk = $false }
# --- tenant facts with an API ---------------------------------------------------------------------------------
if ($tenantOk) {
    $sd = Invoke-DemoGraph GET 'https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy' -NoThrow
    if ($sd -and -not $sd.PSObject.Properties['error']) {
        Add-R 'Entra' 'security defaults disabled' $(if ($sd.isEnabled) { 'KO' } else { 'OK' }) "isEnabled=$($sd.isEnabled)" $(if ($sd.isEnabled) { 'Entra admin center > Overview > Properties > Manage security defaults > Disabled (Conditional Access is used instead)' })
    }
    else { Add-R 'Entra' 'security defaults disabled' 'MANUAL' 'not readable with this token' 'Entra admin center > Overview > Properties > Manage security defaults' }
    foreach ($rp in 'Microsoft.App', 'Microsoft.ContainerRegistry', 'Microsoft.CognitiveServices', 'Microsoft.Web', 'Microsoft.OperationalInsights', 'Microsoft.Insights') {
        $st = (az provider show -n $rp --subscription $cfg.subscriptionId --query registrationState -o tsv 2>$null)
        Add-R 'Azure' "provider $rp" $(if ($st -eq 'Registered') { 'OK' } else { 'WARN' }) "$st" $(if ($st -ne 'Registered') { "az provider register -n $rp --subscription $($cfg.subscriptionId)" })
    }
}
Add-R 'Azure' 'region' $(if ($cfg.region) { 'OK' } else { 'KO' }) "$($cfg.region) (Static Web App: $($cfg.swaRegion))" 'New-DemoConfig.ps1 -Region <region>'
$fm = if ($cfg.foundry) { $cfg.foundry.mode } else { '' }
Add-R 'Azure' 'Foundry project for the review agent' $(if ($fm -eq 'reuse-existing' -and $cfg.foundry.endpoint) { 'OK' } else { 'KO' }) "mode=$fm" "pwsh -File $(Join-Path $script:WizardScriptsDir 'New-FoundryProject.ps1') -Prefix $Prefix -Subscription $($cfg.subscriptionId) -Region $($cfg.region), then New-DemoConfig.ps1 -FoundryMode reuse-existing ..."
$pe = $cfg.copilotStudio.paygEnvironmentId; $de = $cfg.copilotStudio.defaultEnvironmentId
Add-R 'Power Platform' 'payg environment (Dataverse + Copilot Credits)' $(if ($pe) { 'MANUAL' } else { 'KO' }) "id=$pe" "pwsh -File .github/skills/agent365-copilot-studio/scripts/Test-McsPrereqs.ps1 -Harness MCS-NH -EnvironmentId $pe -Tenant $($cfg.tenantId)"
Add-R 'Power Platform' 'default environment (unauthenticated prototype, D14)' $(if ($de) { 'OK' } else { 'KO' }) "id=$de" 'New-DemoConfig.ps1 -DefaultEnvironmentId <id>'

# --- workstation --------------------------------------------------------------------------------------------------
Add-R 'Workstation' 'PowerShell 7' $(if ($PSVersionTable.PSVersion.Major -ge 7) { 'OK' } else { 'KO' }) "$($PSVersionTable.PSVersion)"
foreach ($t in 'az', 'a365', 'pac', 'python', 'git') {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    Add-R 'Workstation' "$t CLI" $(if ($c) { 'OK' } else { 'KO' }) $(if ($c) { $c.Source } else { 'not found' }) $(if (-not $c) { 'see docs/demo-environment-prerequisites.md section 8' })
}
$pyMods = python -c "import importlib.util as u; print(','.join(m for m in ('msal','docx','fpdf','openpyxl') if not u.find_spec(m)))" 2>$null
Add-R 'Workstation' 'Python packages' $(if (-not $pyMods) { 'OK' } else { 'WARN' }) $(if ($pyMods) { "missing: $pyMods" } else { 'msal, python-docx, fpdf2, openpyxl' }) $(if ($pyMods) { 'python -m pip install --user -r .github/skills/agent365-demo-builder/scripts/py/requirements.txt' })

# --- manual checks (no API): precise instructions --------------------------------------------------------------
$manual = @(
    @('Tenant', 'Copilot Frontier enabled (AI teammate, D7)', 'Microsoft 365 admin center > Copilot > Settings > View all > Copilot Frontier (up to 3 h to apply)'),
    @('Tenant', 'Agent 365 Frontier terms accepted (Global Administrator)', 'Microsoft 365 admin center > Agents > Overview > Try now > accept the terms'),
    @('Tenant', 'Registry report names not concealed (D1, D2)', 'Microsoft 365 admin center > Settings > Org settings > Reports: "Conceal user, group, and site names" off'),
    @('Power Platform', 'IP firewall not enforced on the payg and default environments (D5)', 'Power Platform admin center > Security > Identity and access > IP firewall'),
    @('Purview', 'DSPM for AI set up, one-click policies created (D15, >= 24 h before)', 'Purview > DSPM for AI > Recommendations'),
    @('Purview', 'pay-as-you-go billing (Communication Compliance on Copilot Studio agents, D12) - optional', 'Purview > Settings > Pay-as-you-go billing'),
    @('Defender', 'Security for AI on and the Microsoft 365 connector Connected (C6, C7, D16, D17)', 'Defender portal > Settings > Security for AI; Settings > Cloud apps > App connectors'),
    @('Operator', 'operator slots filled for the demo language (D12, D16, D17)', "demo-packs/$($cfg.pack)/OPERATOR-SLOTS.md; check: Test-DemoPack.ps1 -Locale $($cfg.locale) -OperatorSlots generated/$Prefix/demo/operator-slots.json"),
    @('People', 'one browser profile per persona, first sign-in done', 'P1-P11 of the pack; passwords in generated/<prefix>/demo/secrets/')
)
foreach ($m in $manual) { Add-R $m[0] $m[1] 'MANUAL' '' $m[2] }

# --- report -------------------------------------------------------------------------------------------------------
$order = @{ KO = 0; WARN = 1; MANUAL = 2; OK = 3 }
$sorted = $rows | Sort-Object @{ e = { $order[$_.Status] } }, Area, Check
$sorted | Format-Table Status, Area, Check, Detail -AutoSize -Wrap | Out-String -Width 220 | Write-Host
$md = @("# Demo prerequisites - $Prefix - $(Get-Date -Format 'yyyy-MM-dd HH:mm')", '', "License gate: **$(if ($gateOk) { 'PASSED' } else { 'FAILED' })**", '',
    '| Status | Area | Check | Detail | How to fix / verify |', '|---|---|---|---|---|')
$md += $sorted | ForEach-Object { "| $($_.Status) | $($_.Area) | $($_.Check) | $($_.Detail -replace '\|', '/') | $($_.Fix -replace '\|', '/') |" }
$rep = Join-Path (Get-DemoLabDir $Prefix) 'prereqs-report.md'
$md | Set-Content -LiteralPath $rep -Encoding utf8
Write-DemoLog $Prefix "Prerequisites: license gate $(if ($gateOk) { 'PASSED' } else { 'FAILED' }); KO=$(@($rows | Where-Object Status -eq 'KO').Count) MANUAL=$(@($rows | Where-Object Status -eq 'MANUAL').Count); report $rep"
if (-not $gateOk) { exit 1 }
