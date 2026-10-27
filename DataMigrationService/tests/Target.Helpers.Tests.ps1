#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Invoke-RestoreDMS.ps1')
    function Invoke-Sqlcmd {
        [CmdletBinding()]
        param($ServerInstance, $Database, $Query, $ConnectionTimeout, $QueryTimeout, $AbortOnError,
            $DisableVariables, $DisableCommands, $Credential, [string]$AccessToken, $TrustServerCertificate)
        throw 'Unmocked SQL call'
    }
    function Set-AzContext { [CmdletBinding(SupportsShouldProcess)]param($SubscriptionId, $Scope) throw 'Unmocked Azure call' }
    function Get-AzAccessToken { [CmdletBinding()]param($ResourceUrl) throw 'Unmocked Azure call' }
    function Remove-AzDataMigrationToSqlVM { [CmdletBinding(SupportsShouldProcess)]param($ResourceGroupName, $TargetDbName, $SubscriptionId, $SqlVirtualMachineName) throw 'Unmocked mutation' }
    function Remove-AzDataMigrationToSqlManagedInstance { [CmdletBinding(SupportsShouldProcess)]param($ResourceGroupName, $TargetDbName, $SubscriptionId, $ManagedInstanceName) throw 'Unmocked mutation' }
    function Stop-AzDataMigrationToSqlVM { [CmdletBinding(SupportsShouldProcess)]param($ResourceGroupName, $TargetDbName, $SubscriptionId, $SqlVirtualMachineName, $MigrationOperationId) throw 'Unmocked mutation' }
    function Stop-AzDataMigrationToSqlManagedInstance { [CmdletBinding(SupportsShouldProcess)]param($ResourceGroupName, $TargetDbName, $SubscriptionId, $ManagedInstanceName, $MigrationOperationId) throw 'Unmocked mutation' }
    function Remove-AzSqlInstanceDatabase { [CmdletBinding(SupportsShouldProcess)]param($ResourceGroupName, $InstanceName, $Name, [switch]$Force) throw 'Unmocked mutation' }
}

Describe 'Target SQL preflight and authentication' -Tag 'Unit' {
    BeforeEach {
        $Config = Read-ServiceConfiguration (Join-Path $PSScriptRoot 'Fixtures\Restore.config.json')
        $Config.Common.TargetSqlAuthType = ''
        $Config.Common | Add-Member -NotePropertyMembers @{
            SqlCredentialMode = 'Interactive'; SqlCredentialPath = ''; SqlUserName = ''; credential = ''
        } -Force
        $Plan = @(New-DMSItemPlan -Items @(Resolve-DMSConfigurationItems $Config))
        $Credential = [pscredential]::new('test-login', (ConvertTo-SecureString 'fake-password' -AsPlainText -Force))
        $script:TestCredential = $Credential
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Read-Host { throw 'Unexpected prompt' }
        Mock Test-DMSInteractiveSession { $false }
        Mock Get-Credential { throw 'Unexpected credential prompt' }
        Mock Set-AzContext {}
        Mock Get-DMSItemInventory { @() }
        Mock Get-DMSMigrationDetail { @{ MigrationOperationId = 'operation'; MigrationStatus = 'Succeeded' } }
        Mock Invoke-Sqlcmd { @{ CanView = 1; CanAlter = 1; DatabaseId = [DBNull]::Value; CreatedAt = [DBNull]::Value } }
        Mock Get-AzAccessToken { @{ Token = (ConvertTo-SecureString 'fake-token' -AsPlainText -Force) } }
    }
    It 'Checks the configured VM host and port using SQL credentials without an Azure SQL token' {
        $Result = Get-DMSTargetDatabase -Item $Plan[0].Item -SqlCredential $Credential
        $Result.Exists | Should -BeFalse
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
            $ServerInstance -eq 'tcp:akpersonalsqlvm.centralus.cloudapp.azure.com,1433' -and
            $Credential.UserName -eq 'test-login' -and $Database -eq 'master' -and $DisableVariables -and $DisableCommands
        }
        Should -Invoke Get-AzAccessToken -Times 0 -Exactly
    }
    It 'Checks the MI public endpoint using the signed-in Entra identity, not SQL login credentials' {
        (Get-DMSTargetDatabase -Item $Plan[1].Item).Exists | Should -BeFalse
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
            $ServerInstance -eq 'tcp:ak-personal-sqlmi.public.3c52841dc1d0.database.windows.net,3342' -and
            $AccessToken -eq 'fake-token'
        }
        Should -Invoke Get-AzAccessToken -Times 1 -Exactly -ParameterFilter { $ResourceUrl -eq 'https://database.windows.net/' }
    }
    It 'Uses the current Windows identity for WindowsAD VM checks without SQL credentials or Entra tokens' {
        $Plan[0].Item.TargetSqlAuthType = 'WindowsAD'
        $Plan[0].Item.credential = 'must-not-be-loaded'
        $Credentials = @{}
        Initialize-DMSRestorePlan -Plan @($Plan[0]) -SqlCredentials $Credentials
        $Plan[0].RestoreState.Database.Exists | Should -BeFalse
        $Credentials.Keys | Should -HaveCount 0
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
            $ServerInstance -eq 'tcp:akpersonalsqlvm.centralus.cloudapp.azure.com,1433' -and
            -not $PesterBoundParameters.ContainsKey('Credential') -and
            -not $PesterBoundParameters.ContainsKey('AccessToken') -and $TrustServerCertificate
        }
        Should -Invoke Get-AzAccessToken -Times 0 -Exactly
        Should -Invoke Get-Credential -Times 0 -Exactly
    }
    It 'Rejects WindowsAD for MI even if a caller bypasses configuration validation' {
        $Plan[1].Item.TargetSqlAuthType = 'WindowsAD'
        { Get-DMSTargetDatabase -Item $Plan[1].Item } | Should -Throw '*requires a SQLVM target*'
        Should -Invoke Invoke-Sqlcmd -Times 0 -Exactly
        Should -Invoke Get-AzAccessToken -Times 0 -Exactly
    }
    It 'Does not fall back to Windows authentication when an Entra VM login fails' {
        $Plan[0].Item.TargetSqlAuthType = 'Entra'
        Mock Invoke-Sqlcmd { throw "Login failed for user ''" }
        { Get-DMSTargetDatabase -Item $Plan[0].Item } | Should -Throw "*Entra*Login failed*"
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter { $AccessToken -eq 'fake-token' }
    }
    It 'Uses configured SQL login for SQLMI without changing managed-identity Blob restoration' {
        $Plan[1].Item.TargetSqlAuthType = 'SqlLogin'
        (Get-DMSTargetDatabase -Item $Plan[1].Item -SqlCredential $Credential).Exists | Should -BeFalse
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
            $ServerInstance -eq 'tcp:ak-personal-sqlmi.public.3c52841dc1d0.database.windows.net,3342' -and $Credential.UserName -eq 'test-login'
        }
        Should -Invoke Get-AzAccessToken -Times 0 -Exactly
        $Plan[1].Item.BlobAuthType | Should -Be 'ManagedIdentity'
    }
    It 'Loads credentials for both SQL-login target types and still asks once for replacement approval' {
        $Plan[1].Item.TargetSqlAuthType = 'SqlLogin'
        foreach ($Entry in $Plan) { $Entry.Item.SqlCredentialMode = 'Configured' }
        Mock Get-DMSSqlCredential { $script:TestCredential }
        Mock Test-DMSInteractiveSession { $true }
        Mock Invoke-Sqlcmd { @{ CanView = 1; CanAlter = 1; DatabaseId = 7; CreatedAt = 'snapshot' } }
        Mock Read-Host { 'VM-MIGRDEMO,MI-MIGRDEMO' }
        $Credentials = @{}
        Initialize-DMSRestorePlan -Plan $Plan -SqlCredentials $Credentials
        $Credentials.Keys | Should -HaveCount 2
        $Plan[0].RestoreState.ReplaceExisting | Should -BeTrue
        $Plan[1].RestoreState.ReplaceExisting | Should -BeTrue
        Should -Invoke Read-Host -Times 1 -Exactly
        Should -Invoke Get-Credential -Times 0 -Exactly
        Should -Invoke Get-AzAccessToken -Times 0 -Exactly
    }
    It 'Does not treat missing visibility or query errors as database absence' {
        Mock Invoke-Sqlcmd { @{ CanView = 0; DatabaseId = [DBNull]::Value } }
        { Get-DMSTargetDatabase -Item $Plan[0].Item -SqlCredential $Credential } | Should -Throw '*VIEW ANY DATABASE*'
        Mock Invoke-Sqlcmd { throw 'SQL login failed' }
        { Get-DMSTargetDatabase -Item $Plan[0].Item -SqlCredential $Credential } | Should -Throw '*SQL login failed*'
    }
    It 'Identifies the item, SQL endpoint and authentication mode in SQL errors and preserves the cause' {
        Mock Invoke-Sqlcmd { throw 'Login failed for user' }
        $Failure = try { Get-DMSTargetDatabase -Item $Plan[0].Item -SqlCredential $Credential } catch { $_ }
        $Failure.Exception.Message | Should -BeLike "*VM-MIGRDEMO*tcp:akpersonalsqlvm.centralus.cloudapp.azure.com,1433*SqlLogin*Login failed*"
        $Failure.Exception.InnerException.Message | Should -Be 'Login failed for user'
        $Failure.Exception.Message | Should -Not -Match 'fake-password|fake-token'
    }
    It 'Loads a named local credential for both target types without a login prompt or secrets in the plan' {
        $LocalPath = Join-Path $TestDrive 'password.local.json'
        '{"credentials":{"sql_target":{"username":"test-login","password":"local-test-secret"}}}' |
            Set-Content -LiteralPath $LocalPath
        foreach ($Entry in $Plan) {
            $Entry.Item.TargetSqlAuthType = 'SqlLogin'
            $Entry.Item.credential = 'sql_target'
        }
        Mock Test-DMSInteractiveSession { $true }
        $Credentials = @{}
        Initialize-DMSRestorePlan -Plan $Plan -SqlCredentials $Credentials -CredentialFilePath $LocalPath
        foreach ($Id in @('VM-MIGRDEMO', 'MI-MIGRDEMO')) {
            $Credentials[$Id] | Should -BeOfType ([pscredential])
            $Credentials[$Id].UserName | Should -Be 'test-login'
            $Credentials[$Id].GetNetworkCredential().Password | Should -Be 'local-test-secret'
        }
        $Plan | ConvertTo-Json -Depth 30 | Should -Not -Match 'local-test-secret'
        Should -Invoke Get-Credential -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Get-AzAccessToken -Times 0 -Exactly
    }
    It 'Rejects an invalid named store without leaking its contents or falling back to a login prompt' -ForEach @(
        @{ Json = '{"credentials":{"sql_target":{"password":"local-test-secret"}}'; Expected = '*invalid JSON*' }
        @{ Json = '{"credentials":[],"password":"local-test-secret"}'; Expected = '*credentials object*' }
        @{ Json = '{"credentials":{"other":{"password":"local-test-secret"}}}'; Expected = "*sql_target*was not found*" }
        @{ Json = '{"credentials":{"sql_target":{"username":"","password":"local-test-secret"}}}'; Expected = '*nonempty username and password strings*' }
        @{ Json = '{"credentials":{"sql_target":{"username":"test","password":""}}}'; Expected = '*nonempty username and password strings*' }
        @{ Json = '{"credentials":{"sql_target":{"username":"test","password":123}}}'; Expected = '*nonempty username and password strings*' }
    ) {
        $LocalPath = Join-Path $TestDrive 'invalid.local.json'
        $Json | Set-Content -LiteralPath $LocalPath
        $Plan[0].Item.credential = 'sql_target'
        Mock Test-DMSInteractiveSession { $true }
        $Failure = try { Get-DMSSqlCredential -Item $Plan[0].Item -CredentialFilePath $LocalPath } catch { $_ }
        $Failure | Should -BeOfType ([Management.Automation.ErrorRecord])
        $Failure.Exception.Message | Should -BeLike $Expected
        $Failure.Exception.Message | Should -Not -Match 'local-test-secret'
        Should -Invoke Get-Credential -Times 0 -Exactly
    }
    It 'Fails explicitly when a named credential file is missing' {
        $Plan[0].Item.credential = 'sql_target'
        { Get-DMSSqlCredential -Item $Plan[0].Item -CredentialFilePath (Join-Path $TestDrive 'missing.json') } |
            Should -Throw '*does not exist*'
        Should -Invoke Get-Credential -Times 0 -Exactly
    }
    It 'Rejects system database targets before querying SQL' -ForEach @(
        @{ Name = 'master' }, @{ Name = 'model' }, @{ Name = 'msdb' }, @{ Name = 'tempdb' }
    ) {
        $Plan[0].Item.TrgDatabaseName = $Name
        { Get-DMSTargetDatabase -Item $Plan[0].Item -SqlCredential $Credential } | Should -Throw '*System database*'
        Should -Invoke Invoke-Sqlcmd -Times 0 -Exactly
    }
    It 'Records missing VM credentials and continues MI validation without opening a credential dialog' {
        Initialize-DMSRestorePlan -Plan $Plan
        $Plan[0].Result.Status | Should -Be 'Failed'
        $Plan[0].Result.Error | Should -BeLike '*needs interactive SQL sign-in*'
        $Plan[0].PSObject.Properties.Name | Should -Not -Contain 'RestoreState'
        $Plan[1].RestoreState.Database.Exists | Should -BeFalse
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter { $AccessToken -eq 'fake-token' }
    }
    It 'Records a VM SQL failure and checks the next MI instead of treating the VM database as absent' {
        $Plan[0].Item.TargetSqlAuthType = 'Entra'
        Mock Invoke-Sqlcmd {
            if ($ServerInstance -like '*akpersonalsqlvm*') { throw "Login failed for user ''" }
            @{ CanView = 1; CanAlter = 1; DatabaseId = [DBNull]::Value; CreatedAt = [DBNull]::Value }
        }
        Initialize-DMSRestorePlan -Plan $Plan
        $Plan[0].Result.Status | Should -Be 'Failed'
        $Plan[0].Result.Error | Should -BeLike "*Target validation*Entra*Login failed*"
        $Plan[0].PSObject.Properties.Name | Should -Not -Contain 'RestoreState'
        $Plan[1].Result.Status | Should -Be 'Pending'
        $Plan[1].RestoreState.Database.Exists | Should -BeFalse
        Should -Invoke Invoke-Sqlcmd -Times 2 -Exactly
        Should -Invoke Get-DMSItemInventory -Times 1 -Exactly -ParameterFilter { $Item.Id -eq 'MI-MIGRDEMO' }
    }
    It 'Does not query targets that already failed resource preflight' {
        $Plan[0].Result.Status = 'Failed'
        $Plan[0].Result.Error = 'Original resource error'
        Initialize-DMSRestorePlan -Plan $Plan
        $Plan[0].Result.Error | Should -Be 'Original resource error'
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter { $ServerInstance -like '*ak-personal-sqlmi*' }
    }
    It 'Loads a same-user encrypted SQL credential file without storing the password in JSON' {
        $Plan[0].Item.SqlCredentialPath = Join-Path $TestDrive 'credential.xml'
        $Credential | Export-Clixml -LiteralPath $Plan[0].Item.SqlCredentialPath
        $Credentials = @{}
        Initialize-DMSRestorePlan -Plan $Plan -SqlCredentials $Credentials
        $Credentials['VM-MIGRDEMO'].UserName | Should -Be 'test-login'
        $Credentials['VM-MIGRDEMO'] | Should -BeOfType ([pscredential])
        Should -Invoke Read-Host -Times 0 -Exactly
    }
    It 'Collects one exact-item replacement approval and skips unselected existing targets' {
        Mock Test-DMSInteractiveSession { $true }
        Mock Invoke-Sqlcmd { @{ CanView = 1; CanAlter = 1; DatabaseId = 7; CreatedAt = '2026-10-23T01:00:00' } }
        Mock Read-Host { 'MI-MIGRDEMO' }
        Initialize-DMSRestorePlan -Plan $Plan -SqlCredentials @{ 'VM-MIGRDEMO' = $Credential }
        $Plan[0].RestoreState.Skip | Should -BeTrue
        $Plan[0].RestoreState.ReplaceExisting | Should -BeFalse
        $Plan[1].RestoreState.ReplaceExisting | Should -BeTrue
        Should -Invoke Read-Host -Times 1 -Exactly
    }
    It 'Never requests replacement approval during WhatIf preflight' {
        Mock Invoke-Sqlcmd { @{ CanView = 1; CanAlter = 1; DatabaseId = 7; CreatedAt = '2026-10-23T01:00:00' } }
        Initialize-DMSRestorePlan -Plan $Plan -SqlCredentials @{ 'VM-MIGRDEMO' = $Credential } -Preview
        Should -Invoke Read-Host -Times 0 -Exactly
        $Plan[0].RestoreState.ReplaceExisting | Should -BeFalse
    }
    It 'Rejects unknown approval IDs before launching anything' {
        Mock Test-DMSInteractiveSession { $true }
        Mock Invoke-Sqlcmd { @{ CanView = 1; CanAlter = 1; DatabaseId = 7; CreatedAt = '2026-10-23T01:00:00' } }
        Mock Read-Host { 'not-displayed' }
        { Initialize-DMSRestorePlan -Plan $Plan -SqlCredentials @{ 'VM-MIGRDEMO' = $Credential } } | Should -Throw '*not in the displayed*'
    }
    It 'Requires database deletion permission only for approved existing databases' {
        Mock Test-DMSInteractiveSession { $true }
        Mock Invoke-Sqlcmd { @{ CanView = 1; CanAlter = 0; DatabaseId = 7; CreatedAt = '2026-10-23T01:00:00' } }
        Mock Read-Host { 'VM-MIGRDEMO' }
        Initialize-DMSRestorePlan -Plan $Plan -SqlCredentials @{ 'VM-MIGRDEMO' = $Credential }
        $Plan[0].Result.Status | Should -Be 'Failed'
        $Plan[0].Result.Error | Should -BeLike '*ALTER ANY DATABASE*'
        $Plan[1].RestoreState.Skip | Should -BeTrue
    }
    It 'Prefers interactive SQL login over configured credentials' {
        Mock Test-DMSInteractiveSession { $true }
        Mock Get-Credential { $script:TestCredential }
        $Plan[0].Item.SqlCredentialPath = 'must-not-be-read.xml'
        (Get-DMSSqlCredential -Item $Plan[0].Item).UserName | Should -Be 'test-login'
        Should -Invoke Get-Credential -Times 1 -Exactly
    }
    It 'Configured credential mode bypasses login prompts without disabling interactive replacement approval' {
        $Path = Join-Path $TestDrive 'configured.credential.xml'
        $Credential | Export-Clixml -LiteralPath $Path
        $Plan[0].Item.SqlCredentialPath = $Path
        $Plan[0].Item.SqlCredentialMode = 'Configured'
        Mock Test-DMSInteractiveSession { $true }
        (Get-DMSSqlCredential -Item $Plan[0].Item).UserName | Should -Be 'test-login'
        Should -Invoke Get-Credential -Times 0 -Exactly
    }
    It 'Uses configured username and environment password without a prompt in unattended mode' {
        $Plan[0].Item.SqlUserName = 'configured-login'
        $Plan[0].Item.SqlPasswordEnvironmentVariable = 'SQLMIGRATION_UNIT_TEST_PASSWORD'
        [Environment]::SetEnvironmentVariable('SQLMIGRATION_UNIT_TEST_PASSWORD', 'fake-password')
        try {
            $Result = Get-DMSSqlCredential -Item $Plan[0].Item -NonInteractive
            $Result.UserName | Should -Be 'configured-login'
            $Result.GetNetworkCredential().Password | Should -Be 'fake-password'
            Should -Invoke Get-Credential -Times 0 -Exactly
        }
        finally { [Environment]::SetEnvironmentVariable('SQLMIGRATION_UNIT_TEST_PASSWORD', $null) }
    }
    It 'Prompts for SQL login once when multiple databases share the same VM endpoint' {
        Mock Test-DMSInteractiveSession { $true }
        Mock Get-Credential { $script:TestCredential }
        $Second = $Plan[0].Item | ConvertTo-Json | ConvertFrom-Json
        $Second.Id = 'VM-SecondDb'
        $Second.TrgDatabaseName = 'SecondDb'
        $Plan += @(New-DMSItemPlan -Items @($Second))
        Initialize-DMSRestorePlan -Plan $Plan
        Should -Invoke Get-Credential -Times 1 -Exactly
    }
    It 'Does not fall back silently when interactive credential entry is canceled' {
        Mock Test-DMSInteractiveSession { $true }
        Mock Get-Credential { $null }
        $Plan[0].Item.SqlCredentialPath = 'must-not-be-read.xml'
        { Get-DMSSqlCredential -Item $Plan[0].Item } | Should -Throw '*canceled*'
    }
    It 'Skips existing targets without requesting destructive approval in unattended mode' {
        Mock Invoke-Sqlcmd { @{ CanView = 1; CanAlter = 1; DatabaseId = 7; CreatedAt = 'snapshot' } }
        Initialize-DMSRestorePlan -Plan $Plan -SqlCredentials @{ 'VM-MIGRDEMO' = $Credential } -NonInteractive
        $Plan[0].RestoreState.Skip | Should -BeTrue
        $Plan[1].RestoreState.Skip | Should -BeTrue
        Should -Invoke Read-Host -Times 0 -Exactly
    }
}

Describe 'Explicitly approved target replacement' -Tag 'Unit' {
    BeforeEach {
        $Config = Read-ServiceConfiguration (Join-Path $PSScriptRoot 'Fixtures\Restore.config.json')
        $Plan = @(New-DMSItemPlan -Items @(Resolve-DMSConfigurationItems $Config))
        foreach ($Entry in $Plan) {
            $Entry | Add-Member -NotePropertyName RestoreState -NotePropertyValue ([pscustomobject]@{
                Database = [pscustomobject]@{ Exists = $true; DatabaseId = 7; CreatedAt = 'snapshot'; CanAlter = $true }
                MigrationId = 'old-migration'; OperationId = 'operation'; ReplaceExisting = $true; Skip = $false
            })
        }
        $script:Removed = $false
        $script:Dropped = $false
        $script:Canceled = $false
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Start-Sleep {}
        Mock Get-DMSTargetDatabase {
            [pscustomobject]@{
                Exists = -not $script:Dropped; DatabaseId = $(if ($script:Dropped) { 0 } else { 7 })
                CreatedAt = $(if ($script:Dropped) { '' } else { 'snapshot' }); CanAlter = $true
            }
        }
        Mock Get-DMSItemInventory { if (-not $script:Removed) { @{ Id = 'old-migration' } } }
        Mock Get-DMSMigrationDetail { @{ MigrationOperationId = 'operation'; MigrationStatus = 'Succeeded' } }
        Mock Remove-AzDataMigrationToSqlVM { $script:Removed = $true }
        Mock Remove-AzDataMigrationToSqlManagedInstance { $script:Removed = $true }
        Mock Stop-AzDataMigrationToSqlVM { $script:Canceled = $true }
        Mock Stop-AzDataMigrationToSqlManagedInstance { $script:Canceled = $true }
        Mock Invoke-DMSTargetQuery {
            $script:Removed | Should -BeTrue
            $script:Dropped = $true
        }
        Mock Remove-AzSqlInstanceDatabase {
            $script:Removed | Should -BeTrue
            $script:Dropped = $true
        }
    }
    It 'Removes only the approved record before deleting its SQLVM database and escapes identifiers' {
        $Plan[0].Item.TrgDatabaseName = 'App]Db'
        Reset-DMSRestoreTarget -Entry $Plan[0]
        Should -Invoke Remove-AzDataMigrationToSqlVM -Times 1 -Exactly -ParameterFilter { $TargetDbName -eq 'App]Db' -and -not $Confirm }
        Should -Invoke Invoke-DMSTargetQuery -Times 1 -Exactly -ParameterFilter {
            $Query -eq 'ALTER DATABASE [App]]Db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [App]]Db];'
        }
        Should -Invoke Remove-AzSqlInstanceDatabase -Times 0 -Exactly
    }
    It 'Removes the SQLMI database through its Azure resource without a VM-only SINGLE_USER statement' {
        Reset-DMSRestoreTarget -Entry $Plan[1]
        Should -Invoke Remove-AzSqlInstanceDatabase -Times 1 -Exactly -ParameterFilter {
            $InstanceName -eq 'ak-personal-sqlmi' -and $Name -eq 'MIGRDEMO' -and $Force -and -not $Confirm
        }
        Should -Invoke Invoke-DMSTargetQuery -Times 0 -Exactly
    }
    It 'Cancels an active migration and verifies termination before removing its record' {
        Mock Get-DMSMigrationDetail {
            @{ MigrationOperationId = 'operation'; MigrationStatus = $(if ($script:Canceled) { 'Cancelled' } else { 'Restoring' }) }
        }
        Mock Remove-AzDataMigrationToSqlVM {
            $script:Canceled | Should -BeTrue
            $script:Removed = $true
        }
        Reset-DMSRestoreTarget -Entry $Plan[0]
        Should -Invoke Stop-AzDataMigrationToSqlVM -Times 1 -Exactly -ParameterFilter { $MigrationOperationId -eq 'operation' }
        $script:Dropped | Should -BeTrue
    }
    It 'Refuses changed databases or changed migration operations after approval' -ForEach @(
        @{ Changed = 'Database' }, @{ Changed = 'Operation' }
    ) {
        if ($Changed -eq 'Database') { Mock Get-DMSTargetDatabase { @{ Exists = $true; DatabaseId = 8; CreatedAt = 'new-database' } } }
        else { Mock Get-DMSMigrationDetail { @{ MigrationOperationId = 'new-operation'; MigrationStatus = 'Restoring' } } }
        { Reset-DMSRestoreTarget -Entry $Plan[0] } | Should -Throw '*changed after approval*'
        Should -Invoke Remove-AzDataMigrationToSqlVM -Times 0 -Exactly
        Should -Invoke Invoke-DMSTargetQuery -Times 0 -Exactly
    }
    It 'Never deletes a database when migration-record removal fails' {
        Mock Remove-AzDataMigrationToSqlVM { throw 'Deletion denied' }
        { Reset-DMSRestoreTarget -Entry $Plan[0] } | Should -Throw '*Deletion denied*'
        Should -Invoke Invoke-DMSTargetQuery -Times 0 -Exactly
    }
    It 'Refuses to remove a new migration operation observed while cancellation is being verified' {
        Mock Get-DMSMigrationDetail {
            @{
                MigrationOperationId = $(if ($script:Canceled) { 'new-operation' } else { 'operation' })
                MigrationStatus = $(if ($script:Canceled) { 'Succeeded' } else { 'Restoring' })
            }
        }
        { Reset-DMSRestoreTarget -Entry $Plan[0] } | Should -Throw '*changed after approval*'
        Should -Invoke Remove-AzDataMigrationToSqlVM -Times 0 -Exactly
        Should -Invoke Invoke-DMSTargetQuery -Times 0 -Exactly
    }
    It 'Refuses replacement without explicit approval' {
        $Plan[0].RestoreState.ReplaceExisting = $false
        { Reset-DMSRestoreTarget -Entry $Plan[0] } | Should -Throw '*approval is required*'
        Should -Invoke Get-DMSTargetDatabase -Times 0 -Exactly
    }
}
