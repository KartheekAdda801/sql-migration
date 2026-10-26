#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

function Get-DMSItemInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)

    Get-DMSMigrationInventory -SubscriptionId $Item.SubscriptionId -ResourceGroupName $Item.DMSResourceGroup `
        -DMSServiceName $Item.DMSServiceName -TargetName $Item.TargetName -TargetType $Item.TargetType `
        -TargetResourceGroup $Item.TargetResourceGroup -Databases @($Item.TrgDatabaseName) -IncludeDetails
}

function New-DMSItemPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Items)

    foreach ($Item in $Items) {
        $Operation = switch ($Item.Activity) {
            Restore { "Restore-$($Item.TargetType)" }
            Remove { 'Remove' }
            default { 'Control' }
        }
        $Configuration = ConvertTo-DMSItemConfiguration -Item $Item
        $Options = @{}
        foreach ($Property in $Configuration.Settings.PSObject.Properties) { $Options[$Property.Name] = $Property.Value }
        if ($Item.Activity -ne 'Restore') { $Options.MaxConcurrentCutover = 1 }
        $Provider = if ($Item.TargetType -eq 'SQLMI') { 'Microsoft.Sql/managedInstances' } else { 'Microsoft.SqlVirtualMachine/sqlVirtualMachines' }
        $Id = "/subscriptions/$($Item.SubscriptionId)/resourceGroups/$($Item.TargetResourceGroup)/providers/$Provider/$($Item.TargetName)/providers/Microsoft.DataMigration/databaseMigrations/$([uri]::EscapeDataString($Item.TrgDatabaseName))"
        [pscustomobject]@{
            Item = $Item; Operation = $Operation; Configuration = $Configuration; Options = $Options
            Migration = [pscustomobject]@{
                Id = $Id; SubscriptionId = $Item.SubscriptionId; ResourceGroup = $Item.TargetResourceGroup
                TargetName = $Item.TargetName; DatabaseName = $Item.TrgDatabaseName; Kind = $Item.TargetType
            }
            Result = [pscustomobject]@{
                ItemId = $Item.Id; Activity = $Item.Activity; TargetType = $Item.TargetType
                TargetName = $Item.TargetName; DatabaseName = $Item.TrgDatabaseName
                Status = 'Pending'; MigrationStatus = $null; LatestFile = $null; RestoredAt = $null; Error = $null
            }
        }
    }
}

function Get-DMSRestoreBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$Container)

    $Context = New-AzStorageContext -StorageAccountName $Item.BackupStorageAccount -UseConnectedAccount -ErrorAction Stop
    $Files = @(
        foreach ($Blob in @(Get-AzStorageBlob -Container $Container -Context $Context -ErrorAction Stop)) {
            $Extension = [IO.Path]::GetExtension($Blob.Name).TrimStart('.').ToLowerInvariant()
            if ($Extension -notin @('bak', 'diff', 'trn', 'log') -or
                $Blob.Name.IndexOf($Item.SrcDatabaseName, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $Date = Get-MigrationBackupTimestamp -FileName $Blob.Name `
                -TimestampPattern $Item.TimestampPattern -TimestampFormat $Item.TimestampFormat
            if ($null -eq $Date) {
                Write-Warning "Item '$($Item.Id)': cannot parse backup timestamp in '$($Blob.Name)'; file skipped."
                continue
            }
            [pscustomobject]@{ Name = $Blob.Name; Date = $Date; Extension = $Extension }
        }
    )
    $Full = $Files | Where-Object Extension -eq 'bak' | Sort-Object Date -Descending | Select-Object -First 1
    if (-not $Full) { throw "No usable timestamped FULL backup for '$($Item.SrcDatabaseName)' in '$Container'. Migration was not started." }
    $Diff = $Files | Where-Object { $_.Extension -eq 'diff' -and $_.Date -ge $Full.Date } |
        Sort-Object Date -Descending | Select-Object -First 1
    $Start = if ($Diff) { $Diff.Date } else { $Full.Date }
    $Log = $Files | Where-Object { $_.Extension -in @('trn', 'log') -and $_.Date -gt $Start } |
        Sort-Object Date -Descending | Select-Object -First 1
    if ($Log) { return $Log }
    if ($Diff) { return $Diff }
    return $Full
}

function Start-DMSItemRestore {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Entry, [pscredential]$SqlCredential)

    $ConfirmPreference = 'None'
    $Item = $Entry.Item
    if ($WhatIfPreference) {
        $null = $PSCmdlet.ShouldProcess($Entry.Migration.Id, 'Start ONLINE DMS restore')
        return [pscustomobject]@{ Status = 'WhatIf' }
    }
    Assert-DMSBlobIdentityOptions -BlobAuthType $Item.BlobAuthType -BlobIdentityType $Item.BlobIdentityType `
        -BlobUserAssignedIdentity $Item.BlobUserAssignedIdentity
    if ($Item.TargetType -eq 'SQLVM' -and $Item.BlobAuthType -ne 'AccountKey') { throw 'SQLVM requires AccountKey.' }
    $null = Set-AzContext -SubscriptionId $Item.SubscriptionId -Scope Process -WhatIf:$false -Confirm:$false -ErrorAction Stop
    if ($Entry.PSObject.Properties['RestoreState']) {
        if ($Entry.RestoreState.Skip) { return [pscustomobject]@{ Status = 'SkippedExistingTarget' } }
        if (-not $Entry.RestoreState.ReplaceExisting) {
            $Current = Get-DMSTargetDatabase -Item $Item -SqlCredential $SqlCredential
            if ($Current.Exists) { throw "Target database appeared after preflight for '$($Item.Id)'. No replacement was approved." }
        }
    }
    $Existing = @(Get-DMSItemInventory -Item $Item)
    if ($Existing.Count -gt 1) { throw "Multiple migrations matched '$($Item.Id)'." }
    $ReplaceExisting = $Entry.PSObject.Properties['RestoreState'] -and $Entry.RestoreState.ReplaceExisting
    if ($Existing.Count -and -not $ReplaceExisting -and $Existing[0].MigrationStatus -notin @('Failed', 'Canceled', 'Cancelled')) {
        Write-Warning "Skipping '$($Item.Id)': a migration already exists with status '$($Existing[0].MigrationStatus)'. Use Status or Monitor to inspect it; no replacement was submitted."
        return [pscustomobject]@{ Status = 'SkippedExistingMigration' }
    }
    $Container = $Item.BackupStorageContainerName
    if (-not $Container) { $Container = Get-ContainerName -ServerName $Item.SrcServerName -DatabaseName $Item.SrcDatabaseName }
    $Backup = Get-DMSRestoreBackup -Item $Item -Container $Container
    $Service = Get-AzDataMigrationSqlService -Name $Item.DMSServiceName -ResourceGroupName $Item.DMSResourceGroup -ErrorAction Stop
    if (-not $Service.Id) { throw "DMS service '$($Item.DMSServiceName)' did not return an ID." }
    $Provider = if ($Item.TargetType -eq 'SQLMI') { 'Microsoft.Sql/managedInstances' } else { 'Microsoft.SqlVirtualMachine/sqlVirtualMachines' }
    $TargetId = "/subscriptions/$($Item.SubscriptionId)/resourceGroups/$($Item.TargetResourceGroup)/providers/$Provider/$($Item.TargetName)"
    $StorageId = "/subscriptions/$($Item.SubscriptionId)/resourceGroups/$($Item.BackupStorageResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($Item.BackupStorageAccount)"
    $Authentication = Get-DMSBlobAuthentication -BlobAuthType $Item.BlobAuthType -BlobIdentityType $Item.BlobIdentityType `
        -BlobUserAssignedIdentity $Item.BlobUserAssignedIdentity -StorageAccountName $Item.BackupStorageAccount `
        -ResourceGroupName $Item.BackupStorageResourceGroup
    $Parameters = @{
        ResourceGroupName = $Item.TargetResourceGroup; TargetDbName = $Item.TrgDatabaseName
        SubscriptionId = $Item.SubscriptionId; AzureBlobContainerName = $Container
        AzureBlobStorageAccountResourceId = $StorageId; MigrationService = $Service.Id
        Scope = $TargetId; ErrorAction = 'Stop'
    }
    if ($ReplaceExisting) { Reset-DMSRestoreTarget -Entry $Entry -SqlCredential $SqlCredential }
    Write-Host "$($Item.Id): starting ONLINE $($Item.TargetType) migration; Blob authentication $($Item.BlobAuthType); latest backup $($Backup.Name)."
    switch ($Item.TargetType) {
        SQLVM { $Migration = New-AzDataMigrationToSqlVM @Parameters @Authentication -SqlVirtualMachineName $Item.TargetName -Kind SqlVM }
        SQLMI { $Migration = New-AzDataMigrationToSqlManagedInstance @Parameters @Authentication -ManagedInstanceName $Item.TargetName -Kind SqlMI }
        default { throw "Unsupported target type '$($Item.TargetType)'." }
    }
    if (-not $Migration) { throw "Migration submission for '$($Item.Id)' returned no result. Verify Azure state before retrying." }
    return [pscustomobject]@{ Status = 'Submitted' }
}

function Remove-DMSItemMigration {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Entry)

    $ConfirmPreference = 'None'
    $Item = $Entry.Item
    $Statuses = @('Succeeded')
    if ($Item.IncludeReadyForCutover) {
        Write-Warning 'Ready migrations are eligible for removal. Removal does not cut over the database.'
        $Statuses += @('ReadyForCutover', 'ReadyToCutover')
    }
    $Candidates = @(Get-DMSItemInventory -Item $Item | Where-Object MigrationStatus -in $Statuses)
    if ($Candidates.Count -gt 1) { throw "Multiple migrations matched '$($Item.Id)'." }
    if (-not $Candidates.Count) {
        Write-Warning "No eligible migration resource found for '$($Item.Id)'."
        $Entry.Result.Status = 'NoRemoval'
        return
    }
    $Candidates | Format-Table Id, MigrationStatus -Wrap | Out-Host
    $Migration = $Candidates[0]
    if ($WhatIfPreference) {
        $null = $PSCmdlet.ShouldProcess($Migration.Id, 'Remove DMS migration resource, NOT the database')
        $Entry.Result.Status = 'WhatIf'
        return
    }
    try {
        $null = Set-AzContext -SubscriptionId $Migration.SubscriptionId -Scope Process -WhatIf:$false -Confirm:$false -ErrorAction Stop
        $Parameters = @{
            SubscriptionId = $Migration.SubscriptionId; ResourceGroupName = $Migration.ResourceGroup
            TargetDbName = $Migration.DatabaseName; ErrorAction = 'Stop'
        }
        switch ([string]$Migration.Kind) {
            SQLVM { $null = Remove-AzDataMigrationToSqlVM @Parameters -SqlVirtualMachineName $Migration.TargetName }
            SQLMI { $null = Remove-AzDataMigrationToSqlManagedInstance @Parameters -ManagedInstanceName $Migration.TargetName }
            default { throw "Unsupported migration kind '$($Migration.Kind)'." }
        }
        $Entry.Result.Status = 'Removed'
    }
    catch {
        $Entry.Result.Status = 'Failed'
        $Entry.Result.Error = $_.Exception.Message
        throw
    }
}

function Invoke-DMSRestoreQueue {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan,
        [ValidateRange(1, 10)][int]$MaxConcurrentRestores,
        [object[]]$ReportPlan,
        [hashtable]$SqlCredentials = @{},
        [string]$ContextPath
    )

    $ConfirmPreference = 'None'
    if (-not $ReportPlan) { $ReportPlan = $Plan }
    $Active = @{}
    for ($Offset = 0; $Offset -lt $Plan.Count; $Offset += $MaxConcurrentRestores) {
        $End = [math]::Min($Offset + $MaxConcurrentRestores, $Plan.Count) - 1
        $Batch = @($Plan[$Offset..$End])
        Invoke-DMSRestoreBatch -Plan $Batch -SqlCredentials $SqlCredentials -ContextPath $ContextPath `
            -ReportPlan $ReportPlan -WhatIf:$WhatIfPreference -Confirm:$false
    }
    foreach ($Entry in $Plan) {
        if ($Entry.Result.Status -eq 'Submitted') {
            $Active[$Entry.Item.Id] = @{ Entry = $Entry; NextPoll = Get-Date }
        }
    }
    while ($Active.Count) {
        foreach ($Key in @($Active.Keys)) {
            $State = $Active[$Key]
            $Entry = $State.Entry
            if ((Get-Date) -lt $State.NextPoll) { continue }
            $State.NextPoll = (Get-Date).AddSeconds($Entry.Item.MonitorIntervalSeconds)
            try {
                $null = Set-AzContext -SubscriptionId $Entry.Item.SubscriptionId -Scope Process -WhatIf:$false -Confirm:$false -ErrorAction Stop
                $Detail = Get-DMSMigrationDetail -Migration $Entry.Migration
                if (-not $Detail -or -not $Detail.MigrationStatus) {
                    throw "No migration status returned for '$Key'."
                }
            }
            catch {
                $Entry.Result.Status = 'MonitoringFailed'
                $Entry.Result.Error = $_.Exception.Message
                Write-Warning "Monitoring '$Key' failed: $($_.Exception.Message). Other items continue; this Azure migration may still be running."
                $Active.Remove($Key)
                Write-DMSPlanResults -Plan $ReportPlan
                continue
            }
            $Entry.Result.MigrationStatus = [string]$Detail.MigrationStatus
            $Backup = Get-DMSLatestRestoredBackup -Detail $Detail
            $Entry.Result.LatestFile = $Backup.LatestFile
            $Entry.Result.RestoredAt = $Backup.RestoredAt
            Write-Host "$Key : $($Entry.Result.MigrationStatus)"
            Write-DMSPlanResults -Plan $ReportPlan
            if ($Detail.MigrationStatus -in @('ReadyForCutover', 'ReadyToCutover') -and $Entry.Item.AutoCutover) {
                $Parameters = @{
                    Migrations = @($Entry.Migration); MaxConcurrentCutover = 1
                    MonitorIntervalSeconds = $Entry.Item.MonitorIntervalSeconds
                    CutoverTimeoutMinutes = $Entry.Item.CutoverTimeoutMinutes; WhatIf = [bool]$WhatIfPreference; Confirm = $false
                }
                try {
                    $Cutover = @(Invoke-DMSRollingCutover @Parameters)
                    if ($Cutover.Count -ne 1) { throw "No cutover result for '$Key'." }
                }
                catch {
                    $Entry.Result.Status = 'Failed'
                    $Entry.Result.Error = $_.Exception.Message
                    Write-Warning "Automatic cutover for '$Key' failed: $($_.Exception.Message). Other items continue."
                    $Active.Remove($Key)
                    continue
                }
                $Entry.Result.Status = $Cutover[0].Status
                $Entry.Result.Error = $Cutover[0].Error
                if ($Cutover[0].Status -in @('Failed', 'TimedOut')) {
                    Write-Warning "Automatic cutover for '$Key': $($Cutover[0].Error). Other items continue; verify Azure state before retrying."
                    $Active.Remove($Key)
                    continue
                }
                if ($Cutover[0].Status -eq 'Succeeded') { $Active.Remove($Key) }
                else {
                    $Entry.Item.AutoCutover = $false
                    Write-Warning "Automatic cutover declined for '$Key'; migration continues to occupy its global slot."
                }
            }
            elseif ($Detail.MigrationStatus -in @('Succeeded', 'Failed', 'Canceled', 'Cancelled')) {
                $Entry.Result.Status = if ($Detail.MigrationStatus -eq 'Succeeded') { 'Succeeded' } else { 'Failed' }
                if ($Entry.Result.Status -eq 'Failed') {
                    $Entry.Result.Error = "DMS status: $($Detail.MigrationStatus). $($Detail.ErrorDetails)"
                    Write-Warning "$Key : $($Entry.Result.Error)"
                }
                $Active.Remove($Key)
            }
        }
        if ($Active.Count) {
            $Delay = ($Active.Values | ForEach-Object { $_.Entry.Item.MonitorIntervalSeconds } | Measure-Object -Minimum).Minimum
            Start-Sleep -Seconds $Delay
        }
    }
}

function Invoke-DMSPlanCutover {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object[]]$Plan, [ValidateRange(1, 20)][int]$MaxConcurrentCutover)

    $ConfirmPreference = 'None'
    $Migrations = @()
    $Options = @{}
    $SelectedIds = @{}
    foreach ($Entry in $Plan) {
        $Selected = @(Select-DMSCutoverMigration -Migrations @(Get-DMSItemInventory $Entry.Item) `
            -Names @($Entry.Item.TrgDatabaseName) -Target $Entry.Item.TargetName)
        $Migrations += $Selected
        $Options[$Selected[0].Id] = $Entry.Item
        $SelectedIds[$Entry.Item.Id] = $Selected[0].Id
    }
    $Parameters = @{ Migrations = $Migrations; MaxConcurrentCutover = $MaxConcurrentCutover; ItemOptions = $Options; WhatIf = [bool]$WhatIfPreference; Confirm = $false }
    $Results = @(Invoke-DMSRollingCutover @Parameters)
    foreach ($Entry in $Plan) {
        $Result = @($Results | Where-Object Id -eq $SelectedIds[$Entry.Item.Id])
        if ($Result.Count -ne 1) { throw "Missing or ambiguous cutover result for '$($Entry.Item.Id)'." }
        $Entry.Result.Status = $Result[0].Status
        $Entry.Result.Error = $Result[0].Error
    }
}

function Show-DMSPlanStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Plan)

    foreach ($Entry in $Plan) {
        $Inventory = @(Get-DMSItemInventory -Item $Entry.Item)
        if ($Inventory.Count -gt 1) { throw "Multiple migrations matched '$($Entry.Item.Id)'." }
        $Entry.Result.Status = if ($Inventory.Count) { 'Succeeded' } else { 'NotFound' }
        if (-not $Inventory.Count) { Write-Warning "No migration found for item '$($Entry.Item.Id)'." }
        foreach ($Name in @('MigrationStatus', 'LatestFile', 'RestoredAt')) {
            $Entry.Result.$Name = if ($Inventory.Count) { $Inventory[0].$Name } else { $null }
        }
    }
    $Plan.Result | Format-Table ItemId, TargetName, DatabaseName, MigrationStatus, LatestFile -AutoSize | Out-Host
}

function Write-DMSPlanResults {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Plan, [string]$ErrorMessage)

    $ConfirmPreference = 'None'
    foreach ($Group in @($Plan | Where-Object { $_.Item.OutputJsonPath } | Group-Object { [IO.Path]::GetFullPath($_.Item.OutputJsonPath) })) {
        $Status = 'Succeeded'
        if ($ErrorMessage -or @($Group.Group | Where-Object { $_.Result.Status -in @('Failed', 'TimedOut', 'SubmissionUnverified', 'MonitoringFailed') }).Count) {
            $Status = 'Failed'
        }
        elseif (@($Group.Group | Where-Object { $_.Result.Status -in @('Pending', 'Submitting', 'Submitted', 'Monitoring') }).Count) { $Status = 'InProgress' }
        Write-MigrationJsonResult -Path $Group.Name -Result @{
            schemaVersion = 1; operation = 'DMSWorkflow'; updatedAt = [datetime]::UtcNow
            completedAt = $(if ($Status -eq 'InProgress') { $null } else { [datetime]::UtcNow })
            status = $Status
            results = @($Group.Group.Result); errors = @($ErrorMessage | Where-Object { $_ })
        }
    }
    foreach ($Group in @($Plan | Where-Object { $_.Item.ExportCsvPath } | Group-Object { [IO.Path]::GetFullPath($_.Item.ExportCsvPath) })) {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Group.Name))
        $Group.Group.Result | Export-Csv -LiteralPath $Group.Name -NoTypeInformation -Encoding utf8 -Confirm:$false
    }
}

function Invoke-DMSConfiguredActivity {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot '..\..\config\Invoke-RestoreDMS.config.json'),
        [string[]]$ItemId, [string[]]$Databases, [string]$TargetName,
        [ValidateSet('SQLVM', 'SQLMI')][string]$TargetType,
        [ValidateSet('Restore', 'Status', 'Monitor', 'Cutover', 'Remove')][string]$Activity,
        [switch]$Background,
        [hashtable]$SqlCredentials = @{},
        [switch]$NonInteractive
    )

    $ConfirmPreference = 'None'
    $Configuration = Read-ServiceConfiguration -Path $ConfigPath
    if ($Configuration.schemaVersion -ne 2) { throw 'The lifecycle runner requires schemaVersion 2 with Common and Items.' }
    $Items = @(Resolve-DMSConfigurationItems -Configuration $Configuration)
    $Items = @(Select-DMSConfigurationItems -Items $Items -ItemId $ItemId -Databases $Databases -TargetName $TargetName -TargetType $TargetType)
    if ($Activity) { foreach ($Item in $Items) { $Item.Activity = $Activity } }
    $CredentialFilePath = Join-Path (Split-Path -Parent (Convert-Path -LiteralPath $ConfigPath)) 'password.local.json'
    $OutputKinds = @{}
    foreach ($Item in $Items) {
        foreach ($Name in @('OutputJsonPath', 'ExportCsvPath')) {
            if (-not $Item.$Name) { continue }
            $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Item.$Name)
            if ($Path -ieq (Convert-Path -LiteralPath $ConfigPath)) { throw 'A result path cannot overwrite the migration configuration.' }
            if ($Path -ieq $CredentialFilePath) { throw 'A result path cannot overwrite the local credential file.' }
            if ($OutputKinds.ContainsKey($Path) -and $OutputKinds[$Path] -ne $Name) { throw 'JSON and CSV result paths must be different.' }
            $OutputKinds[$Path] = $Name
            $Item.$Name = $Path
        }
    }
    $Plan = @(New-DMSItemPlan -Items $Items)
    foreach ($Entry in $Plan) {
        Write-Host "$($Entry.Item.Id): $($Entry.Item.Activity) $($Entry.Item.TargetType) $($Entry.Item.TargetName)/$($Entry.Item.TrgDatabaseName)"
        if ($Entry.Item.ExportCsvPath) { Assert-ServiceOutputPath -Path $Entry.Item.ExportCsvPath }
        Invoke-DataMigrationPreflight -Operation $Entry.Operation -Configuration $Entry.Configuration -Options $Entry.Options
    }
    Initialize-DMSRestorePlan -Plan $Plan -SqlCredentials $SqlCredentials -Preview:$WhatIfPreference `
        -NonInteractive:$NonInteractive -CredentialFilePath $CredentialFilePath
    if ($WhatIfPreference) {
        foreach ($Entry in $Plan) { $null = $PSCmdlet.ShouldProcess($Entry.Migration.Id, $Entry.Item.Activity) }
        return
    }
    $ReportName = 'Invoke-RestoreDMS.{0}.{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N')
    foreach ($Entry in $Plan) {
        foreach ($Format in @{ OutputJsonPath = 'json'; ExportCsvPath = 'csv' }.GetEnumerator()) {
            if (-not $Entry.Item.($Format.Key)) {
                $Entry.Item.($Format.Key) = Join-Path $PSScriptRoot "..\..\logs\Reports\$ReportName.$($Format.Value)"
            }
        }
    }
    $Directory = New-DMSRunDirectory
    Write-DMSPlanResults -Plan $Plan
    $RunParameters = @{
        Plan = $Plan; Directory = $Directory; SqlCredentials = $SqlCredentials
        MaxConcurrentRestores = $Configuration.Common.MaxConcurrentRestores
        MaxConcurrentCutover = $Configuration.Common.MaxConcurrentCutover
    }
    if ($Background) { Start-DMSBackgroundRun @RunParameters }
    else { Invoke-DMSRun @RunParameters }
}

function Invoke-DMSPreparedPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [Parameter(Mandatory)][int]$MaxConcurrentRestores,
        [Parameter(Mandatory)][int]$MaxConcurrentCutover,
        [hashtable]$SqlCredentials = @{},
        [string]$ContextPath
    )

    $ConfirmPreference = 'None'
    $RunError = $null
    try {
        $Status = @($Plan | Where-Object { $_.Item.Activity -eq 'Status' })
        if ($Status.Count) { Show-DMSPlanStatus -Plan $Status }
        $Cutover = @($Plan | Where-Object { $_.Item.Activity -eq 'Cutover' })
        $Confirmation = @{ Confirm = $false }
        if ($Cutover.Count) { Invoke-DMSPlanCutover -Plan $Cutover -MaxConcurrentCutover $MaxConcurrentCutover @Confirmation }
        foreach ($Entry in @($Plan | Where-Object { $_.Item.Activity -eq 'Remove' })) {
            Remove-DMSItemMigration -Entry $Entry @Confirmation
        }
        $Restores = @($Plan | Where-Object { $_.Item.Activity -eq 'Restore' })
        if ($Restores.Count) {
            Invoke-DMSRestoreQueue -Plan $Restores `
                -MaxConcurrentRestores $MaxConcurrentRestores -ReportPlan $Plan `
                -SqlCredentials $SqlCredentials -ContextPath $ContextPath @Confirmation
        }
        $Monitor = @($Plan | Where-Object { $_.Item.Activity -eq 'Monitor' })
        if ($Monitor.Count) {
            do {
                Show-DMSPlanStatus -Plan $Monitor
                $Pending = @(
                    foreach ($Entry in $Monitor) {
                        if ($Entry.Result.Status -eq 'NotFound' -or [string]::IsNullOrWhiteSpace($Entry.Result.MigrationStatus)) {
                            throw "No migration status returned for monitored item '$($Entry.Item.Id)'."
                        }
                        if ($Entry.Result.MigrationStatus -in @('Failed', 'Canceled', 'Cancelled')) {
                            $Entry.Result.Status = 'Failed'
                            $Entry.Result.Error = "DMS status: $($Entry.Result.MigrationStatus)"
                        }
                        elseif ($Entry.Result.MigrationStatus -ne 'Succeeded') {
                            $Entry.Result.Status = 'Monitoring'
                            $Entry
                        }
                    }
                )
                Write-DMSPlanResults -Plan $Plan
                if ($Pending.Count) {
                    $WaitMinutes = ($Pending | ForEach-Object { $_.Item.RefreshWaitMinutes } | Measure-Object -Minimum).Minimum
                    Start-Sleep -Seconds ($WaitMinutes * 60)
                }
            } while ($Pending.Count)
        }
        $Plan.Result | Format-Table ItemId, Activity, TargetName, DatabaseName, Status, Error -AutoSize | Out-Host
        if (@($Plan | Where-Object { $_.Result.Status -in @('Failed', 'TimedOut', 'SubmissionUnverified', 'MonitoringFailed') }).Count) { throw 'One or more DMS activities failed. Review the results.' }
    }
    catch {
        $RunError = $_.Exception.Message
        Write-Warning "DMS workflow stopped: $RunError. Existing Azure operations were not canceled."
        throw
    }
    finally { Write-DMSPlanResults -Plan $Plan -ErrorMessage $RunError }
}
