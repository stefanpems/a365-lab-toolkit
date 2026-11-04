#requires -Version 7.0
<#
.SYNOPSIS
  Dot-source to use the official CLI in this process with private authentication and the existing Edge work profile.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionDirectory,
    [Parameter(Mandatory)][string]$A365CliDir,
    [Parameter(Mandatory)][string]$EdgeExecutable,
    [string]$EdgeProfile = 'Default',
    [string]$ArchivePath
)
$ErrorActionPreference = 'Stop'
if (-not $env:AZURE_CONFIG_DIR -or -not [IO.Path]::IsPathFullyQualified($env:AZURE_CONFIG_DIR) -or
    [IO.Path]::GetFullPath($env:AZURE_CONFIG_DIR).TrimEnd('\') -eq (Join-Path $HOME '.azure').TrimEnd('\')) {
    throw 'Set AZURE_CONFIG_DIR to the dedicated session profile before loading the private CLI.'
}
if (-not (Test-Path -LiteralPath $EdgeExecutable -PathType Leaf)) { throw "External Edge is unavailable: $EdgeExecutable" }
$prepared = & (Join-Path $PSScriptRoot 'New-A365SessionCli.ps1') -SessionDirectory $SessionDirectory -A365CliDir $A365CliDir -ArchivePath $ArchivePath
$privateCliPath = [string]$prepared.cliPath
$env:A365_SESSION_CONFIG_DIR = [string]$prepared.profileDirectory
$env:A365_BROWSER_EXECUTABLE = $EdgeExecutable
$env:A365_BROWSER_PROFILE = $EdgeProfile
$invokePrivateCli = {
    if ($MyInvocation.ExpectingInput) { $input | & dotnet $privateCliPath @args }
    else { & dotnet $privateCliPath @args }
}.GetNewClosure()
Set-Item -Path Function:\a365 -Value $invokePrivateCli
Write-Host "Process-private Agent 365 CLI ready (source $($prepared.sourceCommit)); shared authentication is unchanged."
