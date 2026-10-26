---
title: Migration script prerequisites
description: Prepare the local PowerShell host and Azure dependencies before running the active SQL migration packages.
---

## Scope

Use these instructions for the two active packages:
[DataMigrationService](../DataMigrationService/README.md) and
[ServerObjectMigrationService](../ServerObjectMigrationService/README.md).
Scripts under Archive are not covered.

The [setup script](./Install-MigrationPrerequisites.ps1) checks local dependencies
and optionally installs missing PowerShell modules. It does not run migrations,
authenticate, change execution policy, trust repositories, install Windows
features, assign permissions, or provision Azure resources.

## Install PowerShell 7 first

Run in a Windows terminal:

```powershell
winget install --id Microsoft.PowerShell --source winget
```

Alternatively, use the
[official PowerShell installation instructions](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows).
Open PowerShell 7 using `pwsh`, not Windows PowerShell 5.1 or PowerShell ISE:

```powershell
pwsh
$PSVersionTable.PSVersion
```

All active entry points require PowerShell 7+. Use a currently supported release.
Server-object migration requires a Windows administration host; the schema-2
source snapshot workflow does not require RSAT or the ActiveDirectory module.
Run setup as the same Windows account that will run migrations or scheduled tasks.
Current-user modules installed under another account might not be available.

## Check and install local dependencies

From the repository root in PowerShell 7:

```powershell
# Check only. Missing dependencies produce an error and a nonzero exit code.
& '.\Prerequisites\Install-MigrationPrerequisites.ps1' -Workload SqlVmRestore

# Preview module installation without installing anything.
& '.\Prerequisites\Install-MigrationPrerequisites.ps1' -Workload SqlVmRestore -Install -WhatIf

# Install missing Gallery modules for the current user and verify imports.
& '.\Prerequisites\Install-MigrationPrerequisites.ps1' -Workload SqlVmRestore -Install
```

Use `-Workload All -Install` to prepare every active workflow, or select:

| Workload | Required modules | Other local requirements |
|----------|------------------|--------------------------|
| `SqlVmRestore` | `Az.Accounts`, `Az.DataMigration`, `Az.Storage`, `Az.Resources`, `Az.SqlVirtualMachine`, `SqlServer` | SQL VM connectivity and the configured SQL-login or Entra access |
| `SqlMiRestore` | `Az.Accounts`, `Az.DataMigration`, `Az.Storage`, `Az.Resources`, `Az.Sql`, `SqlServer` | SQL MI connectivity and the configured SQL-login or Entra access |
| `BackupUpload` | `Az.Accounts`, `Az.Storage` | AzCopy v10+, readable local backups |
| `MigrationControl` | `Az.Accounts`, `Az.DataMigration` | Used for status, cutover, and removal |
| `ServerObjects` | `SqlServer`, `Az.Accounts`, `Az.Resources`, `Az.Storage` | Source SQL for Generate; target SQL/Entra for Execute; private Blob access |
| `LoginProvisioning` | `SqlServer`, `Az.Accounts`, `Az.KeyVault`, `Az.Resources` | Target SQL administration, SQL-login secret reads, and external-principal directory lookup |

`SqlAuthLogins` remains a compatibility alias for `LoginProvisioning`.
Direct provisioning supports SQL logins, Entra users/groups, and managed
identities on SQL VM and MI. Key Vault is used only for SQL-login rows;
directory lookup is used for external rows. Provisioning-only runs do not need
Blob storage access. Enable the item-specific `ProvisionLogins` flag first;
see [login configuration and commands](../ServerObjectMigrationService/README.md#provision-item-specific-logins-directly).

`ServerObjects` covers MI and VM source-object migration, including MI Entra
directory mapping. New managed-identity access uses `LoginProvisioning` and an
item `Logins` entry with `Type: "ManagedIdentity"`; it is not a generated source
component. A basic VM-only SQL operation may not use all Azure modules.
The setup script checks AzCopy on PATH; the DMS backup uploader also accepts an explicit
`AzCopyPath` if your installation is not on PATH.

Gallery installation requires access to PowerShell Gallery and its package
download endpoints. Approve the repository prompt only if your organization
permits it. An installation/import error stops setup. Existing modules are
not automatically upgraded. Restore preflight also checks
`AzureBlobUserAssignedIdentity` when a user-assigned identity is selected.

### Restore authentication

Run `Connect-AzAccount` interactively before restore, in the same PowerShell
session. The signed-in user authorizes Azure resource operations and Blob
discovery. DMS service-side backup reads use different defaults by target:

| Target | Default Blob authentication | Service-side identity |
|--------|-----------------------------|-----------------------|
| SQL MI | `ManagedIdentity`, `SystemAssigned` | Target MI's managed identity |
| SQL VM | `AccountKey` | Runtime-retrieved storage account key |

Restore also checks whether the target database already exists. SQLVM defaults
to SQL login entry in the launcher; SQLMI defaults to the signed-in identity's
Entra SQL token. `TargetSqlAuthType="SqlLogin"` selects SQL login for either
target; `TargetSqlAuthType="Entra"` selects the signed-in Azure user's SQL token
for either target. The operational config currently selects Entra for both.
Neither option changes DMS Blob authentication. Both require `VIEW ANY DATABASE`
on the target endpoint. For
unattended SQL-login execution, configure a named `credential` in the separate,
Git-ignored `password.local.json` beside the migration config, a same-user DPAPI
credential-file path, or a username plus password-environment-variable reference.
Never put passwords in the migration config. The optional local JSON is plaintext
at rest; restrict its file permissions and never publish it.
See [credential configuration and background execution](../DataMigrationService/README.md#sql-login-and-existing-target-approval).

Only explicitly approved replacement items are deleted. Replacement additionally
requires `ALTER ANY DATABASE`, migration cancel/delete authorization, and, for
SQLMI, `Microsoft.Sql/managedInstances/databases/delete` on the target database.
Background workers run under the launching Windows identity using its exported
Azure context and existing token cache. Keep the execution host running; workers
cannot open authentication dialogs if that sign-in expires or needs interaction.

For MI, enable the target's system-assigned identity and grant it **Storage Blob
Data Reader** on the backup container or storage account. The executing user
also needs Blob data read access for discovery and permissions to manage DMS
migrations. MI managed-identity restore, including `-WhatIf`, does not retrieve
storage keys, require `listKeys`, or require shared-key access to be enabled.
Preflight checks that the target identity exists; it does not impersonate that
identity to prove effective Blob access or service-side network connectivity.
Directory Readers for Entra principal lookup is a separate permission and does
not grant Blob access.

The MI setup profile checks `AzureBlobAuthType`, `AzureBlobIdentityType`,
`AzureBlobContainerName`, and `AzureBlobStorageAccountResourceId`.
For an explicitly selected user-assigned MI identity, also verify support for
`AzureBlobUserAssignedIdentity`, attach that identity to the MI, supply its
resource ID, and grant it Blob read access.

For VM, the script retrieves a storage key under the executing user's context
and passes it to DMS using `AzureBlobAccountKey`. DMS does not receive the user's
interactive token. The VM setup profile checks `AzureBlobAccountKey`,
`AzureBlobContainerName`, and `AzureBlobStorageAccountResourceId`.
The user needs storage-account `listKeys` permission in addition to Blob data
access, and the storage account must allow shared-key access. Storage Account
Key Operator Service Role is an example role granting key retrieval; scope it
to the backup storage account. Blob data permissions alone do not grant
`Microsoft.Storage/storageAccounts/listKeys/action`. Keys are fetched at runtime,
not written to config or logs. Restore `-WhatIf` also retrieves a key for
validation, but does not start a migration.

Az.DataMigration 1.1.1 exposes managed-identity parameters on the SQL MI command,
but not the SQL VM command. Capability checks block unsupported modes without
falling back. An explicit AccountKey override remains available for MI when
intentionally configured; it then needs the same key permissions as VM.
The VM JSON's `BlobIdentityType=SystemAssigned` and empty
`BlobUserAssignedIdentity` are inactive in AccountKey mode.

### Optional RSAT for legacy platform scripts

Skip this section for the consolidated schema-2 snapshot workflow. Only older
platform workers that explicitly query on-premises AD require these tools.

ActiveDirectory is a Windows component, not a Gallery module. From an
elevated terminal on supported Windows 10/11 editions:

```powershell
Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
```

On Windows Server, use an elevated Windows PowerShell terminal:

```powershell
Install-WindowsFeature -Name RSAT-AD-PowerShell
```

Honor any restart requirement, reopen PowerShell 7, and rerun setup.
Directory queries require access to the appropriate AD environment; installing
RSAT does not grant directory permissions or join the machine to a domain.

### Install AzCopy for DMS backup uploads

Follow the [AzCopy download instructions](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10).
Add the extracted executable directory to PATH, reopen PowerShell, and verify:

```powershell
azcopy --version
```

The setup script does not download executables or edit PATH.

## Interactive Azure sign-in

After local setup succeeds, authenticate in the same PowerShell 7 terminal
that will run migration preflight and execution:

```powershell
Connect-AzAccount -ErrorAction Stop
Set-AzContext -SubscriptionId '<subscription-id-from-your-config>' -ErrorAction Stop
Get-AzContext | Select-Object Account, Tenant, Subscription
```

Verify the account, tenant, and subscription before proceeding. Azure CLI
authentication does not establish an Az PowerShell context. Do not launch
another `pwsh` process between sign-in and migration when using a process-only
context.

For the current environment, explicitly select the intended Entra user:

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
```

Illustrative output, not proof of SQL access:

```text
Account      : kadda@microsoft.com
Tenant       : b7d7daca-8689-49f9-8a9b-d20adf81c78b
Subscription : cd7743ef-8ddc-4254-b715-2c79c8ab4126
```

This Azure sign-in is required even when SQL connections use a named SQL login.
In Entra mode, SQL connections use this context's access token, not the Windows
account that opened the terminal and not the target VM/MI managed identity.
Complete the target-side prerequisites below before running restore preflight.

### Account picker or token-cache failures on Windows

If no account picker appears, sign-in stalls, or you receive
`SharedTokenCacheCredential authentication failed`, retry browser login with an
explicit tenant and subscription. This is an optional troubleshooting sequence,
not a change performed by the prerequisite installer or migration scripts.

The following values match the current personal subscription. Replace them
for another environment:

```powershell
# These changes apply only to this PowerShell process.
Disable-AzContextAutosave -Scope Process
Clear-AzContext -Scope Process -Force

# Use browser login instead of the Windows account broker.
Update-AzConfig -EnableLoginByWam $false -Scope Process
Update-AzConfig -LoginExperienceV2 Off -Scope Process

$tenantId = 'kartheekkumar801gmail.onmicrosoft.com'
$subscriptionId = 'cd7743ef-8ddc-4254-b715-2c79c8ab4126'

Connect-AzAccount `
    -Tenant $tenantId `
    -Subscription $subscriptionId `
    -ErrorAction Stop

Get-AzContext | Select-Object Account, Tenant, Subscription
```

Complete the browser sign-in with the account that has access to the target
subscription. Clearing the process context removes that session's existing
Azure selection; it does not grant permissions or modify Azure resources.
These settings and the non-autosaved context need to be established again in
a new terminal.

`-Tenant` accepts a tenant GUID or verified directory domain such as
`<directory>.onmicrosoft.com`. To find the GUID in Azure portal, open
Microsoft Entra ID, confirm the directory matches the subscription, and copy
Tenant ID from Overview or Properties. Do not change the subscription's
directory association to troubleshoot login.

If browser login is unavailable and your organization's policy permits
device-code authentication, use `Connect-AzAccount -Tenant $tenantId
-Subscription $subscriptionId -UseDeviceAuthentication -ErrorAction Stop`
instead. Follow only the URL and fresh code displayed by your own command;
do not share device codes or tokens.

If authentication still fails, stop before migration and investigate the
reported identity or Conditional Access error. Do not bypass organizational
authentication requirements. See
[Microsoft's interactive sign-in guidance](https://learn.microsoft.com/en-us/powershell/azure/authenticate-interactive).

## Azure, SQL, and backup prerequisites

Local setup success is not proof that a migration can run.

### Access and infrastructure managed outside scripts

Complete these tasks separately through approved Azure/Entra administration and
SQL DBA procedures. Neither the prerequisite installer nor the DMS lifecycle
script provisions this access or infrastructure. Replacement creates database
migration records under an existing DMS service; it does not deploy that service.

| Principal or component | Required external preparation |
|------------------------|-------------------------------|
| Azure operator, such as `kadda@microsoft.com` | Resource-read and selected migration create/update/cutover/cancel/delete permissions; Blob discovery access; storage `listKeys` for AccountKey flows; MI database-delete permission for replacement |
| SQL connection principal | A working SQL login or Entra login on each target; `VIEW ANY DATABASE` for existence checks and `ALTER ANY DATABASE` for replacement; other DMS scenario permissions remain separate |
| SQL VM managed identity | Directory lookup permissions for VM Entra authentication; these do not grant the operator SQL access or Blob access |
| SQL MI managed identity | Directory lookup permissions for Entra principal resolution and, separately, Storage Blob Data Reader for ManagedIdentity Blob restore |
| Execution host and DMS network paths | DNS, routes, endpoint access, SQL listening ports, NSG/OS/storage firewall rules, and required Entra/Graph outbound access |
| Target and backup infrastructure | Existing SQL VM/MI, registered SQL VM, DMS service, storage/container, capacity, compatible backup chain, and required TDE keys/certificates |

SQL `sysadmin`, Azure RBAC, Entra directory roles, and Blob data roles are
different permission systems. Being sysadmin on both targets does not grant
Azure migration permissions; assigning Directory Readers to a target identity
does not grant your personal account SQL access. Scope each grant to the
resources and operations actually needed.

* Sign in with `Connect-AzAccount` in the migration PowerShell session, then
  select the subscription with `Set-AzContext`. Azure CLI sign-in is not a
  substitute for the Az PowerShell context.
* Give the caller permission to read the configured resources and manage DMS
  migrations. Blob discovery uses the caller's Entra identity and needs Blob
  data read access; uploading backups additionally needs Blob data write access,
  for example Storage Blob Data Contributor on the backup container/account.
* Pre-create the DMS service and containers. For backups already in Azure Blob,
  the lifecycle script does not require a self-hosted integration runtime.
  A self-hosted runtime is required for backups on an on-premises network share,
  not for these Blob-source entry points. DMS and the target must still have
  access to the required endpoints.
* Register SQL VM targets with the SQL IaaS Agent extension. Configure target
  credentials, backup/data paths, service-account access, disk capacity, and other
  [DMS target prerequisites](https://learn.microsoft.com/en-us/azure/dms/migration-using-azure-data-studio)
  for the selected migration scenario.
* SQL MI defaults to its target managed identity for Blob reads; enable it and
  grant Storage Blob Data Reader on the backup container/account. SQL VM defaults
  to a runtime-retrieved storage key; grant the interactive user key retrieval
  permission and allow shared-key access for that flow. Setup does not assign
  roles, enable identities, or change storage policy.
* Verify DNS, routing, SQL TCP listening, NSG, Windows firewall, and storage
  firewall/private-endpoint access from the executor and DMS runtime as applicable.
  Restrict public SQL rules to authorized sources. VM SQL commonly uses 1433;
  the MI public endpoint uses 3342.
* SQL VM server-object scripts currently use Windows integrated authentication,
  not a SQL login/password. MI server objects use Entra authentication.
  Grant the source extraction and target execution permissions needed for the
  enabled components; target logins/jobs may require SQL sysadmin.
* Server-object generation additionally archives SQL to private per-target
  containers using the signed-in Azure identity. Give that identity storage
  account resource-read, container-list, and Blob data read/write access.
  Creating missing containers requires account-scoped container-create rights,
  for example Storage Blob Data Contributor. Archive containers are distinct
  from DMS backup containers. Existing public archive containers are refused;
  the script does not change account policies, RBAC, or firewall rules.
* Key Vault login provisioning supports VM Windows authentication and MI Entra
  authentication. It additionally requires secret-read permissions,
  trusted SQL certificates, and valid login/vault/secret names.
  Never store passwords in configuration files.
* Confirm backup compatibility, restore-chain continuity, and any TDE certificate/
  key requirements. FULL files use `.bak`; DIFF uses `.bak` or `.diff`; LOG uses
  `.trn` or `.log`. Filenames need supported timestamps or explicit timestamp
  options. See the [backup conventions](../DataMigrationService/README.md).
* Review config resource names, subscription/tenant, containers, database scope,
  and execution flags. Hosts used with a separate port field must not include
  `tcp:` or `,port`. Replace placeholders before running preflight.
* Ensure readable input paths and writable output/log locations. SQL Agent and
  scheduled-task execution must use PowerShell 7 and the intended account.

## SQL VM Entra authentication prerequisites

These steps are manual infrastructure and access setup, not actions performed
by the migration scripts. SQL Server 2022 or later is required for the Azure SQL
VM Entra configuration described here; this is not a version requirement for
every SQL-login-only migration scenario.

### 1. Check your SQL Server version

In SSMS, connect using an existing SQL Server administrator connection and run:

```sql
SELECT @@VERSION;
```

Illustrative output excerpt:

```text
Microsoft SQL Server 2022 ...
```

If the version is older, stop this Entra setup and plan a supported
upgrade/configuration separately. The scripts do not upgrade SQL Server.

### 2. Configure a managed identity and directory access

1. In Azure portal, open Virtual machines, select `akpersonalsqlvm`, and open
   Identity, then System assigned.
2. Set Status to On and save. Record the identity's object/principal ID.
3. Ask an authorized Entra administrator to grant that identity either all three
   Microsoft Graph application permissions `User.Read.All`,
   `GroupMember.Read.All`, and `Application.Read.All`, with required admin
   consent, or the broader Directory Readers Entra role.
4. For Directory Readers, an administrator with Privileged Role Administrator
   privileges can open Microsoft Entra ID, Roles and administrators, Directory
   Readers, then Add assignments. Search for the VM's system-assigned identity
   using the VM name and verify the object ID before assigning it.

Assign directory lookup permissions to the VM's managed identity, not your
personal account. Confirm the identity appears as a service principal in
Directory Readers if using that approach. The VM identity lets SQL Server look
up Entra users/groups; it is not the identity used for your client SQL connection.
Azure subscription Owner alone does not confer authority to assign Entra roles.

### 3. Enable Entra authentication for SQL Server

1. Open the Azure portal's SQL virtual machines service, not the regular Virtual
   machines resource page, and select `akpersonalsqlvm`.
2. Open Security, then Security Configuration.
3. Under Microsoft Entra authentication, select Enable.
4. Select System-assigned managed identity.
5. Select Apply or Save and wait for the configuration operation to finish.

If the VM is absent from SQL virtual machines, register it with the SQL IaaS
Agent extension first. Check the extension's supported instance configuration.
Enabling the VM identity alone does not enable SQL Server Entra authentication.
An Enable radio button selected before Apply is not evidence of a completed
configuration change.

Allow SQL Server to reach Microsoft Entra ID and Microsoft Graph, and allow the
client to reach Entra sign-in endpoints through approved outbound rules. Opening
SQL TCP 1433 alone is insufficient. Follow the endpoint/service-tag requirements
in the [official SQL VM Entra configuration guide](https://learn.microsoft.com/en-us/azure/azure-sql/virtual-machines/windows/configure-azure-ad-authentication-for-sql-vm).

### 4. Provision and verify SQL access separately

A DBA must create or validate the intended Entra login and its permissions on
the target. A same-named SQL-authentication or Windows login is not automatically
the Entra principal. If `kadda@microsoft.com` already has Entra SQL sysadmin
access, no additional SQL role grant is needed for the checks below.

For a missing login, an authorized DBA can use the following manual example in
`master` after directory lookup and Entra authentication are configured:

```sql
CREATE LOGIN [kadda@microsoft.com] FROM EXTERNAL PROVIDER;
```

Run it only when the principal is absent; the scripts do not create the
operator's initial login. Have the DBA assign approved phase-specific
permissions. `VIEW ANY DATABASE` is required by restore existence checks;
replacement additionally requires `ALTER ANY DATABASE`. Do not grant sysadmin
automatically merely to bypass a failed preflight.

In SSMS, reconnect using Microsoft Entra MFA/interactive authentication to the
target endpoint and database `master`. Run this read-only check:

```sql
SELECT ORIGINAL_LOGIN() AS OriginalLogin,
       SUSER_SNAME() AS LoginName,
       IS_SRVROLEMEMBER(N'sysadmin') AS IsSysadmin,
       HAS_PERMS_BY_NAME(NULL, NULL, N'VIEW ANY DATABASE') AS CanViewAnyDatabase,
       HAS_PERMS_BY_NAME(NULL, NULL, N'ALTER ANY DATABASE') AS CanAlterAnyDatabase;
```

Illustrative output for an existing Entra sysadmin:

```text
OriginalLogin          LoginName              IsSysadmin CanViewAnyDatabase CanAlterAnyDatabase
-------------          ---------              ---------- ------------------ -------------------
kadda@microsoft.com    kadda@microsoft.com     1          1                  1
```

Repeat the SQL-access verification on SQL MI after completing its prerequisites
below. A successful Azure sign-in, Directory Readers assignment, or TCP probe
does not replace this SQL-level validation.

## SQL MI identity and connection prerequisites

Complete these infrastructure checks before MI server-object execution or
testing Entra access. Directory-read permissions are separate from the MI
identity's Blob read permissions for DMS restore.

1. Wait for the managed instance to finish starting and become available.
2. Configure a Microsoft Entra administrator on the MI. Use an account from
   that tenant, or an appropriately provisioned guest, with SQL access.
3. Grant the MI's managed identity directory-read access, using Directory Readers
   or the supported least-privilege Microsoft Graph permissions for your
   scenario. This enables directory lookup; it does not grant the operator SQL
   permissions. An authorized Entra administrator must grant/consent to these
   permissions. Azure subscription Owner alone does not imply that authority.
4. Review the MI's Microsoft Entra ID pane and its Authentication metadata
   setting. The operator reports configuring `ak-personal-sqlmi` to `Paired`.
   Record and validate this environment-specific choice; do not treat it as a
   universal prerequisite for Blob restore or as proof that Windows/Kerberos
   authentication is configured.
5. For SSMS access to the public endpoint, enable that endpoint and permit
   authorized sources on TCP 3342. Use
   `tcp:ak-personal-sqlmi.public.3c52841dc1d0.database.windows.net,3342`.
   Select Microsoft Entra MFA/interactive authentication for an Entra login.
   Ordinary Windows Authentication requires separate supported Kerberos/client
   setup; directory-read permission and metadata changes alone are insufficient.
6. Keep the authentication policy aligned with the intended login workflow.
   Entra-only authentication disables SQL-authentication connections, including
   the SQL-authentication logins provisioned by the Key Vault workflow.

If SSMS reports `The target principal name is incorrect. Cannot generate SSPI
context`, verify the selected authentication method first. For this project's
MI Entra workflow, retry with Microsoft Entra MFA/interactive authentication,
the correct tenant/account, and database `master`. Do not disable encryption,
change SPNs, or enable Windows authentication as a generic workaround.
If the error persists, collect the SSMS version, authentication selection, and
full new error before changing infrastructure.

References:
[MI directory-read permissions](https://learn.microsoft.com/en-us/azure/azure-sql/database/authentication-aad-directory-readers-role)
and [separate MI Windows/Kerberos setup](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/winauth-azuread-setup).

For DMS Entra testing, validate the operator's existing MI Entra login and
permissions using the [read-only SQL access query](#4-provision-and-verify-sql-access-separately).
Configure the MI administrator separately as described in
[Microsoft's Entra authentication guide](https://learn.microsoft.com/en-us/azure/azure-sql/database/authentication-aad-configure).

### SQL login prerequisites for either target

If choosing `TargetSqlAuthType="SqlLogin"` instead, a DBA must provision a valid
SQL-authentication login and grant the required permissions. SQL VM must have
SQL Server and Windows Authentication mode enabled; an administrator must handle
any required SQL service restart. SQL MI must not have Entra-only authentication
enabled if SQL logins are to be used. The scripts do not change either policy
or create the operator's initial SQL-authentication login.

Keep the password only in approved secret storage or the explicitly local,
ignored credential file. See the
[named SQL credential example](../DataMigrationService/README.md#named-sql-credentials)
and the [Entra user example](../DataMigrationService/README.md#entra-login-as-the-signed-in-user).
Both modes still need Azure RBAC, Blob access, and the network/backup prerequisites.
Use valid trusted SQL certificates where possible; `TargetTrustServerCertificate`
is a separate explicit test exception, not an authentication mode.

### SQL MI restore endpoint caveat

The TCP preflight check is enabled for both SQL VM and SQL MI. It uses each
item's effective `TargetSqlHost` and `TargetSqlPort` from the
[lifecycle configuration](../DataMigrationService/config/Invoke-RestoreDMS.config.json),
with blank item values inheriting Common. A hostname is required for Restore;
there is no automatic substitution of the MI resource's private hostname.

The operational config checks the VM DNS hostname on port 1433 and the MI
public hostname on port 3342. For a private MI endpoint, configure its VNet
hostname and port 1433, and run from a host with the required VNet connectivity.
Provide only the hostname in `TargetSqlHost`, without `tcp:` or `,3342`;
the port belongs in `TargetSqlPort`.

This checks connectivity from the execution host, not from DMS. It does not
change the DMS target to a public SQL endpoint: DMS still uses the Azure
resource identified by `TargetName` and needs its own network access.
A successful public TCP/SSMS connection does not prove DMS's private path works.

## Run SQL VM restore after setup

From the repository root in PowerShell 7, install/check local prerequisites:

```powershell
& '.\Prerequisites\Install-MigrationPrerequisites.ps1' -Workload SqlVmRestore -Install
if ($LASTEXITCODE -ne 0) { throw 'Prerequisite setup failed. Resolve the reported errors first.' }
```

Complete [interactive Azure sign-in](#interactive-azure-sign-in), using the
Windows troubleshooting sequence if needed. Then, in that same terminal:

In [Invoke-RestoreDMS.config.json](../DataMigrationService/config/Invoke-RestoreDMS.config.json),
each item holds its source backup, target type/name, and database details.
Nonblank item values override Common; blank or omitted values inherit it.
Use `-ItemId VM-MIGRDEMO` to select just the VM mapping, or omit selectors for
all enabled VM and MI mappings under one global restore concurrency limit.
For MI, use the `SqlMiRestore` prerequisite workload. MI uses its managed
identity and VM uses AccountKey. Set `Common.Activity` or use CLI `-Activity`
for Restore, Status, Monitor, Cutover, or Remove, without changing scripts or
adding configuration files. The single lifecycle script handles both target types
with isolated submission/background workers; keep its Common helper directory beside it.

```powershell
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -ConfigPath '.\DataMigrationService\config\Invoke-RestoreDMS.config.json' `
    -Activity Restore -ItemId 'VM-MIGRDEMO' -WhatIf
```

Stop if preflight reports an error. After reviewing successful preflight, run:

```powershell
& '.\DataMigrationService\scripts\Invoke-RestoreDMS.ps1' `
    -ConfigPath '.\DataMigrationService\config\Invoke-RestoreDMS.config.json' `
    -Activity Restore -ItemId 'VM-MIGRDEMO'
```

The lifecycle script performs online DMS migrations. With `AutoCutover=false`, cutover
is manual. Stop source writes and upload final logs before cutover. Other entry
points and their exact commands are documented in each package README.
Migration `-WhatIf` performs live access checks; the Key Vault workflow can read
secrets during preflight. It is not an offline configuration validator.
