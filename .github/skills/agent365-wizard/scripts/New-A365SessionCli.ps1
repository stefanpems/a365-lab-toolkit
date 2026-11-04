#requires -Version 7.0
<#
.SYNOPSIS
  Builds a session-only copy of the pinned official Agent 365 CLI without changing its provisioning logic.
.DESCRIPTION
  Reuses installed CLI dependencies. Only authentication/configuration paths, browser selection and
  device-code guards are patched. The global tool, shared caches and default accounts are untouched.
  The resulting CLI requires A365_SESSION_CONFIG_DIR before it will run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionDirectory,
    [Parameter(Mandatory)][string]$A365CliDir,
    [string]$ArchivePath
)
$ErrorActionPreference = 'Stop'
$commit = '90c444832fd3f01cda17fb0b1c39536cf05e85f2'
$version = [Reflection.AssemblyName]::GetAssemblyName((Join-Path $A365CliDir 'Microsoft.Agents.A365.DevTools.Cli.dll')).Version.ToString()
if ($version -ne '1.1.214.37060') { throw "This tested session build requires CLI 1.1.214.37060, found $version. No authentication was started." }
if (-not [IO.Path]::IsPathFullyQualified($SessionDirectory)) { throw 'SessionDirectory must be an absolute, dedicated directory.' }
$root = [IO.Path]::GetFullPath($SessionDirectory).TrimEnd('\')
if ($root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\') -or $root -eq $HOME.TrimEnd('\')) { throw 'A root or home directory is not a session directory.' }
foreach ($shared in @((Join-Path $env:LOCALAPPDATA 'Microsoft.Agents.A365.DevTools.Cli'), (Join-Path $HOME '.azure'))) {
    if ($root -eq $shared -or $root.StartsWith($shared + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SessionDirectory cannot be inside a shared default authentication store.'
    }
}
New-Item -ItemType Directory -Force -Path $root | Out-Null
if (-not $ArchivePath) {
    $ArchivePath = Join-Path $root "official-$commit.zip"
    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        Invoke-WebRequest -Uri "https://codeload.github.com/microsoft/Agent365-devTools/zip/$commit" -OutFile $ArchivePath
    }
}
$source = Join-Path $root 'source'
$support = Join-Path $PSScriptRoot 'a365-session-cli'
$patch = Join-Path $support 'session-auth.patch'
$project = Join-Path $support 'A365SessionCli.csproj'
$policy = Join-Path $support 'SessionAuthenticationProfile.cs'
$fingerprint = @($commit, $version, (Get-FileHash -LiteralPath $patch).Hash,
    (Get-FileHash -LiteralPath $project).Hash, (Get-FileHash -LiteralPath $policy).Hash) -join ':'
$buildId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fingerprint))).Substring(0, 12).ToLowerInvariant()
$output = Join-Path $root "bin\$buildId"
$marker = Join-Path $output 'build-fingerprint.txt'
$cli = Join-Path $output 'Microsoft.Agents.A365.DevTools.Cli.dll'
if (-not ((Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath $cli) -and
    (Get-Content -LiteralPath $marker -Raw).Trim() -eq $fingerprint)) {
    New-Item -ItemType Directory -Force -Path $source | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ArchivePath).Path)
    try {
        foreach ($entry in $archive.Entries) {
            $relative = $null
            if ($entry.FullName -match '^[^/]+/src/Microsoft\.Agents\.A365\.DevTools\.Cli/(.+)$' -and -not $entry.FullName.EndsWith('/')) {
                $relative = $Matches[1].Replace('/', '\')
            }
            elseif ($entry.FullName -match '^[^/]+/(LICENSE[^/]*)$') { $relative = $Matches[1] }
            if (-not $relative) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $source $relative))
            if (-not $target.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid official archive path.' }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    }
    finally { $archive.Dispose() }
    git -C $source init -q
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize the private source worktree for patching.' }
    git -C $source -c core.autocrlf=false apply --check --ignore-space-change $patch
    if ($LASTEXITCODE -ne 0) { throw 'The authentication-only patch does not match the pinned official source.' }
    git -C $source -c core.autocrlf=false apply --ignore-space-change $patch
    if ($LASTEXITCODE -ne 0) { throw 'Applying the session authentication patch failed.' }
    $log = Join-Path $root 'build.log'
    dotnet build $project "-p:A365CliDir=$A365CliDir" "-p:A365SourceRoot=$source" "-p:BaseIntermediateOutputPath=$root\obj\$buildId\" --output $output --verbosity quiet --nologo *> $log
    if ($LASTEXITCODE -ne 0) { throw "The session CLI did not build. See $log. No authentication was started." }
    Set-Content -LiteralPath $marker -Value $fingerprint -Encoding ascii
}
[pscustomobject]@{
    cliPath = $cli
    profileDirectory = Join-Path $root 'profile'
    sourceCommit = $commit
    version = $version
}
