#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

function Invoke-DMSTargetQuery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$Query, [pscredential]$SqlCredential)

    $Arguments = @{
        ServerInstance = "tcp:$($Item.TargetSqlHost),$($Item.TargetSqlPort)"
        Database = 'master'; Query = $Query; ConnectionTimeout = 15; QueryTimeout = 120
        AbortOnError = $true; DisableVariables = $true; DisableCommands = $true; ErrorAction = 'Stop'
        TrustServerCertificate = $Item.TargetTrustServerCertificate
    }
    if ($Item.TargetSqlAuthType -notin @('SqlLogin', 'Entra')) { throw "Invalid TargetSqlAuthType for '$($Item.Id)'." }
    if ($Item.TargetSqlAuthType -eq 'SqlLogin') {
        if (-not $SqlCredential) { throw "Supply a SQL credential for '$($Item.Id)' through credential, SqlCredentials, or SqlCredentialPath." }
        $Arguments.Credential = $SqlCredential
    }
    else {
        $null = Set-AzContext -SubscriptionId $Item.SubscriptionId -Scope Process -WhatIf:$false -Confirm:$false -ErrorAction Stop
        $Token = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/' -ErrorAction Stop).Token
        if ($Token -is [securestring] -and (Get-Command Invoke-Sqlcmd).Parameters['AccessToken'].ParameterType -eq [string]) {
            $Token = [Net.NetworkCredential]::new('', $Token).Password
        }
        $Arguments.AccessToken = $Token
    }
    try { Invoke-Sqlcmd @Arguments }
    catch {
        throw [InvalidOperationException]::new(
            "SQL connection/query failed for item '$($Item.Id)' at '$($Arguments.ServerInstance)' using '$($Item.TargetSqlAuthType)' authentication: $($_.Exception.Message)",
            $_.Exception)
    }
}

function Get-DMSTargetDatabase {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [pscredential]$SqlCredential)

    if ($Item.TrgDatabaseName -in @('master', 'model', 'msdb', 'tempdb')) {
        throw "System database '$($Item.TrgDatabaseName)' cannot be a restore/replacement target."
    }
    $Name = $Item.TrgDatabaseName.Replace("'", "''")
    $Rows = @(Invoke-DMSTargetQuery -Item $Item -SqlCredential $SqlCredential -Query @"
SELECT HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DATABASE') AS CanView,
       HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY DATABASE') AS CanAlter,
       d.database_id AS DatabaseId, CONVERT(nvarchar(33), d.create_date, 126) AS CreatedAt
FROM (VALUES (1)) AS n(x)
LEFT JOIN sys.databases AS d ON d.name = N'$Name';
"@)
    if ($Rows.Count -ne 1 -or $Rows[0].CanView -ne 1) {
        throw "Cannot reliably check database existence for '$($Item.Id)'; VIEW ANY DATABASE is required."
    }
    $Exists = $null -ne $Rows[0].DatabaseId -and $Rows[0].DatabaseId -isnot [DBNull]
    if ($Exists -and [int]$Rows[0].DatabaseId -le 4) { throw 'System database replacement is prohibited.' }
    [pscustomobject]@{
        Exists = $Exists; DatabaseId = $(if ($Exists) { [int]$Rows[0].DatabaseId } else { 0 })
        CreatedAt = $(if ($Exists) { [string]$Rows[0].CreatedAt } else { '' })
        CanAlter = $Rows[0].CanAlter -eq 1
    }
}

function Test-DMSInteractiveSession {
    [CmdletBinding()]
    param()

    return [Environment]::UserInteractive -and $Host.Name -ne 'ServerRemoteHost' -and
        -not @([Environment]::GetCommandLineArgs() | Where-Object { $_ -like '-noni*' }).Count
}

function Get-DMSSqlCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Item,
        [switch]$NonInteractive,
        [string]$CredentialFilePath = (Join-Path $PSScriptRoot '..\..\config\password.local.json')
    )

    if ($Item.credential) {
        $Json = Get-Content -LiteralPath $CredentialFilePath -Raw -ErrorAction Stop
        try { $Store = $Json | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Credential file '$CredentialFilePath' contains invalid JSON. Correct its syntax without adding password content to logs." }
        if ($Store -isnot [pscustomobject] -or $Store.credentials -isnot [pscustomobject]) {
            throw "Credential file '$CredentialFilePath' must contain a credentials object."
        }
        $Property = $Store.credentials.PSObject.Properties[$Item.credential]
        if (-not $Property) { throw "Credential '$($Item.credential)' for item '$($Item.Id)' was not found in '$CredentialFilePath'." }
        $Value = $Property.Value
        if ($Value -isnot [pscustomobject] -or $Value.username -isnot [string] -or [string]::IsNullOrWhiteSpace($Value.username) -or
            $Value.password -isnot [string] -or [string]::IsNullOrEmpty($Value.password)) {
            throw "Credential '$($Item.credential)' must contain nonempty username and password strings."
        }
        return [pscredential]::new($Value.username, (ConvertTo-SecureString $Value.password -AsPlainText -Force))
    }
    if ($Item.SqlCredentialMode -eq 'Interactive' -and -not $NonInteractive -and (Test-DMSInteractiveSession)) {
        $Arguments = @{ Message = "SQL login for $($Item.Id): $($Item.TargetSqlHost),$($Item.TargetSqlPort)" }
        if ($Item.SqlUserName) { $Arguments.UserName = $Item.SqlUserName }
        $Credential = Get-Credential @Arguments
        if (-not $Credential) { throw "SQL credential entry was canceled for '$($Item.Id)'. Nothing was started." }
        return $Credential
    }
    if ($Item.SqlCredentialPath) {
        $Credential = Import-Clixml -LiteralPath $Item.SqlCredentialPath -ErrorAction Stop
        if ($Credential -isnot [pscredential]) { throw "SqlCredentialPath for '$($Item.Id)' must contain a PSCredential exported by this Windows user." }
        return $Credential
    }
    if ($Item.SqlUserName -and $Item.SqlPasswordEnvironmentVariable) {
        $Password = [Environment]::GetEnvironmentVariable($Item.SqlPasswordEnvironmentVariable)
        if ([string]::IsNullOrEmpty($Password)) { throw "Password environment variable '$($Item.SqlPasswordEnvironmentVariable)' is empty or unavailable for '$($Item.Id)'." }
        return [pscredential]::new($Item.SqlUserName, (ConvertTo-SecureString $Password -AsPlainText -Force))
    }
    throw "Item '$($Item.Id)' needs interactive SQL sign-in, a named credential in password.local.json, SqlCredentials, an encrypted SqlCredentialPath, or SqlUserName plus SqlPasswordEnvironmentVariable. No background credential prompt is opened."
}

function Initialize-DMSRestorePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Plan, [hashtable]$SqlCredentials = @{},
        [switch]$Preview, [switch]$NonInteractive,
        [string]$CredentialFilePath = (Join-Path $PSScriptRoot '..\..\config\password.local.json')
    )

    $CredentialCache = @{}
    $Candidates = @(
        foreach ($Entry in @($Plan | Where-Object { $_.Item.Activity -eq 'Restore' })) {
            $Item = $Entry.Item
            if ($Item.TargetSqlAuthType -eq 'SqlLogin' -and -not $SqlCredentials.ContainsKey($Item.Id)) {
                $Key = "$($Item.TargetSqlHost)|$($Item.TargetSqlPort)|$($Item.SqlUserName)|$($Item.SqlCredentialPath)|$($Item.SqlPasswordEnvironmentVariable)|$($Item.SqlCredentialMode)|$($Item.credential)|$CredentialFilePath"
                if (-not $CredentialCache.ContainsKey($Key)) {
                    $CredentialCache[$Key] = Get-DMSSqlCredential -Item $Item -NonInteractive:$NonInteractive -CredentialFilePath $CredentialFilePath
                }
                $SqlCredentials[$Item.Id] = $CredentialCache[$Key]
            }
            if ($SqlCredentials.ContainsKey($Item.Id) -and $SqlCredentials[$Item.Id] -isnot [pscredential]) {
                throw "SqlCredentials['$($Item.Id)'] must be a PSCredential."
            }
            $Database = Get-DMSTargetDatabase -Item $Item -SqlCredential $SqlCredentials[$Item.Id]
            $Inventory = @(Get-DMSItemInventory -Item $Item)
            if ($Inventory.Count -gt 1) { throw "Multiple migrations matched '$($Item.Id)'." }
            $OperationId = ''
            if ($Inventory.Count) {
                $Detail = Get-DMSMigrationDetail -Migration $Inventory[0]
                if (-not $Detail) { throw "Cannot inspect the existing migration for '$($Item.Id)'." }
                $OperationId = [string]$Detail.MigrationOperationId
            }
            $Entry | Add-Member -NotePropertyName RestoreState -NotePropertyValue ([pscustomobject]@{
                Database = $Database; MigrationId = $(if ($Inventory.Count) { $Inventory[0].Id } else { '' })
                OperationId = $OperationId; ReplaceExisting = $false; Skip = $false
            }) -Force
            Write-Host "$($Item.Id): target database exists = $($Database.Exists); existing migration = $([bool]$Inventory.Count)."
            if ($Database.Exists -or $Inventory.Count) { $Entry }
        }
    )
    if (-not $Candidates.Count -or $Preview) { return }
    $Candidates | ForEach-Object {
        [pscustomobject]@{ ItemId = $_.Item.Id; Target = $_.Item.TargetName; Database = $_.Item.TrgDatabaseName; DatabaseExists = $_.RestoreState.Database.Exists }
    } | Format-Table -AutoSize | Out-Host
    Write-Warning 'Replacement cancels/removes the selected migration and permanently deletes its target database, disconnecting users. Back up anything you need first. Unselected items will be skipped.'
    $Answer = ''
    if (-not $NonInteractive -and (Test-DMSInteractiveSession)) {
        $Answer = Read-Host 'Enter exact item IDs to REPLACE (comma-separated), or press Enter to skip all existing targets'
    }
    else { Write-Warning 'Unattended run: existing targets are skipped because interactive replacement approval is unavailable.' }
    $Approved = @($Answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $CandidateIds = @($Candidates | ForEach-Object { $_.Item.Id })
    foreach ($Id in $Approved) {
        if ($Id -notin $CandidateIds) { throw "Replacement item '$Id' was not in the displayed existing-target list. Nothing was started." }
    }
    foreach ($Entry in $Candidates) {
        $Entry.RestoreState.ReplaceExisting = $Entry.Item.Id -in $Approved
        $Entry.RestoreState.Skip = -not $Entry.RestoreState.ReplaceExisting
        if ($Entry.RestoreState.ReplaceExisting -and $Entry.RestoreState.Database.Exists -and -not $Entry.RestoreState.Database.CanAlter) {
            throw "ALTER ANY DATABASE is required for approved replacement '$($Entry.Item.Id)'. Nothing was started."
        }
    }
}

function Assert-DMSTargetSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Entry, [pscredential]$SqlCredential)

    $Current = Get-DMSTargetDatabase -Item $Entry.Item -SqlCredential $SqlCredential
    $Expected = $Entry.RestoreState.Database
    if ($Current.Exists -ne $Expected.Exists -or $Current.DatabaseId -ne $Expected.DatabaseId -or $Current.CreatedAt -cne $Expected.CreatedAt) {
        throw "Target database changed after approval for '$($Entry.Item.Id)'. Refusing replacement; rerun preflight."
    }
}

function Reset-DMSRestoreTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Entry, [pscredential]$SqlCredential)

    if (-not $Entry.RestoreState.ReplaceExisting) { throw 'Explicit replacement approval is required.' }
    $Item = $Entry.Item
    Assert-DMSTargetSnapshot -Entry $Entry -SqlCredential $SqlCredential
    $Existing = @(Get-DMSItemInventory -Item $Item)
    if ($Existing.Count -gt 1 -or ($Existing.Count -and $Existing[0].Id -ne $Entry.RestoreState.MigrationId)) {
        throw "Migration changed after approval for '$($Item.Id)'. Refusing replacement."
    }
    $Deadline = (Get-Date).AddMinutes($Item.CutoverTimeoutMinutes)
    $Parameters = @{ ResourceGroupName = $Item.TargetResourceGroup; TargetDbName = $Item.TrgDatabaseName; SubscriptionId = $Item.SubscriptionId; ErrorAction = 'Stop'; Confirm = $false }
    if ($Item.TargetType -eq 'SQLVM') { $Parameters.SqlVirtualMachineName = $Item.TargetName }
    else { $Parameters.ManagedInstanceName = $Item.TargetName }
    if ($Existing.Count) {
        $Detail = Get-DMSMigrationDetail -Migration $Existing[0]
        if (-not $Detail -or [string]$Detail.MigrationOperationId -ne $Entry.RestoreState.OperationId) {
            throw "Migration operation changed after approval for '$($Item.Id)'. Refusing replacement."
        }
        if ($Detail.MigrationStatus -notin @('Succeeded', 'Failed', 'Canceled', 'Cancelled')) {
            if (-not $Detail.MigrationOperationId) { throw "Cannot safely cancel '$($Item.Id)': operation ID is missing." }
            Write-Host "$($Item.Id): canceling the approved existing migration."
            if ($Item.TargetType -eq 'SQLVM') { $null = Stop-AzDataMigrationToSqlVM @Parameters -MigrationOperationId $Detail.MigrationOperationId }
            else { $null = Stop-AzDataMigrationToSqlManagedInstance @Parameters -MigrationOperationId $Detail.MigrationOperationId }
            do {
                if ((Get-Date) -ge $Deadline) { throw "Cancellation timed out for '$($Item.Id)'. Database was not deleted." }
                Start-Sleep -Seconds $Item.MonitorIntervalSeconds
                $Detail = Get-DMSMigrationDetail -Migration $Existing[0]
                if (-not $Detail -or -not $Detail.MigrationStatus) { throw "Cannot verify cancellation for '$($Item.Id)'." }
                if ([string]$Detail.MigrationOperationId -ne $Entry.RestoreState.OperationId) {
                    throw "Migration operation changed after approval for '$($Item.Id)'. Refusing replacement."
                }
            } while ($Detail.MigrationStatus -notin @('Succeeded', 'Failed', 'Canceled', 'Cancelled'))
        }
        Write-Host "$($Item.Id): removing the approved migration record."
        if ($Item.TargetType -eq 'SQLVM') { $null = Remove-AzDataMigrationToSqlVM @Parameters }
        else { $null = Remove-AzDataMigrationToSqlManagedInstance @Parameters }
        while (@(Get-DMSItemInventory -Item $Item).Count) {
            if ((Get-Date) -ge $Deadline) { throw "Migration removal timed out for '$($Item.Id)'. Database was not deleted." }
            Start-Sleep -Seconds $Item.MonitorIntervalSeconds
        }
    }
    Assert-DMSTargetSnapshot -Entry $Entry -SqlCredential $SqlCredential
    if ($Entry.RestoreState.Database.Exists) {
        Write-Warning "$($Item.Id): deleting the explicitly approved target database '$($Item.TrgDatabaseName)'."
        if ($Item.TargetType -eq 'SQLMI') {
            $null = Remove-AzSqlInstanceDatabase -ResourceGroupName $Item.TargetResourceGroup -InstanceName $Item.TargetName `
                -Name $Item.TrgDatabaseName -Force -Confirm:$false -ErrorAction Stop
        }
        else {
            $Name = $Item.TrgDatabaseName.Replace(']', ']]')
            $null = Invoke-DMSTargetQuery -Item $Item -SqlCredential $SqlCredential `
                -Query "ALTER DATABASE [$Name] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Name];"
        }
        while ((Get-DMSTargetDatabase -Item $Item -SqlCredential $SqlCredential).Exists) {
            if ((Get-Date) -ge $Deadline) { throw "Database deletion timed out for '$($Item.Id)'. New migration was not submitted." }
            Start-Sleep -Seconds $Item.MonitorIntervalSeconds
        }
    }
}
