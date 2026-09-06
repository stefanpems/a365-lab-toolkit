# Shared scaffolder state: the variant map and the .env writer.
# Dot-sourced by scaffold-from-plan.ps1 into the router scope so every module sees $MAP / Set-EnvValue.

# variant -> source sample folder + deploy script + config kind
$MAP = @{
    'ACA-OBO' = @{ src = 'aca\obo';               deploy = 'deploy-aca.ps1';      config = 'aca' }
    'ACA-S2S' = @{ src = 'aca\s2s';               deploy = 'deploy-aca-S2S.ps1';  config = 'aca' }
    'ACA-DW'  = @{ src = 'aca\dw';                deploy = 'deploy-aca-DW.ps1';   config = 'aca' }
    'FH-OBO'  = @{ src = 'foundry-hosted\obo';    deploy = $null;                 config = 'fh'  }
    'FH-S2S'  = @{ src = 'foundry-hosted\s2s';    deploy = $null;                 config = 'fh'  }
    'FH-DW'   = @{ src = 'foundry-hosted\dw';     deploy = $null;                 config = 'fh'  }
    'FD-OBO'  = @{ src = 'foundry-declarative\obo'; deploy = $null;               config = 'fd'  }
    'FD-S2S'  = @{ src = 'foundry-declarative\s2s'; deploy = $null;               config = 'fd'  }
}

function Set-EnvValue {
    param([string]$Path, [string]$Key, [string]$Value)
    $lines = if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path) } else { @() }
    $set = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*#?\s*$([regex]::Escape($Key))=") { $lines[$i] = "$Key=$Value"; $set = $true }
    }
    if (-not $set) { $lines = @($lines) + "$Key=$Value" }
    Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
}
