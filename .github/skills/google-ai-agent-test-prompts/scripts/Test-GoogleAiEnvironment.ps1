[CmdletBinding()]
param(
    [string]$PythonPath,
    [ValidateSet('either', 'file', 'browser')]
    [string]$AuthMode = 'either',
    [string]$GcloudPath,
    [string]$EdgePath,
    [string]$EdgeProfileDirectory
)

$ErrorActionPreference = 'Stop'
if (-not $PythonPath) {
    $dedicated = if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'google-ai-manager\.venv\Scripts\python.exe'
    }
    if ($dedicated -and (Test-Path -LiteralPath $dedicated -PathType Leaf)) {
        $PythonPath = $dedicated
    } else {
        $python = Get-Command python, python3 -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -notmatch '[\\/]WindowsApps[\\/]' } |
            Select-Object -First 1
        if ($python) {
            $PythonPath = $python.Source
        } elseif (Get-Command py -ErrorAction SilentlyContinue) {
            $listed = & py --list-paths
            foreach ($line in $listed) {
                if ($line -match '^\s*-V:3\.(\d+).*?\s+([A-Za-z]:\\.+python(?:\.exe)?)\s*$' -and [int]$Matches[1] -ge 11) {
                    $PythonPath = $Matches[2]
                    break
                }
            }
        }
    }
}
if (-not $PythonPath -or -not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
    @{
        status = 'installation_required'
        missing = @('Python 3.11 or later; Python 3.12 is recommended')
        installation_policy = 'Explain the missing installation and obtain approval before installing. No login or cloud action was started.'
        installation_help = 'https://www.python.org/downloads/windows/'
    } | ConvertTo-Json -Compress
    exit 2
}
$versionText = & $PythonPath -c 'import json,sys; print(json.dumps({"major":sys.version_info[0],"minor":sys.version_info[1]}))'
if ($LASTEXITCODE -ne 0) {
    throw 'The selected Python executable failed its prerequisite version check.'
}
$version = $versionText | ConvertFrom-Json
if ($version.major -lt 3 -or ($version.major -eq 3 -and $version.minor -lt 11)) {
    @{
        status = 'installation_required'
        missing = @("Python $($version.major).$($version.minor) is too old; install Python 3.11 or later, preferably 3.12")
        installation_policy = 'Obtain approval before installing. No dependency imports, login or cloud actions were attempted.'
        installation_help = 'https://www.python.org/downloads/windows/'
    } | ConvertTo-Json -Compress
    exit 2
}
$arguments = @((Join-Path $PSScriptRoot 'google_ai_environment.py'), 'check', '--auth-mode', $AuthMode)
if ($GcloudPath) { $arguments += @('--gcloud-path', $GcloudPath) }
if ($EdgePath) { $arguments += @('--edge-path', $EdgePath) }
if ($EdgeProfileDirectory) { $arguments += @('--edge-profile-directory', $EdgeProfileDirectory) }
& $PythonPath @arguments
exit $LASTEXITCODE
