#requires -Version 7.0
<#
.SYNOPSIS
  Bootstrap step 'python-deps': installs the Python packages of the Demo Builder (py/requirements.txt: msal for the
  browser sign-ins, msal-extensions for the lab az profile token cache, python-docx / fpdf2 / openpyxl for the knowledge documents) when they are missing.
.DESCRIPTION
  Checks the modules first (nothing to do when present); otherwise `python -m pip install --user -r requirements.txt`
  (user site, no administrator rights) and checks again. Exit code 1 when Python is missing or a module still is.
  -WhatIf = report only.
.EXAMPLE
  pwsh -File .\Install-DemoPythonDeps.ps1 -Prefix cts2 -WhatIf
#>
[CmdletBinding(PositionalBinding = $false)]
param([string]$Prefix, [switch]$WhatIf)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-common.ps1')
$req = Join-Path $PSScriptRoot 'py\requirements.txt'
# import name -> package name of requirements.txt
$mods = [ordered]@{ msal = 'msal'; msal_extensions = 'msal-extensions'; docx = 'python-docx'; fpdf = 'fpdf2'; openpyxl = 'openpyxl' }
function Get-MissingModules {
    # Returns the comma-separated missing modules ('' = none) or $null when Python did not run. A string, not an
    # array: an empty array returned by a function arrives as $null.
    $names = ($mods.Keys | ForEach-Object { "'$_'" }) -join ','
    $o = python -c "import importlib.util as u; print(','.join(m for m in ($names,) if not u.find_spec(m)))" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]$o).Trim()
}
function Write-Log([string]$M, [string]$Level = 'INFO') { if ($Prefix) { Write-DemoLog $Prefix $M $Level } else { Write-Host $M } }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { Write-Log 'Python not found: install Python 3.11+ (docs/demo-environment-prerequisites.md section 8)' 'ERROR'; exit 1 }
$raw = Get-MissingModules
if ($null -eq $raw) { Write-Log 'Python did not run: check the python command' 'ERROR'; exit 1 }
$missing = @($raw -split ',' | Where-Object { $_ })
if (-not $missing.Count) { Write-Log "Python packages present: $($mods.Values -join ', ')"; return }
$pk = @($missing | ForEach-Object { $mods[$_] })
if ($WhatIf) { Write-Host "  would install (user site): $($pk -join ', ') from $req"; return }
Write-Log "Installing the missing Python packages: $($pk -join ', ')"
python -m pip install --user --disable-pip-version-check -q -r $req
$missing = @((Get-MissingModules) -split ',' | Where-Object { $_ })
if ($missing.Count) { Write-Log "Python packages still missing: $(@($missing | ForEach-Object { $mods[$_] }) -join ', ')" 'ERROR'; exit 1 }
Write-Log "Python packages installed: $($pk -join ', ')"
