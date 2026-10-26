#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Uploads backups for multiple databases (across multiple servers) to Azure Blob Storage using AzCopy,
    based on a metadata JSON file.

.DESCRIPTION
    For each row in the metadata JSON, this script:
      - Locates the latest FULL backup under <BackupRootPath>\full (mandatory)
      - Optionally locates the latest DIFF after that full under <BackupRootPath>\diff
      - Optionally locates all LOG backups after the selected DIFF (or FULL) under <BackupRootPath>\log
      - Uploads the selected files to a per-row Azure Blob container using AzCopy

    Multi-server / multi-database support:
      - JSON Items can contain multiple records, each describing one (SrcServerName, SrcDatabaseName) backup set.
      - If BackupContainerName is not supplied in a row, the script derives it from
        "<SrcServerName>_<SrcDatabaseName>" and then sanitizes to a valid Azure container
        name (lowercase, only letters/numbers/hyphens).
      - This allows the same SrcDatabaseName to appear on multiple servers while each
        server+database pair maps to its own container.

    Azure DMS requirement:
      - This script does NOT create subfolders in the container.
      - All blobs are uploaded directly into the container root so that
        DMS sees a single-level path.

.PARAMETER ConfigPath
    Path to the JSON configuration describing all databases to upload.

    Required columns per row:
      - SrcServerName      : Source SQL host/instance name (e.g. DESKTOP-SGA61QP\DMF).
      - SrcDatabaseName    : Source database name (e.g. MIGRDEMO).
      - BackupRootPath     : Root folder for that database's backups (contains 'full', optional 'diff' and 'log').
      - IsActive           : 'Y' to process backups for this row; 'N' to skip uploads.
      - BackupStorageAccountName : Azure Storage account name.

    Optional columns per row:
      - BackupContainerName : If provided, use as-is. If blank, derive as
                             sanitized "<SrcServerName>_<SrcDatabaseName>".

.PARAMETER Overwrite
    Controls AzCopy overwrite behavior: 'prompt', 'true' (default), or 'false'.

.PARAMETER InteractiveLogin
    If specified, initiates 'azcopy login' (device code flow) before uploading.

.PARAMETER AzCopyPath
    Optional explicit path to AzCopy executable.

.PARAMETER IncludeLogsAtSameTimestamp
    If present, include logs whose timestamp equals the selected DIFF or FULL timestamp.

.PARAMETER TenantId
    Optional tenant id for AzCopy login.

.PARAMETER SubscriptionId
    Optional subscription id (logged only, AzCopy does not use it).
.PARAMETER TimestampPattern
    Optional timestamp regex with a named ts group. Supply TimestampFormat too.
.PARAMETER TimestampFormat
    DateTime format for the custom regex; otherwise common formats are tried.
.PARAMETER OutputJsonPath
    Optional execution-phase result file, including failures and per-file uploads.
    Preflight failures and WhatIf do not create output files.

.EXAMPLE
    .\Invoke-CopyBackup-OnPrem-AzureBlob.ps1 -ConfigPath "..\config\Invoke-CopyBackup-OnPrem-AzureBlob.config.json" -InteractiveLogin
.NOTES
    Uploads to a flat per-database container for DMS. Does not validate backup LSN chains.

#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [Alias('MetadataCsvPath')]
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\config\Invoke-CopyBackup-OnPrem-AzureBlob.config.json'),

    [ValidateSet('prompt','true','false')]
    [string] $Overwrite = 'true',

    [switch] $InteractiveLogin,

    [string] $AzCopyPath,

    [switch] $IncludeLogsAtSameTimestamp,

    [string] $TenantId,

    [string] $SubscriptionId,

    [ValidateSet('Y','N')]
    [string] $CheckLatestBak = 'N',
    [string]$TimestampPattern,
    [string]$TimestampFormat,
    [string]$OutputJsonPath
)

$ErrorActionPreference = 'Stop'
$MetadataCsvPath = $ConfigPath
. (Join-Path $PSScriptRoot 'Common\Migration.Helpers.ps1')

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    #region Configuration and preflight
    $Configuration = Read-ServiceConfiguration -Path $ConfigPath
    $ResolvedSettings = Resolve-ServiceSettings -Configuration $Configuration -Command $MyInvocation.MyCommand -Overrides $PSBoundParameters
    foreach ($SettingName in $ResolvedSettings.Keys) { Set-Variable -Name $SettingName -Value $ResolvedSettings[$SettingName] -WhatIf:$false -Confirm:$false }
    $Options = Get-ServiceOptions -Command $MyInvocation.MyCommand
    Invoke-DataMigrationPreflight -Operation 'Invoke-CopyBackup-OnPrem-AzureBlob' -Configuration $Configuration -Options $Options
    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Invoke-CopyBackup-OnPrem-AzureBlob: execute validated configuration')) { return }
    #endregion Configuration and preflight

$LogDirectory = Join-Path $PSScriptRoot '..\logs'
$RunStarted = [datetime]::UtcNow
$RunCompleted = $false
$RunError = $null
$reportEntries = @()
$successCount = 0
$failureCount = 0
try {
Assert-MigrationTimestampOptions -TimestampPattern $TimestampPattern -TimestampFormat $TimestampFormat
# ------------------------ Logging helpers ------------------------
$script:LogFile = $null
$script:RunStamp = $null
function Initialize-Logging {
    param([string]$BaseLogDirectory)

    if (-not (Test-Path -LiteralPath $BaseLogDirectory)) {
        New-Item -ItemType Directory -Path $BaseLogDirectory -Force | Out-Null
    }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:RunStamp = $stamp
    $script:LogFile = Join-Path $BaseLogDirectory "Invoke-CopyBackup-OnPrem-AzureBlob.$stamp.log"
    Write-Host "Logging to $script:LogFile"
    "=== Start: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') ===" | Out-File -FilePath $script:LogFile -Encoding UTF8
}
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string] $Message,
        [ValidateSet('INFO','WARN','ERROR')][string] $Level = 'INFO'
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "$ts [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $line
    switch ($Level) {
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        'WARN'  { Write-Warning $Message }
        default { Write-Host $Message }
    }
}

Initialize-Logging -BaseLogDirectory $LogDirectory

# ------------------------ AzCopy initialization ------------------------
try {
    $script:AzCopyExe = $null
    if ($AzCopyPath -and $AzCopyPath.Trim().Length -gt 0) {
        if (-not (Test-Path -LiteralPath $AzCopyPath)) {
            throw "Provided AzCopyPath not found: '$AzCopyPath'"
        }
        $script:AzCopyExe = (Resolve-Path -LiteralPath $AzCopyPath).Path
        Write-Log "Using AzCopy at: $script:AzCopyExe" 'INFO'
    }
    else {
        $azc = Get-Command azcopy -ErrorAction SilentlyContinue
        if ($azc) {
            $script:AzCopyExe = $azc.Source
            Write-Log "AzCopy found in PATH: $script:AzCopyExe" 'INFO'
        }
        else {
            throw "AzCopy is not installed or not in PATH. Install and/or add it to PATH, then rerun."
        }
    }
}
catch {
    Write-Log "AzCopy initialization error: $($_.Exception.Message)" 'ERROR'
    throw
}

if ($SubscriptionId -and $SubscriptionId.Trim().Length -gt 0) {
    Write-Log ("SubscriptionId (for reference): {0}" -f $SubscriptionId) 'INFO'
}

# ------------------------ Metadata JSON ------------------------
if (-not (Test-Path -LiteralPath $MetadataCsvPath)) {
    Write-Log "Metadata JSON not found: $MetadataCsvPath" 'ERROR'
    throw "Metadata JSON not found: $MetadataCsvPath"
}

Write-Log ("Reading metadata JSON: {0}" -f $MetadataCsvPath) 'INFO'
$metadata = @($Configuration.Items)
if (-not $metadata -or $metadata.Count -eq 0) {
    Write-Log "No rows found in metadata JSON." 'ERROR'
    throw "Metadata JSON is empty."
}

$requiredColumns = @('SrcServerName','SrcDatabaseName','BackupRootPath','IsActive','BackupStorageAccountName')
$missingColumns = @()
foreach ($col in $requiredColumns) {
    if ($col -notin $metadata[0].PSObject.Properties.Name) {
        $missingColumns += $col
    }
}
if ($missingColumns.Count -gt 0) {
    Write-Log ("Metadata JSON is missing required columns: {0}" -f ($missingColumns -join ', ')) 'ERROR'
    throw "Metadata JSON is missing required columns: $($missingColumns -join ', ')"
}

Write-Log ("Loaded {0} metadata row(s)." -f $metadata.Count) 'INFO'
foreach ($row in $metadata) {
    if ($row.IsActive -notmatch '^[YN]$') {
        throw "IsActive must be Y or N for '$($row.SrcServerName)/$($row.SrcDatabaseName)'."
    }
}

# ------------------------ AzCopy authentication ------------------------
if ($InteractiveLogin.IsPresent) {
    Write-Log "Initiating 'azcopy login' (device code flow)..." 'INFO'
    $loginArgs = @('login')
    if ($TenantId -and $TenantId.Trim().Length -gt 0) {
        $loginArgs += @('--tenant-id', $TenantId)
        Write-Log ("AzCopy login with tenant id: {0}" -f $TenantId) 'INFO'
    }
    & $script:AzCopyExe @loginArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Log "AzCopy login failed with exit code $LASTEXITCODE." 'ERROR'
        throw "AzCopy login failed. Please retry."
    }
    Write-Log "AzCopy login succeeded." 'INFO'
}
else {
    Write-Log "Assuming AzCopy is already authenticated (run 'azcopy login' if needed)." 'INFO'
}

# ------------------------ Shared helper functions ------------------------
function Get-TimestampFromName {
    param([Parameter(Mandatory=$true)][string] $FileName)
    Get-MigrationBackupTimestamp -FileName $FileName -TimestampPattern $TimestampPattern -TimestampFormat $TimestampFormat
}

function Get-LatestByFolderAndExt {
    param(
        [Parameter(Mandatory=$true)][string] $Folder,
        [Parameter(Mandatory=$true)][string] $Extension
    )
    $files = Get-ChildItem -LiteralPath $Folder -File -Filter "*$Extension" -ErrorAction Stop
    $candidates = @()
    foreach ($f in $files) {
        $ts = Get-TimestampFromName $f.Name
        if ($ts) {
            $candidates += [pscustomobject]@{ File = $f; Timestamp = $ts }
        }
        else {
            Write-Log ("[{0}] Skipping (no timestamp): {1}" -f $Folder, $f.FullName) 'WARN'
        }
    }
    return ($candidates | Sort-Object Timestamp -Descending | Select-Object -First 1)
}

function Get-LatestDiffAfter {
    param(
        [Parameter(Mandatory=$true)][string] $Folder,
        [Parameter(Mandatory=$true)][DateTime] $AfterTimestamp
    )
    $files = Get-ChildItem -LiteralPath $Folder -File -ErrorAction Stop |
        Where-Object { $_.Extension -in @('.bak', '.diff') }
    $candidates = @()
    foreach ($f in $files) {
        $ts = Get-TimestampFromName $f.Name
        if ($ts -and $ts -gt $AfterTimestamp) {
            $candidates += [pscustomobject]@{ File = $f; Timestamp = $ts }
        }
    }
    return ($candidates | Sort-Object Timestamp -Descending | Select-Object -First 1)
}

function Get-LogsAfter {
    param(
        [Parameter(Mandatory=$true)][string] $Folder,
        [Parameter(Mandatory=$true)][DateTime] $AfterTimestamp,
        [switch] $IncludeEqual
    )
    $files = Get-ChildItem -LiteralPath $Folder -File -ErrorAction Stop | Where-Object { $_.Extension -match '^(\.trn|\.log)$' }
    $candidates = @()
    $skippedNoTs = 0
    $skippedBefore = 0
    foreach ($f in $files) {
        $ts = Get-TimestampFromName $f.Name
        if (-not $ts) { $skippedNoTs++; continue }
        $isAfter = $ts -gt $AfterTimestamp
        $isEqual = $ts -eq $AfterTimestamp
        if ($isAfter -or ($IncludeEqual.IsPresent -and $isEqual)) {
            $candidates += [pscustomobject]@{ File = $f; Timestamp = $ts }
        }
        else {
            $skippedBefore++
        }
    }
    Write-Log ("Logs scan (folder={0}): total={1}, selected={2}, skippedNoTs={3}, skippedBeforeOrEqual={4}" -f $Folder, $files.Count, $candidates.Count, $skippedNoTs, $skippedBefore)
    return ($candidates | Sort-Object Timestamp)
}

function Confirm-ContainerExists {
    param([Parameter(Mandatory=$true)][string] $ContainerUrl)
    Write-Log ("Ensuring container exists: {0}" -f $ContainerUrl) 'INFO'
    $output = & $script:AzCopyExe make "$ContainerUrl" 2>&1
    $mkCode = $LASTEXITCODE
    $output | Tee-Object -FilePath $script:LogFile -Append | Write-Host
    if ($mkCode -eq 0) {
        Write-Log "Container created (or already ready)." 'INFO'
        return
    }
    if (($output | Out-String) -match 'ContainerAlreadyExists|already exists') {
        Write-Log 'Container already exists.' 'INFO'
        return
    }
    throw "AzCopy could not create container (exit code $mkCode). Check the AzCopy output and storage permissions."
}

function Test-BlobExists {
    param(
        [Parameter(Mandatory=$true)][string] $ContainerUrl,
        [Parameter(Mandatory=$true)][string] $FileName,
        [int64] $ExpectedSizeBytes = -1
    )
    try {
        $output = & $script:AzCopyExe list "$ContainerUrl" --machine-readable 2>&1 | Out-String
        $escapedName = [regex]::Escape($FileName)
        if ($LASTEXITCODE -ne 0) {
            throw "AzCopy list failed with exit code $LASTEXITCODE."
        }
        if ($output -match "(?m)^(?:INFO:\s*)?$escapedName;\s*Content Length:\s*(\d+)\s*$") {
            return ($ExpectedSizeBytes -ge 0 -and [int64]$Matches[1] -eq $ExpectedSizeBytes)
        }
        return $false
    }
    catch {
        Write-Log ("Test-BlobExists: Error checking '{0}/{1}': {2}" -f $ContainerUrl, $FileName, $_.Exception.Message) 'WARN'
        throw
    }
}

function Invoke-AzCopyUpload {
    param(
        [Parameter(Mandatory=$true)][string] $SourcePath,
        [Parameter(Mandatory=$true)][string] $DestBaseUrl,
        [Parameter(Mandatory=$true)][string] $Overwrite,
        [Parameter(Mandatory=$true)][string] $FileType,
        [string] $ExtraArgs
    )
    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Write-Log "Source file not found: $SourcePath" 'ERROR'
        $fileInfo = $null
        $sizeBytes = $null
    }
    else {
        $fileInfo = Get-Item -LiteralPath $SourcePath
        $sizeBytes = $fileInfo.Length
    }

    $startTime = Get-Date
    $status = 'Failed'
    $errorMessage = $null
    $exitCode = $null

    if (-not $fileInfo) {
        $errorMessage = "Missing source file: $SourcePath"
        Write-Log $errorMessage 'ERROR'
    }
    else {
        $blobFileName = $fileInfo.Name
        if (Test-BlobExists -ContainerUrl $DestBaseUrl -FileName $blobFileName -ExpectedSizeBytes $sizeBytes) {
            $status = 'Skipped'
            Write-Log ("SKIPPED: '{0}' already exists in '{1}' with matching size. File will not be re-uploaded." -f $blobFileName, $DestBaseUrl) 'WARN'
        }
        else {
            Write-Log "Uploading: $SourcePath -> $DestBaseUrl" 'INFO'
            $azCopyArgs = @('copy', "$SourcePath", "$DestBaseUrl", "--overwrite=$Overwrite")
            if ($ExtraArgs -and $ExtraArgs.Trim().Length -gt 0) { $azCopyArgs += $ExtraArgs }
            Write-Log ("AzCopy command: {0} {1}" -f $script:AzCopyExe, ($azCopyArgs -join ' ')) 'INFO'
            & $script:AzCopyExe @azCopyArgs 2>&1 | Tee-Object -FilePath $script:LogFile -Append | Write-Host
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                $status = 'Success'
                Write-Log "Upload succeeded: $SourcePath" 'INFO'
            }
            else {
                $status = 'Failed'
                $errorMessage = "AzCopy upload failed (exit code $exitCode)"
                Write-Log $errorMessage 'ERROR'
            }
        }
    }

    $endTime = Get-Date
    $duration = $endTime - $startTime
    $durationMinutes = [math]::Round($duration.TotalMinutes, 3)

    $fileSizeGB = if ($sizeBytes -ne $null) { [math]::Round(($sizeBytes / 1GB), 3) } else { $null }

    return [pscustomobject]@{
        SourcePath          = $SourcePath
        FileName           = if ($fileInfo) { $fileInfo.Name } else { [System.IO.Path]::GetFileName($SourcePath) }
        FileType           = $FileType
        FileSizeGB         = $fileSizeGB
        Status             = $status
        ErrorMessage       = $errorMessage
        UploadStartTime    = $startTime
        UploadEndTime      = $endTime
        UploadDurationMinutes  = $durationMinutes
        AzCopyExitCode     = $exitCode
    }
}

function Update-CheckLatestBakReport {
    param(
        [Parameter(Mandatory=$true)][Object[]] $Metadata,
        [Parameter(Mandatory=$true)][string] $LogDirectory
    )

    $cutoff = (Get-Date).AddDays(-7)
    $results = @()
    $rowIndex = 0

    foreach ($row in $Metadata) {
        $rowIndex++

        $rootPath = $row.BackupRootPath
        $serverName = $row.SrcServerName
        $databaseName = $row.SrcDatabaseName

        if (-not $rootPath -or -not $serverName -or -not $databaseName) {
            Write-Log ("Row #{0}: Missing BackupRootPath/SrcServerName/SrcDatabaseName; skipping in CheckLatestBak report." -f $rowIndex) 'WARN'
            continue
        }

        # Resolve FULL and DIFF folders in a case-insensitive way (e.g. 'full' or 'FULL')
        $fullFolder = $null
        $diffFolder = $null

        try {
            $subDirs = Get-ChildItem -LiteralPath $rootPath -Directory -ErrorAction SilentlyContinue
        }
        catch {
            $subDirs = @()
            Write-Log ("Row #{0}: Error listing subfolders under BackupRootPath '{1}' for CheckLatestBak: {2}" -f $rowIndex, $rootPath, $_.Exception.Message) 'ERROR'
        }

        if ($subDirs) {
            $fullFolder = ($subDirs | Where-Object { $_.Name -ieq 'FULL' } | Select-Object -First 1).FullName
            $diffFolder = ($subDirs | Where-Object { $_.Name -ieq 'DIFF' } | Select-Object -First 1).FullName
        }

        $latestFull = $null
        $latestDiff = $null

        if ($fullFolder -and (Test-Path -LiteralPath $fullFolder)) {
            try {
                $latestFull = Get-LatestByFolderAndExt -Folder $fullFolder -Extension '.bak'
            }
            catch {
                Write-Log ("Row #{0}: Error scanning FULL folder '{1}' for CheckLatestBak: {2}" -f $rowIndex, $fullFolder, $_.Exception.Message) 'ERROR'
            }
        }
        else {
            Write-Log ("Row #{0}: FULL folder not found for CheckLatestBak: '{1}'" -f $rowIndex, $fullFolder) 'WARN'
        }

        if ($latestFull -and $diffFolder -and (Test-Path -LiteralPath $diffFolder)) {
            try {
                $latestDiff = Get-LatestDiffAfter -Folder $diffFolder -AfterTimestamp $latestFull.Timestamp
            }
            catch {
                Write-Log ("Row #{0}: Error scanning DIFF folder '{1}' for CheckLatestBak: {2}" -f $rowIndex, $diffFolder, $_.Exception.Message) 'ERROR'
            }
        }

        $latestAvailable = if ($latestFull -and $latestFull.Timestamp -ge $cutoff) { 'Y' } else { 'N' }

        $fullNameTs = if ($latestFull) { Get-TimestampFromName $latestFull.File.Name } else { $null }
        $diffNameTs = if ($latestDiff) { Get-TimestampFromName $latestDiff.File.Name } else { $null }

        $latestFullDate = if ($fullNameTs) { $fullNameTs.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        $latestDiffDate = if ($diffNameTs) { $diffNameTs.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }

        $results += [pscustomobject]@{
            RootPath           = $rootPath
            ServerName         = $serverName
            DatabaseName       = $databaseName
            LatestAvailable    = $latestAvailable
            LatestFullBak_date = $latestFullDate
            LatestFullBak      = if ($latestFull) { $latestFull.File.Name } else { '' }
            LatestDiffBak_date = $latestDiffDate
            LatestDiffBak      = if ($latestDiff) { $latestDiff.File.Name } else { '' }
        }
    }

    $reportDirectory = Join-Path $LogDirectory 'Reports'
    if (-not (Test-Path -LiteralPath $reportDirectory)) {
        New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    }

    if (-not $results -or $results.Count -eq 0) {
        Write-Log "CheckLatestBak: No rows to write to report." 'WARN'
        return
    }

    $groups = $results | Group-Object ServerName
    foreach ($g in $groups) {
        $serverNameForFile = ($g.Group[0].ServerName -replace "[^A-Za-z0-9_-]", "_")
        $reportFileName = "{0}_CheckLatestBak_Report.csv" -f $serverNameForFile
        $reportPath = Join-Path $reportDirectory $reportFileName

        $existing = @()
        if (Test-Path -LiteralPath $reportPath) {
            try {
                $existing = Import-Csv -Path $reportPath
            }
            catch {
                Write-Log ("CheckLatestBak: Failed to read existing report '{0}': {1}" -f $reportPath, $_.Exception.Message) 'ERROR'
            }
        }

        $updated = @()
        $updated += $existing

        foreach ($rowResult in $g.Group) {
            $match = $updated | Where-Object { $_.RootPath -eq $rowResult.RootPath -and $_.ServerName -eq $rowResult.ServerName -and $_.DatabaseName -eq $rowResult.DatabaseName }
            if ($match) {
                foreach ($m in $match) {
                    $m.LatestAvailable    = $rowResult.LatestAvailable
                    $m.LatestFullBak_date = $rowResult.LatestFullBak_date
                    $m.LatestFullBak      = $rowResult.LatestFullBak
                    $m.LatestDiffBak_date = $rowResult.LatestDiffBak_date
                    $m.LatestDiffBak      = $rowResult.LatestDiffBak
                }
            }
            else {
                $updated += $rowResult
            }
        }

        $updated | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
        Write-Log ("CheckLatestBak report written to: {0}" -f $reportPath) 'INFO'
    }
    $results
}

$reportEntries = @(Update-CheckLatestBakReport -Metadata $metadata -LogDirectory $LogDirectory)

if ($CheckLatestBak -ne 'Y') {

    # ------------------------ Main: process each metadata row ------------------------
    $successCount = 0
    $failureCount = 0
    $reportEntries = @()

    $index = 0
    foreach ($row in $metadata) {
        $index++
        $rootPath          = $row.BackupRootPath
        $storageAccount    = $row.BackupStorageAccountName
        $serverName        = $row.SrcServerName
        $databaseName      = $row.SrcDatabaseName
        $rowContainerName  = $row.PSObject.Properties["BackupContainerName"].Value

        $activeValue = $row.IsActive.ToString().Trim().ToUpperInvariant()
        if ($activeValue -eq 'N') {
            Write-Log ("Row #{0}: IsActive flag is 'N'; skipping backup for Server='{1}', Database='{2}'." -f $index, $serverName, $databaseName) 'INFO'
            continue
        }

        Write-Log "--- Processing row #$index : Server='$serverName', Database='$databaseName' ---" 'INFO'

        try {
            if (-not (Test-Path -LiteralPath $rootPath)) {
                throw "BackupRootPath not found: '$rootPath'"
            }
            if (-not $storageAccount -or $storageAccount.Trim().Length -eq 0) {
                throw "BackupStorageAccountName is empty for this row."
            }
            if (-not $serverName -or $serverName.Trim().Length -eq 0) {
                throw "SrcServerName is empty for this row."
            }
            if (-not $databaseName -or $databaseName.Trim().Length -eq 0) {
                throw "SrcDatabaseName is empty for this row."
            }

            # Derive container name if not explicitly provided
            $resolvedContainerName = $rowContainerName
            if (-not $resolvedContainerName -or $resolvedContainerName.Trim().Length -eq 0) {
                $rawContainerName = "{0}_{1}" -f $serverName, $databaseName
                $resolvedContainerName = $rawContainerName.ToLower()
                $resolvedContainerName = $resolvedContainerName -replace "[^a-z0-9-]", "-"
                $resolvedContainerName = $resolvedContainerName -replace "-+", "-"
                $resolvedContainerName = $resolvedContainerName.Trim('-')
                if ($resolvedContainerName.Length -lt 3) {
                    $resolvedContainerName = "db-$resolvedContainerName"
                }
                if ($resolvedContainerName.Length -gt 63) {
                    $resolvedContainerName = $resolvedContainerName.Substring(0,63).TrimEnd('-')
                }
                Write-Log ("Derived container '{0}' from SrcServerName='{1}', SrcDatabaseName='{2}' (raw pattern: '{3}')" -f $resolvedContainerName, $serverName, $databaseName, $rawContainerName) 'INFO'
            }

            if ($resolvedContainerName -notmatch '^(?=.{3,63}$)[a-z0-9]+(?:-[a-z0-9]+)*$') {
                throw "Invalid Azure Blob container name: '$resolvedContainerName'."
            }

            $fullFolder = Join-Path $rootPath 'full'
            $diffFolder = Join-Path $rootPath 'diff'
            $logFolder  = Join-Path $rootPath 'log'

            if (-not (Test-Path -LiteralPath $fullFolder)) {
                throw "Required folder missing: '$fullFolder'. Ensure it exists and contains FULL backups."
            }

            $diffFolderExists = Test-Path -LiteralPath $diffFolder
            $logFolderExists  = Test-Path -LiteralPath $logFolder

            if (-not $diffFolderExists) {
                Write-Log ("Optional diff folder not found for row #{0}: '{1}'" -f $index, $diffFolder) 'WARN'
            }
            if (-not $logFolderExists) {
                Write-Log ("Optional log folder not found for row #{0}: '{1}'" -f $index, $logFolder) 'WARN'
            }

            # Discover backups
            $latestFull = Get-LatestByFolderAndExt -Folder $fullFolder -Extension '.bak'
            if (-not $latestFull) {
                throw "No Full backup (.bak) found in '$fullFolder'. Cannot proceed."
            }
            Write-Log ("Row #{0}: Latest FULL: {1} (Timestamp: {2:yyyy-MM-dd HH:mm:ss})" -f $index, $latestFull.File.FullName, $latestFull.Timestamp) 'INFO'

            $latestDiff = $null
            if ($diffFolderExists) {
                $latestDiff = Get-LatestDiffAfter -Folder $diffFolder -AfterTimestamp $latestFull.Timestamp
                if ($latestDiff) {
                    Write-Log ("Row #{0}: Latest DIFF after FULL: {1} (Timestamp: {2:yyyy-MM-dd HH:mm:ss})" -f $index, $latestDiff.File.FullName, $latestDiff.Timestamp) 'INFO'
                }
                else {
                    Write-Log ("Row #{0}: No Differential found after latest Full. Selecting logs after the Full." -f $index) 'INFO'
                }
            }
            else {
                Write-Log ("Row #{0}: Differential folder missing; selecting logs after the Full." -f $index) 'INFO'
            }

            $logsToUpload = @()
            if ($logFolderExists) {
                $logStartTimestamp = if ($latestDiff) { $latestDiff.Timestamp } else { $latestFull.Timestamp }
                $logsToUpload = @(Get-LogsAfter -Folder $logFolder -AfterTimestamp $logStartTimestamp -IncludeEqual:$IncludeLogsAtSameTimestamp.IsPresent)
                if ($logsToUpload -and $logsToUpload.Count -gt 0) {
                    Write-Log ("Row #{0}: Log files selected: {1}" -f $index, ($logsToUpload.File.FullName -join '; ')) 'INFO'
                }
                else {
                    Write-Log ("Row #{0}: No Log (.trn/.log) backups found after the selected Full or Differential." -f $index) 'WARN'
                }
            }

            # Prepare destination (container root only - no subfolders)
            $destinationBase = "https://$storageAccount.blob.core.windows.net/$resolvedContainerName"
            Write-Log ("Row #{0}: Destination base (container root): {1}" -f $index, $destinationBase) 'INFO'

            # Ensure container exists
            Confirm-ContainerExists -ContainerUrl $destinationBase

            # Perform uploads and collect per-file report entries
            $uploaded = @()

            $fullResult = Invoke-AzCopyUpload -SourcePath $latestFull.File.FullName -DestBaseUrl $destinationBase -Overwrite $Overwrite -FileType 'Full'
            $fullResult | Add-Member -NotePropertyName RowIndex -NotePropertyValue $index
            $fullResult | Add-Member -NotePropertyName ServerName -NotePropertyValue $serverName
            $fullResult | Add-Member -NotePropertyName DatabaseName -NotePropertyValue $databaseName
            $fullResult | Add-Member -NotePropertyName StorageAccountName -NotePropertyValue $storageAccount
            $fullResult | Add-Member -NotePropertyName ContainerName -NotePropertyValue $resolvedContainerName
            $fullResult | Add-Member -NotePropertyName RootPath -NotePropertyValue $rootPath
            $reportEntries += $fullResult
            if ($fullResult.Status -eq 'Failed') {
                throw "Upload failed for FULL backup: $($fullResult.SourcePath). Error: $($fullResult.ErrorMessage)"
            }
            $uploaded += $latestFull.File.FullName

            if ($latestDiff) {
                $diffResult = Invoke-AzCopyUpload -SourcePath $latestDiff.File.FullName -DestBaseUrl $destinationBase -Overwrite $Overwrite -FileType 'Diff'
                $diffResult | Add-Member -NotePropertyName RowIndex -NotePropertyValue $index
                $diffResult | Add-Member -NotePropertyName ServerName -NotePropertyValue $serverName
                $diffResult | Add-Member -NotePropertyName DatabaseName -NotePropertyValue $databaseName
                $diffResult | Add-Member -NotePropertyName StorageAccountName -NotePropertyValue $storageAccount
                $diffResult | Add-Member -NotePropertyName ContainerName -NotePropertyValue $resolvedContainerName
                $diffResult | Add-Member -NotePropertyName RootPath -NotePropertyValue $rootPath
                $reportEntries += $diffResult
                if ($diffResult.Status -eq 'Failed') {
                    throw "Upload failed for DIFF backup: $($diffResult.SourcePath). Error: $($diffResult.ErrorMessage)"
                }
                $uploaded += $latestDiff.File.FullName
            }

            foreach ($log in $logsToUpload) {
                $logResult = Invoke-AzCopyUpload -SourcePath $log.File.FullName -DestBaseUrl $destinationBase -Overwrite $Overwrite -FileType 'Log'
                $logResult | Add-Member -NotePropertyName RowIndex -NotePropertyValue $index
                $logResult | Add-Member -NotePropertyName ServerName -NotePropertyValue $serverName
                $logResult | Add-Member -NotePropertyName DatabaseName -NotePropertyValue $databaseName
                $logResult | Add-Member -NotePropertyName StorageAccountName -NotePropertyValue $storageAccount
                $logResult | Add-Member -NotePropertyName ContainerName -NotePropertyValue $resolvedContainerName
                $logResult | Add-Member -NotePropertyName RootPath -NotePropertyValue $rootPath
                $reportEntries += $logResult
                if ($logResult.Status -eq 'Failed') {
                    throw "Upload failed for LOG backup: $($logResult.SourcePath). Error: $($logResult.ErrorMessage)"
                }
                $uploaded += $log.File.FullName
            }

            Write-Log ("Row #{0}: Completed uploads. Files: {1}" -f $index, ($uploaded -join '; ')) 'INFO'
            $successCount++
        }
        catch {
            Write-Log ("Row #{0}: Processing error: {1}" -f $index, $_.Exception.Message) 'ERROR'
            $failureCount++
            continue
        }
    }

    Write-Log ("Summary: Successful rows={0}, Failed rows={1}" -f $successCount, $failureCount) 'INFO'

    # Write detailed backup report CSVs per ServerName
    try {
        $reportDirectory = Join-Path $LogDirectory 'Reports'
        if (-not (Test-Path -LiteralPath $reportDirectory)) {
            New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
        }
        #$reportStamp = if ($script:RunStamp) { $script:RunStamp } else { Get-Date -Format 'yyyyMMdd_HHmmss' }

        if ($reportEntries -and $reportEntries.Count -gt 0) {
            # Group by ServerName so each server gets a single consolidated report
            $groups = $reportEntries | Group-Object ServerName
            foreach ($g in $groups) {
                $serverNameForFile   = ($g.Group[0].ServerName -replace "[^A-Za-z0-9_-]", "_")
                $reportFileName = "{0}_BackupCopyDMS_Report.csv" -f $serverNameForFile
                $reportPath = Join-Path $reportDirectory $reportFileName
                $g.Group | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
                Write-Log ("Detailed backup report written to: {0}" -f $reportPath) 'INFO'
            }
        }
        else {
            Write-Log "No per-file upload entries collected; detailed report not generated." 'WARN'
        }
    }
    catch {
        Write-Log ("Failed to write detailed backup report(s): {0}" -f $_.Exception.Message) 'ERROR'
        throw
    }
    if ($failureCount -gt 0) {
        throw "$failureCount backup-copy row(s) failed. See the log and reports."
    }
}

Write-Log "=== End: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') ===" 'INFO'
$RunCompleted = $true
}
catch {
    $RunError = $_.Exception.Message
    throw
}
finally {
    if ($OutputJsonPath) {
        Write-MigrationJsonResult -Path $OutputJsonPath -Result @{
            schemaVersion = 1; operation = 'CopyBackups'
            status = $(if ($RunCompleted) { 'Succeeded' } else { 'Failed' })
            startedAt = $RunStarted; completedAt = [datetime]::UtcNow
            reportOnly = ($CheckLatestBak -eq 'Y'); logFile = $script:LogFile
            results = @($reportEntries); successfulRows = $successCount; failedRows = $failureCount
            uploadedFiles = @($reportEntries | Where-Object Status -eq 'Success' | Select-Object -ExpandProperty SourcePath)
            skippedFiles = @($reportEntries | Where-Object Status -eq 'Skipped' | Select-Object -ExpandProperty SourcePath)
            errors = @($RunError | Where-Object { $_ })
        }
    }
}
}
#endregion Main Execution
