#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    $Scripts = Join-Path $PSScriptRoot '..\scripts'
    . (Join-Path $Scripts 'Common\ServerObjects.Helpers.ps1')
    . (Join-Path $Scripts 'Common\ServerObjects.Configuration.Helpers.ps1')
    function Get-AzContext { [CmdletBinding()]param() throw 'Unmocked Azure call' }
    function Set-AzContext { [CmdletBinding(SupportsShouldProcess)]param($TenantId, $SubscriptionId, $Scope) throw 'Unmocked Azure call' }
    function Get-AzKeyVaultSecret { [CmdletBinding()]param($VaultName, $Name) throw 'Unmocked Azure call' }
    function Get-AzADUser { [CmdletBinding()]param($ObjectId, $UserPrincipalName) throw 'Unmocked directory call' }
    function Get-AzADGroup { [CmdletBinding()]param($ObjectId, $DisplayName) throw 'Unmocked directory call' }
    function Get-AzADServicePrincipal { [CmdletBinding()]param($ObjectId, $DisplayName) throw 'Unmocked directory call' }
}

Describe 'SQL preflight diagnostic details' -Tag 'Unit' {
    BeforeAll {
        function Invoke-Sqlcmd {
            [CmdletBinding()]
            param($ServerInstance, $Database, $Query, $ConnectionTimeout, $QueryTimeout, $AccessToken, [pscredential]$Credential,
                [switch]$AbortOnError, [string]$Encrypt, [switch]$EncryptConnection, [switch]$TrustServerCertificate)
            throw 'Unmocked SQL call'
        }
        function Get-AzAccessToken { [CmdletBinding()]param($ResourceUrl) throw 'Unmocked token call' }
    }
    BeforeEach {
        Mock Import-Module {}
        Mock Get-AzContext { [pscustomobject]@{ Tenant = @{ Id = 'tenant' } } }
        Mock Set-AzContext {}
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'TOKEN_MUST_NOT_APPEAR' } }
    }
    It 'Reports endpoint, database, authentication and original failure for <Authentication>' -ForEach @(
        @{ Authentication = 'Windows integrated'; Tenant = '' },
        @{ Authentication = 'Microsoft Entra access token'; Tenant = 'tenant' }
    ) {
        Mock Invoke-Sqlcmd { throw [TimeoutException]::new('TCP connection attempt timed out') }
        $Failure = $null
        try {
            Invoke-ServerObjectPreflightQuery -Server 'tcp:target.example,3342' -Database AppDb -Query 'SELECT 1;' `
                -TenantId $Tenant -SubscriptionId subscription
        }
        catch { $Failure = $_ }
        $Failure | Should -Not -BeNullOrEmpty
        $Failure.FullyQualifiedErrorId | Should -Match ServerObjectSqlPreflightFailed
        $Failure.Exception.Message | Should -Match "ServerInstance='tcp:target.example,3342'"
        $Failure.Exception.Message | Should -Match "Database='AppDb'"
        $Failure.Exception.Message | Should -Match ([regex]::Escape("Authentication='$Authentication'"))
        $Failure.Exception.Message | Should -Match 'ConnectionTimeout=15s'
        $Failure.Exception.Message | Should -Match 'TCP connection attempt timed out'
        $Failure.Exception.Message | Should -Not -Match 'TOKEN_MUST_NOT_APPEAR|SELECT 1'
        $Failure.Exception.InnerException | Should -BeOfType ([TimeoutException])
        $Failure.TargetObject.ServerInstance | Should -Be 'tcp:target.example,3342'
    }
    It 'Preserves successful query output' {
        Mock Invoke-Sqlcmd { [pscustomobject]@{ CanConnect = 1 } }
        (Invoke-ServerObjectPreflightQuery -Server source -Query 'SELECT 1;').CanConnect | Should -Be 1
    }
    It 'Uses SQL credentials without acquiring an Entra token and keeps TLS validation' {
        $SqlCredential = [pscredential]::new('offline-admin', (ConvertTo-SecureString 'offline-test-password' -AsPlainText -Force))
        Mock Invoke-Sqlcmd {}
        Invoke-ServerObjectPreflightQuery -Server target -Query 'SELECT 1;' -SqlCredential $SqlCredential
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
            $Credential.UserName -eq 'offline-admin' -and -not $AccessToken -and
            $Encrypt -eq 'Mandatory' -and -not $TrustServerCertificate
        }
        Should -Invoke Get-AzAccessToken -Times 0 -Exactly
    }
    It 'Rejects mixed SQL credential and Entra authentication before connecting' {
        $SqlCredential = [pscredential]::new('offline-admin', (ConvertTo-SecureString 'offline-test-password' -AsPlainText -Force))
        Mock Invoke-Sqlcmd {}
        { Invoke-ServerObjectPreflightQuery -Server target -SqlCredential $SqlCredential -TenantId tenant } |
            Should -Throw '*cannot be combined*'
        Should -Invoke Invoke-Sqlcmd -Times 0 -Exactly
    }
    It 'Requests encryption and explicit certificate validation by default' {
        Mock Invoke-Sqlcmd {}
        Invoke-ServerObjectPreflightQuery -Server source -Query 'SELECT 1;'
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
            $Encrypt -eq 'Mandatory' -and -not $EncryptConnection -and -not $TrustServerCertificate
        }
    }
    It 'Allows an explicit certificate override without disabling encryption or hiding errors' {
        Mock Invoke-Sqlcmd { throw 'SQL permission denied' }
        { Invoke-ServerObjectPreflightQuery -Server source -Query 'SELECT 1;' -TrustServerCertificate $true } |
            Should -Throw '*TrustServerCertificate=True*SQL permission denied*'
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
            $Encrypt -eq 'Mandatory' -and -not $EncryptConnection -and $TrustServerCertificate
        }
    }
    It 'Requests encryption with the legacy cmdlet switch when Encrypt is unavailable' {
        Mock Get-Command { [pscustomobject]@{ Parameters = @{} } } -ParameterFilter { $Name -eq 'Invoke-Sqlcmd' }
        Mock Invoke-Sqlcmd {}
        Invoke-ServerObjectPreflightQuery -Server source -Query 'SELECT 1;' -TrustServerCertificate $true
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
            $EncryptConnection -and -not $Encrypt -and $TrustServerCertificate
        }
    }
}

Describe 'Whole-batch server-object validation' -Tag 'Unit' {
    BeforeEach {
        $Item = Read-ServerObjectItems -Path (Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json') -ItemId MI-Objects
        $Configuration = [pscustomobject]@{ Items = @((ConvertTo-ServerObjectLegacyItem -Item $Item)) }
        $Configuration.Items[0].SQLOperatorsMigrationFlag = 'No'
        $Configuration.Items[0].SQLAlertsMigrationFlag = 'No'
        $Row = $Configuration.Items[0]
        $Row.TargetServerName = 'target.example'
        $Second = $Row | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $Second.TargetServerName = 'second.example'
        $Configuration.Items = @($Row, $Second)
        $Options = @{ OutputJsonPath = '' }
        Mock Import-Module {}
        Mock Assert-ServiceOutputPath {}
        Mock Assert-ServerObjectSqlAccess {}
        Mock Invoke-ServerObjectPreflightQuery {
            if ($Query -like '*state_desc*') {
                [pscustomobject]@{ name = 'MIGRDEMO'; State = 'ONLINE' }
                [pscustomobject]@{ name = 'CDC_Director_PRO'; State = 'ONLINE' }
            }
        }
        Mock Write-Warning {}
    }
    It 'Validates all mixed-platform targets before returning to the dispatcher' {
        $Row.TargetExecutionFlag = 'Yes'
        $Second.TargetExecutionFlag = 'Yes'
        $Second.TargetType = 'SQLVM'
        Mock Assert-ServerObjectSqlAccess {
            if ($Server -eq 'second.example') { throw 'Second target denied access' }
        }
        { Invoke-ServerObjectPreflight -Operation 'Invoke-MigrateServerObjects-OnPrem-AzSQL' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts } |
            Should -Throw '*Second target denied access*'
        Should -Invoke Assert-ServerObjectSqlAccess -ParameterFilter { $Server -eq 'target.example' }
        Should -Invoke Assert-ServerObjectSqlAccess -ParameterFilter { $Server -eq 'second.example' }
    }
    It 'Rejects a later invalid flag before any source, target, or module access' {
        $Second.SQLLoginsMigrationFlag = 'Maybe'
        { Invoke-ServerObjectPreflight -Operation 'Invoke-MigrateServerObjects-OnPrem-AzSQL' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts } |
            Should -Throw '*SQLLoginsMigrationFlag*'
        Should -Invoke Import-Module -Times 0 -Exactly
        Should -Invoke Assert-ServerObjectSqlAccess -Times 0 -Exactly
    }
    It 'Validates every source database and fails on missing or offline databases' {
        Mock Invoke-ServerObjectPreflightQuery { [pscustomobject]@{ name = 'MIGRDEMO'; State = 'OFFLINE' } }
        { Invoke-ServerObjectPreflight -Operation 'Invoke-MigrateServerObjects-OnPrem-AzSQL' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts } |
            Should -Throw '*missing or offline*'
    }
    It 'Does not connect to targets in generate-only mode' {
        Invoke-ServerObjectPreflight -Operation 'Invoke-MigrateServerObjects-OnPrem-AzSQL' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts
        Should -Invoke Assert-ServerObjectSqlAccess -Times 0 -Exactly -ParameterFilter { $Server -in @('target.example', 'second.example') }
    }
    It 'Uses the source override for all source checks but never for target checks on <Platform>' -ForEach @(
        @{ Platform = 'SQLVM' }, @{ Platform = 'SQLMI' }
    ) {
        $Configuration.Items = @($Row)
        $Row.TargetType = $Platform
        $Row.SourceTrustServerCertificate = $true
        $Row.TargetExecutionFlag = 'Yes'
        Invoke-ServerObjectPreflight -Operation "Invoke-MigrateServerObjects-OnPrem-Az$Platform" -Configuration $Configuration -Options $Options -ScriptsPath $Scripts
        Should -Invoke Assert-ServerObjectSqlAccess -Times 0 -Exactly -ParameterFilter {
            $Server -ne 'target.example' -and -not $TrustServerCertificate
        }
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0 -Exactly -ParameterFilter {
            $Server -ne 'target.example' -and -not $TrustServerCertificate
        }
        Should -Invoke Assert-ServerObjectSqlAccess -Times 3 -Exactly -ParameterFilter {
            $Server -eq 'target.example' -and -not $TrustServerCertificate
        }
        Should -Invoke Assert-ServerObjectSqlAccess -Times 0 -Exactly -ParameterFilter {
            $Server -eq 'target.example' -and $TrustServerCertificate
        }
        Should -Invoke Assert-ServerObjectSqlAccess -ParameterFilter { $Server -ne 'target.example' -and $TrustServerCertificate }
        Should -Invoke Invoke-ServerObjectPreflightQuery -ParameterFilter { $Server -ne 'target.example' -and $TrustServerCertificate }
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*development certificate-trust override*' }
    }
    It 'Rejects a non-Boolean legacy source override before module or SQL access' {
        $Second.SourceTrustServerCertificate = 'true'
        { Invoke-ServerObjectPreflight -Operation 'Invoke-MigrateServerObjects-OnPrem-AzSQL' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts } |
            Should -Throw '*SourceTrustServerCertificate must be Boolean*'
        Should -Invoke Import-Module -Times 0 -Exactly
        Should -Invoke Assert-ServerObjectSqlAccess -Times 0 -Exactly
    }
    It 'Checks all execute-only SQL files before any component can run' {
        $Row.OnlyTargetExecutionFlag = 'Yes'
        $Second.OnlyTargetExecutionFlag = 'Yes'
        $Row.SQLAgentJobsMigrationFlag = 'No'
        $Second.SQLAgentJobsMigrationFlag = 'No'
        Mock Assert-ServiceReadableFile { throw 'Execute-only SQL input is missing' }
        { Invoke-ServerObjectPreflight -Operation 'Invoke-MigrateServerObjects-OnPrem-AzSQL' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts } |
            Should -Throw '*Execute-only SQL input is missing*'
        Should -Invoke Assert-ServiceReadableFile -Times 1 -Exactly -ParameterFilter {
            $Path -like '*AzSQLMI\source_instance\SQL Logins MI\source_instance_SQLLoginsMI.sql'
        }
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0 -Exactly -ParameterFilter { $Server -notin @('target.example', 'second.example') }
    }
    It 'Requires server-security access for Database scope and checks only selected user database security' {
        $Row.SQLLoginsMigrationScope = 'Database'
        $Second.SQLLoginsMigrationScope = 'Database'
        $Row.TargetExecutionFlag = 'Yes'
        Invoke-ServerObjectPreflight -Operation 'Invoke-MigrateServerObjects-OnPrem-AzSQL' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts
        Should -Invoke Assert-ServerObjectSqlAccess -Times 2 -Exactly -ParameterFilter { $RequireLoginHashes }
        Should -Invoke Assert-ServerObjectSqlAccess -Times 1 -Exactly -ParameterFilter {
            $Server -eq 'target.example' -and 'ALTER ANY LOGIN' -in $ServerPermissions
        }
        Should -Invoke Assert-ServerObjectSqlAccess -Times 0 -Exactly -ParameterFilter {
            $Database -in @('master', 'msdb', 'model', 'tempdb') -and $DatabasePermissions.Count
        }
    }
    It 'Checks source and target permissions in all four system databases for All scope' {
        Mock Invoke-ServerObjectPreflightQuery {
            if ($Query -like '*state_desc*') {
                @('master', 'msdb', 'model', 'tempdb', 'MIGRDEMO', 'CDC_Director_PRO') |
                    ForEach-Object { [pscustomobject]@{ name = $_; State = 'ONLINE' } }
            }
        }
        $Row.TargetExecutionFlag = 'Yes'
        Invoke-ServerObjectPreflight -Operation 'Invoke-MigrateServerObjects-OnPrem-AzSQL' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts
        foreach ($SystemName in @('master', 'msdb', 'model', 'tempdb')) {
            Should -Invoke Assert-ServerObjectSqlAccess -Times 2 -Exactly -ParameterFilter {
                $Database -eq $SystemName -and 'VIEW DEFINITION' -in $DatabasePermissions
            }
            Should -Invoke Assert-ServerObjectSqlAccess -Times 1 -Exactly -ParameterFilter {
                $Server -eq 'target.example' -and $Database -eq $SystemName -and 'CONTROL' -in $DatabasePermissions
            }
        }
    }
    It 'Checks system database security during execute-only without reconnecting to the source' {
        $Row.OnlyTargetExecutionFlag = 'Yes'
        $Second.OnlyTargetExecutionFlag = 'Yes'
        Mock Assert-ServiceReadableFile {}
        Mock Invoke-ServerObjectPreflightQuery {
            @('master', 'msdb', 'model', 'tempdb') | ForEach-Object { [pscustomobject]@{ name = $_ } }
        }
        Invoke-ServerObjectPreflight -Operation 'Invoke-MigrateServerObjects-OnPrem-AzSQL' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0 -Exactly -ParameterFilter { $Server -notin @('target.example', 'second.example') }
        Should -Invoke Assert-ServerObjectSqlAccess -Times 2 -Exactly -ParameterFilter {
            $Database -eq 'tempdb' -and 'CONTROL' -in $DatabasePermissions
        }
    }
}

Describe 'Key Vault login validation before any provisioning' -Tag 'Unit' {
    BeforeEach {
        $Item = Read-ServerObjectItems -Path (Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json') -ItemId MI-Objects
        $AllRows = @(Get-ServerObjectProvisioningItems -Item $Item)
        $Configuration = [pscustomobject]@{ Items = @($AllRows | Where-Object LoginName -eq dbmigration) }
        foreach ($Item in $Configuration.Items) {
            $Item.LoginName = 'application'
            $Item.KeyVaultName = 'vault'
            $Item.SecretName = 'password'
        }
        $Options = @{ SqlPort = 1433; OutputRoot = (Join-Path $TestDrive 'preflight') }
        Mock Import-Module {}
        Mock Get-AzContext { [pscustomobject]@{ Tenant = @{ Id = 'b7d7daca-8689-49f9-8a9b-d20adf81c78b' } } }
        Mock Set-AzContext {}
        Mock Get-AzKeyVaultSecret {
            [pscustomobject]@{
                SecretValue = (ConvertTo-SecureString 'offline-test-value' -AsPlainText -Force)
                Enabled = $true; Expires = $null; NotBefore = $null
            }
        }
        Mock Assert-ServerObjectSqlAccess {}
        Mock Invoke-ServerObjectPreflightQuery { [pscustomobject]@{ name = 'db_datareader' } }
        Mock Resolve-ServerObjectExternalPrincipal { 'ec787112-0f22-4785-89a5-cb9ee4807a96' }
    }
    It 'Works under the entry point strict mode without needing an OutputJsonPath option' {
        Set-StrictMode -Version Latest
        Invoke-ServerObjectPreflight -Operation 'Invoke-ProvisionLogins-AzSql' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts
        Should -Invoke Get-AzKeyVaultSecret -Times 2 -Exactly
        Should -Invoke Assert-ServerObjectSqlAccess -Times 2 -Exactly
    }
    It 'Rejects an inaccessible later secret before returning to the provisioning loop' {
        $Configuration.Items[1].SecretName = 'denied'
        Mock Get-AzKeyVaultSecret { throw 'Secret access denied' } -ParameterFilter { $Name -eq 'denied' }
        { Invoke-ServerObjectPreflight -Operation 'Invoke-ProvisionLogins-AzSql' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts } |
            Should -Throw '*Secret access denied*'
        Should -Invoke Get-AzKeyVaultSecret -Times 2 -Exactly
    }
    It 'Rejects unsupported roles and permissions before granting database access' {
        $Configuration.Items[1].AccessType = @('invalid_permission')
        { Invoke-ServerObjectPreflight -Operation 'Invoke-ProvisionLogins-AzSql' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts } |
            Should -Throw '*Unknown database role or permission*'
    }
    It 'Normalizes both metadata collations and accepts roles and permissions for <TargetType>' -ForEach @(
        @{ TargetType = 'SQLVM' },
        @{ TargetType = 'SQLMI' }
    ) {
        $Configuration.Items = @($Configuration.Items[0])
        $Configuration.Items[0].TargetType = $TargetType
        $Configuration.Items[0].AccessType = @('db_datareader', 'CONNECT')
        Mock Invoke-ServerObjectPreflightQuery {
            [pscustomobject]@{ name = 'db_datareader' }
            [pscustomobject]@{ name = 'CONNECT' }
        }
        Invoke-ServerObjectPreflight -Operation 'Invoke-ProvisionLogins-AzSql' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 1 -Exactly -ParameterFilter {
            $Database -eq $Configuration.Items[0].Database -and
            $Query -match "(?is)SELECT name COLLATE DATABASE_DEFAULT AS name FROM sys\.database_principals WHERE type = 'R'\s+UNION\s+SELECT permission_name COLLATE DATABASE_DEFAULT AS name FROM sys\.fn_builtin_permissions\('DATABASE'\)"
        }
    }
    It 'Resolves external identities without importing or reading Key Vault' {
        $Configuration.Items = @($AllRows | Where-Object LoginType -eq EntraUser)
        Invoke-ServerObjectPreflight -Operation 'Invoke-ProvisionLogins-AzSql' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts
        Should -Invoke Get-AzKeyVaultSecret -Times 0 -Exactly
        Should -Invoke Import-Module -Times 0 -Exactly -ParameterFilter { $Name -eq 'Az.KeyVault' }
        Should -Invoke Resolve-ServerObjectExternalPrincipal -Times 2 -Exactly
        $Configuration.Items[0].ObjectId | Should -Be 'ec787112-0f22-4785-89a5-cb9ee4807a96'
    }
    It 'Uses Windows authentication for VM provisioning and Entra tokens for MI provisioning' {
        $Configuration.Items[1].TargetType = 'SQLVM'
        Invoke-ServerObjectPreflight -Operation 'Invoke-ProvisionLogins-AzSql' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts
        Should -Invoke Assert-ServerObjectSqlAccess -Times 1 -Exactly -ParameterFilter { $TenantId -eq '' -or $null -eq $TenantId }
        Should -Invoke Assert-ServerObjectSqlAccess -Times 1 -Exactly -ParameterFilter { $TenantId -eq 'b7d7daca-8689-49f9-8a9b-d20adf81c78b' }
    }
    It 'Applies the explicit target TLS override to every provisioning validation query' {
        $Options.TargetTrustServerCertificate = $true
        Invoke-ServerObjectPreflight -Operation 'Invoke-ProvisionLogins-AzSql' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts
        Should -Invoke Assert-ServerObjectSqlAccess -Times 2 -Exactly -ParameterFilter { $TrustServerCertificate }
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 2 -Exactly -ParameterFilter { $TrustServerCertificate }
    }
    It 'Keeps Server-only provisioning in master and uses the target TLS policy' {
        $Options.TargetTrustServerCertificate = $true
        $Options.ServerOnly = $true
        Invoke-ServerObjectPreflight -Operation 'Invoke-ProvisionLogins-AzSql' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts
        Should -Invoke Assert-ServerObjectSqlAccess -Times 2 -Exactly -ParameterFilter { $TrustServerCertificate -and $Database -eq 'master' }
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0 -Exactly
    }
    It 'Fails when a configured external principal cannot be resolved' {
        $Configuration.Items = @($AllRows | Where-Object LoginType -eq EntraUser)
        Mock Resolve-ServerObjectExternalPrincipal { throw 'Identity not found' }
        { Invoke-ServerObjectPreflight -Operation 'Invoke-ProvisionLogins-AzSql' -Configuration $Configuration -Options $Options -ScriptsPath $Scripts } |
            Should -Throw '*Identity not found*'
        Should -Invoke Assert-ServerObjectSqlAccess -Times 0 -Exactly
    }
}

Describe 'External principal lookup' -Tag 'Unit' {
    BeforeEach {
        $Id = 'ec787112-0f22-4785-89a5-cb9ee4807a96'
        Mock Get-AzADUser { [pscustomobject]@{ Id = $Id; UserPrincipalName = 'user@example.com' } }
        Mock Get-AzADGroup { [pscustomobject]@{ Id = $Id; DisplayName = 'Readers' } }
        Mock Get-AzADServicePrincipal { [pscustomobject]@{ Id = $Id; DisplayName = 'app-identity'; ServicePrincipalType = 'ManagedIdentity' } }
    }
    It 'Resolves <Type> as the expected directory object type' -ForEach @(
        @{ Type = 'EntraUser'; Name = 'user@example.com' },
        @{ Type = 'EntraGroup'; Name = 'Readers' },
        @{ Type = 'ManagedIdentity'; Name = 'app-identity' }
    ) {
        $Login = [pscustomobject]@{ LoginName = $Name; LoginType = $Type; ObjectId = '' }
        Resolve-ServerObjectExternalPrincipal -Login $Login | Should -Be $Id
    }
    It 'Checks an explicit object ID instead of using a display-name search' {
        $Login = [pscustomobject]@{ LoginName = 'app-identity'; LoginType = 'ManagedIdentity'; ObjectId = $Id }
        Resolve-ServerObjectExternalPrincipal -Login $Login | Should -Be $Id
        Should -Invoke Get-AzADServicePrincipal -Times 1 -Exactly -ParameterFilter { $ObjectId -eq $Id -and -not $DisplayName }
    }
    It 'Rejects duplicate managed-identity names rather than guessing' {
        Mock Get-AzADServicePrincipal {
            [pscustomobject]@{ Id = $Id; DisplayName = 'app-identity'; ServicePrincipalType = 'ManagedIdentity' }
            [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); DisplayName = 'app-identity'; ServicePrincipalType = 'ManagedIdentity' }
        }
        { Resolve-ServerObjectExternalPrincipal -Login ([pscustomobject]@{ LoginName = 'app-identity'; LoginType = 'ManagedIdentity'; ObjectId = '' }) } |
            Should -Throw '*Cannot uniquely resolve*'
    }
    It 'Rejects an ordinary application when a managed identity is requested' {
        Mock Get-AzADServicePrincipal { [pscustomobject]@{ Id = $Id; DisplayName = 'app-identity'; ServicePrincipalType = 'Application' } }
        { Resolve-ServerObjectExternalPrincipal -Login ([pscustomobject]@{ LoginName = 'app-identity'; LoginType = 'ManagedIdentity'; ObjectId = '' }) } |
            Should -Throw '*Cannot uniquely resolve*'
    }
}

Describe 'Read-only SQL permission checks' -Tag 'Unit' {
    BeforeEach {
        Mock Invoke-ServerObjectPreflightQuery {
            if ($Query -like '*AS Allowed*') { [pscustomobject]@{ Allowed = 1 } }
            else { [pscustomobject]@{ IsSysadmin = 0; CanConnect = 1 } }
        }
    }
    It 'Accepts a non-sysadmin with the permissions required by login-only operations' {
        Assert-ServerObjectSqlAccess -Server target -Database application -ServerPermissions @('ALTER ANY LOGIN') -DatabasePermissions @('CONTROL')
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 3 -Exactly
    }
    It 'Carries the certificate policy through every permission probe' {
        Assert-ServerObjectSqlAccess -Server source -Database application -ServerPermissions @('VIEW ANY DEFINITION') `
            -DatabasePermissions @('VIEW DEFINITION') -RequireLoginHashes -TrustServerCertificate $true
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 4 -Exactly -ParameterFilter { $TrustServerCertificate }
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0 -Exactly -ParameterFilter { -not $TrustServerCertificate }
    }
    It 'Rejects missing server privileges and inaccessible SQL login hashes explicitly' {
        Mock Invoke-ServerObjectPreflightQuery { [pscustomobject]@{ Allowed = 0 } } -ParameterFilter { $Query -like '*AS Allowed*' }
        { Assert-ServerObjectSqlAccess -Server target -ServerPermissions @('ALTER ANY LOGIN') } | Should -Throw '*Missing server permission*'
        { Assert-ServerObjectSqlAccess -Server source -RequireLoginHashes } | Should -Throw '*Cannot read SQL login password hashes*'
    }
    It 'Requires sysadmin only for operations that import arbitrary server-owned Agent or Mail objects' {
        { Assert-ServerObjectSqlAccess -Server target -RequireSysadmin } | Should -Throw '*sysadmin is required*'
        Assert-ServerObjectSqlAccess -Server target
    }
}
