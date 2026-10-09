function ConvertTo-DemoInventoryText($Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '-' }
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) { return $Value.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [array]) { return ($Value | ForEach-Object { [string]$_ }) -join '; ' }
    return ([string]$Value -replace '[\r\n]+', ' ').Trim()
}

function New-DemoInventorySections {
    $definitions = @(
        @('users', '1. Users', @('Demo role (persona)', 'User (name - UPN)', 'Job title', 'Entra roles assigned', 'Other roles / notes', 'Evidence')),
        @('groups', '2. Groups', @('Group', 'Type', 'Object ID', 'Members', 'Owners', 'Assigned permissions / roles', 'Purpose', 'Evidence')),
        @('entra', '3. Entra configuration', @('Type', 'Name', 'Evidence / status', 'ID / values', 'Description / assignments')),
        @('sharepoint', '4. SharePoint resources', @('Type', 'Name', 'URL', 'Permissions', 'Evidence')),
        @('agents', '5. Agents', @('Name', 'Variant', 'Platform / framework / language', 'Authentication', 'Knowledge', 'Tools', 'Surface', 'Evidence', 'URL')),
        @('mcp', '6. Custom MCP servers', @('Name', 'Type', 'Endpoint', 'Tools', 'Registration / approval', 'Audience', 'Connections', 'Evidence / notes')),
        @('other', '7. Infrastructure and other assets', @('Name', 'Type', 'Resource group / location', 'Region', 'Evidence', 'URL', 'Notes')),
        @('actions', '8. User actions', @('ID', 'Status', 'Action', 'Where / how', 'Needed by')),
        @('verification', '9. Verification gaps', @('Resource', 'Gap'))
    )
    @($definitions | ForEach-Object { [ordered]@{ id = $_[0]; title = $_[1]; columns = $_[2]; rows = [System.Collections.Generic.List[object]]::new() } })
}

function Remove-DemoInventoryExcludedRows($Report) {
    # Filter whole rows, not individual cells: never leave a misleading partial configuration.
    $codes = '\b(D12|D14|D16|D17|C6|C7)\b'
    foreach ($s in $Report.sections) {
        $s.rows = @($s.rows | Where-Object { ($_ -join ' ') -notmatch $codes })
    }
    return $Report
}

function ConvertTo-DemoInventoryMarkdown($Report) {
    function Cell($v) { (ConvertTo-DemoInventoryText $v).Replace('\', '\\').Replace('|', '\|').Replace('<', '&lt;').Replace('>', '&gt;') }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Demo lab inventory - $($Report.prefix)")
    $lines.Add('')
    $lines.Add("Schema: $($Report.schemaVersion) | Generated: $($Report.generatedAt) | Mode: $($Report.mode)")
    $lines.Add("Tenant: $($Report.tenantId) | Subscription: $($Report.subscriptionId) | Pack / locale: $($Report.pack) / $($Report.locale)")
    $lines.Add('')
    $lines.Add($Report.scope)
    foreach ($s in $Report.sections) {
        $lines.Add(''); $lines.Add("## $($s.title)"); $lines.Add('')
        $lines.Add('| ' + (($s.columns | ForEach-Object { Cell $_ }) -join ' | ') + ' |')
        $lines.Add('| ' + (($s.columns | ForEach-Object { '---' }) -join ' | ') + ' |')
        foreach ($r in $s.rows) { $lines.Add('| ' + (($r | ForEach-Object { Cell $_ }) -join ' | ') + ' |') }
        if (-not $s.rows.Count) { $lines.Add(''); $lines.Add('No recorded items or verification gaps for this section.') }
    }
    return $lines -join "`n"
}

function ConvertTo-DemoInventoryHtml($Report) {
    function Esc($v) { [System.Net.WebUtility]::HtmlEncode((ConvertTo-DemoInventoryText $v)) }
    $content = [System.Text.StringBuilder]::new()
    $nav = [System.Text.StringBuilder]::new()
    foreach ($s in $Report.sections) {
        $null = $nav.Append("<a href=`"#$($s.id)`">$(Esc $s.title)</a> ")
        $null = $content.Append("<section id=`"$($s.id)`"><h2>$(Esc $s.title)</h2><div class=`"table-wrap`"><table><thead><tr>")
        foreach ($c in $s.columns) { $null = $content.Append("<th scope=`"col`">$(Esc $c)</th>") }
        $null = $content.Append('</tr></thead><tbody>')
        foreach ($r in $s.rows) {
            $null = $content.Append('<tr>')
            foreach ($c in $r) {
                $cell = Esc $c
                if ([string]$c -match '^https://[^\s]+$') { $cell = "<a href=`"$(Esc $c)`" target=`"_blank`" rel=`"noopener noreferrer`">$cell</a>" }
                $null = $content.Append("<td>$cell</td>")
            }
            $null = $content.Append('</tr>')
        }
        $null = $content.Append('</tbody></table></div>')
        if (-not $s.rows.Count) { $null = $content.Append('<p>No recorded items or verification gaps for this section.</p>') }
        $null = $content.Append('</section>')
    }
    $template = Get-Content (Join-Path $PSScriptRoot '..\assets\inventory.html') -Raw
    $template.Replace('{{TITLE}}', (Esc "Demo lab inventory - $($Report.prefix)")).
        Replace('{{META}}', (Esc "Schema $($Report.schemaVersion) | $($Report.generatedAt) | $($Report.mode)")).
        Replace('{{CONTEXT}}', (Esc "Tenant: $($Report.tenantId) | Subscription: $($Report.subscriptionId) | $($Report.pack) / $($Report.locale)")).
        Replace('{{SCOPE}}', (Esc $Report.scope)).Replace('{{NAV}}', $nav.ToString()).Replace('{{CONTENT}}', $content.ToString())
}
