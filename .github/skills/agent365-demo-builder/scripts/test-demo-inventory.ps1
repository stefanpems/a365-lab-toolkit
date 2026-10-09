#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_demo-inventory.ps1')
$passed = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
$sections = New-DemoInventorySections
Assert ($sections.Count -eq 9) 'nine fixed sections'
Assert (($sections.id -join ',') -eq 'users,groups,entra,sharepoint,agents,mcp,other,actions,verification') 'stable section order'
Assert ($sections[0].columns[3] -eq 'Entra roles assigned') 'existing persona role column preserved'
Assert ($sections[0].columns.Count -eq 6) 'persona format plus evidence column'
Assert ((ConvertTo-DemoInventoryText ([datetime]'2026-01-02T03:04:05')) -match '^2026-01-02T03:04:05') 'dates are culture-independent'
$row = @('P1 <script>alert(1)</script>', 'Name | UPN', "line1`nline2", 'Role', 'manual', 'Planned')
$sections[0].rows.Add($row)
# Build excluded test codes without embedding any demo content.
$sections[0].rows.Add(@(('D' + '12'), 'excluded', '', '', '', ''))
$report = [ordered]@{ schemaVersion = '1.0'; prefix = 'unit'; generatedAt = '2026-01-01T00:00:00Z'
    tenantId = 'tenant'; subscriptionId = 'subscription'; pack = 'fixture'; locale = 'en'; mode = 'Snapshot'; scope = 'test'; sections = $sections }
$report = Remove-DemoInventoryExcludedRows $report
Assert ($report.sections[0].rows.Count -eq 1) 'exclusion removes the whole row'
$md = ConvertTo-DemoInventoryMarkdown $report
$html = ConvertTo-DemoInventoryHtml $report
Assert ($md -match 'Name \\\| UPN') 'Markdown pipe escaped'
Assert ($md -match 'line1 line2') 'cell newlines normalized'
Assert ($md -notmatch '<script>alert') 'Markdown markup escaped'
Assert ($html.Contains('&lt;script&gt;alert(1)&lt;/script&gt;')) 'HTML injection escaped'
Assert (([regex]::Matches($html, '<section id=')).Count -eq 9) 'HTML retains empty sections'
Assert (([regex]::Matches($md, '(?m)^## ')).Count -eq 9) 'Markdown retains empty sections'
Assert ($html -notmatch '\{\{[A-Z]+\}\}') 'all template tokens resolved'
Assert ($html -match '--cp-bg: #f7f4ef' -and $html -match 'scoutTheme') 'theme and detection included'
Assert ($html -match 'type="search"') 'search control included'
Assert ($html -notmatch '<script[^>]+src=|<link[^>]+href=') 'self-contained report'
$roundtrip = $report | ConvertTo-Json -Depth 15 | ConvertFrom-Json
Assert ($roundtrip.sections[0].rows[0].Count -eq 6) 'JSON row shape preserved'
Assert ($roundtrip.sections[0].rows[0][1] -eq 'Name | UPN') 'JSON stores data, not markup escapes'
foreach ($section in $roundtrip.sections) {
    foreach ($r in $section.rows) { Assert ($r.Count -eq $section.columns.Count) 'every row matches its schema width' }
}
Write-Host "Passed $passed, failed 0"
