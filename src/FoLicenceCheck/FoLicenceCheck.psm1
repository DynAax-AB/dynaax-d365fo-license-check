#Requires -Version 7.0
<#
    FoLicenceCheck: shows which Dynamics 365 F&O licences are paid for but not
    used, and what that costs per month. Read only: it reads Microsoft Graph
    and, optionally, F&O. It changes nothing.
#>

Set-StrictMode -Version Latest

# Licence tiers, highest first. Used to compare what a user holds with what
# their F&O security roles need.
$script:TierRank = @{ 'Enterprise' = 3; 'Activity' = 2; 'Team Members' = 1; 'None' = 0 }

# --- Small helpers ---------------------------------------------------------

function Get-Value {
    # Reads a property without failing under strict mode when it is missing.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

function ConvertTo-FoEnvironmentUrl {
    <# Turns a pasted address into https://<host>. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Url)
    $text = $Url.Trim()
    if ($text -notmatch '^[a-z]+://') { $text = "https://$text" }
    $uri = $null
    if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref] $uri) -or -not $uri.Host) {
        throw "'$Url' is not a valid F&O environment address."
    }
    if ($uri.Scheme -ne 'https') { throw "'$Url' must use https." }
    "https://$($uri.Host.ToLowerInvariant())"
}

function Get-DefaultSkuMap {
    <#
    .SYNOPSIS
        The Dynamics 365 licences this tool looks at, by SKU part number, with
        a friendly name and a tier. Taken from Microsoft's published list of
        product names and service plan identifiers. Add others in settings.
    #>
    [CmdletBinding()]
    param()
    [ordered]@{
        'DYN365_FINANCE'                                = @{ Name = 'Finance'; Tier = 'Enterprise' }
        'DYN365_FINANCE_ATTACH'                         = @{ Name = 'Finance (attach)'; Tier = 'Enterprise' }
        'DYN365_SCM'                                    = @{ Name = 'Supply Chain Management'; Tier = 'Enterprise' }
        'DYN365_SCM_ATTACH'                             = @{ Name = 'Supply Chain Management (attach)'; Tier = 'Enterprise' }
        'Dynamics_365_Supply_Chain_Management_Premium'  = @{ Name = 'Supply Chain Management Premium'; Tier = 'Enterprise' }
        'DYN365_RETAIL'                                 = @{ Name = 'Commerce'; Tier = 'Enterprise' }
        'DYN365_PROJECT_OPERATIONS'                     = @{ Name = 'Project Operations'; Tier = 'Enterprise' }
        'DYN365_PROJECT_OPERATIONS_ATTACH'              = @{ Name = 'Project Operations (attach)'; Tier = 'Enterprise' }
        'DYN365_HUMAN_RESOURCES_ATTACH'                 = @{ Name = 'Human Resources (attach)'; Tier = 'Enterprise' }
        'Dyn365_Operations_Activity'                    = @{ Name = 'Operations - Activity'; Tier = 'Activity' }
        'DYN365_TEAM_MEMBERS'                           = @{ Name = 'Team Members'; Tier = 'Team Members' }
        'DYN365_ENTERPRISE_TEAM_MEMBERS'                = @{ Name = 'Team Members (Enterprise edition)'; Tier = 'Team Members' }
    }
}

function Read-LicenceSetting {
    <#
    .SYNOPSIS
        Reads the settings file (JSON) and fills in defaults. Without a file,
        returns the defaults: 90 days, no prices, nobody excluded.
    #>
    [CmdletBinding()]
    param([string] $Path)
    $settings = [pscustomobject]@{
        InactiveDays = 90
        Currency     = ''
        Prices       = @{}
        ExcludeUsers = @()
        Skus         = Get-DefaultSkuMap
    }
    if (-not $Path) { return $settings }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Settings file not found: $Path" }
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($json.ContainsKey('inactiveDays')) {
        $days = [int] $json['inactiveDays']
        if ($days -lt 1) { throw 'inactiveDays must be 1 or more.' }
        $settings.InactiveDays = $days
    }
    if ($json.ContainsKey('currency')) { $settings.Currency = "$($json['currency'])" }
    if ($json.ContainsKey('pricesPerMonth') -and $json['pricesPerMonth']) {
        foreach ($key in $json['pricesPerMonth'].Keys) {
            $value = $json['pricesPerMonth'][$key]
            if ($null -ne $value -and "$value" -ne '') { $settings.Prices[$key] = [decimal] $value }
        }
    }
    if ($json.ContainsKey('excludeUsers') -and $json['excludeUsers']) {
        $settings.ExcludeUsers = @($json['excludeUsers'] | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
    }
    if ($json.ContainsKey('extraSkus') -and $json['extraSkus']) {
        foreach ($key in $json['extraSkus'].Keys) {
            $extra = $json['extraSkus'][$key]
            $tier = if ($extra['tier']) { "$($extra['tier'])" } else { 'Enterprise' }
            if (-not $script:TierRank.ContainsKey($tier)) { throw "Unknown tier '$tier' for $key. Use Enterprise, Activity or Team Members." }
            $settings.Skus[$key] = @{ Name = "$($extra['name'])"; Tier = $tier }
        }
    }
    $settings
}

function Get-LastSignIn {
    <#
    .SYNOPSIS
        The latest of the interactive, non-interactive and successful sign-in
        dates. People who only use F&O through Excel, Power BI or
        integrations have non-interactive sign-ins only.
    #>
    [CmdletBinding()]
    param($SignInActivity)
    if ($null -eq $SignInActivity) { return $null }
    $dates = foreach ($name in 'LastSignInDateTime', 'LastNonInteractiveSignInDateTime', 'LastSuccessfulSignInDateTime') {
        $value = Get-Value $SignInActivity $name
        if ($value) { [datetime] $value }
    }
    $dates | Sort-Object -Descending | Select-Object -First 1
}

function Get-TierFromLicenceType {
    <# Maps the F&O UserLicenseType value to a tier name. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $LicenseType)
    switch -Regex ($LicenseType) {
        '^Enterprise' { 'Enterprise'; break }
        '^Activity' { 'Activity'; break }
        '^(Universal|TeamMember)' { 'Team Members'; break }
        default { 'None' }
    }
}

# --- Reading Microsoft Graph ------------------------------------------------

function Get-DynamicsSku {
    <#
    .SYNOPSIS
        The Dynamics 365 licences the tenant has bought. Needs
        Organization.Read.All. Read only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $SkuMap)
    foreach ($sku in @(Get-MgSubscribedSku -All -ErrorAction Stop)) {
        $part = Get-Value $sku 'SkuPartNumber'
        if (-not $SkuMap.Contains($part)) { continue }
        $prepaid = Get-Value $sku 'PrepaidUnits'
        [pscustomobject]@{
            SkuId         = "$(Get-Value $sku 'SkuId')"
            SkuPartNumber = $part
            Name          = $SkuMap[$part].Name
            Tier          = $SkuMap[$part].Tier
            Bought        = [int] (Get-Value $prepaid 'Enabled')
            Assigned      = [int] (Get-Value $sku 'ConsumedUnits')
        }
    }
}

function Get-LicensedUser {
    <#
    .SYNOPSIS
        Users who hold at least one of the given licences, with their
        last sign-in. Needs User.Read.All and, for sign-in dates,
        AuditLog.Read.All plus Entra ID P1 or P2. Read only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Sku)
    $withSignIn = 'id,displayName,userPrincipalName,accountEnabled,userType,assignedLicenses,signInActivity'
    $withoutSignIn = 'id,displayName,userPrincipalName,accountEnabled,userType,assignedLicenses'
    $signInAvailable = $true
    $users = @{}
    foreach ($s in $Sku) {
        $filter = "assignedLicenses/any(x:x/skuId eq $($s.SkuId))"
        $found = $null
        if ($signInAvailable) {
            try {
                $found = @(Get-MgUser -All -Filter $filter -Property $withSignIn -ErrorAction Stop)
            }
            catch {
                Write-Warning "Last sign-in dates are not available ($($_.Exception.Message)). They need Entra ID P1 or P2 and the AuditLog.Read.All permission. The report continues without them."
                $signInAvailable = $false
            }
        }
        if (-not $signInAvailable) {
            $found = @(Get-MgUser -All -Filter $filter -Property $withoutSignIn -ErrorAction Stop)
        }
        foreach ($u in $found) { $users["$(Get-Value $u 'Id')"] = $u }
    }
    [pscustomobject]@{ Users = @($users.Values); SignInAvailable = $signInAvailable }
}

# --- Reading F&O -------------------------------------------------------------

function Get-FoAccessToken {
    <# A token for one F&O environment from the current Az.Accounts session. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $EnvironmentUrl)
    $token = (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -ErrorAction Stop).Token
    if ($token -is [securestring]) { return [System.Net.NetworkCredential]::new('', $token).Password }
    $token
}

function Invoke-FoODataQuery {
    <#
    .SYNOPSIS
        Reads every page of one F&O OData entity with GET. If the field list
        is refused (a field is missing in this version), retries without it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $EnvironmentUrl,
        [Parameter(Mandatory)][string] $AccessToken,
        [Parameter(Mandatory)][string] $Entity,
        [string[]] $Select = @()
    )
    $base = ConvertTo-FoEnvironmentUrl $EnvironmentUrl
    $headers = @{ Authorization = "Bearer $AccessToken"; Accept = 'application/json' }
    $first = "$base/data/$Entity"
    $next = if ($Select.Count) { "$first`?`$select=$($Select -join ',')" } else { $first }
    $retried = $false
    while ($next) {
        try {
            $page = Invoke-RestMethod -Method Get -Uri $next -Headers $headers -ErrorAction Stop
        }
        catch {
            $code = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $code = [int] $_.Exception.Response.StatusCode }
            if ($code -eq 400 -and $Select.Count -and -not $retried) {
                Write-Verbose "$Entity refused the field list; reading all fields instead."
                $retried = $true
                $next = $first
                continue
            }
            throw
        }
        foreach ($row in @(Get-Value $page 'value')) { if ($null -ne $row) { $row } }
        $next = Get-Value $page '@odata.nextLink'
    }
}

function Get-FoSystemUser {
    <# F&O users (entity SystemUsers): ID, name, sign-in alias, email, enabled. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $EnvironmentUrl,
        [Parameter(Mandatory)][string] $AccessToken
    )
    $rows = Invoke-FoODataQuery -EnvironmentUrl $EnvironmentUrl -AccessToken $AccessToken -Entity 'SystemUsers' `
        -Select 'UserID', 'UserName', 'Alias', 'Email', 'Enabled'
    foreach ($row in $rows) {
        $enabled = Get-Value $row 'Enabled'
        [pscustomobject]@{
            UserId  = "$(Get-Value $row 'UserID')"
            Name    = "$(Get-Value $row 'UserName')"
            Alias   = "$(Get-Value $row 'Alias')".Trim().ToLowerInvariant()
            Email   = "$(Get-Value $row 'Email')".Trim().ToLowerInvariant()
            Enabled = ($enabled -eq $true -or "$enabled" -in 'Yes', 'True', '1')
        }
    }
}

function Get-FoRoleLicence {
    <#
    .SYNOPSIS
        The licence each F&O user's security roles call for (entity
        SecurityUserRoles, field UserLicenseType), as the highest tier across
        the user's active role assignments.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $EnvironmentUrl,
        [Parameter(Mandatory)][string] $AccessToken
    )
    $rows = Invoke-FoODataQuery -EnvironmentUrl $EnvironmentUrl -AccessToken $AccessToken -Entity 'SecurityUserRoles' `
        -Select 'UserId', 'SecurityRoleName', 'UserLicenseType', 'AssignmentStatus'
    ConvertTo-FoRoleLicence -Assignment @($rows)
}

function ConvertTo-FoRoleLicence {
    <# Groups role assignments by user and keeps the highest licence tier. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Assignment)
    $byUser = @{}
    foreach ($a in $Assignment) {
        $status = "$(Get-Value $a 'AssignmentStatus')"
        if ($status -match 'Disabled|Expired|Removed') { continue }
        $user = "$(Get-Value $a 'UserId')".ToLowerInvariant()
        if (-not $user) { continue }
        $tier = Get-TierFromLicenceType "$(Get-Value $a 'UserLicenseType')"
        if (-not $byUser.ContainsKey($user) -or $script:TierRank[$tier] -gt $script:TierRank[$byUser[$user]]) {
            $byUser[$user] = $tier
        }
    }
    $byUser
}

# --- Combining ----------------------------------------------------------------

function ConvertTo-LicenceUserRow {
    <#
    .SYNOPSIS
        One row per licensed user, with findings. Optionally joins F&O users
        (matched on sign-in alias or email) and the licence their roles need.
        F&O users who are enabled but hold no Dynamics licence get their own rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $User,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Sku,
        [Parameter(Mandatory)][datetime] $Now,
        [Parameter(Mandatory)][int] $InactiveDays,
        [bool] $SignInAvailable = $true,
        [string[]] $ExcludeUsers = @(),
        [object[]] $FoUser = $null,
        [hashtable] $FoRoleTier = $null
    )
    $skuById = @{}
    foreach ($s in $Sku) { $skuById["$($s.SkuId)".ToLowerInvariant()] = $s }
    $foChecked = $null -ne $FoUser
    $foByKey = @{}
    if ($foChecked) {
        foreach ($f in $FoUser) {
            foreach ($key in @($f.Alias, $f.Email)) { if ($key -and -not $foByKey.ContainsKey($key)) { $foByKey[$key] = $f } }
        }
    }
    $exclude = @{}
    foreach ($x in $ExcludeUsers) { $exclude["$x".ToLowerInvariant()] = $true }
    $matchedFo = @{}

    foreach ($u in $User) {
        $upn = "$(Get-Value $u 'UserPrincipalName')"
        $key = $upn.ToLowerInvariant()
        $held = @(foreach ($l in @(Get-Value $u 'AssignedLicenses')) {
            $id = "$(Get-Value $l 'SkuId')".ToLowerInvariant()
            if ($skuById.ContainsKey($id)) { $skuById[$id] }
        })
        if ($held.Count -eq 0) { continue }
        $topTier = ($held | Sort-Object { $script:TierRank[$_.Tier] } -Descending | Select-Object -First 1).Tier

        $lastSignIn = if ($SignInAvailable) { Get-LastSignIn (Get-Value $u 'SignInActivity') } else { $null }
        $daysSince = if ($lastSignIn) { [int] [Math]::Floor(($Now.ToUniversalTime() - $lastSignIn.ToUniversalTime()).TotalDays) } else { $null }
        $enabled = [bool] (Get-Value $u 'AccountEnabled')

        $fo = $null
        if ($foChecked -and $foByKey.ContainsKey($key)) { $fo = $foByKey[$key]; $matchedFo[$fo.UserId] = $true }
        $roleTier = $null
        if ($fo -and $FoRoleTier) {
            $roleTier = if ($FoRoleTier.ContainsKey($fo.UserId.ToLowerInvariant())) { $FoRoleTier[$fo.UserId.ToLowerInvariant()] } else { 'None' }
        }

        $findings = [System.Collections.Generic.List[string]]::new()
        $inactive = $false
        if (-not $enabled) { $findings.Add('Disabled in Entra but licensed'); $inactive = $true }
        if ($SignInAvailable) {
            if (-not $lastSignIn) { $findings.Add('Never signed in'); $inactive = $true }
            elseif ($daysSince -gt $InactiveDays) { $findings.Add("No sign-in for over $InactiveDays days"); $inactive = $true }
        }
        if ($foChecked) {
            if (-not $fo) { $findings.Add('Licensed but not a user in F&O'); $inactive = $true }
            elseif (-not $fo.Enabled) { $findings.Add('Disabled in F&O but licensed'); $inactive = $true }
        }
        if ($roleTier -and $enabled -and $fo -and $fo.Enabled) {
            if ($script:TierRank[$roleTier] -gt $script:TierRank[$topTier]) { $findings.Add("F&O roles need $roleTier, user has $topTier") }
            elseif ($script:TierRank[$roleTier] -lt $script:TierRank[$topTier]) { $findings.Add("User has $topTier, F&O roles need only $roleTier") }
        }
        $excluded = $exclude.ContainsKey($key)

        [pscustomobject]@{
            UserPrincipalName = $upn
            DisplayName       = "$(Get-Value $u 'DisplayName')"
            EnabledInEntra    = $enabled
            Licences          = ($held.Name | Sort-Object) -join '; '
            SkuPartNumbers    = @($held.SkuPartNumber)
            LicenceTier       = $topTier
            LastSignIn        = $lastSignIn
            DaysSinceSignIn   = $daysSince
            FoUserId          = if ($fo) { $fo.UserId } else { '' }
            EnabledInFo       = if (-not $foChecked) { '' } elseif (-not $fo) { 'Not found' } elseif ($fo.Enabled) { 'Yes' } else { 'No' }
            FoRolesNeed       = if ($roleTier) { $roleTier } else { '' }
            Excluded          = $excluded
            Inactive          = $inactive -and -not $excluded
            Findings          = if ($excluded) { @() } else { @($findings) }
        }
    }

    if ($foChecked) {
        foreach ($f in $FoUser) {
            if ($matchedFo.ContainsKey($f.UserId) -or -not $f.Enabled) { continue }
            $key = if ($f.Alias) { $f.Alias } else { $f.Email }
            if (-not $key -or $key -notmatch '@') { continue } # built-in and service users have no sign-in name
            $excluded = $exclude.ContainsKey($key)
            [pscustomobject]@{
                UserPrincipalName = $key
                DisplayName       = $f.Name
                EnabledInEntra    = $null
                Licences          = ''
                SkuPartNumbers    = @()
                LicenceTier       = 'None'
                LastSignIn        = $null
                DaysSinceSignIn   = $null
                FoUserId          = $f.UserId
                EnabledInFo       = 'Yes'
                FoRolesNeed       = if ($FoRoleTier -and $FoRoleTier.ContainsKey($f.UserId.ToLowerInvariant())) { $FoRoleTier[$f.UserId.ToLowerInvariant()] } else { '' }
                Excluded          = $excluded
                Inactive          = $false
                Findings          = if ($excluded) { @() } else { @('Enabled in F&O but no Dynamics licence') }
            }
        }
    }
}

function Get-LicenceSummary {
    <#
    .SYNOPSIS
        Per licence: bought, assigned, active, inactive, excluded, and the
        monthly cost of the inactive ones when a price is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Row,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Sku,
        [hashtable] $Prices = @{}
    )
    foreach ($s in $Sku) {
        $holders = @($Row | Where-Object { $s.SkuPartNumber -in $_.SkuPartNumbers })
        $inactive = @($holders | Where-Object Inactive).Count
        $excluded = @($holders | Where-Object Excluded).Count
        $price = if ($Prices.ContainsKey($s.SkuPartNumber)) { [decimal] $Prices[$s.SkuPartNumber] } else { $null }
        [pscustomobject]@{
            Licence        = $s.Name
            SkuPartNumber  = $s.SkuPartNumber
            Bought         = $s.Bought
            Assigned       = $s.Assigned
            Unassigned     = [Math]::Max(0, $s.Bought - $s.Assigned)
            Active         = $holders.Count - $inactive - $excluded
            Inactive       = $inactive
            Excluded       = $excluded
            PricePerMonth  = $price
            InactiveCost   = if ($null -ne $price) { $price * $inactive } else { $null }
            UnassignedCost = if ($null -ne $price) { $price * [Math]::Max(0, $s.Bought - $s.Assigned) } else { $null }
        }
    }
}

function Get-FindingCount {
    <# How many users have each finding. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Row)
    $Row | ForEach-Object { $_.Findings } | Group-Object | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ Finding = $_.Name; Users = $_.Count } }
}

# --- Output -----------------------------------------------------------------

function ConvertTo-LicenceCsvRow {
    <# The per-user CSV columns, in a fixed order. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Row)
    foreach ($r in $Row) {
        [pscustomobject][ordered]@{
            'User'              = $r.UserPrincipalName
            'Name'              = $r.DisplayName
            'Licences'          = $r.Licences
            'Licence tier'      = $r.LicenceTier
            'Enabled in Entra'  = if ($null -eq $r.EnabledInEntra) { '' } elseif ($r.EnabledInEntra) { 'Yes' } else { 'No' }
            'Last sign-in'      = if ($r.LastSignIn) { $r.LastSignIn.ToString('yyyy-MM-dd') } else { '' }
            'Days since sign-in' = $r.DaysSinceSignIn
            'Enabled in F&O'    = $r.EnabledInFo
            'F&O roles need'    = $r.FoRolesNeed
            'Excluded'          = if ($r.Excluded) { 'Yes' } else { 'No' }
            'Inactive'          = if ($r.Inactive) { 'Yes' } else { 'No' }
            'Findings'          = ($r.Findings -join '; ')
        }
    }
}

function New-LicenceReportHtml {
    <#
    .SYNOPSIS
        A one-page summary for the business. Counts and costs only: no names,
        so it can be shared more widely than the per-user CSV.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Summary,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $FindingCount,
        [Parameter(Mandatory)][datetime] $GeneratedAt,
        [int] $InactiveDays = 90,
        [string] $Currency = '',
        [bool] $SignInAvailable = $true,
        [string] $FoStatus = '',
        [string] $TenantLabel = ''
    )
    $e = { param($v) [System.Net.WebUtility]::HtmlEncode("$v") }
    $money = { param($v) if ($null -eq $v) { '&ndash;' } else { (& $e $Currency) + ' ' + ([decimal] $v).ToString('N0', [cultureinfo]::InvariantCulture) } }

    $totalInactive = ($Summary | Measure-Object Inactive -Sum).Sum
    $totalUnassigned = ($Summary | Measure-Object Unassigned -Sum).Sum
    $priced = @($Summary | Where-Object { $null -ne $_.PricePerMonth })
    $inactiveCost = if ($priced.Count) { ($priced | Measure-Object InactiveCost -Sum).Sum } else { $null }
    $unassignedCost = if ($priced.Count) { ($priced | Measure-Object UnassignedCost -Sum).Sum } else { $null }

    $skuRows = ($Summary | ForEach-Object {
        "<tr><td><strong>$(& $e $_.Licence)</strong><br><span class=""muted"">$(& $e $_.SkuPartNumber)</span></td>" +
        "<td class=""num"">$($_.Bought)</td><td class=""num"">$($_.Assigned)</td><td class=""num"">$($_.Unassigned)</td>" +
        "<td class=""num"">$($_.Active)</td><td class=""num bad"">$($_.Inactive)</td><td class=""num"">$($_.Excluded)</td>" +
        "<td class=""num"">$(& $money $_.PricePerMonth)</td><td class=""num bad"">$(& $money $_.InactiveCost)</td></tr>"
    }) -join ''
    if (-not $skuRows) { $skuRows = '<tr><td colspan="9" class="muted">No Dynamics 365 F&amp;O licences found in this tenant.</td></tr>' }

    $findingRows = ($FindingCount | ForEach-Object { "<tr><td>$(& $e $_.Finding)</td><td class=""num"">$($_.Users)</td></tr>" }) -join ''
    if (-not $findingRows) { $findingRows = '<tr><td colspan="2" class="muted">No findings.</td></tr>' }

    $notes = [System.Collections.Generic.List[string]]::new()
    if ($SignInAvailable) { $notes.Add("Inactive means: no sign-in (interactive or not) for over $InactiveDays days, never signed in, disabled, or not set up in F&amp;O.") }
    else { $notes.Add('Last sign-in dates were not available (they need Entra ID P1 or P2), so inactivity is based on disabled accounts and F&amp;O only.') }
    $notes.Add($(if ($FoStatus) { & $e $FoStatus } else { 'F&amp;O was not checked. Add -FoEnvironmentUrl to compare with F&amp;O users and roles.' }))
    if (-not $priced.Count) { $notes.Add('No prices set, so costs are not shown. Add your own prices per month in the settings file.') }
    $notes.Add('Service and integration accounts listed in the settings file are counted as excluded, not inactive.')
    $notesHtml = ($notes | ForEach-Object { "<li>$_</li>" }) -join ''

    @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>F&amp;O licence check</title>
<style>
:root { --bg:#f6f7f9; --panel:#fff; --text:#1d2530; --muted:#5f6b7a; --line:#dfe3e8; --bad:#b42318; --good:#2e7d32 }
@media (prefers-color-scheme: dark) { :root { --bg:#14181d; --panel:#1c2229; --text:#e6e9ed; --muted:#9aa5b1; --line:#2f3944; --bad:#ff8a80; --good:#81c784 } }
* { box-sizing:border-box }
body { margin:0; background:var(--bg); color:var(--text); font:14px/1.5 -apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif }
main { max-width:1100px; margin:0 auto; padding:24px 16px 48px }
h1 { font-size:22px; margin:0 0 4px } h2 { font-size:17px; margin:28px 0 8px }
.muted { color:var(--muted); font-size:12px }
.cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); gap:10px; margin:18px 0 }
.card { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:12px 14px }
.card .value { font-size:26px; font-weight:650 } .card .label { color:var(--muted); font-size:12px }
.card.bad .value { color:var(--bad) }
.scroll { overflow-x:auto; background:var(--panel); border:1px solid var(--line); border-radius:10px }
table { border-collapse:collapse; width:100%; min-width:720px }
th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top }
th { font-size:12px; color:var(--muted); font-weight:600 } tr:last-child td { border-bottom:0 }
.num { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap } td.bad { color:var(--bad); font-weight:600 }
ul.notes { color:var(--muted); padding-left:18px; margin:6px 0 } footer { margin-top:28px; color:var(--muted); font-size:12px }
</style>
</head>
<body><main>
<h1>F&amp;O licence check</h1>
<div class="muted">Generated $($GeneratedAt.ToString('yyyy-MM-dd HH:mm')) $(if ($TenantLabel) { '&middot; ' + (& $e $TenantLabel) })</div>
<div class="cards">
<div class="card bad"><div class="value">$totalInactive</div><div class="label">Licences held by inactive users</div></div>
<div class="card bad"><div class="value">$(& $money $inactiveCost)</div><div class="label">Monthly cost of those licences</div></div>
<div class="card"><div class="value">$totalUnassigned</div><div class="label">Licences bought but not assigned</div></div>
<div class="card"><div class="value">$(& $money $unassignedCost)</div><div class="label">Monthly cost of unassigned licences</div></div>
</div>

<h2>By licence</h2>
<div class="scroll"><table>
<thead><tr><th>Licence</th><th class="num">Bought</th><th class="num">Assigned</th><th class="num">Unassigned</th><th class="num">Active</th><th class="num">Inactive</th><th class="num">Excluded</th><th class="num">Price / month</th><th class="num">Inactive cost / month</th></tr></thead>
<tbody>$skuRows</tbody></table></div>

<h2>Findings</h2>
<div class="scroll"><table><thead><tr><th>Finding</th><th class="num">Users</th></tr></thead><tbody>$findingRows</tbody></table></div>

<h2>How to read this</h2>
<ul class="notes">$notesHtml</ul>

<footer>Read-only report. Nothing was changed in Entra or F&amp;O. This page has counts only. The per-user CSV next to it contains names, email addresses and sign-in dates: keep it to the people who need it.</footer>
</main></body></html>
"@
}

# --- Demo data --------------------------------------------------------------

function New-DemoData {
    <# Made-up tenant data for trying the report without signing in. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][datetime] $Now)
    $fin = [pscustomobject]@{ SkuId = '55c9eb4e-c746-45b4-b255-9ab6b19d5c62'; SkuPartNumber = 'DYN365_FINANCE'; Name = 'Finance'; Tier = 'Enterprise'; Bought = 40; Assigned = 36 }
    $scm = [pscustomobject]@{ SkuId = '090b4a96-8114-4c95-9c91-60e81ef53302'; SkuPartNumber = 'DYN365_SCM_ATTACH'; Name = 'Supply Chain Management (attach)'; Tier = 'Enterprise'; Bought = 15; Assigned = 15 }
    $act = [pscustomobject]@{ SkuId = 'b75074f1-4c54-41bf-970f-c9ac871567f5'; SkuPartNumber = 'Dyn365_Operations_Activity'; Name = 'Operations - Activity'; Tier = 'Activity'; Bought = 20; Assigned = 18 }
    $tm = [pscustomobject]@{ SkuId = '7ac9fe77-66b7-4e5e-9e46-10eed1cff547'; SkuPartNumber = 'DYN365_TEAM_MEMBERS'; Name = 'Team Members'; Tier = 'Team Members'; Bought = 60; Assigned = 52 }
    $skus = @($fin, $scm, $act, $tm)

    $random = [System.Random]::new(42)
    $users = [System.Collections.Generic.List[object]]::new()
    $foUsers = [System.Collections.Generic.List[object]]::new()
    $roleTier = @{}
    $plan = @(
        @{ Count = 36; Skus = @($fin); Need = 'Enterprise' }
        @{ Count = 15; Skus = @($scm); Need = 'Enterprise' }
        @{ Count = 18; Skus = @($act); Need = 'Activity' }
        @{ Count = 52; Skus = @($tm); Need = 'Team Members' }
    )
    $n = 0
    foreach ($group in $plan) {
        for ($i = 0; $i -lt $group.Count; $i++) {
            $n++
            $upn = "user$n@contoso.com"
            $roll = $random.NextDouble()
            $last = if ($roll -lt 0.04) { $null } elseif ($roll -lt 0.12) { $Now.AddDays(-1 * $random.Next(95, 400)) } else { $Now.AddDays(-1 * $random.Next(0, 40)) }
            $enabled = $random.NextDouble() -gt 0.02
            $users.Add([pscustomobject]@{
                Id = [guid]::NewGuid().ToString(); DisplayName = "Demo user $n"; UserPrincipalName = $upn; AccountEnabled = $enabled
                AssignedLicenses = @($group.Skus | ForEach-Object { [pscustomobject]@{ SkuId = $_.SkuId } })
                SignInActivity = [pscustomobject]@{ LastSignInDateTime = $last; LastNonInteractiveSignInDateTime = $null }
            })
            if ($random.NextDouble() -gt 0.03) {
                $foUsers.Add([pscustomobject]@{ UserId = "u$n"; Name = "Demo user $n"; Alias = $upn; Email = $upn; Enabled = ($random.NextDouble() -gt 0.03) })
                $need = $group.Need
                $pick = $random.NextDouble()
                if ($need -eq 'Enterprise' -and $pick -lt 0.15) { $need = 'Activity' }
                elseif ($need -eq 'Team Members' -and $pick -lt 0.06) { $need = 'Enterprise' }
                $roleTier["u$n"] = $need
            }
        }
    }
    foreach ($k in 1..3) {
        $foUsers.Add([pscustomobject]@{ UserId = "x$k"; Name = "Unlicensed user $k"; Alias = "contractor$k@contoso.com"; Email = ''; Enabled = $true })
        $roleTier["x$k"] = 'Enterprise'
    }
    [pscustomobject]@{
        Skus = $skus; Users = $users.ToArray(); FoUsers = $foUsers.ToArray(); FoRoleTier = $roleTier
        # Made-up prices in a made-up currency. The tool ships no real prices.
        Prices = @{ DYN365_FINANCE = 100; DYN365_SCM_ATTACH = 25; Dyn365_Operations_Activity = 40; DYN365_TEAM_MEMBERS = 10 }; Currency = 'DEMO'
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-FoEnvironmentUrl', 'Get-DefaultSkuMap', 'Read-LicenceSetting', 'Get-LastSignIn', 'Get-TierFromLicenceType',
    'Get-DynamicsSku', 'Get-LicensedUser', 'Get-FoAccessToken', 'Invoke-FoODataQuery', 'Get-FoSystemUser',
    'Get-FoRoleLicence', 'ConvertTo-FoRoleLicence', 'ConvertTo-LicenceUserRow', 'Get-LicenceSummary',
    'Get-FindingCount', 'ConvertTo-LicenceCsvRow', 'New-LicenceReportHtml', 'New-DemoData'
)
