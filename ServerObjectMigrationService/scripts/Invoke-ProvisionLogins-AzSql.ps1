#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0
#Requires -Modules Az.Accounts

<#
.SYNOPSIS
    Provision item-specific SQL and external logins and database access.
.DESCRIPTION
    Reads a JSON configuration and applies the requested login, user and access changes.
    SQL logins use per-login Key Vault secrets. SQLVM also supports Windows AD
    users; SQLMI supports Entra users, groups and managed identities.
    This does not copy source password hashes or SIDs.
.PARAMETER ConfigPath
    Shared schemaVersion 2 configuration, or private worker input from the orchestrator.
.PARAMETER ItemId
    Optional target item IDs when using the shared configuration.
.PARAMETER SqlPort
    SQL endpoint port. Private MI endpoints normally use 1433; public endpoints use 3342.
.PARAMETER ThrottleLimit
    Maximum concurrent item processes for the shared configuration. Defaults to 10.
.PARAMETER Foreground
    Run shared-configuration provisioning synchronously instead of in the background.
.PARAMETER TargetTrustServerCertificate
    Internal worker TLS override. Schema 2 callers configure the Boolean on the target item.
.EXAMPLE
    .\Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1 -Activity ProvisionLogins -WhatIf
.NOTES
    WhatIf prevents SQL writes but still authenticates, resolves endpoints and reads secrets.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,
    [string[]]$ItemId = @(),
    [hashtable]$SqlCredentials = @{},
    [ValidateRange(1, 128)][int]$ThrottleLimit = 10,
    [switch]$Foreground,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 65535)]
    [int]$SqlPort = 1433,

    [switch]$UseWindowsAuthentication,
    [Parameter(DontShow)][ValidateSet('Auto', 'Windows', 'Entra', 'SqlLogin')][string]$TargetSqlAuthType = 'Auto',
    [Parameter(DontShow)][pscredential]$SqlCredential,
    [bool]$TargetTrustServerCertificate = $false,
    [Parameter(DontShow)][switch]$ServerOnly,
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\output\SqlLoginProvisioning')
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Common\ServerObjects.Helpers.ps1')

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    $InputConfiguration = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($InputConfiguration.schemaVersion -eq 2) {
        if ($PSBoundParameters.ContainsKey('SqlCredential') -or $PSBoundParameters.ContainsKey('TargetSqlAuthType')) {
            throw 'For schema 2, configure TargetSqlAuthType on the item and pass optional overrides through SqlCredentials keyed by item ID.'
        }
        if ($PSBoundParameters.ContainsKey('ServerOnly')) {
            throw 'ServerOnly is an internal worker option. For schema 2, set SQLLoginsMigrationScope to Server in the item configuration.'
        }
        if ($PSBoundParameters.ContainsKey('TargetTrustServerCertificate')) {
            throw 'For schema 2, configure TargetTrustServerCertificate on the target item rather than as a script parameter.'
        }
        & (Join-Path $PSScriptRoot 'Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1') `
            -ConfigPath $ConfigPath -ItemId $ItemId -Activity ProvisionLogins -OutputRoot $OutputRoot `
            -SqlCredentials $SqlCredentials `
            -ThrottleLimit $ThrottleLimit -Foreground:$Foreground -WhatIf:$WhatIfPreference -Confirm:$false
        return
    }
    #region Configuration and preflight
    $Configuration = Read-ServiceConfiguration -Path $ConfigPath
    $ResolvedSettings = Resolve-ServiceSettings -Configuration $Configuration -Command $MyInvocation.MyCommand -Overrides $PSBoundParameters
    foreach ($SettingName in $ResolvedSettings.Keys) { Set-Variable -Name $SettingName -Value $ResolvedSettings[$SettingName] -WhatIf:$false -Confirm:$false }
    $Options = Get-ServiceOptions -Command $MyInvocation.MyCommand
    if ($TargetTrustServerCertificate) {
        Write-Warning 'Target certificate validation is explicitly bypassed for login provisioning; encryption remains required. Use a trusted SQL certificate for production.'
    }
    Invoke-ServerObjectPreflight -Operation 'Invoke-ProvisionLogins-AzSql' -Configuration $Configuration -Options $Options -ScriptsPath $PSScriptRoot
    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Provision configured logins and database access')) { return }
    #endregion Configuration and preflight

$summaryDirectory = Join-Path $OutputRoot 'reports'
$logsDirectory = Join-Path $OutputRoot 'logs'
$summaryOutputPath = Join-Path -Path $summaryDirectory -ChildPath 'Invoke-ProvisionLogins-AzSql.Summary.csv'
$logOutputPath = Join-Path -Path $logsDirectory -ChildPath ("Invoke-ProvisionLogins-AzSql.{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

if (-not (Test-Path -Path $summaryDirectory)) {
    New-Item -ItemType Directory -Path $summaryDirectory -Force | Out-Null
}

if (-not (Test-Path -Path $logsDirectory)) {
    New-Item -ItemType Directory -Path $logsDirectory -Force | Out-Null
}

Start-Transcript -Path $logOutputPath -Force | Out-Null

$secretCache = @{}
try {
function Get-PlainTextFromSecureString {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$SecureString
    )

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Quote-SqlIdentifier {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return "[{0}]" -f ($Name -replace "]", "]]")
}

function Quote-SqlString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return "N'{0}'" -f ($Value -replace "'", "''")
}

function Ensure-AzContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [ref]$CurrentContextKey
    )

    $desiredKey = "{0}|{1}" -f $TenantId, $SubscriptionId
    if ($CurrentContextKey.Value -ne $desiredKey) {
        Write-Verbose "Setting Az context to Tenant '$TenantId', Subscription '$SubscriptionId'."
        Set-AzContext -Tenant $TenantId -Subscription $SubscriptionId | Out-Null
        $CurrentContextKey.Value = $desiredKey
    }
}

function Get-SqlAccessToken {
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://database.windows.net/"
    if (-not $tokenResponse) {
        throw "Could not obtain Azure SQL access token."
    }

    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        return Get-PlainTextFromSecureString -SecureString $tokenResponse.Token
    }

    return [string]$tokenResponse.Token
}

function Invoke-SqlNonQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string]$Database,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$AccessToken,

        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = "tcp:$ServerName,$Port"
    $builder['Initial Catalog'] = $Database
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $TargetTrustServerCertificate
    $builder['Connect Timeout'] = 30
    $builder['Integrated Security'] = (-not $SqlCredential -and [bool]$UseWindowsAuthentication)

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $builder.ConnectionString
    $CredentialPassword = $null
    try {
        if ($SqlCredential) {
            $CredentialPassword = $SqlCredential.Password.Copy()
            $CredentialPassword.MakeReadOnly()
            $connection.Credential = [System.Data.SqlClient.SqlCredential]::new($SqlCredential.UserName, $CredentialPassword)
        }
        elseif (-not $UseWindowsAuthentication) { $connection.AccessToken = $AccessToken }
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 120
        $command.CommandText = $Sql
        [void]$command.ExecuteNonQuery()
    }
    catch {
        $Authentication = if ($SqlCredential) { 'SQL login' } elseif ($UseWindowsAuthentication) { 'Windows integrated' } else { 'Microsoft Entra access token' }
        throw [InvalidOperationException]::new("SQL provisioning query failed: ServerInstance='$ServerName,$Port'; Database='$Database'; Authentication='$Authentication'; Encrypt=True; TrustServerCertificate=$TargetTrustServerCertificate; ConnectionTimeout=30s; QueryTimeout=120s. $($_.Exception.Message)", $_.Exception)
    }
    finally {
        if ($null -ne $connection) {
            $connection.Dispose()
        }
        if ($CredentialPassword) { $CredentialPassword.Dispose() }
    }
}

function Invoke-SqlScalar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string]$Database,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$AccessToken,

        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = "tcp:$ServerName,$Port"
    $builder['Initial Catalog'] = $Database
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $TargetTrustServerCertificate
    $builder['Connect Timeout'] = 30
    $builder['Integrated Security'] = (-not $SqlCredential -and [bool]$UseWindowsAuthentication)

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = $builder.ConnectionString
    $CredentialPassword = $null
    try {
        if ($SqlCredential) {
            $CredentialPassword = $SqlCredential.Password.Copy()
            $CredentialPassword.MakeReadOnly()
            $connection.Credential = [System.Data.SqlClient.SqlCredential]::new($SqlCredential.UserName, $CredentialPassword)
        }
        elseif (-not $UseWindowsAuthentication) { $connection.AccessToken = $AccessToken }
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 120
        $command.CommandText = $Sql
        return $command.ExecuteScalar()
    }
    catch {
        $Authentication = if ($SqlCredential) { 'SQL login' } elseif ($UseWindowsAuthentication) { 'Windows integrated' } else { 'Microsoft Entra access token' }
        throw [InvalidOperationException]::new("SQL provisioning query failed: ServerInstance='$ServerName,$Port'; Database='$Database'; Authentication='$Authentication'; Encrypt=True; TrustServerCertificate=$TargetTrustServerCertificate; ConnectionTimeout=30s; QueryTimeout=120s. $($_.Exception.Message)", $_.Exception)
    }
    finally {
        if ($null -ne $connection) {
            $connection.Dispose()
        }
        if ($CredentialPassword) { $CredentialPassword.Dispose() }
    }
}

function Get-KeyVaultSecretPlainText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultName,

        [Parameter(Mandatory = $true)]
        [string]$SecretName
    )

    $secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName
    if (-not $secret) {
        throw "Secret '$SecretName' was not found in Key Vault '$VaultName'."
    }

    if ($secret.SecretValue) {
        return Get-PlainTextFromSecureString -SecureString $secret.SecretValue
    }

    if ($secret.SecretValueText) {
        return [string]$secret.SecretValueText
    }

    throw "Unable to extract plaintext for secret '$SecretName' from Key Vault '$VaultName'."
}

function New-OrUpdate-SqlLogin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$AccessToken,

        [Parameter(Mandatory = $true)]
        [string]$LoginName,

        [Parameter(Mandatory = $true)]
        [string]$Password,

        [Parameter(Mandatory = $true)]
        [bool]$ResetIfExists
    )

    $quotedLogin = Quote-SqlIdentifier -Name $LoginName
    $loginLiteral = Quote-SqlString -Value $LoginName
    $passwordLiteral = Quote-SqlString -Value $Password

    $compatibleSql = "SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = $loginLiteral AND type <> 'S') THEN 1 ELSE 0 END;"
    if ([int](Invoke-SqlScalar -ServerName $ServerName -Port $Port -Database master -AccessToken $AccessToken -Sql $compatibleSql) -ne 1) {
        throw "Existing login '$LoginName' is not a SQL login."
    }
    $existsSql = "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = $loginLiteral) THEN 1 ELSE 0 END;"
    $loginExists = [int](Invoke-SqlScalar -ServerName $ServerName -Port $Port -Database "master" -AccessToken $AccessToken -Sql $existsSql)

    if ($ResetIfExists) {
        $sql = @"
IF EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = $loginLiteral)
BEGIN
        ALTER LOGIN $quotedLogin WITH PASSWORD = $passwordLiteral, CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
END
ELSE
BEGIN
        CREATE LOGIN $quotedLogin WITH PASSWORD = $passwordLiteral, CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
END
"@

        Invoke-SqlNonQuery -ServerName $ServerName -Port $Port -Database "master" -AccessToken $AccessToken -Sql $sql

        if ($loginExists -eq 1) {
            return "PasswordReset"
        }

        return "Created"
    }
    else {
        if ($loginExists -eq 1) {
            return "AlreadyExists"
        }

        $sql = @"
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = $loginLiteral)
BEGIN
    CREATE LOGIN $quotedLogin WITH PASSWORD = $passwordLiteral, CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
END
"@

        Invoke-SqlNonQuery -ServerName $ServerName -Port $Port -Database "master" -AccessToken $AccessToken -Sql $sql
        return "Created"
    }
}

function Ensure-WindowsADLogin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][AllowEmptyString()][string]$AccessToken,
        [Parameter(Mandatory)][string]$LoginName,
        [Parameter(Mandatory)][string]$TargetWindowsDomain
    )
    $ValidationSql = Get-ServerObjectWindowsLoginValidationSql -LoginName $LoginName -TargetWindowsDomain $TargetWindowsDomain
    $ReportedDomain = Invoke-SqlScalar -ServerName $ServerName -Port $Port -Database master -AccessToken $AccessToken `
        -Sql 'SELECT DEFAULT_DOMAIN();'
    if ([string]::IsNullOrWhiteSpace([string]$ReportedDomain)) {
        throw 'Target SQL Server did not report a default Windows domain.'
    }
    if ([string]$ReportedDomain -ine $TargetWindowsDomain) {
        throw 'Target SQL Server default Windows domain does not match TargetWindowsDomain.'
    }
    $Literal = Quote-SqlString -Value $LoginName
    $Bracket = Quote-SqlIdentifier -Name $LoginName
    # Repeat the read-only preflight checks in the write batch, before CREATE.
    $Sql = @"
SET XACT_ABORT ON;
BEGIN TRY
BEGIN TRANSACTION;
$ValidationSql
DECLARE @Created bit = 0;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = $Literal)
BEGIN
    CREATE LOGIN $Bracket FROM WINDOWS;
    SET @Created = 1;
END;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = $Literal AND type = 'U' AND sid = @ExpectedSid)
    THROW 51000, 'WindowsAD login SID/type verification failed. No database access was granted.', 1;
COMMIT TRANSACTION;
SELECT CASE WHEN @Created = 1 THEN 'Created' ELSE 'AlreadyExists' END;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
"@
    Invoke-SqlScalar -ServerName $ServerName -Port $Port -Database master -AccessToken $AccessToken -Sql $Sql
}

function Ensure-ExternalLogin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][AllowEmptyString()][string]$AccessToken,
        [Parameter(Mandatory)][string]$LoginName,
        [Parameter(Mandatory)][guid]$ObjectId,
        [ValidateSet('E', 'X')][string]$PrincipalType = 'E'
    )
    $Literal = Quote-SqlString -Value $LoginName
    $Bracket = Quote-SqlIdentifier -Name $LoginName
    $Sid = Convert-BytesToHex -Bytes $ObjectId.ToByteArray()
    $Arguments = @{ ServerName = $ServerName; Port = $Port; Database = 'master'; AccessToken = $AccessToken }
    $MatchSql = "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = $Literal AND type = '$PrincipalType' AND sid = $Sid) THEN 1 ELSE 0 END;"
    $Exists = [int](Invoke-SqlScalar @Arguments -Sql "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = $Literal) THEN 1 ELSE 0 END;")
    if ($Exists -eq 1) {
        if ([int](Invoke-SqlScalar @Arguments -Sql $MatchSql) -ne 1) {
            throw "Existing external login '$LoginName' has a different type or ObjectId/SID."
        }
        return 'AlreadyExists'
    }
    Invoke-SqlNonQuery @Arguments -Sql "CREATE LOGIN $Bracket FROM EXTERNAL PROVIDER;"
    if ([int](Invoke-SqlScalar @Arguments -Sql $MatchSql) -ne 1) {
        throw "Created external login '$LoginName' does not match the configured identity. No database access was granted."
    }
    'Created'
}

function Ensure-DatabaseUserAndAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string]$Database,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$AccessToken,

        [Parameter(Mandatory = $true)]
        [string]$LoginName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$AccessTypes,

        [ValidateSet('S', 'U', 'E', 'X')]
        [string]$PrincipalType = 'S'
    )

    $quotedLogin = Quote-SqlIdentifier -Name $LoginName
    $loginLiteral = Quote-SqlString -Value $LoginName

    $userExistsSql = "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.database_principals WHERE name = $loginLiteral) THEN 1 ELSE 0 END;"
    $userExists = [int](Invoke-SqlScalar -ServerName $ServerName -Port $Port -Database $Database -AccessToken $AccessToken -Sql $userExistsSql)

    $userAction = "AlreadyExists"
    if ($userExists -eq 0) {
        $createUserSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = $loginLiteral)
BEGIN
    CREATE USER $quotedLogin FOR LOGIN $quotedLogin;
END
"@

        Invoke-SqlNonQuery -ServerName $ServerName -Port $Port -Database $Database -AccessToken $AccessToken -Sql $createUserSql
        $userAction = "Created"
    }
    else {
        $mappedSql = "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.database_principals WHERE name = $loginLiteral AND type = '$PrincipalType' AND sid = SUSER_SID($loginLiteral)) THEN 1 ELSE 0 END;"
        if ([int](Invoke-SqlScalar -ServerName $ServerName -Port $Port -Database $Database -AccessToken $AccessToken -Sql $mappedSql) -ne 1) {
            throw "Existing database user '$LoginName' does not map to this SQL login. Resolve the SID/type conflict explicitly."
        }
    }

    $accessActions = @()

    foreach ($accessType in $AccessTypes) {
        $permissionOrRole = $accessType.Trim()
        if ([string]::IsNullOrWhiteSpace($permissionOrRole)) {
            continue
        }

        $roleLiteral = Quote-SqlString -Value $permissionOrRole
        $quotedRole = Quote-SqlIdentifier -Name $permissionOrRole

        $roleExistsSql = "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.database_principals WHERE type = 'R' AND name = $roleLiteral) THEN 1 ELSE 0 END;"
        $roleExists = [int](Invoke-SqlScalar -ServerName $ServerName -Port $Port -Database $Database -AccessToken $AccessToken -Sql $roleExistsSql)

        if ($roleExists -eq 1) {
            $isMemberSql = @"
SELECT CASE WHEN EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
    WHERE r.name = $roleLiteral
      AND m.name = $loginLiteral
) THEN 1 ELSE 0 END;
"@
            $isMember = [int](Invoke-SqlScalar -ServerName $ServerName -Port $Port -Database $Database -AccessToken $AccessToken -Sql $isMemberSql)

            if ($isMember -eq 1) {
                $accessActions += [PSCustomObject]@{
                    AccessType = $permissionOrRole
                    Action = "AlreadyAssigned"
                }
                continue
            }

            $roleSql = @"
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE type = 'R' AND name = $roleLiteral)
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM sys.database_role_members drm
        JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
        JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id
        WHERE r.name = $roleLiteral
          AND m.name = $loginLiteral
    )
    BEGIN
        ALTER ROLE $quotedRole ADD MEMBER $quotedLogin;
    END
END
"@

            Invoke-SqlNonQuery -ServerName $ServerName -Port $Port -Database $Database -AccessToken $AccessToken -Sql $roleSql
            $accessActions += [PSCustomObject]@{
                AccessType = $permissionOrRole
                Action = "Assigned"
            }
            continue
        }

        if ($permissionOrRole -notmatch '^[A-Za-z_ ]+$') {
            throw "Unsupported permission format in AccessType value '$permissionOrRole'. Allowed pattern: letters, underscore, spaces."
        }

        $permissionLiteral = Quote-SqlString -Value $permissionOrRole.ToUpperInvariant()
        $permissionGrantedSql = @"
SELECT CASE WHEN EXISTS (
    SELECT 1
    FROM sys.database_permissions p
    JOIN sys.database_principals dp ON dp.principal_id = p.grantee_principal_id
    WHERE dp.name = $loginLiteral
      AND p.class = 0
      AND p.permission_name = $permissionLiteral
      AND p.state IN ('G', 'W')
) THEN 1 ELSE 0 END;
"@
        $permissionGranted = [int](Invoke-SqlScalar -ServerName $ServerName -Port $Port -Database $Database -AccessToken $AccessToken -Sql $permissionGrantedSql)

        if ($permissionGranted -eq 1) {
            $accessActions += [PSCustomObject]@{
                AccessType = $permissionOrRole
                Action = "AlreadyGranted"
            }
            continue
        }

        $grantSql = "GRANT $permissionOrRole TO $quotedLogin;"
        Invoke-SqlNonQuery -ServerName $ServerName -Port $Port -Database $Database -AccessToken $AccessToken -Sql $grantSql
        $accessActions += [PSCustomObject]@{
            AccessType = $permissionOrRole
            Action = "Granted"
        }
    }

    return [PSCustomObject]@{
        UserAction = $userAction
        AccessActions = $accessActions
    }
}

if (-not (Test-Path -Path $ConfigPath)) {
    throw "Config file was not found: $ConfigPath"
}

$requiredColumns = @(
    "Application",
    "TargetServerName",
    "TargetType",
    "TenantId",
    "SubscriptionId",
    "TargetServerFQDN",
    "LoginName",
    "LoginType",
    "ForcePasswordReset",
    "Database",
    "AccessType"
)

$rawRows = @($Configuration.Items)
if (-not $rawRows -or $rawRows.Count -eq 0) {
    throw "The JSON configuration '$ConfigPath' has no Items."
}

# Normalize column names by trimming whitespace
$rows = @()
foreach ($rawRow in $rawRows) {
    $normalizedRow = [PSCustomObject]@{}
    foreach ($prop in $rawRow.PSObject.Properties) {
        $trimmedName = $prop.Name.Trim()
        $normalizedRow | Add-Member -MemberType NoteProperty -Name $trimmedName -Value $prop.Value
    }
    $rows += $normalizedRow
}

foreach ($column in $requiredColumns) {
    if (-not ($rows[0].PSObject.Properties.Name -contains $column)) {
        throw "Missing required JSON item field: $column"
    }
}

$contextKey = ""
$secretCache = @{}
$loginInitialized = @{}
$failedRows = @()
$successCount = 0
$skippedCount = 0
$migrationDetails = @()

foreach ($row in $rows) {
    $loginName = $null
    $database = $null
    $serverName = $null
    $password = $null
    try {
        $tenantId = $row.TenantId.Trim()
        $subscriptionId = $row.SubscriptionId.Trim()
        $serverName = $row.TargetServerName.Trim()
        $targetType = $row.TargetType.Trim()
        if ($targetType -notin @('SQLVM', 'SQLMI')) { throw 'Provisioning requires SQLVM or SQLMI.' }
        $AuthType = $TargetSqlAuthType
        if ($AuthType -eq 'Auto') { $AuthType = if ($targetType -eq 'SQLVM') { 'Windows' } else { 'Entra' } }
        if ($AuthType -eq 'SqlLogin' -and -not $SqlCredential) { throw 'SQL authentication requires a resolved administrative credential.' }
        if ($AuthType -ne 'SqlLogin' -and $SqlCredential) { throw 'SQL credentials cannot be combined with Windows or Entra authentication.' }
        $UseWindowsAuthentication = $AuthType -eq 'Windows'
        $loginName = $row.LoginName.Trim()
        $loginType = $row.LoginType
        $Domain = if ($row.PSObject.Properties['TargetWindowsDomain']) { [string]$row.TargetWindowsDomain } else { '' }
        Assert-ServerObjectLoginTarget -TargetType $targetType -LoginType $loginType -LoginName $loginName -TargetWindowsDomain $Domain
        $vaultName = $row.KeyVaultName.Trim()
        $secretName = $row.SecretName.Trim()
        $database = $row.Database.Trim()

        foreach ($idName in @('TenantId', 'SubscriptionId')) {
            $idValue = [guid]::Empty
            if (-not [guid]::TryParse($row.$idName, [ref]$idValue) -or $idValue -eq [guid]::Empty) {
                throw "$idName must be a non-empty GUID."
            }
        }
        Ensure-AzContext -TenantId $tenantId -SubscriptionId $subscriptionId -CurrentContextKey ([ref]$contextKey)

        $serverFqdn = $row.TargetServerFQDN.Trim()
        $accessTypes = @($row.AccessType)

        if ([string]::IsNullOrWhiteSpace($tenantId) -or
            [string]::IsNullOrWhiteSpace($subscriptionId) -or
            [string]::IsNullOrWhiteSpace($serverName) -or
            [string]::IsNullOrWhiteSpace($loginName) -or
            [string]::IsNullOrWhiteSpace($serverFqdn) -or
            [string]::IsNullOrWhiteSpace($database)) {
            throw "JSON item contains empty required values. Application='$($row.Application)', Login='$loginName', Database='$database'."
        }

        $sqlToken = if ($AuthType -eq 'Entra') { Get-SqlAccessToken } else { '' }

        if ($loginType -eq 'SqlLogin') {
            $secretCacheKey = "{0}|{1}|{2}|{3}" -f $tenantId, $subscriptionId, $vaultName, $secretName
            if (-not $secretCache.ContainsKey($secretCacheKey)) {
                $secretCache[$secretCacheKey] = Get-KeyVaultSecretPlainText -VaultName $vaultName -SecretName $secretName
            }
            $password = $secretCache[$secretCacheKey]
        }

        $loginKey = "{0}|{1}|{2}|{3}|{4}" -f $tenantId, $subscriptionId, $serverFqdn, $SqlPort, $loginName
        $loginAction = "AlreadyExists"
        if (-not $loginInitialized.ContainsKey($loginKey)) {
            if ($PSCmdlet.ShouldProcess("$serverFqdn/master", "Provision $loginType '$loginName'")) {
                if ($loginType -eq 'SqlLogin') {
                    $loginAction = New-OrUpdate-SqlLogin -ServerName $serverFqdn -Port $SqlPort -AccessToken $sqlToken -LoginName $loginName -Password $password -ResetIfExists:$row.ForcePasswordReset
                }
                elseif ($loginType -eq 'WindowsAD') {
                    $loginAction = Ensure-WindowsADLogin -ServerName $serverFqdn -Port $SqlPort -AccessToken $sqlToken `
                        -LoginName $loginName -TargetWindowsDomain $Domain
                }
                else {
                    $principalType = if ($loginType -eq 'EntraGroup') { 'X' } else { 'E' }
                    $loginAction = Ensure-ExternalLogin -ServerName $serverFqdn -Port $SqlPort -AccessToken $sqlToken `
                        -LoginName $loginName -ObjectId $row.ObjectId -PrincipalType $principalType
                }
            }
            else {
                $loginAction = "SkippedByWhatIf"
            }

            $loginInitialized[$loginKey] = $loginAction
        }
        else {
            $loginAction = [string]$loginInitialized[$loginKey]
        }

        $dbResult = [PSCustomObject]@{
            UserAction = "AlreadyExists"
            AccessActions = @()
        }
        if ($ServerOnly) {
            $dbResult = [PSCustomObject]@{ UserAction = 'DeferredUntilAll'; AccessActions = @() }
            Write-Host "Deferred database access for '$loginName' in '$database' until All execution after restore."
        }
        elseif ($PSCmdlet.ShouldProcess("$serverFqdn/$database", "Ensure user '$loginName' and apply access '$($accessTypes -join ',')'")) {
            $principalType = if ($loginType -eq 'SqlLogin') { 'S' } elseif ($loginType -eq 'WindowsAD') { 'U' } elseif ($loginType -eq 'EntraGroup') { 'X' } else { 'E' }
            $dbResult = Ensure-DatabaseUserAndAccess -ServerName $serverFqdn -Port $SqlPort -Database $database -AccessToken $sqlToken -LoginName $loginName -AccessTypes $accessTypes -PrincipalType $principalType
        }
        else {
            $dbResult = [PSCustomObject]@{
                UserAction = "SkippedByWhatIf"
                AccessActions = @()
            }
        }

        $accessActions = @($dbResult.AccessActions)

        $accessSummary = if ($accessActions.Count -gt 0) {
            ($accessActions | ForEach-Object { "{0}:{1}" -f $_.AccessType, $_.Action }) -join "; "
        }
        else {
            "None"
        }

        $changedAccessActions = @($accessActions | Where-Object { $_.Action -in @("Assigned", "Granted") })

        $rowHadChanges =
            ($loginAction -in @("Created", "PasswordReset")) -or
            ($dbResult.UserAction -eq "Created") -or
            ($changedAccessActions.Count -gt 0)

        $migrationDetails += [PSCustomObject]@{
            LoginName = $loginName
            LoginType = $loginType
            UserName = $loginName
            Database = $database
            AccessType = ($accessTypes -join ",")
            Server = $serverFqdn
            LoginAction = $loginAction
            UserAction = $dbResult.UserAction
            AccessAction = $accessSummary
            Status = if ($rowHadChanges) { "Changed" } else { "Skipped" }
        }

        if ($rowHadChanges) {
            Write-Host ("Applied changes for login '{0}' on database '{1}' at server '{2}' (Login={3}, User={4}, Access={5})." -f $loginName, $database, $serverFqdn, $loginAction, $dbResult.UserAction, $accessSummary) -ForegroundColor Green
        }
        else {
            Write-Host ("Skipped login '{0}' for database '{1}' on server '{2}' (already present; no action taken)." -f $loginName, $database, $serverFqdn) -ForegroundColor Yellow
            $skippedCount++
        }

        $successCount++
    }
    catch {
        $safeError = $_.Exception.Message
        if ($password) {
            $safeError = $safeError.Replace($password, '[REDACTED]').Replace(($password -replace "'", "''"), '[REDACTED]')
        }
        $errorDetails = @{
            Application = $row.Application
            LoginName = if ($null -ne $loginName) { $loginName } else { "Unknown" }
            Database = if ($null -ne $database) { $database } else { "Unknown" }
            Server = if ($null -ne $serverName) { $serverName } else { "Unknown" }
            Error = $safeError
        }
        $failedRows += $errorDetails
        Write-Host ("ERROR processing row: Application='$($errorDetails.Application)', Login='$($errorDetails.LoginName)', Database='$($errorDetails.Database)', Server='$($errorDetails.Server)'") -ForegroundColor Red
        Write-Host ("  Details: $($errorDetails.Error)") -ForegroundColor Red
    }
    finally { $password = $null; $sqlToken = $null }
}

Write-Host ""
Write-Host "=== Login Provisioning Summary ===" -ForegroundColor Cyan
Write-Host "Successful: $successCount"
Write-Host "Skipped (no action): $skippedCount"
Write-Host "Failed: $($failedRows.Count)"

if ($migrationDetails.Count -gt 0) {
    Write-Host ""
    Write-Host "Login Provisioning Summary Details" -ForegroundColor Magenta
    Write-Host "-----------------------------------" -ForegroundColor Magenta
    $migrationDetails |
        Sort-Object LoginName, Database |
        Format-Table -Property LoginName, LoginType, Database, AccessType, Server, Status, LoginAction, UserAction -AutoSize |
        Out-Host

    $migrationDetails |
        Sort-Object LoginName, Database |
        Export-Csv -Path $summaryOutputPath -NoTypeInformation -Encoding UTF8
}
else {
    @(
        [PSCustomObject]@{
            LoginName = ""
            UserName = ""
            Database = ""
            AccessType = ""
            Server = ""
        }
    ) | Export-Csv -Path $summaryOutputPath -NoTypeInformation -Encoding UTF8
}

Write-Host ""
Write-Host ("Summary CSV exported to: {0}" -f $summaryOutputPath) -ForegroundColor Cyan

if ($failedRows.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed rows (details):" -ForegroundColor Yellow
    foreach ($failedRow in $failedRows) {
        Write-Host "  - Application: $($failedRow.Application), Login: $($failedRow.LoginName), Database: $($failedRow.Database), Server: $($failedRow.Server)"
        Write-Host "    Error: $($failedRow.Error)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host 'Completed login provisioning from JSON configuration.'

if ($failedRows.Count -gt 0) {
    throw "$($failedRows.Count) login provisioning row(s) failed. Review the transcript."
}
}
finally {
    $secretCache.Clear()
    Stop-Transcript | Out-Null
}
}
#endregion Main Execution