#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Automated SQL Server security object migration from source SQL Server to target (Azure VM SQL Server), driven by JSON configuration.

.DESCRIPTION
    This script performs a two-phase migration of SQL Server security objects:

    PHASE 1 - GENERATE:
      Connects to the source SQL Server and extracts security objects into idempotent T-SQL scripts.
      For each component, produces BOTH a filtered script (excludes system accounts, deleted AD
      principals) and an unfiltered _ALL script (everything on the source).

    PHASE 2 - EXECUTE (optional):
      Runs the generated T-SQL scripts against the target server with batch-level retry logic,
      structured logging, and detailed reporting.

    Components migrated:
      - SQL Logins        : Windows/AD logins, SQL logins (hashed passwords + SID), server roles,
                            server permissions, database users, database role memberships,
                            database permissions, MSDB SQL Agent permissions.
      - SQL Operators     : SQL Agent operator definitions (email notification targets).
      - SQL Alerts        : SQL Agent alert definitions (severity, message ID, performance conditions).
      - SQL Agent Jobs    : Full job definitions via SMO scripting (create/update in place),
                            individual per-job files and a combined migration script.

    Modes of operation:
      - Generate + Execute : Default when TargetExecutionFlag=Yes in JSON Items.
      - Generate Only      : When TargetExecutionFlag=No (scripts produced but not executed).
      - Execute Only       : When OnlyTargetExecutionFlag=Yes (re-runs previously generated scripts).

    Key features:
      - Idempotent SQL output (IF NOT EXISTS / in-place updates).
      - Active Directory validation skips deleted principals (filtered mode).
      - Batch routing detects USE [DB] directives and routes each batch to the correct database.
      - Structured logging: per-component generation logs, execution CSV logs, transcripts,
        and a master summary report per server.
      - Windows Integrated Authentication with TrustServerCertificate.

    Output folder structure:
      <ServiceDirectory>\output\AzSQLVM\<SourceServerName>\
          ├── SQL Logins\
          │   ├── <Server>_SQLLogins.sql
          │   ├── <Server>_SQLLogins_ALL.sql
          │   └── Logs\<RunId>\
          ├── SQL Operators\
          ├── SQL Alerts\
          ├── SQL Agents\
          │   ├── <Server>_SQLAgents.sql
          │   ├── Jobs\          (individual per-job scripts)
          │   ├── Jobs_ALL\
          │   └── Logs\<RunId>\
          └── MasterLogs\
              ├── MigrationSummary_<timestamp>.txt
              └── MigrationSummary_<timestamp>.csv

.PARAMETER ConfigPath
    Path to the JSON configuration containing migration configuration.

    Required columns:
      - SourceServerName                : SQL host name or FQDN, optionally followed by \Instance
      - SourceDomainSuffix              : Optional DNS suffix appended to a short source host name
      - TargetServerName                : Target SQL Server FQDN
      - SourceListofDatabases           : Comma-separated database list or "All"
      - SQLLoginsMigrationFlag          : Yes/No
      - SQLLoginsMigrationScope         : All, Server, or Database
      - SQLOperatorsMigrationFlag       : Yes/No
      - SQLAlertsMigrationFlag          : Yes/No
      - SQLAgentJobsMigrationFlag       : Yes/No
      - SQLAgentJobFilterCriteria       : Regex pattern, "DBA-ENABLED", or ".*" (all)
      - TargetExecutionFlag             : Yes/No - auto-execute generated scripts on target
      - OnlyTargetExecutionFlag         : Yes/No - skip generation, execute existing scripts only

.PARAMETER OutputJsonPath
    Optional structured summary, also written when generation or execution fails.
.EXAMPLE
    ..\Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1 -ItemId VM-Objects -Activity Generate

    Reads JSON Items, generates T-SQL migration scripts for each enabled component, and
    executes them on the target server if TargetExecutionFlag=Yes.

.EXAMPLE

    # With OnlyTargetExecutionFlag=Yes in the JSON item
    #Ensure the scripts are already generated and available for execution.
    Skips generation and re-executes previously generated scripts against the target.

.NOTES
    Set TargetExecutionFlag and OnlyTargetExecutionFlag to No to generate scripts without executing them.
#>

[CmdletBinding(SupportsShouldProcess)]
param(

    [Parameter(Mandatory)]
    [Alias('CsvPath')]
    [string]$ConfigPath,
    [string]$OutputJsonPath,
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\output\AzSQLVM')
)

$ErrorActionPreference = 'Stop'
$CsvPath = $ConfigPath

. (Join-Path $PSScriptRoot 'Common\ServerObjects.Helpers.ps1')

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    #region Configuration and preflight
    $Configuration = Read-ServiceConfiguration -Path $ConfigPath
    $ResolvedSettings = Resolve-ServiceSettings -Configuration $Configuration -Command $MyInvocation.MyCommand -Overrides $PSBoundParameters
    foreach ($SettingName in $ResolvedSettings.Keys) { Set-Variable -Name $SettingName -Value $ResolvedSettings[$SettingName] -WhatIf:$false -Confirm:$false }
    $Options = Get-ServiceOptions -Command $MyInvocation.MyCommand
    Invoke-ServerObjectPreflight -Operation 'Invoke-MigrateServerObjects-OnPrem-AzSQLVM' -Configuration $Configuration -Options $Options -ScriptsPath $PSScriptRoot
    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Invoke-MigrateServerObjects-OnPrem-AzSQLVM: execute validated configuration')) { return }
    #endregion Configuration and preflight


    $RunStarted = [datetime]::UtcNow
    $RunCompleted = $false
    $RunError = $null
    $Global:MigrationResults = [System.Collections.ArrayList]::new()
    try {
$script:MigrationHadErrors = $false
# =========================================================================
# MODULE PREREQUISITES
# =========================================================================
# Ensure required PowerShell modules (SqlServer, ActiveDirectory) are
# installed and imported before any work begins.
# =========================================================================

foreach ($mod in @('SqlServer', 'ActiveDirectory')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        throw "Required module '$mod' is missing. Install prerequisites before running this script. ActiveDirectory is provided by Windows RSAT."
    }
    Import-Module $mod -ErrorAction Stop
    Write-Host "Module '$mod' loaded." -ForegroundColor Green
}

# =========================================================================
# EXECUTION CONTROLS (script-level)
# =========================================================================
# Global retry count, authentication mode, and credential placeholder
# used by the execution engine later in the script.
# =========================================================================

$MaxRetry            = 3
$UseAccessToken      = $false
$TargetSqlCredential = $null

# =========================================================================
# FILE VALIDATION
# =========================================================================
# Reusable function that guards against empty paths, missing files,
# and directory paths passed where a file is expected.
# =========================================================================


# Validate CSV files exist before proceeding
Test-FileExists -Path $CsvPath  -FileType "JSON"

Write-Host "Input validation successful" -ForegroundColor Green


# =========================================================================
# LOAD JSON ITEMS
# =========================================================================

$csvConfigs = @($Configuration.Items)

if (-not $csvConfigs) {
    throw "JSON Items is empty"
}

$RequiredColumns = @(
    'SourceServerName', 'TargetServerName', 'SourceListofDatabases', 'SQLAgentJobFilterCriteria',
    'SQLLoginsMigrationScope', 'SQLAgentJobsMigrationFlag', 'SQLLoginsMigrationFlag',
    'SQLOperatorsMigrationFlag', 'SQLAlertsMigrationFlag', 'TargetExecutionFlag', 'OnlyTargetExecutionFlag'
)
foreach ($Column in $RequiredColumns) {
    if ($Column -notin $csvConfigs[0].PSObject.Properties.Name) { throw "Missing required JSON item field: $Column" }
}
foreach ($Config in $csvConfigs) {
    foreach ($Column in $RequiredColumns | Where-Object { $_ -like '*Flag' }) {
        $Config.$Column = $Config.$Column.Trim()
        if ($Config.$Column -notin @('Yes', 'No')) { throw "$Column must be Yes or No." }
    }
    if ($Config.PSObject.Properties['TargetType'] -and $Config.TargetType -ne 'SQLVM') {
        throw 'This entry point requires TargetType SQLVM.'
    }
    if ($Config.PSObject.Properties['SQLDBMailMigrationFlag']) {
        $Config.SQLDBMailMigrationFlag = $Config.SQLDBMailMigrationFlag.Trim()
        if ($Config.SQLDBMailMigrationFlag -notin @('Yes', 'No')) { throw 'SQLDBMailMigrationFlag must be Yes or No.' }
    }
}

Write-Host "JSON Items loaded successfully" -ForegroundColor Green


# #########################################################################
#
#  SQL SECURITY MIGRATION SHARED HELPER MODULE
#
#  This module contains reusable helper functions for:
#    - Logging & Monitoring
#    - SQL Connectivity Validation
#    - Active Directory Validation
#    - SQL String Escaping Utilities
#    - Safe SQL Execution with Logging
#    - Batch Routing Logic
#
# #########################################################################


#region ===================================================================
#       LOGGING & MONITORING
# =====================================================================

# Script-scoped variable for active log file (set by each Generate-* function)
$script:ActiveLogFile = $null


#endregion




# -------------------------------------------------------------------------
# -------------------------------------------------------------------------


# #########################################################################
#
#  PART 2 EXECUTE GENERATED SQL ON TARGET (Azure VM SQL Server)
#
# #########################################################################


#region ========================= PHASE 2: EXECUTION LOGGING ==============
# Stores per-file overall outcomes for the final summary.
# =========================================================================

$Global:FileResults = @()



#endregion




#region ========================= SCRIPT EXECUTOR (BATCH SPLIT + RETRY) ===
# Reads the generated SQL script file, splits it into batches on GO,
# routes each batch to the proper database, and executes with retry
# logic and structured logging.
# =========================================================================

function Execute-SqlScript {
    param(
        [string]$Server,
        [string]$Database,
        [string]$ScriptPath
    )

    $scriptName = Split-Path $ScriptPath -Leaf

    # --- Validate that script file exists ---
    if (-not (Test-Path $ScriptPath)) {
        Exec-LogText "FAIL | Script not found: $ScriptPath"
        $start = Get-Date; $end = Get-Date
        Exec-LogCsvRow $Server $Database $scriptName 0 "FAILED" $start $end "Script file not found" ""
        $Global:FileResults += [PSCustomObject]@{ Script = $scriptName; Database = $Database; Status = "FAILED" }
        return
    }

    # --- Read file and split batches on GO lines ---
    $content = Get-Content $ScriptPath -Raw
    $batches = $content -split "(?im)^\s*GO\s*$"

    $batchNo    = 0
    $fileFailed = $false

    Exec-LogText "START FILE | $scriptName | Initial DB: $Database"

    foreach ($batch in $batches) {
        if ([string]::IsNullOrWhiteSpace($batch)) { continue }

        $batchNo++
        $attempt = 0
        $success = $false

        # Determine where this batch should run (master or a specific DB)
        $batchDb = Get-BatchTargetDatabase -BatchText $batch -DefaultDb "master"

        # --- Retry loop for transient execution failures ---
        while (-not $success -and $attempt -lt $MaxRetry) {
            $attempt++
            $start = Get-Date

            try {
                # This script targets Azure VM SQL Server (IaaS); token-based access is unsupported
                if ($UseAccessToken) {
                    throw "UseAccessToken=true is not supported for Azure VM SQL Server. Set UseAccessToken=false."
                }

                Invoke-SqlcmdTarget -Server $Server -Database $batchDb `
                                    -Query $batch -Credential $TargetSqlCredential

                $end = Get-Date
                Exec-LogText "OK | $scriptName | Batch $batchNo | DB: $batchDb | Attempt $attempt"
                Exec-LogCsvRow $Server $batchDb $scriptName $batchNo "SUCCESS" $start $end "" $batch
                $success = $true
            }
            catch {
                $end = Get-Date
                $err = $_.Exception.Message

                Exec-LogText "RETRY $attempt/$MaxRetry | $scriptName | Batch $batchNo | DB: $batchDb | $err"

                if ($attempt -eq $MaxRetry) {
                    Exec-LogText "FAIL | $scriptName | Batch $batchNo | DB: $batchDb"
                    Exec-LogCsvRow $Server $batchDb $scriptName $batchNo "FAILED" $start $end $err $batch
                    $fileFailed = $true
                    break
                }
                else {
                    Start-Sleep -Seconds 3
                }
            }
        }

        #if ($fileFailed) { break }
    }

    # Record overall file status for summary
    $Global:FileResults += [PSCustomObject]@{
        Script   = $scriptName
        Database = "(mixed)"
        Status   = if ($fileFailed) { "FAILED" } else { "SUCCESS" }
    }

    Exec-LogText "END FILE | $scriptName | Status: $(if ($fileFailed) { 'FAILED' } else { 'SUCCESS' })"
}

#endregion




# =========================================================================
# INVOKE-TARGETEXECUTION
# =========================================================================
# Orchestrator that wires the generation result into the execution engine,
# sets up execution-specific log paths, and triggers the script executor.
# =========================================================================

function Invoke-TargetExecution {
    param(
        [hashtable]$GenResult,
        [string]$SourceServer,
        [string]$TargetServer,
        [string]$ComponentName
    )

    # Propagate generation metadata into script scope
    $script:RunId        = $GenResult.RunId
    $script:RunLogFolder = $GenResult.RunLogFolder
    $script:OutputFile   = $GenResult.OutputFile

    # Execution log file paths
    $script:ExecTextLog = Join-Path $RunLogFolder "ExecutionLog.txt"
    $script:ExecCsvLog  = Join-Path $RunLogFolder "ExecutionLog.csv"
    $script:ExecSummary = Join-Path $RunLogFolder "ExecutionSummary.txt"

    $script:TargetServerInstance = $TargetServer
    $script:SourceServerInstance = $SourceServer

    $Global:FileResults = @()

    Exec-LogText "===== Starting TARGET execution ($ComponentName) ====="
    Exec-LogText "Run folder: $RunLogFolder"
    Exec-LogText "Target: $TargetServerInstance"
    Exec-LogText "Executing SQL: $OutputFile"

    Execute-SqlScript -Server $TargetServerInstance -Database "master" -ScriptPath $OutputFile

    Write-Summary

    Exec-LogText "DONE | $ComponentName target execution completed."
    Exec-LogText "Execution log: $ExecTextLog"
    Exec-LogText "Batch CSV log: $ExecCsvLog"

    # Propagate batch-level failures to caller
    $failedFiles = @($Global:FileResults | Where-Object { $_.Status -eq "FAILED" })
    if ($failedFiles.Count -gt 0) {
        $failedNames = ($failedFiles | Select-Object -ExpandProperty Script) -join ", "
        Write-Log "===== $ComponentName Execution Completed with FAILURES =====" "ERROR"
        return @{ Status = "FAILED"; ErrorMessage = "Batch execution failed in: $failedNames" }
    }

    Write-Log "===== $ComponentName Execution Completed =====" "SUCCESS"
    return @{ Status = "SUCCESS"; ErrorMessage = "" }
}



# #########################################################################
#
#  END OF HELPER MODULE
#
# #########################################################################


# #########################################################################
#
#  GENERATE-SQLLOGINS FUNCTION
#
#  Connects to the source SQL Server, extracts all security objects
#  (Windows/AD logins, SQL logins with hashed passwords, server roles,
#  server permissions, database users, database roles, database
#  permissions, and MSDB agent permissions), and writes a single
#  idempotent T-SQL migration script.
#
#  When -Unfiltered is specified, ALL principals are included (no
#  system-account exclusions, no AD-existence checks) and the output
#  file is suffixed with _ALL.
#
# #########################################################################


function Generate-SQLLogins {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceServerName,

        [Parameter(Mandatory = $true)]
        [string[]]$DatabaseList,

        [Parameter(Mandatory = $true)]
        [string]$Component,

        [Parameter(Mandatory = $true)]
        [string]$BaseFolder,

        [ValidateSet("All", "Server", "Database")]
        [string]$Scope = "All",

        [switch]$Unfiltered
    )

    #region ===================== CONFIGURATION ===========================

    $SourceServerInstance = $SourceServerName

    # Execution controls (local overrides)
    $EnableTranscript = $true

    # Unfiltered mode: override scope to capture ALL server + database objects
    if ($Unfiltered) { $Scope = "All" }

    #endregion

    #region ===================== OUTPUT / PATH SETUP =====================

    $ComponentFolder = Join-Path $BaseFolder $Component
    New-Item -ItemType Directory -Path $ComponentFolder -Force | Out-Null

    $ShortName      = (($SourceServerName -split '\.')[0] -replace '[\\/:*?"<>|]', '_')
    $CleanComponent = $Component -replace '\s+', ''
    $suffix         = if ($Unfiltered) { "_ALL" } else { "" }
    $OutputFile     = Join-Path $ComponentFolder "$($ShortName)_$CleanComponent$suffix.sql"

    # Delete existing output file if present (idempotent regeneration)
    if (Test-Path $OutputFile) {
        Remove-Item $OutputFile -Force
        Write-Log "Existing output file deleted: $OutputFile" "WARN"
    }
    else {
        Write-Log "No existing output file found. A new file will be created: $OutputFile" "INFO"
    }

    #endregion

    #region ===================== LOG FOLDER SETUP ========================

    $LogsRoot     = Join-Path $ComponentFolder "Logs"
    New-Item -ItemType Directory -Path $LogsRoot -Force | Out-Null

    $RunId        = Get-Date -Format "yyyyMMdd_HHmmss"
    $RunLogFolder = Join-Path $LogsRoot $RunId
    New-Item -ItemType Directory -Path $RunLogFolder -Force | Out-Null

    # Generation log files
    $logSuffix      = if ($Unfiltered) { "_ALL" } else { "" }
    $LogFile        = Join-Path $RunLogFolder "SecurityMigration_Generate$logSuffix.log"
    $TranscriptFile = Join-Path $RunLogFolder "Transcript$logSuffix.txt"

    # Set the script-scoped active log file so Write-Log writes to disk
    $script:ActiveLogFile = $LogFile

    #endregion

    #region ===================== SQL SCRIPT STRING BUILDER ================

    $script:sb = New-Object System.Text.StringBuilder
    $itemCount = 0


    #endregion

    #region ===================== CONDITIONAL FILTERS =====================

    $serverPrincipalFilter = if ($Unfiltered) { "" } else { @"

  AND name NOT LIKE '##%'
  AND name NOT LIKE 'NT SERVICE\%'
  AND name NOT IN ('sa','BUILTIN\Administrators','NT AUTHORITY\SYSTEM')
"@ }

    $sqlLoginFilter = if ($Unfiltered) { "" } else { @"

  AND name NOT LIKE '##%'
  AND name NOT LIKE 'NT SERVICE\%'
  AND name NOT IN ('sa','BUILTIN\Administrators','NT AUTHORITY\SYSTEM')
"@ }

    $memberFilter = if ($Unfiltered) { "" } else { @"

  AND m.name NOT LIKE '##%'
  AND m.name NOT LIKE 'NT SERVICE\%'
  AND m.name NOT IN ('sa','BUILTIN\Administrators','NT AUTHORITY\SYSTEM')
"@ }

    $spFilter = if ($Unfiltered) { "" } else { @"

  AND sp.name NOT LIKE '##%'
  AND sp.name NOT LIKE 'NT SERVICE\%'
  AND sp.name NOT IN ('sa','BUILTIN\Administrators','NT AUTHORITY\SYSTEM')
"@ }

    $dbPrincipalFilter = if ($Unfiltered) { "" } else { @"

  AND dp.name NOT LIKE '##%'
  AND dp.name NOT LIKE 'NT SERVICE\%'
  AND dp.name NOT IN ('sa','BUILTIN\Administrators','NT AUTHORITY\SYSTEM','dbo','guest','sys','INFORMATION_SCHEMA')
"@ }

    #endregion

    # --- Start transcript ---
    if ($EnableTranscript) {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
        try {
            Start-Transcript -Path $TranscriptFile -ErrorAction Stop | Out-Null
            Write-Log "Transcript started: $TranscriptFile" "INFO"
        }
        catch {
            Write-Log "Failed to start transcript. Error: $($_.Exception.Message)" "WARN"
        }
    }

    $ScriptStart = Get-Date
    $modeLabel = if ($Unfiltered) { "UNFILTERED (ALL)" } else { "FILTERED" }
    Write-Log "===== SQL Logins Generation Started ($modeLabel) ====="
    Write-Log "===== Script started. RunId folder: $RunLogFolder =====" "INFO"
    Write-Log "Source: $SourceServerInstance"                             "INFO"
    Write-Log "Output SQL file: $OutputFile"                             "INFO"
    Write-Log "Databases requested: $($DatabaseList -join ', ')"         "INFO"
    Write-Log "Scope: $Scope"                                            "INFO"

    # =====================================================================
    # PHASE 1: SERVER-LEVEL OBJECTS
    # =====================================================================

    if ($Scope -in @("All", "Server", "Database")) {

        Write-Log "Scope=${Scope}: Including server-level objects (logins, server roles, server permissions)." "INFO"

        #region --- WINDOWS / AD LOGINS ---

        Add-SectionHeader "WINDOWS / AD LOGINS"
        Write-Log "Starting section: WINDOWS / AD LOGINS" "INFO"

        $winLogins = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database "master" `
            -Context "Fetch Windows/AD logins" -Query @"
SELECT name
FROM sys.server_principals
WHERE type IN ('U','G')$serverPrincipalFilter
"@

        if ($winLogins) {
            foreach ($row in $winLogins) {
                $n = $row.name

                if (-not $Unfiltered -and $n -like "*\*" -and -not (Test-ADPrincipalExists $n)) {
                    Write-Log "Skipping deleted AD login: $n" "WARN"
                    continue
                }

                $nLit = Escape-SqlLiteral $n
                $nBr  = Escape-SqlBracket $n

                Add-Sql "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$nLit')"
                Add-Sql "BEGIN"
                Add-Sql "    CREATE LOGIN [$nBr] FROM WINDOWS;"
                Add-Sql "END"
                Add-Sql "GO"
                $itemCount++
            }
        }

        #endregion

        #region --- SQL LOGINS (PASSWORD HASH + SID) ---

        Add-SectionHeader "SQL LOGINS"
        Write-Log "Starting section: SQL LOGINS" "INFO"

        $sqlLogins = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database "master" `
            -Context "Fetch SQL logins" -Query @"
SELECT name, sid, is_policy_checked, is_expiration_checked,
       LOGINPROPERTY(name,'PasswordHash') AS password_hash
FROM sys.sql_logins
WHERE 1=1$sqlLoginFilter
"@

        if ($sqlLogins) {
            foreach ($row in $sqlLogins) {
                if (-not $row.password_hash) { continue }

                $sidHex      = Convert-BytesToHex $row.sid
                $pwdHashHex  = Convert-BytesToHex $row.password_hash
                $checkPolicy = if ($row.is_policy_checked -eq 1)    { "ON" } else { "OFF" }
                $checkExp    = if ($row.is_expiration_checked -eq 1) { "ON" } else { "OFF" }

                $nLit = Escape-SqlLiteral $row.name
                $nBr  = Escape-SqlBracket $row.name

                Add-Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$nLit')
BEGIN
    CREATE LOGIN [$nBr]
    WITH PASSWORD = $pwdHashHex HASHED,
         SID = $sidHex,
         CHECK_POLICY = $checkPolicy,
         CHECK_EXPIRATION = $checkExp;
END
GO
"@
                $itemCount++
            }
        }

        #endregion

        #region --- SERVER ROLE MEMBERSHIP ---

        Add-SectionHeader "SERVER ROLE MEMBERSHIP"
        Write-Log "Starting section: SERVER ROLE MEMBERSHIP" "INFO"

        $roleMembers = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database "master" `
            -Context "Fetch server role membership" -Query @"
SELECT r.name AS RoleName, m.name AS MemberName
FROM sys.server_role_members rm
JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id
WHERE m.type IN ('S','U','G')$memberFilter
"@

        if ($roleMembers) {
            foreach ($rm in $roleMembers) {
                $role = $rm.RoleName
                $mem  = $rm.MemberName

                if (-not $Unfiltered -and $mem -like "*\*" -and -not (Test-ADPrincipalExists $mem)) {
                    Write-Log "Skipping deleted AD server role member: $mem" "WARN"
                    continue
                }

                $roleLit = Escape-SqlLiteral $role
                $memLit  = Escape-SqlLiteral $mem
                $roleBr  = Escape-SqlBracket $role
                $memBr   = Escape-SqlBracket $mem

                Add-Sql @"
IF NOT EXISTS (
    SELECT 1
    FROM sys.server_role_members rm
    JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
    JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id
    WHERE r.name = N'$roleLit' AND m.name = N'$memLit'
)
BEGIN
    ALTER SERVER ROLE [$roleBr] ADD MEMBER [$memBr];
END
GO
"@
                $itemCount++
            }
        }

        #endregion

        #region --- SERVER PERMISSIONS ---

        Add-SectionHeader "SERVER PERMISSIONS"
        Write-Log "Starting section: SERVER PERMISSIONS" "INFO"

        $serverPerms = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database "master" `
            -Context "Fetch server permissions" -Query @"
SELECT sp.name, perm.permission_name
FROM sys.server_permissions perm
JOIN sys.server_principals sp ON perm.grantee_principal_id = sp.principal_id
WHERE sp.type IN ('S','U','G')$spFilter
"@

        if ($serverPerms) {
            foreach ($p in $serverPerms) {
                $principal = $p.name
                $permName  = $p.permission_name

                if (-not $Unfiltered -and $principal -like "*\*" -and -not (Test-ADPrincipalExists $principal)) {
                    Write-Log "Skipping deleted AD server permission principal: $principal" "WARN"
                    continue
                }

                $pLit    = Escape-SqlLiteral $principal
                $permLit = Escape-SqlLiteral $permName
                $pBr     = Escape-SqlBracket $principal

                Add-Sql @"
IF NOT EXISTS (
    SELECT 1
    FROM sys.server_permissions perm
    JOIN sys.server_principals sp ON perm.grantee_principal_id = sp.principal_id
    WHERE perm.permission_name = N'$permLit' AND sp.name = N'$pLit'
)
BEGIN
    GRANT $permName TO [$pBr];
END
GO
"@
                $itemCount++
            }
        }

        #endregion

    }

    # =====================================================================
    # PHASE 2: DATABASE SELECTION
    # =====================================================================

    Write-Log "Resolving database list (ONLINE DBs including system DBs filtered by DatabaseList)..." "INFO"

    $allDbList = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database "master" `
        -Context "Fetch ONLINE databases including system DBs" -Query @"
SELECT name
FROM sys.databases
WHERE state_desc = 'ONLINE'
"@

    $SecurityDatabaseNames = @(Get-ServerObjectSecurityDatabaseNames -AvailableNames @($allDbList.name) `
        -DatabaseList $DatabaseList -Scope $Scope)
    $dbList = @($allDbList | Where-Object { $_.name -in $SecurityDatabaseNames })
    Write-Log "Security scope=$Scope; databases selected: $($SecurityDatabaseNames -join ', ')" "INFO"

    # =====================================================================
    # PHASE 3: DATABASE-LEVEL OBJECTS
    # =====================================================================

    foreach ($db in $dbList.name) {
        Write-Log "===== Starting DB: $db =====" "INFO"
        try {

            #region --- DB USERS (MAPPED TO SERVER LOGINS) ---

            Add-SectionHeader "DATABASE USERS - MAPPED TO LOGINS" $db

            $dbMappedUsers = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch DB users mapped to server logins" -ContinueOnError -Query @"
SELECT dp.name AS UserName, sp.name AS LoginName
FROM sys.database_principals dp
JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.type IN ('S','U','G')$dbPrincipalFilter
"@

            if ($dbMappedUsers) {
                foreach ($u in $dbMappedUsers) {
                    $userName  = $u.UserName
                    $loginName = $u.LoginName

                    if (-not $Unfiltered -and $loginName -like "*\*" -and -not (Test-ADPrincipalExists $loginName)) {
                        Write-Log "Skipping deleted AD mapped user: $userName (Login: $loginName, DB: $db)" "WARN"
                        continue
                    }

                    $userLit  = Escape-SqlLiteral $userName
                    $userBr   = Escape-SqlBracket $userName
                    $loginLit = Escape-SqlLiteral $loginName
                    $loginBr  = Escape-SqlBracket $loginName

                    Add-Sql "USE [$db]; IF NOT EXISTS(SELECT 1 FROM sys.database_principals WHERE name = N'$userLit') CREATE USER [$userBr] FOR LOGIN [$loginBr];"
                    Add-Sql "GO"
                    $itemCount++
                }
            }

            #endregion

            #region --- DB-ONLY USERS (WITHOUT LOGIN) ---

            Add-SectionHeader "DATABASE USERS - DB ONLY" $db

            $dbOnlyUsers = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch DB-only users" -ContinueOnError -Query @"
SELECT dp.name AS UserName
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.type IN ('S','U','G')
  AND sp.name IS NULL$dbPrincipalFilter
"@

            if ($dbOnlyUsers) {
                foreach ($u in $dbOnlyUsers) {
                    $userName = $u.UserName

                    if (-not $Unfiltered -and $userName -like "*\*" -and -not (Test-ADPrincipalExists $userName)) {
                        Write-Log "Skipping deleted AD DB-only user: $userName (DB: $db)" "WARN"
                        continue
                    }

                    $userLit = Escape-SqlLiteral $userName
                    $userBr  = Escape-SqlBracket $userName

                    Add-Sql "USE [$db]; IF NOT EXISTS(SELECT 1 FROM sys.database_principals WHERE name = N'$userLit') CREATE USER [$userBr] WITHOUT LOGIN;"
                    Add-Sql "GO"
                    $itemCount++
                }
            }

            #endregion

            #region --- DB ROLE MEMBERSHIP ---

            Add-SectionHeader "DATABASE ROLE MEMBERSHIP" $db

            $dbRoleMembers = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch DB role membership" -ContinueOnError -Query @"
SELECT dr.name AS RoleName, dp.name AS UserName
FROM sys.database_role_members drm
JOIN sys.database_principals dr ON drm.role_principal_id = dr.principal_id
JOIN sys.database_principals dp ON drm.member_principal_id = dp.principal_id
WHERE dp.type IN ('S','U','G')$dbPrincipalFilter
"@

            if ($dbRoleMembers) {
                foreach ($m in $dbRoleMembers) {
                    $role = $m.RoleName
                    $user = $m.UserName

                    if (-not $Unfiltered -and $user -like "*\*" -and -not (Test-ADPrincipalExists $user)) {
                        Write-Log "Skipping deleted AD role member: $user (DB: $db)" "WARN"
                        continue
                    }

                    $roleLit = Escape-SqlLiteral $role
                    $userLit = Escape-SqlLiteral $user
                    $roleBr  = Escape-SqlBracket $role
                    $userBr  = Escape-SqlBracket $user

                    Add-Sql @"
USE [$db];
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals dr ON drm.role_principal_id = dr.principal_id
    JOIN sys.database_principals dp ON drm.member_principal_id = dp.principal_id
    WHERE dr.name = N'$roleLit' AND dp.name = N'$userLit'
)
BEGIN
    ALTER ROLE [$roleBr] ADD MEMBER [$userBr];
END
GO
"@
                    $itemCount++
                }
            }

            #endregion

            #region --- DB PERMISSIONS (CONNECT + OBJECT LEVEL) ---

            Add-SectionHeader "DATABASE PERMISSIONS" $db

            # --- CONNECT permission for each database principal ---
            $dbPrincipals = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch DB principals" -ContinueOnError -Query @"
SELECT dp.name
FROM sys.database_principals dp
WHERE dp.type IN ('S','U','G')$dbPrincipalFilter
"@

            if ($dbPrincipals) {
                foreach ($principal in $dbPrincipals) {
                    $pname = $principal.name
                    if (-not $Unfiltered -and $pname -like "*\*" -and -not (Test-ADPrincipalExists $pname)) { continue }

                    $pLit = Escape-SqlLiteral $pname
                    $pBr  = Escape-SqlBracket $pname

                    Add-Sql "USE [$db]; IF NOT EXISTS(SELECT 1 FROM sys.database_permissions WHERE grantee_principal_id = USER_ID(N'$pLit') AND permission_name='CONNECT') GRANT CONNECT TO [$pBr];"
                    Add-Sql "GO"
                    $itemCount++
                }
            }

            # --- Object-level permissions ---
            $objPerms = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch object-level permissions" -ContinueOnError -Query @"
SELECT dp.name, perm.permission_name,
       SCHEMA_NAME(o.schema_id) AS SchemaName,
       o.name AS ObjName
FROM sys.database_permissions perm
JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id
JOIN sys.objects o ON perm.major_id = o.object_id
WHERE dp.type IN ('S','U','G')$dbPrincipalFilter
  AND perm.class_desc = 'OBJECT_OR_COLUMN'
"@

            if ($objPerms) {
                foreach ($op in $objPerms) {
                    $pname = $op.name
                    if (-not $Unfiltered -and $pname -like "*\*" -and -not (Test-ADPrincipalExists $pname)) { continue }

                    $perm = $op.permission_name
                    $sch  = $op.SchemaName
                    $obj  = $op.ObjName

                    $pLit    = Escape-SqlLiteral $pname
                    $pBr     = Escape-SqlBracket $pname
                    $permLit = Escape-SqlLiteral $perm

                    if ([string]::IsNullOrWhiteSpace($sch) -or [string]::IsNullOrWhiteSpace($obj)) {
                        Add-Sql "USE [$db]; IF NOT EXISTS(SELECT 1 FROM sys.database_permissions WHERE grantee_principal_id = USER_ID(N'$pLit') AND permission_name=N'$permLit') GRANT $perm TO [$pBr];"
                        Add-Sql "GO"
                        $itemCount++
                    }
                    else {
                        $schBr = Escape-SqlBracket $sch
                        $objBr = Escape-SqlBracket $obj

                        Add-Sql @"
USE [$db];
IF OBJECT_ID(N'[$schBr].[$objBr]') IS NOT NULL
AND NOT EXISTS(
    SELECT 1
    FROM sys.database_permissions
    WHERE grantee_principal_id = USER_ID(N'$pLit')
      AND permission_name = N'$permLit'
      AND major_id = OBJECT_ID(N'[$schBr].[$objBr]')
)
BEGIN
    GRANT $perm ON [$schBr].[$objBr] TO [$pBr];
END
GO
"@
                        $itemCount++
                    }
                }
            }

            #endregion

            #region --- MSDB SQL AGENT PERMISSIONS ---

            if ($db -eq "msdb") {
                Add-SectionHeader "MSDB SQL AGENT PERMISSIONS" $db
                Write-Log "Fetching comprehensive SQL Agent permissions (msdb)" "INFO"

                $agentProcPerms = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                    -Context "Fetch SQL Agent procedure permissions" -ContinueOnError -Query @"
SELECT
    USER_NAME(grantee_principal_id) AS PrincipalName,
    OBJECT_NAME(major_id) AS ProcName,
    permission_name
FROM sys.database_permissions
WHERE major_id IN (
    OBJECT_ID('dbo.sp_start_job'),
    OBJECT_ID('dbo.sp_stop_job'),
    OBJECT_ID('dbo.sp_delete_job'),
    OBJECT_ID('dbo.sp_add_job'),
    OBJECT_ID('dbo.sp_update_job'),
    OBJECT_ID('dbo.sp_help_job'),
    OBJECT_ID('dbo.sp_help_jobhistory'),
    OBJECT_ID('dbo.sp_add_jobstep'),
    OBJECT_ID('dbo.sp_update_jobstep'),
    OBJECT_ID('dbo.sp_delete_jobstep'),
    OBJECT_ID('dbo.sp_add_jobschedule'),
    OBJECT_ID('dbo.sp_update_jobschedule'),
    OBJECT_ID('dbo.sp_delete_jobschedule')
)
AND permission_name = 'EXECUTE'
"@

                if ($agentProcPerms) {
                    foreach ($perm in $agentProcPerms) {
                        $principal = $perm.PrincipalName
                        $proc      = $perm.ProcName

                        $pLit   = Escape-SqlLiteral $principal
                        $pBr    = Escape-SqlBracket $principal
                        $procBr = Escape-SqlBracket $proc

                        Add-Sql @"
USE [msdb];
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_permissions
    WHERE grantee_principal_id = USER_ID(N'$pLit')
      AND permission_name = 'EXECUTE'
      AND major_id = OBJECT_ID(N'dbo.$proc')
)
BEGIN
    GRANT EXECUTE ON [dbo].[$procBr] TO [$pBr];
END
GO
"@
                        $itemCount++
                    }
                }

                $jobPermFilter = if ($Unfiltered) { "" } else { @"

  AND USER_NAME(grantee_principal_id) NOT LIKE '##%'
  AND USER_NAME(grantee_principal_id) NOT LIKE 'NT SERVICE\%'
  AND USER_NAME(grantee_principal_id) NOT IN ('sa','BUILTIN\Administrators','NT AUTHORITY\SYSTEM','dbo','guest','sys','INFORMATION_SCHEMA')
"@ }

                $jobPerms = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                    -Context "Fetch SQL Agent job permissions" -ContinueOnError -Query @"
SELECT
    USER_NAME(grantee_principal_id) AS PrincipalName,
    perm.permission_name
FROM sys.database_permissions perm
WHERE perm.class_desc = 'JOB'$jobPermFilter
"@

                if ($jobPerms) {
                    foreach ($jp in $jobPerms) {
                        $principal = $jp.PrincipalName
                        $perm      = $jp.permission_name

                        $pLit    = Escape-SqlLiteral $principal
                        $pBr     = Escape-SqlBracket $principal
                        $permLit = Escape-SqlLiteral $perm

                        Add-Sql @"
USE [msdb];
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_permissions perm
    WHERE perm.grantee_principal_id = USER_ID(N'$pLit')
      AND perm.permission_name = N'$permLit'
      AND perm.class_desc = 'JOB'
)
BEGIN
    GRANT $perm ON msdb.dbo.sysjobs TO [$pBr];
END
GO
"@
                        $itemCount++
                    }
                }
            }

            #endregion

            Write-Log "===== Completed DB: $db =====" "INFO"
        }
        catch {
            Write-Log "DB [$db] failed with error: $($_.Exception.Message). Continuing." "ERROR"
            continue
        }
    }

    # =====================================================================
    # WRITE GENERATED SQL TO FILE
    # =====================================================================

    if ($itemCount -eq 0) {
        Write-Log "No SQL security items found on source server. No output file written." "WARN"
    }
    else {
        try {
            [System.IO.File]::WriteAllText($OutputFile, $script:sb.ToString(), [System.Text.Encoding]::UTF8)
            Write-Log "SQL migration script written successfully: $OutputFile ($itemCount item(s))" "INFO"
        }
        catch {
            Write-Log "FAILED to write SQL output file: $OutputFile. Error: $($_.Exception.Message)" "ERROR"
            throw
        }
    }

    $elapsed = New-TimeSpan -Start $ScriptStart -End (Get-Date)
    Write-Log "===== Generation completed ($modeLabel). Duration: $($elapsed.ToString()) =====" "INFO"

    if ($EnableTranscript) {
        try { Stop-Transcript | Out-Null } catch {}
    }

    Write-Log "===== SQL Security Migration Script Generation Completed ($modeLabel) =====" "SUCCESS"

    $script:ActiveLogFile = $null

    Write-Host "  SQL File  : $OutputFile"   -ForegroundColor Cyan
    Write-Host "  Logs      : $RunLogFolder" -ForegroundColor Cyan

    return @{
        RunId        = $RunId
        RunLogFolder = $RunLogFolder
        OutputFile   = $OutputFile
        ItemCount    = $itemCount
    }
}


# #########################################################################
#
#  GENERATE-SQLOPERATORS FUNCTION
#
#  Reads operator definitions from the source server's msdb database
#  and generates an idempotent T-SQL script that creates or updates
#  SQL Agent operators on the target.
#
#  When -Unfiltered is specified the output file is suffixed with _ALL.
#  (Operators already fetches all rows no query filters to remove.)
#
# #########################################################################

function Generate-SQLOperators {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceServerName,

        [Parameter(Mandatory = $true)]
        [string]$BaseFolder,

        [Parameter(Mandatory = $true)]
        [string]$Component,

        [switch]$Unfiltered
    )

    # =====================================================================
    # OUTPUT FOLDER STRUCTURE
    # =====================================================================

    $ComponentFolder = Join-Path $BaseFolder $Component
    New-Item -ItemType Directory -Path $ComponentFolder -Force | Out-Null

    $ShortName      = (($SourceServerName -split '\.')[0] -replace '[\\/:*?"<>|]', '_')
    $CleanComponent = $Component -replace '\s+', ''
    $suffix         = if ($Unfiltered) { "_ALL" } else { "" }
    $OutputFile     = Join-Path $ComponentFolder "$($ShortName)_$CleanComponent$suffix.sql"

    if (Test-Path $OutputFile) {
        Remove-Item $OutputFile -Force
        Write-Log "Existing output file deleted: $OutputFile" "WARN"
    }
    else {
        Write-Log "No existing output file found. A new file will be created: $OutputFile" "INFO"
    }

    # =====================================================================
    # LOG + TRANSCRIPT SETUP
    # =====================================================================

    $LogsRoot     = Join-Path $ComponentFolder "Logs"
    New-Item -ItemType Directory -Path $LogsRoot -Force | Out-Null

    $RunId        = Get-Date -Format "yyyyMMdd_HHmmss"
    $RunLogFolder = Join-Path $LogsRoot $RunId
    New-Item -ItemType Directory -Path $RunLogFolder -Force | Out-Null

    $logSuffix      = if ($Unfiltered) { "_ALL" } else { "" }
    $LogFile        = Join-Path $RunLogFolder "SQLOperators_Generate$logSuffix.log"
    $TranscriptFile = Join-Path $RunLogFolder "Transcript$logSuffix.txt"

    $script:ActiveLogFile = $LogFile

    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    try {
        Start-Transcript -Path $TranscriptFile -ErrorAction Stop | Out-Null
        Write-Log "Transcript started: $TranscriptFile" "INFO"
    }
    catch {
        Write-Log "Failed to start transcript. Error: $($_.Exception.Message)" "WARN"
    }
    $ScriptStart = Get-Date
    $modeLabel = if ($Unfiltered) { "UNFILTERED (ALL)" } else { "FILTERED" }
    Write-Log "===== SQL Operators Generation Started ($modeLabel) ====="
    Write-Log "Source      : $SourceServerName"
    Write-Log "Output File : $OutputFile"

    # =====================================================================
    # FETCH OPERATORS FROM SOURCE SERVER
    # =====================================================================

    $operators = Invoke-SqlcmdLogged `
        -ServerInstance $SourceServerName `
        -Database "msdb" `
        -Context "Fetch SQL Agent Operators" `
        -Query @"
SELECT name, enabled, email_address
FROM msdb.dbo.sysoperators
ORDER BY name
"@

   if (-not $operators -or @($operators).Count -eq 0) {
        Write-Log "No operators found on source server. Skipping..." "WARN"
        try { Stop-Transcript | Out-Null } catch {}
        $script:ActiveLogFile = $null
       return @{
    RunId        = $RunId
    RunLogFolder = $RunLogFolder
    OutputFile   = $OutputFile
    ItemCount    = 0
}
    }

    Write-Log "Found $(@($operators).Count) operator(s) on source server" "INFO"

    # =====================================================================
    # SQL BUILDER
    # =====================================================================

    $script:sb = New-Object System.Text.StringBuilder

    Add-Sql "/* ========================================================="
    Add-Sql "   SQL Agent Operators Script ($modeLabel)"
    Add-Sql "   Source      : $SourceServerName"
    Add-Sql "   Generated   : $(Get-Date)"
    Add-Sql "========================================================= */"
    Add-Sql ""

    # =====================================================================
    # GENERATE OPERATORS
    # =====================================================================

    foreach ($op in $operators) {

    $opName  = if ($op.name -eq 'MSXOperator') { 'DBA_Notifications' } else { $op.name }
    $name    = Escape-SqlLiteral $opName
    $email   = if ($op.email_address) { Escape-SqlLiteral $op.email_address } else { "" }
    $enabled = if ($op.enabled -eq 1) { 1 } else { 0 }

    if ($op.name -eq 'MSXOperator') {
        Write-Log "Renaming operator 'MSXOperator' -> 'DBA_Notifications'" "WARN"
    }
    Write-Log "Generating operator: $opName"

        Add-Sql "USE [msdb];"
        Add-Sql "IF EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N'$name')"
        Add-Sql "BEGIN"
        Add-Sql "    EXEC msdb.dbo.sp_update_operator"
        Add-Sql "        @name = N'$name',"
        Add-Sql "        @enabled = $enabled,"
        Add-Sql "        @email_address = N'$email';"
        Add-Sql "END"
        Add-Sql "ELSE"
        Add-Sql "BEGIN"
        Add-Sql "    EXEC msdb.dbo.sp_add_operator"
        Add-Sql "        @name = N'$name',"
        Add-Sql "        @enabled = $enabled,"
        Add-Sql "        @email_address = N'$email';"
        Add-Sql "END"
        Add-Sql "GO"
        Add-Sql ""
    }

    # =====================================================================
    # WRITE FILE
    # =====================================================================

    $script:sb.ToString() | Out-File -FilePath $OutputFile -Encoding UTF8
    $elapsed = New-TimeSpan -Start $ScriptStart -End (Get-Date)
    Write-Log "SQL Operators script generated successfully ($modeLabel). Duration: $($elapsed.ToString())"
    Write-Log "File: $OutputFile"

    try { Stop-Transcript | Out-Null } catch {}

    Write-Log "===== SQL Operators Generation Completed ($modeLabel) =====" "SUCCESS"
    $script:ActiveLogFile = $null

    return @{
    RunId        = $RunId
    RunLogFolder = $RunLogFolder
    OutputFile   = $OutputFile
    ItemCount    = @($operators).Count
}
}

# #########################################################################
#
#  GENERATE-SQLALERTS FUNCTION
#
#  Connects to the source server's msdb database, reads all configured
#  SQL Agent alerts, and generates an idempotent T-SQL script that
#  creates or updates each alert on the target.
#
#  When -Unfiltered is specified the output file is suffixed with _ALL.
#  (Alerts already fetches all rows no query filters to remove.)
#
# #########################################################################


function Generate-SQLAlerts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceServerName,

        [Parameter(Mandatory = $true)]
        [string]$Component,

        [Parameter(Mandatory = $true)]
        [string]$BaseFolder,

        [switch]$Unfiltered
    )

    # =====================================================================
    # OUTPUT FOLDER
    # =====================================================================

    $ComponentFolder = Join-Path $BaseFolder $Component
    New-Item -ItemType Directory -Path $ComponentFolder -Force | Out-Null

    $ShortName      = (($SourceServerName -split '\.')[0] -replace '[\\/:*?"<>|]', '_')
    $CleanComponent = $Component -replace '\s+', ''
    $suffix         = if ($Unfiltered) { "_ALL" } else { "" }
    $OutputFile     = Join-Path $ComponentFolder "$($ShortName)_$CleanComponent$suffix.sql"

    if (Test-Path $OutputFile) {
        Remove-Item $OutputFile -Force
        Write-Log "Existing file deleted: $OutputFile" "WARN"
    }

    # =====================================================================
    # LOG SETUP
    # =====================================================================

    $LogsRoot     = Join-Path $ComponentFolder "Logs"
    $RunId        = Get-Date -Format "yyyyMMdd_HHmmss"
    $RunLogFolder = Join-Path $LogsRoot $RunId

    New-Item -ItemType Directory -Path $RunLogFolder -Force | Out-Null

    $logSuffix      = if ($Unfiltered) { "_ALL" } else { "" }
    $LogFile        = Join-Path $RunLogFolder "SQLAlerts_Generate$logSuffix.log"
    $TranscriptFile = Join-Path $RunLogFolder "Transcript$logSuffix.txt"

    $script:ActiveLogFile = $LogFile

    # Start transcript (stop any prior one first)
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    try {
        Start-Transcript -Path $TranscriptFile -ErrorAction Stop | Out-Null
        Write-Log "Transcript started: $TranscriptFile" "INFO"
    }
    catch {
        Write-Log "Failed to start transcript. Error: $($_.Exception.Message)" "WARN"
    }
    $ScriptStart = Get-Date
    $modeLabel = if ($Unfiltered) { "UNFILTERED (ALL)" } else { "FILTERED" }
    Write-Log "===== SQL Alerts Generation Started ($modeLabel) ====="
    Write-Log "Source: $SourceServerName"
    Write-Log "Output: $OutputFile"

    # =====================================================================
    # FETCH ALERTS FROM SOURCE
    # =====================================================================

    $alerts = Invoke-SqlcmdLogged `
        -ServerInstance $SourceServerName `
        -Database "msdb" `
        -Context "Fetch SQL Alerts" `
        -Query @"
SELECT
    name,
    enabled,
    message_id,
    severity,
    database_name,
    delay_between_responses,
    performance_condition
FROM dbo.sysalerts
ORDER BY name
"@

    if (-not $alerts -or @($alerts).Count -eq 0) {
        Write-Log "No alerts found on source server. Skipping..." "WARN"
        try { Stop-Transcript | Out-Null } catch {}
        $script:ActiveLogFile = $null
        return @{
            RunId        = $RunId
            RunLogFolder = $RunLogFolder
            OutputFile   = $OutputFile
            ItemCount = 0
        }
    }

    # =====================================================================
    # SQL BUILDER
    # =====================================================================

    $script:sb = New-Object System.Text.StringBuilder

    # --- Header ---
    Add-Sql "/* ========================================================="
    Add-Sql "   SQL Agent Alerts Script ($modeLabel)"
    Add-Sql "   Source      : $SourceServerName"
    Add-Sql "   Generated   : $(Get-Date)"
    Add-Sql "========================================================= */"


    Add-Sql ""
    Add-Sql "/* ==================== SQL ALERTS ==================== */"
    Add-Sql ""

    # =====================================================================
    # GENERATE ALERTS
    # =====================================================================

    foreach ($a in $alerts) {

                $name  = Escape-SqlLiteral $a.name
        $nameB = Escape-SqlBracket $a.name

        $enabled   = if ($a.enabled -eq 1) { 1 } else { 0 }
        $messageId = if ($a.message_id)              { $a.message_id }              else { 0 }
        $severity  = if ($a.severity)                { $a.severity }                else { 0 }
        $dbName    = if ($a.database_name)           { "N'$(Escape-SqlLiteral $a.database_name)'" } else { "NULL" }
        $delay     = if ($a.delay_between_responses) { $a.delay_between_responses } else { 0 }
        $perfCond  = if ($a.performance_condition -and -not [string]::IsNullOrWhiteSpace($a.performance_condition)) {
                         "N'$(Escape-SqlLiteral $a.performance_condition)'"
                     } else { "NULL" }

        Write-Log "Processing alert: $name (msgId=$messageId, sev=$severity, perfCond=$perfCond)"

        Add-Sql @"
USE [msdb];
IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = N'$name')
BEGIN
    EXEC msdb.dbo.sp_update_alert
        @name = N'$name',
        @enabled = $enabled,
        @message_id = $messageId,
        @severity = $severity,
        @database_name = $dbName,
        @delay_between_responses = $delay,
        @performance_condition = $perfCond;
END
ELSE
BEGIN
    EXEC msdb.dbo.sp_add_alert
        @name = N'$name',
        @enabled = $enabled,
        @message_id = $messageId,
        @severity = $severity,
        @database_name = $dbName,
        @delay_between_responses = $delay,
        @performance_condition = $perfCond;
END
GO

"@
    }

    # =====================================================================
    # WRITE FILE
    # =====================================================================

    $script:sb.ToString() | Out-File -FilePath $OutputFile -Encoding UTF8
    $elapsed = New-TimeSpan -Start $ScriptStart -End (Get-Date)
    Write-Log "SQL Alerts script generated successfully ($modeLabel). Duration: $($elapsed.ToString())"
    Write-Log "File: $OutputFile"

    try { Stop-Transcript | Out-Null } catch {}
    Write-Log "===== SQL Alerts Generation Completed ($modeLabel) =====" "SUCCESS"
    $script:ActiveLogFile = $null

    return @{
        RunId        = $RunId
        RunLogFolder = $RunLogFolder
        OutputFile   = $OutputFile
        ItemCount = @($alerts).Count
    }
}


# #########################################################################
#
#  GENERATE-SQLAGENTJOBS FUNCTION
#
#  Connects to the source SQL Server via SMO, extracts SQL Agent jobs,
#  generates individual T-SQL creation scripts per job (for reference)
#  and a single combined idempotent migration script (for execution).
#
#  When -Unfiltered is specified:
#    - ALL jobs are included (not just enabled ones)
#    - Regex filter is skipped
#    - All databases are included
#    - Output file is suffixed with _ALL
#    - Individual scripts go into Jobs_ALL subfolder
#
# #########################################################################

function Generate-SQLAgentJobs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceServerName,

        [Parameter(Mandatory = $true)]
        [string[]]$DatabaseList,

        [string]$JobNameRegex = ".*",

        [Parameter(Mandatory = $true)]
        [string]$Component,

        [Parameter(Mandatory = $true)]
        [string]$BaseFolder,

        [switch]$Unfiltered
    )

    #region ===================== OUTPUT / PATH SETUP =====================

    $SourceServerInstance = $SourceServerName
    $EnableTranscript     = $true

    $ComponentFolder = Join-Path $BaseFolder $Component
    New-Item -ItemType Directory -Path $ComponentFolder -Force | Out-Null

    # Individual job scripts go into a Jobs or Jobs_ALL subfolder
    $jobSubName    = if ($Unfiltered) { "Jobs_ALL" } else { "Jobs" }
    $JobsSubFolder = Join-Path $ComponentFolder $jobSubName

    # Clean up previous individual job scripts
    if (Test-Path $JobsSubFolder) {
        Remove-Item -Path "$JobsSubFolder\*.sql" -Force -ErrorAction SilentlyContinue
        Write-Log "Cleared previous job scripts from: $JobsSubFolder" "WARN"
    }

    New-Item -ItemType Directory -Path $JobsSubFolder -Force | Out-Null

    $ShortName      = (($SourceServerName -split '\.')[0] -replace '[\\/:*?"<>|]', '_')
    $CleanComponent = $Component -replace '\s+', ''
    $suffix         = if ($Unfiltered) { "_ALL" } else { "" }
    $OutputFile     = Join-Path $ComponentFolder "$($ShortName)_$CleanComponent$suffix.sql"

    if (Test-Path $OutputFile) {
        Remove-Item $OutputFile -Force
        Write-Log "Existing output file deleted: $OutputFile" "WARN"
    }
    else {
        Write-Log "No existing output file found. A new file will be created: $OutputFile" "INFO"
    }

    #endregion

    #region ===================== LOG FOLDER SETUP ========================

    $LogsRoot     = Join-Path $ComponentFolder "Logs"
    New-Item -ItemType Directory -Path $LogsRoot -Force | Out-Null

    $RunId        = Get-Date -Format "yyyyMMdd_HHmmss"
    $RunLogFolder = Join-Path $LogsRoot $RunId
    New-Item -ItemType Directory -Path $RunLogFolder -Force | Out-Null

    $logSuffix      = if ($Unfiltered) { "_ALL" } else { "" }
    $LogFile        = Join-Path $RunLogFolder "SQLAgentJobs_Generate$logSuffix.log"
    $TranscriptFile = Join-Path $RunLogFolder "Transcript$logSuffix.txt"

    $script:ActiveLogFile = $LogFile

    #endregion

    #region ===================== SQL SCRIPT STRING BUILDER ================

    $script:sb = New-Object System.Text.StringBuilder

    #endregion

    # --- Start transcript ---
    if ($EnableTranscript) {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
        try {
            Start-Transcript -Path $TranscriptFile -ErrorAction Stop | Out-Null
            Write-Log "Transcript started: $TranscriptFile" "INFO"
        }
        catch {
            Write-Log "Failed to start transcript. Error: $($_.Exception.Message)" "WARN"
        }
    }

    $ScriptStart = Get-Date
    $modeLabel = if ($Unfiltered) { "UNFILTERED (ALL)" } else { "FILTERED" }
    Write-Log "===== SQL Agent Jobs Generation Started ($modeLabel) =====" "INFO"
    Write-Log "Source          : $SourceServerInstance"                     "INFO"
    Write-Log "Output SQL file : $OutputFile"                              "INFO"
    Write-Log "Jobs folder     : $JobsSubFolder"                           "INFO"
    Write-Log "Job regex filter: $(if ($Unfiltered) { '(skipped - ALL)' } elseif ($JobNameRegex -eq 'DBA-ENABLED') { 'DBA-ENABLED (enabled jobs in DBA category)' } else { $JobNameRegex })" "INFO"
    Write-Log "Databases       : $(if ($Unfiltered) { 'ALL (unfiltered)' } else { $DatabaseList -join ', ' })" "INFO"

    # =====================================================================
    # CONNECT TO SOURCE VIA SMO
    # =====================================================================

    Write-Log "Connecting to source server via SMO..." "INFO"

    try {
        $sourceSmo = Connect-SmoTrusted -ServerInstance $SourceServerInstance -TrustServerCertificate:$script:SourceTrustServerCertificate
        Write-Log "SMO connection successful. Version: $($sourceSmo.Information.Version)" "INFO"
    }
    catch {
        Write-Log "SMO connection FAILED: $($_.Exception.Message)" "ERROR"
        throw
    }

    # =====================================================================
    # EXTRACT AND FILTER JOBS
    # =====================================================================

    Write-Log "Extracting jobs from source..." "INFO"

    if ($Unfiltered) {
        # ALL jobs enabled and disabled
        $allJobs = @($sourceSmo.JobServer.Jobs)
        Write-Log "Total jobs on source (all, unfiltered): $($allJobs.Count)" "INFO"
    }
    elseif ($JobNameRegex -eq "DBA-ENABLED") {
        # Log all distinct categories for diagnostics
        $allCategories = @($sourceSmo.JobServer.Jobs | Select-Object -ExpandProperty Category -Unique)
        Write-Log "Available job categories on source: $($allCategories -join ', ')" "INFO"

        # DBA-ENABLED: fetch enabled jobs whose NAME starts with "DBA"
        $allJobs = @($sourceSmo.JobServer.Jobs | Where-Object {
            $_.IsEnabled -eq $true -and $_.Name -like "DBA*"
        })
        Write-Log "DBA-ENABLED: Total enabled jobs starting with 'DBA': $($allJobs.Count)" "INFO"
    }
    else {
        $allJobs = @($sourceSmo.JobServer.Jobs | Where-Object { $_.IsEnabled -eq $true })
        Write-Log "Total enabled jobs on source: $($allJobs.Count)" "INFO"

        # Apply regex filter (filtered mode only)
        if ($JobNameRegex -and $JobNameRegex -ne ".*") {
            $allJobs = @($allJobs | Where-Object { $_.Name -match $JobNameRegex })
            Write-Log "Jobs matching regex '$JobNameRegex': $($allJobs.Count)" "INFO"
        }
    }

    # =====================================================================
    # RESOLVE TARGET DATABASES
    # =====================================================================

    $targetDatabases = @()
    $isAllDatabases  = $false

    if ($Unfiltered) {
        # Unfiltered mode include ALL databases
        $isAllDatabases  = $true
        $targetDatabases = @($sourceSmo.Databases |
            Where-Object { $_.IsSystemObject -eq $false } |
            Select-Object -ExpandProperty Name)
        $targetDatabases += @("master", "msdb")
        Write-Log "Database filter: ALL - unfiltered ($($targetDatabases.Count) databases)" "INFO"
    }
    else {
        $cleanedList = @($DatabaseList |
            Where-Object  { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() })

        if ($cleanedList.Count -eq 1 -and $cleanedList[0] -eq "All") {
            $isAllDatabases  = $true
            $targetDatabases = @($sourceSmo.Databases |
                Where-Object { $_.IsSystemObject -eq $false } |
                Select-Object -ExpandProperty Name)
            $targetDatabases += @("master", "msdb", "model", "tempdb")
            Write-Log "Database filter: ALL ($($targetDatabases.Count) databases)" "INFO"
        }
        else {
            $targetDatabases = $cleanedList
            Write-Log "Database filter: $($targetDatabases -join ', ')" "INFO"
        }
    }

    # In filtered mode, exclude model and tempdb
    if (-not $Unfiltered) {
        $targetDatabases = @($targetDatabases | Where-Object { $_ -notin @('model', 'tempdb') })
        Write-Log "Filtered mode: excluded model and tempdb from target databases." "INFO"
    }


    # =====================================================================
    # MAP JOBS TO DATABASES
    # =====================================================================

    $jobsByDatabase  = @{}
    $matchedJobNames = [System.Collections.Generic.List[string]]::new()

    foreach ($job in $allJobs) {
        $OutOfScope = @(Get-OutOfScopeJobDatabase -Steps @($job.JobSteps) -Databases @($targetDatabases))
        if ($OutOfScope.Count) {
            Write-Log "Skipping job '$($job.Name)': T-SQL steps reference databases outside the migration scope: $($OutOfScope -join ', ')." "WARN"
            continue
        }
        $jobMapped = $false

        foreach ($step in $job.JobSteps) {
            if ($step.DatabaseName -in $targetDatabases) {
                if (-not $jobsByDatabase.ContainsKey($step.DatabaseName)) {
                    $jobsByDatabase[$step.DatabaseName] = [System.Collections.ArrayList]::new()
                }

                # Prevent duplicate entries per database
                if ($job.Name -notin ($jobsByDatabase[$step.DatabaseName] |
                        Select-Object -ExpandProperty Name)) {
                    $jobsByDatabase[$step.DatabaseName].Add($job) | Out-Null
                    if ($job.Name -notin $matchedJobNames) { $matchedJobNames.Add($job.Name) }
                }
                $jobMapped = $true
                break   # map to first matched DB only
            }
        }

        # Fallback for jobs with no specific DB match
        if (-not $jobMapped -and ($isAllDatabases -or $Unfiltered)) {
            if (-not $jobsByDatabase.ContainsKey("ServerLevel_System")) {
                $jobsByDatabase["ServerLevel_System"] = [System.Collections.ArrayList]::new()
            }
            $jobsByDatabase["ServerLevel_System"].Add($job) | Out-Null
            if ($job.Name -notin $matchedJobNames) { $matchedJobNames.Add($job.Name) }
        }
    }

    if ($matchedJobNames.Count -eq 0) {
        Write-Log "No jobs found matching criteria." "WARN"
        if ($EnableTranscript) { try { Stop-Transcript | Out-Null } catch {} }
        $script:ActiveLogFile = $null
        return @{
            RunId        = $RunId
            RunLogFolder = $RunLogFolder
            OutputFile   = $OutputFile
            JobNames     = @()
            ItemCount = 0
        }
    }

    Write-Log "Matched $($matchedJobNames.Count) jobs across $($jobsByDatabase.Keys.Count) database groups." "INFO"

    # =====================================================================
    # COMBINED FILE HEADER
    # =====================================================================

    Add-Sql "/* ========================================================="
    Add-Sql "   SQL Agent Jobs Migration Script ($modeLabel)"
    Add-Sql "   Source      : $SourceServerName"
    Add-Sql "   Jobs        : $($matchedJobNames.Count)"
    Add-Sql "   Generated   : $(Get-Date)"
    Add-Sql "   Mode        : IDEMPOTENT (create or update in place)"
    Add-Sql "========================================================= */"
    Add-Sql ""

    # =====================================================================
    # SCRIPT EACH JOB (INDIVIDUAL + COMBINED)
    # =====================================================================

    $generatedIndividualFiles = @()
    $jobCounter = 0

    foreach ($dbName in $jobsByDatabase.Keys) {
        $dbJobs = $jobsByDatabase[$dbName]

        foreach ($job in $dbJobs) {
            $jobCounter++
            $safeJobName    = Get-SafeFileName -FileName $job.Name

            Write-Log "[$jobCounter/$($matchedJobNames.Count)] Scripting: $($job.Name) (DB: $dbName)" "INFO"

            try {
                # ---- Configure SMO Scripter ----
                $scripter = New-Object Microsoft.SqlServer.Management.Smo.Scripter($sourceSmo)
                $scripter.Options.ScriptDrops       = $false
                $scripter.Options.IncludeIfNotExists = $true

                $WasEnabled = $job.IsEnabled
                try {
                    # Change only SMO's in-memory scripting state; never call Alter on the source.
                    $job.IsEnabled = $false
                    $sqlCollection = @($job.Script() | ForEach-Object { ConvertTo-ServerObjectJobUpsertSql -Sql $_ })
                }
                finally { $job.IsEnabled = $WasEnabled }

                # ---- Individual job file ----
                $individualFile = Join-Path $JobsSubFolder "$safeJobName.sql"
                $individualContent = @"
USE [msdb];
GO

"@
                foreach ($sqlLine in $sqlCollection) {
                    $cleanedIndividual = $sqlLine -replace "@category_name=N'Jobs from MSX'",
                                           "@category_name=N'[Uncategorized (Local)]'"
                    $cleanedIndividual = $cleanedIndividual -replace 'MSXOperator', 'DBA_Notifications'
                    $individualContent += "$cleanedIndividual`nGO`n`n"
                }
                $individualContent += Get-DisabledImportedJobSql -JobName $job.Name
                [System.IO.File]::WriteAllText($individualFile, $individualContent, [System.Text.Encoding]::UTF8)
                $generatedIndividualFiles += $individualFile

                # ---- Append to combined file ----
                # Prefix each job section with a comment header
                Add-Sql "/* -----------------------------------------------------------"
                Add-Sql "   JOB: $($job.Name)"
                Add-Sql "   Database Mapping: $dbName"
                Add-Sql "   Owner: $($job.OwnerLoginName)"
                Add-Sql "   Category: $($job.Category)"
                Add-Sql "   Enabled: $($job.IsEnabled)"
                Add-Sql "   ----------------------------------------------------------- */"

                Add-Sql "USE [msdb];"
                Add-Sql "GO"
                Add-Sql ""

                foreach ($sqlLine in $sqlCollection) {
                    $cleanedLine = $sqlLine

                    # Replace reserved MSX category with a valid local category
                    if ($cleanedLine -match "Jobs from MSX") {
                        $cleanedLine = $cleanedLine -replace "@category_name=N'Jobs from MSX'",
                                              "@category_name=N'[Uncategorized (Local)]'"
                        $cleanedLine = $cleanedLine -replace "@name=N'Jobs from MSX'",
                                              "@name=N'[Uncategorized (Local)]'"
                        $cleanedLine = $cleanedLine -replace "name=N'Jobs from MSX'",
                                              "name=N'[Uncategorized (Local)]'"
                        Write-Log "Replaced 'Jobs from MSX' references with '[Uncategorized (Local)]' for job: $($job.Name)" "WARN"
                    }

                    # Replace MSXOperator with DBA_Notifications
                    if ($cleanedLine -match 'MSXOperator') {
                        $cleanedLine = $cleanedLine -replace 'MSXOperator', 'DBA_Notifications'
                        Write-Log "Replaced 'MSXOperator' with 'DBA_Notifications' for job: $($job.Name)" "WARN"
                    }

                    # Prepend USE [msdb]; so batch routing logs correctly
                    Add-Sql "USE [msdb];"
                    Add-Sql $cleanedLine
                    Add-Sql "GO"
                    Add-Sql ""
                }

                Add-Sql (Get-DisabledImportedJobSql -JobName $job.Name)
                Write-Log "Scripted successfully (imported disabled): $safeJobName.sql" "INFO"
            }
            catch {
                Write-Log "FAILED to script job '$($job.Name)': $($_.Exception.Message)" "ERROR"
            }
        }
    }

    # =====================================================================
    # WRITE COMBINED SQL TO FILE
    # =====================================================================

    try {
        [System.IO.File]::WriteAllText($OutputFile, $script:sb.ToString(), [System.Text.Encoding]::UTF8)
        Write-Log "Combined SQL migration script written: $OutputFile" "INFO"
    }
    catch {
        Write-Log "FAILED to write combined SQL file: $($_.Exception.Message)" "ERROR"
        throw
    }

    $elapsed = New-TimeSpan -Start $ScriptStart -End (Get-Date)
    Write-Log "Individual job scripts: $($generatedIndividualFiles.Count) files in $JobsSubFolder" "INFO"
    Write-Log "===== Generation completed ($modeLabel). Duration: $($elapsed.ToString()) =====" "INFO"

    if ($EnableTranscript) {
        try { Stop-Transcript | Out-Null } catch {}
    }

    Write-Log "===== SQL Agent Jobs Generation Completed ($modeLabel) =====" "SUCCESS"
    $script:ActiveLogFile = $null

    Write-Host "  SQL File      : $OutputFile"     -ForegroundColor Cyan
    Write-Host "  Individual    : $JobsSubFolder"  -ForegroundColor Cyan
    Write-Host "  Logs          : $RunLogFolder"   -ForegroundColor Cyan

    return @{
        RunId        = $RunId
        RunLogFolder = $RunLogFolder
        OutputFile   = $OutputFile
        JobNames     = [string[]]$matchedJobNames
        ItemCount = $matchedJobNames.Count
    }
}

# =========================================================================
# IDENTITY CONTEXT
# =========================================================================
$ExecutingUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Host "Executing as: $ExecutingUser" -ForegroundColor Cyan

# =========================================================================
# GLOBAL MIGRATION TRACKER
# =========================================================================
$Global:MigrationResults = [System.Collections.ArrayList]::new()
$MigrationRunId   = Get-Date -Format "yyyyMMdd_HHmmss"




# #########################################################################
#
#  MAIN PROCESSING LOOP
#
#  Iterates over every row in JSON Items, validates mandatory fields,
#  checks SQL connectivity, and dispatches to the appropriate
#  Generate-* and (optionally) Invoke-TargetExecution functions.
#
#  For EVERY component, BOTH the filtered script AND the unfiltered
#  _ALL script are generated automatically.  Only the filtered script
#  is executed on the target automatically when TargetExecutionFlag=Yes.
#  Y/N prompts are only used in execute-only (override) mode.
#
# #########################################################################

foreach ($row in $csvConfigs) {

    # =====================================================================
    # JSON ITEM VALIDATION (HARDENING)
    # =====================================================================

    if (-not $row.SourceServerName -or [string]::IsNullOrWhiteSpace($row.SourceServerName)) {
        Write-Log "Missing SourceServerName in JSON item. Skipping row." "ERROR"
        continue
    }

    if (-not $row.TargetServerName -or [string]::IsNullOrWhiteSpace($row.TargetServerName)) {
        Write-Log "Missing TargetServerName in JSON item. Skipping row." "ERROR"
        continue
    }

    # --- Normalize Yes/No flags (case-insensitive) ---
    $SQLLoginsFlag       = ($row.SQLLoginsMigrationFlag          -match "^(?i)yes$")
    $SQLOperatorsFlag    = ($row.SQLOperatorsMigrationFlag        -match "^(?i)yes$")
    $SQLAlertsFlag       = ($row.SQLAlertsMigrationFlag           -match "^(?i)yes$")
    $TargetExecutionFlag = ($row.TargetExecutionFlag              -match "^(?i)yes$")
    $SQLAgentsFlag       = ($row.SQLAgentJobsMigrationFlag        -match "^(?i)yes$")
    $OnlyTargetExecutionFlag = ($row.OnlyTargetExecutionFlag      -match "^(?i)yes$")
    $SQLDBMailFlag       = ($row.SQLDBMailMigrationFlag -match "^(?i)yes$")
    $script:SourceTrustServerCertificate = $row.SourceTrustServerCertificate
    $SQLLoginsScope      = if ($row.SQLLoginsMigrationScope -match "^(?i)server$") { "Server" }
                           elseif ($row.SQLLoginsMigrationScope -match "^(?i)(database|db)$") { "Database" }
                           else { "All" }

    if (-not ($SQLLoginsFlag -or $SQLOperatorsFlag -or $SQLAlertsFlag -or $SQLAgentsFlag -or $SQLDBMailFlag)) {
        Write-Log "No server-object components enabled for Source [$($row.SourceServerName)]. Skipping row." "WARN"
        continue
    }

    # --- Build server FQDNs ---
    $SourceInstanceName = $row.SourceServerName.Trim()
    $SourceDomainSuffix = ([string]$row.SourceDomainSuffix).Trim().Trim('.')
    $SourceParts = $SourceInstanceName -split '\\', 2
    $SourceHost = $SourceParts[0]
    if ($SourceDomainSuffix -and $SourceHost -notmatch '\.') {
        $SourceHost = "$SourceHost.$SourceDomainSuffix"
    }
    $SourceServer = if ($SourceParts.Count -eq 2) { "$SourceHost\$($SourceParts[1])" } else { $SourceHost }
    $SourceInstanceName = $SourceInstanceName -replace '[\\/:*?"<>|]', '_'
    $TargetServer       = $row.TargetServerName

    # =====================================================================
    # DISPLAY SOURCE -> TARGET BANNER
    # =====================================================================
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host "  PROCESSING MIGRATION ROW" -ForegroundColor Yellow
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host "  SOURCE      : $SourceServer" -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host "  TARGET      : $TargetServer" -ForegroundColor White -BackgroundColor DarkGreen
    Write-Host "  EXECUTED BY : $ExecutingUser" -ForegroundColor White -BackgroundColor DarkCyan
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host ""
    if ($OnlyTargetExecutionFlag) {
        Write-Host "  MODE   : EXECUTE-ONLY (OnlyTargetExecutionFlag=Yes)" -ForegroundColor White -BackgroundColor DarkMagenta
    }
    Write-Host ""

    # =================================================================
    # PRIORITY 1: EXECUTE-ONLY MODE (OnlyTargetExecutionFlag=Yes)
    # =================================================================
    # Override/re-run mode: skip generation, execute previously generated
    # scripts on target. Y/N prompt retained here because this is an
    # override scenario where objects may already exist on target.
    # =================================================================

    if ($OnlyTargetExecutionFlag) {

        Write-Log "OnlyTargetExecutionFlag=Yes. Entering EXECUTE-ONLY mode." "INFO"
        Write-Log "Executed by: $ExecutingUser" "INFO"

        # --- Validate target server connectivity ---
        $targetOk = Test-SqlServerConnection -ServerInstance $TargetServer
        if (-not $targetOk) {
            Write-Log "TARGET server validation failed for [$TargetServer]. Cannot execute. Skipping this row." "ERROR"
            continue
        }
        Write-Log "Target server validated: $TargetServer" "SUCCESS"

        # Log authenticated identity on target
        try {
            $tgtIdentity = Invoke-SqlcmdSafe -ServerInstance $TargetServer -Database "master" `
                -Query "SELECT SUSER_SNAME() AS LoginName, ORIGINAL_LOGIN() AS OriginalLogin"
            Write-Log "TARGET authenticated as: $($tgtIdentity.LoginName) (Original: $($tgtIdentity.OriginalLogin))" "INFO"
        }
        catch {
            Write-Log "Could not retrieve TARGET identity: $($_.Exception.Message)" "WARN"
        }

        # Base folder uses short instance name (same convention as generation)
        $BaseFolder = Join-Path $OutputRoot $SourceInstanceName
        $ShortName  = (($SourceServer -split '\.')[0] -replace '[\\/:*?"<>|]', '_')

        # Map enabled component flags to their folder/file naming conventions
        $componentsToExecute = @()
        if ($SQLLoginsFlag) {
            $componentsToExecute += @{
                Name      = "SQL Logins"
                Folder    = "SQL Logins"
                CleanName = "SQLLogins"
            }
        }
        if ($SQLOperatorsFlag) {
            $componentsToExecute += @{
                Name      = "SQL Operators"
                Folder    = "SQL Operators"
                CleanName = "SQLOperators"
            }
        }
        if ($SQLAlertsFlag) {
            $componentsToExecute += @{
                Name      = "SQL Alerts"
                Folder    = "SQL Alerts"
                CleanName = "SQLAlerts"
            }
        }
        if ($SQLAgentsFlag) {
            $componentsToExecute += @{
                Name      = "SQL Agent Jobs"
                Folder    = "SQL Agents"
                CleanName = "SQLAgents"
            }
        }

        if ($SQLDBMailFlag) {
            $componentsToExecute += @{ Name = 'SQL DB Mail'; Folder = 'SQL DB Mail'; CleanName = 'SQLDBMail' }
        }
        if ($componentsToExecute.Count -eq 0) {
            Write-Log "No component flags enabled for execute-only mode. Skipping." "WARN"
            continue
        }

        $compIndex = 0
        $compTotal = $componentsToExecute.Count
        foreach ($comp in $componentsToExecute) {
            $compIndex++
            Write-Log "Processing execute-only component $compIndex of $compTotal : $($comp.Name)" "INFO"

            try {
                $componentFolder = Join-Path $BaseFolder $comp.Folder
                $scriptFile      = Join-Path $componentFolder "$($ShortName)_$($comp.CleanName).sql"

                Write-Log "Looking for script: $scriptFile" "INFO"

                if (-not (Test-Path $scriptFile)) {
                    Write-Log "Script file not found for $($comp.Name): $scriptFile. Generate the component before execute-only mode." "ERROR"
                    Write-Host "Script not found: $scriptFile" -ForegroundColor Yellow
                    continue
                }

                Write-Host ""
                Write-Host "=========================================================" -ForegroundColor Yellow
                Write-Host "  EXECUTE-ONLY MODE ($compIndex of $compTotal)"              -ForegroundColor Magenta
                Write-Host "  COMPONENT : $($comp.Name)"                                -ForegroundColor Yellow
                Write-Host "  TARGET    : $TargetServer"                                -ForegroundColor Yellow
                Write-Host "  SCRIPT    : $scriptFile"                                  -ForegroundColor Yellow
                Write-Host "=========================================================" -ForegroundColor Yellow
                Write-Host ""

                $logsRoot     = Join-Path $componentFolder "Logs"
                New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null

                if ($compIndex -gt 1) { Start-Sleep -Seconds 1 }
                $runId        = Get-Date -Format "yyyyMMdd_HHmmss"
                $runLogFolder = Join-Path $logsRoot $runId
                New-Item -ItemType Directory -Path $runLogFolder -Force | Out-Null

                $genResult = @{
                    RunId        = $runId
                    RunLogFolder = $runLogFolder
                    OutputFile   = $scriptFile
                    ItemCount    = 1
                }

                $execResult = Invoke-TargetExecution `
                    -GenResult     $genResult `
                    -SourceServer  $SourceServer `
                    -TargetServer  $TargetServer `
                    -ComponentName $comp.Name
                Write-Log "Execute-only completed for $($comp.Name) with status: $($execResult.Status)" `
                    $(if ($execResult.Status -eq "FAILED") { "ERROR" } else { "SUCCESS" })
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component $comp.Name -Status $execResult.Status -OutputFile $scriptFile `
                    -ErrorMessage $execResult.ErrorMessage -Mode "Execute-Only"
            }
            catch {
                Write-Log "Execute-only FAILED for $($comp.Name): $($_.Exception.Message)" "ERROR"
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component $comp.Name -Status "FAILED" -ErrorMessage $_.Exception.Message -Mode "Execute-Only"
                Write-Host "$($comp.Name) execution failed. Continuing with remaining components..." -ForegroundColor Yellow
            }
        }

        # Write per-server summary
        Write-ServerMigrationSummary -BaseFolder $BaseFolder -SourceServer $SourceServer -TargetServer $TargetServer

        Write-Host ""
        Write-Host "Execute-only processing completed for [$SourceInstanceName] -> [$TargetServer]." -ForegroundColor Green
        Write-Host ""
        continue
    }

    #region ===================== SERVER VALIDATION =======================

    $sourceOk = Test-SqlServerConnection -ServerInstance $SourceServer -TrustServerCertificate:$script:SourceTrustServerCertificate
    if (-not $sourceOk) {
        Write-Log "SOURCE server validation failed for [$SourceServer]. Skipping this row." "ERROR"
        continue
    }

    # Log authenticated identity on source
    try {
        $srcIdentity = Invoke-SqlcmdSafe -ServerInstance $SourceServer -Database "master" -TrustServerCertificate:$script:SourceTrustServerCertificate `
            -Query "SELECT SUSER_SNAME() AS LoginName, ORIGINAL_LOGIN() AS OriginalLogin"
        Write-Log "SOURCE authenticated as: $($srcIdentity.LoginName) (Original: $($srcIdentity.OriginalLogin))" "INFO"
    }
    catch {
        Write-Log "Could not retrieve SOURCE identity: $($_.Exception.Message)" "WARN"
    }

    if ($TargetExecutionFlag) {
        $targetOk = Test-SqlServerConnection -ServerInstance $TargetServer
        if (-not $targetOk) {
            Write-Log "TARGET server validation failed for [$TargetServer]. Skipping this row." "ERROR"
            continue
        }

        try {
            $tgtIdentity = Invoke-SqlcmdSafe -ServerInstance $TargetServer -Database "master" `
                -Query "SELECT SUSER_SNAME() AS LoginName, ORIGINAL_LOGIN() AS OriginalLogin"
            Write-Log "TARGET authenticated as: $($tgtIdentity.LoginName) (Original: $($tgtIdentity.OriginalLogin))" "INFO"
        }
        catch {
            Write-Log "Could not retrieve TARGET identity: $($_.Exception.Message)" "WARN"
        }
    }

    Write-Log "Pre-flight validation successful for the selected execution mode." "INFO"
    Write-Log "Executed by: $ExecutingUser" "INFO"
    Write-Host "Connection successful for Source=$SourceServer, Target=$TargetServer" -ForegroundColor Green

    #endregion

    # Base folder uses short instance name (no FQDN)
    $BaseFolder = Join-Path $OutputRoot $SourceInstanceName

    # =====================================================================
    # SQL MIGRATION PROCESSING — GENERATE + EXECUTE (NO PROMPTS)
    # =====================================================================
    # Normal flow: CSV flags control intent. If TargetExecutionFlag=Yes
    # and generation produces items, execution proceeds automatically.
    # No Y/N prompts — JSON Items are the source of truth.
    # =====================================================================

    # -----------------------------------------------------------------
    # SQL Logins
    # -----------------------------------------------------------------
    if ($SQLLoginsFlag) {
        try {
            $genResult = Generate-SQLLogins `
                -SourceServerName $SourceServer `
                -DatabaseList     ($row.SourceListofDatabases -split ",") `
                -Component        "SQL Logins" `
                -BaseFolder       $BaseFolder `
                -Scope            $SQLLoginsScope

            if ($TargetExecutionFlag -and $genResult.ItemCount -gt 0) {
                Write-Log "Executing SQL Logins on target [$TargetServer]..." "INFO"
                $execResult = Invoke-TargetExecution `
                    -GenResult     $genResult `
                    -SourceServer  $SourceServer `
                    -TargetServer  $TargetServer `
                    -ComponentName "SQL Logins"
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component "SQL Logins" -Status $execResult.Status `
                    -OutputFile $genResult.OutputFile -ErrorMessage $execResult.ErrorMessage `
                    -Mode "Generate+Execute"
            }
            elseif ($TargetExecutionFlag -and $genResult.ItemCount -eq 0) {
                Write-Log "No SQL Logins items found on source. Skipping target execution." "WARN"
                Write-Host "No SQL Logins found on source [$SourceServer]. Nothing to execute." -ForegroundColor Yellow
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component "SQL Logins" -Status "SKIPPED"  -Mode "Generate"
            }
            else {
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component "SQL Logins" -Status "SUCCESS"  `
                    -OutputFile $genResult.OutputFile -Mode "Generate"
            }

            Write-Log "Generating unfiltered SQL Logins (_ALL)..." "INFO"
            Generate-SQLLogins `
                -SourceServerName $SourceServer `
                -DatabaseList     ($row.SourceListofDatabases -split ",") `
                -Component        "SQL Logins" `
                -BaseFolder       $BaseFolder `
                -Scope            $SQLLoginsScope `
                -Unfiltered | Out-Null
        }
        catch {
            Write-Log "SQL Logins FAILED for [$SourceServer]: $($_.Exception.Message)" "ERROR"
            Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                -Component "SQL Logins" -Status "FAILED" -ErrorMessage $_.Exception.Message
            $script:ActiveLogFile = $null
            try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
            Write-Host "SQL Logins failed. Continuing with remaining components..." -ForegroundColor Yellow
        }
    }

    # -----------------------------------------------------------------
    # SQL Operators
    # -----------------------------------------------------------------
       if ($SQLOperatorsFlag) {
        try {
            $genResult = Generate-SQLOperators `
                -SourceServerName $SourceServer `
                -Component        "SQL Operators" `
                -BaseFolder       $BaseFolder

            if ($TargetExecutionFlag -and $genResult -and $genResult.ItemCount -gt 0) {
                Write-Log "Executing SQL Operators on target [$TargetServer]..." "INFO"
                $execResult = Invoke-TargetExecution `
                    -GenResult     $genResult `
                    -SourceServer  $SourceServer `
                    -TargetServer  $TargetServer `
                    -ComponentName "SQL Operators"
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component "SQL Operators" -Status $execResult.Status `
                    -OutputFile $genResult.OutputFile -ErrorMessage $execResult.ErrorMessage `
                    -Mode "Generate+Execute"
            }
            elseif ($TargetExecutionFlag -and $genResult -and $genResult.ItemCount -eq 0) {
                Write-Log "No SQL Operators found on source. Skipping target execution." "WARN"
                Write-Host "No SQL Operators found on source [$SourceServer]. Nothing to execute." -ForegroundColor Yellow
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component "SQL Operators" -Status "SKIPPED"  -Mode "Generate"
            }
            else {
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component "SQL Operators" -Status "SUCCESS"  `
                    -OutputFile $genResult.OutputFile -Mode "Generate"
            }

            Write-Log "Generating unfiltered SQL Operators (_ALL)..." "INFO"
            Generate-SQLOperators `
                -SourceServerName $SourceServer `
                -Component        "SQL Operators" `
                -BaseFolder       $BaseFolder `
                -Unfiltered | Out-Null
        }
        catch {
            Write-Log "SQL Operators FAILED for [$SourceServer]: $($_.Exception.Message)" "ERROR"
            Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                -Component "SQL Operators" -Status "FAILED" -ErrorMessage $_.Exception.Message
            $script:ActiveLogFile = $null
            try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
            Write-Host "SQL Operators failed. Continuing with remaining components..." -ForegroundColor Yellow
        }
    }

    # -----------------------------------------------------------------
    # SQL Alerts
    # -----------------------------------------------------------------
        if ($SQLAlertsFlag) {
        try {
            $genResult = Generate-SQLAlerts `
                -SourceServerName $SourceServer `
                -Component        "SQL Alerts" `
                -BaseFolder       $BaseFolder

            if ($TargetExecutionFlag -and $genResult -and $genResult.ItemCount -gt 0) {
                Write-Log "Executing SQL Alerts on target [$TargetServer]..." "INFO"
               $execResult = Invoke-TargetExecution `
                    -GenResult     $genResult `
                    -SourceServer  $SourceServer `
                    -TargetServer  $TargetServer `
                    -ComponentName "SQL Alerts"
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component "SQL Alerts" -Status $execResult.Status `
                    -OutputFile $genResult.OutputFile -ErrorMessage $execResult.ErrorMessage `
                    -Mode "Generate+Execute"
            }
            elseif ($TargetExecutionFlag -and $genResult -and $genResult.ItemCount -eq 0) {
                Write-Log "No SQL Alerts found on source. Skipping target execution." "WARN"
                Write-Host "No SQL Alerts found on source [$SourceServer]. Nothing to execute." -ForegroundColor Yellow
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component "SQL Alerts" -Status "SKIPPED"  -Mode "Generate"
            }
            else {
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component "SQL Alerts" -Status "SUCCESS"  `
                    -OutputFile $genResult.OutputFile -Mode "Generate"
            }

            Write-Log "Generating unfiltered SQL Alerts (_ALL)..." "INFO"
            Generate-SQLAlerts `
                -SourceServerName $SourceServer `
                -Component        "SQL Alerts" `
                -BaseFolder       $BaseFolder `
                -Unfiltered | Out-Null
        }
        catch {
            Write-Log "SQL Alerts FAILED for [$SourceServer]: $($_.Exception.Message)" "ERROR"
            Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                -Component "SQL Alerts" -Status "FAILED" -ErrorMessage $_.Exception.Message
            $script:ActiveLogFile = $null
            try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
            Write-Host "SQL Alerts failed. Continuing with remaining components..." -ForegroundColor Yellow
        }
    }

    # -----------------------------------------------------------------
    # SQL Agent Jobs
    # -----------------------------------------------------------------
        if ($SQLAgentsFlag) {
        try {
            $jobNameRegex = if ($row.SQLAgentJobFilterCriteria -and
                -not [string]::IsNullOrWhiteSpace($row.SQLAgentJobFilterCriteria)) {
                $row.SQLAgentJobFilterCriteria
            } else { ".*" }

            $genResult = Generate-SQLAgentJobs `
                -SourceServerName $SourceServer `
                -DatabaseList     ($row.SourceListofDatabases -split ",") `
                -JobNameRegex     $jobNameRegex `
                -Component        "SQL Agents" `
                -BaseFolder       $BaseFolder

            if ($TargetExecutionFlag -and $genResult.ItemCount -gt 0) {
                Write-Log "Executing SQL Agent Jobs on target [$TargetServer]..." "INFO"
                $execResult = Invoke-TargetExecution `
                    -GenResult     $genResult `
                    -SourceServer  $SourceServer `
                    -TargetServer  $TargetServer `
                    -ComponentName "SQL Agents"
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component "SQL Agent Jobs" -Status $execResult.Status `
                    -OutputFile $genResult.OutputFile -ErrorMessage $execResult.ErrorMessage `
                    -Mode "Generate+Execute"
            }
            elseif ($TargetExecutionFlag -and $genResult.ItemCount -eq 0) {
                Write-Log "No SQL Agent Jobs found matching criteria. Skipping target execution." "WARN"
                Write-Host "No SQL Agent Jobs found on source [$SourceServer]. Nothing to execute." -ForegroundColor Yellow
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component "SQL Agent Jobs" -Status "SKIPPED"  -Mode "Generate"
            }
            else {
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component "SQL Agent Jobs" -Status "SUCCESS"  `
                    -OutputFile $genResult.OutputFile -Mode "Generate"
            }

            Write-Log "Generating unfiltered SQL Agent Jobs (_ALL)..." "INFO"
            Generate-SQLAgentJobs `
                -SourceServerName $SourceServer `
                -DatabaseList     ($row.SourceListofDatabases -split ",") `
                -JobNameRegex     $jobNameRegex `
                -Component        "SQL Agents" `
                -BaseFolder       $BaseFolder `
                -Unfiltered | Out-Null
        }
        catch {
            Write-Log "SQL Agent Jobs FAILED for [$SourceServer]: $($_.Exception.Message)" "ERROR"
            Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                -Component "SQL Agent Jobs" -Status "FAILED" -ErrorMessage $_.Exception.Message
            $script:ActiveLogFile = $null
            try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
            Write-Host "SQL Agent Jobs failed. Continuing with remaining components..." -ForegroundColor Yellow
         }
    }

    foreach ($AdditionalComponent in @('SQL DB Mail')) {
        if (-not $SQLDBMailFlag) { continue }
        try {
            if ([string]::IsNullOrWhiteSpace($row.SmtpServer) -or [string]::IsNullOrWhiteSpace($row.SmtpPort)) {
                throw 'SmtpServer and SmtpPort are required when Database Mail migration is enabled.'
            }
            $AdditionalInfo = Generate-SQLDBMail -SourceServerName $SourceServer -TargetServerName $TargetServer `
                -Component 'SQL DB Mail' -BaseFolder $BaseFolder -TargetType SQLVM -SmtpServer $row.SmtpServer -SmtpPort ([int]$row.SmtpPort)
            if ($TargetExecutionFlag) {
                $AdditionalExec = Invoke-TargetExecution -SourceServer $SourceServer -TargetServer $TargetServer `
                    -ComponentName $AdditionalComponent -GenResult $AdditionalInfo
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer -Component $AdditionalComponent `
                    -Status $AdditionalExec.Status -OutputFile $AdditionalInfo.OutputFile -ItemCount $AdditionalInfo.ItemCount `
                    -ErrorMessage $AdditionalExec.ErrorMessage -Mode 'Generate+Execute'
            }
            else {
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer -Component $AdditionalComponent `
                    -Status 'SUCCESS' -OutputFile $AdditionalInfo.OutputFile -ItemCount $AdditionalInfo.ItemCount -Mode 'Generate-Only'
            }
        }
        catch {
            Write-Log "$AdditionalComponent failed: $($_.Exception.Message)" 'ERROR'
            Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer -Component $AdditionalComponent `
                -Status 'FAILED' -ErrorMessage $_.Exception.Message -Mode 'Generate'
        }
    }

    # Write per-server summary
    Write-ServerMigrationSummary -BaseFolder $BaseFolder -SourceServer $SourceServer -TargetServer $TargetServer
}

# #########################################################################
#
#  OVERALL MIGRATION SUMMARY (ALL SERVERS)
#
# #########################################################################

if ($Global:MigrationResults.Count -gt 0) {
    $totalComponents  = $Global:MigrationResults.Count
    $successCount     = @($Global:MigrationResults | Where-Object { $_.Status -eq "SUCCESS" }).Count
    $failedCount      = @($Global:MigrationResults | Where-Object { $_.Status -eq "FAILED"  }).Count
    $skippedCount     = @($Global:MigrationResults | Where-Object { $_.Status -eq "SKIPPED" }).Count
    $uniqueServers    = @($Global:MigrationResults | Select-Object -ExpandProperty SourceServer -Unique).Count

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  OVERALL MIGRATION COMPLETE"                              -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  Servers Processed : $uniqueServers"                      -ForegroundColor Cyan
    Write-Host "  Total Components  : $totalComponents"                    -ForegroundColor Cyan
    Write-Host "  Succeeded         : $successCount"                       -ForegroundColor Green
    Write-Host "  Failed            : $failedCount"                        -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "Green" })
    Write-Host "  Skipped           : $skippedCount"                       -ForegroundColor Yellow
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  Consolidated server-level summaries:"                    -ForegroundColor Cyan
    Write-Host "    $OutputRoot\<ServerName>\MasterLogs\"         -ForegroundColor White
    Write-Host "  Detailed per-component execution logs:"                  -ForegroundColor Cyan
    Write-Host "    $OutputRoot\<ServerName>\<Component>\Logs\<RunId>\" -ForegroundColor White
    Write-Host ("=" * 70) -ForegroundColor Cyan
}
if ($script:MigrationHadErrors) {
    throw 'Server-object migration encountered errors. Review component logs and migration summaries.'
}
    $RunCompleted = $true
    }
    catch { $RunError = $_.Exception.Message; throw }
    finally {
        if ($OutputJsonPath) {
            Write-ServerObjectJsonResult -Path $OutputJsonPath -Results @($Global:MigrationResults.ToArray()) `
                -Started $RunStarted -RunCompleted $RunCompleted -ErrorMessage $RunError
        }
    }
}
#endregion Main Execution
