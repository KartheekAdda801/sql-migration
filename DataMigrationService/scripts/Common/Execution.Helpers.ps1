#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

function New-DMSRunDirectory {
    [CmdletBinding()]
    param([string]$RootDirectory = (Join-Path $PSScriptRoot '..\..\logs\Runs'))

    if (-not $IsWindows) { throw 'Persistent DMS execution currently requires Windows for protected credential/context handoff.' }
    $Path = Join-Path $RootDirectory ("{0}.{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N'))
    $Directory = [IO.Directory]::CreateDirectory($Path)
    $Acl = Get-Acl -LiteralPath $Directory.FullName
    $Acl.SetAccessRuleProtection($true, $false)
    $Rule = [Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $Acl.SetAccessRule($Rule)
    Set-Acl -LiteralPath $Directory.FullName -AclObject $Acl -Confirm:$false -ErrorAction Stop
    $Directory.FullName
}

function Write-DMSRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Status, [string]$ErrorMessage)

    $State = [ordered]@{ Status = $Status; ProcessId = $PID; UpdatedAt = [datetime]::UtcNow.ToString('o'); Error = $ErrorMessage }
    $Path = Join-Path $Directory 'run.json'
    $Temporary = "$Path.tmp"
    [IO.File]::WriteAllText($Temporary, ($State | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($Temporary, $Path, $true)
}

function Invoke-DMSRestoreBatch {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [hashtable]$SqlCredentials = @{},
        [Parameter(Mandatory)][string]$ContextPath,
        [Parameter(Mandatory)][object[]]$ReportPlan,
        [string]$EntryScript = (Join-Path $PSScriptRoot '..\Invoke-RestoreDMS.ps1')
    )

    $ConfirmPreference = 'None'
    if ($Plan.Count -gt 10) { throw 'A migration submission batch cannot exceed 10 items.' }
    if ($WhatIfPreference) {
        foreach ($Entry in $Plan) {
            $null = $PSCmdlet.ShouldProcess($Entry.Migration.Id, 'Submit ONLINE DMS migration')
            $Entry.Result.Status = 'WhatIf'
        }
        return
    }
    $Jobs = @()
    try {
        foreach ($Entry in $Plan) {
            if ($Entry.PSObject.Properties['RestoreState'] -and $Entry.RestoreState.Skip) {
                $Entry.Result.Status = 'SkippedExistingTarget'
                Write-DMSPlanResults -Plan $ReportPlan
                continue
            }
            $Job = Start-Job -ScriptBlock {
                param($Entry, $Credential, $ContextPath, $EntryScript)
                $ErrorActionPreference = 'Stop'
                $ConfirmPreference = 'None'
                . $EntryScript
                try {
                    Disable-AzContextAutosave -Scope Process | Out-Null
                    Import-AzContext -Path $ContextPath -Scope Process -ErrorAction Stop | Out-Null
                    $Submission = Start-DMSItemRestore -Entry $Entry -SqlCredential $Credential -Confirm:$false
                    [pscustomobject]@{ ItemId = $Entry.Item.Id; Status = $Submission.Status; Error = $null }
                }
                catch {
                    [pscustomobject]@{ ItemId = $Entry.Item.Id; Status = 'SubmissionUnverified'; Error = $_.Exception.Message }
                }
            } -ArgumentList $Entry, $SqlCredentials[$Entry.Item.Id], $ContextPath, $EntryScript -ErrorAction Stop
            $Jobs += [pscustomobject]@{ Job = $Job; Entry = $Entry }
            $Entry.Result.Status = 'Submitting'
            Write-DMSPlanResults -Plan $ReportPlan
        }
        while ($Jobs.Count) {
            $Finished = Wait-Job -Job @($Jobs | ForEach-Object { $_.Job }) -Any -ErrorAction Stop
            $Record = $Jobs | Where-Object { $_.Job.Id -eq $Finished.Id }
            $Entry = $Record.Entry
            try {
                $Output = @(Receive-Job -Job $Finished -ErrorAction Stop)
                $Results = @($Output | Where-Object { $_.PSObject.Properties['ItemId'] -and $_.ItemId -eq $Entry.Item.Id })
                if ($Finished.State -ne 'Completed' -or $Results.Count -ne 1 -or
                    $Results[0].Status -notin @('Submitted', 'SkippedExistingMigration', 'SkippedExistingTarget', 'SubmissionUnverified')) {
                    throw "Submission worker did not return one valid result for '$($Entry.Item.Id)'. Verify Azure before retrying."
                }
                $Entry.Result.Status = $Results[0].Status
                $Entry.Result.Error = $Results[0].Error
            }
            catch {
                $Entry.Result.Status = 'SubmissionUnverified'
                $Entry.Result.Error = $_.Exception.Message
            }
            if ($Entry.Result.Status -eq 'SubmissionUnverified') {
                Write-Warning "$($Entry.Item.Id): $($Entry.Result.Error). Other selected items will continue; verify this item's Azure state before retrying."
            }
            Write-DMSPlanResults -Plan $ReportPlan
            Remove-Job -Job $Finished -Confirm:$false -ErrorAction Stop
            $Jobs = @($Jobs | Where-Object { $_.Job.Id -ne $Finished.Id })
        }
    }
    finally {
        foreach ($Record in $Jobs) {
            Stop-Job -Job $Record.Job -Confirm:$false -ErrorAction Stop
            Remove-Job -Job $Record.Job -Confirm:$false -ErrorAction Stop
            $Record.Entry.Result.Status = 'SubmissionUnverified'
            $Record.Entry.Result.Error = 'Submission worker interrupted. Verify Azure state before retrying; existing Azure operations were not canceled.'
        }
        Write-DMSPlanResults -Plan $ReportPlan
    }
}

function Invoke-DMSRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][int]$MaxConcurrentRestores,
        [Parameter(Mandatory)][int]$MaxConcurrentCutover,
        [hashtable]$SqlCredentials = @{},
        [string]$ContextPath
    )

    $ConfirmPreference = 'None'
    $null = Start-Transcript -LiteralPath (Join-Path $Directory 'execution.log') -Append -ErrorAction Stop
    try {
        Write-DMSRunState -Directory $Directory -Status Running
        if (-not $ContextPath -and @($Plan | Where-Object { $_.Item.Activity -eq 'Restore' }).Count) {
            $ContextPath = Join-Path $Directory 'azure.context.json'
            $null = Save-AzContext -Path $ContextPath -Force -Confirm:$false -ErrorAction Stop
        }
        Invoke-DMSPreparedPlan -Plan $Plan -MaxConcurrentRestores $MaxConcurrentRestores `
            -MaxConcurrentCutover $MaxConcurrentCutover -SqlCredentials $SqlCredentials -ContextPath $ContextPath
        Write-DMSRunState -Directory $Directory -Status Succeeded
    }
    catch {
        Write-DMSRunState -Directory $Directory -Status Failed -ErrorMessage $_.Exception.Message
        throw
    }
    finally {
        if ($ContextPath -and (Test-Path -LiteralPath $ContextPath)) {
            Remove-Item -LiteralPath $ContextPath -Force -Confirm:$false -ErrorAction Stop
        }
        $null = Stop-Transcript -ErrorAction Stop
    }
}

function Invoke-DMSBackgroundWorker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RequestPath)

    $Directory = Split-Path -Parent $RequestPath
    try {
        $Request = Import-Clixml -LiteralPath $RequestPath -ErrorAction Stop
        Remove-Item -LiteralPath $RequestPath -Force -Confirm:$false -ErrorAction Stop
        Disable-AzContextAutosave -Scope Process | Out-Null
        Import-AzContext -Path $Request.ContextPath -Scope Process -ErrorAction Stop | Out-Null
        Invoke-DMSRun -Plan $Request.Plan -Directory $Directory -MaxConcurrentRestores $Request.MaxConcurrentRestores `
            -MaxConcurrentCutover $Request.MaxConcurrentCutover -SqlCredentials $Request.SqlCredentials -ContextPath $Request.ContextPath
    }
    catch {
        Write-DMSRunState -Directory $Directory -Status Failed -ErrorMessage $_.Exception.Message
        Write-Error $_ -ErrorAction Continue
        exit 1
    }
    finally {
        foreach ($Path in @($RequestPath, (Join-Path $Directory 'azure.context.json'))) {
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -Confirm:$false -ErrorAction Stop }
        }
    }
}

function Start-DMSBackgroundRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][int]$MaxConcurrentRestores,
        [Parameter(Mandatory)][int]$MaxConcurrentCutover,
        [hashtable]$SqlCredentials = @{},
        [string]$EntryScript = (Join-Path $PSScriptRoot '..\Invoke-RestoreDMS.ps1')
    )

    $ConfirmPreference = 'None'
    $ContextPath = Join-Path $Directory 'azure.context.json'
    $RequestPath = Join-Path $Directory 'request.clixml'
    $Process = $null
    try {
        $null = Save-AzContext -Path $ContextPath -Force -Confirm:$false -ErrorAction Stop
        @{
            Plan = $Plan; SqlCredentials = $SqlCredentials; ContextPath = $ContextPath
            MaxConcurrentRestores = $MaxConcurrentRestores; MaxConcurrentCutover = $MaxConcurrentCutover
        } | Export-Clixml -LiteralPath $RequestPath -Depth 30 -Confirm:$false -ErrorAction Stop
        $Script = (Resolve-Path -LiteralPath $EntryScript).Path.Replace("'", "''")
        $EscapedRequest = $RequestPath.Replace("'", "''")
        $Command = "& '$Script' -WorkerRequestPath '$EscapedRequest'"
        $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
        $Process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -WindowStyle Hidden -PassThru `
            -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $Encoded) `
            -RedirectStandardOutput (Join-Path $Directory 'stdout.log') -RedirectStandardError (Join-Path $Directory 'stderr.log') -ErrorAction Stop
        $StatePath = Join-Path $Directory 'run.json'
        $Deadline = [datetime]::UtcNow.AddSeconds(60)
        while (-not (Test-Path -LiteralPath $StatePath)) {
            $Process.Refresh()
            if ($Process.HasExited) { throw "Background process $($Process.Id) exited before startup. Check '$Directory\stderr.log'." }
            if ([datetime]::UtcNow -ge $Deadline) { throw "Background startup not confirmed for process $($Process.Id). Check '$Directory' before retrying; it may still be running." }
            Start-Sleep -Milliseconds 200
        }
        $State = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        if ($State.Status -eq 'Failed') { throw "Background run failed: $($State.Error). Logs: '$Directory'." }
        [pscustomobject]@{
            ProcessId = $Process.Id; Status = $State.Status; RunDirectory = $Directory
            LogPath = Join-Path $Directory 'execution.log'; StatePath = $StatePath
            JsonReports = @($Plan | ForEach-Object { $_.Item.OutputJsonPath } | Select-Object -Unique)
            CsvReports = @($Plan | ForEach-Object { $_.Item.ExportCsvPath } | Select-Object -Unique)
        }
    }
    catch {
        if (-not $Process) {
            foreach ($Path in @($ContextPath, $RequestPath)) {
                if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -Confirm:$false -ErrorAction Stop }
            }
        }
        throw
    }
}
