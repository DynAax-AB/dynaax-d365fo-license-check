#Requires -Version 7.0
<#
.SYNOPSIS
    Shows which Dynamics 365 F&O licences are paid for but not used, and what
    that costs per month.

.DESCRIPTION
    Read only. Reads from Microsoft Graph: the tenant's Dynamics 365 licences,
    the users who hold them and their last sign-in. Optionally reads the F&O
    users (SystemUsers) and the licence their security roles need
    (SecurityUserRoles) from one F&O environment, usually production.

    Writes a per-user CSV and a one-page HTML summary without names. Nothing
    is changed in Entra or F&O, and nothing is sent anywhere.

.PARAMETER TenantId
    The Entra tenant ID or domain.

.PARAMETER SettingsFile
    A JSON settings file: days without sign-in that count as inactive, your
    prices per month, accounts to leave out. See settings.example.json.

.PARAMETER InactiveDays
    Overrides inactiveDays from the settings file. Default 90.

.PARAMETER FoEnvironmentUrl
    Optional. One F&O environment to compare with, usually production.

.PARAMETER OutputFolder
    Where to write the files. Default: ./output

.PARAMETER Demo
    Use made-up data instead of signing in.

.EXAMPLE
    ./Get-FoLicenceCheck.ps1 -Demo

.EXAMPLE
    ./Get-FoLicenceCheck.ps1 -TenantId contoso.onmicrosoft.com -SettingsFile ./settings.json `
        -FoEnvironmentUrl https://contoso-prod.operations.dynamics.com
#>
[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(ParameterSetName = 'Live')][string] $TenantId,
    [string] $SettingsFile,
    [ValidateRange(1, 3650)][int] $InactiveDays,
    [Parameter(ParameterSetName = 'Live')][string] $FoEnvironmentUrl,
    [string] $OutputFolder = (Join-Path (Get-Location) 'output'),
    [Parameter(ParameterSetName = 'Demo')][switch] $Demo
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/FoLicenceCheck/FoLicenceCheck.psd1') -Force

$now = Get-Date
$settings = Read-LicenceSetting -Path $SettingsFile
if ($PSBoundParameters.ContainsKey('InactiveDays')) { $settings.InactiveDays = $InactiveDays }

$foUsers = $null
$foRoleTier = $null
$foStatus = ''
$signInAvailable = $true
$tenantDomains = @()

if ($Demo) {
    Write-Host 'Demo mode: using made-up data. Nothing is read from Entra or F&O.' -ForegroundColor Yellow
    $demoData = New-DemoData -Now $now
    $skus = $demoData.Skus
    $users = $demoData.Users
    $foUsers = $demoData.FoUsers
    $foRoleTier = $demoData.FoRoleTier
    $settings.Prices = $demoData.Prices
    $settings.Currency = $demoData.Currency
    $foStatus = 'F&O users and roles compared with the demo environment.'
    $tenantLabel = 'Demo tenant (made-up data and prices)'
    $tenantDomains = @('contoso.com')
}
else {
    foreach ($module in 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.Identity.DirectoryManagement') {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            throw "The $module module is missing. Install it with: Install-Module $module -Scope CurrentUser"
        }
    }
    $scopes = 'User.Read.All', 'AuditLog.Read.All', 'Organization.Read.All'
    $context = Get-MgContext
    $reuse = $context -and -not ($scopes | Where-Object { $_ -notin $context.Scopes }) -and (-not $TenantId -or $context.TenantId -eq $TenantId)
    if ($reuse) {
        Write-Host 'Using the existing Microsoft Graph sign-in.'
    }
    else {
        Write-Host 'Signing in to Microsoft Graph (read only)...'
        $graphArgs = @{ Scopes = $scopes; NoWelcome = $true }
        if ($TenantId) { $graphArgs.TenantId = $TenantId }
        Connect-MgGraph @graphArgs | Out-Null
    }
    $tenantLabel = "Tenant $((Get-MgContext).TenantId)"
    $tenantDomains = @(Get-TenantDomain)

    Write-Host 'Reading Dynamics 365 licences...'
    $skus = @(Get-DynamicsSku -SkuMap $settings.Skus)
    Write-Host "  $($skus.Count) Dynamics 365 F&O licence types found."

    Write-Host 'Reading licensed users and their last sign-in...'
    $result = Get-LicensedUser -Sku $skus
    $users = $result.Users
    $signInAvailable = $result.SignInAvailable
    Write-Host "  $($users.Count) licensed users."

    if ($FoEnvironmentUrl) {
        if (-not (Get-Module -ListAvailable -Name 'Az.Accounts')) {
            throw 'The Az.Accounts module is missing. It is used to sign in to F&O. Install it with: Install-Module Az.Accounts -Scope CurrentUser'
        }
        $base = ConvertTo-FoEnvironmentUrl $FoEnvironmentUrl
        try {
            $azContext = Get-AzContext -ErrorAction SilentlyContinue
            if ($azContext -and (-not $TenantId -or $azContext.Tenant.Id -eq $TenantId)) {
                Write-Host 'Using the existing sign-in for F&O.'
            }
            else {
                Write-Host "Signing in to F&O ($base)..."
                Update-AzConfig -LoginExperienceV2 Off -Scope Process -WarningAction SilentlyContinue | Out-Null
                # The macOS sign-in broker only works from an app's main thread, so use the browser instead.
                if (-not $IsWindows) { Update-AzConfig -EnableLoginByWam $false -Scope Process -WarningAction SilentlyContinue | Out-Null }
                $azArgs = @{ WarningAction = 'SilentlyContinue' }
                if ($TenantId) { $azArgs.Tenant = $TenantId }
                Connect-AzAccount @azArgs | Out-Null
            }
            $token = Get-FoAccessToken -EnvironmentUrl $base
            Write-Host 'Reading F&O users...'
            $foUsers = @(Get-FoSystemUser -EnvironmentUrl $base -AccessToken $token)
            try {
                Write-Host 'Reading the licence each user''s F&O roles need...'
                $foRoleTier = Get-FoRoleLicence -EnvironmentUrl $base -AccessToken $token
                $foStatus = "F&O users and roles compared with $base."
            }
            catch {
                Write-Warning "Could not read SecurityUserRoles: $($_.Exception.Message). Role-based licence checks are skipped."
                $foStatus = "F&O users compared with $base. Role licences could not be read."
            }
        }
        catch {
            Write-Warning "Could not read F&O users: $($_.Exception.Message). The F&O checks are skipped."
            $foUsers = $null
            $foStatus = "F&O could not be read ($base), so the F&O checks were skipped."
        }
    }
}

if ($null -ne $foUsers -and $tenantDomains.Count) {
    $otherDomain = Get-OtherDomainFoUserCount -FoUser $foUsers -TenantDomain $tenantDomains
    if ($otherDomain -gt 0) {
        $foStatus += " $otherDomain enabled F&O users from other domains (demo data, service accounts, other tenants) were not checked, because they can't hold a licence in this tenant."
    }
}
$rows = @(ConvertTo-LicenceUserRow -User $users -Sku $skus -Now $now -InactiveDays $settings.InactiveDays `
    -SignInAvailable $signInAvailable -ExcludeUsers $settings.ExcludeUsers -FoUser $foUsers -FoRoleTier $foRoleTier `
    -TenantDomain $tenantDomains)
$summary = @(Get-LicenceSummary -Row $rows -Sku $skus -Prices $settings.Prices)
$findings = @(Get-FindingCount -Row $rows)

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$stamp = $now.ToString('yyyyMMdd-HHmm')
$htmlPath = Join-Path $OutputFolder "licence-check-summary-$stamp.html"
$csvPath = Join-Path $OutputFolder "licence-check-users-$stamp.csv"

New-LicenceReportHtml -Summary $summary -FindingCount $findings -GeneratedAt $now -InactiveDays $settings.InactiveDays `
    -Currency $settings.Currency -SignInAvailable $signInAvailable -FoStatus $foStatus -TenantLabel $tenantLabel |
    Set-Content -LiteralPath $htmlPath -Encoding utf8
ConvertTo-LicenceCsvRow -Row $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

Write-Host ''
$summary | Format-Table Licence, Bought, Assigned, Active, Inactive, Excluded,
    @{ n = 'InactiveCost'; e = { if ($null -ne $_.InactiveCost) { ([decimal] $_.InactiveCost).ToString('N0') } }; a = 'Right' } -AutoSize | Out-String | Write-Host
foreach ($f in $findings) { Write-Host ("{0,5}  {1}" -f $f.Users, $f.Finding) }
Write-Host ''
Write-Host "Summary (no names): $htmlPath"
Write-Host "Per-user CSV (personal data, keep it private): $csvPath"
