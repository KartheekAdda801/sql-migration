#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Migrate server objects to SQL VMs and managed instances from one JSON configuration.
.DESCRIPTION
    Generates and snapshots SQL objects, executes a reviewed snapshot, or provisions
    item-specific SQL logins, Entra users/groups, and managed identities.
.PARAMETER ConfigPath
    Schema version 2 JSON with independent SQLVM/SQLMI Items.
.PARAMETER Activity
    Optional override: Generate, GenerateAndExecute, Execute,
    or ProvisionLogins. ProvisionSqlLogins remains an alias for ProvisionLogins.
.PARAMETER ItemId
    Optional item IDs to select.
.PARAMETER OutputRoot
    Local run directory. Each invocation creates a new protected subdirectory.
.PARAMETER OutputJsonPath
    Optional combined execution result JSON, also written when a child fails.
    Item preflight failures are recorded; WhatIf does not create output files.
.PARAMETER ThrottleLimit
    Maximum concurrent independent item processes. Defaults to 10; use 1 for serial execution.
.PARAMETER SqlCredentials
    Optional PSCredentials keyed by item ID, overriding configured SQL credential references.
.PARAMETER Foreground
    Run synchronously instead of launching a persistent hidden worker.
.PARAMETER RunDirectory
    Local run directory to inspect with Status or Monitor. Omit to select the latest run.
.PARAMETER MonitorIntervalSeconds
    Polling interval for Monitor; defaults to 5 seconds.
.EXAMPLE
    .\Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1 -ConfigPath ..\config\Invoke-MigrateServerObjects-ProvisionLogin-AzSql.config.json -OutputJsonPath .\results.json
.NOTES
    Mixed-platform means mixed SQL targets, not cross-platform executor support.
    Source Windows authentication and the existing platform prerequisites apply.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\Invoke-MigrateServerObjects-ProvisionLogin-AzSql.config.json'),
    [string]$OutputJsonPath,
    [ValidateSet('Generate', 'GenerateAndExecute', 'Execute', 'ProvisionLogins', 'ProvisionSqlLogins', 'Status', 'Monitor')]
    [string]$Activity,
    [string[]]$ItemId,
    [hashtable]$SqlCredentials = @{},
    [ValidateRange(1, 128)][int]$ThrottleLimit = 10,
    [switch]$Foreground,
    [string]$RunDirectory,
    [ValidateRange(1, 3600)][int]$MonitorIntervalSeconds = 5,
    [Parameter(DontShow)][string]$WorkerRequestPath,
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\output\Runs')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common\ServerObjects.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Common\ServerObjects.Configuration.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Common\ServerObjects.Authentication.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Common\ServerObjects.BlobUpload.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Common\ServerObjects.SecuritySnapshot.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Common\ServerObjects.JobSnapshot.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Common\ServerObjects.SourceSnapshot.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Common\ServerObjects.Workflow.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Common\ServerObjects.Execution.Helpers.ps1')

#region Functions
function Invoke-ServerObjectPlatform {
    [CmdletBinding()]
    param([string]$EntryPath, [string]$ConfigPath, [string]$OutputJsonPath)

    & $EntryPath -ConfigPath $ConfigPath -OutputJsonPath $OutputJsonPath -Confirm:$false
}

function Invoke-ServerObjectBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string]$ScriptsPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Results
    )

    if (-not $Rows.Count) { throw 'The migration JSON contains no Items.' }
    foreach ($Row in $Rows) {
        if (([string]$Row.TargetType).Trim() -notin @('SQLVM', 'SQLMI')) {
            throw "TargetType '$($Row.TargetType)' must be SQLVM or SQLMI."
        }
        $Row.TargetType = ([string]$Row.TargetType).Trim().ToUpperInvariant()
    }
    $TemporaryFolder = Join-Path ([IO.Path]::GetTempPath()) ("sql-object-migration-" + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($TemporaryFolder)
    $TemporaryFiles = [Collections.Generic.List[string]]::new()
    try {
        foreach ($Platform in @('SQLVM', 'SQLMI')) {
            $PlatformRows = @($Rows | Where-Object TargetType -eq $Platform)
            if (-not $PlatformRows.Count) { continue }
            $PlatformConfigPath = Join-Path $TemporaryFolder "$Platform.config.json"
            $PlatformJson = Join-Path $TemporaryFolder "$Platform.results.json"
            $TemporaryFiles.Add($PlatformConfigPath)
            $TemporaryFiles.Add($PlatformJson)
            @{ schemaVersion = 1; Settings = @{}; Items = @($PlatformRows) } |
                ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $PlatformConfigPath -Encoding utf8 -ErrorAction Stop
            $ChildError = $null
            try {
                Invoke-ServerObjectPlatform -EntryPath (Join-Path $ScriptsPath "Invoke-MigrateServerObjects-OnPrem-Az$Platform.ps1") `
                    -ConfigPath $PlatformConfigPath -OutputJsonPath $PlatformJson | Out-Host
            }
            catch { $ChildError = $_.Exception.Message }
            if (Test-Path -LiteralPath $PlatformJson) {
                try {
                    $Child = Get-Content -LiteralPath $PlatformJson -Raw | ConvertFrom-Json -ErrorAction Stop
                    if ($Child.schemaVersion -ne 1 -or $Child.status -notin @('Succeeded', 'Failed') -or
                        $null -eq $Child.results) { throw 'Invalid child result schema.' }
                    foreach ($Result in @($Child.results)) { $Results.Add($Result) }
                    if ($Child.status -eq 'Failed' -and -not $ChildError) { $ChildError = "$Platform reported a failed migration." }
                }
                catch { $ChildError = "Cannot read $Platform results: $($_.Exception.Message)" }
            }
            elseif (-not $ChildError) { $ChildError = "$Platform did not write a result JSON file." }
            if ($ChildError) {
                Write-Warning "$Platform migration failed: $ChildError"
                $Results.Add([pscustomobject]@{
                    SourceServer = ''; TargetServer = $Platform; Component = 'Platform invocation'
                    Status = 'FAILED'; Mode = 'Batch'; OutputFile = ''; ErrorMessage = $ChildError
                })
            }
        }
    }
    finally {
        foreach ($File in $TemporaryFiles) {
            if (Test-Path -LiteralPath $File) { Remove-Item -LiteralPath $File -Force -ErrorAction Stop }
        }
        Remove-Item -LiteralPath $TemporaryFolder -Force -ErrorAction Stop
    }
    if (@($Results | Where-Object Status -eq 'FAILED').Count) {
        throw 'One or more platform migrations failed. Review the combined results.'
    }
}
#endregion Functions

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    $ConfirmPreference = 'None'
    if ($WorkerRequestPath) { Invoke-ServerObjectBackgroundWorker -RequestPath $WorkerRequestPath; return }
    if ($Activity -eq 'Status') { Get-ServerObjectRunStatus -OutputRoot $OutputRoot -RunDirectory $RunDirectory -ItemId $ItemId; return }
    if ($Activity -eq 'Monitor') {
        Watch-ServerObjectRun -OutputRoot $OutputRoot -RunDirectory $RunDirectory -ItemId $ItemId -MonitorIntervalSeconds $MonitorIntervalSeconds
        return
    }
    if ($RunDirectory) { throw 'RunDirectory is only supported with Activity Status or Monitor.' }
    if ($OutputJsonPath -and ([IO.Path]::GetFullPath($OutputJsonPath) -eq [IO.Path]::GetFullPath($ConfigPath) -or
        [IO.Path]::GetFileName($OutputJsonPath) -eq 'password.local.json')) {
        throw 'OutputJsonPath cannot overwrite the configuration or local SQL credential file.'
    }
    $Rows = @(Read-ServerObjectItems -Path $ConfigPath -ItemId $ItemId -Activity $Activity)
    $ResolvedCredentials = Initialize-ServerObjectSqlCredentials -Items $Rows -ConfigPath $ConfigPath -SqlCredentials $SqlCredentials
    $Parameters = @{ Items = $Rows; ScriptsPath = $PSScriptRoot; OutputRoot = $OutputRoot
        OutputJsonPath = $OutputJsonPath; ThrottleLimit = $ThrottleLimit; SqlCredentials = $ResolvedCredentials }
    if ($Foreground -or $WhatIfPreference) { Invoke-ServerObjectWorkflow @Parameters -Preview:$WhatIfPreference }
    else { Start-ServerObjectBackgroundRun @Parameters }
}
#endregion Main Execution
