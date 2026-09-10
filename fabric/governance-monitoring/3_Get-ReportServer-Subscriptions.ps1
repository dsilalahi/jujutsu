<#
.SYNOPSIS
    Inventories subscriptions on Power BI Report Server / SQL Server Reporting
    Services, and flags external recipients.

.DESCRIPTION
    Report Server is a SEPARATE control plane from the Power BI service. It has
    its own SMTP configuration and its own item-level roles, and none of its
    subscriptions appear in the Power BI activity log or the Purview audit log.
    If report authors are creating paginated-report subscriptions here, scripts
    1 and 2 will show you nothing at all.

    This script calls the Report Server REST API:

        GET https://<server>/reports/api/v2.0/subscriptions

    and flattens each subscription, pivoting the delivery settings so that the
    TO / CC / BCC recipients and the render format become columns.

    Outputs:
      RS_Subscription_Inventory.csv - one row per subscription
      RS_Subscription_External.csv  - only subscriptions with an external recipient
      RS_Subscriptions_Raw.json     - full untouched response

.PREREQUISITES
      * Network access to the Report Server web portal URL.
      * An account with rights to view subscriptions. Note the relevant role
        tasks: "Manage individual subscriptions" (own subscriptions only) versus
        "Manage all subscriptions" (any subscription regardless of owner, part
        of the Content Manager role). To see everything, you need the latter.

.EXAMPLE
    .\3_Get-ReportServer-Subscriptions.ps1 `
        -ReportServerUrl 'https://reports.bc.com/reports' `
        -UseDefaultCredentials `
        -InternalDomains 'bc.com'

.EXAMPLE
    .\3_Get-ReportServer-Subscriptions.ps1 `
        -ReportServerUrl 'https://reports.bc.com/reports' `
        -Credential (Get-Credential) `
        -InternalDomains 'bc.com','abc.com'

.NOTES
    The script reads delivery settings defensively (it pivots whatever parameter
    names the server returns) rather than assuming a fixed schema, so it should
    survive version differences. Inspect RS_Subscriptions_Raw.json if a column
    you expect is empty.
#>

[CmdletBinding()]
param(
    # Web portal URL, e.g. https://reports.contoso.com/reports
    [Parameter(Mandatory)]
    [string] $ReportServerUrl,

    [switch] $UseDefaultCredentials,

    [System.Management.Automation.PSCredential] $Credential,

    [string[]] $InternalDomains = @('bc.com'),

    [string] $OutputFolder = (Join-Path (Get-Location) 'PBI-Audit-Output')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

$baseUri = $ReportServerUrl.TrimEnd('/')
$uri     = "$baseUri/api/v2.0/subscriptions"

$invokeArgs = @{ Method = 'Get'; Uri = $uri; ErrorAction = 'Stop' }
if ($UseDefaultCredentials) { $invokeArgs['UseDefaultCredentials'] = $true }
elseif ($Credential)        { $invokeArgs['Credential']            = $Credential }
else { throw "Provide either -UseDefaultCredentials or -Credential." }

Write-Host "Querying $uri ..." -ForegroundColor Cyan
$response = Invoke-RestMethod @invokeArgs

$subs = if ($response.PSObject.Properties['value']) { $response.value } else { $response }
if (-not $subs) {
    Write-Warning "No subscriptions returned. Confirm the URL is the web portal (usually ending in /reports) and that the account can see all subscriptions."
    return
}

Write-Host ("  {0} subscription(s) returned" -f @($subs).Count)

$rawPath = Join-Path $OutputFolder 'RS_Subscriptions_Raw.json'
$subs | ConvertTo-Json -Depth 15 | Out-File -LiteralPath $rawPath -Encoding utf8

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-SettingValue {
    <#
      Delivery settings arrive as a collection of Name/Value pairs whose names
      vary by delivery extension (email, file share, etc). Pull by name without
      assuming the collection shape.
    #>
    param($Subscription, [string[]]$Names)

    $bag = $null
    foreach ($p in @('DeliverySettings','ExtensionSettings')) {
        if ($Subscription.PSObject.Properties[$p]) { $bag = $Subscription.$p; break }
    }
    if (-not $bag) { return $null }

    $pairs = $null
    foreach ($p in @('ParameterValues','Parameters','Values')) {
        if ($bag.PSObject.Properties[$p]) { $pairs = $bag.$p; break }
    }
    if (-not $pairs) { return $null }

    foreach ($n in $Names) {
        $hit = $pairs | Where-Object { $_.Name -and ($_.Name.ToString().ToLower() -eq $n.ToLower()) }
        if ($hit) { return (($hit | ForEach-Object { $_.Value }) -join '; ') }
    }
    return $null
}

function Get-ExternalAddresses {
    param([string]$AddressList)
    if ([string]::IsNullOrWhiteSpace($AddressList)) { return @() }
    $internal = $InternalDomains | ForEach-Object { $_.ToLower() }
    $addresses = $AddressList -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    return @($addresses | Where-Object {
        if ($_ -notlike '*@*') { return $true }
        $domain = ($_ -split '@')[-1].Trim().ToLower()
        return (-not ($internal -contains $domain))
    })
}

function Get-DeliveryExtension {
    param($Subscription)
    foreach ($p in @('DeliveryExtension','ExtensionName')) {
        if ($Subscription.PSObject.Properties[$p] -and $Subscription.$p) { return $Subscription.$p }
    }
    $bag = $Subscription.PSObject.Properties['DeliverySettings']
    if ($bag -and $Subscription.DeliverySettings.PSObject.Properties['Extension']) {
        return $Subscription.DeliverySettings.Extension
    }
    return $null
}

# ---------------------------------------------------------------------------
# Flatten
# ---------------------------------------------------------------------------
$rows = foreach ($s in $subs) {

    $to  = Get-SettingValue -Subscription $s -Names @('TO','To')
    $cc  = Get-SettingValue -Subscription $s -Names @('CC','Cc')
    $bcc = Get-SettingValue -Subscription $s -Names @('BCC','Bcc')

    $allRecipients = @($to, $cc, $bcc) | Where-Object { $_ } 
    $externals     = @()
    foreach ($list in $allRecipients) { $externals += Get-ExternalAddresses -AddressList $list }
    $externals = @($externals | Select-Object -Unique)

    [PSCustomObject]@{
        SubscriptionId    = $s.Id
        Owner             = $s.Owner
        ReportPath        = $s.Report
        Description       = $s.Description
        IsActive          = $s.IsActive
        EventType         = $s.EventType
        Schedule          = $s.ScheduleDescription
        LastRunTime       = $s.LastRunTime
        LastStatus        = $s.LastStatus
        ModifiedBy        = $s.ModifiedBy
        ModifiedDate      = $s.ModifiedDate
        DeliveryExtension = Get-DeliveryExtension -Subscription $s
        RenderFormat      = Get-SettingValue -Subscription $s -Names @('RenderFormat','RENDER_FORMAT')
        Subject           = Get-SettingValue -Subscription $s -Names @('Subject')
        To                = $to
        Cc                = $cc
        Bcc               = $bcc
        ExternalCount     = $externals.Count
        ExternalAddresses = ($externals -join '; ')
        HasExternal       = ($externals.Count -gt 0)
    }
}

$invPath = Join-Path $OutputFolder 'RS_Subscription_Inventory.csv'
$extPath = Join-Path $OutputFolder 'RS_Subscription_External.csv'

$rows | Sort-Object ReportPath, Owner |
    Export-Csv -LiteralPath $invPath -NoTypeInformation -Encoding UTF8
Write-Host ("Wrote {0} row(s) -> {1}" -f @($rows).Count, $invPath) -ForegroundColor Green

$ext = $rows | Where-Object { $_.HasExternal }
if ($ext) {
    $ext | Export-Csv -LiteralPath $extPath -NoTypeInformation -Encoding UTF8
    Write-Host ("Wrote {0} subscription(s) WITH EXTERNAL RECIPIENTS -> {1}" -f @($ext).Count, $extPath) -ForegroundColor Yellow
}
else {
    Write-Host "No external recipients detected on this Report Server."
}

Write-Host ""
Write-Host "How to read the output:" -ForegroundColor Cyan
Write-Host "  * Owner is the account the subscription runs as - and therefore the permission"
Write-Host "    level at which every recipient receives data."
Write-Host "  * HasExternal = TRUE here is delivery that no Fabric tenant setting governs."
Write-Host "  * If most of the non-compliant subscriptions turn up in THIS file rather than in"
Write-Host "    script 2's output, the gap is the Report Server plane, not Power BI at all."
