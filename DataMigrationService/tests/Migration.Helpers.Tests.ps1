#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

class TestDMSMigrationKind {
    [string]$Value
    TestDMSMigrationKind([string]$Value) { $this.Value = $Value }
    [string] ToString() { return $this.Value }
    [bool] Equals([object]$Other) { return $this.Value -ceq [string]$Other }
}

BeforeAll {
    $Scripts = Join-Path $PSScriptRoot '..\scripts'
    . (Join-Path $Scripts 'Common\Migration.Helpers.ps1')
    . (Join-Path $Scripts 'Common\Workflow.Helpers.ps1')
    function Get-SourceFunctions {
        param([string]$Path, [string[]]$Names)
        $Tokens = $null; $Errors = $null
        $Ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)
        if ($Errors.Count) { throw $Errors[0] }
        $Functions = @($Ast.FindAll({
            param($Node)
            $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -in $Names
        }, $true))
        foreach ($Name in $Names) {
            if ($Name -notin $Functions.Name) { throw "Function '$Name' not found in '$Path'." }
        }
        [scriptblock]::Create(($Functions.Extent.Text -join "`n"))
    }
    function Get-AzStorageAccountKey { [CmdletBinding()]param($ResourceGroupName, $Name) throw 'Unmocked Azure call' }
    function Get-AzContext { throw 'Unmocked Azure call' }
    function Remove-AzDataMigrationToSqlManagedInstance { [CmdletBinding(SupportsShouldProcess)]param($SubscriptionId, $ResourceGroupName, $TargetDbName, $ManagedInstanceName) throw 'Unmocked Azure call' }
    function Remove-AzDataMigrationToSqlVM { [CmdletBinding(SupportsShouldProcess)]param($SubscriptionId, $ResourceGroupName, $TargetDbName, $SqlVirtualMachineName) throw 'Unmocked Azure call' }
    function Set-AzContext { [CmdletBinding(SupportsShouldProcess)]param($SubscriptionId, $Scope) throw 'Unmocked Azure call' }
    function Get-AzDataMigrationSqlService { [CmdletBinding()]param($ResourceGroupName, $SubscriptionId, $Name) throw 'Unmocked Azure call' }
    function Get-AzDataMigrationSqlServiceMigration { [CmdletBinding()]param($ResourceGroupName, $SqlMigrationServiceName, $SubscriptionId) throw 'Unmocked Azure call' }
    function Invoke-AzDataMigrationCutoverToSqlManagedInstance { [CmdletBinding()]param($SubscriptionId, $ResourceGroupName, $TargetDbName, $MigrationOperationId, $ManagedInstanceName) throw 'Unmocked Azure call' }
    function Invoke-AzDataMigrationCutoverToSqlVM { [CmdletBinding()]param($SubscriptionId, $ResourceGroupName, $TargetDbName, $MigrationOperationId, $SqlVirtualMachineName) throw 'Unmocked Azure call' }
    function New-AzStorageContext { [CmdletBinding()]param($StorageAccountName, [switch]$UseConnectedAccount) throw 'Unmocked Azure call' }
    function Get-AzStorageBlob { [CmdletBinding()]param($Container, $Context) throw 'Unmocked Azure call' }
    function Get-AzDataMigrationToSqlManagedInstance { [CmdletBinding()]param($SubscriptionId, $ResourceGroupName, $TargetDbName, $ManagedInstanceName) throw 'Unmocked Azure call' }
    function Get-AzDataMigrationToSqlVM { [CmdletBinding()]param($SubscriptionId, $ResourceGroupName, $TargetDbName, $SqlVirtualMachineName) throw 'Unmocked Azure call' }
    function New-AzDataMigrationToSqlManagedInstance {
        [CmdletBinding()]param($ResourceGroupName, $ManagedInstanceName, $TargetDbName, $SubscriptionId,
            $AzureBlobAuthType, $AzureBlobIdentityType, $AzureBlobUserAssignedIdentity, $AzureBlobAccountKey,
            $AzureBlobContainerName, $AzureBlobStorageAccountResourceId, $Kind, $MigrationService, $Scope)
        throw 'Unmocked Azure call'
    }
    function New-AzDataMigrationToSqlVM {
        [CmdletBinding()]param($ResourceGroupName, $SqlVirtualMachineName, $TargetDbName, $SubscriptionId,
            $AzureBlobAuthType, $AzureBlobIdentityType, $AzureBlobUserAssignedIdentity, $AzureBlobAccountKey,
            $AzureBlobContainerName, $AzureBlobStorageAccountResourceId, $Kind, $MigrationService, $Scope)
        throw 'Unmocked Azure call'
    }
    function New-TestMigration {
        param([string]$Target = 'target', [string]$Database = 'db', [string]$Kind = 'SqlMi')
        [pscustomobject]@{
            Id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/target-rg/providers/Microsoft.Sql/managedInstances/$Target/providers/Microsoft.DataMigration/databaseMigrations/$Database"
            SubscriptionId = '11111111-1111-1111-1111-111111111111'; ResourceGroup = 'target-rg'
            TargetName = $Target; DatabaseName = $Database; Kind = $Kind; MigrationStatus = 'ReadyForCutover'
        }
    }

}

Describe 'Source-derived backup container naming' -Tag 'Unit' {
    It 'Preserves normalization for <Server> and <Database>' -ForEach @(
        @{ Server = 'SQLServerMigVM'; Database = 'MIGRDEMO'; Expected = 'sqlservermigvm-migrdemo' }
        @{ Server = 'SeRvEr\InStAnCe'; Database = 'AppDb'; Expected = 'server-instance-appdb' }
        @{ Server = 'Server.Name\SQL_Instance'; Database = ' App__ DB-- '; Expected = 'server-name-sql-instance-app-db' }
        @{ Server = 'a'; Database = 'b'; Expected = 'a-b' }
        @{ Server = 'a'; Database = '_'; Expected = 'db-a' }
        @{ Server = 'SERVER'; Database = '应用'; Expected = 'server' }
    ) {
        Get-ContainerName -ServerName $Server -DatabaseName $Database | Should -BeExactly $Expected
    }
    It 'Retains 63-character truncation and trims the resulting trailing separator' {
        Get-ContainerName -ServerName ('s' * 70) -DatabaseName 'db' | Should -BeExactly ('s' * 63)
        Get-ContainerName -ServerName ('s' * 62) -DatabaseName 'db' | Should -BeExactly ('s' * 62)
    }
    It 'Rejects malformed source server or instance <Server>' -ForEach @(
        @{ Server = '' }, @{ Server = ' ' }, @{ Server = '\instance' }, @{ Server = 'server\' }
        @{ Server = 'server\\instance' }, @{ Server = 'server\instance\extra' }
        @{ Server = '<server>' }, @{ Server = 'server/instance' }, @{ Server = 'tcp:server,1433' }
        @{ Server = 'server\ ' }, @{ Server = '---' }
    ) {
        { Get-ContainerName -ServerName $Server -DatabaseName 'db' } | Should -Throw '*SrcServerName*'
    }
    It 'Rejects malformed source database <Database>' -ForEach @(
        @{ Database = '' }, @{ Database = ' ' }, @{ Database = '<database>' }
        @{ Database = "db`nname" }
    ) {
        { Get-ContainerName -ServerName 'server' -DatabaseName $Database } | Should -Throw '*SrcDatabaseName*'
    }
}

Describe 'Backup timestamps' -Tag 'Unit' {
    It 'Parses built-in <Name>' -ForEach @(
        @{ Name = 'db_20250102_030405.bak'; Expected = '2025-01-02T03:04:05' }
        @{ Name = 'db_2025-01-02_03-04-05.diff'; Expected = '2025-01-02T03:04:05' }
        @{ Name = 'db_2025-01-02T03-04-05.trn'; Expected = '2025-01-02T03:04:05' }
        @{ Name = 'db_20250102030405.log'; Expected = '2025-01-02T03:04:05' }
        @{ Name = 'db_backup_2025_1_2.bak'; Expected = '2025-01-02T00:00:00' }
    ) {
        (Get-MigrationBackupTimestamp -FileName $Name).ToString('s') | Should -Be $Expected
    }
    It 'Uses the final timestamp rather than an earlier database-name timestamp' {
        (Get-MigrationBackupTimestamp -FileName 'db_20240101_000000_20250102_030405.bak').Year | Should -Be 2025
    }
    It 'Supports a custom named capture and invariant date format' {
        (Get-MigrationBackupTimestamp -FileName 'db_02Jan2025-030405.bak' -TimestampPattern '(?<ts>\d{2}[A-Za-z]{3}\d{4}-\d{6})' -TimestampFormat 'ddMMMyyyy-HHmmss').Day | Should -Be 2
    }
    It 'Rejects incomplete or unnamed custom patterns' {
        { Assert-MigrationTimestampOptions -TimestampPattern '(?<ts>\d+)' } | Should -Throw '*together*'
        { Assert-MigrationTimestampOptions -TimestampFormat 'yyyy' } | Should -Throw '*together*'
        { Assert-MigrationTimestampOptions -TimestampPattern '(\d+)' -TimestampFormat 'yyyy' } | Should -Throw '*named group*'
    }
    It 'Does not turn invalid or missing dates into usable backups' {
        Get-MigrationBackupTimestamp -FileName 'db_20250230_000000.bak' | Should -BeNullOrEmpty
        Get-MigrationBackupTimestamp -FileName 'db.bak' | Should -BeNullOrEmpty
    }
}

Describe 'DMS Blob authentication' -Tag 'Unit' {

    It 'Uses system-assigned managed identity without passing or retrieving a key' {
        $Auth = Get-DMSBlobAuthentication -BlobAuthType ManagedIdentity -StorageAccountName 'storage' -ResourceGroupName 'backups'
        $Auth.Count | Should -Be 2
        $Auth.AzureBlobAuthType | Should -Be 'ManagedIdentity'
        $Auth.AzureBlobIdentityType | Should -Be 'SystemAssigned'
        Should -Invoke Get-AzStorageAccountKey -Times 0 -Exactly
    }
    BeforeEach { Mock Get-AzStorageAccountKey { @([pscustomobject]@{ Value = 'test-key' }) } }
    It 'Defaults to a storage key retrieved under the current Azure context' {
        $Auth = Get-DMSBlobAuthentication -StorageAccountName 'storage' -ResourceGroupName 'backups'
        $Auth.AzureBlobAccountKey | Should -Be 'test-key'
        $Auth.ContainsKey('AzureBlobAuthType') | Should -BeFalse
        Should -Invoke Get-AzStorageAccountKey -Times 1 -Exactly -ParameterFilter {
            $ResourceGroupName -eq 'backups' -and $Name -eq 'storage'
        }
    }
    It 'Supports an explicitly attached user-assigned identity' {
        $Id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/identity'
        $Auth = Get-DMSBlobAuthentication -StorageAccountName 'storage' -ResourceGroupName 'backups' -BlobAuthType ManagedIdentity -BlobIdentityType UserAssigned -BlobUserAssignedIdentity $Id
        $Auth.AzureBlobUserAssignedIdentity | Should -Be $Id
        Should -Invoke Get-AzStorageAccountKey -Times 0 -Exactly
    }
    It 'Rejects invalid combinations before any Azure mutation' {
        { Assert-DMSBlobIdentityOptions -BlobAuthType ManagedIdentity -BlobIdentityType UserAssigned } | Should -Throw '*resource ID*'
        { Assert-DMSBlobIdentityOptions -BlobAuthType ManagedIdentity -BlobUserAssignedIdentity 'identity' } | Should -Throw '*requires*'
        { Assert-DMSBlobIdentityOptions -BlobAuthType AccountKey -BlobIdentityType UserAssigned } | Should -Throw '*cannot be combined*'
    }
    It 'Supports explicit account-key authentication' {
        (Get-DMSBlobAuthentication -StorageAccountName 'storage' -ResourceGroupName 'backups' -BlobAuthType AccountKey).AzureBlobAccountKey | Should -Be 'test-key'
        Should -Invoke Get-AzStorageAccountKey -Times 1 -Exactly
    }
    It 'Rejects empty storage keys' {
        Mock Get-AzStorageAccountKey { @() }
        { Get-DMSBlobAuthentication -StorageAccountName 'storage' -ResourceGroupName 'backups' } | Should -Throw '*No account key*'
    }
    It 'Propagates storage-key permission failures without falling back' {
        Mock Get-AzStorageAccountKey { throw 'Storage listKeys access denied' }
        { Get-DMSBlobAuthentication -StorageAccountName 'storage' -ResourceGroupName 'backups' } | Should -Throw '*listKeys access denied*'
    }
    It 'Checks installed command capabilities rather than silently falling back' {
        Assert-DMSAuthenticationSupport -CommandName New-AzDataMigrationToSqlVM -BlobAuthType ManagedIdentity -BlobIdentityType UserAssigned
        { Assert-DMSAuthenticationSupport -CommandName Get-Date -BlobAuthType ManagedIdentity -BlobIdentityType SystemAssigned } | Should -Throw '*authentication mode is blocked*No authentication fallback*'
    }
}

Describe 'Independent DMS discovery and cutover' -Tag 'Unit' {
    BeforeEach {
        Mock Set-AzContext {}
        Mock Start-Sleep {}
        Mock Write-Warning {}
        Mock Invoke-AzDataMigrationCutoverToSqlManagedInstance {}
        Mock Invoke-AzDataMigrationCutoverToSqlVM {}
    }
    It 'Uses the actual restored file, never the currently restoring file' {
        $Backup = Get-DMSLatestRestoredBackup -Detail @{ MigrationStatusDetail = @{ LastRestoredFilename = 'done.bak'; CurrentRestoringFilename = 'pending.trn'; ActiveBackupLastRestoredTime = '2025-01-01T00:00:00Z' } }
        $Backup.LatestFile | Should -Be 'done.bak'
        $Backup.TimestampSource | Should -Be 'DMS'
        (Get-DMSLatestRestoredBackup -Detail @{ MigrationStatusDetail = @{ CurrentRestoringFilename = 'pending.trn' } }).LatestFile | Should -BeNullOrEmpty
    }
    It 'Labels filename-derived time separately from DMS restored time' {
        (Get-DMSLatestRestoredBackup -Detail @{ LastRestoredFilename = 'db_20250102_030405.bak' }).TimestampSource | Should -Be 'Filename'
    }
    It 'Discovers across subscriptions/groups and filters service, target and platform' {
        Mock Set-AzContext {}
        Mock Get-AzDataMigrationSqlService { @(@{ Name = 'selected' }, @{ Name = 'other' }) }
        Mock Get-AzDataMigrationSqlServiceMigration {
            @((New-TestMigration), (New-TestMigration -Target 'other'), (New-TestMigration -Kind SqlVm -Database 'vmdb'))
        }
        $Items = @(Get-DMSMigrationInventory -SubscriptionId @('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222') -ResourceGroupName @('one', 'two') -DMSServiceName 'selected' -TargetName 'target' -TargetType SqlMI)
        $Items.Count | Should -Be 1
        $Items[0].ResourceGroup | Should -Be 'target-rg'
        Should -Invoke Get-AzDataMigrationSqlServiceMigration -Times 4 -Exactly -ParameterFilter { $SqlMigrationServiceName -eq 'selected' }
    }
    It 'Rejects missing, ambiguous, unready or unscoped cutover selections' {
        $Item = New-TestMigration
        { Select-DMSCutoverMigration -Migrations @($Item) -Names @('missing') -Target 'target' } | Should -Throw
        { Select-DMSCutoverMigration -Migrations @($Item, $Item) -Names @('db') -Target 'target' } | Should -Throw
        { Select-DMSCutoverMigration -Migrations @($Item) -Names @('db') -Target '' } | Should -Throw
        $Item.MigrationStatus = 'Restoring'
        { Select-DMSCutoverMigration -Migrations @($Item) -Names @('db') -Target 'target' } | Should -Throw
    }
    It 'Filters exact database and target group before querying details of unrelated migrations' {
        Mock Get-AzDataMigrationSqlService { @{ Name = 'selected' } }
        Mock Get-AzDataMigrationSqlServiceMigration {
            $OtherGroup = New-TestMigration
            $OtherGroup.Id = $OtherGroup.Id.Replace('/target-rg/', '/other-rg/')
            @((New-TestMigration), (New-TestMigration -Database unrelated), $OtherGroup)
        }
        Mock Get-DMSMigrationDetail { @{ MigrationStatus = 'Succeeded' } }
        $Items = @(Get-DMSMigrationInventory -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -ResourceGroupName dms -DMSServiceName selected -TargetName target -TargetResourceGroup target-rg -Databases db -IncludeDetails)
        $Items | Should -HaveCount 1
        $Items[0].DatabaseName | Should -Be 'db'
        $Items[0].ResourceGroup | Should -Be 'target-rg'
        Should -Invoke Get-DMSMigrationDetail -Times 1 -Exactly
    }
    It 'Normalizes typed Azure kinds before filtering <Kind> by <TargetType>' -ForEach @(
        @{ Kind = 'SqlVm'; TargetType = 'SqlVM' }
        @{ Kind = 'SqlMi'; TargetType = 'SqlMI' }
    ) {
        Mock Set-AzContext {}
        Mock Get-AzDataMigrationSqlService { @{ Name = 'selected' } }
        Mock Get-AzDataMigrationSqlServiceMigration {
            $Migration = New-TestMigration -Kind $Kind
            $Migration.Kind = [TestDMSMigrationKind]::new($Kind)
            $Migration
        }
        Mock Get-DMSMigrationDetail { @{ MigrationStatus = 'ReadyForCutover' } }
        $Items = @(Get-DMSMigrationInventory -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -ResourceGroupName 'dms' -DMSServiceName 'selected' -TargetName 'target' -TargetType $TargetType -IncludeDetails)
        $Items.Count | Should -Be 1
        $Items[0].Kind | Should -BeOfType ([string])
        $Items[0].Kind | Should -BeExactly $Kind
        $Items[0].MigrationStatus | Should -Be 'ReadyForCutover'
        (Select-DMSCutoverMigration -Migrations $Items -Names 'db' -Target 'target').DatabaseName | Should -Be 'db'
        Should -Invoke Get-DMSMigrationDetail -Times 1 -Exactly
    }
    It 'Accepts both readiness spellings' -ForEach @(@{ Ready = 'ReadyForCutover' }, @{ Ready = 'ReadyToCutover' }) {
        Mock Get-DMSMigrationDetail { @{ MigrationStatus = $Ready; MigrationOperationId = 'operation' } }
        $Selected = @(Select-DMSCutoverMigration -Migrations @((New-TestMigration)) -Names @('db') -Target 'target')
        $Selected.Count | Should -Be 1
        $Result = @(Invoke-DMSRollingCutover -Migrations $Selected -WhatIf)
        $Result[0].Status | Should -Be 'WhatIf'
        Should -Invoke Invoke-AzDataMigrationCutoverToSqlManagedInstance -Times 0 -Exactly
    }
    It 'Refills the queue after failures and initiates each surviving cutover once' {
        $script:Calls = @{}
        Mock Get-DMSMigrationDetail {
            param($Migration)
            if ($Migration.DatabaseName -eq 'bad') { throw 'readiness failure' }
            $script:Calls[$Migration.Id]++
            @{ MigrationStatus = $(if ($script:Calls[$Migration.Id] -eq 1) { 'ReadyForCutover' } else { 'Succeeded' }); MigrationOperationId = 'operation' }
        }
        $Results = @(Invoke-DMSRollingCutover -Migrations @((New-TestMigration -Database 'bad'), (New-TestMigration -Database 'good'), (New-TestMigration -Database 'last')) -MaxConcurrentCutover 1 -MonitorIntervalSeconds 1)
        @($Results | Where-Object Status -eq 'Failed').Count | Should -Be 1
        @($Results | Where-Object Status -eq 'Succeeded').Count | Should -Be 2
        Should -Invoke Invoke-AzDataMigrationCutoverToSqlManagedInstance -Times 2 -Exactly
    }
    It 'Tracks duplicate database names on different targets by full resource ID' {
        $script:Calls = @{}
        Mock Get-DMSMigrationDetail {
            param($Migration)
            $script:Calls[$Migration.Id]++
            @{ MigrationStatus = $(if ($script:Calls[$Migration.Id] -eq 1) { 'ReadyToCutover' } else { 'Succeeded' }); MigrationOperationId = 'operation' }
        }
        $Results = @(Invoke-DMSRollingCutover -Migrations @((New-TestMigration -Target 'one'), (New-TestMigration -Target 'two' -Kind SqlVm)) -MaxConcurrentCutover 2 -MonitorIntervalSeconds 1)
        @($Results | Where-Object Status -eq 'Succeeded').Count | Should -Be 2
        Should -Invoke Invoke-AzDataMigrationCutoverToSqlVM -Times 1 -Exactly
    }
    It 'Reports a timeout without claiming or cancelling remote completion' {
        $script:Time = [datetime]'2025-01-01'
        Mock Get-Date { $script:Time = $script:Time.AddMinutes(2); $script:Time }
        Mock Get-DMSMigrationDetail { @{ MigrationStatus = 'ReadyForCutover'; MigrationOperationId = 'operation' } }
        $Results = @(Invoke-DMSRollingCutover -Migrations @((New-TestMigration)) -CutoverTimeoutMinutes 1 -MonitorIntervalSeconds 1)
        $Results[0].Status | Should -Be 'TimedOut'
        $Results[0].Error | Should -Match 'not canceled'
    }
    It 'Surfaces terminal DMS failures' {
        $script:Call = 0
        Mock Get-DMSMigrationDetail {
            $script:Call++
            @{ MigrationStatus = $(if ($script:Call -eq 1) { 'ReadyForCutover' } else { 'Failed' }); MigrationOperationId = 'operation' }
        }
        @(Invoke-DMSRollingCutover -Migrations @((New-TestMigration)) -MonitorIntervalSeconds 1 -Confirm)[0].Status | Should -Be 'Failed'
    }
}

Describe 'Upload timestamp selection and restore automatic cutover' -Tag 'Unit' {
    It 'Uses custom timestamps for actual FULL/DIFF/LOG selection and availability output' {
        . (Get-SourceFunctions -Path (Join-Path $Scripts 'Invoke-CopyBackup-OnPrem-AzureBlob.ps1') -Names @(
            'Get-TimestampFromName', 'Get-LatestByFolderAndExt', 'Get-LatestDiffAfter', 'Get-LogsAfter', 'Update-CheckLatestBakReport'
        ))
        function Write-Log {}
        $TimestampPattern = '(?<ts>\d{2}[A-Za-z]{3}\d{4}-\d{6})'
        $TimestampFormat = 'ddMMMyyyy-HHmmss'
        foreach ($Folder in @('full', 'diff', 'log')) { $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive $Folder) }
        foreach ($File in @('full\db_02Jan2025-010000.bak', 'full\db_01Jan2025-010000.bak', 'full\db_invalid.bak',
                'diff\db_02Jan2025-020000.diff', 'log\db_02Jan2025-015959.trn', 'log\db_02Jan2025-030000.log')) {
            $null = New-Item -ItemType File -Path (Join-Path $TestDrive $File)
        }
        $Full = Get-LatestByFolderAndExt -Folder (Join-Path $TestDrive 'full') -Extension '.bak'
        $Diff = Get-LatestDiffAfter -Folder (Join-Path $TestDrive 'diff') -AfterTimestamp $Full.Timestamp
        $Logs = @(Get-LogsAfter -Folder (Join-Path $TestDrive 'log') -AfterTimestamp $Diff.Timestamp)
        $Full.File.Name | Should -Be 'db_02Jan2025-010000.bak'
        $Diff.File.Name | Should -Be 'db_02Jan2025-020000.diff'
        $Logs.Count | Should -Be 1
        $Logs[0].File.Name | Should -Be 'db_02Jan2025-030000.log'
        $Availability = @(Update-CheckLatestBakReport -Metadata @(@{ BackupRootPath = $TestDrive; SrcServerName = 'source'; SrcDatabaseName = 'db' }) -LogDirectory $TestDrive)
        $Availability.Count | Should -Be 1
        $Availability[0].LatestFullBak | Should -Be $Full.File.Name
    }

}
