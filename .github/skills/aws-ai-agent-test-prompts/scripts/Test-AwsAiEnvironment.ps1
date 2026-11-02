param([string]$Python = "python")
$ErrorActionPreference = "Stop"
if (-not (Get-Command $Python -ErrorAction SilentlyContinue)) {
    throw "Python 3.10 or later is required. Install it or pass -Python with its absolute path."
}
& $Python (Join-Path $PSScriptRoot "aws_ai_environment.py") check
exit $LASTEXITCODE
