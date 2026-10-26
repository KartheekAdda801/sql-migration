#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Common\ServerObjects.SecuritySnapshot.Helpers.ps1')
    function Escape-SqlLiteral { param([string]$Value) $Value.Replace("'", "''") }
    function Escape-SqlBracket { param([string]$Value) $Value.Replace(']', ']]') }
    function Invoke-SqlcmdLogged {
        [CmdletBinding()]
        param($ServerInstance, $Database, $Query, $Context)
        throw "Unexpected source access: $Context"
    }
    function Get-AzContext { [CmdletBinding()] param() throw 'Unmocked Azure call' }
    function Get-AzADUser { [CmdletBinding()] param($UserPrincipalName) throw 'Unmocked Azure call' }
    function Get-AzADGroup { [CmdletBinding()] param($DisplayName) throw 'Unmocked Azure call' }
    $Vm = [pscustomobject]@{ TargetType = 'SQLVM'; SQLLoginsMigrationScope = 'Server'; SourceListofDatabases = @('SelectedOnly') }
    $Mi = [pscustomobject]@{
        TargetType = 'SQLMI'; SQLLoginsMigrationScope = 'All'; SourceListofDatabases = @('SelectedOnly')
        JobOwnerUpnSuffix = 'cloud.example'; TenantId = 'tenant'; SubscriptionId = 'subscription'
    }
    function New-TestPrincipal {
        param([string]$Name = "sql'login]", [string]$Type = 'S')
        [pscustomobject]@{
            PrincipalId = 300; Name = $Name; Type = $Type; IsFixedRole = $false
            IsDisabled = $true; Sid = '0x00112233445566778899AABBCCDDEEFF'
            DefaultDatabase = 'UnselectedApp'; DefaultLanguage = 'us_english'
            PolicyChecked = $true; ExpirationChecked = $false; PasswordHash = '0x0200AABB'
            MustChange = 0; OwnerName = ''; CredentialName = ''
        }
    }
    function New-TestPermission {
        param([int]$Class = 1, [string]$State = 'D', [int]$MinorId = 2)
        [pscustomobject]@{
            Class = $Class; ClassDescription = 'OBJECT_OR_COLUMN'; State = $State
            PermissionName = 'SELECT'; GranteeName = "user]one"; GrantorName = 'dbo'
            MinorId = $MinorId; SchemaName = 'schema]one'; SecurableName = "object'name]"
            SecurableType = 'USER'; ColumnName = 'column]two'
        }
    }
}

Describe 'Complete source security capture' {
    BeforeEach {
        Mock Get-AzContext { throw 'Extraction must not access Azure' }
        Mock Get-AzADUser { throw 'Extraction must not access Entra' }
        $script:Principals = @(New-TestPrincipal)
        $script:Users = @([pscustomobject]@{
            PrincipalId = 10; Name = 'appuser'; Type = 'S'; Sid = '0x00112233445566778899AABBCCDDEEFF'
            AuthenticationType = 'INSTANCE'; LoginName = "sql'login]"; LoginType = 'S'
            DefaultSchema = 'dbo'; IsFixedRole = $false; OwnerName = ''; KeyName = ''
        })
        $script:PermissionRows = @(New-TestPermission)
        $script:CatalogQueries = @{}
        $script:Databases = @('master', 'tempdb', 'model', 'msdb', 'UnselectedApp') | ForEach-Object {
            [pscustomobject]@{ Name = $_; HasAccess = 1 }
        }
        Mock Invoke-SqlcmdLogged {
            $script:CatalogQueries[$Context] = $Query
            switch ($Context) {
                'SecuritySnapshot.Access' { [pscustomobject]@{ IsSysadmin = 1 } }
                'SecuritySnapshot.ServerPrincipals' { $script:Principals }
                'SecuritySnapshot.Databases' { $script:Databases }
                'SecuritySnapshot.DatabasePrincipals' { $script:Users }
                'SecuritySnapshot.DatabasePermissions' { $script:PermissionRows }
                'SecuritySnapshot.SchemaOwners' { [pscustomobject]@{ Name = 'appschema'; OwnerName = 'appuser' } }
                'SecuritySnapshot.ObjectOwners' { }
                'SecuritySnapshot.ServerMemberships' { }
                'SecuritySnapshot.ServerPermissions' { }
                'SecuritySnapshot.DatabaseMemberships' { }
                default { throw "Unexpected query $Context" }
            }
        }
    }
    It 'Captures every online database including all system databases, without execution filters' {
        $Blocks = @(Get-ServerObjectSecuritySnapshotBlocks -Server 'SOURCE\INSTANCE')
        @($Blocks | Where-Object Kind -eq 'DatabaseUser').Count | Should -Be 5
        foreach ($ExpectedDatabase in @('master', 'tempdb', 'model', 'msdb', 'UnselectedApp')) {
            Should -Invoke Invoke-SqlcmdLogged -ParameterFilter {
                $ServerInstance -eq 'SOURCE\INSTANCE' -and $Database -eq $ExpectedDatabase -and $Context -eq 'SecuritySnapshot.DatabasePrincipals'
            } -Times 1 -Exactly
        }
        $UserBlock = $Blocks | Where-Object { $_.Database -eq 'UnselectedApp' -and $_.Kind -eq 'DatabaseUser' }
        $UserBlock.ServerSafe | Should -BeFalse
        @($UserBlock.DependsOnDatabases) | Should -Be @('UnselectedApp')
        $SystemBlock = $Blocks | Where-Object { $_.Database -eq 'msdb' -and $_.Kind -eq 'DatabaseUser' }
        $SystemBlock.ServerSafe | Should -BeTrue
        @($SystemBlock.DependsOnDatabases) | Should -Be @('msdb')
        @($Blocks | Where-Object { $_.Component -ne 'SQLLogins' -or -not $_.SourceEnabled }).Count | Should -Be 0
    }
    It 'Preserves SQL hash/SID/policy and forces a pre-restore-safe master default' {
        $Block = Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' | Where-Object Kind -eq 'Login'
        $Block.Sql | Should -Match 'PASSWORD = 0x0200AABB HASHED, SID = 0x00112233445566778899AABBCCDDEEFF'
        $Block.Sql | Should -Match 'DEFAULT_DATABASE = \[master\]'
        $Block.Sql | Should -Not -Match 'DEFAULT_DATABASE = \[UnselectedApp\]'
        $Block.Sql | Should -Match "name = N'sql''login\]'"
        $Block.Sql | Should -Match 'CREATE LOGIN \[sql''login\]\]\]'
        $Block.Sql | Should -Match 'CHECK_POLICY = ON, CHECK_EXPIRATION = OFF'
        $Block.Sql | Should -Match 'BEGIN[\s\S]*CREATE LOGIN[\s\S]*ALTER LOGIN[\s\S]*DISABLE;[\s\S]*END'
        $Block.Metadata.DefaultDatabase | Should -Be 'UnselectedApp'
        $Block.ServerSafe | Should -BeTrue
        @($Block.DependsOnDatabases).Count | Should -Be 0
    }
    It 'Captures Windows identities raw without contacting AD, Entra, or target' {
        $script:Principals = @(New-TestPrincipal 'arbitrary-domain\alice' 'U')
        $script:Users = @()
        $Block = Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' | Where-Object Kind -eq 'Login'
        $Block.Name | Should -Be 'arbitrary-domain\alice'
        $Block.Metadata.Type | Should -Be 'U'
        $Block.Sql | Should -Match 'FROM WINDOWS WITH DEFAULT_DATABASE = \[master\]'
        Should -Invoke Get-AzContext -Times 0
        Should -Invoke Get-AzADUser -Times 0
    }
    It 'Preserves exact column securable, schema, DENY and grantor instead of broad database GRANT' {
        $Block = Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' |
            Where-Object { $_.Database -eq 'UnselectedApp' -and $_.Kind -eq 'DatabasePermission' }
        $Block.Sql | Should -Be "USE [UnselectedApp];`nDENY SELECT ON OBJECT::[schema]]one].[object'name]]] ([column]]two]) TO [user]]one] AS [dbo];"
        $Block.Metadata.Class | Should -Be 1
        $Block.Metadata.MinorId | Should -Be 2
    }
    It 'Normalizes every mixed-catalog CASE and COALESCE name operand to DATABASE_DEFAULT' {
        $null = @(Get-ServerObjectSecuritySnapshotBlocks 'SOURCE')
        $DatabasePermissions = $script:CatalogQueries['SecuritySnapshot.DatabasePermissions']
        foreach ($Expression in @(
            'OBJECT_SCHEMA_NAME(p.major_id)', 'SCHEMA_NAME(t.schema_id)', 'SCHEMA_NAME(x.schema_id)',
            'OBJECT_NAME(p.major_id)', 'sc.name', 'dp.name', 'ass.name', 't.name', 'x.name',
            'mt.name', 'ct.name', 'sv.name', 'rb.name', 'rt.name', 'fc.name', 'sk.name',
            'ce.name', 'ak.name', 'fs.name', 'sl.name', 'cr.name'
        )) {
            $DatabasePermissions | Should -Match (
                'THEN\s+' + [regex]::Escape($Expression) + '\s+COLLATE\s+DATABASE_DEFAULT'
            ) -Because "'$Expression' must not mix BIN and instance catalog collations in a CASE result"
        }
        $ServerPermissions = $script:CatalogQueries['SecuritySnapshot.ServerPermissions']
        foreach ($Expression in @('s.name', 'e.name')) {
            $ServerPermissions | Should -Match (
                'THEN\s+' + [regex]::Escape($Expression) + '\s+COLLATE\s+DATABASE_DEFAULT'
            )
        }
        $script:CatalogQueries['SecuritySnapshot.DatabasePrincipals'] | Should -Match (
            'COALESCE\(\s*c\.name\s+COLLATE\s+DATABASE_DEFAULT\s*,\s*k\.name\s+COLLATE\s+DATABASE_DEFAULT\s*\)'
        )
    }
    It 'Excludes built-in identities completely, including a renamed sa' {
        $P = New-TestPrincipal 'renamed-sa'; $P.PrincipalId = 1
        $script:Principals = @($P, (New-TestPrincipal 'NT SERVICE\SQLAgent' 'U'))
        $Blocks = @(Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' | Where-Object Kind -eq 'ProtectedPrincipal')
        $Blocks.Count | Should -Be 0
    }
    It 'Handles empty catalogs without null-shaped fake blocks' {
        $script:Principals = @(); $script:Users = @(); $script:PermissionRows = @(); $script:Databases = @()
        @(Get-ServerObjectSecuritySnapshotBlocks 'SOURCE').Count | Should -Be 0
    }
    It 'Fails before exposing partial output if an online database is inaccessible' {
        $script:Databases[-1].HasAccess = 0
        $Seen = [Collections.Generic.List[object]]::new()
        { Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' | ForEach-Object { $Seen.Add($_) } } |
            Should -Throw '*inaccessible*'
        $Seen.Count | Should -Be 0
    }
    It 'Propagates catalog errors instead of continuing with incomplete security' {
        Mock Invoke-SqlcmdLogged { throw 'catalog access denied' } -ParameterFilter { $Context -eq 'SecuritySnapshot.DatabasePrincipals' }
        { Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' } | Should -Throw '*catalog access denied*'
    }
    It 'Requires full catalog visibility' {
        Mock Invoke-SqlcmdLogged { [pscustomobject]@{ IsSysadmin = 0 } } -ParameterFilter { $Context -eq 'SecuritySnapshot.Access' }
        { Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' } | Should -Throw '*sysadmin*'
    }
    It 'Rejects missing password hashes rather than omitting SQL logins' {
        $script:Principals[0].PasswordHash = $null
        { Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' } | Should -Throw '*password hash*'
    }
    It 'Normalizes SQL DBNull fields rather than treating absent credentials as configured' {
        $script:Principals[0].CredentialName = [DBNull]::Value
        $script:Principals[0].OwnerName = [DBNull]::Value
        $script:Principals[0].MustChange = [DBNull]::Value
        $Blocks = @(Get-ServerObjectSecuritySnapshotBlocks 'SOURCE')
        ($Blocks | Where-Object Kind -eq 'Login').Metadata.OwnerName | Should -Be ''
        @($Blocks | Where-Object Kind -eq 'Login').Count | Should -Be 1
    }
    It 'Accepts real Invoke-Sqlcmd DataRow results with null catalog values' {
        $Table = [Data.DataTable]::new()
        foreach ($Column in @('PrincipalId', 'Name', 'Type', 'Sid', 'PasswordHash', 'CredentialName')) {
            $null = $Table.Columns.Add($Column, [string])
        }
        $script:PrincipalRow = $Table.NewRow()
        $script:PrincipalRow.PrincipalId = '300'; $script:PrincipalRow.Name = 'rowLogin'; $script:PrincipalRow.Type = 'S'
        $script:PrincipalRow.Sid = '0x00112233'; $script:PrincipalRow.PasswordHash = '0x0200AABB'
        Mock Invoke-SqlcmdLogged { $script:PrincipalRow } -ParameterFilter { $Context -eq 'SecuritySnapshot.ServerPrincipals' }
        $Block = Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' | Where-Object Kind -eq 'Login'
        $Block.Name | Should -Be 'rowLogin'
        $Block.Sql | Should -Match 'PASSWORD = 0x0200AABB HASHED'
    }
    It 'Rejects unsupported principal types and unsupported contained passwords' {
        $script:Users[0].Type = 'A'
        { Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' } | Should -Throw '*Unsupported database principal*'
        $script:Users[0].Type = 'S'; $script:Users[0].AuthenticationType = 'DATABASE'
        { Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' } | Should -Throw '*Contained SQL user*'
    }
    It 'Rejects unsupported permission classes instead of losing their securable' {
        $script:PermissionRows[0].Class = 999
        { Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' } | Should -Throw '*Unsupported database permission class 999*'
    }
    It 'Captures database-only Windows users raw even without a matching source login' {
        $script:Users[0].Type = 'U'; $script:Users[0].AuthenticationType = 'WINDOWS'
        $script:Users[0].Name = 'OTHER\direct'; $script:Users[0].LoginName = ''
        $Block = Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' |
            Where-Object { $_.Database -eq 'UnselectedApp' -and $_.Kind -eq 'DatabaseUser' }
        $Block.Metadata.WindowsWithoutLogin | Should -BeTrue
        $Block.Sql | Should -Match 'CREATE USER \[OTHER\\direct\] WITH DEFAULT_SCHEMA'
        Should -Invoke Get-AzADUser -Times 0
    }
    It 'Captures source external object IDs without directory lookup' {
        $script:Principals = @(New-TestPrincipal 'external-group' 'X')
        $script:Users = @()
        $Block = Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' | Where-Object Kind -eq 'Login'
        $Block.Metadata.EntraObjectId | Should -Be '33221100-5544-7766-8899-aabbccddeeff'
        $Block.Sql | Should -Match "FROM EXTERNAL PROVIDER WITH OBJECT_ID = '33221100-5544-7766-8899-aabbccddeeff'"
    }
    It 'Includes schema ownership after principals and before permissions' {
        $Blocks = @(Get-ServerObjectSecuritySnapshotBlocks 'SOURCE')
        $DbBlocks = @($Blocks | Where-Object Database -eq 'UnselectedApp')
        $DbBlocks[0].Kind | Should -Be 'DatabaseUser'
        $DbBlocks[1].Kind | Should -Be 'SchemaOwner'
        $DbBlocks[1].Sql | Should -Match 'ALTER AUTHORIZATION ON SCHEMA::\[appschema\] TO \[appuser\]'
        $DbBlocks[-1].Kind | Should -Be 'DatabasePermission'
    }
    It 'Protects public role ownership even when catalog is_fixed_role is false' {
        $script:Users = @([pscustomobject]@{
            PrincipalId = 0; Name = 'public'; Type = 'R'; IsFixedRole = $false; OwnerName = 'dbo'
        })
        $Blocks = @(Get-ServerObjectSecuritySnapshotBlocks 'SOURCE')
        @($Blocks | Where-Object Kind -eq 'DatabaseRoleOwner').Count | Should -Be 0
        @($Blocks | Where-Object Kind -eq 'DatabaseRole').Count | Should -Be 0
    }
    It 'Excludes immutable system schema ownership' {
        Mock Invoke-SqlcmdLogged { [pscustomobject]@{ Name = 'dbo'; OwnerName = 'dbo' } } -ParameterFilter {
            $Context -eq 'SecuritySnapshot.SchemaOwners'
        }
        $Blocks = @(Get-ServerObjectSecuritySnapshotBlocks 'SOURCE' | Where-Object Kind -eq 'SchemaOwner')
        $Blocks.Count | Should -Be 0
    }
    It 'Persists only JSON-compatible metadata and replays after round trip without source access' {
        $Blocks = @(Get-ServerObjectSecuritySnapshotBlocks 'SOURCE')
        $RoundTrip = @($Blocks | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
        Mock Invoke-SqlcmdLogged { throw 'Source has been decommissioned' }
        foreach ($Block in $RoundTrip) {
            ConvertTo-ServerObjectSecurityReplaySql $Block $Vm | Should -Be $Block.Sql
        }
    }
    It 'Filters SID-one, internal, service and key logins without discarding application-like names' {
        $Renamed = New-TestPrincipal 'renamed-admin'; $Renamed.Sid = '0x01'
        $script:Principals = @(
            $Renamed, (New-TestPrincipal '##MS_PolicySigningCertificate##' 'C'),
            (New-TestPrincipal 'BUILTIN\Administrators' 'G'), (New-TestPrincipal 'NT AUTHORITY\SYSTEM' 'U'),
            (New-TestPrincipal 'custom-key-login' 'K'), (New-TestPrincipal 'application-system-admin-service'),
            (New-TestPrincipal 'DOMAIN\service-admin' 'U'), (New-TestPrincipal 'DOMAIN\ApplicationGroup' 'G')
        )
        $script:Users = @(); $script:PermissionRows = @()
        $Blocks = @(Get-ServerObjectSecuritySnapshotBlocks SOURCE)
        @($Blocks | Where-Object Kind -eq Login).Name |
            Should -Be @('application-system-admin-service', 'DOMAIN\service-admin', 'DOMAIN\ApplicationGroup')
    }
    It 'Keeps user assignments to fixed roles and custom roles but removes built-in dependency fanout' {
        $Sa = New-TestPrincipal 'renamed-sa'; $Sa.Sid = '0x01'
        $Fixed = New-TestPrincipal 'sysadmin' 'R'; $Fixed.IsFixedRole = $true
        $Custom = New-TestPrincipal 'custom-role' 'R'; $Custom.OwnerName = 'renamed-sa'
        $script:Principals = @($Sa, $Fixed, $Custom, (New-TestPrincipal 'app'))
        Mock Invoke-SqlcmdLogged {
            [pscustomobject]@{ RoleName = 'sysadmin'; MemberName = 'renamed-sa' }
            [pscustomobject]@{ RoleName = 'sysadmin'; MemberName = 'app' }
            [pscustomobject]@{ RoleName = 'custom-role'; MemberName = 'app' }
        } -ParameterFilter { $Context -eq 'SecuritySnapshot.ServerMemberships' }
        Mock Invoke-SqlcmdLogged {
            [pscustomobject]@{ Class = 100; State = 'G'; PermissionName = 'CONNECT SQL'; GranteeName = 'sysadmin'; GrantorName = 'renamed-sa' }
            [pscustomobject]@{ Class = 100; State = 'G'; PermissionName = 'CONNECT SQL'; GranteeName = 'app'; GrantorName = 'renamed-sa' }
            [pscustomobject]@{ Class = 101; State = 'G'; PermissionName = 'IMPERSONATE'; GranteeName = 'app'; GrantorName = 'renamed-sa'; SecurableName = 'renamed-sa' }
        } -ParameterFilter { $Context -eq 'SecuritySnapshot.ServerPermissions' }
        $Blocks = @(Get-ServerObjectSecuritySnapshotBlocks SOURCE)
        @($Blocks | Where-Object Kind -eq ServerMembership).Name | Should -Be @('sysadmin/app', 'custom-role/app')
        @($Blocks | Where-Object Kind -eq ServerRole).Name | Should -Be @('custom-role')
        @($Blocks | Where-Object Kind -eq ServerRoleOwner).Count | Should -Be 0
        $Permission = @($Blocks | Where-Object Kind -eq ServerPermission)
        $Permission.Count | Should -Be 1
        $Permission[0].Sql | Should -Match 'GRANT CONNECT SQL TO \[app\];'
        $Permission[0].Metadata.GrantorName | Should -Be 'renamed-sa'
    }
    It 'Filters database built-ins, login aliases, role permissions and owners while retaining custom roles' {
        $Sa = New-TestPrincipal 'renamed-sa'; $Sa.Sid = '0x01'
        $script:Principals += $Sa
        $script:Users = @(
            $script:Users[0],
            [pscustomobject]@{ PrincipalId = 1; Name = 'dbo'; Type = 'S' },
            [pscustomobject]@{ PrincipalId = 5; Name = 'db_datareader'; Type = 'R'; IsFixedRole = $true },
            [pscustomobject]@{ PrincipalId = 20; Name = 'custom-role'; Type = 'R'; OwnerName = 'dbo' },
            [pscustomobject]@{ PrincipalId = 21; Name = 'alias-to-sa'; Type = 'S'; LoginName = 'renamed-sa' }
        )
        $SystemPermission = New-TestPermission; $SystemPermission.GranteeName = 'db_datareader'
        $script:PermissionRows += $SystemPermission
        Mock Invoke-SqlcmdLogged {
            [pscustomobject]@{ RoleName = 'db_datareader'; MemberName = 'appuser' }
            [pscustomobject]@{ RoleName = 'db_datareader'; MemberName = 'dbo' }
        } -ParameterFilter { $Context -eq 'SecuritySnapshot.DatabaseMemberships' }
        $Blocks = @(Get-ServerObjectSecuritySnapshotBlocks SOURCE | Where-Object Database -eq UnselectedApp)
        @($Blocks | Where-Object Kind -eq DatabaseUser).Name | Should -Be @('appuser')
        @($Blocks | Where-Object Kind -eq DatabaseRole).Name | Should -Be @('custom-role')
        @($Blocks | Where-Object Kind -eq DatabaseMembership).Name | Should -Be @('db_datareader/appuser')
        @($Blocks | Where-Object Kind -eq DatabasePermission).Count | Should -Be 1
        ($Blocks | Where-Object Kind -eq DatabasePermission).Sql | Should -Not -Match 'AS \[dbo\]'
        @($Blocks | Where-Object Kind -eq DatabaseRoleOwner).Count | Should -Be 0
    }
    It 'Distinguishes non-fixed msdb product roles from same-named application roles' {
        $Role = [pscustomobject]@{ PrincipalId = 25; Name = 'SQLAgentUserRole'; Type = 'R'; IsFixedRole = $false }
        Test-SecuritySnapshotSystemPrincipal $Role -DatabaseScope -DatabaseName msdb | Should -BeTrue
        Test-SecuritySnapshotSystemPrincipal $Role -DatabaseScope -DatabaseName AppDb | Should -BeFalse
        $script:Users += $Role
        $ProductPermission = New-TestPermission; $ProductPermission.GranteeName = $Role.Name
        $script:PermissionRows = @($ProductPermission)
        Mock Invoke-SqlcmdLogged {
            [pscustomobject]@{ RoleName = 'SQLAgentUserRole'; MemberName = 'appuser' }
        } -ParameterFilter { $Context -eq 'SecuritySnapshot.DatabaseMemberships' }
        $Blocks = @(Get-ServerObjectSecuritySnapshotBlocks SOURCE)
        @($Blocks | Where-Object { $_.Database -eq 'msdb' -and $_.Kind -eq 'DatabaseRole' }).Count | Should -Be 0
        @($Blocks | Where-Object { $_.Database -eq 'msdb' -and $_.Kind -eq 'DatabasePermission' }).Count | Should -Be 0
        @($Blocks | Where-Object { $_.Database -eq 'msdb' -and $_.Kind -eq 'DatabaseMembership' }).Count | Should -Be 1
        @($Blocks | Where-Object { $_.Database -eq 'UnselectedApp' -and $_.Kind -eq 'DatabaseRole' }).Count | Should -Be 1
    }
}

Describe 'Reviewable idempotent security replay' {
    It 'Retains all permission states, column REVOKE exceptions, and qualified schema targets' -ForEach @(
        @{ State = 'G'; Verb = 'GRANT'; Tail = 'TO [reader] AS [dbo];' }
        @{ State = 'D'; Verb = 'DENY'; Tail = 'TO [reader] AS [dbo];' }
        @{ State = 'W'; Verb = 'GRANT'; Tail = 'TO [reader] WITH GRANT OPTION AS [dbo];' }
        @{ State = 'R'; Verb = 'REVOKE'; Tail = 'FROM [reader] AS [dbo];' }
    ) {
        $Block = New-SecuritySnapshotBlock 'permission' 'DatabasePermission' 'db]one' @{
            PermissionName = 'SELECT'; State = $State; Target = 'SCHEMA::[app]'
            GranteeName = 'reader'; GrantorName = 'dbo'
        }
        $Block.Sql | Should -Be "USE [db]]one];`n$Verb SELECT ON SCHEMA::[app] $Tail"
    }
    It 'Qualifies each supported permission class without database-wide fallback' -ForEach @(
        @{ Class = 3; Expected = 'SCHEMA::' }
        @{ Class = 4; Expected = 'USER::' }
        @{ Class = 5; Expected = 'ASSEMBLY::' }
        @{ Class = 6; Expected = 'TYPE::[schema]]one].' }
        @{ Class = 10; Expected = 'XML SCHEMA COLLECTION::[schema]]one].' }
        @{ Class = 25; Expected = 'CERTIFICATE::' }
        @{ Class = 32; Expected = 'DATABASE SCOPED CREDENTIAL::' }
    ) {
        $R = New-TestPermission -Class $Class
        (Get-SecuritySnapshotPermissionTarget $R).StartsWith($Expected) | Should -BeTrue
    }
    It 'Protects restored user SIDs and never blindly remaps a SQL user to a conflicting login' {
        $Block = New-SecuritySnapshotBlock 'restored' 'DatabaseUser' 'app' @{
            Name = 'restored'; Type = 'S'; Sid = '0x00112233'; LoginName = 'sqlLogin'
            LoginType = 'S'; DefaultSchema = 'dbo'
        }
        $Block.Sql | Should -Match "SUSER_SID\(N'sqlLogin'\) <> 0x00112233 THROW"
        $Block.Sql | Should -Match 'Existing database user SID conflicts'
        $Block.Sql | Should -Not -Match 'ALTER USER.+WITH LOGIN'
        $Block.Sql | Should -Match 'IF NOT EXISTS[\s\S]*CREATE USER \[restored\] FOR LOGIN \[sqlLogin\]'
    }
    It 'Creates all roles before separate ownership and makes memberships rerunnable' {
        $Role = New-SecuritySnapshotBlock 'custom' 'ServerRole' '' @{ Name = 'custom'; IsFixedRole = $false }
        $Role.Sql | Should -Match 'IF NOT EXISTS.+CREATE SERVER ROLE \[custom\];'
        $Owner = New-SecuritySnapshotBlock 'custom' 'ServerRoleOwner' '' @{ Name = 'custom'; OwnerName = 'owner' }
        $Owner.Sql | Should -Match 'ALTER AUTHORIZATION ON SERVER ROLE::\[custom\] TO \[owner\]'
        $Member = New-SecuritySnapshotBlock 'custom/member' 'ServerMembership' '' @{ RoleName = 'custom'; MemberName = 'member' }
        $Member.Sql | Should -Match 'IF NOT EXISTS[\s\S]*ALTER SERVER ROLE \[custom\] ADD MEMBER \[member\]'
    }
    It 'Rejects unknown kinds and target types explicitly' {
        { ConvertTo-ServerObjectSecurityReplaySql ([pscustomobject]@{ Kind = 'Surprise'; Metadata = @{} }) $Vm } | Should -Throw
        { ConvertTo-ServerObjectSecurityReplaySql ([pscustomobject]@{ Metadata = @{ Name = 'a' } }) ([pscustomobject]@{ TargetType = 'SQLDB' }) } | Should -Throw '*TargetType*'
    }
    It 'Requires restored WITHOUT LOGIN users rather than generating a different SID' {
        $Block = New-SecuritySnapshotBlock 'moduleUser' 'DatabaseUser' 'app' @{
            Name = 'moduleUser'; Type = 'S'; AuthenticationType = 'NONE'; Sid = '0x00112233'
        }
        $Block.Sql | Should -Match 'name=N''moduleUser'' AND sid=0x00112233'
        $Block.Sql | Should -Match 'requires its restored source database to preserve SID'
        $Block.Sql | Should -Not -Match 'CREATE USER \[moduleUser\]'
    }
    It 'Keeps internal server permissions as explicitly reported protected entries' {
        $Block = New-SecuritySnapshotBlock 'internal/CONTROL SERVER' 'ServerPermission' '' @{
            GranteeName = 'NT SERVICE\Engine'; Protected = $true; State = 'G'; PermissionName = 'CONTROL SERVER'
        }
        $Block.Sql | Should -Match 'PRINT'
        $Block.Sql | Should -Not -Match '^GRANT'
    }
    It 'Rejects unresolved object and column securables' {
        $P = New-TestPermission; $P.SchemaName = ''
        { Get-SecuritySnapshotPermissionTarget $P } | Should -Throw '*object permission*'
        $P.SchemaName = 'dbo'; $P.ColumnName = ''
        { Get-SecuritySnapshotPermissionTarget $P } | Should -Throw '*column permission*'
    }
    It 'Orders grantor grant-options before dependent grants, and column exceptions after object permissions' {
        $Root = New-TestPermission -State 'W' -MinorId 0
        $Root.GranteeName = 'zGrantor'; $Root.GrantorName = 'dbo'
        $Child = New-TestPermission -State 'G' -MinorId 0
        $Child.GranteeName = 'aReader'; $Child.GrantorName = 'zGrantor'
        $Column = New-TestPermission -State 'R' -MinorId 2
        $Column.GranteeName = 'aReader'; $Column.GrantorName = 'dbo'
        $Ordered = @(Get-OrderedSecuritySnapshotPermissions @($Column, $Child, $Root))
        $Ordered[0].GranteeName | Should -Be 'zGrantor'
        $Ordered[1].GranteeName | Should -Be 'aReader'
        $Ordered[2].MinorId | Should -Be 2
    }
    It 'Explicitly rejects cyclic grantor graphs rather than emitting an unusable order' {
        $A = New-TestPermission -State 'W' -MinorId 0
        $A.GranteeName = 'a'; $A.GrantorName = 'b'
        $B = New-TestPermission -State 'W' -MinorId 0
        $B.GranteeName = 'b'; $B.GrantorName = 'a'
        { Get-OrderedSecuritySnapshotPermissions @($A, $B) } | Should -Throw '*Cyclic explicit permission*'
    }
}

Describe 'SQLMI cloud-only Windows identity mapping' {
    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = @{ Id = 'tenant' }; Subscription = @{ Id = 'subscription' } } }
        Mock Get-AzADUser { [pscustomobject]@{ UserPrincipalName = $UserPrincipalName; Id = '01234567-89ab-cdef-0123-456789abcdef' } }
        Mock Get-AzADGroup { @() }
        Mock Invoke-SqlcmdLogged { throw 'Replay may never query source' }
    }
    It 'Maps arbitrary Windows domains using the configured suffix, not a host/domain constant' {
        $Block = New-SecuritySnapshotBlock 'OTHER\alice' 'Login' '' @{ Name = 'OTHER\alice'; Type = 'U' }
        $Sql = ConvertTo-ServerObjectSecurityReplaySql $Block $Mi
        $Sql | Should -Match 'CREATE LOGIN \[alice@cloud.example\] FROM EXTERNAL PROVIDER'
        $Sql | Should -Match "WITH OBJECT_ID = '01234567-89ab-cdef-0123-456789abcdef'"
        Should -Invoke Get-AzADUser -ParameterFilter { $UserPrincipalName -eq 'alice@cloud.example' } -Times 1 -Exactly
        Should -Invoke Invoke-SqlcmdLogged -Times 0
    }
    It 'Translates server membership references to the same Entra identity' {
        $Block = New-SecuritySnapshotBlock 'role/OTHER\alice' 'ServerMembership' '' @{
            RoleName = 'role'; MemberName = 'OTHER\alice'; MemberType = 'U'
        }
        ConvertTo-ServerObjectSecurityReplaySql $Block $Mi | Should -Match 'ADD MEMBER \[alice@cloud.example\]'
    }
    It 'Remaps only restored Windows users with source-or-target SID guards, retaining database aliases' {
        $Block = New-SecuritySnapshotBlock 'alias' 'DatabaseUser' 'app' @{
            Name = 'alias'; Type = 'U'; Sid = '0x00112233'; LoginName = 'OTHER\alice'; LoginType = 'U'
        }
        $Sql = ConvertTo-ServerObjectSecurityReplaySql $Block $Mi
        $Sql | Should -Match 'sid<>0x00112233 AND sid<>SUSER_SID'
        $Sql | Should -Match 'ALTER USER \[alias\] WITH LOGIN = \[alice@cloud.example\]'
    }
    It 'Does not contact Azure when retaining SQL login hashes/SIDs on MI' {
        $Block = New-SecuritySnapshotBlock 'sqlLogin' 'Login' '' @{
            Name = 'sqlLogin'; Type = 'S'; Sid = '0x00112233'; PasswordHash = '0x0200AABB'
        }
        ConvertTo-ServerObjectSecurityReplaySql $Block $Mi | Should -Match 'PASSWORD = 0x0200AABB HASHED, SID = 0x00112233'
        Should -Invoke Get-AzContext -Times 0
    }
    It 'Fails actionably when suffix/UPN is unavailable, without searching AD' {
        $BadItem = [pscustomobject]@{ TargetType = 'SQLMI'; TenantId = 'tenant'; SubscriptionId = 'subscription' }
        $Block = New-SecuritySnapshotBlock 'OTHER\alice' 'Login' '' @{ Name = 'OTHER\alice'; Type = 'U' }
        { ConvertTo-ServerObjectSecurityReplaySql $Block $BadItem } | Should -Throw '*valid JobOwnerUpnSuffix*'
        Should -Invoke Get-AzADUser -Times 0
    }
    It 'Refuses an incorrect Azure context without modifying it' {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = @{ Id = 'wrong' }; Subscription = @{ Id = 'subscription' } } }
        $Block = New-SecuritySnapshotBlock 'OTHER\alice' 'Login' '' @{ Name = 'OTHER\alice'; Type = 'U' }
        { ConvertTo-ServerObjectSecurityReplaySql $Block $Mi } | Should -Throw '*matching configured TenantId*'
    }
    It 'Rejects ambiguous exact users instead of choosing the first result' {
        Mock Get-AzADUser { @([pscustomobject]@{ UserPrincipalName = $UserPrincipalName }, [pscustomobject]@{ UserPrincipalName = $UserPrincipalName }) }
        $Block = New-SecuritySnapshotBlock 'OTHER\alice' 'Login' '' @{ Name = 'OTHER\alice'; Type = 'U' }
        { ConvertTo-ServerObjectSecurityReplaySql $Block $Mi } | Should -Throw '*resolved to 2 users*'
    }
    It 'Does not guess a group by stripping the domain' {
        $Block = New-SecuritySnapshotBlock 'OTHER\Finance' 'Login' '' @{ Name = 'OTHER\Finance'; Type = 'G' }
        { ConvertTo-ServerObjectSecurityReplaySql $Block $Mi } | Should -Throw '*no unique exact Entra*'
        Should -Invoke Get-AzADGroup -ParameterFilter { $DisplayName -eq 'OTHER\Finance' } -Times 1 -Exactly
    }
    It 'Accepts an unambiguous exact group using its immutable Entra object ID' {
        Mock Get-AzADGroup { [pscustomobject]@{ DisplayName = $DisplayName; Id = '01234567-89ab-cdef-0123-456789abcdef' } }
        $Block = New-SecuritySnapshotBlock 'OTHER\Finance' 'Login' '' @{ Name = 'OTHER\Finance'; Type = 'G' }
        ConvertTo-ServerObjectSecurityReplaySql $Block $Mi |
            Should -Match "CREATE LOGIN \[OTHER\\Finance\] FROM EXTERNAL PROVIDER WITH OBJECT_ID = '01234567-89ab-cdef-0123-456789abcdef'"
    }
    It 'Translates server permission grantee, grantor and LOGIN securable references consistently' {
        $Block = New-SecuritySnapshotBlock 'permission' 'ServerPermission' '' @{
            Class = 101; PermissionName = 'IMPERSONATE'; State = 'W'; Target = 'LOGIN::[OTHER\target]'
            GranteeName = 'OTHER\reader'; GranteeType = 'U'; GrantorName = 'OTHER\owner'; GrantorType = 'U'
            SecurableName = 'OTHER\target'; SecurableType = 'LOGIN'; SecurablePrincipalType = 'U'
        }
        ConvertTo-ServerObjectSecurityReplaySql $Block $Mi |
            Should -Be "USE [master];`nGRANT IMPERSONATE ON LOGIN::[target@cloud.example] TO [reader@cloud.example] WITH GRANT OPTION AS [owner@cloud.example];"
    }
}

Describe 'Generated SQL grammar (offline ScriptDom)' {
    It 'Parses all catalog queries and non-external replay SQL when the existing SqlServer parser is available' {
        $Module = Get-Module SqlServer -ListAvailable | Select-Object -First 1
        if (-not $Module) { Set-ItResult -Skipped -Because 'SqlServer ScriptDom is not installed'; return }
        $Dll = Join-Path $Module.ModuleBase 'coreclr\Microsoft.SqlServer.TransactSql.ScriptDom.dll'
        if (-not (Test-Path -LiteralPath $Dll)) { Set-ItResult -Skipped -Because 'ScriptDom DLL is unavailable'; return }
        Add-Type -Path $Dll -ErrorAction Stop
        $Parser = [Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser]::new($true)
        $script:SqlTexts = [Collections.Generic.List[string]]::new()
        Mock Invoke-SqlcmdLogged {
            $script:SqlTexts.Add($Query)
            switch ($Context) {
                'SecuritySnapshot.Access' { [pscustomobject]@{ IsSysadmin = 1 } }
                'SecuritySnapshot.ServerPrincipals' { New-TestPrincipal }
                'SecuritySnapshot.Databases' { [pscustomobject]@{ Name = 'app'; HasAccess = 1 } }
                'SecuritySnapshot.DatabasePrincipals' {
                    [pscustomobject]@{
                        PrincipalId = 10; Name = 'appuser'; Type = 'S'; AuthenticationType = 'INSTANCE'
                        LoginName = "sql'login]"; LoginType = 'S'; Sid = '0x00112233'; DefaultSchema = 'dbo'
                    }
                }
                default { }
            }
        }
        $Blocks = @(Get-ServerObjectSecuritySnapshotBlocks 'SOURCE')
        foreach ($Block in $Blocks) { $script:SqlTexts.Add($Block.Sql) }
        foreach ($Kind in @('ServerRole', 'DatabaseRole', 'ServerRoleOwner', 'DatabaseRoleOwner', 'SchemaOwner', 'ObjectOwner', 'ServerMembership', 'DatabaseMembership')) {
            $Block = New-SecuritySnapshotBlock 'role' $Kind 'app' @{ Name = 'role'; SchemaName = 'dbo'; OwnerName = 'owner'; RoleName = 'role'; MemberName = 'member' }
            $script:SqlTexts.Add($Block.Sql)
        }
        foreach ($State in @('G', 'W', 'D', 'R')) {
            $Block = New-SecuritySnapshotBlock 'permission' 'DatabasePermission' 'app' @{
                PermissionName = 'SELECT'; State = $State; Target = 'OBJECT::[dbo].[t] ([c])'
                GranteeName = 'reader'; GrantorName = 'dbo'
            }
            $script:SqlTexts.Add($Block.Sql)
        }
        foreach ($Sql in $script:SqlTexts) {
            $Reader = [IO.StringReader]::new($Sql)
            $Errors = $null
            try { $null = $Parser.Parse($Reader, [ref]$Errors) }
            finally { $Reader.Dispose() }
            @($Errors).Count | Should -Be 0 -Because ($Sql + "`n" + ($Errors.Message -join "`n"))
        }
    }
}
