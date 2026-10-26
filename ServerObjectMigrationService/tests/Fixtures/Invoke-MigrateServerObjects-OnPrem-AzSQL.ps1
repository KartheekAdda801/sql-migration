#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

[CmdletBinding()]
param([string]$WorkerRequestPath)
$FixtureRequest = $WorkerRequestPath
. (Join-Path $PSScriptRoot '..\..\scripts\Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1')

function New-ServerObjectItemPlan {
    param($Item, $ScriptsPath, $RunRoot, [pscredential]$SqlCredential)
    if ($Item.Id -eq 'preflight-failure') { throw 'SQL preflight timeout at target.example:1433' }
    $Root = Join-Path $RunRoot $Item.Id
    [pscustomobject]@{ Root = $Root; SourceRoot = Join-Path $Root SourceObjects; ProvisionRoot = Join-Path $Root Provisioning
        Snapshot = $null; ProvisioningError = $null }
}

function Invoke-ServerObjectWorker {
    param($Item, $Root, $ScriptsPath, [switch]$Execution, [pscredential]$SqlCredential)
    if ($Item.Id -eq 'runtime-failure') { throw 'Simulated SQL execution failure' }
    $Started = [datetime]::UtcNow.Ticks
    if ($Item.PSObject.Properties['CheckConcurrent'] -and $Item.CheckConcurrent) {
        $RunRoot = Split-Path -Parent (Split-Path -Parent $Root)
        [IO.File]::WriteAllText((Join-Path $RunRoot "$($Item.Id).ready"), '')
        $Deadline = [datetime]::UtcNow.AddSeconds(15)
        while (@(Get-ChildItem -LiteralPath $RunRoot -Filter '*.ready').Count -lt 2) {
            if ([datetime]::UtcNow -gt $Deadline) { throw 'Concurrent worker did not start before the barrier deadline.' }
            Start-Sleep -Milliseconds 50
        }
    }
    Start-Sleep -Milliseconds 600
    [pscustomobject]@{ Status = 'SUCCESS'; Component = 'Fixture'; Started = $Started; Finished = [datetime]::UtcNow.Ticks
        ProcessId = $PID; SourceTrustServerCertificate = $Item.SourceTrustServerCertificate
        CredentialUser = if ($SqlCredential) { $SqlCredential.UserName } else { '' } }
}

function Publish-ServerObjectBlobSnapshot { param($Item, $RunId, $Root) 'https://example/manifest.json' }
function Save-ServerObjectBlobSnapshot { param($Snapshot, $Root) }
function Export-ServerObjectAzureContext { param($Path) '' }

if ($MyInvocation.InvocationName -ne '.' -and $FixtureRequest) {
    Invoke-ServerObjectBackgroundWorker -RequestPath $FixtureRequest
}
