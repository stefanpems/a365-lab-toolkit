param([string[]]$Targets, [string]$Message = "Hello!")
$ErrorActionPreference='Continue'
$Targets = @($Targets | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
$outdir = "$env:TEMP\a09091runs"
New-Item -ItemType Directory -Force -Path $outdir | Out-Null
foreach($t in $Targets){
  $f = Join-Path $outdir "r_$t.json"
  pwsh -File C:\gh\a365-agent-lab\_test\invoke.ps1 -Target $t -Message $Message -OutFile $f | Out-Null
  Write-Host "===== $t ====="
  Get-Content $f
  Write-Host ""
}
