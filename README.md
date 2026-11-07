# F&O license check

[![Tests](https://github.com/DynAax-AB/dynaax-d365fo-license-check/actions/workflows/test.yml/badge.svg)](https://github.com/DynAax-AB/dynaax-d365fo-license-check/actions/workflows/test.yml)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
[![Read only](https://img.shields.io/badge/access-read%20only-2ea44f)](#safe-to-run)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A free, read-only PowerShell script that shows which Dynamics 365 Finance and
Supply Chain Management (F&O) licences are paid for but not used, and what that
costs per month.

![One-page summary: licences held by inactive users, their monthly cost, and findings](docs/images/summary.png)

*The one-page summary, with made-up demo data and prices.*

## What problem this solves

Companies keep paying for F&O licences held by people who left, changed role or
never sign in. Nobody checks, because the facts sit in two places:

- **Entra** knows who holds a licence and when they last signed in.
- **F&O** knows who is still enabled, and which licence their security roles
  actually need.

This script reads both and puts them side by side.

## How it works

```mermaid
flowchart LR
    subgraph cloud["☁️ Your Microsoft cloud"]
        direction TB
        entra["👥 <b>Entra ID</b><br/>Dynamics licences,<br/>who holds them,<br/>last sign-in"]
        fo["🏭 <b>F&O environment</b><br/>users, and the licence<br/>their security roles need"]
    end
    settings["🛠️ <b>settings.json</b><br/>your prices, inactive days,<br/>accounts to leave out"]
    subgraph pc["💻 Your machine"]
        direction LR
        script["⚙️ <b>Get-FoLicenceCheck.ps1</b><br/>puts both sides together"]
        html["📊 <b>One-page summary</b><br/>counts and cost, no names<br/>share with the business"]
        csv["🔒 <b>Per-user CSV</b><br/>names and findings<br/>keep it private"]
    end

    entra -- "Microsoft Graph · read only" --> script
    fo -. "optional · OData · read only" .-> script
    settings --> script
    script --> html
    script --> csv

    classDef source fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#0f172a
    classDef fo fill:#ede9fe,stroke:#7c3aed,stroke-width:2px,color:#0f172a
    classDef tool fill:#ccfbf1,stroke:#0d9488,stroke-width:2px,color:#0f172a
    classDef config fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#0f172a
    classDef output fill:#dcfce7,stroke:#16a34a,stroke-width:2px,color:#0f172a
    classDef private fill:#fee2e2,stroke:#dc2626,stroke-width:2px,color:#0f172a
    class entra source
    class fo fo
    class script tool
    class settings config
    class html output
    class csv private
    style cloud fill:#3b82f614,stroke:#60a5fa,color:#3b82f6
    style pc fill:#22c55e14,stroke:#4ade80,color:#16a34a
```

The script only reads. Prices and exclusions come from your own settings file, and
both outputs stay on your machine.

## What it reports

Per user (in a CSV, for the licence owner):

| Finding | Why it matters |
|---|---|
| Never signed in | Waste, or an account set up and forgotten |
| No sign-in for over 90 days (you choose the number) | Likely to be removed |
| Disabled in Entra but licensed | Paying for someone who can't sign in |
| Licensed but not a user in the checked F&O environment, or disabled there | Paying for someone who may not use F&O. Check production: a licence covers every environment. |
| Enabled in F&O but no Dynamics licence | A compliance risk, the other way round. Only users in your tenant's own domains are checked, so demo data users and Microsoft service accounts don't show up. |
| F&O roles need a higher licence than the user has | A compliance risk |
| User has a higher licence than their F&O roles need | A possible saving |

Per licence type (in a one-page HTML summary without names, for the business):
licences bought, assigned, active and inactive, and the monthly cost of the
inactive and unassigned ones.

The last two findings compare the user's licence with the licence type F&O
records for each of their security roles. Treat them as a starting point:
F&O's own user licence reports and your licensing partner have the final word.

## Try it in one minute

No sign-in needed. With [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell):

```powershell
git clone https://github.com/DynAax-AB/dynaax-d365fo-license-check.git
cd dynaax-d365fo-license-check
./Get-FoLicenceCheck.ps1 -Demo
```

Open the files it writes to the `output` folder.

## Run it on your tenant

### 1. Install the modules (once)

```powershell
Install-Module Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser
Install-Module Az.Accounts -Scope CurrentUser   # only for the F&O comparison
```

### 2. Make your settings file

Copy `settings.example.json` to `settings.json` and fill in:

- **`inactiveDays`**: days without a sign-in that count as inactive (for example
  60 or 90).
- **`pricesPerMonth`**: your own price per licence per month. Prices differ per
  agreement, so the tool ships none. Leave a price empty to hide that cost.
- **`excludeUsers`**: service and integration accounts. They often look inactive
  but are needed.
- **`extraSkus`**: any other Dynamics licence to include, with a name and a tier
  (`Enterprise`, `Activity` or `Team Members`).

### 3. Run

```powershell
./Get-FoLicenceCheck.ps1 -TenantId contoso.onmicrosoft.com -SettingsFile ./settings.json `
    -FoEnvironmentUrl https://contoso-prod.operations.dynamics.com
```

Leave out `-FoEnvironmentUrl` to check Entra only.

### What you need

| For | You need |
|---|---|
| Entra | An admin who can consent to the read-only permissions `User.Read.All`, `AuditLog.Read.All` and `Organization.Read.All`. Global Reader or Reports Reader can run it once consent is given. |
| Sign-in dates | Entra ID P1 or P2. Without it, the script still runs but can't tell who is inactive by sign-in date. |
| F&O (optional) | Read access to the F&O environment with your normal account. The script reads the `SystemUsers` and `SecurityUserRoles` entities. |
| Your machine | PowerShell 7 on Windows, macOS or Linux. |

## How "inactive" is decided

- The **latest** of the interactive and non-interactive sign-in dates is used.
  People who use F&O only through Excel, Power BI or integrations have
  non-interactive sign-ins only, and would otherwise look inactive.
- A user is inactive if they never signed in, haven't signed in for longer than
  `inactiveDays`, are disabled in Entra, or (with the F&O check) are missing or
  disabled in F&O.
- Accounts in `excludeUsers` are counted as excluded, never as inactive.

## Safe to run

- **Read only.** The script only reads from Microsoft Graph and F&O (GET
  requests). A test checks that the code contains no write calls.
- **Nothing is sent anywhere.** The output stays on your machine.
- **Personal data.** The per-user CSV has names, email addresses and sign-in
  dates. Keep it to the people who need it, and delete it when you're done. The
  HTML summary has counts only, so it can be shared with the business.

## Tests

The logic is in a module (`src/FoLicenceCheck`) with [Pester](https://pester.dev)
tests that use fake Graph and F&O responses:

```powershell
Install-Module Pester -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester ./tests
```

## Contributing

Issues and pull requests are welcome. Please run the tests first, keep the
script read-only, and never include tenant data or real prices in issues.

## Licence

[MIT](LICENSE). Free to use, change and share. This is a community project. It
isn't affiliated with or endorsed by Microsoft.
