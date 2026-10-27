---
title: Server Object Migration Service
description: Capture complete source SQL Server snapshots in private Blob Storage and replay Server or All objects on Azure SQL VM and SQL Managed Instance.
---

## One entry point and one configuration

Use [Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1](./scripts/Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1)
with [Invoke-MigrateServerObjects-ProvisionLogin-AzSql.config.json](./config/Invoke-MigrateServerObjects-ProvisionLogin-AzSql.config.json).
The VM, MI, and login-provisioning worker scripts remain directly under
[scripts](./scripts). Only shared helper functions live under [Common](./scripts/Common).
Their separate operational configs have been removed; the consolidated entry point
supplies worker configuration. Keep both folders when copying the tool.

Generate captures all supported user/application source objects, regardless of execution flags,
database selection, job regex, or provisioning settings. It never connects to
the target, resolves on-premises AD identities, or provisions configured logins.
SQLMI Generate additionally performs a **read-only Entra resolution/report pass**
after raw extraction; SQLVM Generate does not query Entra. This deliberately extends
the earlier source-only/no-directory-lookup generation contract without changing
source identity metadata or connecting to target SQL.
Use an explicit `-Activity Generate` override when taking a snapshot: the
operational configuration currently selects `Generate`.

| Item ID      | Target                        | SQL endpoint                                                        | Derived Blob container    |
|--------------|-------------------------------|---------------------------------------------------------------------|---------------------------|
| `MI-Objects` | SQLMI `free-sql-mi-6265221`     | `free-sql-mi-6265221.9c5d642b3e14.database.windows.net:1433`            | `sqlservermigvm-sqlobjects` |

Only `MI-Objects` is enabled. It extracts from the default SQL instance on
`sqlservermigvm`; `MIGRDEMO` is the current execution database selection,
not an extraction filter. Snapshots use `sqlmimigrationbackup` in
`SQL-Migration-Assistant`; private-container creation is enabled if missing.
The Azure tenant is `396b3622-063d-4ef2-9c28-383d840705b4` and the subscription
is `bdac0d16-ad4b-4953-83f3-91b12451a425`. The old `VM-Objects` item is retained
but disabled; update its settings before enabling it.
Database Mail is disabled, so SMTP settings are not needed. Additional login
provisioning is enabled for `DBUsrLogin` with `db_datareader` on `MIGRDEMO`,
using secret `sql-DBUsrLogin-pwd` in Key Vault `sqlmig-kv`. Existing passwords
are not reset (`ForcePasswordReset: false`). The Entra user `DBAGroup`
(`01fe121e-dcad-4dc4-8223-678a9b61bd61`) is also configured with
`db_datareader` and `db_datawriter` on `MIGRDEMO`; no Key Vault secret is
required for this external login. The default `Generate` activity
does not provision logins; use `ProvisionLogins` explicitly or provision during
`Execute`/`GenerateAndExecute`. Existing source login migration remains enabled
for replay.
The MI endpoint uses port 1433, so the migration host needs network access to
the MI virtual network through a connected VNet, peering, or VPN.
The tool does not create storage accounts or change their network/RBAC settings.

Containers normally have no platform suffix, for example
`desktop-sga61qp-dmf-sqlobjects`. Azure does not allow underscores in container
names. If the same source/account is configured for VM and MI testing, suffixes
`-sqlvm` and `-sqlmi` keep their platform snapshots separate. Derivation considers
the entire config before ItemId selection, and never uses target names or run IDs.
`StorageContainer` is derived; remove legacy explicit values. Old target-named
containers remain untouched.
Containers using the former `sqlobjects-` prefix are also left untouched.
Generate new snapshots under the new names before running Execute.

## Reference-script coverage

The original platform generators remain available for reference against the
[archived reference](../Archive/manual-migration/SqlServerObjects/SQLServerObjects-Src-to-Trgt-Migration.ps1).
The public schema-2 workflow now uses source snapshot helpers rather than the
legacy filtered platform generation/execution path.

| Reference functionality | Consolidated behavior |
|-------------------------|-----------------------|
| SQL logins, password hashes/SIDs, roles and permissions | Captured without directory lookups; target translation happens during replay |
| Database users, role memberships, database/schema/object/column permissions | Captured for all supported online databases, preserving DENY and GRANT OPTION |
| Login/job scopes | Independent `Server` and `All` execution scopes |
| Operators and alerts | Source names/settings and alert notifications; rerunnable add/update |
| Agent jobs | Capture enabled and disabled; replay source-enabled matching jobs, always disabled on target |
| Snapshot files | Combined `_Server.sql` and `_All.sql`; no per-job folders |
| Generate, generate-and-execute, execute-only | `Generate`, `GenerateAndExecute`, `Execute` |
| SQL batches | SQLCMD GO handling, explicit errors; no automatic retries of partially applied object SQL |
| Logs | Local item `migration.log`, persistent run status/results, extraction/provisioning logs |

Additional components remain available: Database Mail and direct provisioning
of item-specific SQL and external logins, including managed identities.
Provisioning supports both target types and never uploads provisioning SQL.

### SQL MI project-reference coverage

The [archived SQL MI implementation](../Archive/profisee/SQLServerObjectMigration/SQLServerObjects-Src-to-Trgt-Migration-SQLMI.ps1)
is also covered. The DEV, QA, and PROD CSVs use the same operational fields;
use separate copies of the consolidated config for environments rather than
restoring separate script entry points.

| MI reference functionality | Consolidated behavior |
|----------------------------|-----------------------|
| Windows identities | Captured without AD; replay requires unambiguous Azure identity resolution |
| Mapping metadata | Embedded in SQL snapshot comments and reviewed before replay |
| Server/database security | Target translation from the captured security blocks |
| Source SQL logins | Source SID/hash migration where supported, rather than commented manual statements |
| New-login database access | Configure each item's `Logins` and their explicit permissions; the separate permission-extraction activity has been removed |
| MI Agent jobs | Explicit owner resolution; unsupported subsystems/proxies fail instead of being silently removed |
| Database Mail | Source settings retained; only SMTP server/port overridden during execution |

Review source security and target identity mappings before execution.
Key Vault provisioning creates a new login/SID where absent; it does not
automatically repair users restored with a different SID.

Deliberate safeguards differ from the old archived script: no automatic module
installation, no hardcoded organizational DNS suffix, no successful skip for a
missing executable file, explicit overall failure after component errors, and
disabled imported jobs. ScriptDom classification checks contexts and multipart
references. Dynamic SQL, unresolved execution, non-TSQL steps and external
dependencies are conservatively excluded from Server replay, with reasons in
snapshot metadata. All replay still requires review of those dependencies.

Linked servers, credentials, proxies, certificates, SSIS, TDE keys, SMTP
passwords, and external dependencies are not a complete instance migration.
MI does not silently remove unsupported job-step proxy references; review subsystem support,
owners, schedules, notifications, and those transformations.

## Common defaults and item overrides

The checked-in public config uses numeric `schemaVersion: 2`, `Common`, and
`Items`. Common supplies enable/activity defaults, Azure context, source domain
suffix, mail settings, storage account/resource group/container-creation policy,
and Key Vault. Each item supplies its independent source, database list, target,
container, component flags, and login definitions. `Id` must be unique;
`Enabled=false` excludes an item. Unknown properties fail validation.
Old schema-version-1 configs are private worker contracts, not public inputs.

Nonblank item properties override Common; omitted, null, empty, and whitespace-only
strings inherit. Boolean `false` is an explicit override, not a blank. For example,
an item with `Enabled: true` overrides `Common.Enabled: false`; omit or blank the
item value to inherit the Common switch. CLI `-Activity` overrides both layers.
Common remains optional when each item supplies all required settings.

Example item settings, not a replacement configuration:

```json
{
  "schemaVersion": 2,
  "Common": {
    "Enabled": true,
    "Activity": "Generate",
    "TenantId": "b7d7daca-8689-49f9-8a9b-d20adf81c78b",
    "SubscriptionId": "cd7743ef-8ddc-4254-b715-2c79c8ab4126",
    "SourceDomainSuffix": "",
    "SQLDBMailMigrationFlag": "No",
    "JobOwnerUpnSuffix": "",
    "SmtpServer": "",
    "SmtpPort": "",
    "StorageAccountName": "akpersonalsa",
    "StorageResourceGroup": "rg-ak-personal",
    "CreateContainerIfMissing": true,
    "KeyVaultName": "ak-personal-kv"
  },
  "Items": [
    {
      "Id": "VM-Objects",
      "Enabled": true,
      "SourceServerName": "DESKTOP-SGA61QP\\DMF",
      "SourceListofDatabases": "MIGRDEMO,CDC_Director_PRO",
      "SQLLoginsMigrationFlag": "Yes",
      "SQLLoginsMigrationScope": "Server",
      "SQLAgentJobsMigrationScope": "Server",
      "TargetType": "SQLVM",
      "TargetName": "akpersonalsqlvm",
      "TargetSqlHost": "akpersonalsqlvm.centralus.cloudapp.azure.com",
      "TargetSqlPort": 1433,
      "Activity": "",
      "CreateContainerIfMissing": false,
      "ProvisionLogins": false,
      "Logins": []
    }
  ]
}
```

Keep hostnames separate from numeric ports; do not include `tcp:` or `,port`
in `TargetSqlHost`. Database names are a comma-separated string, or `All`
for object migration. Key Vault provisioning requires explicit database names.
Migration component flags remain `"Yes"`/`"No"`; storage/reset/enable controls
and `ProvisionLogins` are Booleans. Only `Logins` and `ProvisionLogins` must remain
item-specific. `KeyVaultName` can be shared in Common and overridden per item.

### Security migration scope

With `SQLLoginsMigrationFlag: "Yes"`, the normal executable security export uses:

| Scope | Server security | Database security |
|-------|-----------------|-------------------|
| `All` | All eligible source logins, server-role memberships, and server permissions | Selected user databases plus every online system database: `master`, `msdb`, `model`, `tempdb` |
| `Server` | Server-safe logins, roles and permissions | No user-database dependencies |

`SourceListofDatabases: "All"` expands to all user databases, while the scope
still decides whether to include database-dependent security. `Database`/`DB`
are no longer accepted scopes. Generation always writes the complete All
snapshot and a Server-safe subset, even when migration flags are No.

`Activity: "Generate"` extracts and stores SQL; `Execute` applies its normal
executable files; `GenerateAndExecute` performs both. No scope bypasses the activity.
`SQLLoginsMigrationFlag: "No"` skips target security replay, but does not disable
direct `ProvisionLogins`. `_All` is executable after database restoration.

> [!IMPORTANT]
> Regenerate the current snapshot before executing with the updated rules.
> Snapshot manifest version 4 rejects versions 1, 2 and 3 rather than replaying SQL
> generated with older security scopes or job drop/recreate behavior.
> Review system database grants carefully; `tempdb` changes are not persistent
> across a SQL Server restart.

| Configuration | Purpose |
|---------------|---------|
| `Activity` | `Generate`, `Execute`, `GenerateAndExecute`, or `ProvisionLogins`; Execute reads the current stored snapshot |
| `SourceServerName`, `SourceDomainSuffix`, `SourceListofDatabases` | Source instance, optional domain suffix, database scope |
| `SourceTrustServerCertificate` | Boolean, default `false`; development-only source certificate-validation override, configurable in Common or per item |
| `TargetTrustServerCertificate` | Boolean, default `false`; explicit development-only target TLS validation override for replay, provisioning, and their preflights; encryption remains required |
| `TargetType`, `TargetName`, `TargetSqlHost`, `TargetSqlPort` | Platform, target identity, endpoint |
| `TargetSqlAuthType` | `Auto` (default: Windows for VM, Entra for MI), `Windows` (VM only), `Entra`, or `SqlLogin` |
| `credential` | Named administrative SQL credential in `password.local.json` beside the selected config; takes precedence over interactive/file/environment modes |
| `SqlCredentialMode`, `SqlUserName` | `Interactive` (default) prompts in the launcher; `Configured` avoids prompting; optional username for the prompt or environment mode |
| `SqlCredentialPath`, `SqlPasswordEnvironmentVariable` | Alternative encrypted PSCredential file, relative to config, or password environment variable paired with `SqlUserName` |
| `TenantId`, `SubscriptionId` | Signed-in Azure context scope |
| `SQLLoginsMigrationFlag`, `SQLLoginsMigrationScope` | Security scripting and scope |
| `SQLOperatorsMigrationFlag`, `SQLAlertsMigrationFlag` | Agent operators and alerts |
| `SQLAgentJobsMigrationFlag`, `SQLAgentJobsMigrationScope`, `SQLAgentJobFilterCriteria` | Execute-only job enable, independent Server/All scope and name regex |
| `JobOwnerUpnSuffix` | Explicit MI domain-user UPN suffix, shared by security and job-owner resolution; no default is invented |
| `EntraIdentityMappings` | Optional object keyed by exact source Windows identity; values are reviewed Entra user UPNs or exact group display names |
| `SQLDBMailMigrationFlag`, `SmtpServer`, `SmtpPort` | Optional mail scripting and relay |
| `StorageAccountName`, `StorageResourceGroup` | Account/resource group; source-derived container |
| `CreateContainerIfMissing` | Allow creation of a private container, never an account |
| Item `ProvisionLogins` | Target provisioning during Execute/GenerateAndExecute or explicit ProvisionLogins; never Generate |
| `KeyVaultName` | Common or item vault for SQL-login secrets; not needed for external-only lists |
| Item `Logins` | Array of SQL logins, Entra users/groups, and managed identities, with per-principal access |
| Login `SecretName`, `ForcePasswordReset` | SQL-only secret reference and explicit password-reset opt-in |
| Login `AccessType`, `Databases`, `ObjectId` | Per-login grants, optional database subset, and optional external directory object ID |

`SourceDomainSuffix` is appended only to a short source hostname before an
instance suffix; FQDNs are not extended again. It is a SQL connection suffix,
not an AD domain or an identity-mapping prefix. `DomainPrefix` is not a supported
configuration property. SQLVM retains domain users/groups and Windows authentication
as-is on the domain-joined target; no Entra translation applies. SQLMI resolves
captured Windows identities through Entra using a reviewed `EntraIdentityMappings`
entry, an existing UPN, or an explicitly supplied `JobOwnerUpnSuffix` for domain users.
Groups require a unique exact full source-name match unless explicitly mapped;
the Windows domain is never stripped to guess a group. Local Windows identities
require an explicit mapping, even when a suffix is configured. For example,
`"EntraIdentityMappings": { "SOURCE\\localuser": "reviewed@contoso.com",
"CONTOSO\\AppGroup": "Application Readers" }` documents reviewed mappings; it
does not create those identities. Every mapping is verified in the configured
tenant/subscription context. New source
logins default to `master` for safe pre-restore connectivity; original defaults
are retained in snapshot metadata for review rather than applied automatically.

### System-object filtering and regeneration

The shared source-capture helpers apply the same filtering before writing either
Server or All snapshots, including GenerateAndExecute:

* Exclude `sa` by SID `0x01` or principal ID (including renamed `sa`), reserved
  `##` internal/policy identities, `NT SERVICE`, `NT AUTHORITY`, `BUILTIN`, and
  certificate/asymmetric-key principals.
* Keep application SQL logins, domain users/groups, supported external principals,
  and custom roles. Words such as `admin`, `service`, or `system` in an application
  name do not cause exclusion.
* Exclude built-in database users, aliases mapped to excluded logins, fixed/public
  role definitions and permissions, and dependent ownership/securable references.
  Known non-fixed product roles are recognized only in `msdb` (Agent, Mail,
  SSIS/DTS, data collector, policy, registered-server and target-server roles).
  Same-named custom roles outside `msdb` remain eligible.
* Retain user/custom-role membership in system roles. Keep user grants issued by
  built-ins but emit them under the executing sysadmin instead of referencing a
  source-only grantor; the original grantor remains in metadata. Custom-role
  ownership by built-ins is not replayed; normal target creation ownership applies.
* Exclude jobs marked `IsSystemObject` by SMO and the exact reserved product jobs
  `syspolicy_purge_history` and `SSIS Server Maintenance Job`. Ownership by `sa`,
  disabled state, category, or a generic name substring is not a system-job test.
  Unknown/custom platform jobs remain eligible rather than risking user-job loss;
  review them explicitly. Disabled user jobs remain in generated output, while
  existing execution filters and disabled-on-target replay safeguards still apply.

Generation never edits existing local output, archives, or stored snapshots in
place. Rerun Generate into a new run directory to publish newly filtered snapshots;
previous Blob snapshots remain unchanged until regeneration. Older snapshots retain
their original contents and must be regenerated to receive these filtering rules
and authoritative job-owner user/group and local-account metadata.

### Missing Entra identity reports

SQLMI writes `<run>/<item>/MissingEntraIdentities.csv` beside `SourceObjects`
after generating all seven raw SQL files, irrespective of execution flags.
Generate publishes those raw captures even if mappings are unresolved, but marks
the identity-report component and item FAILED so the issue cannot be mistaken for
successful migration. No identities are provisioned by this pass.

Before replay, eligible security/job dependencies are resolved again against the
current directory, writing `MissingEntraIdentities.Replay.csv` in the same item
directory. GenerateAndExecute keeps both reports. Missing dependencies fail the
affected component before its target validation/writes; independent components
continue. Existing object-level SQL failures still produce FAILED results.
WhatIf/preview validates in memory without writing CSVs.

Each UTF-8 CSV has these columns, with one row per unresolved source identity/type:
`SourceIdentity`, `PrincipalType` (`U` user, `G` group, or `UnknownWindows` for
legacy job metadata), `Components`, `DependencyContexts`, `AttemptedMapping`,
`FailureReason`, and `ErrorMessage`. Repeated database, permission and job
references are deduplicated while retaining semicolon-separated dependency
contexts. All missing identities are collected, not just the first failure.
`NotFound`, `Ambiguous`, `DirectoryAccessError` (including authorization, context
and network failures), `ExplicitMappingRequired`, and `InvalidDirectoryResponse`
are distinct remediation categories. Directory outages are not reported as missing
users. A successful pass produces a header-only CSV.

Report paths appear in the identity component's `OutputFile`, the item's
`IdentityReports`, and `migration.log`, including failures. Reports contain no
passwords, hashes or tokens, but do contain identity names and dependency context;
handle them as access-control information. They remain local and are not uploaded
as managed Blob snapshot files. Give the infrastructure team the CSV, remediate
directory access/identities or explicit mappings, and rerun Generate/replay.

The old `ManagedIdentityName`, `ManagedIdentityRoles`, and
`ManagedIdentityPermissions` properties and their generated SQL component have
been removed. On SQLMI, configure managed identities only under item `Logins`, using
`Type: "ManagedIdentity"` and per-principal `AccessType` and optional `Databases`.
Set that item's `ProvisionLogins: true` to apply them directly without storage.
SQLVM does not support these external principal types for provisioning.
Target external-authentication and directory lookup permissions remain prerequisites on SQLMI.

Mail snapshots preserve source sender/display/reply-to values and SMTP server/port.
Execute overrides only the SMTP server and port through parsed procedure parameters.
SMTP passwords cannot be exported; prepare relay credentials separately.
MI Windows Integrated SMTP authentication fails explicitly rather than omitting accounts.

## Authentication and prerequisites

Use PowerShell 7 on a Windows administration host with source Windows SQL
access. RSAT/ActiveDirectory is not required for this snapshot workflow.
Install/check local prerequisites:

```powershell
& '.\Prerequisites\Install-MigrationPrerequisites.ps1' -Workload ServerObjects -Install

# Additional modules for direct login provisioning.
& '.\Prerequisites\Install-MigrationPrerequisites.ps1' -Workload LoginProvisioning -Install

Connect-AzAccount -AccountId 'kadda@microsoft.com' `
    -Tenant 'b7d7daca-8689-49f9-8a9b-d20adf81c78b' `
    -Subscription 'cd7743ef-8ddc-4254-b715-2c79c8ab4126' `
    -Scope Process -ErrorAction Stop
```

| Connection | Authentication |
|------------|----------------|
| Source SQL extraction | Executing Windows account, not the Azure login |
| SQL VM execution/provisioning | Configured Windows integrated, Entra token, or SQL login |
| SQL MI execution/provisioning | Configured Entra token or SQL login |
| Blob archives | Selected Az identity, no storage account keys or SAS |
| Key Vault | Selected Az identity with secret-read access |

Signing in as `kadda@microsoft.com` does not grant the executing Windows
principal SQL access to the VM. A workgroup/public-IP VM might not support
that Windows authentication path. Configure `TargetSqlAuthType: "SqlLogin"` to
use the same administrative SQL login that works in SSMS. The server-object
config is independent of the DMS config, but uses the existing
[DMS credential provider](../DataMigrationService/scripts/Common/Target.Helpers.ps1)
for consistent credential formats and precedence. Keep both services in this
repository layout.
Key Vault passwords provision the configured SQL logins; they do not authenticate the
migration connection.

### Configure administrative SQL login authentication

The enabled MI item selects SQL login authentication for replay:

```json
{
  "TargetSqlAuthType": "SqlLogin",
  "SqlCredentialMode": "Configured",
  "credential": "sql_target"
}
```

Before replay, create `password.local.json` beside your selected config
with the same format as DMS:

```json
{
  "credentials": {
    "sql_target": {
      "username": "<MI administrative SQL login>",
      "password": "<MI SQL password>"
    }
  }
}
```

**This named JSON format stores passwords in plaintext at rest.** Restrict file
access to the migration operator. The repository ignores `password.local.json`,
but Git ignore is not encryption. Never commit, upload, or share this file.
Missing/invalid named entries fail without prompting or falling back.

For interactive SQL authentication, clear `credential`, set `TargetSqlAuthType`
to `SqlLogin`, and set `SqlCredentialMode` to `Interactive`. This prompts for a
SQL username/password, not an Entra browser sign-in. The launcher resolves
credentials before starting background or concurrent workers. Generate-only
runs and Status/Monitor do not resolve target credentials. Noninteractive runs
must supply configured credentials; workers never prompt.

For encrypted local storage, export a PSCredential on the Windows migration
computer as the account that runs migration:

```powershell
$Credential = Get-Credential -Message 'Target administrative SQL login'
$CredentialPath = Join-Path $env:USERPROFILE 'sql-vm-admin.clixml'
$Credential | Export-Clixml -LiteralPath $CredentialPath
```

Clear `credential`, select `SqlCredentialMode: "Configured"`, and configure
`SqlCredentialPath` with the absolute path in `$CredentialPath` on the VM item.
Use a separate file for MI. Relative paths resolve beside the selected config.
Windows protects this file with DPAPI for the exporting user/computer; keep
it outside source control. Alternatively, supply `-SqlCredentials` with
a hashtable keyed by item ID, such as `@{ 'VM-Objects' = $Credential }`.
Explicit overrides take precedence over all configured sources.

The same credential is used for target validation, replay, and optional
provisioning. It is kept separate from item configuration, generated SQL, Blob
snapshots, reports, and process command-line text. Background handoff uses
Windows-encrypted PSCredentials in a temporary, access-restricted CLIXML request,
deleted by the worker. SQL login mode does not request an Entra SQL token.
Azure sign-in is still required for Blob, Key Vault, and external-principal
lookups. Changing connection authentication does not fix missing Windows-to-Entra
identity mappings on MI.

`TargetTrustServerCertificate` remains independent of authentication. Keep it
`false` for trusted SQL MI certificates; the configured VM override remains
development-only and does not disable encryption.

Prepare externally:

* SQL Server 2016+ source sysadmin, hash access and access to every ONLINE source database
* Existing target databases before applying database users/permissions
* Target `sysadmin` for source snapshot replay; standalone configured-login provisioning checks its narrower permissions
* SQL VM/MI DNS, network rules, listening ports, and host firewall access
* Target Entra administrator/identity/Graph permissions when required for external principals
* Storage account read access and Blob data access for the executing Azure identity
* Storage Blob Data Contributor at account scope for generation's container replacement and Blob list/write/delete operations
* Private containers and reachable storage endpoints
* Secret-read access, such as Key Vault Secrets User, when provisioning SQL logins
* Directory-read permissions for `Az.Resources` to resolve configured external identities
* Trusted SQL certificates for the TLS-protected Key Vault provisioning connection

The BlobUpload preflight lists containers and reads the storage account resource.
An Azure resource Reader role alone does not grant Blob data access. For
read-only replay, grant the corresponding account/container-list and Blob read
permissions. The account's existing firewall/private-endpoint restrictions
still apply. No resource deployment, role assignment, identity creation, or
network changes are automated.

Follow the [external access checklist](../Prerequisites/README.md#access-and-infrastructure-managed-outside-scripts),
[SQL VM Entra setup](../Prerequisites/README.md#sql-vm-entra-authentication-prerequisites),
and [SQL MI identity checklist](../Prerequisites/README.md#sql-mi-identity-and-connection-prerequisites).
Directory Readers on a target identity enables lookups, not personal SQL access
or Blob RBAC.

## Generate and archive first

From the repository root:

```powershell
$Script = '.\ServerObjectMigrationService\scripts\Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1'
$Config = '.\ServerObjectMigrationService\config\Invoke-MigrateServerObjects-ProvisionLogin-AzSql.config.json'

# Read-only checks for enabled targets; no local output or new containers.
& $Script -ConfigPath $Config -WhatIf

# Generate and upload source SQL without target SQL writes, even with provisioning enabled.
$Run = & $Script -ConfigPath $Config -Activity Generate
$Run | Format-List ProcessId, Status, RunDirectory, ResultsPath
& $Script -Activity Monitor -RunDirectory $Run.RunDirectory

# Select one target instead.
& $Script -ConfigPath $Config -ItemId 'MI-Objects' -Activity Generate
```

Illustrative preview output:

```text
ItemId     Activity Status          RunId
------     -------- ------          -----
MI-Objects Generate PreflightPassed
```

Execution runs in a persistent background process by default, with up to 10
independent item processes. Use `-Foreground` to wait in the current terminal,
or `-ThrottleLimit 1` for serial item execution. Foreground execution still runs
items concurrently unless you reduce the throttle. `-WhatIf` stays foreground
and performs read-only checks sequentially without starting background processes.

Live output includes a local run directory and status/log paths. Completed
item results include component logs and the private archive manifest URL.
The run ID is for local reporting only, not storage selection.
Both targets in one invocation share the top-level run ID but have separate
item paths and containers.

```text
ServerObjectMigrationService\output\Runs\<run-id>\
    results.json
    run.json
    stdout.log
    stderr.log
    VM-Objects\SourceObjects\SQLLogins\SQLLogins_All.sql
    VM-Objects\SourceObjects\SQLAgentJobs\SQLAgentJobs_Server.sql
    VM-Objects\migration.log
    VM-Objects\Provisioning\reports\...
    MI-Objects\SourceObjects\SQLLogins\SQLLogins_All.sql
```

Blob names use forward slashes:

```text
<source-container>/
    SQLOperators/SQLOperators_Server.sql
    SQLAlerts/SQLAlerts_Server.sql
    SQLAgentJobs/SQLAgentJobs_All.sql
    SQLAgentJobs/SQLAgentJobs_Server.sql
    SQLLogins/SQLLogins_All.sql
    SQLLogins/SQLLogins_Server.sql
    SQLDBMail/SQLDBMail_Server.sql
    manifest.json
```

Only these seven SQL files and the integrity manifest are uploaded. Empty
components still produce valid no-op files. SQL comments carry length-delimited
object metadata so execution can filter after the source is decommissioned.
Local configs,
credentials, logs, and transcripts are not uploaded. Logs and summaries remain
under the protected local run directory.

Generation finishes local extraction first, then deletes and recreates only the
derived managed container. Nonempty containers require a matching version-4
ownership manifest and must contain only managed snapshot files; unrelated
contents are never deleted. Incomplete uploads without a manifest require manual
review/recovery before retry. Azure deletion propagation is retried for up to two
minutes only for `ContainerBeingDeleted`. The new manifest is uploaded last and
records file sizes, SHA256 hashes, source, platform and Azure context.
Partial uploads without a manifest cannot execute. Failed uploads fail that
item and block its dependent execution. Do not generate concurrently for the
same source/container across processes or computers; overlapping writers can invalidate replay.
Duplicate destinations within one invocation are rejected.
Retention, backups, versioning, legal
holds, and storage-enforced immutability are account policies, not configured
by this script. Existing account versioning or soft delete can retain previous
versions despite overwriting; immutability policies can reject replacement.
Authorized storage writers can still alter/delete artifacts;
hashes are integrity checks, not signatures.

> [!CAUTION]
> SQL exports contain password hashes, SIDs, and privilege details. Keep both
> containers private, restrict Blob RBAC and local ACLs, and do not publish
> generated SQL. The tool refuses an already-public archive container.

## Execute the reviewed current snapshot

Review `_Server` and `_All` SQL, and validate MI mappings and job
dependencies. If SQL needs correction, update the generation configuration or
source metadata and regenerate the current snapshot. Editing a local generated file does
not change the archived replay input. Do not edit archived files in place.

```powershell
# In the same or a later session; no generation ID is required.
& $Script -ConfigPath $Config -Activity Execute -WhatIf

# Writes to both configured targets. There are no confirmation prompts.
$Execution = & $Script -ConfigPath $Config -Activity Execute
& $Script -Activity Monitor -RunDirectory $Execution.RunDirectory
```

Execute always reads the current manifest and component files from each
source-derived container, with no prefix or run-ID folder. There is no snapshot-run
selector. Regeneration replaces what a later Execute will read, so review again
after regenerating.

Replay verifies all seven files before any target writes. It never contacts the
source or on-premises AD. Flags, scopes, database selection, job regex, relay and
target endpoint can change without regeneration. Source/platform/Azure identity
must still match the manifest.

Before cutover, set `SQLLoginsMigrationScope: "Server"` and
`SQLAgentJobsMigrationScope: "Server"`; selected user databases need not exist.
After restore, set each desired scope to `"All"` and select restored databases
with `SourceListofDatabases`; they must be ONLINE. Reruns update supported objects
without dropping existing jobs, and skip existing logins without changing SIDs.
Jobs disabled on source are never imported, and imported jobs remain disabled.
Use the orchestrator for replay, not direct execution of the source-faithful SQL
files: filtering, owner translation and disabled-job enforcement happen there.
The legacy `DBA-ENABLED` job filter remains supported for source-enabled job names
starting with `DBA`; other filter values are regular expressions.
Alerts with a user-database/job dependency are deferred while the job scope is
Server, even though alerts share one file. Normal server-only alerts/operators
need no user database.

`GenerateAndExecute` retains the old combined mode but archives and verifies
the uploaded SQL before execution. Use only after rehearsing and approving the
generation rules; it is not the default and does not pause for review.

```powershell
& $Script -ConfigPath $Config -ItemId 'MI-Objects' -Activity GenerateAndExecute
```

Imported jobs remain disabled. The tool does not stop source jobs, freeze
application writes, cut over DMS, redirect applications, or enable target jobs.

### Rerun behavior

| Object | Existing target behavior |
|--------|--------------------------|
| Source login | Skip creation; do not replace its password or SID; replay scripted security blocks |
| Database users and roles | Existing creation/membership guards remain; scripted permissions are additive, not a full security reconciliation |
| Operator or alert | Update the matching named object in place |
| Agent job | Update the matching named job in place, preserving job ID and history; update matching step IDs and attached schedule names |
| Shared job schedule | Detach only this job and create its own updated schedule; leave other jobs' shared schedule unchanged |
| Database Mail account | Update matching account settings using the configured SMTP relay |
| Mail profile and associations | Update profile description, account sequence, and principal default setting |

Missing objects are created. Target-only objects, steps, schedules, and
associations are not deleted. All imported jobs are disabled, including updated
jobs. Duplicate attached schedule names fail explicitly rather than choosing an
ambiguous match. SMTP passwords are not extracted; required authentication
secrets still need the existing manual setup. Direct provisioning retains its
explicit `ForcePasswordReset` opt-in and identity/SID compatibility checks.

Regenerate and review the current snapshot once before using Execute with these
rules. Older snapshots are rejected; they are not rewritten during replay.

## Provision item-specific logins directly

Use [Invoke-ProvisionLogins-AzSql.ps1](./scripts/Invoke-ProvisionLogins-AzSql.ps1)
for new logins, rather than source-object migration. It uses the selected item's
target type, host, and port. Confirm each configured secret and principal before
enabling provisioning.

| Target | Allowed login principal types |
|--------|-------------------------------|
| SQLVM | `SqlLogin`, `WindowsAD` (domain-qualified Windows AD user) |
| SQLMI | `SqlLogin`, `EntraUser`, `EntraGroup`, `ManagedIdentity` |

These are login principal types, not connection authentication settings.
`TargetSqlAuthType` still selects the administrator's connection authentication.
Entra connection authentication does not enable provisioning Entra principals on SQLVM.

For SQLVM SQL logins, enable **SQL Server and Windows Authentication mode**
(mixed mode) alongside domain authentication. Restart SQL Server after changing
authentication mode as required for the change to take effect. This tool does
not change the server authentication mode.

For SQLMI SQL logins, obtain approved exceptions where Entra-only authentication
or organizational policies apply. Do not automatically disable Entra-only
authentication or organizational controls to make provisioning succeed.

For `WindowsAD`, set `TargetWindowsDomain` on the item to the independently
verified expected NetBIOS domain for the target SQL Server. For example, use
`TargetWindowsDomain: "CONTOSO"` with `Name: "CONTOSO\appuser"` (JSON:
`"CONTOSO\\appuser"`). These are placeholders, not operational accounts.
Use `DOMAIN\user`
in `Name`, without `SecretName`, `ForcePasswordReset`, or `ObjectId`. UPNs,
unqualified names, local accounts, other domains and Windows groups are not
supported. Do not infer this setting from `SourceDomainSuffix`, a hostname,
or the requested login name. You must verify the correct target domain before
configuring a Windows AD account. The operational SQLVM configuration contains
only `SqlLogin` and does not need `TargetWindowsDomain`.

Preflight compares SQL Server's `DEFAULT_DOMAIN()` with `TargetWindowsDomain`
and the account prefix, case-insensitively. A missing, blank or mismatching
reported default Windows domain stops provisioning, even if a trusted
other-domain account could resolve. The worker repeats this comparison before
login writes and inside the login-creation transaction.
Preflight also resolves the account/SID on the target using `xp_logininfo` and
`SUSER_SID`; resolution/permission failures stop provisioning. Since
`xp_logininfo` can return no rows for an account without SQL access, the worker
also verifies Windows user type and SID inside the login-creation transaction.
Groups and conflicting principals fail and roll back before database grants.
These checks compare the target SQL Server's default Windows domain; they do
not independently verify the machine's domain membership.

Set `ProvisionLogins: true` on only the intended items. Each login has independent
access; this illustrative SQLMI item fragment adds a group and managed identity:

```json
{
  "TargetType": "SQLMI",
  "KeyVaultName": "ak-personal-kv",
  "ProvisionLogins": true,
  "Logins": [
    {
      "Name": "dbmigration",
      "Type": "SqlLogin",
      "SecretName": "sql-dbmigration-pwd",
      "AccessType": ["db_datareader", "EXECUTE"],
      "ForcePasswordReset": false
    },
    {
      "Name": "dbtestuser",
      "Type": "SqlLogin",
      "SecretName": "sql-dbtestuser-pwd",
      "AccessType": ["db_datawriter"],
      "ForcePasswordReset": false,
      "Databases": ["MIGRDEMO"]
    },
    {
      "Name": "kadda@microsoft.com",
      "Type": "EntraUser",
      "AccessType": ["db_datareader"]
    },
    {
      "Name": "example-readers-group",
      "Type": "EntraGroup",
      "AccessType": ["db_datareader"]
    },
    {
      "Name": "example-app-managed-identity",
      "Type": "ManagedIdentity",
      "AccessType": ["db_datareader", "EXECUTE"]
    }
  ]
}
```

Replace illustrative group/identity names with existing directory principals
before using them. Both system-assigned and user-assigned managed identities use
`Type: "ManagedIdentity"` with the identity's service-principal name and optional
directory `ObjectId` (principal ID), not its application/client ID. There is no
separate managed-identity subtype field. These identities are supported only on
SQLMI. External identities use no password or Key Vault secret.
Optional `ObjectId` is the directory object GUID, not an application/client ID.
The name must still resolve through SQL's external provider; duplicate display
names can fail even with `ObjectId`, which is used for identity verification.

`AccessType` is an array of existing database roles and/or database permissions,
not server roles. Multiple values are additive; `[]` creates the login/user
without extra grants. Omitted `Databases` applies to every explicitly selected
item database. A supplied list must be a subset of `SourceListofDatabases`;
`All` is not allowed for provisioning.

```powershell
$ProvisionScript = '.\ServerObjectMigrationService\scripts\Invoke-ProvisionLogins-AzSql.ps1'

# Requires ProvisionLogins=true on the selected item.
& $ProvisionScript -ConfigPath $Config -ItemId 'MI-Objects' -WhatIf
& $ProvisionScript -ConfigPath $Config -ItemId 'MI-Objects'

# Equivalent orchestrator command; omit ItemId to select both enabled items.
& $Script -ConfigPath $Config -ItemId 'VM-Objects' -Activity ProvisionLogins -WhatIf
```

Provisioning-only mode does not extract source objects or access storage.
With `ProvisionLogins: true`, the normal activities also provision directly:

| Activity | Order after that item's preflight |
|----------|----------------------------------|
| `Generate` | Extract all supported source objects and replace the Blob snapshot; no target operations |
| `Execute` | Download and verify current snapshot, provision logins, execute source SQL |
| `GenerateAndExecute` | Extract, overwrite snapshot, download/verify, provision, execute |
| `ProvisionLogins` | Provision only; requires the flag to be true |

With the flag false, activities skip provisioning. Server login scope provisions
only server logins; database users/grants are explicitly deferred until All
execution after restore. Use `-WhatIf` before target execution.

Preflight checks secret availability/validity, target SQL access, and requested
roles on every selected database. Existing login passwords remain unchanged
unless `ForcePasswordReset=true` is configured. This retains the provisioning
worker's password-policy behavior (`CHECK_POLICY=OFF`, `CHECK_EXPIRATION=OFF`);
apply your approved policy separately. New logins get new SIDs. An existing
database user with a different SID/type fails explicitly rather than silently
being remapped. Existing SQL-login SIDs are not replaced.

Passwords are read only at runtime, not written as SQL files or archived.
Provisioning artifacts and reports stay under the separate local `Provisioning`
directory, never the uploaded `SourceObjects` directory. Grants are additive:
removing a permission from config does not revoke existing access.
This is not source-login password-hash/SID migration or restored-user remapping.
If source security extraction manages the same login, coordinate those changes
before executing it; provisioning is not a substitute for arbitrary source permissions.

## Preflight, failures, and logs

Each item validates shared prerequisites before generation or replay. Local run
tracking is created first so failures are recorded. Generate checks source SQL
and storage without connecting to target SQL, even with provisioning enabled.
SQLMI generation also performs the read-only Entra report pass described above;
its directory failures are recorded separately from raw extraction/storage failures.
Execute verifies the complete stored snapshot before target writes. Configured
login provisioning validates target access, directory identities, secrets, and
per-login permissions independently from source-object replay. Replay validates
each enabled component's target access and database requirements before executing
its objects. A failed validation prevents writes for that component, not other
independent components. An All-scope login/job validation failure does not block
Server-scope jobs, operators, alerts, or mail.
`-WhatIf` creates no directories, reports, containers, uploads, or target
objects; it may read SQL/Entra, Key Vault secrets, and complete SQL snapshots.
Snapshot validation downloads SQL into memory, including in previews. The
schema-2 snapshot workflow does not require the ActiveDirectory module.
Reads cannot prove future write authorization, disk capacity, target-host
AD/SMTP routing, or arbitrary SQL compatibility.

SQL generation and Blob publication are separate steps. Generated local files
with an overall failed item and an empty `BlobManifest` do not constitute
a completed snapshot. Check the item's
storage/container error before treating the snapshot as executable.
`New-AzStorageContainer` does not accept `-Confirm`; container creation is gated by
the workflow's live Generate path and `CreateContainerIfMissing`, not by that
cmdlet's confirmation parameters. Previews never create the container.

Preflight failures identify the item, activity, failing phase, configured source,
selected databases, and target resource, SQL host, and port. SQL query failures
also include the actual attempted `ServerInstance`, database, authentication
method, connection/query timeouts, and original SQL error. The original exception
is retained as the inner exception within the item process; its contextual message
is persisted in results. Query text, passwords, and access tokens are not added
to the diagnostic context.

Use the SQL error's `ServerInstance` to distinguish a source connection failure
from a target failure. SQL VM preflight uses Windows integrated authentication;
SQL MI uses a Microsoft Entra access token. Signing in with `Connect-AzAccount`
does not change the Windows identity used for a SQL VM connection.

After a failure, display the complete message and test the affected host/port
from the machine running the script:

```powershell
$Error[0].Exception.Message
Test-NetConnection -ComputerName 'akpersonalsqlvm.centralus.cloudapp.azure.com' -Port 1433
```

Replace the host and port with the failing endpoint. A TCP timeout alone does not
identify whether DNS, routing, an NSG, the Windows firewall, or the SQL TCP listener
is responsible. `-WhatIf` still performs these read-only SQL connectivity checks;
it is not offline validation.

Items run concurrently in isolated processes, including their preflight,
generation, archive, provisioning, and execution stages. Within each target,
execution is sequential: configured login provisioning, source security,
Database Mail, operators, jobs, then alerts. This preserves prerequisite ordering
without running competing SQL changes concurrently on the same target.
Provisioning failures do not block snapshot replay. Individual replay object
failures are recorded and later objects and components are still attempted;
dependent objects can report their own missing-prerequisite errors.
Configuration errors and unverified, missing, or corrupt snapshots still block
the affected item's unsafe work. Failed extraction/upload does not publish or
execute a partial snapshot. Other target items continue.
The controlling worker waits for every selected item, records all outcomes, and
then fails if any item failed. There is no cross-target transaction or rollback.
Concurrent items must have distinct SQL host/port pairs; use one item per target.
Do not launch overlapping runs against the same target or snapshot.

The item `migration.log` includes per-component success/failure/skip totals.
The `Components` array in `results.json` records each replay object's component,
name, database, validation/execution phase, status, source-file path, and contextual
error; failed records also include the error identifier and PowerShell stack.
Disabled components and components with no eligible objects have explicit
`SKIPPED` records. Provisioning has a separate component outcome plus its existing
per-login CSV and transcript. `-WhatIf -Activity Execute` validates the snapshot
in memory and reports all independent validation results without writing SQL
or local reports. The console is the preview's diagnostic output.

To inspect all object outcomes after a run:

```powershell
$Report = Get-Content -LiteralPath '.\ServerObjectMigrationService\output\Runs\<run-id>\results.json' -Raw |
    ConvertFrom-Json
$Report.results | ForEach-Object {
    Write-Host $_.ItemId
    $_.Components | Format-Table Component, Name, Database, Phase, Status -AutoSize
    $_.Components | Where-Object Status -eq 'FAILED' |
        Format-List Component, Name, Database, Phase, OutputFile, ErrorMessage, ErrorId, ScriptStackTrace
}
```

Background execution uses the same Windows account as the launching terminal.
It imports a temporary Azure profile inside the protected local run directory,
without credential export. That profile and the launch request are removed;
neither is uploaded. Item processes also isolate Azure context changes, SQL
script state, and transcripts.

### Source and target certificate trust

Use the error's `ServerInstance` to identify the failing connection. A failure
against `DESKTOP-SGA61QP\DMF` concerns the source instance, even when the item also
lists an Azure target. Generate-only still reads source metadata.

Source SQL connections validate certificates by default and request encryption.
For an isolated development source with an untrusted certificate, explicitly set
this Boolean on the test item:

```json
"SourceTrustServerCertificate": true
```

This setting applies to source preflight, metadata extraction, connection checks,
and SQL Agent SMO scripting in both foreground and background workers. It keeps
encryption enabled but skips source certificate validation, including chain and
hostname checks. A warning identifies the source when enabled. Do not use it on
untrusted networks or as a production certificate fix. Set it back to `false`
after configuring a trusted source certificate.

The source setting does not affect target certificate validation. Target replay,
configured login provisioning, and their SQL preflights use a separate Boolean,
`TargetTrustServerCertificate`, also defaulting to `false`. Both options inherit
from Common, with item `false` overriding Common `true`. Use JSON Booleans, not
strings or `"Yes"`/`"No"`. Neither option bypasses authentication or permissions.

For an isolated SQL VM development target, set this on only the VM item:

```json
"TargetTrustServerCertificate": true
```

Encryption remains enabled, but the target certificate chain and hostname are
not validated. This reduces protection against server impersonation; do not use
it on untrusted networks or as a production certificate fix. Keep it `false`
on SQL MI, whose service certificate should validate normally, and return the
VM setting to `false` once a trusted certificate is installed. Changing target
trust does not require regenerating Blob snapshots. It does not change SQL VM
Windows integrated authentication into SQL-password authentication.

Source connection trust is recorded in the snapshot configuration but does not
need to match when replaying SQL: Execute-only does not connect to the source.

### SQL VM certificate trust and SQL MI metadata collations

A connection followed by "The certificate chain was issued by an authority that
is not trusted" reached SQL Server but failed TLS validation, before SQL
authentication completed. Starting the VM or opening another NSG rule does not
repair certificate trust. Certificate validation is enabled by default for
login provisioning and replay. Prefer installing a trusted certificate; the
explicit development-only target override above is not a certificate repair.

To configure the SQL VM while retaining validation:

1. Obtain a CA-issued SQL Server TLS certificate with Server Authentication EKU,
   a private key, and a valid date range. Include
   `akpersonalsqlvm.centralus.cloudapp.azure.com` in its DNS Subject Alternative
   Names, along with the VM hostname/FQDN used by other clients. For another VM,
   use that item's actual `TargetSqlHost`.
2. On the SQL VM, import the certificate and private key into Local Computer >
   Personal > Certificates. Grant the SQL Server service account read access to
   its private key.
3. In SQL Server Configuration Manager, open SQL Server Network Configuration >
   Protocols for the target instance > Properties > Certificate. Select the
   certificate. Schedule and perform a SQL Server service restart, then check
   its error log to verify that the intended certificate loaded. Setting Force
   Encryption affects other clients; it is not required for these clients,
   which already request encryption.
4. On the migration machine, install the verified issuing root CA certificate
   in Local Computer > Trusted Root Certification Authorities and any
   intermediate CA certificates in Intermediate Certification Authorities.
   Distribute only public certificates, not the server private key. Background
   workers run on this machine and need the same trusted chain.
5. Retry the preview. If it next reports a Windows login or untrusted-domain
   error, resolve Windows authentication separately. The `Logins` array
   describes principals to create, not credentials for the administrative
   connection.

Follow Microsoft's [certificate requirements](https://learn.microsoft.com/sql/database-engine/configure-windows/certificate-requirements)
and [certificate installation instructions](https://learn.microsoft.com/sql/database-engine/configure-windows/configure-sql-server-encryption)
for your SQL Server version. Do not import an unverified certificate as a
trusted root.

SQL MI can use different collations for database catalog metadata and built-in
permission metadata. Provisioning preflight applies `COLLATE DATABASE_DEFAULT`
to both name expressions in its role/permission `UNION`. This avoids error 468
without changing server/database collations or any stored data. The same query
is used for SQL VM. SQL MI certificate validation remains enabled; no custom MI
certificate installation is needed for this collation error.

`results.json` is updated atomically with `Running`, then `Succeeded`/`Failed`,
including each item's mode, run IDs, archive URL, component results, and error.
Use `-OutputJsonPath` for an additional report copy. Inspect the persistent
report even when the command throws. A generated SQL file does not prove it
was applied to a target.

### Status and monitoring

`Status` and `Monitor` read local reports without SQL/Azure access or configuration
revalidation. Omit `RunDirectory` to inspect the latest local run, or pass the
directory returned by launch to pin a particular run. `ItemId` filters displayed
results, not the overall run outcome. Monitoring stops after the whole run
finishes. Ctrl+C stops monitoring, not the background worker.

```powershell
$Status = & $Script -Activity Status -RunDirectory $Run.RunDirectory
$Status | Select-Object Status, ProcessId, RunDirectory, ErrorMessage
$Status.Results | Format-Table ItemId, Mode, Status, ErrorMessage -Wrap

# Monitor a pinned run or the latest run after reopening PowerShell.
& $Script -Activity Monitor -RunDirectory $Run.RunDirectory -MonitorIntervalSeconds 5
& $Script -Activity Status
& $Script -Activity Monitor

# Alternative to background launch: wait here while both targets run concurrently.
& $Script -ConfigPath $Config -Activity Generate -Foreground -ThrottleLimit 10
```

Per-item states are `Pending`, `Running`, `SUCCESS`, or `FAILED`; the run is
`Running`, `Succeeded`, or `Failed`. An unexpectedly exited owner process is
reported as `Interrupted`, with a warning to verify target SQL state before
retrying. Reports do not roll back already applied SQL.

```powershell
Get-Content -LiteralPath '.\ServerObjectMigrationService\output\Runs\<run-id>\results.json' -Raw |
    ConvertFrom-Json | Select-Object status, results

Invoke-Pester -Path '.\ServerObjectMigrationService\tests' -Output Detailed
```

Tests use mocked SQL/AD/Azure boundaries; they do not certify generated SQL
against a live instance. Coordinate actual object execution with
[database migration](../DataMigrationService/README.md), validate applications,
and enable target jobs only through the approved cutover runbook.
