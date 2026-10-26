---
title: SQL Migration Workspace
description: Scope, prerequisites, configuration, and operation of SQL Server migrations to Azure SQL VM and Azure SQL Managed Instance.
---

## SQL Migration Workspace

PowerShell-based migration workspace for restoring **SQL Server database backups**
through **Azure Database Migration Service (DMS)** to **SQL Server on Azure VM**
or **Azure SQL Managed Instance**, and migrating the associated SQL Server
objects separately.

Use the scripts to stage existing backups in Blob storage, start and monitor
online migrations, request an approved cutover, and generate or execute reviewed
server-object SQL. Database migration and server-object migration are separate
workstreams, not one automatically coordinated deployment.

> [!IMPORTANT]
> This workspace operates against existing infrastructure. It does not deploy
> VM/MI/DMS instances or storage accounts, install SQL Server, create source backups, configure networking,
> or coordinate application shutdown and redirection. Review configuration and
> permissions before every live run. There is no dashboard or hosted service.

## Scope

### In scope

* Check local prerequisites and optionally install missing PowerShell modules.
* Select timestamped FULL, optional DIFF, and subsequent LOG backup files and
  upload them to a flat, pre-existing database Blob container.
* Start and monitor online, Blob-source DMS migrations to SQL VM or SQL MI.
* Discover existing migrations independently of the initiating process,
  including migrations created through the Azure portal.
* Display migration status and available latest-restored-backup metadata,
  export inventory, and request cutover for explicitly selected databases.
* Remove selected migration tracking resources after completion, without
  deleting the target databases.
* Generate and optionally execute SQL for supported logins, database users,
  roles, permissions, Agent jobs, operators, alerts, and Database Mail.
* Support AD-to-Entra mapping for the MI object workflow and optional access
  grants for existing, uniquely resolvable managed identities.
* Generate and archive server-object SQL to private per-target Blob containers,
  then execute an explicitly selected, integrity-checked archive.
* Provision SQL-authentication logins on VM or MI using existing Key Vault secrets.
* Extract login-specific database permissions from an archived SQL generation.
* Produce operation-specific logs, generated SQL, CSV reports, and optional JSON
  results. Available evidence differs by script.

### Out of scope and current limitations

The active scope is SQL Server database migration from existing backup files to
Azure SQL VM or SQL Managed Instance, plus the supported server objects listed
above. The following boundaries apply to those workflows.

#### Not automated by this project

* Infrastructure preparation: creating the VM, SQL MI, DMS service, storage
  account, backup containers, or Key Vault; installing SQL Server; and configuring SQL
  VM registration, DNS, routing, NSGs, and firewalls.
  Server-object archival can create its configured private containers when enabled.
* Access provisioning: creating AD/Entra identities, assigning Azure RBAC, and
  establishing the executor's initial SQL and directory permissions. Optional
  SQL grants for existing managed identities are a separate supported component.
* Backup production and lifecycle: taking or scheduling source FULL, DIFF, and
  LOG backups, validating their SQL backup chain, enforcing retention, or
  deleting local backups. Uploading existing backups to Blob remains in scope.
* Application cutover coordination: stopping source writes, taking the final
  log backup, confirming final catch-up, disabling source jobs, changing
  application connection strings, and enabling target jobs. The script can
  request DMS cutover, but does not perform these surrounding tasks.
* Complete instance migration: reproducing linked servers, proxies, credentials,
  certificates, SMTP passwords, SSIS packages, and dependencies beyond the
  explicitly supported server-object components.
* Availability and recovery design: configuring WSFC, Always On, log shipping,
  disaster recovery, or an automatic rollback to the source.
* Post-migration acceptance: comprehensive data reconciliation, application
  testing, performance tuning, and business sign-off remain operator activities.

#### Current implementation limitations

* The unified DMS lifecycle script supports online migration from Azure Blob
  only. It does not implement offline restore or DMS network-share backup sources.
* SQL MI service-side Blob reads default to the target MI's system-assigned
  managed identity; it needs Blob read access. SQL VM uses a runtime-retrieved
  storage key. Az.DataMigration 1.1.1 supports managed-identity parameters for
  MI, not VM. The executor's interactive token is not passed to DMS for Blob reads.
* SQL VM server-object execution uses Windows integrated authentication;
  configuring a SQL login in SSMS does not change that behavior. SQL MI
  server-object execution uses Entra authentication.
* Server-object generation and database restore are independent. There is no
  single transaction or orchestrator coordinating both, and generated SQL
  must be reviewed before target execution.
* Imported Agent jobs remain disabled. Generated job SQL can drop and recreate
  existing target jobs; review schedules, owners, and dependencies before use.
* DMS readiness and restored-backup metadata do not prove that source writes
  have stopped or every required transaction has reached the target.
  A cutover-monitoring timeout does not cancel the Azure operation.
* Preflight validates the checks implemented by each script, not future write
  success, every network path, SQL backup/LSN compatibility, or production
  readiness. Unit tests do not replace a rehearsal and target validation.
* Historical files under Archive are reference material, not supported active
  entry points or evidence that additional migration features are implemented.

## Repository layout

```text
SQLMigration\
|-- README.md                          Project entry point and examples
|-- Prerequisites\
|   |-- README.md                      Installation, authentication, permissions
|   |-- Install-MigrationPrerequisites.ps1
|   `-- tests\                         Setup unit tests
|-- DataMigrationService\
|   |-- README.md                      Backup upload and DMS operating guide
|   |-- config\                        Two operational configs and one template
|   |-- scripts\
|   |   |-- Invoke-CopyBackup-OnPrem-AzureBlob.ps1
|   |   |-- Invoke-RestoreDMS.ps1        Restore, status, monitor, cutover, removal
|   |   `-- Common\                    Configuration, preflight, migration helpers
|   |-- tests\                         Configuration and migration unit tests
|   `-- logs\                          Runtime logs and restore reports
`-- ServerObjectMigrationService\
    |-- README.md                      Object selection and execution safeguards
    |-- config\                        One Common/Items object-migration config
    |-- scripts\
    |   |-- Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1
    |   `-- Common\                    Configuration, preflight, SQL/SMO helpers
    |-- tests\                         Configuration and object-generation tests
    `-- output\Runs\                   Per-run/item SQL, logs and reports
```

Runtime output directories are created as needed. Keep each package's Common
helpers with its entry-point scripts; neither package imports the other's helpers.

## Prerequisites

Use the [prerequisites guide](Prerequisites/README.md) for installation commands,
workload-specific modules, Azure permissions, and sign-in troubleshooting.

* Use **PowerShell 7+** (`pwsh`), not Windows PowerShell 5.1 or PowerShell ISE.
  VS Code's PowerShell 7 terminal and standalone PowerShell 7 are both suitable.
* Use a Windows administration host with the SqlServer module and RSAT
  ActiveDirectory tools for server-object migration.
* Restore requires the appropriate Az modules; backup upload also needs AzCopy
  v10+ and separate AzCopy authentication.
* Pre-create DMS, storage containers, and the target SQL VM/MI. Register SQL VM
  with the SQL IaaS Agent extension and meet the target-specific DMS prerequisites.
* Validate network paths, SQL ports, target capacity, and source/target SQL,
  AD/Entra, Azure, and Key Vault permissions for the selected operation.
* For MI restore, grant the target MI identity Storage Blob Data Reader on the
  backup container/account. For VM restore, grant the Azure user storage-account
  `listKeys` permission and allow shared-key access. Both need executor Blob
  data access for discovery; MI's default flow does not retrieve keys.
* Backups already in Blob do **not** require an Online self-hosted integration
  runtime. Network-share migrations are a different scenario.

Installing modules does not grant permissions or prove connectivity.

Complete the manual
[access and infrastructure checklist](Prerequisites/README.md#access-and-infrastructure-managed-outside-scripts)
before running the migration scripts. For SQL VM Entra login, follow the
[SQL Server 2022+, managed identity, directory permissions, and SQL IaaS configuration steps](Prerequisites/README.md#sql-vm-entra-authentication-prerequisites).
These are not performed by the prerequisite installer or restore script.
Directory Readers belongs on the target managed identity for directory lookup,
not on your personal account as a substitute for SQL permissions. SQL sysadmin,
Azure migration RBAC, and Blob access must be validated separately.

For MI, also review the [identity and connection prerequisites](Prerequisites/README.md#sql-mi-identity-and-connection-prerequisites):
configure an Entra administrator and the MI identity's directory-read access.
The reported `Paired` authentication metadata setting is an environment-specific
choice, not a substitute for SQL permissions or Windows/Kerberos setup.

## Initial setup

Run all examples from the repository root. Start PowerShell 7, then confirm:

```powershell
$PSVersionTable.PSVersion

# Check only; select the workload you need.
& '.\Prerequisites\Install-MigrationPrerequisites.ps1' -Workload SqlVmRestore

# Preview installation, then install missing Gallery modules for CurrentUser.
& '.\Prerequisites\Install-MigrationPrerequisites.ps1' -Workload SqlVmRestore -Install -WhatIf
& '.\Prerequisites\Install-MigrationPrerequisites.ps1' -Workload SqlVmRestore -Install
```

Other workload names are `SqlMiRestore`, `BackupUpload`, `MigrationControl`,
`ServerObjects`, `LoginProvisioning` (`SqlAuthLogins` compatibility alias), and `All`.
Setup does not install PowerShell itself, AzCopy, or RSAT, sign in, or run migrations.

Illustrative setup output for `SqlVmRestore`:

```text
PASS module: Az.Accounts
PASS module: Az.DataMigration
PASS module: Az.Storage
PASS module: Az.Resources
PASS module: Az.SqlVirtualMachine
PASS module: SqlServer
Local prerequisites passed for SqlVmRestore. Azure access, SQL permissions, identities, and configuration still require migration preflight.
```

For Azure operations, sign in in the **same PowerShell process**:

```powershell
$tenantId = 'kartheekkumar801gmail.onmicrosoft.com'
$subscriptionId = 'cd7743ef-8ddc-4254-b715-2c79c8ab4126'

Connect-AzAccount -AccountId 'kadda@microsoft.com' `
    -Tenant $tenantId -Subscription $subscriptionId -Scope Process -ErrorAction Stop
Get-AzContext | Select-Object Account, Tenant, Subscription
```

If account selection or token-cache authentication fails, use the documented
[process-scoped browser-login workaround](Prerequisites/README.md#account-picker-or-token-cache-failures-on-windows).
Azure CLI login does not establish an Az PowerShell context. Azure sign-in also
does not grant SQL access.

## Configuration conventions and current environment

DataMigrationService uses two operational files:
[backup upload](DataMigrationService/config/Invoke-CopyBackup-OnPrem-AzureBlob.config.json)
and [DMS lifecycle](DataMigrationService/config/Invoke-RestoreDMS.config.json).
The [DMS example template](DataMigrationService/config/Invoke-RestoreDMS.example.json)
contains both SQLVM and SQLMI mappings; it is not a third operational configuration.
ServerObjectMigrationService uses one
[server-object configuration](ServerObjectMigrationService/config/Invoke-MigrateServerObjects-ProvisionLogin-AzSql.config.json).
Upload files use schema version 1 (`Settings` and optional `Items`).
DMS and server objects each use their own schema-version-2 `Common`/`Items`
contract. Server-object sources, targets, database lists, containers, and login
definitions remain independent per item; shared settings live in Common.
Their properties and authentication options are not interchangeable.
Each item holds one source backup-to-target database mapping, including
`TargetType` (`SQLVM` or `SQLMI`), target resource name, and database name.
Nonblank item values override Common; blank, null, or omitted values inherit.
Boolean false is an override, not a blank. Resource-group overrides can place
storage, DMS, and targets in different groups for every mapping.

Set `Common.Activity` to `Restore`, `Status`, `Monitor`, `Cutover`, or `Remove`.
An item's nonblank `Activity` overrides it for that mapping. Run
[Invoke-RestoreDMS.ps1](DataMigrationService/scripts/Invoke-RestoreDMS.ps1)
after each edit, or use an explicit CLI `-Activity` override.
With no filters it processes every enabled mapping, including both target types.
The operational configuration currently selects Restore and enables both
VM-MIGRDEMO and MI-MIGRDEMO. A config-only invocation without `-WhatIf` starts
live restores; use explicit `-Activity Status` for status checks.
`Common.MaxConcurrentRestores` limits parallel migration creation requests across
VM and MI, in batches of up to 10. Later batches do not wait for earlier restores
or cutovers. Twenty configured databases can therefore have all 20 restores active
after two submission batches. Live runs launch a background worker by default;
use `-Foreground` for synchronous console output.
The operational config currently uses Entra authentication for both targets,
using the signed-in Azure identity's SQL access token. The retained
`"credential": "sql_target"` reference is ignored in Entra mode. When
`TargetSqlAuthType="SqlLogin"` is selected, username/password are loaded from a separate,
Git-ignored `password.local.json` beside the selected migration config. This
local file is plaintext at rest and must have restricted access. Without a named
reference, SQLVM login is interactive first, with encrypted credential-file or
username/password-environment-variable alternatives for unattended execution.
SQLMI target checks default to Entra authentication; `TargetSqlAuthType="SqlLogin"`
supports SQL login on either target. `SqlCredentialMode="Configured"` uses stored
credential references without disabling replacement approval. The launcher checks target database
existence and asks once for exact replacement IDs when needed. Replacement
permanently deletes the approved target databases; unattended runs skip existing
targets. Routine operations and report writes never ask for confirmation.
See [login, replacement, and background examples](DataMigrationService/README.md#sql-login-and-existing-target-approval).
See the [inheritance reference](DataMigrationService/README.md#common-defaults-and-per-database-overrides).

* Edit a copy for another environment and pass it using `-ConfigPath`.
* The runner supports `ItemId`, `Databases`, `TargetName`, and `TargetType`
  selectors. An explicit CLI Activity takes precedence for selected items.
  The single DMS lifecycle script routes by each item's Activity and TargetType;
  it does not invoke separate VM/MI, control, or removal scripts.
* Keep `WhatIf` on the command line, not in JSON. The DMS lifecycle accepts
  `Confirm` for compatibility but does not use it to enable routine prompts.
* Preserve the configuration's field names and value types. Some flags are
  JSON booleans; server-object flags use `"Yes"`/`"No"`, and uploader row
  activation uses `"Y"`/`"N"`.
* The snippets below show fields to edit, **not complete replacement files**.
  Keep all other required settings and item fields.
* Never store passwords, storage keys, tokens, or secret values in tracked configuration.
  Keep the optional local SQL password file ignored and access-restricted.

The checked-in personal environment currently uses:

| Setting | Current value |
|---------|---------------|
| Subscription | `cd7743ef-8ddc-4254-b715-2c79c8ab4126` |
| Resource group | `rg-ak-personal` |
| Region | `centralus` |
| Storage account | `akpersonalsa` |
| DMS service | `ak-personal-dms` |
| Source SQL instance | `DESKTOP-SGA61QP\DMF` |
| SQL VM resource | `akpersonalsqlvm` |
| SQL VM connection endpoint | `tcp:akpersonalsqlvm.centralus.cloudapp.azure.com,1433` |
| SQL MI resource | `ak-personal-sqlmi` |
| SQL MI connection endpoint | `ak-personal-sqlmi.public.3c52841dc1d0.database.windows.net,3342` |
| Backup container | `desktop-sga61qp-dmf-migrdemo` |

These values are environment examples, not required infrastructure names.
Upload and restore currently select only `MIGRDEMO`. Server-object configs still
select `MIGRDEMO,CDC_Director_PRO`; align that selection with the databases you
actually intend to migrate. The mixed-target dispatcher currently contains an
MI row only. Key Vault login names, vault/secret names, and permission-export
login selection still require real values.

## Script configuration and command examples

> [!WARNING]
> `-WhatIf` runs live read-only preflight, not an offline simulation. Depending
> on the script, it can query SQL, Azure, AD/Entra, read Key Vault secrets, or
> retrieve a storage account key. It returns before uploads, SQL generation,
> target writes, cutover, removal, and run-output creation.

The sample outputs below are illustrative excerpts, not results from executing
these examples. Timestamps, warnings, paths, counts, and statuses vary. Omitted
lines are marked `...`; generated-output trees describe files rather than
literal console output. Azure module deprecation warnings can appear before
the useful results and do not by themselves mean the operation failed.

### Choose SQL credentials or Entra before restore

These modes apply to DMS restore SQL connections on either target type, not to
all scripts in this repository. They do not change the VM AccountKey or MI
ManagedIdentity service-side Blob settings. Both modes require Azure sign-in
for resource operations and executor Blob discovery.

For named SQL credentials, edit these fields in Common:

```json
{
  "TargetSqlAuthType": "SqlLogin",
  "credential": "sql_target"
}
```

The separate `DataMigrationService\config\password.local.json` contains the
matching named entry, for example:

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

Never replace an existing local password with this placeholder. The file is
Git-ignored but plaintext at rest; restrict access and never publish it.
Named credentials load without a SQL login prompt. See the
[named credential and interactive/encrypted alternatives](DataMigrationService/README.md#named-sql-credentials).

For Entra, edit these Common fields instead:

```json
{
  "TargetSqlAuthType": "Entra",
  "credential": "sql_target"
}
```

The retained credential reference is ignored in Entra mode, with no SQL-login
fallback. This is the current operational setting for both MIGRDEMO mappings.
Sign in as the intended account using the [initial setup](#initial-setup)
commands, verify the account/tenant/subscription, and complete target-side
Entra setup first. The SQL token represents the signed-in Azure user, not the
target's managed identity or automatically the Windows terminal user.

Both items include blank `TargetTrustServerCertificate`, `TargetSqlAuthType`,
and `credential` fields. Blank values inherit Common; a nonblank item value
wins. JSON boolean `false` explicitly overrides `true`. For mixed authentication,
set one item's auth type to SqlLogin and the other's to Entra; see the
[mixed-item example](DataMigrationService/README.md#mixed-authentication-and-item-overrides).
Prefer a valid trusted SQL certificate and `TargetTrustServerCertificate=false`;
the current true setting is an explicit test exception.

The same preview and run commands work for either selected auth mode:

```powershell
$ConfigPath = '.\DataMigrationService\config\Invoke-RestoreDMS.config.json'

# Live read-only checks, including SQL authentication and target existence.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -ConfigPath $ConfigPath -Activity Restore -WhatIf

# Only after successful preflight and review of target replacement.
$Run = & '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -ConfigPath $ConfigPath -Activity Restore
```

If both targets exist, illustrative approval input is:

```text
Enter exact item IDs to REPLACE (comma-separated), or press Enter to skip all existing targets: VM-MIGRDEMO,MI-MIGRDEMO
```

> [!CAUTION]
> Approval cancels/removes the selected old migration and permanently deletes
> the selected target database before recreating its migration. This is not
> cutover or rollback. Coordinate any existing local monitoring worker before
> replacing an actively monitored target. `-NonInteractive` skips existing
> targets; it cannot approve replacement.

Illustrative background launch excerpt:

```text
ProcessId : 18452
Status    : Running
LogPath   : ...\DataMigrationService\logs\Runs\<run-id>\execution.log
StatePath : ...\DataMigrationService\logs\Runs\<run-id>\run.json
```

Follow the exact run and query Azure migration state separately:

```powershell
Get-Content -LiteralPath $Run.StatePath -Raw | ConvertFrom-Json
Get-Content -LiteralPath $Run.LogPath -Tail 30 -Wait
```

In a separate signed-in terminal, status can be checked without restarting restore:

```powershell
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -ConfigPath '.\DataMigrationService\config\Invoke-RestoreDMS.config.json' `
    -Activity Status -Foreground
```

`Running` describes the local worker, not migration success. A DMS
`ReadyForCutover` state awaits an explicitly approved cutover. Save the returned
paths before closing the launcher; `$Run` is not available automatically in a
new terminal. See the
[complete Entra example](DataMigrationService/README.md#entra-login-as-the-signed-in-user)
and [output/report examples](DataMigrationService/README.md#output-examples-and-reports).

### 1. Upload existing backups to Blob

Edit [Invoke-CopyBackup-OnPrem-AzureBlob.config.json](DataMigrationService/config/Invoke-CopyBackup-OnPrem-AzureBlob.config.json).
Set the subscription/tenant and AzCopy executable in Settings. For each selected
Items record, update:

```json
{
  "SrcServerName": "DESKTOP-SGA61QP\\DMF",
  "SrcDatabaseName": "MIGRDEMO",
  "BackupRootPath": "C:\\Backups\\DESKTOP-SGA61QP$DMF\\MIGRDEMO",
  "IsActive": "Y",
  "BackupStorageAccountName": "akpersonalsa",
  "BackupContainerName": "desktop-sga61qp-dmf-migrdemo"
}
```

The current row is active and `Settings.Overwrite` is `"true"`; review overwrite
behavior before a live upload. Use `IsActive="N"` to exclude a row from upload.
Prepare compatible timestamped backups and the destination container separately.

```powershell
& '.\DataMigrationService\scripts\Invoke-CopyBackup-OnPrem-AzureBlob.ps1' -WhatIf

# Live upload; request AzCopy interactive authentication.
& '.\DataMigrationService\scripts\Invoke-CopyBackup-OnPrem-AzureBlob.ps1' -InteractiveLogin
```

Skip this step if the required backups are already uploaded.

Illustrative successful upload excerpt, with timestamp prefixes omitted:

```text
[INFO] Row #1: Completed uploads. Files: ...
[INFO] Summary: Successful rows=1, Failed rows=0
```

This reports file upload, not successful database restore. Investigate failed
rows before starting DMS.

### 2. Restore to SQL VM

Edit [Invoke-RestoreDMS.config.json](DataMigrationService/config/Invoke-RestoreDMS.config.json).
Keep `Common.AutoCutover=false` for separately approved cutover.
VM-MIGRDEMO is one source-to-target item:

```json
{
  "Id": "VM-MIGRDEMO",
  "Activity": "",
  "SrcServerName": "DESKTOP-SGA61QP\\DMF",
  "SrcDatabaseName": "MIGRDEMO",
  "BackupStorageAccount": "",
  "BackupStorageResourceGroup": "",
  "BackupStorageContainerName": "desktop-sga61qp-dmf-migrdemo",
  "TargetType": "SQLVM",
  "TargetName": "akpersonalsqlvm",
  "TargetResourceGroup": "",
  "TargetSqlHost": "akpersonalsqlvm.centralus.cloudapp.azure.com",
  "TargetSqlPort": 1433,
  "TargetTrustServerCertificate": "",
  "TargetSqlAuthType": "",
  "credential": "",
  "TrgDatabaseName": "MIGRDEMO",
  "BlobAuthType": "AccountKey",
  "BlobIdentityType": "SystemAssigned",
  "BlobUserAssignedIdentity": ""
}
```

The host has no `tcp:` prefix or port. Blank group/account fields inherit Common;
blank component groups then use the effective `ResourceGroupName`.
The item can override any source/target/DMS group without changing other items.

```powershell
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Restore -ItemId 'VM-MIGRDEMO' -WhatIf

# Live: start the configured migration and monitor it.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Restore -ItemId 'VM-MIGRDEMO'
```

Do not start another restore for a target database already migrating through
the portal or another process. Use `-Activity Status` or `-Activity Monitor`
with the same lifecycle script instead.

Illustrative VM restore preflight excerpt:

```text
Read-only preflight passed for Restore-SQLVM.
What if: Performing the operation "Restore" on target ".../databaseMigrations/MIGRDEMO".
```

For a live run, per-run restore JSON and CSV reports are written beneath the
package's logs directory. Set Common or item `OutputJsonPath`/`ExportCsvPath`
to choose other result paths. Reports update during submission and polling;
in-progress restore reports do not claim terminal success.
A `ReadyForCutover`/`ReadyToCutover` status
is a waiting state, not completed restore. With automatic cutover disabled,
continued polling at that state is expected.

### 3. Restore to SQL Managed Instance

In the same [Invoke-RestoreDMS.config.json](DataMigrationService/config/Invoke-RestoreDMS.config.json),
keep the MI-MIGRDEMO mapping alongside the VM mapping:

```json
{
  "Id": "MI-MIGRDEMO",
  "Activity": "",
  "SrcServerName": "DESKTOP-SGA61QP\\DMF",
  "SrcDatabaseName": "MIGRDEMO",
  "BackupStorageContainerName": "desktop-sga61qp-dmf-migrdemo",
  "TargetType": "SQLMI",
  "TargetName": "ak-personal-sqlmi",
  "TargetResourceGroup": "",
  "TargetSqlHost": "ak-personal-sqlmi.public.3c52841dc1d0.database.windows.net",
  "TargetSqlPort": 3342,
  "TargetTrustServerCertificate": "",
  "TargetSqlAuthType": "",
  "credential": "",
  "TrgDatabaseName": "MIGRDEMO",
  "BlobAuthType": "ManagedIdentity",
  "BlobIdentityType": "SystemAssigned",
  "BlobUserAssignedIdentity": ""
}
```

Use the Azure MI resource name, not its public SQL endpoint. Preserve the
common region/subscription and `Common.AutoCutover=false` unless intentionally changed.

MI defaults to `BlobAuthType="ManagedIdentity"` and
`BlobIdentityType="SystemAssigned"`, with an empty
`BlobUserAssignedIdentity`. Enable the target MI identity and grant it
Storage Blob Data Reader on the backup container/account. This MI flow does
not retrieve storage keys, including during `-WhatIf`; VM remains AccountKey.

The executor TCP check is enabled for both target types. It uses the effective
configured `TargetSqlHost` and `TargetSqlPort`, including the MI public hostname
and port 3342 above. For private MI testing, set its VNet hostname and port 1433.
This check does not change DMS's target resource or establish DMS-side connectivity.
See the [endpoint caveat](Prerequisites/README.md#sql-mi-restore-endpoint-caveat).

```powershell
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Restore -ItemId 'MI-MIGRDEMO' -WhatIf

# Live MI only.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Restore -ItemId 'MI-MIGRDEMO'

# Preview both types together, sharing the global Common.MaxConcurrentRestores.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Restore -WhatIf
```

Illustrative MI restore preflight excerpt:

```text
Read-only preflight passed for Restore-SQLMI.
What if: Performing the operation "Restore" on target ".../databaseMigrations/MIGRDEMO".
```

This confirms preflight only. A live run must subsequently reach terminal
migration success; inspect its reports and the target database separately.

### 4. Inspect status, monitor, and preview cutover

Edit `Common.Activity` in
[Invoke-RestoreDMS.config.json](DataMigrationService/config/Invoke-RestoreDMS.config.json):

```json
{
  "Activity": "Status"
}
```

This applies to all enabled items with a blank item Activity.
An explicit CLI Activity overrides the selected items without editing JSON.
Set `Common.ExportCsvPath` and `Common.OutputJsonPath` for aggregate reports,
or override either path on individual items.

```powershell
# Status for every configured database on both target types.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Status -Foreground

# Status for a single mapping or exact target/database pair.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Status -ItemId 'MI-MIGRDEMO' -Foreground
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -Activity Status -Databases 'MIGRDEMO' -TargetName 'akpersonalsqlvm' -Foreground

# Automatically poll all selected mappings; no interactive menu or implicit cutover.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Monitor

# Preview cutover of all enabled mappings, or add ItemId to select just one.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Cutover -WhatIf
# Live cutover only after source-write freeze, final logs, and readiness approval.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Cutover
```

Cutover requires exactly one ready migration per selected database. Remove
`-WhatIf` only after the approved final-write/log-backup checks. Monitor refresh
is automatic and continues while selected migrations await external cutover.
A cutover-monitoring timeout does not cancel the operation in Azure. Live
commands return background log/report locations; add `-Foreground` to see
the sample execution output directly.

Illustrative Status output, with optional backup columns omitted for width:

```text
TargetName      DatabaseName MigrationStatus
----------      ------------ ---------------
akpersonalsqlvm MIGRDEMO     ReadyForCutover

Read-only preflight passed for Control.

ItemId      TargetName      DatabaseName MigrationStatus
------      ----------      ------------ ---------------
VM-MIGRDEMO akpersonalsqlvm MIGRDEMO     ReadyForCutover
```

The first table is preflight inventory; the second is the execution-phase
status query. The runner labels its combined table with ItemId, and migration
results include LatestFile and RestoredAt. Monitor refreshes this inventory
automatically until the selected migrations reach terminal states.

Illustrative Cutover **with `-WhatIf`**:

```text
TargetName      DatabaseName MigrationStatus
----------      ------------ ---------------
akpersonalsqlvm MIGRDEMO     ReadyForCutover

Read-only preflight passed for Control.
What if: Performing the operation "Cutover" on target ".../databaseMigrations/MIGRDEMO".
```

The preview exits after preflight; it does not print a successful cutover-result
row. A separately approved live cutover, **without `-WhatIf`**, can finish with:

```text
ItemId      Activity TargetName      DatabaseName Status    Error
------      -------- ----------      ------------ ------    -----
VM-MIGRDEMO Cutover  akpersonalsqlvm MIGRDEMO     Succeeded
```

> [!CAUTION]
> A comment such as "validate without performing cutover" does not change a
> command's behavior. Omitting `-WhatIf` submits live cutover. If a cutover result
> says Succeeded but a later query still says ReadyForCutover, do not treat that
> sequence as proof of completion or immediately retry. Verify the migration
> in Azure and the target database's actual state before cleanup or application
> redirection. Preserve the migration record while investigating.

### 5. Remove completed DMS migration records

In [Invoke-RestoreDMS.config.json](DataMigrationService/config/Invoke-RestoreDMS.config.json),
set `Common.Activity="Remove"` or use the explicit CLI override below.
Keep these Common values (individual items may override them):

```json
{
  "IncludeReadyForCutover": false,
  "Force": false
}
```

```powershell
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Remove -WhatIf

# Live: remove eligible completed records in the selected scope without prompts.
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' -Activity Remove
```

Removal is restricted to the selected items' target databases, not every
completed database on a target. This removes migration resources, not target databases, the DMS service, or
backup blobs. It is not rollback. Including ready-for-cutover records is a
separate disruptive opt-in; do not enable it for routine cleanup.

Illustrative no-candidate output from a live discovery run:

```text
Read-only preflight passed for Remove.
WARNING: No eligible migration resource found for 'VM-MIGRDEMO'.
```

A ready migration is excluded by the default completed-only filter. After
completion, a live removal run processes selected eligible records automatically.
With `-Foreground`, it can return:

```text
Database Status  Error
-------- ------  -----
MIGRDEMO Removed
```

`Removed` means tracking-resource removal, not database deletion or validation.
`-WhatIf` exits after preflight without removing records or writing reports.

### 6. Generate and archive server objects for VM and MI

Edit the single
[object config](ServerObjectMigrationService/config/Invoke-MigrateServerObjects-ProvisionLogin-AzSql.config.json).
It selects `Generate` for both targets and both `MIGRDEMO,CDC_Director_PRO`.
Sources, targets, database lists, containers, and login definitions are item-specific.
Common supplies Azure context, enable/activity defaults, storage account and
resource group, Key Vault, source domain suffix, and optional mail defaults.
Nonblank item values override Common; blank/null/omitted values inherit.
Boolean false overrides Common, and CLI `-Activity` overrides both layers.
The VM item uses `SQLLoginsMigrationScope: "Database"` for the two selected
databases; this scripts all eligible source server-level security plus users,
roles, and permissions for those databases. MI retains scope `All`, which also
includes every online system database (`master`, `msdb`, `model`, `tempdb`).
SQL MI's existing manual/commented source SQL-login blocks remain manual.
The shared source in this sample is for testing only;
set each item's source and database list independently for your environment.
The MI domain prefix is derived from the source hostname before `\instance`;
it is no longer a config property. Managed identities use item `Logins` with
`Type: "ManagedIdentity"`; the separate identity-generation properties are removed.

Regenerate snapshots before execution: manifest version 3 rejects SQL generated
under previous security-scope rules or job drop/recreate behavior.

```powershell
$ObjectScript = '.\ServerObjectMigrationService\scripts\Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1'
$ObjectConfig = '.\ServerObjectMigrationService\config\Invoke-MigrateServerObjects-ProvisionLogin-AzSql.config.json'

& $ObjectScript -ConfigPath $ObjectConfig -WhatIf
$ObjectRun = & $ObjectScript -ConfigPath $ObjectConfig -Activity Generate
$ObjectRun | Format-List ProcessId, Status, RunDirectory, ResultsPath
& $ObjectScript -Activity Monitor -RunDirectory $ObjectRun.RunDirectory
```

Generation preserves the existing login/security/operator/alert/job generators,
including hash/SID handling, filtered and `_ALL` outputs, individual job files,
and component logs. SQL is archived in `akpersonalsa`, separately under
`sqlobjects-akpersonalsqlvm` and `sqlobjects-ak-personal-sqlmi`.
Missing containers are created privately only if configured. No target SQL
objects are created by Generate while the item-specific `ProvisionLogins` flag
remains false, as configured. Setting it true also provisions new logins directly.

Illustrative preview:

```text
ItemId     Activity Status          RunId
------     -------- ------          -----
VM-Objects Generate PreflightPassed
MI-Objects Generate PreflightPassed
```

Generated SQL and logs are isolated by invocation and target:

```text
ServerObjectMigrationService\output\Runs\<run-id>\
    results.json
    VM-Objects\SourceObjects\DESKTOP-SGA61QP_DMF\SQL Logins\...
    VM-Objects\SourceObjects\DESKTOP-SGA61QP_DMF\SQL Agents\Jobs\...
    MI-Objects\SourceObjects\DESKTOP-SGA61QP_DMF\SQL Logins MI\...
```

Storage retains one current snapshot per source/item, with separate component
subfolders and no run-ID history folders. Generation overwrites existing SQL and
removes stale files in that prefix. Local run IDs remain for reports only.
Storage account versioning/soft delete can still retain older versions externally;
the script does not change those policies.

### 7. Execute the reviewed current server-object snapshot

```powershell
# Works in a later session too; no generation ID is needed.
& $ObjectScript -ConfigPath $ObjectConfig -Activity Execute -WhatIf

# Live target writes, with no routine confirmation prompts.
& $ObjectScript -ConfigPath $ObjectConfig -Activity Execute
```

Use `-ItemId 'VM-Objects'` or `-ItemId 'MI-Objects'` for one target. Each archive
has a completion manifest, file hashes, and source/target/configuration checks.
Execute always reads the current stored snapshot. Regeneration replaces it;
review again after each generation. `_ALL` files do not execute.
SQL VM execution uses the Windows account; MI uses the signed-in Entra account.
Local Windows users are not Entra principals: review MI mappings and owners.

`GenerateAndExecute` retains combined generation/execution for approved rules,
but archives and verifies SQL before applying it. Imported jobs remain disabled.
See [full commands and safety boundaries](ServerObjectMigrationService/README.md#execute-the-reviewed-current-snapshot).

### 8. Provision multiple SQL and external logins directly

The same config shares `KeyVaultName` in Common, with optional item overrides.
`ProvisionLogins` and `Logins` remain item-only. Both target items retain these
SQL-login entries, alongside their configured external principals:

| Login | Type | Secret in `ak-personal-kv` | Database access |
|-------|------|---------------------------|-----------------|
| `dbmigration` | `SqlLogin` | `sql-dbmigration-pwd` | `db_datareader` |
| `dbtestuser` | `SqlLogin` | `sql-dbtestuser-pwd` | `db_datawriter` |

Confirm both secrets exist, verify each external principal's `Name` and `Type`,
and set `ProvisionLogins: true` on the intended
items before running. Each principal's `AccessType` is an array, for example
`["db_datareader", "EXECUTE"]`; optional `Databases` restricts it to a subset
of that item's selected databases. `EntraGroup` and `ManagedIdentity` are also
supported, with an optional directory `ObjectId` and no password fields.

```powershell
$LoginScript = '.\ServerObjectMigrationService\scripts\Invoke-ProvisionLogins-AzSql.ps1'
& $LoginScript -ConfigPath $ObjectConfig -ItemId 'MI-Objects' -WhatIf

# Direct target provisioning only: no source extraction or storage access.
& $LoginScript -ConfigPath $ObjectConfig -ItemId 'MI-Objects'

# Equivalent orchestrator preview for the VM.
& $ObjectScript -ConfigPath $ObjectConfig -ItemId 'VM-Objects' -Activity ProvisionLogins -WhatIf
```

Both target types are supported with their existing administration authentication.
The flag also enables provisioning alongside normal activities: after snapshot
upload in Generate, and after snapshot verification but before source-SQL
execution in Execute/GenerateAndExecute. False skips provisioning.
Generate with the flag true therefore writes to the target.
Secret values are runtime-only and never archived as generated SQL.
Only source-extracted SQL is uploaded; provisioning reports stay in a separate
local directory.
This provisions new SIDs instead of copying source SIDs/password hashes.
Existing login passwords remain unchanged unless `ForcePasswordReset=true`;
conflicting database-user mappings fail explicitly.
Provisioning grants configured access additively; it does not revoke existing
grants or automatically apply the MI generator's commented source permissions.
The separate permission-export script/activity has been removed.
See [SQL, group, and managed-identity examples](ServerObjectMigrationService/README.md#provision-item-specific-logins-directly).

Server-object execution runs in the background by default, with up to 10 isolated
item processes. Each item completes its own preflight before SQL work; preflight
or runtime failure does not block independently valid items. Use `-Foreground`
to wait in the terminal and `-ThrottleLimit 1` to serialize items.
`-WhatIf` remains read-only and foreground. The per-run JSON is updated atomically
with pending/running item states and final outcomes; there is no cross-target
transaction or automatic rollback.

Reruns skip existing source-login creation and replay scripted security blocks.
Matching jobs, operators, alerts, and Database Mail objects are updated in place.
Job IDs/history and target-only objects are preserved; imported jobs remain
disabled. Direct login provisioning retains its explicit password-reset opt-in.

```powershell
# Execute reviewed current snapshots for both targets in the background.
$ObjectExecution = & $ObjectScript -ConfigPath $ObjectConfig -Activity Execute -ThrottleLimit 10
& $ObjectScript -Activity Monitor -RunDirectory $ObjectExecution.RunDirectory

# Inspect a pinned run, or omit RunDirectory to inspect the latest local run.
$ObjectStatus = & $ObjectScript -Activity Status -RunDirectory $ObjectExecution.RunDirectory
$ObjectStatus.Results | Format-Table ItemId, Mode, Status, ErrorMessage -Wrap
```

## Recommended migration sequence

1. Prepare the execution host, permissions, existing Azure resources, and networks.
2. Review database/object selections and run relevant `-WhatIf` preflights.
3. Create compatible source backups separately; upload them if not already in Blob.
4. Start exactly one DMS migration per target database, through the lifecycle script
   or the portal. Do not launch both VM and MI examples unless both are intended.
5. Generate server-object SQL, review dependencies, and plan its execution timing.
6. Monitor DMS. With AutoCutover disabled, the lifecycle script keeps polling until
   manual cutover or terminal failure. Ready databases do not block later creation
   batches. Follow the returned execution log or request foreground Status.
7. During the approved cutover window, stop source writes and coordinate source
   jobs. Create/upload the final log backup and verify DMS has consumed it.
8. Preview and approve cutover, then execute it. Inspect Azure state before retries.
9. Execute reviewed server objects at the approved stage, verify users/SIDs and
   effective access, reconcile data, test applications, and redirect connections.
10. Review and enable target jobs only after validation. Clean up completed
    migration records when the migration evidence is no longer needed.

Object execution timing depends on dependencies; this sequence is not an
automatic runbook or a guarantee of zero downtime. Retain an independently
tested recovery/rollback plan.

## Evidence and operational safeguards

| Workstream | Main evidence |
|------------|---------------|
| Backup upload | Upload logs and optional per-file JSON results |
| DMS restore | Console progress and per-run JSON/CSV results, updated while polling |
| Status/cutover | Console inventory, optional CSV inventory and JSON results |
| Migration removal | Selected-record results and optional JSON |
| Server objects | Generated SQL, component logs, optional execution JSON |
| Key Vault provisioning | Transcript and provisioning summary |
| Permission extraction | Local extracted SQL file |

Preflight failures and `-WhatIf` do not create operation output files.
Once execution begins, scripts with JSON result support report failures and
still raise an error; do not infer success from file existence alone.

Protect generated SQL, logs, and transcripts: they can contain login hashes,
SIDs, principal names, permissions, and environment details. Do not commit
secrets or unreviewed migration evidence.

Imported Agent jobs remain disabled. Existing target jobs may be dropped and
recreated by generated SQL. Review owners, schedules, operators, transformations,
and `_ALL` versus filtered exports before execution.

Latest-restored file/time fields are whatever DMS exposes. A filename-derived
timestamp is labeled separately and does not prove restore completion or catch-up.
Successful preflight is not a universal no-change/idempotency guarantee for reruns.

## Tests

The active packages use Pester 5.x. After installing a compatible Pester version,
run tests from PowerShell 7:

```powershell
Import-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99 -ErrorAction Stop
Invoke-Pester -Path @(
    '.\Prerequisites\tests'
    '.\DataMigrationService\tests'
    '.\ServerObjectMigrationService\tests'
) -Output Detailed
```

Tests exercise configuration/preflight contracts, mocked migration behavior,
backup selection, object generation, authentication safeguards, and results.
Some existing tests depend on checked-in demo configuration contents; changing
those selections may require updating the corresponding fixtures/assertions.
Test results are not proof of live migration readiness or business acceptance.

## Component documentation

* [Prerequisites, module setup, permissions, and Azure sign-in](Prerequisites/README.md)
* [Backup staging, online DMS restore, status, cutover, and cleanup](DataMigrationService/README.md)
* [Server-object selection, identity mapping, SQL execution, and safeguards](ServerObjectMigrationService/README.md)
