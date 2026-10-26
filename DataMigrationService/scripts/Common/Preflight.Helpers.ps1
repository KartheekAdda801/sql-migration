#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

function Assert-DataMigrationAzCopyAccess {
    [CmdletBinding()]
    param([string]$Executable, [string]$Destination)

    $null = & $Executable list $Destination --output-type=json --log-level=NONE 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "AzCopy cannot list '$Destination' (exit $LASTEXITCODE). Authenticate AzCopy as the executor and check network and Blob permissions."
    }
}

function Invoke-DataMigrationPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][hashtable]$Options
    )

    if ($Options.OutputJsonPath) { Assert-ServiceOutputPath -Path $Options.OutputJsonPath }
    if ($Options.ExportCsvPath) { Assert-ServiceOutputPath -Path $Options.ExportCsvPath }
    if ($Operation -like 'Invoke-CopyBackup*' -or $Operation -like 'Restore-*') {
        Assert-ServiceOutputPath -Path (Join-Path $PSScriptRoot '..\..\logs\.preflight')
    }
    if ($Operation -like 'Invoke-CopyBackup*') {
        $Items = @($Configuration.Items)
        Assert-ServiceFields -Items $Items -Required SrcServerName, SrcDatabaseName, BackupRootPath, IsActive, BackupStorageAccountName
        foreach ($Item in $Items) {
            if ($Item.IsActive -notmatch '^[YN]$') { throw 'IsActive must be Y or N.' }
        }
        Assert-MigrationTimestampOptions -TimestampPattern $Options.TimestampPattern -TimestampFormat $Options.TimestampFormat
        $Selected = @($Items | Where-Object { $_.IsActive -eq 'Y' -or $Options.CheckLatestBak -eq 'Y' })
        foreach ($Item in $Selected) {
            $FullFolder = Join-Path $Item.BackupRootPath 'full'
            $Files = @(Get-ChildItem -LiteralPath $Item.BackupRootPath -Recurse -File -ErrorAction Stop |
                Where-Object Extension -in @('.bak', '.diff', '.trn', '.log'))
            $Full = @($Files | Where-Object {
                $_.DirectoryName -eq $FullFolder -and $_.Extension -eq '.bak' -and
                $null -ne (Get-MigrationBackupTimestamp -FileName $_.Name -TimestampPattern $Options.TimestampPattern -TimestampFormat $Options.TimestampFormat)
            })
            if (-not $Full.Count) { throw "No usable FULL backup in '$FullFolder'." }
            foreach ($File in $Files) { Assert-ServiceReadableFile -Path $File.FullName }
        }
        if ($Options.AzCopyPath) {
            $ExecutableFile = Get-Item -LiteralPath $Options.AzCopyPath -ErrorAction Stop
            if ($ExecutableFile.PSIsContainer) { throw 'AzCopyPath must be an executable file.' }
            $Executable = $ExecutableFile.FullName
        }
        else { $Executable = (Get-Command azcopy -CommandType Application -ErrorAction Stop).Source }
        if ($Selected.Count -and $Options.CheckLatestBak -ne 'Y') {
            Import-Module Az.Accounts, Az.Storage -ErrorAction Stop
            $Context = Get-AzContext -ErrorAction Stop
            if (-not $Context) { throw 'Authenticate with Connect-AzAccount before storage preflight.' }
            if ($Options.TenantId -and $Context.Tenant.Id -ne $Options.TenantId) { throw 'Azure context tenant does not match configured TenantId.' }
            if ($Options.SubscriptionId) {
                Assert-ServiceGuid -Name SubscriptionId -Value $Options.SubscriptionId
                $null = Set-AzContext -SubscriptionId $Options.SubscriptionId -Scope Process -WhatIf:$false -Confirm:$false -ErrorAction Stop
            }
            if ($Options.InteractiveLogin) {
                $LoginArguments = @('login', '--log-level=NONE')
                if ($Options.TenantId) { $LoginArguments += "--tenant-id=$($Options.TenantId)" }
                $null = & $Executable @LoginArguments
                if ($LASTEXITCODE -ne 0) { throw "AzCopy login failed (exit $LASTEXITCODE)." }
            }
            foreach ($Item in $Selected) {
                $Container = [string]$Item.BackupContainerName
                if ([string]::IsNullOrWhiteSpace($Container)) {
                    $Container = Get-ContainerName -ServerName $Item.SrcServerName -DatabaseName $Item.SrcDatabaseName
                }
                $null = Assert-ServiceStorage -Account $Item.BackupStorageAccountName -Container $Container
                Assert-DataMigrationAzCopyAccess -Executable $Executable -Destination "https://$($Item.BackupStorageAccountName).blob.core.windows.net/$Container"
            }
            Write-Warning 'Storage reads do not prove AzCopy write access. AzCopy authentication must also be configured for the executor.'
        }
    }
    elseif ($Operation -like 'Restore-*') {
        $Platform = if ($Operation -like '*SQLMI') { 'SQLMI' } else { 'SQLVM' }
        $Items = @($Configuration.Items)
        Assert-ServiceFields -Items $Items -Required @('SrcServerName', 'SrcDatabaseName', 'BackupStorageAccount',
            'BackupStorageResourceGroup', 'SubscriptionId', 'Location', "Trg$Platform",
            "Trg${Platform}ResourceGroup", 'TrgDatabaseName', 'DMSServiceName', 'DMSResourceGroup', 'TargetSqlHost')
        $Targets = @{}
        foreach ($Item in $Items) {
            Assert-ServiceGuid -Name SubscriptionId -Value $Item.SubscriptionId
            $Key = "$($Item.SubscriptionId)|$($Item."Trg${Platform}ResourceGroup")|$($Item."Trg$Platform")|$($Item.TrgDatabaseName)"
            if ($Targets.ContainsKey($Key)) { throw "Duplicate target database configuration: $Key" }
            $Targets[$Key] = $true
        }
        Assert-MigrationTimestampOptions -TimestampPattern $Options.TimestampPattern -TimestampFormat $Options.TimestampFormat
        Assert-DMSBlobIdentityOptions -BlobAuthType $Options.BlobAuthType -BlobIdentityType $Options.BlobIdentityType -BlobUserAssignedIdentity $Options.BlobUserAssignedIdentity
        Import-Module Az.Accounts, Az.Storage, Az.Resources, Az.DataMigration -ErrorAction Stop
        if ($Platform -eq 'SQLVM') { Import-Module Az.SqlVirtualMachine -ErrorAction Stop }
        if (-not (Get-AzContext -ErrorAction Stop)) { throw 'Authenticate with Connect-AzAccount before restore preflight.' }
        $Command = if ($Platform -eq 'SQLMI') { 'New-AzDataMigrationToSqlManagedInstance' } else { 'New-AzDataMigrationToSqlVM' }
        Assert-DMSAuthenticationSupport -CommandName $Command -BlobAuthType $Options.BlobAuthType -BlobIdentityType $Options.BlobIdentityType
        foreach ($Item in $Items) {
            $null = Set-AzContext -SubscriptionId $Item.SubscriptionId -Scope Process -WhatIf:$false -Confirm:$false -ErrorAction Stop
            $StorageId = "/subscriptions/$($Item.SubscriptionId)/resourceGroups/$($Item.BackupStorageResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($Item.BackupStorageAccount)"
            $Storage = Get-AzResource -ResourceId $StorageId -ExpandProperties -ErrorAction Stop
            if ($Options.BlobAuthType -eq 'AccountKey' -and $Storage.Properties.allowSharedKeyAccess -eq $false) {
                throw "Shared-key access is disabled on storage account '$($Item.BackupStorageAccount)'. AccountKey restore cannot proceed."
            }
            $Container = [string]$Item.BackupStorageContainerName
            if (-not $Container) { $Container = Get-ContainerName -ServerName $Item.SrcServerName -DatabaseName $Item.SrcDatabaseName }
            $Blobs = @(Assert-ServiceStorage -Account $Item.BackupStorageAccount -Container $Container)
            $Full = @($Blobs | Where-Object {
                [IO.Path]::GetExtension($_.Name) -eq '.bak' -and
                $null -ne (Get-MigrationBackupTimestamp -FileName $_.Name -TimestampPattern $Options.TimestampPattern -TimestampFormat $Options.TimestampFormat)
            })
            if (-not $Full.Count) { throw "No timestamped FULL backup found in '$Container'." }
            $Service = Get-AzDataMigrationSqlService -Name $Item.DMSServiceName -ResourceGroupName $Item.DMSResourceGroup -ErrorAction Stop
            if (-not $Service) {
                throw "DMS SQL service '$($Item.DMSServiceName)' was not returned in resource group '$($Item.DMSResourceGroup)'. Verify the service name, subscription, and access. If the service itself was deleted, recreate it before restoring; the script creates database migration records, not the DMS service."
            }
            if ($Service.Location -and $Service.Location -ne $Item.Location) { throw "Configured Location does not match DMS '$($Item.DMSServiceName)'." }
            if ($Service.ProvisioningState -and $Service.ProvisioningState -ne 'Succeeded') { throw "DMS '$($Item.DMSServiceName)' is not successfully provisioned." }
            $Provider = if ($Platform -eq 'SQLMI') { 'Microsoft.Sql/managedInstances' } else { 'Microsoft.SqlVirtualMachine/sqlVirtualMachines' }
            $TargetId = "/subscriptions/$($Item.SubscriptionId)/resourceGroups/$($Item."Trg${Platform}ResourceGroup")/providers/$Provider/$($Item."Trg$Platform")"
            $Target = Get-AzResource -ResourceId $TargetId -ExpandProperties -ErrorAction Stop
            $HostName = [string]$Item.TargetSqlHost
            Write-Host "Checking executor TCP connectivity to ${HostName}:$($Options.TargetSqlPort) ($Platform)."
            Assert-ServiceTcpEndpoint -HostName $HostName -Port $Options.TargetSqlPort
            Write-Host "Executor TCP connectivity passed for ${HostName}:$($Options.TargetSqlPort)."
            if ($Options.BlobAuthType -eq 'ManagedIdentity') {
                if ($Options.BlobIdentityType -eq 'SystemAssigned' -and -not $Target.Identity.PrincipalId) {
                    throw "System-assigned identity is not enabled on '$TargetId'."
                }
                if ($Options.BlobIdentityType -eq 'UserAssigned' -and
                    $Options.BlobUserAssignedIdentity -notin $Target.Identity.UserAssignedIdentities.Keys) {
                    throw "Configured user-assigned identity is not attached to '$TargetId'."
                }
            }
            else {
                $null = Get-DMSBlobAuthentication -BlobAuthType AccountKey `
                    -StorageAccountName $Item.BackupStorageAccount -ResourceGroupName $Item.BackupStorageResourceGroup
            }
        }
        Write-Warning 'Preflight checks executor connectivity, Blob discovery, and configured authentication. DMS-host routing, service-side Blob access, restore compatibility, and future mutation authorization must also be verified operationally.'
        if ($Options.BlobAuthType -eq 'AccountKey') {
            Write-Warning 'AccountKey preflight retrieves a storage key without printing or persisting it.'
        }
        else {
            Write-Warning 'ManagedIdentity preflight does not retrieve storage keys. Verify that the selected target identity has Storage Blob Data Reader access to the backup container and can reach storage.'
        }
    }
    else {
        if (-not $Options.SubscriptionId -or -not $Options.ResourceGroupName) { throw 'SubscriptionId and ResourceGroupName are required.' }
        foreach ($Id in $Options.SubscriptionId) { Assert-ServiceGuid -Name SubscriptionId -Value $Id }
        Import-Module Az.Accounts, Az.DataMigration -ErrorAction Stop
        if (-not (Get-AzContext -ErrorAction Stop)) { throw 'Authenticate with Connect-AzAccount before DMS preflight.' }
        $Inventory = @(Get-DMSMigrationInventory -SubscriptionId $Options.SubscriptionId -ResourceGroupName $Options.ResourceGroupName `
            -DMSServiceName $Options.DMSServiceName -TargetName $Options.TargetName -TargetType $Options.TargetType `
            -TargetResourceGroup $Options.TargetResourceGroup -Databases $Options.Databases -IncludeDetails)
        if ($Options.Mode -eq 'Cutover') {
            $null = @(Select-DMSCutoverMigration -Migrations $Inventory -Names $Options.Databases -Target $Options.TargetName)
        }
        if ($Operation -eq 'Remove') {
            $Statuses = if ($Options.IncludeReadyForCutover) { @('Succeeded', 'ReadyForCutover', 'ReadyToCutover') } else { @('Succeeded') }
            $Inventory = @($Inventory | Where-Object MigrationStatus -in $Statuses)
        }
        $Inventory | Format-Table TargetName, DatabaseName, MigrationStatus -AutoSize | Out-Host
    }
    Write-Host "Read-only preflight passed for $Operation." -ForegroundColor Green
}
