#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    $Scripts = Join-Path $PSScriptRoot '..\scripts'
    . (Join-Path $Scripts 'Invoke-RestoreDMS.ps1')
    $ReferencePath = Join-Path $PSScriptRoot 'Fixtures\Restore.config.json'
    function Set-AzContext { [CmdletBinding(SupportsShouldProcess)]param($SubscriptionId, $Scope) throw 'Unmocked Azure call' }
    function Get-AzDataMigrationSqlService { [CmdletBinding()]param($Name, $ResourceGroupName, $SubscriptionId) throw 'Unmocked Azure call' }
    function New-AzDataMigrationSqlService {
        [CmdletBinding(SupportsShouldProcess)]param($Name, $ResourceGroupName, $SubscriptionId, $Location)
        throw 'Unmocked DMS service creation'
    }
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
    It 'Supports explicit WindowsAD for VM while leaving MI on Entra and Blob authentication unchanged' {
        $Shared.Items[0].TargetSqlAuthType = 'WindowsAD'
        $Items = @(Resolve-DMSConfigurationItems $Shared)
        $Items.TargetSqlAuthType | Should -Be @('WindowsAD', 'Entra')
        $Items.BlobAuthType | Should -Be @('AccountKey', 'ManagedIdentity')
    }
    It 'Rejects WindowsAD authentication for MI' {
        $Shared.Items[1].TargetSqlAuthType = 'WindowsAD'
        { Resolve-DMSConfigurationItems $Shared } | Should -Throw '*WindowsAD*supported only for SQLVM*'
    }
    It 'Rejects obsolete container fields in Common or Items, including blank overrides' -ForEach @(
        @{ Section = 'Common'; Field = 'BackupStorageContainerName'; Value = '' }
        @{ Section = 'Items'; Field = 'BackupStorageContainerName'; Value = 'old-container' }
        @{ Section = 'Common'; Field = 'BackupContainerName'; Value = 'old-container' }
        @{ Section = 'Items'; Field = 'BackupContainerName'; Value = '' }
    ) {
        $ValueObject = if ($Section -eq 'Common') { $Shared.Common } else { $Shared.Items[0] }
        $ValueObject | Add-Member -NotePropertyName $Field -NotePropertyValue $Value
        { Resolve-DMSConfigurationItems $Shared } | Should -Throw "*$Field*Remove it*SrcServerName/SrcDatabaseName*"
    }
    It 'Does not require source fields solely for <Activity> discovery' -ForEach @(
        @{ Activity = 'Status' }, @{ Activity = 'Monitor' }, @{ Activity = 'Cutover' }
    ) {
        $Shared.Common.Activity = $Activity
        foreach ($Source in $Shared.Items) {
            $Source.PSObject.Properties.Remove('SrcServerName')
            $Source.PSObject.Properties.Remove('SrcDatabaseName')
        }
        $Items = @(Resolve-DMSConfigurationItems $Shared)
        $Items | Should -HaveCount 2
        { New-DMSItemPlan -Items $Items } | Should -Not -Throw
    }
    It 'Requires source fields when Restore needs container derivation' {
        $Shared.Items[0].SrcServerName = ''
        { Resolve-DMSConfigurationItems $Shared } | Should -Throw '*SrcServerName*'
    }
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

Describe 'Configured DMS SQL service creation' -Tag 'Unit' {
    BeforeEach {
        $Config = Read-ServiceConfiguration $ReferencePath
        $Plan = @(New-DMSItemPlan -Items @(Resolve-DMSConfigurationItems $Config))
        $script:Services = @()
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Write-DMSPlanResults {}
        Mock Get-AzDataMigrationSqlService { $script:Services }
        Mock New-AzDataMigrationSqlService {
            $script:Services += [pscustomobject]@{
                Name = $Name; Location = $Location; ProvisioningState = 'Succeeded'
                Id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DataMigration/sqlMigrationServices/$Name"
            }
        }
        Mock Invoke-DMSRestoreQueue {}
    }
    It 'Creates one shared service before submitting both VM and MI restores' {
        Mock Invoke-DMSRestoreQueue {
            $script:Services | Should -HaveCount 1
            @($Plan | ForEach-Object { $_.Item.TargetType }) | Should -Be @('SQLVM', 'SQLMI')
        }
        Invoke-DMSPreparedPlan -Plan $Plan -MaxConcurrentRestores 10 -MaxConcurrentCutover 5
        Should -Invoke New-AzDataMigrationSqlService -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'test-dms' -and $ResourceGroupName -eq 'rg-ak-personal' -and
            $SubscriptionId -eq '11111111-1111-1111-1111-111111111111' -and $Location -eq 'centralus' -and -not $Confirm
        }
        Should -Invoke Invoke-DMSRestoreQueue -Times 1 -Exactly
    }
    It 'Creates independently named configured services rather than one service per database' {
        $Plan[1].Item.DMSServiceName = 'mi-dms'
        Initialize-DMSRestoreServices -Plan $Plan -Confirm:$false
        @($script:Services.Name | Sort-Object) | Should -Be @('mi-dms', 'test-dms')
        Should -Invoke New-AzDataMigrationSqlService -Times 2 -Exactly
    }
    It 'Keeps services in different subscriptions or groups separate' -ForEach @(
        @{ Field = 'SubscriptionId'; Value = '22222222-2222-2222-2222-222222222222' }
        @{ Field = 'DMSResourceGroup'; Value = 'another-group' }
    ) {
        $Plan[1].Item.($Field) = $Value
        Mock Get-AzDataMigrationSqlService {
            $script:Services | Where-Object {
                $_.Id -like "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/*"
            }
        }
        Initialize-DMSRestoreServices -Plan $Plan -Confirm:$false
        Should -Invoke New-AzDataMigrationSqlService -Times 2 -Exactly
    }
    It 'Reuses an existing service without updating it' {
        $script:Services = @([pscustomobject]@{ Name = 'test-dms'; Location = 'centralus'; ProvisioningState = 'Succeeded' })
        Initialize-DMSRestoreServices -Plan $Plan
        Should -Invoke New-AzDataMigrationSqlService -Times 0 -Exactly
    }
    It 'Does not let an unrelated existing service hide the missing configured service' {
        $script:Services = @([pscustomobject]@{ Name = 'another-dms'; Location = 'centralus'; ProvisioningState = 'Succeeded' })
        Initialize-DMSRestoreServices -Plan $Plan -Confirm:$false
        Should -Invoke New-AzDataMigrationSqlService -Times 1 -Exactly -ParameterFilter { $Name -eq 'test-dms' }
    }
    It 'Deduplicates names case insensitively' {
        $Plan[1].Item.DMSServiceName = 'TEST-DMS'
        Initialize-DMSRestoreServices -Plan $Plan -Confirm:$false
        Should -Invoke New-AzDataMigrationSqlService -Times 1 -Exactly
    }
    It 'Rejects conflicting locations before creating any service' {
        $Plan[1].Item.Location = 'eastus'
        { Initialize-DMSRestoreServices -Plan $Plan } | Should -Throw '*Conflicting Location*'
        Should -Invoke Get-AzDataMigrationSqlService -Times 0 -Exactly
        Should -Invoke New-AzDataMigrationSqlService -Times 0 -Exactly
    }
    It 'Rejects a failed or differently located existing service instead of overwriting it' -ForEach @(
        @{ Location = 'eastus'; State = 'Succeeded'; Message = '*Location does not match*' }
        @{ Location = 'centralus'; State = 'Failed'; Message = '*not successfully provisioned*' }
    ) {
        $script:Services = @([pscustomobject]@{ Name = 'test-dms'; Location = $Location; ProvisioningState = $State })
        { Initialize-DMSRestoreServices -Plan $Plan } | Should -Throw $Message
        Should -Invoke New-AzDataMigrationSqlService -Times 0 -Exactly
    }
    It 'Surfaces service discovery errors instead of treating them as absence' -ForEach @(
        @{ Message = 'AuthorizationFailed' }, @{ Message = 'Network timeout' }, @{ Message = 'ResourceGroupNotFound' }
    ) {
        Mock Get-AzDataMigrationSqlService { throw $Message }
        { Initialize-DMSRestoreServices -Plan $Plan } | Should -Throw "*$Message*"
        Should -Invoke New-AzDataMigrationSqlService -Times 0 -Exactly
    }
    It 'Stops migration submission when creation fails' {
        Mock New-AzDataMigrationSqlService { throw 'DMS creation denied' }
        { Invoke-DMSPreparedPlan -Plan $Plan -MaxConcurrentRestores 10 -MaxConcurrentCutover 5 } |
            Should -Throw '*DMS creation denied*'
        Should -Invoke Invoke-DMSRestoreQueue -Times 0 -Exactly
        Should -Invoke Write-DMSPlanResults -Times 1 -Exactly -ParameterFilter { $ErrorMessage -like '*creation denied*' }
    }
    It 'Verifies the newly created resource before allowing migration submission' {
        Mock New-AzDataMigrationSqlService {}
        { Invoke-DMSPreparedPlan -Plan $Plan -MaxConcurrentRestores 10 -MaxConcurrentCutover 5 } |
            Should -Throw '*could not be verified*'
        Should -Invoke Invoke-DMSRestoreQueue -Times 0 -Exactly
    }
    It 'Continues independent MI service initialization and restore when VM service creation fails' {
        $Plan[0].Item.DMSServiceName = 'a-vm-dms'
        $Plan[1].Item.DMSServiceName = 'z-mi-dms'
        Mock New-AzDataMigrationSqlService {
            if ($Name -eq 'a-vm-dms') { throw 'VM DMS denied' }
            $script:Services += [pscustomobject]@{
                Name = $Name; Location = $Location; ProvisioningState = 'Succeeded'; Id = 'mi-service-id'
            }
        }
        Mock Invoke-DMSRestoreQueue { foreach ($Entry in $Plan) { $Entry.Result.Status = 'Succeeded' } }
        { Invoke-DMSPreparedPlan -Plan $Plan -MaxConcurrentRestores 10 -MaxConcurrentCutover 5 } |
            Should -Throw '*VM DMS denied*'
        $Plan[0].Result.Status | Should -Be 'Failed'
        $Plan[1].Result.Status | Should -Be 'Succeeded'
        Should -Invoke New-AzDataMigrationSqlService -Times 2 -Exactly
        Should -Invoke Invoke-DMSRestoreQueue -Times 1 -Exactly -ParameterFilter {
            $Plan.Count -eq 1 -and $Plan[0].Item.Id -eq 'MI-MIGRDEMO' -and $ReportPlan.Count -eq 2
        }
    }
    It 'Does not create resources when the service helper is previewed directly' {
        Initialize-DMSRestoreServices -Plan $Plan -WhatIf
        Should -Invoke New-AzDataMigrationSqlService -Times 0 -Exactly
    }
    It 'Does not create services for skipped existing targets' {
        foreach ($Entry in $Plan) { $Entry | Add-Member RestoreState ([pscustomobject]@{ Skip = $true }) }
        Initialize-DMSRestoreServices -Plan $Plan
        Should -Invoke Get-AzDataMigrationSqlService -Times 0 -Exactly
        Should -Invoke New-AzDataMigrationSqlService -Times 0 -Exactly
    }
    It 'Does not create services for <Activity>' -ForEach @(
        @{ Activity = 'Status' }, @{ Activity = 'Monitor' }, @{ Activity = 'Cutover' }, @{ Activity = 'Remove' }
    ) {
        foreach ($Entry in $Plan) { $Entry.Item.Activity = $Activity }
        Initialize-DMSRestoreServices -Plan $Plan
        Should -Invoke Get-AzDataMigrationSqlService -Times 0 -Exactly
        Should -Invoke New-AzDataMigrationSqlService -Times 0 -Exactly
    }
}

Describe 'SQL validation failure isolation through the restore workflow' -Tag 'Unit' {
    It 'Records a first VM login failure, submits the next MI, and persists both outcomes before reporting failure' {
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Invoke-DataMigrationPreflight {}
        Mock Get-DMSTargetDatabase {
            if ($Item.TargetType -eq 'SQLVM') { throw "SQL VM login failed for user ''" }
            [pscustomobject]@{ Exists = $false; DatabaseId = 0; CreatedAt = ''; CanAlter = $true }
        }
        Mock Get-DMSItemInventory { @() }
        Mock Initialize-DMSRestoreServices {}
        Mock New-DMSRunDirectory { Join-Path $TestDrive 'sql-isolation-run' }
        Mock Invoke-DMSRun {
            Invoke-DMSPreparedPlan -Plan $Plan -MaxConcurrentRestores $MaxConcurrentRestores `
                -MaxConcurrentCutover $MaxConcurrentCutover -SqlCredentials $SqlCredentials -ContextPath 'offline-context'
        }
        Mock Invoke-DMSRestoreQueue { foreach ($Entry in $Plan) { $Entry.Result.Status = 'Succeeded' } }
        $Config = Read-ServiceConfiguration $ReferencePath
        $ReportPath = Join-Path $TestDrive 'mixed-sql-results.json'
        $Config.Common.OutputJsonPath = $ReportPath
        $Config.Common.ExportCsvPath = Join-Path $TestDrive 'mixed-sql-results.csv'
        $ConfigPath = Join-Path $TestDrive 'mixed-sql-config.json'
        $Config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath
        { Invoke-DMSConfiguredActivity -ConfigPath $ConfigPath -Activity Restore } |
            Should -Throw '*VM-MIGRDEMO*Target validation*SQL VM login failed*'
        Should -Invoke Get-DMSTargetDatabase -Times 2 -Exactly
        Should -Invoke Invoke-DMSRestoreQueue -Times 1 -Exactly -ParameterFilter {
            $Plan.Count -eq 1 -and $Plan[0].Item.Id -eq 'MI-MIGRDEMO'
        }
        $Report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
        $Report.status | Should -Be 'Failed'
        $Report.results.Status | Should -Be @('Failed', 'Succeeded')
        $Report.results[0].Error | Should -BeLike '*Target validation*SQL VM login failed*'
    }
}

Describe 'Mixed-target workflow safeguards' -Tag 'Unit' {
    BeforeEach {
        Mock Write-Host {}
        Mock Read-Host { throw 'Unexpected prompt' }
        Mock Invoke-DataMigrationPreflight {}
        Mock Initialize-DMSRestorePlan {}
        Mock Initialize-DMSRestoreServices {}
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
        Should -Invoke Initialize-DMSRestoreServices -Times 0 -Exactly
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
    It 'Continues the healthy VM restore when MI preflight fails and reports an overall failure' {
        Mock Invoke-DataMigrationPreflight { if ($Operation -like '*SQLMI') { throw 'MI denied' } }
        Mock Write-Warning {}
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        { Invoke-DMSConfiguredActivity -ConfigPath $Path -Activity Restore -Confirm:$false } | Should -Throw '*MI denied*'
        Should -Invoke Invoke-DataMigrationPreflight -Times 2 -Exactly
        Should -Invoke Invoke-DMSRestoreQueue -Times 1 -Exactly -ParameterFilter {
            $Plan.Count -eq 1 -and $Plan[0].Item.Id -eq 'VM-MIGRDEMO' -and
            $ReportPlan.Count -eq 2 -and $ReportPlan[1].Result.Status -eq 'Failed'
        }
        Should -Invoke Initialize-DMSRestoreServices -Times 1 -Exactly -ParameterFilter { $Plan.Count -eq 1 }
    }
    It 'Continues MI when the first VM resource preflight fails' {
        Mock Invoke-DataMigrationPreflight { if ($Operation -like '*SQLVM') { throw 'VM unavailable' } }
        Mock Write-Warning {}
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        { Invoke-DMSConfiguredActivity -ConfigPath $Path -Activity Restore } | Should -Throw '*VM unavailable*'
        Should -Invoke Invoke-DataMigrationPreflight -Times 2 -Exactly
        Should -Invoke Invoke-DMSRestoreQueue -Times 1 -Exactly -ParameterFilter {
            $Plan.Count -eq 1 -and $Plan[0].Item.Id -eq 'MI-MIGRDEMO' -and
            $ReportPlan[0].Result.Error -like '*Preflight*VM unavailable*'
        }
    }
    It 'Attempts all restore previews and reports failures without creating output or starting jobs' {
        Mock Invoke-DataMigrationPreflight { if ($Operation -like '*SQLVM') { throw 'VM preview denied' } }
        Mock Write-Warning {}
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        { Invoke-DMSConfiguredActivity -ConfigPath $Path -Activity Restore -WhatIf } | Should -Throw '*Restore preview failed*VM preview denied*'
        Should -Invoke Invoke-DataMigrationPreflight -Times 2 -Exactly
        Should -Invoke Initialize-DMSRestoreServices -Times 0 -Exactly
        Should -Invoke Invoke-DMSRestoreQueue -Times 0 -Exactly
        Should -Invoke Write-DMSPlanResults -Times 0 -Exactly
        Should -Invoke New-DMSRunDirectory -Times 0 -Exactly
    }
    It 'Writes failure reports without launching execution when every restore fails preflight' {
        Mock Invoke-DataMigrationPreflight { throw 'No target access' }
        Mock Write-Warning {}
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        { Invoke-DMSConfiguredActivity -ConfigPath $Path -Activity Restore } | Should -Throw '*All selected restore items failed validation*'
        Should -Invoke Write-DMSPlanResults -Times 1 -Exactly -ParameterFilter {
            @($Plan | Where-Object { $_.Result.Status -eq 'Failed' }).Count -eq 2
        }
        Should -Invoke Invoke-DMSRun -Times 0 -Exactly
        Should -Invoke Invoke-DMSRestoreQueue -Times 0 -Exactly
    }
    It 'Preserves all-or-nothing preflight for explicit cutover' {
        Mock Invoke-DataMigrationPreflight { throw 'Cutover not ready' }
        $Shared | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        { Invoke-DMSConfiguredActivity -ConfigPath $Path -Activity Cutover } | Should -Throw '*Cutover not ready*'
        Should -Invoke Invoke-DMSRun -Times 0 -Exactly
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
    It 'Uses the source mapping for <Target> with <Server>, even when the target database is renamed' -ForEach @(
        @{ Target = 'SQLVM'; Server = 'SoUrCe'; Expected = 'source-appdb' }
        @{ Target = 'SQLVM'; Server = 'SoUrCe\InStAnCe'; Expected = 'source-instance-appdb' }
        @{ Target = 'SQLMI'; Server = 'SoUrCe'; Expected = 'source-appdb' }
        @{ Target = 'SQLMI'; Server = 'SoUrCe\InStAnCe'; Expected = 'source-instance-appdb' }
    ) {
        $Entry = $Plan | Where-Object { $_.Item.TargetType -eq $Target }
        $Entry.Item.SrcServerName = $Server
        $Entry.Item.SrcDatabaseName = 'AppDb'
        $Entry.Item.TrgDatabaseName = 'RenamedDb'
        Mock Get-AzStorageBlob { [pscustomobject]@{ Name = 'AppDb_20261023_010000.bak' } }
        $null = Start-DMSItemRestore -Entry $Entry -Confirm:$false
        $Command = if ($Target -eq 'SQLVM') { 'New-AzDataMigrationToSqlVM' } else { 'New-AzDataMigrationToSqlManagedInstance' }
        Should -Invoke Get-AzStorageBlob -Times 1 -Exactly -ParameterFilter { $Container -eq $Expected }
        Should -Invoke $Command -Times 1 -Exactly -ParameterFilter {
            $AzureBlobContainerName -eq $Expected -and $TargetDbName -eq 'RenamedDb'
        }
    }
    It 'Aborts on an uncertain existing-migration lookup instead of continuing to submit' {
        Mock Get-DMSItemInventory { throw 'Inventory permission denied' }
        { Start-DMSItemRestore -Entry $Plan[1] -Confirm:$false } | Should -Throw '*Inventory permission denied*'
        Should -Invoke New-AzDataMigrationToSqlManagedInstance -Times 0 -Exactly
    }
    It 'Does not submit <Target> when backup discovery fails or no FULL is usable: <Failure>' -ForEach @(
        @{ Target = 'SQLVM'; Failure = 'Denied' }, @{ Target = 'SQLVM'; Failure = 'NoFull' }
        @{ Target = 'SQLMI'; Failure = 'Denied' }, @{ Target = 'SQLMI'; Failure = 'NoFull' }
    ) {
        Mock Get-AzStorageBlob {
            if ($Failure -eq 'Denied') { throw 'Blob read denied' }
            @(@{ Name = 'MIGRDEMO_20261023_030000.trn' })
        }
        $Entry = $Plan | Where-Object { $_.Item.TargetType -eq $Target }
        { Start-DMSItemRestore -Entry $Entry -Confirm:$false } | Should -Throw
        Should -Invoke New-AzDataMigrationToSqlVM -Times 0 -Exactly
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
    It 'Keeps a partial-failure report in progress until the healthy restore completes' {
        $Plan[0].Result.Status = 'Failed'
        $Plan[0].Result.Error = 'VM login failed'
        $Plan[1].Result.Status = 'Monitoring'
        Write-DMSPlanResults -Plan $Plan
        $Json = Get-Content -LiteralPath $Shared.Common.OutputJsonPath -Raw | ConvertFrom-Json
        $Json.status | Should -Be 'InProgress'
        $Json.completedAt | Should -BeNullOrEmpty
        $Json.results[0].Error | Should -Be 'VM login failed'
        $Plan[1].Result.Status = 'Succeeded'
        Write-DMSPlanResults -Plan $Plan
        $Json = Get-Content -LiteralPath $Shared.Common.OutputJsonPath -Raw | ConvertFrom-Json
        $Json.status | Should -Be 'Failed'
        $Json.completedAt | Should -Not -BeNullOrEmpty
        $Json.results.Status | Should -Be @('Failed', 'Succeeded')
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
