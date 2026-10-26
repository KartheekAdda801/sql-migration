---
title: Data Migration Service scripts
description: Upload SQL Server backups and run item-based online DMS migrations to SQL VM and SQL Managed Instance.
---

## Configuration files

Maintain two operational files:

| File | Purpose |
|------|---------|
| [Invoke-CopyBackup-OnPrem-AzureBlob.config.json](./config/Invoke-CopyBackup-OnPrem-AzureBlob.config.json) | On-premises backup folders and upload settings |
| [Invoke-RestoreDMS.config.json](./config/Invoke-RestoreDMS.config.json) | Restore, Status, Monitor, Cutover, and Remove for all database mappings |

[Invoke-RestoreDMS.example.json](./config/Invoke-RestoreDMS.example.json) is an
optional template, not a third operational file. It demonstrates inherited
defaults, mixed SQLVM/SQLMI targets, and different storage/target/DMS groups.
ServerObjectMigrationService configurations are unchanged.

Run [Invoke-RestoreDMS.ps1](./scripts/Invoke-RestoreDMS.ps1) for every DMS
lifecycle activity. It replaces the separate VM restore, MI restore, control,
and removal scripts, as well as the earlier dispatcher. It calls shared
functions through one public entry point, with isolated submission workers. Keep its
[Common helpers](./scripts/Common) with the script.
Default configuration paths are relative to the script, not the terminal.
Explicit `-ConfigPath` paths are relative to your current PowerShell location.
No plaintext passwords, account keys, or access tokens belong in the migration
configuration. SQL login can reference a named entry in a separate, Git-ignored
local password file, an encrypted credential file, or a password environment variable.

> [!WARNING]
> The operational configuration currently enables Restore for both MIGRDEMO
> mappings. Running without `-WhatIf` starts live work. Use `-Activity Status`
> explicitly to inspect status without submitting restores.

## Common defaults and per-database overrides

The DMS file has only `schemaVersion`, `Common`, and `Items`. Each item is one
source-to-target database mapping. SQLVM and SQLMI records belong in the same
array; there are no separate target, restore, or control sections.

```json
{
  "schemaVersion": 2,
  "Common": {
    "Activity": "Restore",
    "MaxConcurrentRestores": 10,
    "MaxConcurrentCutover": 5,
    "SubscriptionId": "cd7743ef-8ddc-4254-b715-2c79c8ab4126",
    "ResourceGroupName": "rg-ak-personal",
    "Location": "centralus",
    "DMSServiceName": "ak-personal-dms",
    "BackupStorageAccount": "akpersonalsa",
    "AutoCutover": false
  },
  "Items": [
    {
      "Id": "VM-MIGRDEMO",
      "Activity": "",
      "SrcServerName": "DESKTOP-SGA61QP\\DMF",
      "SrcDatabaseName": "MIGRDEMO",
      "BackupStorageContainerName": "desktop-sga61qp-dmf-migrdemo",
      "TargetType": "SQLVM",
      "TargetName": "akpersonalsqlvm",
      "TargetSqlHost": "akpersonalsqlvm.centralus.cloudapp.azure.com",
      "TargetSqlPort": 1433,
      "TrgDatabaseName": "MIGRDEMO"
    },
    {
      "Id": "MI-MIGRDEMO",
      "Activity": "",
      "SrcServerName": "DESKTOP-SGA61QP\\DMF",
      "SrcDatabaseName": "MIGRDEMO",
      "BackupStorageContainerName": "desktop-sga61qp-dmf-migrdemo",
      "TargetType": "SQLMI",
      "TargetName": "ak-personal-sqlmi",
      "TargetSqlHost": "ak-personal-sqlmi.public.3c52841dc1d0.database.windows.net",
      "TargetSqlPort": 3342,
      "TrgDatabaseName": "MIGRDEMO"
    }
  ]
}
```

Inheritance follows this order:

1. A nonblank value on the item wins.
2. An omitted, `null`, empty-string, or whitespace-only item value inherits
   the same property from `Common`.
3. If neither supplies a value, the script's documented default applies.

JSON `false` is an explicit override, not a blank value. Numeric `0` is also
explicit and fails validation where a positive number is required. Use `""`
or omit a property to inherit. Misspelled properties and invalid types fail
before work. `Id` must be unique and belongs only on an item.

Every common property below can be overridden per item except
`MaxConcurrentRestores` and `MaxConcurrentCutover`. These are global
limits and are accepted only in `Common`. `MaxConcurrentRestores` now limits
simultaneous migration creation requests, not the number of active Azure restores.
Its supported range is 1 through 10.

| Properties | Meaning |
|------------|---------|
| `Enabled`, `Activity` | Select participation and Restore/Status/Monitor/Cutover/Remove; built-in defaults true and Status; operational file currently selects Restore |
| `SubscriptionId`, `ResourceGroupName`, `Location` | Subscription and fallback resource group for this mapping; DMS region |
| `SrcServerName`, `SrcDatabaseName` | Original backup source instance and database |
| `BackupStorageAccount`, `BackupStorageResourceGroup`, `BackupStorageContainerName` | Existing source backup account, resource group, and flat Blob container |
| `TargetType`, `TargetName`, `TargetResourceGroup` | SQLVM or SQLMI and its Azure resource name/group |
| `TargetSqlHost`, `TargetSqlPort` | Executor SQL hostname and TCP port for either target type; host required for Restore, without `tcp:` or port suffix; item overrides Common, port defaults 1433 only if neither supplies it |
| `SqlCredentialPath` | DPAPI-encrypted PSCredential file for SQL-login access on either target; Interactive mode prefers login entry |
| `TargetSqlAuthType` | SQL endpoint authentication: SqlLogin or Entra; blank defaults to SqlLogin for SQLVM and Entra for SQLMI; independent of BlobAuthType |
| `credential` | Named SQL login in password.local.json beside the selected configuration; item overrides Common; explicit reference loads without a login prompt |
| `SqlCredentialMode` | Interactive (default) prefers login entry; Configured loads credential references without a login prompt, while retaining replacement approval |
| `SqlUserName`, `SqlPasswordEnvironmentVariable` | Alternative configured SQL login: username and the name of a password environment variable, never the password itself |
| `TargetTrustServerCertificate` | Defaults false; explicitly opt in only when accepting a known self-signed SQL certificate is necessary |
| `TrgDatabaseName` | Exact target database name |
| `DMSServiceName`, `DMSResourceGroup` | Existing SQL migration service and its discovery group |
| `BlobAuthType`, `BlobIdentityType`, `BlobUserAssignedIdentity` | Backup authentication: blank auth type defaults to AccountKey for VM, ManagedIdentity for MI; identity defaults SystemAssigned |
| `AutoCutover` | Defaults false; does not freeze source writes or upload final logs |
| `TimestampPattern`, `TimestampFormat` | Optional paired custom backup filename timestamp parser |
| `MonitorIntervalSeconds`, `CutoverTimeoutMinutes`, `RefreshWaitMinutes` | Defaults 15 seconds, 60 minutes, and 5 minutes; replacement cancellation/deletion also uses the cutover timeout |
| `IncludeReadyForCutover`, `Force` | Ready-record removal is an explicit opt-in; Force is retained for compatibility but no longer controls a selection prompt |
| `OutputJsonPath`, `ExportCsvPath` | Optional workflow result paths; blank uses per-run JSON and CSV reports for every activity |

After same-name inheritance, blank `BackupStorageResourceGroup`,
`TargetResourceGroup`, and `DMSResourceGroup` use the effective
`ResourceGroupName`. To put only one component elsewhere, override that
component's group on its item. If Common supplies a nonblank component-specific
group, an item must explicitly replace it to use another group.

For example, edit an MI item without changing any other mapping:

```json
{
  "Id": "MI-AnotherDb",
  "SrcServerName": "ANOTHER-SOURCE",
  "SrcDatabaseName": "AnotherDb",
  "BackupStorageAccount": "anotherbackupaccount",
  "BackupStorageResourceGroup": "backup-rg",
  "BackupStorageContainerName": "another-source-anotherdb",
  "TargetType": "SQLMI",
  "TargetName": "another-mi",
  "TargetResourceGroup": "target-rg",
  "TrgDatabaseName": "AnotherDb",
  "DMSServiceName": "another-dms",
  "DMSResourceGroup": "dms-rg",
  "Activity": "Status"
}
```

Each item uses one subscription for its storage, target, and DMS resources.
Different items can use different subscriptions. Cross-subscription resources
within a single mapping are not configured by this schema.

## Run all databases or select individual mappings

From the repository root in PowerShell 7, after
[prerequisite setup and Azure sign-in](../Prerequisites/README.md):

```powershell
# Preview the configured Restore for both MIGRDEMO mappings.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -WhatIf

# Explicit temporary activity override for all enabled mappings.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Status -Foreground

# One exact mapping. IDs disambiguate the same database on different servers.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Status -ItemId 'MI-MIGRDEMO' -Foreground

# Database and server selection; without TargetName, this name selects both mappings.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Status -Databases 'MIGRDEMO' -TargetName 'akpersonalsqlvm' -Foreground

# All configured VM mappings.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Status -TargetType SQLVM -Foreground
```

Selectors are exact and combine by intersection. A requested ID or database
that does not match an enabled item fails instead of silently running a subset.
`Enabled=false` excludes an item. With no selectors, all enabled items run.

Set `Common.Activity` for all items and leave each item's `Activity` blank.
For exceptions, set the item's `Activity`, such as Status for one database and
Restore for another. An explicit CLI `-Activity` overrides all selected items
for that invocation, without editing the file.

The runner preflights every selected item before starting any work. It then
runs Status, Cutover, and Remove activities, followed by the global Restore
submissions and restore polling, then automatic Monitor polling. Monitor displays
all selected monitor mappings in one table. A separate status/cutover command can
inspect or act on migrations while the background restore worker keeps polling.

### SQL login and existing-target approval

Restore preflight checks database existence using each configured SQL hostname
and port. SQLVM defaults to SQL login authentication; SQLMI defaults to an Entra
SQL token for the signed-in Azure identity. Set `TargetSqlAuthType="SqlLogin"`
to use SQL credentials for either or both target types. This does not change
MI managed-identity Blob restore authentication.
Both require `VIEW ANY DATABASE` so a hidden
database cannot be mistaken for an absent database.

Complete the externally managed
[access and infrastructure prerequisites](../Prerequisites/README.md#access-and-infrastructure-managed-outside-scripts),
including [SQL VM Entra setup](../Prerequisites/README.md#sql-vm-entra-authentication-prerequisites)
and [SQL MI identity setup](../Prerequisites/README.md#sql-mi-identity-and-connection-prerequisites)
when applicable. These scripts do not enable Entra authentication, assign
Directory Readers, create the operator's initial SQL login, or provision DMS,
networking, and target infrastructure.

Keep these authentication layers separate:

| Layer | SQL-login mode | Entra mode |
|-------|----------------|------------|
| Azure resource operations and executor Blob discovery | Signed-in Azure context | Signed-in Azure context |
| Executor SQL checks and SQL VM replacement query | Named/interactive SQL credential | SQL access token for the signed-in Azure user |
| DMS service-side Blob access | VM AccountKey; MI ManagedIdentity by default | Unchanged; independent of SQL authentication |

The operational config currently selects `TargetSqlAuthType="Entra"` for both
MIGRDEMO mappings. SQL connections use an Azure SQL access token for the active
Azure context; sign in as the intended user before launching. The retained
`"credential": "sql_target"` reference is ignored in Entra mode, with no SQL-login
fallback. Existing-target replacement still requires explicit approval.

Both operational and example items include blank `TargetTrustServerCertificate`,
`TargetSqlAuthType`, and `credential` fields. A nonblank item value overrides
Common; blank values inherit. Use the JSON boolean `false`, not `"false"`, to
override a common certificate-trust setting of `true`.

#### Named SQL credentials

To switch back to SQL login, use these credential-selection fields in Common,
or override them on a particular item. These are fragments to merge, not complete
replacement configuration files:

```json
{
  "TargetSqlAuthType": "SqlLogin",
  "credential": "sql_target"
}
```

Create `password.local.json` in the same directory as the file passed to
`-ConfigPath`, not the terminal's current directory. Use matching names:
`sql_target` and `SQLTarget` are different names. The local JSON must have this
shape, with no trailing comma:

```json
{
  "credentials": {
    "sql_target": {
      "username": "sqladmin",
      "password": "<your-SQL-login-password>"
    }
  }
}
```

Add other named entries when servers need different credentials. An explicit
`credential` reference takes precedence over legacy credential settings and
interactive login entry. A `-SqlCredentials` PSCredential keyed by exact item ID
still overrides the configured reference. Missing files, unknown names, invalid
JSON, and empty or invalid username/password fields fail before submission,
without falling back to another login. The migration configuration contains only
the name; credentials are excluded from reports. The worker receives protected PSCredential
handoff data, not plaintext passwords in command arguments.

> [!WARNING]
> This local JSON stores the password in plaintext at rest. Git ignore is not
> encryption. The repository ignores files named `password.local.json`; verify
> they remain untracked, restrict file access to the executing Windows account,
> and never force-add, publish, or share them. Prefer the encrypted-file or
> secret-management alternatives below for unattended production use. Rotate any
> password exposed in chat or logs and update the local entry.

After [Azure sign-in](../Prerequisites/README.md#interactive-azure-sign-in) and
selecting SqlLogin, preview both targets with the same script used for Entra:

```powershell
$ConfigPath = '.\DataMigrationService\config\Invoke-RestoreDMS.config.json'
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -ConfigPath $ConfigPath -Activity Restore -WhatIf
```

The named file is loaded without SQL credential prompts. The real Restore run
still requests one replacement approval if targets exist; use the
[replacement example](#replacement-approval-example) only after reviewing the
destructive behavior. Never put a password on the command line.

#### Interactive and encrypted credential alternatives

Without a named reference, interactive SQL credential entry is preferred and
happens before background launch. Items sharing the same endpoint and credential settings reuse one
login entry. You can also supply a `-SqlCredentials` hashtable keyed by exact
item ID with PSCredential values you already obtained.

For interactive SQL login, set this in Common and clear any nonblank item
credential references. A blank item alone cannot disable a named Common value:

```json
{
  "TargetSqlAuthType": "SqlLogin",
  "credential": "",
  "SqlCredentialMode": "Interactive"
}
```

Alternatively, obtain a credential in the launcher and pass it explicitly for
SQL-login items. Neither the password nor this hashtable belongs in JSON:

```powershell
$Login = Get-Credential -UserName 'sqladmin' -Message 'SQL login for both targets'
$SqlCredentials = @{ 'VM-MIGRDEMO' = $Login; 'MI-MIGRDEMO' = $Login }
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Restore -SqlCredentials $SqlCredentials -WhatIf
```

For an unattended run, configure one of these alternatives in Common or on the
SQL-login item:

```json
{
  "SqlCredentialPath": "C:\\Users\\your-user\\AppData\\Local\\SQLMigration\\vm.credential.xml"
}
```

Create that encrypted file once as the Windows account that runs migration:

```powershell
$Directory = Join-Path $env:LOCALAPPDATA 'SQLMigration'
$null = New-Item -ItemType Directory -Path $Directory -Force
Get-Credential -Message 'SQL VM login' |
    Export-Clixml -LiteralPath (Join-Path $Directory 'vm.credential.xml')
```

Alternatively, use configuration references:

```json
{
  "SqlUserName": "migration_login",
  "SqlPasswordEnvironmentVariable": "SQLMIGRATION_VM_PASSWORD"
}
```

Populate that environment variable through your approved secret-management or
automation system before launch. The migration config does not accept a plaintext
password field. `-NonInteractive` disables login prompts and loads the named local
entry if supplied, otherwise the encrypted file, then username/environment references. Missing credentials,
empty password variables, SQL access failures, and insufficient metadata visibility
stop preflight rather than reporting that the database does not exist.

To use saved credentials but still approve replacement interactively, configure
`credential`, or use `SqlCredentialMode="Configured"` for the legacy references,
and run normally without `-NonInteractive`. An encrypted credential file is usable
only by the Windows account on the machine that created it; recreate it after
changing the password.

#### Entra login as the signed-in user

For Entra on both targets, use this Common fragment and leave item auth fields
blank. No username/password entry is read from the local credential file:

```json
{
  "TargetSqlAuthType": "Entra",
  "credential": "sql_target"
}
```

The retained credential name is inactive in Entra mode; it is not a fallback.
Sign in as `kadda@microsoft.com` in the same PowerShell 7 process:

```powershell
$AccountId = 'kadda@microsoft.com'
$TenantId = 'b7d7daca-8689-49f9-8a9b-d20adf81c78b'
$SubscriptionId = 'cd7743ef-8ddc-4254-b715-2c79c8ab4126'

Connect-AzAccount -AccountId $AccountId -Tenant $TenantId `
    -Subscription $SubscriptionId -Scope Process -ErrorAction Stop
$Context = Get-AzContext -ErrorAction Stop
if ($Context.Account.Id -ne $AccountId -or $Context.Tenant.Id -ne $TenantId -or
    $Context.Subscription.Id -ne $SubscriptionId) {
    throw 'The active Azure context does not match the intended migration identity.'
}
[pscustomobject]@{
    Account = $Context.Account.Id
    Tenant = $Context.Tenant.Id
    Subscription = $Context.Subscription.Id
}

$ConfigPath = '.\DataMigrationService\config\Invoke-RestoreDMS.config.json'
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -ConfigPath $ConfigPath -Activity Restore -WhatIf
```

The context output should identify your account, tenant, and subscription.
Illustrative preflight excerpts below apply to either successful auth mode;
the script does not print passwords or access tokens:

```text
Read-only preflight passed for Restore-SQLVM.
Read-only preflight passed for Restore-SQLMI.
VM-MIGRDEMO: target database exists = True; existing migration = True.
MI-MIGRDEMO: target database exists = True; existing migration = True.
What if: Performing the operation "Restore" on target ".../databaseMigrations/MIGRDEMO".
```

Actual existence/migration booleans vary. WhatIf checks access and target
existence but does not ask for replacement approval, delete databases, or
create a background worker. Confirm the account has SQL access as an Entra
principal, not merely a same-named Windows or SQL-authentication login.

A SQL error such as `Login failed for user ''` while `TargetSqlAuthType="Entra"`
is selected does not prove a missing SQL username. That mode uses an Azure SQL
access token, not the SQL password. Azure sign-in and Directory Readers alone do
not grant SQL access: SQL VM needs supported and enabled Entra authentication;
SQL MI needs configured Entra administration and a permitted SQL login/user.
Selecting SqlLogin avoids that Entra dependency but still requires a valid
server-side SQL login and the permissions above. Azure/Blob preflight success
does not validate SQL authentication. Connection/query failures identify the
item, endpoint, and authentication mode; no fallback to another identity occurs.

#### Mixed authentication and item overrides

For SQL login on VM and Entra on MI, merge these fields into the existing
Common and items, retaining all source, target, and DMS details:

```json
{
  "Common": {
    "TargetTrustServerCertificate": true,
    "TargetSqlAuthType": "SqlLogin",
    "credential": "sql_target"
  },
  "Items": [
    {
      "Id": "VM-MIGRDEMO",
      "TargetTrustServerCertificate": "",
      "TargetSqlAuthType": "",
      "credential": ""
    },
    {
      "Id": "MI-MIGRDEMO",
      "TargetTrustServerCertificate": false,
      "TargetSqlAuthType": "Entra",
      "credential": ""
    }
  ]
}
```

VM inherits SQL login, the named credential, and the certificate setting.
MI uses Entra and explicitly overrides certificate trust to false; the inherited
credential name is unused in Entra mode. For different SQL logins, put another
name on the relevant item and add the matching entry to the same local file.
Prefer `TargetTrustServerCertificate=false` with a valid trusted certificate.
The operational file's true value is an explicit test exception; this switch
does not enable Entra, grant access, or disable SQL encryption.

#### Replacement approval example

When databases or migration records already exist, the launcher displays all
affected mappings and asks once for exact replacement item IDs. Enter, for
example, `VM-MIGRDEMO,MI-MIGRDEMO` to approve both; press Enter to skip all existing
targets. Other mappings still run. Unknown IDs stop the launch. In unattended
mode, existing targets are skipped; they are never replaced without this approval.
WhatIf checks existence but never requests replacement approval or deletes anything.

The commands are identical for SQL login and Entra once preflight passes:

```powershell
$ConfigPath = '.\DataMigrationService\config\Invoke-RestoreDMS.config.json'
$Run = & '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -ConfigPath $ConfigPath -Activity Restore
```

Illustrative existing-target prompt and response:

```text
ItemId      Target            Database DatabaseExists
------      ------            -------- --------------
VM-MIGRDEMO akpersonalsqlvm   MIGRDEMO           True
MI-MIGRDEMO ak-personal-sqlmi MIGRDEMO           True
...
Enter exact item IDs to REPLACE (comma-separated), or press Enter to skip all existing targets: VM-MIGRDEMO,MI-MIGRDEMO
```

Do not pass `-NonInteractive` for a replacement test: that skips existing targets.
This is the intentional destructive-approval step, not a routine Y/A/N prompt.
Before replacing an actively monitored target, coordinate and stop its previous
local monitoring worker using the recorded process ID if appropriate; a new
run does not coordinate or terminate an older worker. Do not kill unrelated
PowerShell processes or assume stopping local monitoring cancels Azure migrations.

> [!CAUTION]
> Replacement cancels the existing migration, verifies its termination, removes
> its record, and permanently deletes the selected target database before creating
> a new migration. It disconnects users and is not rollback. The script rechecks
> database identity/create time and migration operation identity after approval;
> changed targets are rejected. Back up target data before approving replacement.

Replacement requires `ALTER ANY DATABASE` on the SQL endpoint and permission to
cancel/delete the database migration resource. SQLMI database deletion uses
`Remove-AzSqlInstanceDatabase`, so the Azure identity also needs managed-instance
database delete permission. System databases are prohibited.

### Background execution and persistent logs

Live execution runs in a hidden, independent PowerShell process by default, on
the same Windows host and user. Login and optional replacement approval finish
in the launching session first. The worker never opens a login or confirmation
dialog. Closing the launching terminal does not terminate the worker; shutting
down the execution host still stops local monitoring.

```powershell
# Default: prompt for SQL login if needed, preflight, approve any replacement,
# launch the worker, then return its PID and log/report locations.
$Run = & '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Restore

# Follow output without controlling the background worker.
Get-Content -LiteralPath $Run.LogPath -Tail 30 -Wait

# Check local worker state, independently of DMS migration state.
Get-Content -LiteralPath $Run.StatePath -Raw | ConvertFrom-Json

# Query Azure migration state for both targets, even from a new signed-in session.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Status -Foreground

# Or inspect just one target database migration.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Status -ItemId 'MI-MIGRDEMO' -Foreground

# Run visibly in this terminal instead.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Status -Foreground

# Use configured credentials, with no interactive input.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Restore -NonInteractive
```

Run these inspection commands individually. `Get-Content -Wait` keeps following
the log until Ctrl+C; stopping the log tail does not stop the background worker.
The `-NonInteractive` example skips existing targets and is not a replacement run.

Illustrative launch response:

```text
ProcessId    : 18452
Status       : Running
RunDirectory : ...\DataMigrationService\logs\Runs\20261023-150000.<run-id>
LogPath      : ...\execution.log
StatePath    : ...\run.json
JsonReports  : {...\Reports\Invoke-RestoreDMS.<run-id>.json}
CsvReports   : {...\Reports\Invoke-RestoreDMS.<run-id>.csv}
```

Each run keeps a transcript, stdout/stderr, local process state, and periodically
updated database reports. `Running` means the worker started, not that migration
succeeded. Verify the reports and Azure state. `run.json` records Succeeded or
Failed when the local workflow finishes.

Illustrative local worker-state output:

```text
Status    : Running
ProcessId : 18452
UpdatedAt : 2026-10-23T10:30:00Z
Error     :
```

`$Run` exists only in the launching session. Record its paths before closing
that terminal, or open the exact run's `run.json`/`execution.log` under
[logs/Runs](./logs/Runs). Do not assume the newest directory belongs to the run
you intend to inspect. Azure Status queries are independent of this local
process state and do not restart or cut over a migration.

The launcher exports its Azure context and DPAPI-encrypted SQL credentials into
a current-user-only run directory. The request is deleted when consumed; context
files are deleted when work finishes. No secrets go on process command lines.
Use the same Windows identity and an existing usable Azure sign-in; a worker
authentication error is recorded, not replaced with an interactive sign-in.
After a crash or host shutdown, protected handoff files may require manual cleanup.

### Restore multiple VM and MI databases

```powershell
# Preview every enabled mapping without submitting a migration.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Restore -WhatIf

# Live: both types share Common.MaxConcurrentRestores.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Restore

# Or start just the MI mapping.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Restore -ItemId 'MI-MIGRDEMO'
```

DMS migration creation runs in process-isolated batches governed by
`Common.MaxConcurrentRestores`, up to 10. For 20 items at a limit of 10, all
10 creation workers start together; after their submission results return, the
next 10 start. There is no wait for database restoration or cutover between
batches. All 20 accepted migrations can restore concurrently in Azure.
Each process imports the Azure context independently, avoiding cross-subscription
context races. This creates database migration records under existing DMS
services, not separate DMS services.

One item's creation, restore, or monitoring failure is recorded without blocking
the other selected restores. The final workflow is failed if any item has failed
or unverified status. An unverified submission may still be running in Azure;
inspect it before retrying. Local process-launch/reporting failures can stop the
workflow, without canceling accepted Azure migrations.
With AutoCutover false, the worker continues polling while ready databases await
an explicitly initiated cutover. Later creation batches are not blocked.

Restore submission uses one implementation with a `TargetType` switch to select
the VM or MI Azure cmdlet. Authentication and backup selection are shared;
the same workflow handles monitoring, cutover, removal, and aggregate results.
Do not start another restore for a target database already migrating elsewhere.
Treat `SkippedExistingMigration` and `SkippedExistingTarget` as skipped work,
not completed restore.

### Cutover and cleanup

```powershell
# Preview cutover for all enabled mappings; every selected database must be ready.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Cutover -WhatIf

# Live only after the approved write freeze, final logs, and catch-up verification.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Cutover

# Or cut over just one mapping.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Cutover -ItemId 'MI-MIGRDEMO'

# Remove only configured completed database migration records, not databases.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Remove -WhatIf
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Remove
```

Discovery matches each item's subscription, DMS group/service, target
type/name/group, and target database. It does not operate on unrelated
databases on the same server. Cutover accepts ReadyForCutover and ReadyToCutover
and uses the common global cutover limit, with per-item polling/timeout values.
No cutover begins if preflight for any selected mapping fails.

Remove processes all eligible records within the selected config/CLI scope,
without row-selection or confirmation prompts. It selects Succeeded records
by default. `IncludeReadyForCutover=true` is disruptive:
it removes tracking without cutting over. Neither option deletes the target
database, backup blobs, resource group, or DMS service.

Monitor (`-Activity Monitor`) refreshes automatically using the smallest pending
item's `RefreshWaitMinutes`, until all selected migrations reach Succeeded,
Failed, Canceled, or Cancelled. It never initiates cutover. Use `-Activity Cutover`
separately after the source-write freeze and final-log checks. ReadyForCutover can
wait indefinitely for that action. Ctrl+C in Foreground stops local monitoring,
not Azure migrations. Missing migration status is an error.

Routine database operations and report writes never prompt, including when
`-Confirm` is supplied for compatibility. Use `-WhatIf` to preview mutations.
Interactive steps are Azure sign-in when needed, SQL credential entry only when
configured, and explicit existing-target replacement approval before launch.
Named SQL credentials and Entra SQL tokens do not open SQL credential dialogs.

## Authentication and preflight

For service-side Blob access, SQL MI defaults to ManagedIdentity/SystemAssigned.
This is separate from `TargetSqlAuthType`. Enable its identity and grant
Storage Blob Data Reader on the corresponding backup account/container.
This mode never retrieves account keys. The executor separately needs Blob
discovery access, resource-read access, and migration management permissions.
User-assigned identity and explicit MI AccountKey remain supported when the
installed cmdlet supports them. SQL VM requires AccountKey; the executor needs
listKeys permission and the storage account must allow shared-key access.
No authentication fallback is applied.

Pre-create containers, target resources, and the SQL migration service.
Deleting database migration records/projects allows a new Restore run to create
them again. If you deleted the DMS SQL service itself, recreate it first;
preflight stops rather than provisioning a replacement.
Blob-source restore does not require a self-hosted integration runtime to report
Online; network-share workflows have different requirements.
Preflight checks resource fields, duplicate target databases, module
capabilities, subscription access, timestamped FULL visibility, DMS provisioning
and region, target identity, and executor connectivity.

TCP preflight is enabled for both target types and uses the effective configured
`TargetSqlHost` and `TargetSqlPort`. It does not substitute the MI resource's
private hostname or force port 1433. The operational config checks VM DNS on
1433 and the MI public hostname on 3342. For private MI connectivity, configure
its VNet hostname and port 1433 instead. Keep `TargetName` as the Azure resource
name, not a SQL endpoint. This executor check does not change how DMS connects
to the target or verify DMS-side networking. See the
[endpoint caveat](../Prerequisites/README.md#sql-mi-restore-endpoint-caveat).

`-WhatIf` runs live read-only preflight, including key retrieval for AccountKey,
but creates no logs, reports, dispatch files, or migrations. It does not certify
future write permissions, service-side Blob access, DMS network routing, backup
integrity, or production readiness. Confirm authorization and SQL compatibility
in a rehearsal.

## Backup staging

The uploader retains schema version 1 (`Settings` and `Items`).
Its current MIGRDEMO row is active and overwrite is enabled; review before use.
`BackupRootPath` contains FULL, optional DIFF, and LOG subfolders.

```powershell
& '.\DataMigrationService\scripts\Invoke-CopyBackup-OnPrem-AzureBlob.ps1' -WhatIf
& '.\DataMigrationService\scripts\Invoke-CopyBackup-OnPrem-AzureBlob.ps1' -InteractiveLogin
```

The uploader selects the latest timestamped FULL, latest later DIFF, and
subsequent LOG files. FULL uses `.bak`; DIFF uses `.bak`/`.diff`; LOG uses
`.trn`/`.log`. Built-in timestamp formats include `yyyyMMdd_HHmmss`,
`yyyy-MM-dd_HH-mm-ss`, `yyyy-MM-ddTHH-mm-ss`, `yyyyMMddHHmmss`, and legacy
`_backup_yyyy_M_d`. Custom `TimestampPattern` must capture `(?<ts>...)` and be
paired with `TimestampFormat`; use the same parser for upload and restore.

`IsActive=N` excludes uploads; `CheckLatestBak=Y` checks availability instead.
`IncludeLogsAtSameTimestamp` includes logs at the baseline timestamp.
If container names are omitted, restore/upload derive the same lowercase,
sanitized source-server/database name, truncated to 63 characters. Explicit
containers avoid naming collisions and support existing containers.

Schedule repeated log uploads separately; the uploader scans once, not
continuously. Do not upload files still being written. Blob length matches
are not checksum verification. Striped backups require a separate workflow
that stages every media-family member. Verify FULL/DIFF compatibility and
unbroken LOG LSN chains from SQL backup metadata, not filenames.

## Output examples and reports

Illustrative output only; actual statuses and backup filenames vary:

```text
VM-MIGRDEMO: Status SQLVM akpersonalsqlvm/MIGRDEMO
MI-MIGRDEMO: Status SQLMI ak-personal-sqlmi/MIGRDEMO
...
ItemId      TargetName        DatabaseName MigrationStatus LatestFile
------      ----------        ------------ --------------- ----------
VM-MIGRDEMO akpersonalsqlvm   MIGRDEMO     ReadyForCutover ...
MI-MIGRDEMO ak-personal-sqlmi MIGRDEMO     Restoring       ...
```

Restore preview ends with What if lines, not successful cutover results:

```text
Read-only preflight passed for Restore-SQLVM.
Checking executor TCP connectivity to ak-personal-sqlmi.public.3c52841dc1d0.database.windows.net:3342 (SQLMI).
Executor TCP connectivity passed for ak-personal-sqlmi.public.3c52841dc1d0.database.windows.net:3342.
Read-only preflight passed for Restore-SQLMI.
What if: Performing the operation "Restore" on target ".../databaseMigrations/MIGRDEMO".
```

Live restore monitoring writes item IDs and DMS states to the execution log
(and the console with Foreground). Approved cutover can
report Succeeded. Remove can report NoRemoval while databases remain ready for
cutover; the completed-only filter deliberately excludes them.
See the [project examples](../README.md#script-configuration-and-command-examples)
for upload and server-object sample outputs.

Set `Common.OutputJsonPath`/`ExportCsvPath` to write one aggregate result file
for all selected mappings. Override the path on an item for its own report.
Mappings inheriting the same path are grouped into one write, not overwritten
by the last database. Preflight failures and WhatIf create no output files.
Execution errors produce failure details and are rethrown. Reports contain
item ID, activity, target/database, local status, DMS migration status, latest
restored backup, and errors. Live activities without explicit report paths write
per-run JSON and CSV reports in the Reports subdirectory under [logs](./logs). These replace the
separate platform logs/reports and are updated during submission and polling.
Routine report writes never request confirmation.
An in-progress restore report has status `InProgress`, not `Succeeded`.
Uncertain submissions and failed monitoring are recorded explicitly; verify
Azure state before restarting those items.

Illustrative aggregate JSON excerpt for a restore still waiting for cutover
(selected fields only):

```json
{
  "schemaVersion": 1,
  "operation": "DMSWorkflow",
  "status": "InProgress",
  "completedAt": null,
  "results": [
    {
      "ItemId": "VM-MIGRDEMO",
      "Activity": "Restore",
      "Status": "Submitted",
      "MigrationStatus": "ReadyForCutover"
    },
    {
      "ItemId": "MI-MIGRDEMO",
      "Activity": "Restore",
      "Status": "Submitted",
      "MigrationStatus": "Restoring"
    }
  ],
  "errors": []
}
```

Report `status`, per-item `Status`, and Azure `MigrationStatus` describe different
things. For a Status activity, local `Succeeded` means inventory was read, not
that the database migration finished. Require the relevant Azure terminal state
and target validation before declaring a restore complete.

An authentication failure can look like this illustrative excerpt:

```text
SQL connection/query failed for item 'VM-MIGRDEMO' at 'tcp:akpersonalsqlvm.centralus.cloudapp.azure.com,1433' using 'Entra' authentication: Login failed for user ''.
```

Stop and check account/tenant, SQL VM Entra enablement, managed-identity Graph
permissions, and the SQL login grants. An auth failure during preflight starts
no new migrations in that invocation; it does not cancel migrations already
running in Azure.

## Single entry point and validation

Use `Common.Activity` or an item's `Activity` to select Restore, Status, Monitor,
Cutover, or Remove, then run the same command without changing scripts:

```powershell
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -ConfigPath '.\DataMigrationService\config\Invoke-RestoreDMS.config.json' `
    -WhatIf
```

An explicit CLI `-Activity` overrides the selected items. The lifecycle script
requires schema version 2; convert old per-operation schema version 1 files to
the Common/Items format. The separate backup uploader still uses schema version 1.
Its historical ConfigPath aliases accept JSON, not CSV; generated CSV reports
remain supported.

Timestamp parsing, Blob authentication, inventory, cutover, configuration
inheritance, and global queue management use [shared helpers](./scripts/Common).
No server-object helpers are imported.

Validation uses PowerShell 7 and mocked Pester 5 tests:

```powershell
Invoke-Pester -Path '.\DataMigrationService\tests' -Output Detailed
```

Tests do not replace validation with real backups and installed Azure modules.
TDE certificates, keys, SSISDB requirements, compatibility levels, final source
write freeze, application redirection, and rollback planning remain separate.
Existing targets/migrations require the explicit replacement approval described
above. Unattended runs skip them; skipped records are not successful restores.

## Related workflow

Use [ServerObjectMigrationService](../ServerObjectMigrationService/README.md)
for logins, users, permissions, operators, alerts, and SQL Agent jobs. Database
restore does not migrate those objects. Both restore paths are online-only;
offline restore and network-share backup sources are not implemented here.

Server-object migration has one separate Common/Items configuration and entry point.
Each item has its independent source, target, database list, container, and login
definitions. Shared settings include Azure context, storage account/resource group,
Key Vault, enable/activity defaults, and mail defaults. Nonblank item settings take
priority; blank/null/omitted values inherit Common and false is an explicit override.
Its default `Generate` activity preserves SQL in private,
server-specific Blob containers, replacing the current snapshot in component
subfolders. Later `Execute` reads those files without a generation ID.
The item-specific `ProvisionLogins` flag enables direct provisioning of multiple
SQL/Entra/managed-identity logins with per-login access; provisioning-only runs
do not access storage. New SQL-login passwords come from Key Vault at runtime
and are never uploaded. See the
[provisioning examples](../ServerObjectMigrationService/README.md#provision-item-specific-logins-directly).
These activities do not inherit DMS credential settings, background execution,
replacement approval, or restore concurrency.

Microsoft references:
[SQL VM migration cmdlets](https://learn.microsoft.com/powershell/module/az.datamigration/new-azdatamigrationtosqlvm)
and [SQL MI migration cmdlets](https://learn.microsoft.com/powershell/module/az.datamigration/new-azdatamigrationtosqlmanagedinstance).
