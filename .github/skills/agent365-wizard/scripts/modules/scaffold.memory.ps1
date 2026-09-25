# Short conversation memory (last N exchanges) — ALWAYS ON for the 8 code agent types (ACA/FH/FD x
# OBO/S2S/DW); MCS excluded. Nothing to scaffold or deploy: the memory needs NO infrastructure.
#
#  * Web-UI agents: the SPA (ui/app.js) sends the last MEMORY_TURNS exchanges with every request —
#    'history' for ACA-OBO/S2S (/chat) and FH-OBO (Invocations); a Responses 'input' message list for
#    FH-S2S and FD (handled natively by the platform, no agent code involved).
#  * Digital Workers (ACA-DW / FH-DW, Teams): an in-process per-conversation window (ConversationMemory).
#  * ACA-*, FH-OBO and FH-DW import conversation_memory.py, which the router's robocopy copies with the
#    sample. This module only checks that those copies stay byte-identical (warn-only, like web_fetch.py).
# Reads $repoRoot from the router scope.

$ConversationMemoryCanonical = 'aca\obo'
$ConversationMemoryCopies = @('aca\s2s', 'aca\dw', 'foundry-hosted\obo', 'foundry-hosted\dw\src\hello_world_a365_agent')

function Test-ConversationMemoryCopies {
    $canon = Join-Path $repoRoot (Join-Path $ConversationMemoryCanonical 'conversation_memory.py')
    if (-not (Test-Path -LiteralPath $canon)) { Write-Host "  WARN memory: $ConversationMemoryCanonical\conversation_memory.py not found - ACA/FH agents would fail to import it." -ForegroundColor Yellow; return }
    $h = (Get-FileHash -LiteralPath $canon -Algorithm SHA256).Hash
    foreach ($d in $ConversationMemoryCopies) {
        $p = Join-Path $repoRoot (Join-Path $d 'conversation_memory.py')
        if (-not (Test-Path -LiteralPath $p)) { Write-Host "  WARN memory: $d\conversation_memory.py is missing - that agent family would fail to import it." -ForegroundColor Yellow }
        elseif ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne $h) { Write-Host "  WARN memory: $d\conversation_memory.py differs from $ConversationMemoryCanonical\conversation_memory.py (keep every copy byte-identical)." -ForegroundColor Yellow }
    }
}
