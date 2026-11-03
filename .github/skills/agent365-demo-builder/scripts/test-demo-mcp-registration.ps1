#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$A365CliDir)
$ErrorActionPreference = 'Stop'
$directory = Join-Path ([IO.Path]::GetTempPath()) ('a365-registration-host-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $PSScriptRoot 'dotnet\IsolatedMcpRegistration\IsolatedMcpRegistration.csproj'
$passed = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
try {
    New-Item -ItemType Directory -Path $directory | Out-Null
    $output = Join-Path $directory 'host'
    $buildLog = Join-Path $directory 'build.log'
    dotnet build $project "-p:A365CliDir=$A365CliDir" "-p:BaseIntermediateOutputPath=$directory\obj\" --output $output --nologo --verbosity quiet *> $buildLog
    if ($LASTEXITCODE -ne 0) { Get-Content -LiteralPath $buildLog -Tail 10; throw 'Offline registration host build failed.' }
    Assert (Test-Path -LiteralPath (Join-Path $output 'Microsoft.Agents.A365.DevTools.Cli.dll')) 'Official CLI runtime is copied into the host.'
    dotnet (Join-Path $output 'IsolatedMcpRegistration.dll') --self-test
    Assert ($LASTEXITCODE -eq 0) 'Credential and transport checks pass without network access.'
    foreach ($name in 'New-DemoMcpRegistration.ps1', 'Invoke-DemoMcpRegistrationHost.ps1') {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$tokens, [ref]$errors)
        Assert (-not $errors.Count) "$name has valid PowerShell syntax."
    }
    $registration = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'New-DemoMcpRegistration.ps1'))
    Assert ($registration.Contains('Invoke-DemoMcpRegistrationHost.ps1') -and $registration.Contains('$cfg.azConfigDir -or $env:DEMO_SESSION_AUTH_DIR')) 'Private profiles use the isolated host.'
    Assert ($registration.Contains("'y' | a365 develop-mcp")) 'The legacy non-isolated registration path remains available.'
    Assert ($registration.Contains('resuming confirmation only')) 'Completed submissions resume confirmation without another POST.'
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dotnet\IsolatedMcpRegistration\Program.cs'))
    Assert (-not $source.Contains('new AuthenticationService(')) 'No shared authentication service is constructed.'
    Assert ($source.Contains('Console.ReadLine()') -and -not $source.Contains('DispatchProxy')) 'Private credentials use stdin and typed services.'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($registration, [ref]$tokens, [ref]$errors)
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Test-CompletedDemoMcpSubmission' }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
    $payload = Join-Path $directory 'payload.json'
    Assert (-not (Test-CompletedDemoMcpSubmission $payload ext_Fixture)) 'Payload preparation alone is not proof of submission.'
    @{ serverName = 'ext_Fixture'; status = 'Success' } | ConvertTo-Json | Set-Content -LiteralPath "$payload.receipt.json"
    $rejected = $false
    try { Test-CompletedDemoMcpSubmission $payload ext_Fixture | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*incomplete official app configuration*' }
    Assert $rejected 'A gateway receipt without completed app configuration blocks resubmission.'
    Set-Content -LiteralPath (Join-Path $directory 'register-ext_Fixture.log') -Value 'ext_Fixture has been registered successfully'
    Assert (Test-CompletedDemoMcpSubmission $payload ext_Fixture) 'Matching receipt and official success log permit confirmation-only resume.'
    @{ serverName = 'ext_Other'; status = 'Success' } | ConvertTo-Json | Set-Content -LiteralPath "$payload.receipt.json"
    $rejected = $false
    try { Test-CompletedDemoMcpSubmission $payload ext_Fixture | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*does not prove a successful submission*' }
    Assert $rejected 'A receipt for another server cannot mark registration complete.'
    @{ serverName = 'ext_Fixture'; status = 'Failed' } | ConvertTo-Json | Set-Content -LiteralPath "$payload.receipt.json"
    $rejected = $false
    try { Test-CompletedDemoMcpSubmission $payload ext_Fixture | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*does not prove a successful submission*' }
    Assert $rejected 'A failed gateway receipt cannot mark registration complete.'
    $currentAssignment = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'cur'
    }, $true)
    $selectCurrent = [scriptblock]::Create($currentAssignment.Extent.Text)
    $knownAssignment = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'known'
    }, $true)
    $selectKnown = [scriptblock]::Create($knownAssignment.Extent.Text)
    $pool = @(
        @{ key = 'dates'; role = 'live'; number = 1; name = 'ext_DatesTest01'; status = 'payload' },
        @{ key = 'dates'; role = 'live'; number = 2; name = 'ext_DatesTest02'; status = 'failed' },
        @{ key = 'dates'; role = 'spare'; number = 3; name = 'ext_DatesTest03'; status = 'payload' }
    )
    $state = @{ mcp = @{ servers = @{ records = @{ name = 'ext_Fixture'; status = 'payload' } } } }
    function Get-AllInstances { @($pool) + @($state.mcp.servers.Values) }
    $isPool = $true; $key = 'dates'; $Role = 'live'; $Number = 0; $tenant = @()
    . $selectCurrent
    Assert ($cur.name -eq 'ext_DatesTest02') 'Pool resume selects the latest incomplete instance of the requested role.'
    $Number = 1
    . $selectCurrent
    Assert ($cur.name -eq 'ext_DatesTest01') 'An explicit pool number selects only that incomplete instance.'
    . $selectKnown
    Assert ($known -contains 'ext_DatesTest01' -and $known -contains 'ext_DatesTest02') 'Pool names remain reserved when no completed submission can be resumed.'
    $isPool = $false; $key = 'records'
    . $selectCurrent
    . $selectKnown
    Assert ($cur.name -eq 'ext_Fixture' -and $known -notcontains 'ext_Fixture') 'Long-lived payload-only preparation retains the existing retry behavior.'
    Write-Host "$passed procedure checks passed."
}
finally {
    if (Test-Path -LiteralPath $directory) {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}
