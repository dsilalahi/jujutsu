<#
.SYNOPSIS
    Builds a tenant-wide inventory of Power BI service email subscriptions and
    flags the ones with external recipients - using the Admin REST API directly.

.DESCRIPTION
    Calls, via raw HTTPS requests (Invoke-RestMethod), in this order:

      1) GET https://api.powerbi.com/v1.0/myorg/admin/groups?$top=5000&$expand=reports,dashboards
         (Groups GetGroupsAsAdmin - workspaces plus their reports and dashboards)

      2) GET https://api.powerbi.com/v1.0/myorg/admin/reports/{reportId}/subscriptions
         (Reports GetReportSubscriptionsAsAdmin - PREVIEW API)

      3) GET https://api.powerbi.com/v1.0/myorg/admin/dashboards/{dashboardId}/subscriptions
         (Dashboards GetDashboardSubscriptionsAsAdmin - PREVIEW API)

    Each subscription is expanded to one row per recipient, and any recipient
    whose email domain is not in -InternalDomains is flagged IsExternal = TRUE.
    That flagged set is the answer to "who is actually sending externally".

    Outputs:
      Subscription_Inventory.csv    - every subscription x recipient
      Subscription_External.csv     - only rows where IsExternal = TRUE
      Subscription_Inventory.json   - raw responses, unflattened

.PREREQUISITES
      * Caller must be a Fabric administrator, OR authenticate as a service
        principal. Required scope: Tenant.Read.All (or Tenant.ReadWrite.All).
      * For the service principal route, the SPN must be in a group enabled for
        the tenant setting "Service principals can access read-only admin APIs".

.IMPORTANT - RATE LIMIT
      These admin APIs allow a maximum of 200 requests per hour. This script
      makes one call per report and one per dashboard, so a large tenant will
      exhaust the budget quickly. Use -WorkspaceNameLike to scope the run to the
      workspaces under investigation, and -MaxApiCalls as a hard stop.

.EXAMPLE
    # Delegated (interactive) sign-in as a Fabric admin, scoped to two workspaces
    .\2_Get-PBI-SubscriptionInventory-REST.ps1 `
        -WorkspaceNameLike 'Finance*','*Lakehouse*' `
        -InternalDomains 'bc.com','abc.com'

.EXAMPLE
    # Service principal
    .\2_Get-PBI-SubscriptionInventory-REST.ps1 `
        -TenantId '<tenant-guid>' -ClientId '<app-guid>' -ClientSecret '<secret>' `
        -InternalDomains 'bc.com'

.NOTES
    The subscription endpoints are documented as PREVIEW API calls. Validate the
    output against the workspace Subscriptions UI before presenting it as final.
#>

[CmdletBinding(DefaultParameterSetName = 'Delegated')]
param(
    [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory)]
    [string] $TenantId,

    [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory)]
    [string] $ClientId,

    [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory)]
    [string] $ClientSecret,

    # Email domains considered internal. Everything else is flagged external.
    [string[]] $InternalDomains = @('bc.com'),

    # Optional wildcard filters on workspace name. Empty = every workspace.
    [string[]] $WorkspaceNameLike = @(),

    # Hard stop below the documented 200-requests-per-hour ceiling.
    [int] $MaxApiCalls = 190,

    [string] $OutputFolder = (Join-Path (Get-Location) 'PBI-Audit-Output'),

    # Include dashboard subscriptions as well as report subscriptions.
    [bool] $IncludeDashboards = $true
)

$ErrorActionPreference = 'Stop'
$apiRoot = 'https://api.powerbi.com/v1.0/myorg/admin'

if (-not (Test-Path -LiteralPath $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Authentication - two routes
# ---------------------------------------------------------------------------
function Get-AuthHeader {
    if ($PSCmdlet.ParameterSetName -eq 'ServicePrincipal') {
        Write-Host "Acquiring a token as a service principal..." -ForegroundColor Cyan
        $body = @{
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = 'https://analysis.windows.net/powerbi/api/.default'
            grant_type    = 'client_credentials'
        }
        $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        $resp = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $body `
                                  -ContentType 'application/x-www-form-urlencoded'
        return @{ Authorization = "Bearer $($resp.access_token)" }
    }
    else {
        Write-Host "Signing in interactively (Fabric Administrator required)..." -ForegroundColor Cyan
        Import-Module MicrosoftPowerBIMgmt.Profile -ErrorAction Stop
        Connect-PowerBIServiceAccount | Out-Null
        # Returns a string already prefixed with 'Bearer '
        return @{ Authorization = (Get-PowerBIAccessToken -AsString) }
    }
}

$headers   = Get-AuthHeader
$callCount = 0

function Invoke-Admin {
    param([string]$Uri)

    if ($script:callCount -ge $MaxApiCalls) {
        throw "Reached the -MaxApiCalls limit of $MaxApiCalls. The API allows 200 requests per hour; re-run later or narrow the scope with -WorkspaceNameLike."
    }
    $script:callCount++

    try {
        return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -ErrorAction Stop
    }
    catch {
        $status = $null
        if ($_.Exception.Response) { $status = $_.Exception.Response.StatusCode.value__ }
        if ($status -eq 429) {
            Write-Warning "Throttled (HTTP 429). Pausing 60 seconds..."
            Start-Sleep -Seconds 60
            $script:callCount++
            return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -ErrorAction Stop
        }
        Write-Warning ("Call failed [{0}]: {1} - {2}" -f $status, $Uri, $_.Exception.Message)
        return $null
    }
}

# ---------------------------------------------------------------------------
# 1. Workspaces, with their reports and dashboards
# ---------------------------------------------------------------------------
Write-Host "Retrieving workspaces..." -ForegroundColor Cyan
$groupsUri = "$apiRoot/groups?`$top=5000&`$expand=reports,dashboards"
$groups    = (Invoke-Admin -Uri $groupsUri).value

if (-not $groups) { throw "No workspaces returned. Confirm the caller has Fabric Administrator rights or admin-API access." }

if ($WorkspaceNameLike.Count -gt 0) {
    $groups = $groups | Where-Object {
        $name = $_.name
        ($WorkspaceNameLike | Where-Object { $name -like $_ }).Count -gt 0
    }
}

$reportCount    = ($groups.reports    | Measure-Object).Count
$dashboardCount = ($groups.dashboards | Measure-Object).Count
Write-Host ("  {0} workspace(s), {1} report(s), {2} dashboard(s) in scope" -f @($groups).Count, $reportCount, $dashboardCount)

$plannedCalls = $reportCount + $(if ($IncludeDashboards) { $dashboardCount } else { 0 })
if ($plannedCalls -gt $MaxApiCalls) {
    Write-Warning ("This scope needs about {0} calls but -MaxApiCalls is {1}. Narrow the scope with -WorkspaceNameLike, or run it in batches across hours." -f $plannedCalls, $MaxApiCalls)
}

# ---------------------------------------------------------------------------
# 2 + 3. Subscriptions per item
# ---------------------------------------------------------------------------
function Test-IsExternal {
    param([string]$Email)
    if ([string]::IsNullOrWhiteSpace($Email)) { return $null }
    if ($Email -notlike '*@*') { return $true }
    $domain = ($Email -split '@')[-1].Trim().ToLower()
    return (-not ($InternalDomains | ForEach-Object { $_.ToLower() } | Where-Object { $_ -eq $domain }))
}

$rows = New-Object System.Collections.Generic.List[object]
$raw  = New-Object System.Collections.Generic.List[object]

foreach ($g in $groups) {

    $items = @()
    foreach ($r in @($g.reports))    { $items += [PSCustomObject]@{ Kind='Report';    Id=$r.id; Name=$r.name; Path="reports" } }
    if ($IncludeDashboards) {
        foreach ($d in @($g.dashboards)) { $items += [PSCustomObject]@{ Kind='Dashboard'; Id=$d.id; Name=$d.displayName; Path="dashboards" } }
    }

    foreach ($item in $items) {

        if (-not $item.Id) { continue }
        $uri  = "$apiRoot/$($item.Path)/$($item.Id)/subscriptions"
        $resp = Invoke-Admin -Uri $uri
        if (-not $resp -or -not $resp.value) { continue }

        foreach ($s in $resp.value) {

            [void]$raw.Add([PSCustomObject]@{
                WorkspaceName = $g.name
                WorkspaceId   = $g.id
                ItemKind      = $item.Kind
                ItemName      = $item.Name
                Subscription  = $s
            })

            $recipients = @($s.users)
            if ($recipients.Count -eq 0) { $recipients = @([PSCustomObject]@{ emailAddress = $null; displayName = $null; principalType = $null; userType = $null }) }

            foreach ($u in $recipients) {
                [void]$rows.Add([PSCustomObject]@{
                    WorkspaceName        = $g.name
                    WorkspaceId          = $g.id
                    CapacityId           = $g.capacityId
                    IsOnDedicatedCapacity= $g.isOnDedicatedCapacity
                    ItemKind             = $item.Kind
                    ItemName             = $item.Name
                    ItemId               = $item.Id
                    SubscriptionId       = $s.id
                    SubscriptionTitle    = $s.title
                    ArtifactType         = $s.artifactType
                    ArtifactDisplayName  = $s.artifactDisplayName
                    ReportPage           = $s.subArtifactDisplayName
                    IsEnabled            = $s.isEnabled
                    Frequency            = $s.frequency
                    StartDate            = $s.startDate
                    EndDate              = $s.endDate
                    AttachmentFormat     = $s.attachmentFormat
                    LinkToContent        = $s.linkToContent
                    PreviewImage         = $s.previewImage
                    RecipientName        = $u.displayName
                    RecipientEmail       = $u.emailAddress
                    RecipientPrincipal   = $u.principalType
                    RecipientUserType    = $u.userType
                    IsExternal           = (Test-IsExternal -Email $u.emailAddress)
                })
            }
        }
    }
}

Write-Host ("API calls used: {0}" -f $callCount)

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
$invPath = Join-Path $OutputFolder 'Subscription_Inventory.csv'
$extPath = Join-Path $OutputFolder 'Subscription_External.csv'
$rawPath = Join-Path $OutputFolder 'Subscription_Inventory.json'

if ($rows.Count -gt 0) {
    $rows | Sort-Object WorkspaceName, ItemName, SubscriptionTitle |
        Export-Csv -LiteralPath $invPath -NoTypeInformation -Encoding UTF8
    Write-Host ("Wrote {0} subscription/recipient rows -> {1}" -f $rows.Count, $invPath) -ForegroundColor Green

    $external = $rows | Where-Object { $_.IsExternal -eq $true }
    if ($external) {
        $external | Export-Csv -LiteralPath $extPath -NoTypeInformation -Encoding UTF8
        Write-Host ("Wrote {0} EXTERNAL recipient rows -> {1}" -f @($external).Count, $extPath) -ForegroundColor Yellow
    }
    else {
        Write-Host "No external recipients found in the scoped workspaces."
    }
}
else {
    Write-Warning "No subscriptions found in the scoped workspaces."
}

$raw | ConvertTo-Json -Depth 15 | Out-File -LiteralPath $rawPath -Encoding utf8

Write-Host ""
Write-Host "How to read the output:" -ForegroundColor Cyan
Write-Host "  * IsExternal = TRUE with IsOnDedicatedCapacity = TRUE is the live non-compliant path."
Write-Host "  * IsExternal = TRUE with IsOnDedicatedCapacity = FALSE will not actually deliver -"
Write-Host "    external recipients require a paid, non-PPU capacity regardless of tenant settings."
Write-Host "  * AttachmentFormat tells you which export-format tenant switches are in play."
Write-Host "  * This does NOT show who CREATED the subscription. Join to script 1's output on"
Write-Host "    ItemId / ItemName to get the creator, within the activity log's 28-day window."
