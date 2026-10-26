#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Check or install local dependencies for the active migration packages.
.DESCRIPTION
    Checks dependencies for the selected workload. With Install, installs missing
    PowerShell Gallery modules for the current user. Does not install Windows
    features, AzCopy, or PowerShell itself, authenticate, or modify Azure resources.
.PARAMETER Workload
    Select the operation to prepare, or All for every active operation.
.PARAMETER Install
    Install missing Gallery modules. Without this switch, only check dependencies.
.EXAMPLE
    .\Prerequisites\Install-MigrationPrerequisites.ps1 -Workload SqlVmRestore -Install
.EXAMPLE
    .\Prerequisites\Install-MigrationPrerequisites.ps1 -Workload All
.NOTES
    Run in PowerShell 7 under the account that will run the migration scripts.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('SqlVmRestore', 'SqlMiRestore', 'BackupUpload', 'MigrationControl',
        'ServerObjects', 'LoginProvisioning', 'SqlAuthLogins', 'All')]
    [string]$Workload = 'SqlVmRestore',

    [Parameter(Mandatory = $false)]
    [switch]$Install
)

$ErrorActionPreference = 'Stop'

#region Functions
function Invoke-MigrationPrerequisiteSetup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('SqlVmRestore', 'SqlMiRestore', 'BackupUpload', 'MigrationControl',
            'ServerObjects', 'LoginProvisioning', 'SqlAuthLogins', 'All')]
        [string]$Workload,
        [switch]$Install
    )

    if ($Workload -eq 'SqlAuthLogins') { $Workload = 'LoginProvisioning' }
    $Dependencies = @{
        SqlVmRestore = @('Az.Accounts', 'Az.DataMigration', 'Az.Storage', 'Az.Resources', 'Az.SqlVirtualMachine', 'SqlServer')
        SqlMiRestore = @('Az.Accounts', 'Az.DataMigration', 'Az.Storage', 'Az.Resources', 'Az.Sql', 'SqlServer')
        BackupUpload = @('Az.Accounts', 'Az.Storage')
        MigrationControl = @('Az.Accounts', 'Az.DataMigration')
        ServerObjects = @('SqlServer', 'Az.Accounts', 'Az.Resources', 'Az.Storage')
        LoginProvisioning = @('SqlServer', 'Az.Accounts', 'Az.KeyVault', 'Az.Resources')
    }
    $Selected = if ($Workload -eq 'All') { @($Dependencies.Keys) } else { @($Workload) }
    $Modules = @($Selected | ForEach-Object { $Dependencies[$_] } | Sort-Object -Unique)
    $Problems = [System.Collections.Generic.List[string]]::new()
    $Deferred = $false

    foreach ($Name in $Modules) {
        $Available = @(Get-Module -ListAvailable -Name $Name)
        if (-not $Available.Count) {
            if ($Name -eq 'ActiveDirectory') {
                $Problems.Add('ActiveDirectory is missing. Install Windows RSAT AD tools from an elevated terminal; see Prerequisites\README.md.')
                continue
            }
            if (-not $Install) {
                $Problems.Add("Module '$Name' is missing. Rerun with -Install to install missing Gallery modules.")
                continue
            }
            if (-not $PSCmdlet.ShouldProcess($Name, 'Install missing module from PSGallery for CurrentUser')) {
                $Deferred = $true
                continue
            }
            Install-Module -Name $Name -Repository PSGallery -Scope CurrentUser -ErrorAction Stop
        }
        Import-Module -Name $Name -ErrorAction Stop
        Write-Host "PASS module: $Name"
    }

    if ($Selected -contains 'BackupUpload') {
        $AzCopy = Get-Command azcopy -CommandType Application -ErrorAction SilentlyContinue
        if (-not $AzCopy) {
            $Problems.Add('AzCopy is missing from PATH. Install AzCopy v10+ and reopen the terminal; see Prerequisites\README.md.')
        }
        else {
            $VersionText = (& $AzCopy.Source --version 2>&1) -join ' '
            if ($LASTEXITCODE -ne 0 -or $VersionText -notmatch '\bversion\s+(\d+)\.' -or [int]$Matches[1] -lt 10) {
                $Problems.Add("AzCopy v10+ is required; version check returned: $VersionText")
            }
            else { Write-Host "PASS tool: $VersionText" }
        }
    }

    if ($Problems.Count) {
        throw ("Local prerequisites are not ready:`n - " + ($Problems -join "`n - "))
    }
    if ($Deferred) {
        Write-Warning 'Module installation was skipped. Prerequisite readiness has not been verified; rerun without -WhatIf or approve installation.'
        return
    }

    foreach ($Target in @('SqlVmRestore', 'SqlMiRestore')) {
        if ($Selected -contains $Target) {
            $CommandName = if ($Target -eq 'SqlVmRestore') { 'New-AzDataMigrationToSqlVM' } else { 'New-AzDataMigrationToSqlManagedInstance' }
            $Command = Get-Command $CommandName -ErrorAction Stop
            $AuthMode = if ($Target -eq 'SqlVmRestore') { 'AccountKey' } else { 'ManagedIdentity' }
            $RequiredParameters = @('AzureBlobContainerName', 'AzureBlobStorageAccountResourceId')
            $RequiredParameters += if ($AuthMode -eq 'AccountKey') { @('AzureBlobAccountKey') } else { @('AzureBlobAuthType', 'AzureBlobIdentityType') }
            foreach ($ParameterName in $RequiredParameters) {
                if (-not $Command.Parameters.ContainsKey($ParameterName)) {
                    throw "Installed '$CommandName' lacks '$ParameterName', required for the default $AuthMode restore flow. Install a compatible Az.DataMigration version and rerun setup. No authentication fallback was applied. See Prerequisites\README.md."
                }
            }
        }
    }
    Write-Host "Local prerequisites passed for $Workload. Azure access, SQL permissions, identities, and configuration still require migration preflight." -ForegroundColor Green
}
#endregion Functions

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-MigrationPrerequisiteSetup -Workload $Workload -Install:$Install
        exit 0
    }
    catch {
        Write-Error "Prerequisite setup failed: $($_.Exception.Message)" -ErrorAction Continue
        exit 1
    }
}
#endregion Main Execution
