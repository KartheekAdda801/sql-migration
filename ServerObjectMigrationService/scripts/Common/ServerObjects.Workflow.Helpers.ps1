#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

#region Functions
function Invoke-ServerObjectWorker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ScriptsPath, [switch]$Execution, [pscredential]$SqlCredential)
    if ($Execution) { Invoke-ServerObjectSnapshotReplay -Item $Item -Root $Root -SqlCredential $SqlCredential }
    else { New-ServerObjectSourceSnapshot -Item $Item -Root $Root }
}

function Invoke-ServerObjectProvisioning {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ScriptsPath, [pscredential]$SqlCredential)
    $Config = Join-Path $Root 'provision.config.json'
    @{ schemaVersion = 1; Settings = @{}; Items = @(Get-ServerObjectProvisioningItems -Item $Item) } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Config -Encoding utf8 -Confirm:$false
    try {
        & (Join-Path $ScriptsPath 'Invoke-ProvisionLogins-AzSql.ps1') `
            -ConfigPath $Config -SqlPort $Item.TargetSqlPort -OutputRoot $Root `
            -ServerOnly:($Item.SQLLoginsMigrationScope -eq 'Server') `
            -TargetTrustServerCertificate $Item.TargetTrustServerCertificate `
            -TargetSqlAuthType $Item.TargetSqlAuthType -SqlCredential $SqlCredential `
            -UseWindowsAuthentication:($Item.TargetSqlAuthType -eq 'WindowsAD' -or
                ($Item.TargetSqlAuthType -eq 'Auto' -and $Item.TargetType -eq 'SQLVM')) -Confirm:$false | Out-Host
    }
    finally { Remove-Item -LiteralPath $Config -Force -Confirm:$false -ErrorAction Stop }
}

function New-ServerObjectItemPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$ScriptsPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [pscredential]$SqlCredential
    )
    $Root = Join-Path $RunRoot $Item.Id
    $SourceRoot = Join-Path $Root 'SourceObjects'
    $ProvisionRoot = Join-Path $Root 'Provisioning'
    $Snapshot = $null
    $ProvisioningError = $null
    $Configuration = @{ Items = @() }
    $Options = @{ OutputRoot = $SourceRoot }
    $Phase = 'Login provisioning preflight'
    try {
        if ($Item.ProvisionLogins -and $Item.Activity -ne 'Generate') {
            $Configuration.Items = @(Get-ServerObjectProvisioningItems -Item $Item)
            $Options.SqlPort = $Item.TargetSqlPort
            try {
                Invoke-ServerObjectPreflight -Operation 'Invoke-ProvisionLogins-AzSql' `
                    -Configuration $Configuration -Options @{ SqlPort = $Item.TargetSqlPort; OutputRoot = $ProvisionRoot
                        TargetTrustServerCertificate = $Item.TargetTrustServerCertificate
                        TargetSqlAuthType = $Item.TargetSqlAuthType; SqlCredential = $SqlCredential
                        ServerOnly = $Item.SQLLoginsMigrationScope -eq 'Server' } -ScriptsPath $ScriptsPath
            }
            catch {
                $Message = "Login provisioning validation failed: item='$($Item.Id)', target='$($Item.TargetSqlHost),$($Item.TargetSqlPort)', databases='$($Item.SourceListofDatabases)'. $($_.Exception.Message)"
                $ProvisioningError = [pscustomobject]@{ Component = 'ProvisionLogins'; Name = ''; Database = ''; Mode = $Item.Activity
                    Phase = 'Validation'; Status = 'FAILED'; OutputFile = $ProvisionRoot; ErrorMessage = $Message
                    ErrorId = $_.FullyQualifiedErrorId; ScriptStackTrace = $_.ScriptStackTrace }
            }
        }
        if ($Item.Activity -ne 'ProvisionLogins') {
            $Phase = 'Reading current SQL snapshot'
            if ($Item.Activity -eq 'Execute') {
                $Snapshot = Read-ServerObjectBlobSnapshot -Item $Item
            }
            else {
                $Phase = 'Storage preflight'
                $null = Get-ServerObjectStorage -Item $Item
            }
            $Phase = 'Source/target SQL migration preflight'
            Import-Module SqlServer -ErrorAction Stop
            if ($Item.Activity -ne 'Execute') {
                Assert-ServerObjectSqlAccess -Server (Get-ServerObjectSourceEndpoint -Item $Item) -RequireSysadmin -RequireLoginHashes `
                    -TrustServerCertificate $Item.SourceTrustServerCertificate
            }
        }
    }
    catch {
        $Message = "Item '$($Item.Id)' failed during $Phase. Activity='$($Item.Activity)'; TargetType='$($Item.TargetType)'; TargetName='$($Item.TargetName)'; TargetSqlHost='$($Item.TargetSqlHost)'; TargetSqlPort=$($Item.TargetSqlPort); ConfiguredSource='$($Item.SourceServerName)'; Databases='$($Item.SourceListofDatabases)'. $($_.Exception.Message)"
        $Exception = [InvalidOperationException]::new($Message, $_.Exception)
        $Record = [Management.Automation.ErrorRecord]::new($Exception, 'ServerObjectItemPreflightFailed', $_.CategoryInfo.Category, $Item.Id)
        $PSCmdlet.ThrowTerminatingError($Record)
    }
    [pscustomobject]@{ Item = $Item; Root = $Root; SourceRoot = $SourceRoot; ProvisionRoot = $ProvisionRoot
        Snapshot = $Snapshot; ProvisioningError = $ProvisioningError }
}

function New-ServerObjectItemResult {
    [CmdletBinding()]
    param([object]$Item, [string]$RunRoot, [string]$RunId, [string]$Status = 'SUCCESS', [string]$ErrorMessage = '')
    [pscustomobject][ordered]@{
        ItemId = $Item.Id; SourceServer = $Item.SourceServerName; TargetServer = $Item.TargetName
        Component = 'Server objects'; Mode = $Item.Activity; Status = $Status
        RunId = $RunId; OutputFile = (Join-Path $RunRoot $Item.Id); ProvisionLogins = $Item.ProvisionLogins
        BlobManifest = ''; ErrorMessage = $ErrorMessage; Components = @(); IdentityReports = @()
    }
}

function Assert-ServerObjectItemTargets {
    [CmdletBinding()]
    param([object[]]$Items, [int]$ThrottleLimit)
    if ($ThrottleLimit -gt 1) {
        $Duplicates = @($Items | Group-Object { "$($_.TargetSqlHost):$($_.TargetSqlPort)" } | Where-Object Count -gt 1)
        if ($Duplicates.Count) { throw 'Concurrent items must use distinct target SQL endpoints. Combine overlapping items or use -ThrottleLimit 1.' }
    }
    $Destinations = @($Items | Where-Object Activity -in @('Generate', 'GenerateAndExecute') |
        Group-Object { "$($_.StorageAccountName)/$($_.StorageContainer)" } | Where-Object Count -gt 1)
    if ($Destinations.Count) { throw 'Generating items must have distinct source snapshot containers. Run duplicate destinations separately.' }
}

function Invoke-ServerObjectItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$ScriptsPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$RunId,
        [pscredential]$SqlCredential,
        [switch]$Preview
    )
    $ConfirmPreference = 'None'
    $script:ActiveLogFile = $null
    $Result = New-ServerObjectItemResult -Item $Item -RunRoot $RunRoot -RunId $RunId
    try {
        $Plan = New-ServerObjectItemPlan -Item $Item -ScriptsPath $ScriptsPath -RunRoot $RunRoot -SqlCredential $SqlCredential
        if ($Preview) {
            if ($Plan.ProvisioningError) { $Result.Components += $Plan.ProvisioningError }
            elseif ($Item.ProvisionLogins -and $Item.Activity -ne 'Generate') {
                $Result.Components += [pscustomobject]@{ Component = 'ProvisionLogins'; Phase = 'Validation'
                    Status = 'PreflightPassed'; ErrorMessage = '' }
            }
            if ($Item.Activity -eq 'Execute') {
                $Result.Components += @(Invoke-ServerObjectSnapshotReplay -Item $Item -Root $Plan.SourceRoot -Snapshot $Plan.Snapshot -Preview -SqlCredential $SqlCredential)
            }
            $Failures = @($Result.Components | Where-Object Status -eq 'FAILED')
            if ($Failures.Count) { throw ($Failures.ErrorMessage -join [Environment]::NewLine) }
            return [pscustomobject]@{ ItemId = $Item.Id; Activity = $Item.Activity; Status = 'PreflightPassed'
                RunId = $null; Components = $Result.Components }
        }
        $null = [IO.Directory]::CreateDirectory($Plan.Root)
        $null = [IO.Directory]::CreateDirectory($Plan.SourceRoot)
        $script:ActiveLogFile = Join-Path $Plan.Root 'migration.log'
        Write-Host "$($Item.Id): $($Item.Activity); run $RunId."
        switch ($Item.Activity) {
            'ProvisionLogins' { }
            'Execute' {
                Save-ServerObjectBlobSnapshot -Snapshot $Plan.Snapshot -Root $Plan.SourceRoot
            }
            default {
                $Result.Components = @(Invoke-ServerObjectWorker -Item $Item -Root $Plan.SourceRoot -ScriptsPath $ScriptsPath)
                $Result.BlobManifest = Publish-ServerObjectBlobSnapshot -Item $Item -RunId $RunId -Root $Plan.SourceRoot
                if ($Item.Activity -eq 'GenerateAndExecute') {
                    # Replay the uploaded, verified bytes, not mutable local generation output.
                    $Snapshot = Read-ServerObjectBlobSnapshot -Item $Item
                    Save-ServerObjectBlobSnapshot -Snapshot $Snapshot -Root $Plan.SourceRoot
                }
            }
        }
        if ($Item.ProvisionLogins -and $Item.Activity -ne 'Generate') {
            if ($Plan.ProvisioningError) {
                $Result.Components += $Plan.ProvisioningError
                Write-Log $Plan.ProvisioningError.ErrorMessage ERROR
            }
            else {
                try {
                    $null = [IO.Directory]::CreateDirectory($Plan.ProvisionRoot)
                    Invoke-ServerObjectProvisioning -Item $Item -Root $Plan.ProvisionRoot -ScriptsPath $ScriptsPath -SqlCredential $SqlCredential
                    $Result.Components += [pscustomobject]@{ Component = 'ProvisionLogins'; Name = ''; Database = ''; Mode = $Item.Activity
                        Phase = 'Execution'; Status = 'SUCCESS'; OutputFile = $Plan.ProvisionRoot; ErrorMessage = '' }
                }
                catch {
                    $Message = "Login provisioning failed: item='$($Item.Id)', target='$($Item.TargetSqlHost),$($Item.TargetSqlPort)', databases='$($Item.SourceListofDatabases)', reports='$($Plan.ProvisionRoot)'. $($_.Exception.Message)"
                    Write-Log $Message ERROR
                    $Result.Components += [pscustomobject]@{ Component = 'ProvisionLogins'; Name = ''; Database = ''; Mode = $Item.Activity
                        Phase = 'Execution'; Status = 'FAILED'; OutputFile = $Plan.ProvisionRoot; ErrorMessage = $Message
                        ErrorId = $_.FullyQualifiedErrorId; ScriptStackTrace = $_.ScriptStackTrace }
                }
            }
        }
        if ($Item.Activity -in @('Execute', 'GenerateAndExecute')) {
            $Result.Components += @(Invoke-ServerObjectWorker -Item $Item -Root $Plan.SourceRoot -ScriptsPath $ScriptsPath -Execution -SqlCredential $SqlCredential)
        }
    }
    catch {
        $Result.Status = 'FAILED'
        $Result.ErrorMessage = $_.Exception.Message
        if (Test-Path -LiteralPath $Result.OutputFile) {
            Add-Content -LiteralPath (Join-Path $Result.OutputFile 'migration.log') -Value ("{0:o} ERROR Item='{1}' Activity='{2}' Source='{3}' Target='{4},{5}' {6}" -f
                [datetime]::UtcNow, $Item.Id, $Item.Activity, $Item.SourceServerName, $Item.TargetSqlHost, $Item.TargetSqlPort, $_.Exception.Message)
        }
    }
    $Result.IdentityReports = @(
        foreach ($Name in @('MissingEntraIdentities.csv', 'MissingEntraIdentities.Replay.csv')) {
            $Path = Join-Path $Result.OutputFile $Name
            if (Test-Path -LiteralPath $Path) { $Path }
        }
    )
    $Failures = @($Result.Components | Where-Object Status -eq 'FAILED')
    if ($Failures.Count) {
        $Result.Status = 'FAILED'
        $Result.ErrorMessage = @(@($Result.ErrorMessage | Where-Object { $_ }) + @($Failures.ErrorMessage) | Select-Object -Unique) -join [Environment]::NewLine
    }
    if (-not $Preview -and (Test-Path -LiteralPath $Result.OutputFile)) {
        foreach ($Group in @($Result.Components | Group-Object Component)) {
            $Success = @($Group.Group | Where-Object Status -eq 'SUCCESS').Count
            $Failed = @($Group.Group | Where-Object Status -eq 'FAILED').Count
            $Skipped = @($Group.Group | Where-Object Status -eq 'SKIPPED').Count
            Write-Log "Summary item='$($Item.Id)', component='$($Group.Name)': SUCCESS=$Success; FAILED=$Failed; SKIPPED=$Skipped. Object and validation details are in results.json." INFO
        }
    }
    [pscustomobject]$Result
}

function Export-ServerObjectAzureContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Import-Module Az.Accounts -ErrorAction Stop
    if (-not (Get-AzContext -ErrorAction Stop)) { throw 'Authenticate with Connect-AzAccount before starting concurrent items.' }
    # The protected run directory holds only a temporary profile, never a credential export.
    Save-AzContext -Path $Path -Force -Confirm:$false -WhatIf:$false -ErrorAction Stop | Out-Null
    $Path
}

function Start-ServerObjectItemJob {
    [CmdletBinding()]
    param([object]$Item, [string]$ScriptsPath, [string]$RunRoot, [string]$RunId, [string]$ContextPath, [pscredential]$SqlCredential)
    Start-Job -ScriptBlock {
        param($Item, $ScriptsPath, $RunRoot, $RunId, $ContextPath, $SqlCredential)
        $ErrorActionPreference = 'Stop'
        $ConfirmPreference = 'None'
        if ($ContextPath) {
            Import-Module Az.Accounts -ErrorAction Stop
            Disable-AzContextAutosave -Scope Process | Out-Null
            Import-AzContext -Path $ContextPath -Scope Process -Confirm:$false -WhatIf:$false -ErrorAction Stop | Out-Null
        }
        . (Join-Path $ScriptsPath 'Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1')
        Invoke-ServerObjectItem -Item $Item -ScriptsPath $ScriptsPath -RunRoot $RunRoot -RunId $RunId -SqlCredential $SqlCredential
    } -ArgumentList $Item, $ScriptsPath, $RunRoot, $RunId, $ContextPath, $SqlCredential -ErrorAction Stop
}

function Invoke-ServerObjectWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][string]$ScriptsPath,
        [Parameter(Mandatory)][string]$OutputRoot,
        [string]$OutputJsonPath,
        [ValidateRange(1, 128)][int]$ThrottleLimit = 10,
        [string]$RunId = (New-ServerObjectRunId),
        [switch]$PreparedRunDirectory,
        [hashtable]$SqlCredentials = @{},
        [switch]$Preview
    )
    $ConfirmPreference = 'None'
    Assert-ServerObjectItemTargets -Items $Items -ThrottleLimit $ThrottleLimit
    $OutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
    $ScriptsPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ScriptsPath)
    if ($OutputJsonPath) { $OutputJsonPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputJsonPath) }
    $RunRoot = Join-Path $OutputRoot $RunId
    Assert-ServiceOutputPath -Path (Join-Path $RunRoot '.preflight')
    if ($OutputJsonPath) { Assert-ServiceOutputPath -Path $OutputJsonPath }
    $Started = [datetime]::UtcNow
    $ReportPath = Join-Path $RunRoot 'results.json'
    $Results = [ordered]@{}
    foreach ($Item in $Items) { $Results[$Item.Id] = New-ServerObjectItemResult -Item $Item -RunRoot $RunRoot -RunId $RunId -Status Pending }
    $Active = [Collections.Generic.List[object]]::new()
    $ContextPath = $null
    $FinishedNormally = $false
    $HandledFailure = $false
    try {
        if (-not $Preview) {
            if (-not $PreparedRunDirectory) { $null = New-ServerObjectRunDirectory -Path $RunRoot }
            Write-ServerObjectRunState -Directory $RunRoot -Status Running
            Write-ServerObjectJsonResult -Path $ReportPath -Started $Started -Results @($Results.Values) -Running
            if ($Items.Count -gt 1 -and $ThrottleLimit -gt 1) {
                $ContextPath = Join-Path $RunRoot 'azure.context.json'
                $ContextPath = Export-ServerObjectAzureContext -Path $ContextPath
            }
        }
        $Next = 0
        while ($Next -lt $Items.Count -or $Active.Count) {
            while ($Next -lt $Items.Count -and $Active.Count -lt $ThrottleLimit) {
                $Item = $Items[$Next++]
                $Results[$Item.Id].Status = 'Running'
                if (-not $Preview) {
                    Write-ServerObjectJsonResult -Path $ReportPath -Started $Started -Results @($Results.Values) -Running
                    if ($OutputJsonPath) { Write-ServerObjectJsonResult -Path $OutputJsonPath -Started $Started -Results @($Results.Values) -Running }
                }
                if ($Preview -or $ThrottleLimit -eq 1 -or $Items.Count -eq 1) {
                    $Results[$Item.Id] = Invoke-ServerObjectItem -Item $Item -ScriptsPath $ScriptsPath -RunRoot $RunRoot -RunId $RunId -Preview:$Preview -SqlCredential $SqlCredentials[$Item.Id]
                    break
                }
                try {
                    $Job = Start-ServerObjectItemJob -Item $Item -ScriptsPath $ScriptsPath -RunRoot $RunRoot -RunId $RunId -ContextPath $ContextPath -SqlCredential $SqlCredentials[$Item.Id]
                    $Active.Add([pscustomobject]@{ Job = $Job; Item = $Item })
                }
                catch {
                    $Results[$Item.Id] = New-ServerObjectItemResult -Item $Item -RunRoot $RunRoot -RunId $RunId -Status FAILED -ErrorMessage $_.Exception.Message
                }
            }
            if ($Active.Count) {
                $Finished = Wait-Job -Job @($Active | ForEach-Object { $_.Job }) -Any
                $Entry = @($Active | Where-Object { $_.Job.Id -eq $Finished.Id })[0]
                try {
                    $Output = @(Receive-Job -Job $Finished -ErrorAction Stop)
                    if ($Finished.State -ne 'Completed' -or $Output.Count -ne 1 -or
                        $Output[0].ItemId -ne $Entry.Item.Id -or $Output[0].Status -notin @('SUCCESS', 'FAILED')) {
                        throw "Item process '$($Entry.Item.Id)' did not return a valid result."
                    }
                    $Results[$Entry.Item.Id] = $Output[0]
                }
                catch {
                    $Results[$Entry.Item.Id] = New-ServerObjectItemResult -Item $Entry.Item -RunRoot $RunRoot -RunId $RunId -Status FAILED -ErrorMessage $_.Exception.Message
                }
                finally {
                    Remove-Job -Job $Finished -Force -ErrorAction Stop
                    $null = $Active.Remove($Entry)
                }
            }
            if (-not $Preview) {
                $Failed = @($Results.Values | Where-Object Status -eq 'FAILED').Count
                $Running = @($Results.Values | Where-Object Status -in @('SUCCESS', 'FAILED')).Count -lt $Items.Count
                $Ordered = @($Results.Values)
                Write-ServerObjectJsonResult -Path $ReportPath -Started $Started -Results $Ordered -RunCompleted:($Failed -eq 0) -Running:$Running
                if ($OutputJsonPath) {
                    Write-ServerObjectJsonResult -Path $OutputJsonPath -Started $Started -Results $Ordered -RunCompleted:($Failed -eq 0) -Running:$Running
                }
            }
            $FinishedNormally = $true
        }
    }
    catch {
        if (-not $Preview -and (Test-Path -LiteralPath $RunRoot)) {
            $HandledFailure = $true
            Write-ServerObjectRunState -Directory $RunRoot -Status Failed -ErrorMessage $_.Exception.Message
            Write-ServerObjectJsonResult -Path $ReportPath -Started $Started -Results @($Results.Values) -RunCompleted $false -ErrorMessage $_.Exception.Message
            if ($OutputJsonPath) {
                Write-ServerObjectJsonResult -Path $OutputJsonPath -Started $Started -Results @($Results.Values) -RunCompleted $false -ErrorMessage $_.Exception.Message
            }
        }
        throw
    }
    finally {
        foreach ($Entry in $Active) {
            Stop-Job -Job $Entry.Job -ErrorAction Stop
            Remove-Job -Job $Entry.Job -Force -ErrorAction Stop
        }
        if ($ContextPath -and (Test-Path -LiteralPath $ContextPath)) { Remove-Item -LiteralPath $ContextPath -Force -Confirm:$false -ErrorAction Stop }
        if (-not $Preview -and -not $FinishedNormally -and -not $HandledFailure -and (Test-Path -LiteralPath $RunRoot)) {
            Write-ServerObjectRunState -Directory $RunRoot -Status Failed -ErrorMessage 'Execution interrupted. Verify target SQL state before retrying; completed changes are not rolled back.'
        }
    }
    $Failures = @($Results.Values | Where-Object Status -eq 'FAILED')
    if (-not $Preview) {
        Write-ServerObjectRunState -Directory $RunRoot -Status $(if ($Failures.Count) { 'Failed' } else { 'Succeeded' }) `
            -ErrorMessage (($Failures | ForEach-Object { $_.ErrorMessage }) -join "`n")
    }
    foreach ($Result in $Results.Values) {
        if ($Result.Status -eq 'FAILED') { Write-Warning "$($Result.ItemId) failed: $($Result.ErrorMessage)" }
    }
    $Results.Values
    if (-not $Preview) { Write-Host "Results: $ReportPath" }
    if ($Failures.Count) {
        $Details = ($Failures | ForEach-Object { $_.ErrorMessage }) -join "`n"
        throw "One or more server-object items failed. $Details$(if (-not $Preview) { " Review $ReportPath." })"
    }
}
#endregion Functions
