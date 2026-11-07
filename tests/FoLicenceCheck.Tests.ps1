#Requires -Version 7.0
# Run from the repository folder:  Invoke-Pester ./tests

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    # Stand-ins so the tests run without the Graph and Az modules installed.
    $stubs = @{
        'Get-MgSubscribedSku' = { param([switch] $All) }
        'Get-MgUser'          = { param([switch] $All, [string] $Filter, [string[]] $Property) }
        'Get-AzAccessToken'   = { param([string] $ResourceUrl) }
        'Get-MgOrganization'  = { param([string[]] $Property) }
    }
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            New-Item -Path "function:global:$name" -Value $stubs[$name] | Out-Null
        }
    }
    Import-Module (Join-Path $repo 'src/FoLicenceCheck/FoLicenceCheck.psd1') -Force
    $script:now = [datetime]::new(2026, 11, 7, 12, 0, 0, [DateTimeKind]::Utc)

    $script:fin = [pscustomobject]@{ SkuId = 'f1'; SkuPartNumber = 'DYN365_FINANCE'; Name = 'Finance'; Tier = 'Enterprise'; Bought = 10; Assigned = 8 }
    $script:tm = [pscustomobject]@{ SkuId = 't1'; SkuPartNumber = 'DYN365_TEAM_MEMBERS'; Name = 'Team Members'; Tier = 'Team Members'; Bought = 5; Assigned = 5 }
    function script:New-User([string] $Upn, [string[]] $SkuIds, $Last, [bool] $Enabled = $true) {
        [pscustomobject]@{
            Id = [guid]::NewGuid().ToString(); DisplayName = $Upn; UserPrincipalName = $Upn; AccountEnabled = $Enabled
            AssignedLicenses = @($SkuIds | ForEach-Object { [pscustomobject]@{ SkuId = $_ } })
            SignInActivity = [pscustomobject]@{ LastSignInDateTime = $Last; LastNonInteractiveSignInDateTime = $null }
        }
    }
}

Describe 'Read-LicenceSetting' {
    It 'has safe defaults without a file' {
        $s = Read-LicenceSetting
        $s.InactiveDays | Should -Be 90
        $s.Prices.Count | Should -Be 0
        $s.Skus.Contains('DYN365_FINANCE') | Should -BeTrue
    }
    It 'reads prices, exclusions and extra licences, and skips empty prices' {
        $path = Join-Path $TestDrive 'settings.json'
        @{
            inactiveDays = 60; currency = 'EUR'
            pricesPerMonth = @{ DYN365_FINANCE = 12.5; DYN365_SCM = $null }
            excludeUsers = @(' SVC@Contoso.com ')
            extraSkus = @{ MY_SKU = @{ name = 'Custom'; tier = 'Activity' } }
        } | ConvertTo-Json -Depth 5 | Set-Content $path
        $s = Read-LicenceSetting -Path $path
        $s.InactiveDays | Should -Be 60
        $s.Prices['DYN365_FINANCE'] | Should -Be 12.5
        $s.Prices.ContainsKey('DYN365_SCM') | Should -BeFalse
        $s.ExcludeUsers | Should -Be @('svc@contoso.com')
        $s.Skus['MY_SKU'].Tier | Should -Be 'Activity'
    }
    It 'refuses an unknown tier' {
        $path = Join-Path $TestDrive 'bad.json'
        '{ "extraSkus": { "X": { "name": "X", "tier": "Gold" } } }' | Set-Content $path
        { Read-LicenceSetting -Path $path } | Should -Throw '*Unknown tier*'
    }
    It 'ships the example file with no prices' {
        $example = Get-Content (Join-Path $repo 'settings.example.json') -Raw | ConvertFrom-Json -AsHashtable
        @($example.pricesPerMonth.Values | Where-Object { $null -ne $_ }).Count | Should -Be 0
    }
}

Describe 'Get-LastSignIn' {
    It 'takes the latest of interactive and non-interactive sign-ins' {
        $activity = [pscustomobject]@{ LastSignInDateTime = $now.AddDays(-100); LastNonInteractiveSignInDateTime = $now.AddDays(-3) }
        Get-LastSignIn $activity | Should -Be $now.AddDays(-3)
    }
    It 'returns nothing when there is no sign-in' {
        Get-LastSignIn ([pscustomobject]@{ LastSignInDateTime = $null }) | Should -BeNullOrEmpty
        Get-LastSignIn $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-TierFromLicenceType' {
    It 'maps <Type> to <Tier>' -ForEach @(
        @{ Type = 'Enterprise'; Tier = 'Enterprise' }
        @{ Type = 'Activity'; Tier = 'Activity' }
        @{ Type = 'Universal'; Tier = 'Team Members' }
        @{ Type = 'None'; Tier = 'None' }
        @{ Type = ''; Tier = 'None' }
    ) {
        Get-TierFromLicenceType $Type | Should -Be $Tier
    }
}

Describe 'ConvertTo-FoRoleLicence' {
    It 'keeps the highest tier per user and skips disabled assignments' {
        $tiers = ConvertTo-FoRoleLicence -Assignment @(
            [pscustomobject]@{ UserId = 'Anna'; UserLicenseType = 'Universal'; AssignmentStatus = 'Enabled' }
            [pscustomobject]@{ UserId = 'anna'; UserLicenseType = 'Activity'; AssignmentStatus = 'Enabled' }
            [pscustomobject]@{ UserId = 'anna'; UserLicenseType = 'Enterprise'; AssignmentStatus = 'Disabled' }
            [pscustomobject]@{ UserId = 'bob'; UserLicenseType = 'Enterprise' }
        )
        $tiers['anna'] | Should -Be 'Activity'
        $tiers['bob'] | Should -Be 'Enterprise'
    }
}

Describe 'ConvertTo-LicenceUserRow' {
    It 'finds never signed in, inactive and disabled users' {
        $users = @(
            New-User 'active@contoso.com' @('f1') $now.AddDays(-5)
            New-User 'never@contoso.com' @('f1') $null
            New-User 'old@contoso.com' @('f1') $now.AddDays(-120)
            New-User 'off@contoso.com' @('f1') $now.AddDays(-1) $false
        )
        $rows = @(ConvertTo-LicenceUserRow -User $users -Sku @($fin) -Now $now -InactiveDays 90)
        ($rows | Where-Object UserPrincipalName -eq 'active@contoso.com').Inactive | Should -BeFalse
        ($rows | Where-Object UserPrincipalName -eq 'never@contoso.com').Findings | Should -Contain 'Never signed in'
        ($rows | Where-Object UserPrincipalName -eq 'old@contoso.com').Findings | Should -Contain 'No sign-in for over 90 days'
        ($rows | Where-Object UserPrincipalName -eq 'off@contoso.com').Findings | Should -Contain 'Disabled in Entra but licensed'
        ($rows | Where-Object UserPrincipalName -eq 'old@contoso.com').DaysSinceSignIn | Should -Be 120
    }
    It 'ignores users without a Dynamics licence' {
        $rows = @(ConvertTo-LicenceUserRow -User @(New-User 'x@contoso.com' @('other') $null) -Sku @($fin) -Now $now -InactiveDays 90)
        $rows.Count | Should -Be 0
    }
    It 'leaves excluded service accounts out of the findings' {
        $rows = @(ConvertTo-LicenceUserRow -User @(New-User 'SVC@contoso.com' @('f1') $null) -Sku @($fin) -Now $now -InactiveDays 90 -ExcludeUsers 'svc@contoso.com')
        $rows[0].Excluded | Should -BeTrue
        $rows[0].Inactive | Should -BeFalse
        $rows[0].Findings.Count | Should -Be 0
    }
    It 'does not judge sign-ins when the dates are not available' {
        $rows = @(ConvertTo-LicenceUserRow -User @(New-User 'a@contoso.com' @('f1') $null) -Sku @($fin) -Now $now -InactiveDays 90 -SignInAvailable $false)
        $rows[0].Findings.Count | Should -Be 0
        $rows[0].Inactive | Should -BeFalse
    }
    Context 'with F&O users and roles' {
        BeforeAll {
            $users = @(
                New-User 'anna@contoso.com' @('f1') $now.AddDays(-1)
                New-User 'bob@contoso.com' @('t1') $now.AddDays(-1)
                New-User 'cara@contoso.com' @('f1') $now.AddDays(-1)
                New-User 'dan@contoso.com' @('f1') $now.AddDays(-1)
            )
            $foUsers = @(
                [pscustomobject]@{ UserId = 'anna'; Name = 'Anna'; Alias = 'anna@contoso.com'; Email = ''; Enabled = $true }
                [pscustomobject]@{ UserId = 'bob'; Name = 'Bob'; Alias = 'bob@contoso.com'; Email = ''; Enabled = $true }
                [pscustomobject]@{ UserId = 'cara'; Name = 'Cara'; Alias = ''; Email = 'cara@contoso.com'; Enabled = $false }
                [pscustomobject]@{ UserId = 'eve'; Name = 'Eve'; Alias = 'eve@contoso.com'; Email = ''; Enabled = $true }
                [pscustomobject]@{ UserId = 'Admin'; Name = 'Admin'; Alias = 'admin'; Email = ''; Enabled = $true }
            )
            $tiers = @{ anna = 'Activity'; bob = 'Enterprise'; eve = 'Team Members' }
            $rows = @(ConvertTo-LicenceUserRow -User $users -Sku @($fin, $tm) -Now $now -InactiveDays 90 -FoUser $foUsers -FoRoleTier $tiers)
        }
        It 'flags a licence higher than the roles need' {
            ($rows | Where-Object UserPrincipalName -eq 'anna@contoso.com').Findings | Should -Contain 'User has Enterprise, F&O roles need only Activity'
        }
        It 'flags roles that need a higher licence' {
            ($rows | Where-Object UserPrincipalName -eq 'bob@contoso.com').Findings | Should -Contain 'F&O roles need Enterprise, user has Team Members'
        }
        It 'matches on email when the alias is empty, and flags users disabled in F&O' {
            $cara = $rows | Where-Object UserPrincipalName -eq 'cara@contoso.com'
            $cara.EnabledInFo | Should -Be 'No'
            $cara.Findings | Should -Contain 'Disabled in F&O but licensed'
        }
        It 'flags licensed users who are not in F&O' {
            ($rows | Where-Object UserPrincipalName -eq 'dan@contoso.com').Findings | Should -Contain 'Licensed but not a user in the checked F&O environment'
        }
        It 'skips F&O users outside the tenant domains' {
            $foUsers2 = @($foUsers) + [pscustomobject]@{ UserId = 'demo1'; Name = 'Demo'; Alias = 'ellen@contosoax7.onmicrosoft.com'; Email = ''; Enabled = $true }
            $rows2 = @(ConvertTo-LicenceUserRow -User $users -Sku @($fin, $tm) -Now $now -InactiveDays 90 -FoUser $foUsers2 -FoRoleTier $tiers -TenantDomain 'contoso.com')
            $rows2.UserPrincipalName | Should -Not -Contain 'ellen@contosoax7.onmicrosoft.com'
            $rows2.UserPrincipalName | Should -Contain 'eve@contoso.com'
            Get-OtherDomainFoUserCount -FoUser $foUsers2 -TenantDomain 'contoso.com' | Should -Be 1
        }
        It 'lists F&O users with no Dynamics licence, but not built-in accounts' {
            ($rows | Where-Object UserPrincipalName -eq 'eve@contoso.com').Findings | Should -Contain 'Enabled in F&O but no Dynamics licence'
            $rows.UserPrincipalName | Should -Not -Contain 'admin'
        }
    }
}

Describe 'Get-LicenceSummary' {
    It 'counts active, inactive and excluded per licence and prices the inactive ones' {
        $rows = @(
            [pscustomobject]@{ SkuPartNumbers = @('DYN365_FINANCE'); Inactive = $true; Excluded = $false }
            [pscustomobject]@{ SkuPartNumbers = @('DYN365_FINANCE'); Inactive = $false; Excluded = $false }
            [pscustomobject]@{ SkuPartNumbers = @('DYN365_FINANCE'); Inactive = $false; Excluded = $true }
        )
        $s = Get-LicenceSummary -Row $rows -Sku @($fin) -Prices @{ DYN365_FINANCE = 100 }
        $s.Active | Should -Be 1
        $s.Inactive | Should -Be 1
        $s.Excluded | Should -Be 1
        $s.Unassigned | Should -Be 2
        $s.InactiveCost | Should -Be 100
        $s.UnassignedCost | Should -Be 200
    }
    It 'shows no cost without a price' {
        $s = Get-LicenceSummary -Row @() -Sku @($fin)
        $s.InactiveCost | Should -BeNullOrEmpty
    }
}

Describe 'Graph reads' {
    It 'keeps only Dynamics licences' {
        Mock -ModuleName FoLicenceCheck Get-MgSubscribedSku {
            [pscustomobject]@{ SkuId = 'f1'; SkuPartNumber = 'DYN365_FINANCE'; ConsumedUnits = 8; PrepaidUnits = [pscustomobject]@{ Enabled = 10 } }
            [pscustomobject]@{ SkuId = 'o1'; SkuPartNumber = 'SPE_E5'; ConsumedUnits = 100; PrepaidUnits = [pscustomobject]@{ Enabled = 100 } }
        }
        $skus = @(Get-DynamicsSku -SkuMap (Get-DefaultSkuMap))
        $skus.Count | Should -Be 1
        $skus[0].Bought | Should -Be 10
        $skus[0].Name | Should -Be 'Finance'
    }
    It 'falls back to no sign-in dates when Graph refuses them' {
        Mock -ModuleName FoLicenceCheck Get-MgUser {
            if ($Property -like '*signInActivity*') { throw 'Neither tenant is B2C or tenant doesn''t have premium license' }
            New-User 'a@contoso.com' @('f1') $null
        }
        $result = Get-LicensedUser -Sku @($fin) 3>$null
        $result.SignInAvailable | Should -BeFalse
        $result.Users.Count | Should -Be 1
    }
    It 'filters users by licence on the server' {
        Mock -ModuleName FoLicenceCheck Get-MgUser { }
        Get-LicensedUser -Sku @($fin) | Out-Null
        Should -Invoke -ModuleName FoLicenceCheck Get-MgUser -ParameterFilter { $Filter -eq 'assignedLicenses/any(x:x/skuId eq f1)' }
    }
}

Describe 'Get-TenantDomain' {
    It 'returns the verified domains in lower case' {
        Mock -ModuleName FoLicenceCheck Get-MgOrganization {
            [pscustomobject]@{ VerifiedDomains = @([pscustomobject]@{ Name = 'Contoso.com' }, [pscustomobject]@{ Name = 'contoso.onmicrosoft.com' }) }
        }
        @(Get-TenantDomain) | Should -Be @('contoso.com', 'contoso.onmicrosoft.com')
    }
}

Describe 'F&O reads' {
    It 'pages through results with GET only' {
        Mock -ModuleName FoLicenceCheck Invoke-RestMethod {
            if ($Uri -like '*skip*') { [pscustomobject]@{ value = @([pscustomobject]@{ UserID = 'b'; Alias = 'B@contoso.com'; Enabled = 'Yes' }) } }
            else { [pscustomobject]@{ value = @([pscustomobject]@{ UserID = 'a'; Alias = 'a@contoso.com'; Enabled = $true }); '@odata.nextLink' = 'https://c.operations.dynamics.com/data/SystemUsers?skip=1' } }
        }
        $users = @(Get-FoSystemUser -EnvironmentUrl 'c.operations.dynamics.com' -AccessToken 't')
        $users.Count | Should -Be 2
        $users[1].Alias | Should -Be 'b@contoso.com'
        $users[1].Enabled | Should -BeTrue
        Should -Invoke -ModuleName FoLicenceCheck Invoke-RestMethod -Times 0 -ParameterFilter { $Method -ne 'Get' }
    }
    It 'retries without the field list when a field is missing' {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName FoLicenceCheck Invoke-RestMethod {
            $script:calls.Add($Uri)
            if ($Uri -like '*select*') {
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Bad request', $response)
            }
            [pscustomobject]@{ value = @([pscustomobject]@{ UserId = 'a'; UserLicenseType = 'Enterprise' }) }
        }
        $tiers = Get-FoRoleLicence -EnvironmentUrl 'https://c.operations.dynamics.com' -AccessToken 't'
        $tiers['a'] | Should -Be 'Enterprise'
        $script:calls[-1] | Should -Be 'https://c.operations.dynamics.com/data/SecurityUserRoles'
    }
}

Describe 'Report output' {
    BeforeAll {
        $demo = New-DemoData -Now $now
        $rows = @(ConvertTo-LicenceUserRow -User $demo.Users -Sku $demo.Skus -Now $now -InactiveDays 90 -FoUser $demo.FoUsers -FoRoleTier $demo.FoRoleTier)
        $summary = @(Get-LicenceSummary -Row $rows -Sku $demo.Skus -Prices $demo.Prices)
        $html = New-LicenceReportHtml -Summary $summary -FindingCount @(Get-FindingCount -Row $rows) -GeneratedAt $now -Currency 'DEMO'
    }
    It 'keeps names and email addresses out of the HTML summary' {
        $html | Should -Not -Match '@contoso\.com'
        $html | Should -Not -Match 'Demo user'
    }
    It 'shows the cost of inactive licences' {
        $html | Should -Match 'Monthly cost of those licences'
        $html | Should -Match 'DEMO \d'
    }
    It 'writes the per-user CSV columns in a fixed order' {
        $csv = @(ConvertTo-LicenceCsvRow -Row $rows)
        $csv[0].PSObject.Properties.Name[0..3] | Should -Be @('User', 'Name', 'Licences', 'Licence tier')
    }
}

Describe 'Read-only guarantee' {
    It 'sends no write requests and calls no Graph write cmdlets' {
        $source = Get-Content (Join-Path $repo 'src/FoLicenceCheck/FoLicenceCheck.psm1') -Raw
        $script = Get-Content (Join-Path $repo 'Get-FoLicenceCheck.ps1') -Raw
        foreach ($text in $source, $script) {
            $text | Should -Not -Match '-Method\s+(Post|Put|Patch|Delete|Merge)'
            $text | Should -Not -Match '(New|Update|Remove|Set|Add)-Mg\w+'
        }
    }
}

Describe 'Get-FoLicenceCheck.ps1 -Demo' {
    It 'writes a summary page and a per-user CSV' {
        $out = Join-Path $TestDrive 'out'
        & (Join-Path $repo 'Get-FoLicenceCheck.ps1') -Demo -OutputFolder $out 6>$null | Out-Null
        @(Get-ChildItem $out -Filter 'licence-check-summary-*.html').Count | Should -Be 1
        @(Import-Csv (Get-ChildItem $out -Filter 'licence-check-users-*.csv').FullName).Count | Should -BeGreaterThan 100
    }
}
