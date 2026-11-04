#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionDirectory,
    [Parameter(Mandatory)][string]$A365CliDir,
    [string]$ArchivePath
)
$ErrorActionPreference = 'Stop'
$built = & (Join-Path $PSScriptRoot 'New-A365SessionCli.ps1') -SessionDirectory $SessionDirectory -A365CliDir $A365CliDir -ArchivePath $ArchivePath
$project = Join-Path $PSScriptRoot 'a365-session-cli\checks\ProfileChecks.csproj'
$output = Join-Path $SessionDirectory 'checks'
$log = Join-Path $SessionDirectory 'checks-build.log'
dotnet build $project "-p:A365CliDir=$A365CliDir" "-p:A365SessionCliDir=$(Split-Path -Parent $built.cliPath)" "-p:BaseIntermediateOutputPath=$SessionDirectory\checks-obj\" --output $output --verbosity quiet --nologo *> $log
if ($LASTEXITCODE -ne 0) { throw "Private CLI profile checks did not build. See $log." }
dotnet (Join-Path $output 'ProfileChecks.dll')
if ($LASTEXITCODE -ne 0) { throw 'Private CLI profile checks failed.' }
foreach ($name in 'New-A365SessionCli.ps1', 'Use-A365SessionCli.ps1') {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$name contains a PowerShell parse error." }
}
Write-Host 'Private CLI builder and loader syntax checks passed.'
$tokens = $null; $errors = $null
$loader = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Use-A365SessionCli.ps1'), [ref]$tokens, [ref]$errors)
$assignment = $loader.Find({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -eq 'invokePrivateCli'
}, $true)
$privateCliPath = Join-Path $output 'ProfileChecks.dll'
. ([scriptblock]::Create($assignment.Extent.Text))
$originalFunction = Get-Item -Path Function:\a365 -ErrorAction SilentlyContinue
$originalExitCode = $global:LASTEXITCODE
$nested = Join-Path $output 'nested-wrapper-check.ps1'
try {
    Set-Item -Path Function:\a365 -Value $invokePrivateCli
    @'
$script:privateCliPath = 'must-not-replace-the-bound-executable'
$result = 'y' | a365 --pipe-check
if ($result -ne 'stdin-forwarded' -or $LASTEXITCODE -ne 0) { throw 'Private CLI stdin was not forwarded from the nested deploy script.' }
a365 --exit-check
if ($LASTEXITCODE -ne 7) { throw 'The private CLI wrapper did not preserve the native exit status.' }
$result = 'y' | a365 --pipe-check
if ($result -ne 'stdin-forwarded' -or $LASTEXITCODE -ne 0) { throw 'A successful private CLI invocation did not reset the previous failure status.' }
'@ | Set-Content -LiteralPath $nested -Encoding utf8
    & $nested
    Write-Host 'Private CLI nested-script path, stdin and native exit-status checks passed.'
}
finally {
    if ($originalFunction) { Set-Item -Path Function:\a365 -Value $originalFunction.ScriptBlock }
    else { Remove-Item -Path Function:\a365 }
    if (Test-Path -LiteralPath $nested) { Remove-Item -LiteralPath $nested -Force }
    $global:LASTEXITCODE = $originalExitCode
}
