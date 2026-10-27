#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Shared timestamp, authentication, reporting, and DMS operations helpers.
.DESCRIPTION
    Dot-source this file from a DataMigrationService entry point.
.EXAMPLE
    . (Join-Path $PSScriptRoot 'Common\Migration.Helpers.ps1')
.NOTES
    Loading helpers does not authenticate or contact Azure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

#region Functions
function Assert-MigrationTimestampOptions {
    [CmdletBinding()]
    param([string]$TimestampPattern, [string]$TimestampFormat)

    if ([string]::IsNullOrWhiteSpace($TimestampPattern) -ne [string]::IsNullOrWhiteSpace($TimestampFormat)) {
        throw 'TimestampPattern and TimestampFormat must be supplied together.'
    }
    if (-not [string]::IsNullOrWhiteSpace($TimestampPattern)) {
        $Regex = [regex]::new($TimestampPattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [timespan]::FromSeconds(2))
        if ('ts' -notin $Regex.GetGroupNames()) { throw "TimestampPattern must contain a named group 'ts'." }
        $null = [datetime]::UtcNow.ToString($TimestampFormat, [Globalization.CultureInfo]::InvariantCulture)
    }
}

function Get-MigrationBackupTimestamp {
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string]$TimestampPattern,
        [string]$TimestampFormat
    )

    Assert-MigrationTimestampOptions -TimestampPattern $TimestampPattern -TimestampFormat $TimestampFormat
    $Formats = @(
        @{ Pattern = '(?<ts>\d{8}_\d{6})'; Format = 'yyyyMMdd_HHmmss' },
        @{ Pattern = '(?<ts>\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})'; Format = 'yyyy-MM-dd_HH-mm-ss' },
        @{ Pattern = '(?<ts>\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})'; Format = 'yyyy-MM-ddTHH-mm-ss' },
        @{ Pattern = '(?<ts>\d{14})'; Format = 'yyyyMMddHHmmss' },
        @{ Pattern = '_backup_(?<ts>\d{4}_\d{1,2}_\d{1,2})(?=\.)'; Format = 'yyyy_M_d' }
    )
    if ($TimestampPattern) { $Formats = @(@{ Pattern = $TimestampPattern; Format = $TimestampFormat }) }
    foreach ($Candidate in $Formats) {
        $Regex = [regex]::new($Candidate.Pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant, [timespan]::FromSeconds(2))
        $MatchesFound = $Regex.Matches($FileName)
        if ($MatchesFound.Count -eq 0) { continue }
        $Parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact(
                $MatchesFound[$MatchesFound.Count - 1].Groups['ts'].Value,
                $Candidate.Format, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
            return $Parsed
        }
    }
}

function Assert-DMSBlobIdentityOptions {
    [CmdletBinding()]
    param(
        [string]$BlobAuthType = 'AccountKey',
        [string]$BlobIdentityType = 'SystemAssigned',
        [string]$BlobUserAssignedIdentity
    )

    if ($BlobAuthType -eq 'AccountKey') {
        if ($BlobIdentityType -ne 'SystemAssigned' -or $BlobUserAssignedIdentity) {
            throw 'AccountKey authentication cannot be combined with managed identity options.'
        }
        return
    }
    if ($BlobIdentityType -eq 'UserAssigned') {
        if ($BlobUserAssignedIdentity -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$') {
            throw 'BlobUserAssignedIdentity must be the resource ID of a user-assigned identity attached to the target.'
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($BlobUserAssignedIdentity)) {
        throw 'BlobUserAssignedIdentity requires BlobIdentityType UserAssigned.'
    }
}

function Assert-DMSAuthenticationSupport {
    [CmdletBinding()]
    param([string]$CommandName, [string]$BlobAuthType, [string]$BlobIdentityType)

    $Command = Get-Command -Name $CommandName -ErrorAction Stop
    $Required = if ($BlobAuthType -eq 'AccountKey') { @('AzureBlobAccountKey') }
        elseif ($BlobIdentityType -eq 'UserAssigned') { @('AzureBlobAuthType', 'AzureBlobIdentityType', 'AzureBlobUserAssignedIdentity') }
        else { @('AzureBlobAuthType', 'AzureBlobIdentityType') }
    foreach ($Name in $Required) {
        if (-not $Command.Parameters.ContainsKey($Name)) {
            throw "Installed Az.DataMigration command '$CommandName' does not support '$Name' required for BlobAuthType '$BlobAuthType'. This authentication mode is blocked with the installed command; updating the module does not guarantee support. No authentication fallback was applied. See Prerequisites\README.md."
        }
    }
}

function Get-DMSBlobAuthentication {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [ValidateSet('ManagedIdentity', 'AccountKey')][string]$BlobAuthType = 'AccountKey',
        [ValidateSet('SystemAssigned', 'UserAssigned')][string]$BlobIdentityType = 'SystemAssigned',
        [string]$BlobUserAssignedIdentity,
        [Parameter(Mandatory)][string]$StorageAccountName,
        [Parameter(Mandatory)][string]$ResourceGroupName
    )

    Assert-DMSBlobIdentityOptions -BlobAuthType $BlobAuthType -BlobIdentityType $BlobIdentityType -BlobUserAssignedIdentity $BlobUserAssignedIdentity
    if ($BlobAuthType -eq 'AccountKey') {
        $Keys = @(Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop)
        if ($Keys.Count -eq 0 -or [string]::IsNullOrWhiteSpace($Keys[0].Value)) { throw "No account key returned for '$StorageAccountName'." }
        return @{ AzureBlobAccountKey = $Keys[0].Value }
    }
    $Parameters = @{ AzureBlobAuthType = 'ManagedIdentity'; AzureBlobIdentityType = $BlobIdentityType }
    if ($BlobIdentityType -eq 'UserAssigned') {
        $Parameters.AzureBlobUserAssignedIdentity = $BlobUserAssignedIdentity
    }
    return $Parameters
}

function Write-MigrationJsonResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$Result
    )

    $FullPath = [IO.Path]::GetFullPath($Path)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($FullPath))
    $Json = ConvertTo-Json -InputObject $Result -Depth 20
    [IO.File]::WriteAllText($FullPath, $Json, [Text.UTF8Encoding]::new($false))
}

function ConvertFrom-DMSMigrationId {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Id)

    if ($Id -notmatch '^/subscriptions/(?<Sub>[^/]+)/resourceGroups/(?<Group>[^/]+)/providers/[^/]+/[^/]+/(?<Target>[^/]+)/providers/Microsoft\.DataMigration/databaseMigrations/(?<Database>[^/]+)$') {
        throw "Unrecognized DMS migration resource ID: $Id"
    }
    return @{
        SubscriptionId = $Matches.Sub
        ResourceGroup = $Matches.Group
        TargetName = [uri]::UnescapeDataString($Matches.Target)
        DatabaseName = [uri]::UnescapeDataString($Matches.Database)
    }
}

function Get-DMSMigrationDetail {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Migration)

    $Parameters = @{
        SubscriptionId = $Migration.SubscriptionId
        ResourceGroupName = $Migration.ResourceGroup
        TargetDbName = $Migration.DatabaseName
        Expand = 'MigrationStatusDetails'
        ErrorAction = 'Stop'
    }
    if ($Migration.Kind -eq 'SqlMi') {
        Get-AzDataMigrationToSqlManagedInstance @Parameters -ManagedInstanceName $Migration.TargetName
    }
    elseif ($Migration.Kind -eq 'SqlVm') {
        Get-AzDataMigrationToSqlVM @Parameters -SqlVirtualMachineName $Migration.TargetName
    }
    else { throw "Unsupported migration kind '$($Migration.Kind)'." }
}

function Get-DMSLatestRestoredBackup {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][object]$Detail)

    $Result = @{ LatestFile = $null; RestoredAt = $null; TimestampSource = $null }
    if ($null -eq $Detail) { return $Result }
    $StatusDetail = if ($Detail.MigrationStatusDetail) { $Detail.MigrationStatusDetail } else { $Detail.MigrationStatusDetails }
    foreach ($Candidate in @($StatusDetail, $Detail)) {
        if ($null -eq $Candidate) { continue }
        foreach ($Property in @('LastRestoredFilename', 'LastRestoredFile', 'LastRestoredFileName')) {
            if (-not $Result.LatestFile -and $Candidate.$Property) { $Result.LatestFile = [string]$Candidate.$Property }
        }
        foreach ($Property in @('ActiveBackupLastRestoredTime', 'LastRestoredTime', 'LastBackupRestoredTime', 'LastRestoredBackupSetInfoBackupFinishDate')) {
            if (-not $Result.RestoredAt -and $Candidate.$Property) {
                $Result.RestoredAt = $Candidate.$Property
                $Result.TimestampSource = 'DMS'
            }
        }
    }
    if (-not $Result.RestoredAt -and $Result.LatestFile) {
        $Result.RestoredAt = Get-MigrationBackupTimestamp -FileName $Result.LatestFile
        if ($Result.RestoredAt) { $Result.TimestampSource = 'Filename' }
    }
    return $Result
}

function Select-DMSCutoverMigration {
    [CmdletBinding()]
    param([object[]]$Migrations, [string[]]$Names, [string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target) -or -not $Names -or @($Names | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) {
        throw 'Cutover requires TargetName and a nonempty Databases list.'
    }
    foreach ($Name in ($Names | Select-Object -Unique)) {
        $MatchesFound = @($Migrations | Where-Object { $_.DatabaseName -ieq $Name -and $_.TargetName -ieq $Target })
        if ($MatchesFound.Count -ne 1) {
            throw "Database '$Name' matched $($MatchesFound.Count) migrations. Narrow SubscriptionId, TargetType, or DMSServiceName to select exactly one."
        }
        if ($MatchesFound[0].MigrationStatus -notin @('ReadyForCutover', 'ReadyToCutover')) {
            throw "Database '$Name' is not ready for cutover (status '$($MatchesFound[0].MigrationStatus)')."
        }
        $MatchesFound[0]
    }
}

function Get-DMSConfiguredSqlService {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)

    # Listing distinguishes an absent service from failed resource-group access without suppressing errors.
    $Services = @(Get-AzDataMigrationSqlService -ResourceGroupName $Item.DMSResourceGroup `
        -SubscriptionId $Item.SubscriptionId -ErrorAction Stop |
        Where-Object { $_.Name -ieq $Item.DMSServiceName })
    if ($Services.Count -gt 1) { throw "Multiple DMS SQL services matched '$($Item.DMSServiceName)'." }
    if ($Services.Count) { return $Services[0] }
}

function Assert-DMSConfiguredSqlService {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][object]$Service)

    if ($Service.Location -and $Service.Location -ine $Item.Location) {
        throw "Configured Location does not match DMS '$($Item.DMSServiceName)'."
    }
    if ($Service.ProvisioningState -and $Service.ProvisioningState -ne 'Succeeded') {
        throw "DMS '$($Item.DMSServiceName)' is not successfully provisioned."
    }
}

function Get-DMSMigrationInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$SubscriptionId,
        [Parameter(Mandatory)][string[]]$ResourceGroupName,
        [string[]]$DMSServiceName,
        [string]$TargetName,
        [string]$TargetResourceGroup,
        [string[]]$Databases,
        [ValidateSet('SqlMI', 'SqlVM', 'Both')][string]$TargetType = 'Both',
        [switch]$IncludeDetails
    )

    $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Subscription in $SubscriptionId) {
        $ParsedSubscription = [guid]::Empty
        if (-not [guid]::TryParse($Subscription, [ref]$ParsedSubscription) -or $ParsedSubscription -eq [guid]::Empty) {
            throw "Invalid SubscriptionId '$Subscription'."
        }
        $null = Set-AzContext -SubscriptionId $Subscription -Scope Process -WhatIf:$false -Confirm:$false -ErrorAction Stop
        foreach ($Group in $ResourceGroupName) {
            if ([string]::IsNullOrWhiteSpace($Group)) { throw 'ResourceGroupName cannot contain empty values.' }
            $Services = @(Get-AzDataMigrationSqlService -ResourceGroupName $Group -SubscriptionId $Subscription -ErrorAction Stop)
            foreach ($Service in $Services) {
                if ($DMSServiceName -and $Service.Name -notin $DMSServiceName) { continue }
                $Migrations = @(Get-AzDataMigrationSqlServiceMigration -ResourceGroupName $Group -SqlMigrationServiceName $Service.Name -SubscriptionId $Subscription -ErrorAction Stop)
                foreach ($Migration in $Migrations) {
                    $Kind = [string]$Migration.Kind
                    if ($Kind -notin @('SqlMi', 'SqlVm')) { continue }
                    if ($TargetType -ne 'Both' -and $Kind -ine $TargetType) { continue }
                    $Parsed = ConvertFrom-DMSMigrationId -Id $Migration.Id
                    if ($TargetName -and $Parsed.TargetName -ine $TargetName) { continue }
                    if ($TargetResourceGroup -and $Parsed.ResourceGroup -ine $TargetResourceGroup) { continue }
                    if ($Databases -and $Parsed.DatabaseName -notin $Databases) { continue }
                    if (-not $Seen.Add($Migration.Id)) { continue }
                    $Item = [pscustomobject]@{
                        Id = $Migration.Id
                        SubscriptionId = $Parsed.SubscriptionId
                        ResourceGroup = $Parsed.ResourceGroup
                        TargetName = $Parsed.TargetName
                        DatabaseName = $Parsed.DatabaseName
                        Kind = $Kind
                        DMSService = $Service.Name
                        MigrationStatus = $Migration.MigrationStatus
                        LatestFile = $null
                        RestoredAt = $null
                        TimestampSource = $null
                    }
                    if ($IncludeDetails) {
                        $Detail = Get-DMSMigrationDetail -Migration $Item
                        if ($null -eq $Detail) { throw "No migration details returned for '$($Item.Id)'." }
                        $Item.MigrationStatus = $Detail.MigrationStatus
                        $Backup = Get-DMSLatestRestoredBackup -Detail $Detail
                        $Item.LatestFile = $Backup.LatestFile
                        $Item.RestoredAt = $Backup.RestoredAt
                        $Item.TimestampSource = $Backup.TimestampSource
                    }
                    $Item
                }
            }
        }
    }
}

function Invoke-DMSRollingCutover {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Migrations,
        [ValidateRange(1, 20)][int]$MaxConcurrentCutover = 5,
        [ValidateRange(1, 3600)][int]$MonitorIntervalSeconds = 15,
        [ValidateRange(1, 10080)][int]$CutoverTimeoutMinutes = 60,
        [hashtable]$ItemOptions = @{}
    )

    $ConfirmPreference = 'None'
    $Queue = [Collections.Generic.Queue[object]]::new()
    foreach ($Migration in $Migrations) { $Queue.Enqueue($Migration) }
    $Active = @{}
    $Results = [Collections.Generic.List[object]]::new()
    while ($Queue.Count -gt 0 -or $Active.Count -gt 0) {
        while ($Queue.Count -gt 0 -and $Active.Count -lt $MaxConcurrentCutover) {
            $Migration = $Queue.Dequeue()
            $Result = [pscustomobject]@{ Id = $Migration.Id; Target = $Migration.TargetName; Database = $Migration.DatabaseName; Status = 'Pending'; Error = $null }
            $Results.Add($Result)
            if ($WhatIfPreference) {
                $null = $PSCmdlet.ShouldProcess($Migration.Id, 'Cut over online database migration')
                $Result.Status = if ($WhatIfPreference) { 'WhatIf' } else { 'Declined' }
                continue
            }
            try {
                $null = Set-AzContext -SubscriptionId $Migration.SubscriptionId -Scope Process -WhatIf:$false -Confirm:$false -ErrorAction Stop
                $Detail = Get-DMSMigrationDetail -Migration $Migration
                if ($Detail.MigrationStatus -notin @('ReadyForCutover', 'ReadyToCutover')) {
                    throw "Migration is not ready for cutover (status '$($Detail.MigrationStatus)')."
                }
                if (-not $Detail.MigrationOperationId) { throw 'MigrationOperationId is missing.' }
                $Parameters = @{
                    SubscriptionId = $Migration.SubscriptionId
                    ResourceGroupName = $Migration.ResourceGroup
                    TargetDbName = $Migration.DatabaseName
                    MigrationOperationId = $Detail.MigrationOperationId
                    ErrorAction = 'Stop'
                }
                if ($Migration.Kind -eq 'SqlMi') {
                    $null = Invoke-AzDataMigrationCutoverToSqlManagedInstance @Parameters -ManagedInstanceName $Migration.TargetName
                }
                elseif ($Migration.Kind -eq 'SqlVm') {
                    $null = Invoke-AzDataMigrationCutoverToSqlVM @Parameters -SqlVirtualMachineName $Migration.TargetName
                }
                else { throw "Unsupported migration kind '$($Migration.Kind)'." }
                $Result.Status = 'Running'
                $Options = if ($ItemOptions.ContainsKey($Migration.Id)) { $ItemOptions[$Migration.Id] } else {
                    @{ MonitorIntervalSeconds = $MonitorIntervalSeconds; CutoverTimeoutMinutes = $CutoverTimeoutMinutes }
                }
                $Active[$Migration.Id] = @{ Migration = $Migration; Result = $Result; Started = Get-Date; Options = $Options; NextPoll = Get-Date }
            }
            catch {
                $Result.Status = 'Failed'
                $Result.Error = $_.Exception.Message
                Write-Warning "Cutover failed for '$($Migration.Id)': $($Result.Error)"
            }
        }
        if ($Active.Count -eq 0) { continue }
        $PollDelay = ($Active.Values | ForEach-Object { $_.Options.MonitorIntervalSeconds } | Measure-Object -Minimum).Minimum
        Start-Sleep -Seconds $PollDelay
        foreach ($Id in @($Active.Keys)) {
            $Entry = $Active[$Id]
            if ((Get-Date) -lt $Entry.NextPoll) { continue }
            $Entry.NextPoll = (Get-Date).AddSeconds($Entry.Options.MonitorIntervalSeconds)
            try {
                $null = Set-AzContext -SubscriptionId $Entry.Migration.SubscriptionId -Scope Process -WhatIf:$false -Confirm:$false -ErrorAction Stop
                $Detail = Get-DMSMigrationDetail -Migration $Entry.Migration
                if ($null -eq $Detail) { throw 'Migration status was not returned.' }
                if ($Detail.MigrationStatus -in @('Succeeded', 'Failed', 'Canceled', 'Cancelled')) {
                    $Entry.Result.Status = if ($Detail.MigrationStatus -eq 'Succeeded') { 'Succeeded' } else { 'Failed' }
                    if ($Entry.Result.Status -eq 'Failed') { $Entry.Result.Error = "DMS status: $($Detail.MigrationStatus). $($Detail.ErrorDetails)" }
                    $Active.Remove($Id)
                }
                elseif (((Get-Date) - $Entry.Started).TotalMinutes -ge $Entry.Options.CutoverTimeoutMinutes) {
                    $Entry.Result.Status = 'TimedOut'
                    $Entry.Result.Error = "Cutover monitoring timed out after $($Entry.Options.CutoverTimeoutMinutes) minutes. The Azure operation was not canceled."
                    $Active.Remove($Id)
                }
            }
            catch {
                $Entry.Result.Status = 'Failed'
                $Entry.Result.Error = $_.Exception.Message
                Write-Warning "Cutover monitoring failed for '$Id': $($Entry.Result.Error)"
                $Active.Remove($Id)
            }
        }
    }
    $Results.ToArray()
}

function Get-ContainerName {
    param([string]$ServerName, [string]$DatabaseName)

    # Accept a host or host\instance, not a SQL connection string or an empty component.
    $ServerParts = @($ServerName -split '\\')
    if ([string]::IsNullOrWhiteSpace($ServerName) -or $ServerParts.Count -gt 2 -or
        $ServerName -match '[\s/,:<>\x00-\x1f]' -or
        @($ServerParts | Where-Object { $_ -notmatch '[\p{L}\p{N}]' }).Count) {
        throw 'SrcServerName must contain a source server name, optionally followed by \instance with a nonempty instance name.'
    }
    if ([string]::IsNullOrWhiteSpace($DatabaseName) -or $DatabaseName -match '[<>\x00-\x1f]') {
        throw 'SrcDatabaseName must contain a nonempty source database name, not a placeholder or control characters.'
    }

    $containerName = ("{0}_{1}" -f $ServerName, $DatabaseName).ToLowerInvariant()
    $containerName = $containerName -replace '[^a-z0-9-]', '-'
    $containerName = $containerName -replace '-+', '-'
    $containerName = $containerName -replace '_', '-'
    $containerName = $containerName.Trim('-')

    if ($containerName.Length -lt 3) {
        $containerName = "db-$containerName"
    }

    if ($containerName.Length -gt 63) {
        $containerName = $containerName.Substring(0, 63).TrimEnd('-')
    }

    if ($containerName -notmatch '^[a-z0-9](?:[a-z0-9-]{1,61})[a-z0-9]$') {
        throw 'SrcServerName/SrcDatabaseName do not produce a valid Azure Blob container name after normalization.'
    }

    return $containerName
}

function Get-MigrationName {
    param(
        [string]$ServerName,
        [string]$DatabaseName
    )

    if ([string]::IsNullOrWhiteSpace($ServerName) -or [string]::IsNullOrWhiteSpace($DatabaseName)) {
        $rawName = "${ServerName}_${DatabaseName}"
        return ($rawName -replace "[^A-Za-z0-9_]", "")
    }

    $cleanServer   = ($ServerName   -replace "[^A-Za-z0-9_]", "")
    $cleanDatabase = ($DatabaseName -replace "[^A-Za-z0-9_]", "")

    $combined = "${cleanServer}_${cleanDatabase}"

    # Collapse multiple underscores and trim leading/trailing underscores
    $combined = $combined -replace "_+", "_"
    $combined = $combined.Trim("_")

    return $combined
}

#endregion Functions

. (Join-Path $PSScriptRoot 'Configuration.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Preflight.Helpers.ps1')
