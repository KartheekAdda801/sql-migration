#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    $Scripts = Join-Path $PSScriptRoot '..\scripts'
    . (Join-Path $Scripts 'Common\ServerObjects.Helpers.ps1')
    . (Join-Path $Scripts 'Common\ServerObjects.Configuration.Helpers.ps1')
    $Tokens = $null
    $Errors = $null
    $Ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $Scripts 'Invoke-ProvisionLogins-AzSql.ps1'), [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count) { throw $Errors[0] }
    $Names = @('Quote-SqlIdentifier', 'Quote-SqlString', 'Invoke-SqlScalar', 'Invoke-SqlNonQuery',
        'Ensure-WindowsADLogin', 'Ensure-ExternalLogin', 'Ensure-DatabaseUserAndAccess', 'Ensure-AzContext')
    foreach ($Function in $Ast.FindAll({
        param($Node)
        $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -in $Names
    }, $true)) {
        . ([scriptblock]::Create($Function.Extent.Text))
    }
    # Exercise the actual worker row loop without running its module imports,
    # configuration preflight, report writes or process exit.
    $RowLoop = $Ast.Find({
        param($Node)
        $Node -is [Management.Automation.Language.ForEachStatementAst] -and
        $Node.Variable.VariablePath.UserPath -eq 'row' -and $Node.Condition.Extent.Text -eq '$rows'
    }, $true)
    if (-not $RowLoop) { throw 'Provisioning row loop was not found.' }
    $ProvisioningRowLoop = [scriptblock]::Create(
        '[CmdletBinding(SupportsShouldProcess)] param() $failedRows = @(); ' + $RowLoop.Extent.Text + '; $failedRows')
}

Describe 'Target-specific provisioning validation' -Tag 'Unit' {
    It 'Parses operational configuration with only the existing SQL login on SQLVM' {
        $Path = Join-Path $PSScriptRoot '..\config\Invoke-MigrateServerObjects-ProvisionLogin-AzSql.config.json'
        $Items = @(Read-ServerObjectItems -Path $Path)
        $Vm = $Items | Where-Object TargetType -eq SQLVM
        $Vm.Logins | Should -HaveCount 1
        $Vm.Logins[0].Name | Should -BeExactly DBUsrLogin
        $Vm.Logins[0].Type | Should -BeExactly SqlLogin
        $Vm.TargetWindowsDomain | Should -BeNullOrEmpty
        foreach ($Item in $Items) {
            @(Get-ServerObjectProvisioningItems -Item $Item).Count | Should -BeGreaterThan 0
        }
    }

    It 'Enforces <Target>/<Type> with Allowed=<Allowed> at configuration and private preflight boundaries' -ForEach @(
        @{ Target = 'SQLVM'; Type = 'SqlLogin'; Allowed = $true },
        @{ Target = 'SQLVM'; Type = 'WindowsAD'; Allowed = $true },
        @{ Target = 'SQLVM'; Type = 'EntraUser'; Allowed = $false },
        @{ Target = 'SQLVM'; Type = 'EntraGroup'; Allowed = $false },
        @{ Target = 'SQLVM'; Type = 'ManagedIdentity'; Allowed = $false },
        @{ Target = 'SQLMI'; Type = 'SqlLogin'; Allowed = $true },
        @{ Target = 'SQLMI'; Type = 'WindowsAD'; Allowed = $false },
        @{ Target = 'SQLMI'; Type = 'EntraUser'; Allowed = $true },
        @{ Target = 'SQLMI'; Type = 'EntraGroup'; Allowed = $true },
        @{ Target = 'SQLMI'; Type = 'ManagedIdentity'; Allowed = $true }
    ) {
        $Json = Get-Content (Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json') -Raw | ConvertFrom-Json -AsHashtable
        $Json.Items = @($Json.Items[0])
        $Json.Items[0].TargetType = $Target
        $Login = @{ Name = 'test-principal'; Type = $Type; AccessType = @() }
        if ($Type -eq 'WindowsAD') { $Login.Name = 'EXAMPLE\testuser' }
        if ($Type -eq 'SqlLogin') { $Login.SecretName = 'test-secret' }
        $Json.Items[0].Logins = @($Login)
        $Path = Join-Path $TestDrive 'matrix.json'
        $Json | ConvertTo-Json -Depth 10 | Set-Content $Path
        if ($Allowed) {
            $Item = Read-ServerObjectItems -Path $Path
            $Rows = @(Get-ServerObjectProvisioningItems -Item $Item)
            @($Rows.LoginType | Select-Object -Unique) | Should -Be @($Type)
            { Assert-ServerObjectLoginTarget -TargetType $Target -LoginType $Type -LoginName $Login.Name -TargetWindowsDomain EXAMPLE } |
                Should -Not -Throw
        }
        else {
            { Read-ServerObjectItems -Path $Path } | Should -Throw '*not supported*'
            # A private schema 1 caller cannot skip the schema 2 checks.
            $Row = [pscustomobject]@{
                Application = 'test'; TargetServerName = 'target'; TargetServerFQDN = 'target.example'
                TargetType = $Target; TenantId = $Json.Common.TenantId; SubscriptionId = $Json.Common.SubscriptionId
                LoginName = $Login.Name; LoginType = $Type; Database = 'AppDb'; TargetWindowsDomain = 'EXAMPLE'
                ForcePasswordReset = $false; AccessType = @()
            }
            Mock Import-Module {}
            Mock Assert-ServiceOutputPath {}
            Mock Invoke-ServerObjectPreflightQuery {}
            Mock Resolve-ServerObjectExternalPrincipal {}
            { Invoke-ServerObjectPreflight -Operation Invoke-ProvisionLogins-AzSql -Configuration @{ Items = @($Row) } `
                -Options @{ OutputRoot = $TestDrive; SqlPort = 1433 } -ScriptsPath $Scripts } | Should -Throw '*not supported*'
            Should -Invoke Import-Module -Times 0 -Exactly
            Should -Invoke Assert-ServiceOutputPath -Times 0 -Exactly
            Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0 -Exactly
            Should -Invoke Resolve-ServerObjectExternalPrincipal -Times 0 -Exactly
        }
    }

    It 'Rejects WindowsAD name <Name> or unverified domain <Domain>' -ForEach @(
        @{ Name = 'testuser'; Domain = 'EXAMPLE' },
        @{ Name = 'testuser@example.test'; Domain = 'EXAMPLE' },
        @{ Name = '.\testuser'; Domain = 'EXAMPLE' },
        @{ Name = 'OTHER\testuser'; Domain = 'EXAMPLE' },
        @{ Name = 'EXAMPLE\testuser'; Domain = '' },
        @{ Name = 'EXAMPLE\testuser'; Domain = 'example.test' },
        @{ Name = 'EXAMPLE\'; Domain = 'EXAMPLE' },
        @{ Name = 'EXAMPLE\a\b'; Domain = 'EXAMPLE' }
    ) {
        { Assert-ServerObjectLoginTarget -TargetType SQLVM -LoginType WindowsAD -LoginName $Name -TargetWindowsDomain $Domain } |
            Should -Throw
    }

    It 'Accepts case-insensitive domain qualification but does not use a source suffix' {
        { Assert-ServerObjectLoginTarget -TargetType SQLVM -LoginType WindowsAD -LoginName 'example\testuser' -TargetWindowsDomain EXAMPLE } |
            Should -Not -Throw
        $Item = Read-ServerObjectItems -Path (Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json') -ItemId VM-Objects
        $Item.TargetWindowsDomain = ''
        $Item.SourceDomainSuffix = 'EXAMPLE'
        { Get-ServerObjectProvisioningItems -Item $Item } | Should -Throw '*TargetWindowsDomain*'
    }

    It 'Rejects a later wrong-target row before any output checks, imports, secrets, directory or SQL access' {
        $Item = Read-ServerObjectItems -Path (Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json') -ItemId MI-Objects
        $Rows = @(Get-ServerObjectProvisioningItems -Item $Item)
        $Rows[-1].TargetType = 'SQLVM'
        Mock Import-Module {}
        Mock Assert-ServiceOutputPath {}
        Mock Resolve-ServerObjectExternalPrincipal {}
        Mock Invoke-ServerObjectPreflightQuery {}
        { Invoke-ServerObjectPreflight -Operation Invoke-ProvisionLogins-AzSql -Configuration @{ Items = $Rows } `
            -Options @{ OutputRoot = $TestDrive; SqlPort = 1433 } -ScriptsPath $Scripts } | Should -Throw '*not supported*'
        Should -Invoke Import-Module -Times 0 -Exactly
        Should -Invoke Assert-ServiceOutputPath -Times 0 -Exactly
        Should -Invoke Resolve-ServerObjectExternalPrincipal -Times 0 -Exactly
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0 -Exactly
    }

    It 'Rejects WindowsAD property <Property> instead of interpreting it as an external identity' -ForEach @(
        @{ Property = 'ObjectId'; Value = 'ec787112-0f22-4785-89a5-cb9ee4807a96' },
        @{ Property = 'SecretName'; Value = 'unused-secret' },
        @{ Property = 'ForcePasswordReset'; Value = $false }
    ) {
        $Item = Read-ServerObjectItems -Path (Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json') -ItemId VM-Objects
        $Login = @{ Name = 'EXAMPLE\testuser'; Type = 'WindowsAD'; AccessType = @() }
        $Login[$Property] = $Value
        $Item.Logins = @($Login)
        { ConvertTo-ServerObjectLogins -Item $Item } | Should -Throw
    }
}

Describe 'WindowsAD private preflight target checks' -Tag 'Unit' {
    BeforeEach {
        $Item = Read-ServerObjectItems -Path (Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json') -ItemId VM-Objects
        $Item.Logins = @($Item.Logins | Where-Object Type -eq WindowsAD)
        $Rows = @(Get-ServerObjectProvisioningItems -Item $Item)
        Mock Import-Module {}
        Mock Assert-ServiceOutputPath {}
        Mock Get-AzContext { [pscustomobject]@{ Tenant = @{ Id = $Item.TenantId } } }
        Mock Set-AzContext {}
        Mock Resolve-ServerObjectExternalPrincipal { throw 'Windows AD must not query Entra' }
        Mock Assert-ServerObjectSqlAccess {}
        Mock Invoke-ServerObjectPreflightQuery {}
    }
    It 'Checks the Windows account in master even in Server-only scope with <Authentication> connection auth' -ForEach @(
        @{ Authentication = 'Windows' },
        @{ Authentication = 'Entra' },
        @{ Authentication = 'SqlLogin' }
    ) {
        $Credential = if ($Authentication -eq 'SqlLogin') {
            [pscredential]::new('test-admin', (ConvertTo-SecureString 'offline-only' -AsPlainText -Force))
        } else { $null }
        Invoke-ServerObjectPreflight -Operation Invoke-ProvisionLogins-AzSql -Configuration @{ Items = $Rows } `
            -Options @{ OutputRoot = $TestDrive; SqlPort = 1433; ServerOnly = $true
                TargetSqlAuthType = $Authentication; SqlCredential = $Credential } -ScriptsPath $Scripts
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 2 -Exactly -ParameterFilter {
            $Database -eq 'master' -and $Query -match 'xp_logininfo' -and $Query -match "SUSER_SID\(.*?, 1\)" -and
            $Query -match 'DEFAULT_DOMAIN\(\)' -and
            $Query.IndexOf('default Windows domain does not match') -lt $Query.IndexOf('xp_logininfo') -and
            $Query -match "NULLIF\(LTRIM\(RTRIM\(@TargetDefaultDomain\)\), N''\) IS NULL" -and
            $Query -match "COLLATE Latin1_General_100_CI_AS <> N'EXAMPLE'"
        }
        Should -Invoke Resolve-ServerObjectExternalPrincipal -Times 0 -Exactly
        Should -Invoke Import-Module -Times 0 -Exactly -ParameterFilter { $Name -in @('Az.Resources', 'Az.KeyVault') }
    }
    It 'Stops before permission checks when target-side AD resolution fails' {
        Mock Invoke-ServerObjectPreflightQuery { throw 'Windows AD resolution failed' }
        { Invoke-ServerObjectPreflight -Operation Invoke-ProvisionLogins-AzSql -Configuration @{ Items = $Rows } `
            -Options @{ OutputRoot = $TestDrive; SqlPort = 1433; ServerOnly = $true } -ScriptsPath $Scripts } |
            Should -Throw '*Windows AD resolution failed*'
        Should -Invoke Assert-ServerObjectSqlAccess -Times 0 -Exactly
    }
}

Describe 'Provisioning SQL principal semantics' -Tag 'Unit' {
    BeforeEach {
        Mock Invoke-SqlScalar { 'Created' }
        Mock Invoke-SqlScalar { 'EXAMPLE' } -ParameterFilter { $Sql -eq 'SELECT DEFAULT_DOMAIN();' }
        Mock Invoke-SqlNonQuery {}
    }
    It 'Accepts matching target default Windows domain <ReportedDomain>' -ForEach @(
        @{ ReportedDomain = 'EXAMPLE' },
        @{ ReportedDomain = 'example' }
    ) {
        Mock Invoke-SqlScalar { $ReportedDomain } -ParameterFilter { $Sql -eq 'SELECT DEFAULT_DOMAIN();' }
        Ensure-WindowsADLogin -ServerName target -Port 1433 -AccessToken '' `
            -LoginName 'EXAMPLE\testuser' -TargetWindowsDomain EXAMPLE | Should -Be Created
        Should -Invoke Invoke-SqlScalar -Times 1 -Exactly -ParameterFilter {
            $Database -eq 'master' -and $Sql -eq 'SELECT DEFAULT_DOMAIN();'
        }
        Should -Invoke Invoke-SqlScalar -Times 1 -Exactly -ParameterFilter { $Sql -match 'CREATE LOGIN' }
    }
    It 'Creates a Windows user with target resolution, escaping, transaction rollback and SID/type checks before granting access' {
        Ensure-WindowsADLogin -ServerName target -Port 1433 -AccessToken '' `
            -LoginName "EXAMPLE\user']" -TargetWindowsDomain EXAMPLE | Should -Be Created
        Should -Invoke Invoke-SqlScalar -Times 1 -Exactly -ParameterFilter {
            $Database -eq 'master' -and $Sql -match 'xp_logininfo' -and
            $Sql -match "SUSER_SID\(N'EXAMPLE\\user''\]', 1\)" -and
            $Sql -match 'CREATE LOGIN \[EXAMPLE\\user''\]\]\] FROM WINDOWS' -and
            $Sql -match "type = 'U' AND sid = @ExpectedSid" -and
            $Sql -match 'DEFAULT_DOMAIN\(\)' -and
            $Sql.IndexOf('default Windows domain does not match') -lt $Sql.IndexOf('CREATE LOGIN') -and
            $Sql -match 'BEGIN TRANSACTION' -and $Sql -match 'ROLLBACK TRANSACTION' -and
            $Sql -notmatch 'EXTERNAL PROVIDER|CREATE USER|GRANT '
        }
    }
    It 'Does not attempt SQL when Windows domain qualification fails' {
        { Ensure-WindowsADLogin -ServerName target -Port 1433 -AccessToken '' `
            -LoginName 'OTHER\testuser' -TargetWindowsDomain EXAMPLE } | Should -Throw
        Should -Invoke Invoke-SqlScalar -Times 0 -Exactly
    }
    It 'Stops on target resolution or type/SID failures without a subsequent grant' {
        Mock Invoke-SqlScalar { throw 'Target Windows account could not be verified' }
        Mock Invoke-SqlScalar { 'EXAMPLE' } -ParameterFilter { $Sql -eq 'SELECT DEFAULT_DOMAIN();' }
        { Ensure-WindowsADLogin -ServerName target -Port 1433 -AccessToken '' `
            -LoginName 'EXAMPLE\testuser' -TargetWindowsDomain EXAMPLE } | Should -Throw '*could not be verified*'
        Should -Invoke Invoke-SqlNonQuery -Times 0 -Exactly
    }
    It 'Uses Windows U type and matching server SID for existing database users' {
        Mock Invoke-SqlScalar { 1 }
        Ensure-DatabaseUserAndAccess -ServerName target -Port 1433 -Database AppDb -AccessToken '' `
            -LoginName 'EXAMPLE\testuser' -AccessTypes @() -PrincipalType U
        Should -Invoke Invoke-SqlScalar -Times 1 -Exactly -ParameterFilter {
            $Sql -match "type = 'U' AND sid = SUSER_SID"
        }
    }

    It 'Uses external-provider SQL and object SID for <Variant> managed identity on MI' -ForEach @(
        @{ Variant = 'system-assigned'; Name = 'test-system-identity' },
        @{ Variant = 'user-assigned'; Name = 'test-user-identity' }
    ) {
        # Both variants are represented by the same service-principal type/ObjectId.
        $Item = Read-ServerObjectItems -Path (Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json') -ItemId MI-Objects
        $Id = 'ec787112-0f22-4785-89a5-cb9ee4807a96'
        $Item.Logins = @(@{ Name = $Name; Type = 'ManagedIdentity'; ObjectId = $Id; AccessType = @() })
        $Item.Logins = @(ConvertTo-ServerObjectLogins -Item $Item)
        $Rows = @(Get-ServerObjectProvisioningItems -Item $Item)
        $Rows[0].LoginType | Should -Be ManagedIdentity
        Mock Invoke-SqlScalar { 0 }
        Mock Invoke-SqlScalar { 1 } -ParameterFilter { $Sql -match "type = 'E' AND sid = 0x" }
        Ensure-ExternalLogin -ServerName target -Port 3342 -AccessToken token -LoginName $Rows[0].LoginName `
            -ObjectId $Rows[0].ObjectId -PrincipalType E | Should -Be Created
        Should -Invoke Invoke-SqlNonQuery -Times 1 -Exactly -ParameterFilter {
            $Sql -eq "CREATE LOGIN [$Name] FROM EXTERNAL PROVIDER;"
        }
    }
}

Describe 'WindowsAD target default-domain failures in the worker' -Tag 'Unit' {
        BeforeEach {
            $Item = Read-ServerObjectItems -Path (Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json') -ItemId VM-Objects
            $Item.Logins = @($Item.Logins | Where-Object Type -eq WindowsAD)
            $rows = @(Get-ServerObjectProvisioningItems -Item $Item)
            $TargetSqlAuthType = 'Windows'
            $SqlCredential = $null
            $SqlPort = 1433
            $ServerOnly = $false
            $contextKey = ''
            $secretCache = @{}
            $loginInitialized = @{}
            $failedRows = @()
            $migrationDetails = @()
            $successCount = 0
            $skippedCount = 0
            Mock Ensure-AzContext {}
            Mock Write-Host {}
            Mock Invoke-SqlScalar { throw 'Unexpected SQL write or account resolution' }
            Mock Invoke-SqlNonQuery { throw 'Unexpected SQL write' }
            Mock Ensure-DatabaseUserAndAccess {}
        }

        It 'Rejects <Case> before CREATE LOGIN or database access, even if an account could resolve' -ForEach @(
            @{ Case = 'a trusted other domain'; ReportedDomain = 'OTHER'; ExpectedError = '*does not match TargetWindowsDomain*' },
            @{ Case = 'a null domain'; ReportedDomain = $null; ExpectedError = '*did not report*' },
            @{ Case = 'a missing domain value'; ReportedDomain = [DBNull]::Value; ExpectedError = '*did not report*' },
            @{ Case = 'an empty domain'; ReportedDomain = ''; ExpectedError = '*did not report*' },
            @{ Case = 'a whitespace domain'; ReportedDomain = '   '; ExpectedError = '*did not report*' }
        ) {
            Mock Invoke-SqlScalar { $ReportedDomain } -ParameterFilter { $Sql -eq 'SELECT DEFAULT_DOMAIN();' }
            $Failures = @(& $ProvisioningRowLoop)
            $Failures | Should -HaveCount $rows.Count
            foreach ($Failure in $Failures) { $Failure.Error | Should -BeLike $ExpectedError }
            Should -Invoke Invoke-SqlScalar -Times $rows.Count -Exactly -ParameterFilter {
                $Database -eq 'master' -and $Sql -eq 'SELECT DEFAULT_DOMAIN();'
            }
            Should -Invoke Invoke-SqlScalar -Times 0 -Exactly -ParameterFilter { $Sql -ne 'SELECT DEFAULT_DOMAIN();' }
            Should -Invoke Invoke-SqlNonQuery -Times 0 -Exactly
            Should -Invoke Ensure-DatabaseUserAndAccess -Times 0 -Exactly
        }
}
