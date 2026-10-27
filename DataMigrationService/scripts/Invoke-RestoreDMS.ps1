#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Run item-based SQL VM and SQL MI migrations using inherited common settings.
.DESCRIPTION
    Validates all selected database items before work. Live Restore creates missing
    configured SQL migration services before submitting database migrations.
    Migration submissions run
    in batches of up to 10 independent processes. Accepted restores continue in
    Azure without blocking later batches. Execution runs in the background unless
    Foreground is supplied. Existing-target replacement requires one explicit
    approval before launch; all other execution is non-interactive.
    Confirm does not enable routine prompts. Use WhatIf to preview without mutation.
    Restore derives the backup container with the same Get-ContainerName helper as
    copy, from SrcServerName and SrcDatabaseName (never TrgDatabaseName):
    servername-databasename or servername-instancename-databasename, normalized
    to lowercase and limited to 63 characters. Restore requires that container
    to exist and contain usable backups. Container overrides are not supported;
    remove obsolete configured container fields. Containers are not renamed.
.PARAMETER ConfigPath
    JSON file with Common defaults and source-to-target Items.
.PARAMETER ItemId
    Optional exact item IDs. Omit all selectors to use every enabled item.
.PARAMETER Databases
    Optional exact target database names; combine with TargetName to disambiguate.
.PARAMETER TargetName
    Optional exact Azure target resource name.
.PARAMETER TargetType
    Optional SQLVM or SQLMI filter.
.PARAMETER Activity
    Optional explicit activity override for all selected items.
.PARAMETER Foreground
    Run synchronously in this terminal instead of launching a hidden worker.
.PARAMETER SqlCredentials
    Hashtable of exact SQL-login item IDs to PSCredential objects. Alternatively
    configure a named credential in password.local.json beside ConfigPath,
    use interactive sign-in, or configure encrypted credentials.
.PARAMETER NonInteractive
    Use configured SQL credentials without asking for login input. Existing
    targets are skipped; destructive replacement requires foreground approval.
.EXAMPLE
    .\Invoke-RestoreDMS.ps1 -Activity Status -ItemId MI-MIGRDEMO
.EXAMPLE
    .\Invoke-RestoreDMS.ps1 -Activity Restore -WhatIf
.NOTES
    WhatIf performs live preflight, without mutation or output files.
    Cutover requires a separate source-write freeze and final-log verification.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\Invoke-RestoreDMS.config.json'),
    [string[]]$ItemId,
    [string[]]$Databases,
    [string]$TargetName,
    [ValidateSet('SQLVM', 'SQLMI')][string]$TargetType,
    [ValidateSet('Restore', 'Status', 'Monitor', 'Cutover', 'Remove')][string]$Activity,
    [switch]$Foreground,
    [hashtable]$SqlCredentials = @{},
    [switch]$NonInteractive,
    [Parameter(DontShow)][string]$WorkerRequestPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common\Migration.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Common\Workflow.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Common\Target.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Common\Execution.Helpers.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    if ($WorkerRequestPath) {
        Invoke-DMSBackgroundWorker -RequestPath $WorkerRequestPath
    }
    else {
        $Parameters = @{} + $PSBoundParameters
        $Parameters.Remove('Foreground')
        $Parameters.Remove('WorkerRequestPath')
        $Parameters.Background = -not $Foreground -and -not $WhatIfPreference
        Invoke-DMSConfiguredActivity @Parameters
    }
}
