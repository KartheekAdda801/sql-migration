#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

function Test-DMSConfigurationValue {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    return $null -ne $Value -and ($Value -isnot [string] -or -not [string]::IsNullOrWhiteSpace($Value))
}

function Resolve-DMSConfigurationItems {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Configuration)

    Assert-DMSConfigurationProperties -Value $Configuration -Section root -Required @('schemaVersion', 'Common', 'Items')
    if (($Configuration.schemaVersion -isnot [long] -and $Configuration.schemaVersion -isnot [int]) -or $Configuration.schemaVersion -ne 2) {
        throw 'Item-based DMS configuration requires numeric schemaVersion 2.'
    }
    $Defaults = [ordered]@{
        Enabled = $true; Activity = 'Status'; SubscriptionId = ''; ResourceGroupName = ''; Location = ''
        SrcServerName = ''; SrcDatabaseName = ''; BackupStorageAccount = ''; BackupStorageResourceGroup = ''
        BackupStorageContainerName = ''; TargetType = ''; TargetName = ''; TargetResourceGroup = ''
        TargetSqlHost = ''; TargetSqlPort = 1433; TargetTrustServerCertificate = $false; SqlCredentialPath = ''
        SqlUserName = ''; SqlPasswordEnvironmentVariable = ''; TargetSqlAuthType = ''; SqlCredentialMode = 'Interactive'; credential = ''
        TrgDatabaseName = ''; DMSServiceName = ''; DMSResourceGroup = ''
        AutoCutover = $false; BlobAuthType = ''; BlobIdentityType = 'SystemAssigned'; BlobUserAssignedIdentity = ''
        TimestampPattern = ''; TimestampFormat = ''; MonitorIntervalSeconds = 15; CutoverTimeoutMinutes = 60
        RefreshWaitMinutes = 5; IncludeReadyForCutover = $false; Force = $false; ExportCsvPath = ''; OutputJsonPath = ''
    }
    Assert-DMSConfigurationProperties -Value $Configuration.Common -Section Common -Required @() `
        -Optional @(@($Defaults.Keys) + @('MaxConcurrentRestores', 'MaxConcurrentCutover'))
    foreach ($Limit in @('MaxConcurrentRestores', 'MaxConcurrentCutover')) {
        $Value = $Configuration.Common.$Limit
        if (-not (Test-DMSConfigurationValue $Value)) { throw "Common.$Limit is required and is a global limit." }
        $Maximum = if ($Limit -eq 'MaxConcurrentRestores') { 10 } else { 20 }
        if (($Value -isnot [long] -and $Value -isnot [int]) -or $Value -lt 1 -or $Value -gt $Maximum) {
            throw "Common.$Limit must be an integer from 1 to $Maximum."
        }
    }
    if ($Configuration.Items -isnot [array] -or -not $Configuration.Items.Count) { throw 'Items must be a nonempty JSON array.' }
    $SeenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $SeenTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $Index = 0
    foreach ($Source in $Configuration.Items) {
        $Index++
        Assert-DMSConfigurationProperties -Value $Source -Section "Items[$Index]" -Required @('Id') -Optional @($Defaults.Keys)
        if ($Source.Id -isnot [string] -or [string]::IsNullOrWhiteSpace($Source.Id) -or -not $SeenIds.Add($Source.Id)) {
            throw "Items[$Index].Id must be a nonempty unique string."
        }
        $Values = [ordered]@{ Id = $Source.Id }
        foreach ($Name in $Defaults.Keys) {
            $Values[$Name] = $Defaults[$Name]
            foreach ($Level in @($Configuration.Common, $Source)) {
                if (Test-DMSConfigurationValue $Level.$Name) { $Values[$Name] = $Level.$Name }
            }
        }
        foreach ($Name in $Defaults.Keys) {
            $Value = $Values[$Name]
            if ($Defaults[$Name] -is [bool]) {
                if ($Value -isnot [bool]) { throw "Item '$($Source.Id)': $Name must be a JSON boolean, or blank to inherit." }
            }
            elseif ($Defaults[$Name] -is [int]) {
                $Maximum = switch ($Name) { TargetSqlPort { 65535 } MonitorIntervalSeconds { 3600 } CutoverTimeoutMinutes { 10080 } default { 1440 } }
                if (($Value -isnot [long] -and $Value -isnot [int]) -or $Value -lt 1 -or $Value -gt $Maximum) {
                    throw "Item '$($Source.Id)': $Name must be an integer from 1 to $Maximum, or blank to inherit."
                }
            }
            elseif ($Value -isnot [string]) { throw "Item '$($Source.Id)': $Name must be a string." }
        }
        if ($Values.TargetType -notin @('SQLVM', 'SQLMI')) { throw "Item '$($Source.Id)': TargetType must be SQLVM or SQLMI." }
        $Values.TargetType = $Values.TargetType.ToUpperInvariant()
        if (-not $Values.TargetSqlAuthType) { $Values.TargetSqlAuthType = if ($Values.TargetType -eq 'SQLMI') { 'Entra' } else { 'SqlLogin' } }
        if ($Values.TargetSqlAuthType -notin @('SqlLogin', 'Entra')) { throw "Item '$($Source.Id)': TargetSqlAuthType must be SqlLogin or Entra." }
        if ($Values.SqlCredentialMode -notin @('Interactive', 'Configured')) { throw "Item '$($Source.Id)': SqlCredentialMode must be Interactive or Configured." }
        if ($Values.Activity -notin @('Restore', 'Status', 'Monitor', 'Cutover', 'Remove')) { throw "Item '$($Source.Id)': invalid Activity '$($Values.Activity)'." }
        foreach ($Name in @('BackupStorageResourceGroup', 'TargetResourceGroup', 'DMSResourceGroup')) {
            if (-not $Values[$Name]) { $Values[$Name] = $Values.ResourceGroupName }
        }
        if (-not $Values.BlobAuthType) { $Values.BlobAuthType = if ($Values.TargetType -eq 'SQLMI') { 'ManagedIdentity' } else { 'AccountKey' } }
        if ($Values.BlobAuthType -notin @('ManagedIdentity', 'AccountKey') -or $Values.BlobIdentityType -notin @('SystemAssigned', 'UserAssigned')) {
            throw "Item '$($Source.Id)': invalid Blob authentication settings."
        }
        if ($Values.TargetType -eq 'SQLVM' -and $Values.BlobAuthType -ne 'AccountKey') { throw "Item '$($Source.Id)': SQLVM requires AccountKey." }
        if ($Values.TargetName -match '[.,:/\\]') { throw "Item '$($Source.Id)': TargetName must be an Azure resource name, not a SQL endpoint." }
        $Item = [pscustomobject]$Values
        if ($Item.Enabled) {
            Assert-ServiceFields -Items @($Item) -Required SubscriptionId, DMSServiceName, DMSResourceGroup, TargetName, TargetResourceGroup, TrgDatabaseName
            Assert-ServiceGuid -Name SubscriptionId -Value $Item.SubscriptionId
            $Key = "$($Item.SubscriptionId)|$($Item.TargetResourceGroup)|$($Item.TargetType)|$($Item.TargetName)|$($Item.TrgDatabaseName)"
            if (-not $SeenTargets.Add($Key)) { throw "Duplicate target database configuration: $Key" }
            if ($Item.Activity -eq 'Restore') {
                Assert-ServiceFields -Items @($Item) -Required SrcServerName, SrcDatabaseName, BackupStorageAccount, BackupStorageResourceGroup, Location, TargetSqlHost
            }
        }
        $Item
    }
}

function ConvertTo-DMSItemConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)

    $Settings = [ordered]@{ OutputJsonPath = $Item.OutputJsonPath }
    if ($Item.Activity -eq 'Restore') {
        $Settings.MaxConcurrentRestores = 1
        foreach ($Name in @('AutoCutover', 'BlobAuthType', 'BlobIdentityType', 'BlobUserAssignedIdentity',
            'TimestampPattern', 'TimestampFormat', 'TargetSqlPort')) { $Settings[$Name] = $Item.$Name }
        $Row = [ordered]@{}
        foreach ($Name in @('SrcServerName', 'SrcDatabaseName', 'BackupStorageAccount', 'BackupStorageContainerName',
            'BackupStorageResourceGroup', 'SubscriptionId', 'Location', 'TargetSqlHost')) { $Row[$Name] = $Item.$Name }
        $Row["Trg$($Item.TargetType)"] = $Item.TargetName
        $Row["Trg$($Item.TargetType)ResourceGroup"] = $Item.TargetResourceGroup
        $Row.TrgDatabaseName = $Item.TrgDatabaseName
        $Row.DMSServiceName = $Item.DMSServiceName
        $Row.DMSResourceGroup = $Item.DMSResourceGroup
        return [pscustomobject]@{ schemaVersion = 1; Settings = [pscustomobject]$Settings; Items = @([pscustomobject]$Row) }
    }
    $Settings.SubscriptionId = @($Item.SubscriptionId)
    $Settings.ResourceGroupName = @($Item.DMSResourceGroup)
    $Settings.DMSServiceName = @($Item.DMSServiceName)
    $Settings.TargetName = $Item.TargetName
    $Settings.TargetType = $Item.TargetType
    $Settings.TargetResourceGroup = $Item.TargetResourceGroup
    $Settings.Databases = @($Item.TrgDatabaseName)
    if ($Item.Activity -eq 'Remove') {
        $Settings.Force = $Item.Force
        $Settings.IncludeReadyForCutover = $Item.IncludeReadyForCutover
    }
    else {
        $Settings.Mode = $Item.Activity
        $Settings.MaxConcurrentCutover = 1
        foreach ($Name in @('MonitorIntervalSeconds', 'CutoverTimeoutMinutes', 'RefreshWaitMinutes', 'ExportCsvPath')) { $Settings[$Name] = $Item.$Name }
    }
    return [pscustomobject]@{ schemaVersion = 1; Settings = [pscustomobject]$Settings }
}

function Select-DMSConfigurationItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [string[]]$ItemId, [string[]]$Databases, [string]$TargetName, [string]$TargetType
    )

    $Selected = @($Items | Where-Object Enabled)
    foreach ($Filter in @(
        @{ Values = $ItemId; Property = 'Id' }, @{ Values = $Databases; Property = 'TrgDatabaseName' },
        @{ Values = @($TargetName | Where-Object { $_ }); Property = 'TargetName' },
        @{ Values = @($TargetType | Where-Object { $_ }); Property = 'TargetType' }
    )) {
        if (-not $Filter.Values.Count) { continue }
        foreach ($Value in $Filter.Values) {
            if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notin $Selected.($Filter.Property)) {
                throw "Selection '$($Filter.Property)=$Value' does not match an enabled item in the selected scope."
            }
        }
        $Selected = @($Selected | Where-Object { $_.($Filter.Property) -in $Filter.Values })
    }
    if (-not $Selected.Count) { throw 'No enabled DMS configuration items were selected.' }
    return $Selected
}
