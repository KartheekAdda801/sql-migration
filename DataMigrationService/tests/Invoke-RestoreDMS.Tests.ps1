#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    $Scripts = Join-Path $PSScriptRoot '..\scripts'
    . (Join-Path $Scripts 'Invoke-RestoreDMS.ps1')
    $ReferencePath = Join-Path $Scripts '..\config\Invoke-RestoreDMS.config.json'
    function Set-AzContext { [CmdletBinding(SupportsShouldProcess)]param($SubscriptionId, $Scope) throw 'Unmocked Azure call' }
    function Get-AzDataMigrationSqlService { [CmdletBinding()]param($Name, $ResourceGroupName) throw 'Unmocked Azure call' }
    function New-AzStorageContext { [CmdletBinding()]param($StorageAccountName, [switch]$UseConnectedAccount) throw 'Unmocked Azure call' }
    function Get-AzStorageBlob { [CmdletBinding()]param($Container, $Context) throw 'Unmocked Azure call' }
    function Get-AzStorageAccountKey { [CmdletBinding()]param($ResourceGroupName, $Name) throw 'Unmocked Azure call' }
    function New-AzDataMigrationToSqlVM {
        [CmdletBinding()]param($SubscriptionId, $ResourceGroupName, $TargetDbName, $SqlVirtualMachineName,
            $AzureBlobContainerName, $AzureBlobStorageAccountResourceId, $MigrationService, $Scope, $Kind,
            $AzureBlobAccountKey, $AzureBlobAuthType, $AzureBlobIdentityType, $AzureBlobUserAssignedIdentity)
        throw 'Unmocked Azure mutation'
    }
    function New-AzDataMigrationToSqlManagedInstance {
        [CmdletBinding()]param($SubscriptionId, $ResourceGroupName, $TargetDbName, $ManagedInstanceName,
            $AzureBlobContainerName, $AzureBlobStorageAccountResourceId, $MigrationService, $Scope, $Kind,
            $AzureBlobAccountKey, $AzureBlobAuthType, $AzureBlobIdentityType, $AzureBlobUserAssignedIdentity)
        throw 'Unmocked Azure mutation'
    }
    function Remove-AzDataMigrationToSqlVM {
        [CmdletBinding()]param($SubscriptionId, $ResourceGroupName, $TargetDbName, $SqlVirtualMachineName)
        throw 'Unmocked Azure mutation'
    }
    function Remove-AzDataMigrationToSqlManagedInstance {
        [CmdletBinding()]param($SubscriptionId, $ResourceGroupName, $TargetDbName, $ManagedInstanceName)
        throw 'Unmocked Azure mutation'
    }
}

Describe 'Item-based DMS configuration inheritance' -Tag 'Unit' {
    BeforeEach { $Shared = Read-ServiceConfiguration -Path $ReferencePath }
    It 'Inherits blank item SQL authentication settings and preserves explicit per-item overrides' {
        $Shared.Common.TargetTrustServerCertificate = $true
        $Shared.Common.TargetSqlAuthType = 'Entra'
        $Shared.Common.credential = 'shared_login'
        foreach ($Source in $Shared.Items) {
            foreach ($Name in @('TargetTrustServerCertificate', 'TargetSqlAuthType', 'credential')) { $Source.$Name = '' }
        }
        $Items = @(Resolve-DMSConfigurationItems $Shared)
        foreach ($Item in $Items) {
            $Item.TargetTrustServerCertificate | Should -BeTrue
            $Item.TargetSqlAuthType | Should -Be 'Entra'
            $Item.credential | Should -Be 'shared_login'
        }
        $Shared.Items[0].TargetTrustServerCertificate = $false
        $Shared.Items[0].TargetSqlAuthType = 'SqlLogin'
        $Shared.Items[0].credential = 'vm_login'
        $Items = @(Resolve-DMSConfigurationItems $Shared)
        $Items[0].TargetTrustServerCertificate | Should -BeFalse
        $Items[0].TargetSqlAuthType | Should -Be 'SqlLogin'
        $Items[0].credential | Should -Be 'vm_login'
        $Items[1].TargetTrustServerCertificate | Should -BeTrue
        $Items[1].TargetSqlAuthType | Should -Be 'Entra'
        $Items[1].credential | Should -Be 'shared_login'
    }
    It 'Inherits a named credential and permits a different credential for each mapping' {
        $Shared.Common.credential = 'shared_login'
        $Shared.Items[1] | Add-Member -NotePropertyName credential -NotePropertyValue 'mi_login' -Force
        $Items = @(Resolve-DMSConfigurationItems $Shared)
        $Items[0].credential | Should -Be 'shared_login'
        $Items[1].credential | Should -Be 'mi_login'
        $Shared.Items[1].credential = ''
        @(Resolve-DMSConfigurationItems $Shared)[1].credential | Should -Be 'shared_login'
        $Shared.Common.credential = 123
        { Resolve-DMSConfigurationItems $Shared } | Should -Throw '*credential must be a string*'
    }
    It 'Keeps two operational files and both MIGRDEMO targets in the same file' {
        @(Get-ChildItem -LiteralPath (Join-Path $Scripts '..\config') -Filter '*.config.json') | Should -HaveCount 2
        Test-Path -LiteralPath (Join-Path $Scripts '..\config\Invoke-RestoreDMS.example.json') | Should -BeTrue
        $Shared.Common.Activity | Should -Be 'Restore'
        $Items = @(Resolve-DMSConfigurationItems $Shared)
        $Items | Should -HaveCount 2
        $Items.TargetType | Should -Be @('SQLVM', 'SQLMI')
        $Items.TrgDatabaseName | Should -Be @('MIGRDEMO', 'MIGRDEMO')
        $Items.BlobAuthType | Should -Be @('AccountKey', 'ManagedIdentity')
        $Items.Enabled | Should -Be @($true, $true)
        $Items.Activity | Should -Be @('Restore', 'Restore')
        $Items.TargetSqlHost | Should -Be @('akpersonalsqlvm.centralus.cloudapp.azure.com', 'ak-personal-sqlmi.public.3c52841dc1d0.database.windows.net')
        $Items.TargetSqlPort | Should -Be @(1433, 3342)
    }
    It 'Prefers nonblank item values and inherits omitted, null, empty, and whitespace values' {
        $Shared.Items[0].BackupStorageAccount = 'differentstorage'
        $Shared.Items[0].BackupStorageResourceGroup = 'backup-rg'
        $Shared.Items[0].TargetResourceGroup = 'target-rg'
        $Shared.Items[0].DMSResourceGroup = 'dms-rg'
        $Shared.Items[0].DMSServiceName = 'different-dms'
        $Shared.Items[1].BackupStorageAccount = ' '
        $Shared.Items[1].TargetResourceGroup = $null
        $Items = @(Resolve-DMSConfigurationItems $Shared)
        $Items[0].BackupStorageAccount | Should -Be 'differentstorage'
        $Items[0].BackupStorageResourceGroup | Should -Be 'backup-rg'
        $Items[0].TargetResourceGroup | Should -Be 'target-rg'
        $Items[0].DMSResourceGroup | Should -Be 'dms-rg'
        $Items[0].DMSServiceName | Should -Be 'different-dms'
        $Items[1].BackupStorageAccount | Should -Be 'akpersonalsa'
        $Items[1].TargetResourceGroup | Should -Be 'rg-ak-personal'
    }
    It 'Preserves false overrides, inherits blank booleans and integers, and rejects zero instead of inheriting' {
        $Shared.Common.AutoCutover = $true
        $Shared.Common.Force = $true
        $Shared.Items[0].AutoCutover = $false
        $Shared.Items[0] | Add-Member -NotePropertyName Force -NotePropertyValue $false
        $Shared.Items[1].TargetSqlPort = ''
        $Items = @(Resolve-DMSConfigurationItems $Shared)
        $Items[0].AutoCutover | Should -BeFalse
        $Items[0].Force | Should -BeFalse
        $Items[1].AutoCutover | Should -BeTrue
        $Items[1].TargetSqlPort | Should -Be 1433
        $Shared.Items[0].TargetSqlPort = 0
        { Resolve-DMSConfigurationItems $Shared } | Should -Throw '*TargetSqlPort*'
    }
    It 'Uses item activity overrides above the common activity' {
        $Shared.Common.Activity = 'Status'
        $Shared.Items[0].Activity = 'Cutover'
        $Items = @(Resolve-DMSConfigurationItems $Shared)
        $Items.Activity | Should -Be @('Cutover', 'Status')
    }
    It 'Passes inherited host/port and MI public overrides through the restore preflight plan' {
        $Shared.Common | Add-Member -NotePropertyName TargetSqlHost -NotePropertyValue 'common.target.example'
        $Shared.Common.TargetSqlPort = 1500
        $Shared.Items[0].TargetSqlHost = ''
        $Shared.Items[0].TargetSqlPort = ''
        $Plan = @(New-DMSItemPlan -Items @(Resolve-DMSConfigurationItems $Shared))
        $Plan[0].Configuration.Items[0].TargetSqlHost | Should -Be 'common.target.example'
        $Plan[0].Options.TargetSqlPort | Should -Be 1500
        $Plan[1].Configuration.Items[0].TargetSqlHost | Should -Be 'ak-personal-sqlmi.public.3c52841dc1d0.database.windows.net'
        $Plan[1].Options.TargetSqlPort | Should -Be 3342
    }
    It 'Requires an effective restore hostname for both target types' -ForEach @(
        @{ Index = 0 }, @{ Index = 1 }
    ) {
        $Shared.Items[$Index].TargetSqlHost = ''
        { Resolve-DMSConfigurationItems $Shared } | Should -Throw '*TargetSqlHost*'
    }
    It 'Projects and parameter-binds every activity with separate resource groups on <Target>' -ForEach @(
        @{ Target = 'SQLVM' }, @{ Target = 'SQLMI' }
    ) {
        foreach ($Activity in @('Restore', 'Status', 'Monitor', 'Cutover', 'Remove')) {
            $Shared.Common.Activity = $Activity
            $Source = $Shared.Items | Where-Object TargetType -eq $Target
            $Source.TargetResourceGroup = 'target-rg'
            $Source.DMSResourceGroup = 'dms-rg'
            $Items = @(Resolve-DMSConfigurationItems $Shared | Where-Object TargetType -eq $Target)
            $Plan = @(New-DMSItemPlan -Items $Items)
            $Plan | Should -HaveCount 1
            $Plan[0].Migration.ResourceGroup | Should -Be 'target-rg'
            if ($Activity -eq 'Restore') {
                $Plan[0].Configuration.Items[0]."Trg${Target}ResourceGroup" | Should -Be 'target-rg'
                $Plan[0].Configuration.Items[0].DMSResourceGroup | Should -Be 'dms-rg'
            }
            else {
                $Plan[0].Options.TargetResourceGroup | Should -Be 'target-rg'
                $Plan[0].Options.ResourceGroupName | Should -Be @('dms-rg')
                $Plan[0].Options.Databases | Should -Be @('MIGRDEMO')
            }
        }
    }
    It 'Rejects unknown fields, wrong types, duplicate IDs and targets, and per-item global limits' {
        $Shared.Common | Add-Member -NotePropertyName Typo -NotePropertyValue 1
        { Resolve-DMSConfigurationItems $Shared } | Should -Throw '*Unknown*'
        $Shared.Common.PSObject.Properties.Remove('Typo')
        $Shared.Items[0].AutoCutover = 'false'
        { Resolve-DMSConfigurationItems $Shared } | Should -Throw '*JSON boolean*'
        $Shared.Items[0].AutoCutover = ''
        $Shared.Items[0] | Add-Member -NotePropertyName MaxConcurrentRestores -NotePropertyValue 1
        { Resolve-DMSConfigurationItems $Shared } | Should -Throw '*Unknown*'
        $Shared.Items[0].PSObject.Properties.Remove('MaxConcurrentRestores')
        $Shared.Items[1].Id = $Shared.Items[0].Id
        { Resolve-DMSConfigurationItems $Shared } | Should -Throw '*unique*'
        $Shared.Items[1] = $Shared.Items[0] | ConvertTo-Json | ConvertFrom-Json
        $Shared.Items[1].Id = 'duplicate-target'
        { Resolve-DMSConfigurationItems $Shared } | Should -Throw '*Duplicate target*'
    }
    It 'Has only one lifecycle entry script plus the independent backup uploader' {
        $Entries = @(Get-ChildItem -LiteralPath $Scripts -Filter '*.ps1' -File)
        $Entries | Should -HaveCount 2
        $Entries.Name | Should -Contain 'Invoke-RestoreDMS.ps1'
        $Entries.Name | Should -Contain 'Invoke-CopyBackup-OnPrem-AzureBlob.ps1'
    }
}

Describe 'Exact DMS item selection' -Tag 'Unit' {
    BeforeEach { $Items = @(Resolve-DMSConfigurationItems (Read-ServiceConfiguration $ReferencePath)) }
    It 'Selects all enabled items by default and exactly one with item IDs or target selectors' {
        @(Select-DMSConfigurationItems $Items) | Should -HaveCount 2
        @(Select-DMSConfigurationItems $Items -ItemId 'MI-MIGRDEMO').TargetType | Should -Be 'SQLMI'
        @(Select-DMSConfigurationItems $Items -Databases MIGRDEMO -TargetName akpersonalsqlvm).Id | Should -Be 'VM-MIGRDEMO'
        $Items[0].Enabled = $false
        @(Select-DMSConfigurationItems $Items) | Should -HaveCount 1
        { Select-DMSConfigurationItems $Items -ItemId 'VM-MIGRDEMO' } | Should -Throw '*does not match*'
    }
    It 'Rejects a missing requested database, even when another requested database matches' {
        { Select-DMSConfigurationItems $Items -Databases MIGRDEMO, MissingDb } | Should -Throw '*MissingDb*'
    }
}

Describe 'Mixed-target workflow safeguards' -Tag 'Unit' {
    BeforeEach {
        Mock Write-Host {}
        Mock Read-Host { throw 'Unexpected prompt' }
        Mock Invoke-DataMigrationPreflight {}
        Mock Initialize-DMSRestorePlan {}
        Mock New-DMSRunDirectory { Join-Path $TestDrive 'run' }
        Mock Invoke-DMSRun {
            Invoke-DMSPreparedPlan -Plan $Plan -MaxConcurrentRestores $MaxConcurrentRestores `
                -MaxConcurrentCutover $MaxConcurrentCutover -SqlCredentials $SqlCredentials -ContextPath 'mock-context'
        }
        Mock Show-DMSPlanStatus {}
        Mock Invoke-DMSRestoreQueue {}
        Mock Write-DMSPlanResults {}
        $Shared = Read-ServiceConfiguration $ReferencePath
        $Shared.Common.Activity = 'Status'
        $Path = Join-Path $TestDrive 'items.json'
    }
    It 'Preflights every selected row but performs no work or output with WhatIf' {
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        Invoke-DMSConfiguredActivity -ConfigPath $Path -Activity Restore -WhatIf -Confirm
        Should -Invoke Invoke-DataMigrationPreflight -Times 2 -Exactly
        Should -Invoke Invoke-DMSRestoreQueue -Times 0 -Exactly
        Should -Invoke Write-DMSPlanResults -Times 0 -Exactly
    }
    It 'Resolves the local credential file beside a custom configuration, not the terminal directory' {
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        Invoke-DMSConfiguredActivity -ConfigPath $Path -Activity Restore -WhatIf
        Should -Invoke Initialize-DMSRestorePlan -Times 1 -Exactly -ParameterFilter {
            $CredentialFilePath -eq (Join-Path $TestDrive 'password.local.json')
        }
    }
    It 'Rejects report paths that would overwrite the local password file' {
        $Shared.Common.OutputJsonPath = Join-Path $TestDrive 'password.local.json'
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        { Invoke-DMSConfiguredActivity -ConfigPath $Path -WhatIf } | Should -Throw '*overwrite the local credential file*'
        Should -Invoke Invoke-DataMigrationPreflight -Times 0 -Exactly
    }
    It 'Aborts before any work if the last item fails preflight' {
        Mock Invoke-DataMigrationPreflight { if ($Operation -like '*SQLMI') { throw 'MI denied' } }
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        { Invoke-DMSConfiguredActivity -ConfigPath $Path -Activity Restore -Confirm:$false } | Should -Throw '*MI denied*'
        Should -Invoke Invoke-DMSRestoreQueue -Times 0 -Exactly
        Should -Invoke Write-DMSPlanResults -Times 0 -Exactly
    }
    It 'Dispatches configured Cutover for both target types without a CLI activity override' {
        $Shared.Common.Activity = 'Cutover'
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        Mock Invoke-DMSPlanCutover {}
        Invoke-DMSConfiguredActivity -ConfigPath $Path -Confirm
        Should -Invoke Invoke-DMSPlanCutover -Times 1 -Exactly -ParameterFilter {
            $Plan.Count -eq 2 -and $MaxConcurrentCutover -eq 5 -and -not $Confirm
        }
        Should -Invoke Invoke-DMSRestoreQueue -Times 0 -Exactly
    }
    It 'Dispatches configured Remove without confirmation even when Confirm is supplied' {
        $Shared.Common.Activity = 'Remove'
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        Mock Remove-DMSItemMigration { $Entry.Result.Status = 'Removed' }
        Invoke-DMSConfiguredActivity -ConfigPath $Path -Confirm
        Should -Invoke Remove-DMSItemMigration -Times 2 -Exactly -ParameterFilter { -not $Confirm }
        Should -Invoke Invoke-DMSRestoreQueue -Times 0 -Exactly
    }
    It 'Monitors both targets to completion without a menu or implicit cutover' {
        $Shared.Common.Activity = 'Monitor'
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        Mock Show-DMSPlanStatus {
            foreach ($Entry in $Plan) {
                $Entry.Result.Status = 'Succeeded'
                $Entry.Result.MigrationStatus = 'Succeeded'
            }
        }
        Mock Invoke-DMSPlanCutover {}
        Mock Start-Sleep {}
        Invoke-DMSConfiguredActivity -ConfigPath $Path -Confirm
        Should -Invoke Show-DMSPlanStatus -Times 1 -Exactly -ParameterFilter { $Plan.Count -eq 2 }
        Should -Invoke Invoke-DMSPlanCutover -Times 0 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
    }
    It 'Refreshes the combined monitor using the minimum selected per-item wait' {
        $Shared.Common.Activity = 'Monitor'
        $Shared.Items[0] | Add-Member -NotePropertyName RefreshWaitMinutes -NotePropertyValue 1 -Force
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        $script:Refreshes = 0
        $script:MonitoringWrites = 0
        Mock Write-DMSPlanResults {
            if (@($Plan | Where-Object { $_.Result.Status -eq 'Monitoring' }).Count -eq 2) { $script:MonitoringWrites++ }
        }
        Mock Show-DMSPlanStatus {
            $script:Refreshes++
            foreach ($Entry in $Plan) {
                $Entry.Result.Status = 'Succeeded'
                $Entry.Result.MigrationStatus = if ($script:Refreshes -eq 1) { 'ReadyForCutover' } else { 'Succeeded' }
            }
        }
        Mock Start-Sleep {}
        Invoke-DMSConfiguredActivity -ConfigPath $Path -Confirm:$false
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 60 }
        Should -Invoke Show-DMSPlanStatus -Times 2 -Exactly
        $script:MonitoringWrites | Should -Be 1
        Should -Invoke Read-Host -Times 0 -Exactly
    }
    It 'Surfaces terminal monitor failures without prompting' -ForEach @(
        @{ State = 'Failed' }, @{ State = 'Canceled' }, @{ State = 'Cancelled' }
    ) {
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        Mock Write-Warning {}
        Mock Start-Sleep {}
        Mock Show-DMSPlanStatus {
            foreach ($Entry in $Plan) {
                $Entry.Result.Status = 'Succeeded'
                $Entry.Result.MigrationStatus = $State
            }
        }
        { Invoke-DMSConfiguredActivity -ConfigPath $Path -Activity Monitor -Confirm } | Should -Throw '*activities failed*'
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
    }
    It 'Stops monitoring explicitly when a selected migration is missing' {
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        Mock Write-Warning {}
        Mock Start-Sleep {}
        Mock Show-DMSPlanStatus { foreach ($Entry in $Plan) { $Entry.Result.Status = 'NotFound' } }
        { Invoke-DMSConfiguredActivity -ConfigPath $Path -Activity Monitor } | Should -Throw '*No migration status*'
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
    It 'Provides default per-run restore reports without writing them during preview' {
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        Mock Invoke-DMSRestoreQueue {
            foreach ($Entry in $Plan) {
                $Entry.Item.OutputJsonPath | Should -Match 'logs\\Reports\\Invoke-RestoreDMS\..*\.json$'
                $Entry.Item.ExportCsvPath | Should -Match 'logs\\Reports\\Invoke-RestoreDMS\..*\.csv$'
            }
            $ReportPlan | Should -HaveCount 2
        }
        Invoke-DMSConfiguredActivity -ConfigPath $Path -Activity Restore -Confirm:$false
        Should -Invoke Invoke-DMSRestoreQueue -Times 1 -Exactly
    }
    It 'Requires Common/Items rather than silently accepting an old per-operation file' {
        '{"schemaVersion":1,"Settings":{},"Items":[]}' | Set-Content -LiteralPath $Path
        { Invoke-DMSConfiguredActivity -ConfigPath $Path } | Should -Throw '*schemaVersion 2*'
        Should -Invoke Invoke-DataMigrationPreflight -Times 0 -Exactly
    }
    It 'Passes the global limit and both targets while suppressing explicit Confirm' {
        $Shared.Common.MaxConcurrentRestores = 2
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        Invoke-DMSConfiguredActivity -ConfigPath $Path -Activity Restore -Confirm
        Should -Invoke Invoke-DMSRestoreQueue -Times 1 -Exactly -ParameterFilter {
            $MaxConcurrentRestores -eq 2 -and $Plan.Count -eq 2 -and -not $Confirm
        }
    }
    It 'Honors item activity overrides and restricts Status to requested rows' {
        $Shared.Items[0].Activity = 'Restore'
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        Invoke-DMSConfiguredActivity -ConfigPath $Path -Confirm:$false
        Should -Invoke Show-DMSPlanStatus -Times 1 -Exactly -ParameterFilter { $Plan.Count -eq 1 -and $Plan[0].Item.TargetType -eq 'SQLMI' }
        Should -Invoke Invoke-DMSRestoreQueue -Times 1 -Exactly -ParameterFilter { $Plan.Count -eq 1 -and $Plan[0].Item.TargetType -eq 'SQLVM' }
    }
    It 'Rejects paths that would overwrite configuration or mix JSON and CSV' {
        $Shared.Common.OutputJsonPath = $Path
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        { Invoke-DMSConfiguredActivity -ConfigPath $Path -WhatIf } | Should -Throw '*overwrite the migration configuration*'
        $Shared.Common.OutputJsonPath = Join-Path $TestDrive 'report.json'
        $Shared.Common.ExportCsvPath = $Shared.Common.OutputJsonPath
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        { Invoke-DMSConfiguredActivity -ConfigPath $Path -WhatIf } | Should -Throw '*must be different*'
        Should -Invoke Invoke-DataMigrationPreflight -Times 0 -Exactly
    }
}

Describe 'Batched submissions and independent restore monitoring' -Tag 'Unit' {
    BeforeEach {
        $Shared = Read-ServiceConfiguration $ReferencePath
        $Shared.Common.Activity = 'Restore'
        $Third = $Shared.Items[0] | ConvertTo-Json | ConvertFrom-Json
        $Third.Id = 'VM-SecondDb'
        $Third.TrgDatabaseName = 'SecondDb'
        $Shared.Items += $Third
        $Plan = @(New-DMSItemPlan -Items @(Resolve-DMSConfigurationItems $Shared))
        $script:StartedIds = [Collections.Generic.List[string]]::new()
        $script:ActiveCount = 0
        $script:PeakCount = 0
        $script:PollCount = @{}
        $script:Clock = [datetime]'2026-10-23T00:00:00Z'
        Mock Write-Host {}
        Mock Set-AzContext {}
        Mock Start-Sleep { $script:Clock = $script:Clock.AddSeconds($Seconds) }
        Mock Get-Date { $script:Clock }
        Mock Start-DMSItemRestore {
            $script:StartedIds.Add($Entry.Item.Id)
            $script:ActiveCount++
            $script:PeakCount = [math]::Max($script:PeakCount, $script:ActiveCount)
            [pscustomobject]@{ Status = 'Submitted' }
        }
        $script:BatchSizes = [Collections.Generic.List[int]]::new()
        Mock Invoke-DMSRestoreBatch {
            $script:BatchSizes.Add($Plan.Count)
            foreach ($Entry in $Plan) {
                try { $Entry.Result.Status = (Start-DMSItemRestore -Entry $Entry -Confirm:$false).Status }
                catch { $Entry.Result.Status = 'SubmissionUnverified'; $Entry.Result.Error = $_.Exception.Message }
            }
        }
        Mock Get-DMSMigrationDetail {
            $script:StartedIds.Count | Should -Be 3
            $script:ActiveCount--
            [pscustomobject]@{ MigrationStatus = 'Succeeded' }
        }
    }
    It 'Batches submissions at <Limit> without limiting active restores' -ForEach @(
        @{ Limit = 1 }, @{ Limit = 2 }
    ) {
        Invoke-DMSRestoreQueue -Plan $Plan -MaxConcurrentRestores $Limit -ContextPath 'offline-context' -Confirm:$false
        $script:PeakCount | Should -Be 3
        @($script:BatchSizes | Where-Object { $_ -gt $Limit }) | Should -HaveCount 0
        $script:BatchSizes.Count | Should -Be ([math]::Ceiling(3 / $Limit))
        $script:StartedIds | Should -HaveCount 3
        $Plan.Result.Status | Should -Be @('Succeeded', 'Succeeded', 'Succeeded')
    }
    It 'Submits all 20 databases as two batches of 10 before polling, even while they await cutover' {
        $Template = $Plan[0]
        $Plan = @(
            foreach ($Index in 1..20) {
                $Entry = $Template | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $Entry.Item.Id = "VM-$Index"
                $Entry.Migration.Id = "migration-$Index"
                $Entry
            }
        )
        Mock Get-DMSMigrationDetail {
            $script:StartedIds.Count | Should -Be 20
            $script:BatchSizes | Should -Be @(10, 10)
            $Id = $Migration.Id
            if (-not $script:PollCount.ContainsKey($Id)) {
                $script:PollCount[$Id] = 1
                [pscustomobject]@{ MigrationStatus = 'ReadyForCutover' }
            }
            else {
                $script:ActiveCount--
                [pscustomobject]@{ MigrationStatus = 'Succeeded' }
            }
        }
        Invoke-DMSRestoreQueue -Plan $Plan -MaxConcurrentRestores 10 -ContextPath 'offline-context' -Confirm
        $script:PeakCount | Should -Be 20
        $script:PollCount.Count | Should -Be 20
        @($Plan | Where-Object { $_.Result.Status -ne 'Succeeded' }) | Should -HaveCount 0
    }
    It 'Records monitoring errors independently after all submissions have started' {
        Mock Write-Warning {}
        Mock Get-DMSMigrationDetail { throw 'Monitoring access denied' }
        Invoke-DMSRestoreQueue -Plan $Plan -MaxConcurrentRestores 1 -ContextPath 'offline-context' -Confirm:$false
        $script:StartedIds | Should -HaveCount 3
        $Plan.Result.Status | Should -Be @('MonitoringFailed', 'MonitoringFailed', 'MonitoringFailed')
    }
    It 'Retains a failed restore without blocking independent restores' {
        Mock Write-Warning {}
        Mock Get-DMSMigrationDetail {
            $script:ActiveCount--
            if ($Migration.TargetName -eq 'ak-personal-sqlmi') { [pscustomobject]@{ MigrationStatus = 'Failed'; ErrorDetails = 'Restore failed' } }
            else { [pscustomobject]@{ MigrationStatus = 'Succeeded' } }
        }
        Invoke-DMSRestoreQueue -Plan $Plan -MaxConcurrentRestores 1 -ContextPath 'offline-context' -Confirm:$false
        $script:PeakCount | Should -Be 3
        $Plan.Result.Status | Should -Be @('Succeeded', 'Failed', 'Succeeded')
        $Plan[1].Result.Error | Should -Match 'Restore failed'
    }
    It 'Retains an uncertain submission while continuing the other items' {
        Mock Start-DMSItemRestore {
            if ($Entry.Item.Id -eq 'VM-MIGRDEMO') { throw 'Submission response lost' }
            [pscustomobject]@{ Status = 'Submitted' }
        }
        Mock Get-DMSMigrationDetail { [pscustomobject]@{ MigrationStatus = 'Succeeded' } }
        Invoke-DMSRestoreQueue -Plan $Plan -MaxConcurrentRestores 2 -ContextPath 'offline-context' -Confirm:$false
        $Plan[0].Result.Status | Should -Be 'SubmissionUnverified'
        $Plan[0].Result.Error | Should -Be 'Submission response lost'
        Should -Invoke Start-DMSItemRestore -Times 3 -Exactly
        Should -Invoke Get-DMSMigrationDetail -Times 2 -Exactly
        $Plan[1].Result.Status | Should -Be 'Succeeded'
    }
    It 'Runs automatic cutover once for <Target>' -ForEach @(
        @{ Target = 'SQLVM' }, @{ Target = 'SQLMI' }
    ) {
        $Selected = @($Plan | Where-Object { $_.Item.TargetType -eq $Target } | Select-Object -First 1)
        $Selected[0].Item.AutoCutover = $true
        Mock Get-DMSMigrationDetail { [pscustomobject]@{ MigrationStatus = 'ReadyForCutover' } }
        Mock Invoke-DMSRollingCutover { [pscustomobject]@{ Status = 'Succeeded'; Error = $null } }
        Invoke-DMSRestoreQueue -Plan $Selected -MaxConcurrentRestores 1 -ContextPath 'offline-context' -Confirm:$false
        $Selected[0].Result.Status | Should -Be 'Succeeded'
        Should -Invoke Invoke-DMSRollingCutover -Times 1 -Exactly -ParameterFilter {
            $MaxConcurrentCutover -eq 1 -and $Migrations[0].Kind -eq $Target
        }
    }
    It 'Does not repeatedly prompt after automatic cutover is declined' {
        $Selected = @($Plan[0])
        $Selected[0].Item.AutoCutover = $true
        $script:Calls = 0
        Mock Write-Warning {}
        Mock Get-DMSMigrationDetail {
            $script:Calls++
            [pscustomobject]@{ MigrationStatus = $(if ($script:Calls -eq 1) { 'ReadyToCutover' } else { 'Succeeded' }) }
        }
        Mock Invoke-DMSRollingCutover { [pscustomobject]@{ Status = 'Declined'; Error = $null } }
        Invoke-DMSRestoreQueue -Plan $Selected -MaxConcurrentRestores 1 -ContextPath 'offline-context' -Confirm:$false
        $Selected[0].Result.Status | Should -Be 'Succeeded'
        $script:Calls | Should -Be 2
        Should -Invoke Invoke-DMSRollingCutover -Times 1 -Exactly
    }
    It 'Retains automatic cutover failures without blocking other restores' -ForEach @(
        @{ Status = 'Failed' }, @{ Status = 'TimedOut' }
    ) {
        $Plan[0].Item.AutoCutover = $true
        Mock Write-Warning {}
        Mock Get-DMSMigrationDetail {
            [pscustomobject]@{ MigrationStatus = $(if ($Migration.TargetName -eq 'akpersonalsqlvm' -and $Migration.DatabaseName -eq 'MIGRDEMO') { 'ReadyForCutover' } else { 'Succeeded' }) }
        }
        Mock Invoke-DMSRollingCutover { [pscustomobject]@{ Status = $Status; Error = 'Check Azure before retrying' } }
        Invoke-DMSRestoreQueue -Plan $Plan -MaxConcurrentRestores 1 -ContextPath 'offline-context' -Confirm:$false
        $Plan[0].Result.Status | Should -Be $Status
        $Plan[0].Result.Error | Should -Be 'Check Azure before retrying'
        Should -Invoke Start-DMSItemRestore -Times 3 -Exactly
        $Plan[1].Result.Status | Should -Be 'Succeeded'
    }
}

Describe 'Unified restore submission and target routing' -Tag 'Unit' {
    BeforeEach {
        $Shared = Read-ServiceConfiguration $ReferencePath
        $Shared.Common.Activity = 'Restore'
        $Plan = @(New-DMSItemPlan -Items @(Resolve-DMSConfigurationItems $Shared))
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Read-Host { throw 'Unexpected prompt' }
        Mock Set-AzContext {}
        Mock Get-DMSItemInventory { @() }
        Mock Get-AzDataMigrationSqlService { [pscustomobject]@{ Id = 'dms-resource-id' } }
        Mock New-AzStorageContext { 'entra-context' }
        Mock Get-AzStorageBlob { @(@{ Name = 'MIGRDEMO_20261023_010000.bak' }, @{ Name = 'MIGRDEMO_20261023_030000.trn' }) }
        Mock Get-AzStorageAccountKey { @([pscustomobject]@{ Value = 'key-not-for-output' }) }
        Mock New-AzDataMigrationToSqlVM { [pscustomobject]@{ Id = 'vm-migration' } }
        Mock New-AzDataMigrationToSqlManagedInstance { [pscustomobject]@{ Id = 'mi-migration' } }
    }
    It 'Uses the correct ONLINE command, identity and per-item resource groups for <Target> <Auth>' -ForEach @(
        @{ Target = 'SQLVM'; Auth = 'AccountKey'; UserAssigned = $false }
        @{ Target = 'SQLMI'; Auth = 'ManagedIdentity'; UserAssigned = $false }
        @{ Target = 'SQLMI'; Auth = 'ManagedIdentity'; UserAssigned = $true }
        @{ Target = 'SQLMI'; Auth = 'AccountKey'; UserAssigned = $false }
    ) {
        $Entry = $Plan | Where-Object { $_.Item.TargetType -eq $Target }
        $Entry.Item.BlobAuthType = $Auth
        $Entry.Item.TargetResourceGroup = 'specific-target-rg'
        $Entry.Item.BackupStorageResourceGroup = 'specific-backup-rg'
        $Entry.Item.DMSResourceGroup = 'specific-dms-rg'
        if ($UserAssigned) {
            $Entry.Item.BlobIdentityType = 'UserAssigned'
            $Entry.Item.BlobUserAssignedIdentity = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/restore'
        }
        (Start-DMSItemRestore -Entry $Entry -Confirm).Status | Should -Be 'Submitted'
        $Command = if ($Target -eq 'SQLVM') { 'New-AzDataMigrationToSqlVM' } else { 'New-AzDataMigrationToSqlManagedInstance' }
        $OtherCommand = if ($Target -eq 'SQLVM') { 'New-AzDataMigrationToSqlManagedInstance' } else { 'New-AzDataMigrationToSqlVM' }
        Should -Invoke $Command -Times 1 -Exactly -ParameterFilter {
            $ResourceGroupName -eq 'specific-target-rg' -and $TargetDbName -eq 'MIGRDEMO' -and
            $SubscriptionId -eq $Entry.Item.SubscriptionId -and $Kind -eq $Target -and
            $MigrationService -eq 'dms-resource-id' -and $Scope -like '*/resourceGroups/specific-target-rg/*' -and
            $AzureBlobStorageAccountResourceId -like '*/resourceGroups/specific-backup-rg/*' -and
            $AzureBlobContainerName -eq 'desktop-sga61qp-dmf-migrdemo' -and
            $(if ($Auth -eq 'AccountKey') { $AzureBlobAccountKey -eq 'key-not-for-output' -and -not $AzureBlobAuthType }
              else { $AzureBlobAuthType -eq 'ManagedIdentity' -and -not $AzureBlobAccountKey -and
                     $AzureBlobIdentityType -eq $Entry.Item.BlobIdentityType -and
                     [string]$AzureBlobUserAssignedIdentity -eq [string]$Entry.Item.BlobUserAssignedIdentity })
        }
        Should -Invoke $OtherCommand -Times 0 -Exactly
        Should -Invoke Get-AzDataMigrationSqlService -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'specific-dms-rg' }
        Should -Invoke New-AzStorageContext -Times 1 -Exactly -ParameterFilter { $UseConnectedAccount -and $StorageAccountName -eq 'akpersonalsa' }
        $KeyCalls = if ($Auth -eq 'AccountKey') { 1 } else { 0 }
        Should -Invoke Get-AzStorageAccountKey -Times $KeyCalls -Exactly
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { ($Object -join ' ') -match 'key-not-for-output' }
    }
    It 'Blocks SQLVM managed identity before accessing Azure' {
        $Plan[0].Item.BlobAuthType = 'ManagedIdentity'
        { Start-DMSItemRestore -Entry $Plan[0] -Confirm:$false } | Should -Throw '*SQLVM requires AccountKey*'
        Should -Invoke Set-AzContext -Times 0 -Exactly
    }
    It 'Does not read Azure, retrieve keys or submit migrations when previewed directly' {
        (Start-DMSItemRestore -Entry $Plan[0] -WhatIf).Status | Should -Be 'WhatIf'
        Should -Invoke Set-AzContext -Times 0 -Exactly
        Should -Invoke Get-AzStorageAccountKey -Times 0 -Exactly
        Should -Invoke New-AzDataMigrationToSqlVM -Times 0 -Exactly
    }
    It 'Warns and skips existing <State> migrations without prompting or replacing them' -ForEach @(
        @{ State = 'Restoring' }, @{ State = 'ReadyForCutover' }, @{ State = 'Succeeded' }
    ) {
        Mock Get-DMSItemInventory { [pscustomobject]@{ MigrationStatus = $State } }
        (Start-DMSItemRestore -Entry $Plan[0] -Confirm).Status | Should -Be 'SkippedExistingMigration'
        Should -Invoke New-AzDataMigrationToSqlVM -Times 0 -Exactly
        Should -Invoke Get-AzStorageAccountKey -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*no replacement was submitted*' }
    }
    It 'Allows retry of failed or cancelled migration records without the replacement prompt' -ForEach @(
        @{ Status = 'Failed' }, @{ Status = 'Canceled' }, @{ Status = 'Cancelled' }
    ) {
        Mock Get-DMSItemInventory { [pscustomobject]@{ MigrationStatus = $Status } }
        (Start-DMSItemRestore -Entry $Plan[1] -Confirm:$false).Status | Should -Be 'Submitted'
        Should -Invoke Read-Host -Times 0 -Exactly
    }
    It 'Derives the same container name as the uploader when it is omitted' {
        $Plan[1].Item.BackupStorageContainerName = ''
        $null = Start-DMSItemRestore -Entry $Plan[1] -Confirm:$false
        Should -Invoke New-AzDataMigrationToSqlManagedInstance -Times 1 -Exactly -ParameterFilter {
            $AzureBlobContainerName -eq 'desktop-sga61qp-dmf-migrdemo'
        }
    }
    It 'Aborts on an uncertain existing-migration lookup instead of continuing to submit' {
        Mock Get-DMSItemInventory { throw 'Inventory permission denied' }
        { Start-DMSItemRestore -Entry $Plan[1] -Confirm:$false } | Should -Throw '*Inventory permission denied*'
        Should -Invoke New-AzDataMigrationToSqlManagedInstance -Times 0 -Exactly
    }
    It 'Does not submit a migration when backup discovery fails or no FULL is usable' -ForEach @(
        @{ Failure = 'Denied' }, @{ Failure = 'NoFull' }
    ) {
        Mock Get-AzStorageBlob {
            if ($Failure -eq 'Denied') { throw 'Blob read denied' }
            @(@{ Name = 'MIGRDEMO_20261023_030000.trn' })
        }
        { Start-DMSItemRestore -Entry $Plan[1] -Confirm:$false } | Should -Throw
        Should -Invoke New-AzDataMigrationToSqlManagedInstance -Times 0 -Exactly
    }
    It 'Checks backup discovery before any approved database replacement' {
        $Plan[1] | Add-Member -NotePropertyName RestoreState -NotePropertyValue @{ ReplaceExisting = $true; Skip = $false }
        Mock Get-DMSItemInventory { @{ MigrationStatus = 'Restoring' } }
        Mock Get-AzStorageBlob { throw 'Backup access denied' }
        Mock Reset-DMSRestoreTarget { throw 'Must not delete the target' }
        { Start-DMSItemRestore -Entry $Plan[1] -Confirm } | Should -Throw '*Backup access denied*'
        Should -Invoke Reset-DMSRestoreTarget -Times 0 -Exactly
        Should -Invoke New-AzDataMigrationToSqlManagedInstance -Times 0 -Exactly
    }
    It 'Does not delete a database that appeared after a non-replacement preflight' {
        $Plan[1] | Add-Member -NotePropertyName RestoreState -NotePropertyValue @{ ReplaceExisting = $false; Skip = $false }
        Mock Get-DMSTargetDatabase { @{ Exists = $true } }
        Mock Reset-DMSRestoreTarget {}
        { Start-DMSItemRestore -Entry $Plan[1] -Confirm } | Should -Throw '*appeared after preflight*'
        Should -Invoke Reset-DMSRestoreTarget -Times 0 -Exactly
        Should -Invoke New-AzDataMigrationToSqlManagedInstance -Times 0 -Exactly
    }
    It 'Does not provision a missing DMS service' {
        Mock Get-AzDataMigrationSqlService { $null }
        { Start-DMSItemRestore -Entry $Plan[1] -Confirm:$false } | Should -Throw '*did not return an ID*'
        Should -Invoke New-AzDataMigrationToSqlManagedInstance -Times 0 -Exactly
    }
    It 'Surfaces submission errors without falling back to an account key' {
        Mock New-AzDataMigrationToSqlManagedInstance { throw 'MI restore denied' }
        { Start-DMSItemRestore -Entry $Plan[1] -Confirm:$false } | Should -Throw '*MI restore denied*'
        Should -Invoke New-AzDataMigrationToSqlManagedInstance -Times 1 -Exactly
        Should -Invoke Get-AzStorageAccountKey -Times 0 -Exactly
    }
    It 'Rejects an empty submission response rather than reporting success' {
        Mock New-AzDataMigrationToSqlVM { $null }
        { Start-DMSItemRestore -Entry $Plan[0] -Confirm:$false } | Should -Throw '*returned no result*'
    }
    It 'Uses the latest compatible filename baseline and subsequent log, not older backups' {
        Mock Get-AzStorageBlob {
            @('MIGRDEMO_20261022_010000.bak', 'MIGRDEMO_20261023_010000.bak',
              'MIGRDEMO_20261022_230000.diff', 'MIGRDEMO_20261023_020000.diff',
              'MIGRDEMO_20261023_015959.trn', 'MIGRDEMO_20261023_030000.log',
              'otherdb_20261023_040000.trn') | ForEach-Object { @{ Name = $_ } }
        }
        (Get-DMSRestoreBackup -Item $Plan[0].Item -Container 'backups').Name | Should -Be 'MIGRDEMO_20261023_030000.log'
    }
    It 'Falls back to the latest DIFF or FULL when no later log exists' -ForEach @(
        @{ Diff = $true; Extension = 'diff' }, @{ Diff = $false; Extension = 'bak' }
    ) {
        Mock Get-AzStorageBlob {
            @{ Name = 'MIGRDEMO_20261023_010000.bak' }
            if ($Diff) { @{ Name = 'MIGRDEMO_20261023_020000.diff' } }
        }
        (Get-DMSRestoreBackup -Item $Plan[0].Item -Container 'backups').Extension | Should -Be $Extension
    }
    It 'Uses per-item custom timestamp parsing for both platforms' {
        $Plan[1].Item.TimestampPattern = '(?<ts>\d{2}[A-Za-z]{3}\d{4}-\d{6})'
        $Plan[1].Item.TimestampFormat = 'ddMMMyyyy-HHmmss'
        Mock Get-AzStorageBlob { @(@{ Name = 'MIGRDEMO_23Oct2026-010000.bak' }, @{ Name = 'MIGRDEMO_23Oct2026-020000.log' }) }
        (Get-DMSRestoreBackup -Item $Plan[1].Item -Container 'backups').Name | Should -Be 'MIGRDEMO_23Oct2026-020000.log'
        { Get-DMSRestoreBackup -Item $Plan[0].Item -Container 'backups' } | Should -Throw '*No usable*FULL*'
    }
}

Describe 'Unified migration-resource removal' -Tag 'Unit' {
    BeforeEach {
        $Shared = Read-ServiceConfiguration $ReferencePath
        $Shared.Common.Activity = 'Remove'
        $Plan = @(New-DMSItemPlan -Items @(Resolve-DMSConfigurationItems $Shared))
        $script:RemovalStatus = 'Succeeded'
        Mock Get-DMSItemInventory {
            $Entry = $Plan | Where-Object { $_.Item.Id -eq $Item.Id }
            $Entry.Migration | Select-Object *, @{ Name = 'MigrationStatus'; Expression = { $script:RemovalStatus } }
        }
        Mock Read-Host { throw 'Unexpected prompt' }
        Mock Write-Warning {}
        Mock Set-AzContext {}
        Mock Remove-AzDataMigrationToSqlVM {}
        Mock Remove-AzDataMigrationToSqlManagedInstance {}
    }
    It 'Removes only the selected migration resource with the correct native command for <Target>' -ForEach @(
        @{ Target = 'SQLVM' }, @{ Target = 'SQLMI' }
    ) {
        $Entry = $Plan | Where-Object { $_.Item.TargetType -eq $Target }
        Remove-DMSItemMigration -Entry $Entry -Confirm
        $Entry.Result.Status | Should -Be 'Removed'
        $Command = if ($Target -eq 'SQLVM') { 'Remove-AzDataMigrationToSqlVM' } else { 'Remove-AzDataMigrationToSqlManagedInstance' }
        $OtherCommand = if ($Target -eq 'SQLVM') { 'Remove-AzDataMigrationToSqlManagedInstance' } else { 'Remove-AzDataMigrationToSqlVM' }
        Should -Invoke $Command -Times 1 -Exactly -ParameterFilter {
            $SubscriptionId -eq $Entry.Item.SubscriptionId -and $ResourceGroupName -eq $Entry.Item.TargetResourceGroup -and $TargetDbName -eq 'MIGRDEMO'
        }
        Should -Invoke $OtherCommand -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
    }
    It 'Does not remove ready migrations unless opted in' {
        $script:RemovalStatus = 'ReadyForCutover'
        Remove-DMSItemMigration -Entry $Plan[0] -Confirm:$false
        $Plan[0].Result.Status | Should -Be 'NoRemoval'
        Should -Invoke Remove-AzDataMigrationToSqlVM -Times 0 -Exactly
        $Plan[0].Item.IncludeReadyForCutover = $true
        Remove-DMSItemMigration -Entry $Plan[0] -Confirm:$false
        $Plan[0].Result.Status | Should -Be 'Removed'
        Should -Invoke Remove-AzDataMigrationToSqlVM -Times 1 -Exactly
    }
    It 'Does not remove failed or running migrations even with Force' -ForEach @(
        @{ Status = 'Failed' }, @{ Status = 'Restoring' }
    ) {
        $script:RemovalStatus = $Status
        $Plan[0].Item.Force = $true
        Remove-DMSItemMigration -Entry $Plan[0] -Confirm:$false
        $Plan[0].Result.Status | Should -Be 'NoRemoval'
        Should -Invoke Remove-AzDataMigrationToSqlVM -Times 0 -Exactly
    }
    It 'Does not bypass ShouldProcess with Force' {
        $Plan[0].Item.Force = $true
        Remove-DMSItemMigration -Entry $Plan[0] -WhatIf
        $Plan[0].Result.Status | Should -Be 'WhatIf'
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Remove-AzDataMigrationToSqlVM -Times 0 -Exactly
    }
    It 'Retains an explicit failed result and propagates native removal errors' {
        Mock Remove-AzDataMigrationToSqlVM { throw 'Removal denied' }
        { Remove-DMSItemMigration -Entry $Plan[0] -Confirm:$false } | Should -Throw '*Removal denied*'
        $Plan[0].Result.Status | Should -Be 'Failed'
        $Plan[0].Result.Error | Should -Be 'Removal denied'
    }
}



Describe 'Scoped workflow results' -Tag 'Unit' {
    BeforeEach {
        $Shared = Read-ServiceConfiguration $ReferencePath
        $Shared.Common.OutputJsonPath = Join-Path $TestDrive 'all.json'
        $Shared.Common.ExportCsvPath = Join-Path $TestDrive 'all.csv'
        $Plan = @(New-DMSItemPlan -Items @(Resolve-DMSConfigurationItems $Shared))
    }
    It 'Writes every inherited database result to one aggregate file without last-item overwrites' {
        Write-DMSPlanResults -Plan $Plan
        $Json = Get-Content -LiteralPath $Shared.Common.OutputJsonPath -Raw | ConvertFrom-Json
        $Json.results | Should -HaveCount 2
        $Json.status | Should -Be 'InProgress'
        $Json.completedAt | Should -BeNullOrEmpty
        @(Import-Csv -LiteralPath $Shared.Common.ExportCsvPath) | Should -HaveCount 2
    }
    It 'Updates real JSON and CSV reports repeatedly under an inherited Confirm preference without prompts' {
        & {
            [CmdletBinding(SupportsShouldProcess)]
            param($Plan)
            $ConfirmPreference | Should -Be 'Low'
            Write-DMSPlanResults -Plan $Plan
            foreach ($Entry in $Plan) { $Entry.Result.Status = 'Monitoring' }
            Write-DMSPlanResults -Plan $Plan
        } -Plan $Plan -Confirm
        $Json = Get-Content -LiteralPath $Shared.Common.OutputJsonPath -Raw | ConvertFrom-Json
        $Json.status | Should -Be 'InProgress'
        $Json.completedAt | Should -BeNullOrEmpty
        $Json.results | Should -HaveCount 2
        $Rows = @(Import-Csv -LiteralPath $Shared.Common.ExportCsvPath)
        $Rows | Should -HaveCount 2
        $Rows.Status | Should -Be @('Monitoring', 'Monitoring')
    }
    It 'Honors a per-item report override and records uncertain failures' {
        $Plan[1].Item.OutputJsonPath = Join-Path $TestDrive 'mi.json'
        Write-DMSPlanResults -Plan $Plan -ErrorMessage 'Monitoring access denied; migrations may still be running'
        $Default = Get-Content -LiteralPath $Shared.Common.OutputJsonPath -Raw | ConvertFrom-Json
        $Mi = Get-Content -LiteralPath $Plan[1].Item.OutputJsonPath -Raw | ConvertFrom-Json
        $Default.results | Should -HaveCount 1
        $Mi.results[0].ItemId | Should -Be 'MI-MIGRDEMO'
        $Mi.status | Should -Be 'Failed'
        $Mi.errors[0] | Should -Match 'Monitoring access denied'
    }
}

Describe 'Lifecycle script parameter forwarding' -Tag 'Unit' {
    It 'Preserves selectors and preview/confirmation flags through the real main guard' {
        $Fixture = Join-Path $TestDrive 'entry'
        $null = New-Item -ItemType Directory -Path (Join-Path $Fixture Common) -Force
        Copy-Item -LiteralPath (Join-Path $Scripts 'Invoke-RestoreDMS.ps1') -Destination $Fixture
        '[CmdletBinding()]param()' | Set-Content -LiteralPath (Join-Path $Fixture 'Common\Migration.Helpers.ps1')
        '' | Set-Content -LiteralPath (Join-Path $Fixture 'Common\Target.Helpers.ps1')
        '' | Set-Content -LiteralPath (Join-Path $Fixture 'Common\Execution.Helpers.ps1')
        @(
            'function Invoke-DMSConfiguredActivity {'
            '[CmdletBinding(SupportsShouldProcess)]param($ConfigPath, $ItemId, $Databases, $TargetName, $TargetType, $Activity, $Background)'
            'return ,$PSBoundParameters'
            '}'
        ) | Set-Content -LiteralPath (Join-Path $Fixture 'Common\Workflow.Helpers.ps1')
        $Result = & (Join-Path $Fixture 'Invoke-RestoreDMS.ps1') -ConfigPath 'custom.json' `
            -ItemId 'MI-MIGRDEMO' -Activity Status -WhatIf -Confirm:$false
        $Result.ConfigPath | Should -Be 'custom.json'
        $Result.ItemId | Should -Be @('MI-MIGRDEMO')
        $Result.Activity | Should -Be 'Status'
        $Result.WhatIf | Should -BeTrue
        $Result.Confirm | Should -BeFalse
        $Result.Background | Should -BeFalse
        $Background = & (Join-Path $Fixture 'Invoke-RestoreDMS.ps1') -ConfigPath 'custom.json' -Activity Status
        $Background.Background | Should -BeTrue
        $Foreground = & (Join-Path $Fixture 'Invoke-RestoreDMS.ps1') -ConfigPath 'custom.json' -Activity Status -Foreground
        $Foreground.Background | Should -BeFalse
    }
}

Describe 'Item cutover result association' -Tag 'Unit' {
    It 'Associates results with discovered IDs rather than assuming URL encoding of database names' {
        $Shared = Read-ServiceConfiguration $ReferencePath
        $Shared.Common.Activity = 'Cutover'
        $Shared.Items[0].TrgDatabaseName = 'App Db'
        $Plan = @(New-DMSItemPlan -Items @(Resolve-DMSConfigurationItems $Shared))
        Mock Get-DMSItemInventory {
            $Entry = $Plan | Where-Object { $_.Item.Id -eq $Item.Id }
            [pscustomobject]@{
                Id = $Entry.Migration.Id.Replace('%20', ' ')
                TargetName = $Item.TargetName; DatabaseName = $Item.TrgDatabaseName; MigrationStatus = 'ReadyForCutover'
            }
        }
        Mock Invoke-DMSRollingCutover {
            foreach ($Migration in $Migrations) { [pscustomobject]@{ Id = $Migration.Id; Status = 'Succeeded'; Error = $null } }
        }
        Invoke-DMSPlanCutover -Plan $Plan -MaxConcurrentCutover 2 -Confirm:$false
        $Plan.Result.Status | Should -Be @('Succeeded', 'Succeeded')
        Should -Invoke Invoke-DMSRollingCutover -Times 1 -Exactly -ParameterFilter {
            $MaxConcurrentCutover -eq 2 -and $ItemOptions.Count -eq 2 -and -not $Confirm
        }
    }
}
