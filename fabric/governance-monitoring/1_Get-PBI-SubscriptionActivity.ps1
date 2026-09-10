<#
.SYNOPSIS
    Extracts Power BI / Fabric activity-log events relating to email subscriptions.

.DESCRIPTION
    Uses the Get-PowerBIActivityEvent cmdlet (which wraps the Get Activity Events
    admin REST API and handles continuation tokens automatically) to pull activity
    events one UTC day at a time, then filters to subscription-related operations.

    Outputs:
      raw\activity_<yyyy-MM-dd>.json   - full untouched daily payloads (keep these)
      Subscription_Activity.csv        - filtered, flattened subscription events
      Operation_Names_Found.csv        - every distinct operation name seen, with counts

    KNOWN LIMITS (by design of the API, not this script):
      * History is limited to roughly the last 28 days / four weeks. Subscriptions
        created before that window will NOT appear here - you will only see later
        activity, if any. Plan the investigation accordingly.
      * Start and end date must fall on the same UTC day, so this loops per day.
      * Most audit events appear within 30 minutes, but there can be a lag of up
        to 60 minutes for Power BI events. Do not treat "today" as complete.
      * Report Server / SSRS subscriptions do NOT appear in this log at all.
        Use script 3 for that plane.

.PREREQUISITES
      * Fabric Administrator role.
      * Power BI Management cmdlets installed:
            Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser
        (or run in Azure Cloud Shell)

.EXAMPLE
    .\1_Get-PBI-SubscriptionActivity.ps1 -DaysBack 28

.EXAMPLE
    # Narrow to the Data Services team members who create subscriptions on behalf of others
    .\1_Get-PBI-SubscriptionActivity.ps1 -DaysBack 28 -Users 'someone@bc.com','someoneelse@bc.com'

.NOTES
    Provided as-is for investigation purposes. Review before running in production.
#>

[CmdletBinding()]
param(
    # API history window. Maximum supported is 28.
    [ValidateRange(1, 28)]
    [int] $DaysBack = 28,

    # Where to write the output.
    [string] $OutputFolder = (Join-Path (Get-Location) 'PBI-Audit-Output'),

    # Regex matched against the Operation / Activity name. 'Subscri' catches
    # Create/Update/Delete/Run subscription operations without hard-coding names
    # that may change. Confirm the exact names against the Fabric operation list.
    [string] $OperationMatch = 'Subscri',

    # Optional: restrict the flattened CSV to these user principal names.
    [string[]] $Users = @(),

    # Seconds to pause between daily calls (be polite to the API).
    [int] $ThrottleSeconds = 2
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
$rawFolder = Join-Path $OutputFolder 'raw'
foreach ($folder in @($OutputFolder, $rawFolder)) {
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
}

Write-Host "Signing in to the Power BI service (a Fabric Administrator account is required)..." -ForegroundColor Cyan
Connect-PowerBIServiceAccount | Out-Null

# Helper: read a property that may or may not exist, and may vary in casing.
function Get-Prop {
    param($Object, [string[]]$Names)
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Pull one UTC day at a time
# ---------------------------------------------------------------------------
$allEvents = New-Object System.Collections.Generic.List[object]
$todayUtc  = (Get-Date).ToUniversalTime().Date

for ($i = $DaysBack - 1; $i -ge 0; $i--) {

    $day   = $todayUtc.AddDays(-$i)
    $start = $day.ToString('yyyy-MM-ddT00:00:00')
    $end   = $day.ToString('yyyy-MM-ddT23:59:59')
    $label = $day.ToString('yyyy-MM-dd')

    Write-Host ("  Retrieving {0} (UTC)..." -f $label) -NoNewline

    try {
        $dayEvents = Get-PowerBIActivityEvent `
                        -StartDateTime $start `
                        -EndDateTime   $end `
                        -ResultType    JsonObject
    }
    catch {
        Write-Host ""
        Write-Warning ("  Failed for {0}: {1}" -f $label, $_.Exception.Message)
        continue
    }

    if (-not $dayEvents) {
        Write-Host "  0 events"
        continue
    }

    # Always keep the raw payload - the schema differs per event type and
    # evolves over time, so do not throw anything away at extract time.
    $rawPath = Join-Path $rawFolder ("activity_{0}.json" -f $label)
    $dayEvents | ConvertTo-Json -Depth 15 | Out-File -LiteralPath $rawPath -Encoding utf8

    foreach ($e in $dayEvents) { [void]$allEvents.Add($e) }
    Write-Host ("  {0} events" -f $dayEvents.Count)

    if ($ThrottleSeconds -gt 0) { Start-Sleep -Seconds $ThrottleSeconds }
}

Write-Host ("Total events retrieved: {0}" -f $allEvents.Count) -ForegroundColor Green

if ($allEvents.Count -eq 0) {
    Write-Warning "No activity events returned. Check the account has Fabric Administrator rights."
    return
}

# ---------------------------------------------------------------------------
# Distinct operation names - use this to confirm the real subscription
# operation names in this tenant before trusting the filter below.
# ---------------------------------------------------------------------------
$opsPath = Join-Path $OutputFolder 'Operation_Names_Found.csv'
$allEvents |
    Group-Object -Property { Get-Prop $_ @('Operation','Activity') } |
    Sort-Object Count -Descending |
    Select-Object @{n='Operation';e={$_.Name}}, Count |
    Export-Csv -LiteralPath $opsPath -NoTypeInformation -Encoding UTF8
Write-Host "Wrote distinct operation names -> $opsPath"

# ---------------------------------------------------------------------------
# Filter to subscription operations and flatten
# ---------------------------------------------------------------------------
$subEvents = $allEvents | Where-Object {
    $op  = Get-Prop $_ @('Operation')
    $act = Get-Prop $_ @('Activity')
    ($op -and $op -match $OperationMatch) -or ($act -and $act -match $OperationMatch)
}

if ($Users.Count -gt 0) {
    $subEvents = $subEvents | Where-Object {
        $u = Get-Prop $_ @('UserId','UserKey')
        $u -and ($Users -contains $u)
    }
}

$flat = foreach ($e in $subEvents) {
    [PSCustomObject]@{
        CreationTimeUtc = Get-Prop $e @('CreationTime')
        UserId          = Get-Prop $e @('UserId')
        Operation       = Get-Prop $e @('Operation','Activity')
        IsSuccess       = Get-Prop $e @('IsSuccess')
        WorkspaceName   = Get-Prop $e @('WorkSpaceName','WorkspaceName')
        WorkspaceId     = Get-Prop $e @('WorkspaceId','WorkSpaceId')
        ItemName        = Get-Prop $e @('ItemName','ArtifactName','ReportName','DatasetName')
        ItemType        = Get-Prop $e @('ArtifactKind','ReportType','ObjectType')
        ItemId          = Get-Prop $e @('ArtifactId','ObjectId','ReportId')
        CapacityName    = Get-Prop $e @('CapacityName')
        CapacityId      = Get-Prop $e @('CapacityId')
        DistributionBy  = Get-Prop $e @('DistributionMethod')
        ConsumptionBy   = Get-Prop $e @('ConsumptionMethod')
        ClientIP        = Get-Prop $e @('ClientIP')
        RequestId       = Get-Prop $e @('RequestId')
    }
}

$csvPath = Join-Path $OutputFolder 'Subscription_Activity.csv'
if ($flat) {
    $flat | Sort-Object CreationTimeUtc |
        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host ("Wrote {0} subscription events -> {1}" -f @($flat).Count, $csvPath) -ForegroundColor Green
}
else {
    Write-Warning "No events matched '$OperationMatch'. Open Operation_Names_Found.csv and adjust -OperationMatch."
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Open Operation_Names_Found.csv and confirm the subscription operation names."
Write-Host "  2. In Subscription_Activity.csv, compare CreationTimeUtc against the date the"
Write-Host "     external-subscription tenant setting was tightened. Events BEFORE that date"
Write-Host "     mean pre-existing subscriptions still running; events AFTER mean new ones"
Write-Host "     are still being created and the control is not covering that path."
Write-Host "  3. Note the CapacityName column - external recipients are only permitted on"
Write-Host "     workspaces backed by a paid, non-PPU capacity."
