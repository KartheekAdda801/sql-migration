#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

#region Functions
function Read-ServerObjectRunJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    # Windows readers must allow replacement while the controller atomically updates reports.
    $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $Reader = [IO.StreamReader]::new($Stream)
        try { $Text = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
    }
    finally { $Stream.Dispose() }
    $Text | ConvertFrom-Json -ErrorAction Stop
}

function Write-ServerObjectRunState {
    [CmdletBinding()]
    param([string]$Directory, [string]$Status, [string]$ErrorMessage)
    $State = [ordered]@{
        Status = $Status; ProcessId = $PID
        ProcessStartedUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        UpdatedUtc = [datetime]::UtcNow.ToString('o'); Error = $ErrorMessage
    }
    $Path = Join-Path $Directory 'run.json'
    $Temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($Temporary, ($State | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Move-ServerObjectJsonFile -Source $Temporary -Destination $Path
    }
    finally { if ([IO.File]::Exists($Temporary)) { [IO.File]::Delete($Temporary) } }
}

function Invoke-ServerObjectBackgroundWorker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RequestPath)
    $Directory = Split-Path -Parent $RequestPath
    $ContextPath = Join-Path $Directory 'bootstrap.context.json'
    try {
        $Request = Import-Clixml -LiteralPath $RequestPath -ErrorAction Stop
        if ($Request.ContextPath) {
            Import-Module Az.Accounts -ErrorAction Stop
            Disable-AzContextAutosave -Scope Process | Out-Null
            Import-AzContext -Path $Request.ContextPath -Scope Process -Confirm:$false -WhatIf:$false -ErrorAction Stop | Out-Null
        }
        foreach ($Path in @($RequestPath, $ContextPath)) {
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -Confirm:$false -ErrorAction Stop }
        }
        Write-ServerObjectRunState -Directory $Directory -Status Running
        $Parameters = $Request.Parameters
        Invoke-ServerObjectWorkflow @Parameters -PreparedRunDirectory
    }
    catch {
        Write-ServerObjectRunState -Directory $Directory -Status Failed -ErrorMessage $_.Exception.Message
        Write-Error $_ -ErrorAction Continue
        exit 1
    }
    finally {
        foreach ($Path in @($RequestPath, $ContextPath)) {
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -Confirm:$false -ErrorAction Stop }
        }
    }
}

function Start-ServerObjectBackgroundRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Items, [Parameter(Mandatory)][string]$ScriptsPath,
        [Parameter(Mandatory)][string]$OutputRoot, [string]$OutputJsonPath,
        [ValidateRange(1, 128)][int]$ThrottleLimit = 10, [hashtable]$SqlCredentials = @{})
    if (-not $IsWindows) { throw 'Persistent server-object execution currently requires Windows; use -Foreground on other platforms.' }
    $RunId = New-ServerObjectRunId
    $OutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
    if ($OutputJsonPath) { $OutputJsonPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputJsonPath) }
    $Directory = Join-Path $OutputRoot $RunId
    Assert-ServiceOutputPath -Path (Join-Path $Directory '.preflight')
    if ($OutputJsonPath) { Assert-ServiceOutputPath -Path $OutputJsonPath }
    Assert-ServerObjectItemTargets -Items $Items -ThrottleLimit $ThrottleLimit
    $null = New-ServerObjectRunDirectory -Path $Directory
    $ContextPath = Join-Path $Directory 'bootstrap.context.json'
    $RequestPath = Join-Path $Directory 'request.clixml'
    $Process = $null
    $Initial = @($Items | ForEach-Object { New-ServerObjectItemResult -Item $_ -RunRoot $Directory -RunId $RunId -Status Pending })
    try {
        $Context = Export-ServerObjectAzureContext -Path $ContextPath
        $Parameters = @{
            Items = $Items; ScriptsPath = $ScriptsPath; OutputRoot = $OutputRoot
            OutputJsonPath = $OutputJsonPath; ThrottleLimit = $ThrottleLimit; RunId = $RunId
            SqlCredentials = $SqlCredentials
        }
        @{ Parameters = $Parameters; ContextPath = $Context } |
            Export-Clixml -LiteralPath $RequestPath -Depth 30 -Confirm:$false -ErrorAction Stop
        Write-ServerObjectJsonResult -Path (Join-Path $Directory 'results.json') -Started ([datetime]::UtcNow) -Results $Initial -Running
        if ($OutputJsonPath) { Write-ServerObjectJsonResult -Path $OutputJsonPath -Started ([datetime]::UtcNow) -Results $Initial -Running }
        $Script = (Join-Path $ScriptsPath 'Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1').Replace("'", "''")
        $Command = "& '$Script' -WorkerRequestPath '$($RequestPath.Replace("'", "''"))'"
        $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
        $Process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -WindowStyle Hidden -PassThru `
            -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $Encoded) `
            -RedirectStandardOutput (Join-Path $Directory 'stdout.log') -RedirectStandardError (Join-Path $Directory 'stderr.log') -ErrorAction Stop
        $Deadline = [datetime]::UtcNow.AddSeconds(60)
        $StatePath = Join-Path $Directory 'run.json'
        while (-not (Test-Path -LiteralPath $StatePath)) {
            $Process.Refresh()
            if ($Process.HasExited) { throw "Background process $($Process.Id) exited before startup. Check '$Directory\stderr.log'." }
            if ([datetime]::UtcNow -ge $Deadline) { throw "Startup not confirmed for process $($Process.Id). It may still be running; inspect '$Directory' before retrying." }
            Start-Sleep -Milliseconds 200
        }
        $State = Read-ServerObjectRunJson -Path $StatePath
        if ($State.Status -eq 'Failed') { throw "Background run failed: $($State.Error). Reports: '$Directory'." }
        [pscustomobject]@{
            ProcessId = $Process.Id; Status = $State.Status; RunId = $RunId; RunDirectory = $Directory
            StatePath = $StatePath; ResultsPath = Join-Path $Directory 'results.json'
            LogPath = Join-Path $Directory 'stdout.log'; ErrorLogPath = Join-Path $Directory 'stderr.log'
        }
    }
    catch {
        if (-not $Process) {
            $Message = $_.Exception.Message
            foreach ($Result in $Initial) { $Result.Status = 'FAILED'; $Result.ErrorMessage = $Message }
            Write-ServerObjectRunState -Directory $Directory -Status Failed -ErrorMessage $_.Exception.Message
            Write-ServerObjectJsonResult -Path (Join-Path $Directory 'results.json') -Started ([datetime]::UtcNow) -Results $Initial -RunCompleted $false -ErrorMessage $Message
            if ($OutputJsonPath) { Write-ServerObjectJsonResult -Path $OutputJsonPath -Started ([datetime]::UtcNow) -Results $Initial -RunCompleted $false -ErrorMessage $Message }
            foreach ($Path in @($ContextPath, $RequestPath)) {
                if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -Confirm:$false -ErrorAction Stop }
            }
        }
        throw
    }
}

function Get-ServerObjectRunStatus {
    [CmdletBinding()]
    param([string]$OutputRoot, [string]$RunDirectory, [string[]]$ItemId)
    if (-not $RunDirectory) {
        $Latest = Get-ChildItem -LiteralPath $OutputRoot -Directory -ErrorAction Stop |
            Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName 'results.json')) -or (Test-Path -LiteralPath (Join-Path $_.FullName 'run.json')) } |
            Sort-Object CreationTimeUtc -Descending | Select-Object -First 1
        if (-not $Latest) { throw "No server-object runs found under '$OutputRoot'." }
        $RunDirectory = $Latest.FullName
    }
    $ReportPath = Join-Path $RunDirectory 'results.json'
    $StatePath = Join-Path $RunDirectory 'run.json'
    $State = if (Test-Path -LiteralPath $StatePath) { Read-ServerObjectRunJson -Path $StatePath } else { $null }
    $Report = Read-ServerObjectRunJson -Path $ReportPath
    if ($Report.schemaVersion -ne 1 -or $Report.operation -ne 'MigrateServerObjects') { throw "Invalid server-object result report '$ReportPath'." }
    $Status = $Report.status
    $Message = ''
    if ($State -and $State.Status -eq 'Failed') { $Status = 'Failed'; $Message = $State.Error }
    elseif ($State -and $Status -eq 'Running') {
        $Process = Get-Process -Id $State.ProcessId -ErrorAction SilentlyContinue
        if (-not $Process -or $Process.StartTime.ToUniversalTime().Ticks -ne ([datetime]$State.ProcessStartedUtc).ToUniversalTime().Ticks) {
            $Status = 'Interrupted'
            $Message = 'The owning process is no longer running. Verify target SQL state before retrying; completed changes are not rolled back.'
        }
    }
    $Results = @($Report.results)
    foreach ($Id in $ItemId) {
        if ($Id -notin @($Results | ForEach-Object { $_.ItemId })) { throw "Item '$Id' is not part of this run." }
    }
    if ($ItemId) { $Results = @($Results | Where-Object ItemId -in $ItemId) }
    [pscustomobject]@{ Status = $Status; RunDirectory = $RunDirectory; ProcessId = $(if ($State) { $State.ProcessId } else { $null })
        Results = $Results; ErrorMessage = $Message; ResultsPath = $ReportPath }
}

function Watch-ServerObjectRun {
    [CmdletBinding()]
    param([string]$OutputRoot, [string]$RunDirectory, [string[]]$ItemId,
        [ValidateRange(1, 3600)][int]$MonitorIntervalSeconds = 5)
    do {
        $State = Get-ServerObjectRunStatus -OutputRoot $OutputRoot -RunDirectory $RunDirectory -ItemId $ItemId
        $RunDirectory = $State.RunDirectory
        Write-Host "$([datetime]::Now.ToString('HH:mm:ss')) $($State.Status): $RunDirectory"
        $State.Results | Format-Table ItemId, Mode, Status, ErrorMessage -Wrap | Out-Host
        if ($State.ErrorMessage) { Write-Warning $State.ErrorMessage }
        if ($State.Status -eq 'Running') { Start-Sleep -Seconds $MonitorIntervalSeconds }
    } while ($State.Status -eq 'Running')
    $State
}
#endregion Functions
