#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Automated SQL Server security object migration from source SQL Server to target (Azure VM SQL Server, Azure SQL Managed Instance), driven by JSON configuration.

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
      <ServiceDirectory>\output\AzSQLMI\<SourceServerName>\
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

    Application : Application name
    SourceServerName : SQL host name or FQDN, optionally followed by \Instance
    SourceDomainSuffix : Optional DNS suffix appended to a short source host name
    TargetServerName : Target SQL Server FQDN
    TargetType : Target type (SQLMI / SQLVM)
    TenantId : Azure Tenant ID
    SubscriptionId : Azure Subscription ID
    Domain prefix is derived from SourceServerName before the instance separator.
    SourceListofDatabases : Comma-separated database list or "ALL"
    SQLAgentJobFilterCriteria : Regex pattern, "DBA-ENABLED", or ".*" (all)
    SQLAgentJobsMigrationFlag : Yes/No
    SQLLoginsMigrationFlag : Yes/No
    SQLLoginsMigrationScope : ALL, SERVER, or DATABASE
    SQLOperatorsMigrationFlag : Yes/No
    SQLAlertsMigrationFlag : Yes/No
    SQLDBMailMigrationFlag : Yes/No
    TargetExecutionFlag : Yes/No - auto-execute generated scripts on target
    OnlyTargetExecutionFlag : Yes/No - skip generation, execute existing scripts only

.PARAMETER OutputJsonPath
    Optional structured summary, also written when generation or execution fails.
.EXAMPLE
    ..\Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1 -ItemId MI-Objects -Activity Generate

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
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\output\AzSQLMI')
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
    Invoke-ServerObjectPreflight -Operation 'Invoke-MigrateServerObjects-OnPrem-AzSQLMI' -Configuration $Configuration -Options $Options -ScriptsPath $PSScriptRoot
    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Invoke-MigrateServerObjects-OnPrem-AzSQLMI: execute validated configuration')) { return }
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

foreach ($mod in @('SqlServer', 'ActiveDirectory', 'Az.Accounts', 'Az.Resources')) {
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
    'SourceServerName', 'TargetServerName', 'TargetType', 'TenantId', 'SubscriptionId',
    'SourceListofDatabases', 'SQLAgentJobFilterCriteria', 'SQLLoginsMigrationScope',
    'SQLAgentJobsMigrationFlag', 'SQLLoginsMigrationFlag', 'SQLOperatorsMigrationFlag',
    'SQLAlertsMigrationFlag', 'SQLDBMailMigrationFlag', 'TargetExecutionFlag', 'OnlyTargetExecutionFlag'
)
foreach ($Column in $RequiredColumns) {
    if ($Column -notin $csvConfigs[0].PSObject.Properties.Name) { throw "Missing required JSON item field: $Column" }
}
foreach ($Config in $csvConfigs) {
    foreach ($Column in $RequiredColumns | Where-Object { $_ -like '*Flag' }) {
        $Config.$Column = $Config.$Column.Trim()
        if ($Config.$Column -notin @('Yes', 'No')) { throw "$Column must be Yes or No." }
    }
    if ($Config.TargetType.Trim() -ne 'SQLMI') { throw 'This entry point requires TargetType SQLMI.' }
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





<#
.SYNOPSIS
    Connectivity check for Azure SQL Managed Instance — uses an Entra ID
    access token instead of Integrated Security.
#>
function Test-SqlMIConnection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerInstance,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [string]$Database = "master"
    )

    try {
        Write-Log "Validating MI connectivity to [$ServerInstance] using Entra auth..." "INFO"

        # Ensure Azure context is established
        Connect-EntraID -TenantId $TenantId -SubscriptionId $SubscriptionId

        # Acquire access token for Azure SQL
        $tokenResult = Get-AzAccessToken -ResourceUrl "https://database.windows.net/"
        $accessToken = ConvertTo-PlainToken $tokenResult.Token

        if (-not $accessToken) {
            Write-Log "Failed to acquire access token for Azure SQL." "ERROR"
            return $false
        }

        # Test connectivity using access token
        $cmd = Get-Command Invoke-Sqlcmd -ErrorAction Stop
        if ($cmd.Parameters.ContainsKey("AccessToken")) {
            Invoke-Sqlcmd -ServerInstance $ServerInstance `
                          -Database $Database `
                          -AccessToken $accessToken `
                          -Query "SELECT @@SERVERNAME AS ServerName;" | Out-Null
        }
        else {
            # Fallback for older SqlServer module versions
            $conn = New-Object System.Data.SqlClient.SqlConnection
            $conn.ConnectionString = "Server=$ServerInstance;Database=$Database;" +
                                     "Encrypt=True;TrustServerCertificate=False;"
            $conn.AccessToken = $accessToken
            $conn.Open()
            $sqlCmd = $conn.CreateCommand()
            $sqlCmd.CommandText = "SELECT @@SERVERNAME AS ServerName;"
            $sqlCmd.ExecuteScalar() | Out-Null
            $conn.Close()
        }

        Write-Log "MI connection successful: [$ServerInstance]" "INFO"
        return $true
    }
    catch {
        Write-Log "MI connection FAILED: [$ServerInstance]. Error: $($_.Exception.Message)" "ERROR"
        return $false
    }
}





function ConvertTo-PlainToken {
    param($Token)
    if ($Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $Token).Password
    }
    return [string]$Token
}




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




function Invoke-SqlcmdTargetMI {
    param(
        [string]$Server,
        [string]$Database,
        [string]$Query,
        [string]$AccessToken
    )

    $cmd = Get-Command Invoke-Sqlcmd -ErrorAction Stop

    if ($cmd.Parameters.ContainsKey("AccessToken")) {
        Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $Query `
                      -AccessToken $AccessToken -QueryTimeout 0 -ErrorAction Stop
    }
    else {
        $conn = New-Object System.Data.SqlClient.SqlConnection
        $conn.ConnectionString = "Server=$Server;Database=$Database;" +
                                 "Encrypt=True;TrustServerCertificate=False;"
        $conn.AccessToken = $AccessToken
        $conn.Open()
        $sqlCmd = $conn.CreateCommand()
        $sqlCmd.CommandText = $Query
        $sqlCmd.CommandTimeout = 0
        $sqlCmd.ExecuteNonQuery() | Out-Null
        $conn.Close()
    }
}


#region ========================= SCRIPT EXECUTOR (BATCH SPLIT + RETRY) ===
# Reads the generated SQL script file, splits it into batches on GO,
# routes each batch to the proper database, and executes with retry
# logic and structured logging.
# =========================================================================

function Execute-SqlScript {
    param(
        [string]$Server,
        [string]$Database,
        [string]$ScriptPath,

        [ValidateSet("SQLVM","SQLMI")]
        [string]$TargetType = "SQLVM",

        [string]$TenantId,
        [string]$SubscriptionId
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
     # For SQLMI, acquire an Entra access token once before executing batches
    $miAccessToken = $null
    if ($TargetType -eq "SQLMI") {
        try {
            Connect-EntraID -TenantId $TenantId -SubscriptionId $SubscriptionId
            $tokenResult  = Get-AzAccessToken -ResourceUrl "https://database.windows.net/"
            $miAccessToken = ConvertTo-PlainToken $tokenResult.Token

            if (-not $miAccessToken) {
                Exec-LogText "FAIL | Could not acquire Entra access token for MI execution"
                $start = Get-Date; $end = Get-Date
                Exec-LogCsvRow $Server $Database $scriptName 0 "FAILED" $start $end "Access token acquisition failed" ""
                $Global:FileResults += [PSCustomObject]@{ Script = $scriptName; Database = $Database; Status = "FAILED" }
                return
            }
            Exec-LogText "Entra access token acquired for MI execution"
        }
        catch {
            Exec-LogText "FAIL | Entra auth error: $($_.Exception.Message)"
            $start = Get-Date; $end = Get-Date
            Exec-LogCsvRow $Server $Database $scriptName 0 "FAILED" $start $end $_.Exception.Message ""
            $Global:FileResults += [PSCustomObject]@{ Script = $scriptName; Database = $Database; Status = "FAILED" }
            return
        }
    }

    # --- Read file and split batches on GO lines ---
    $content = Get-Content $ScriptPath -Raw
    $batches = $content -split "(?im)^\s*GO\s*$"

    $batchNo    = 0
    $fileFailed = $false
    $tokenAcquiredAt = Get-Date

    Exec-LogText "START FILE | $scriptName | Initial DB: $Database"

    foreach ($batch in $batches) {
        if ([string]::IsNullOrWhiteSpace($batch)) { continue }

        $batchNo++
        $attempt = 0
        $success = $false

        # Determine where this batch should run (master or a specific DB)
        $batchDb = Get-BatchTargetDatabase -BatchText $batch -DefaultDb "master"
        #$connectionDb = if ($TargetType -eq "SQLMI") { "master" } else { $batchDb }
        $connectionDb = $batchDb

        #Exec-LogText "DEBUG | Batch $batchNo | batchDb=$batchDb | connectionDb=$connectionDb | TargetType=$TargetType"

        # Refresh MI token if older than 20 minutes (tokens expire ~60 min)
        if ($TargetType -eq "SQLMI" -and ((Get-Date) - $tokenAcquiredAt).TotalMinutes -gt 20) {
            try {
                $tokenResult    = Get-AzAccessToken -ResourceUrl "https://database.windows.net/"
                $miAccessToken  = ConvertTo-PlainToken $tokenResult.Token
                $tokenAcquiredAt = Get-Date
                Exec-LogText "Refreshed Entra access token (batch $batchNo)"
            }
            catch {
                Exec-LogText "WARNING | Token refresh failed: $($_.Exception.Message). Using existing token."
            }
        }

        # --- Retry loop for transient execution failures ---
        while (-not $success -and $attempt -lt $MaxRetry) {
            $attempt++
            $start = Get-Date

            try {
                if ($TargetType -eq "SQLMI") {
                    Invoke-SqlcmdTargetMI -Server $Server -Database $connectionDb `
                                         -Query $batch -AccessToken $miAccessToken
                }
                else {
                    Invoke-SqlcmdTarget -Server $Server -Database $connectionDb `
                                        -Query $batch -Credential $TargetSqlCredential
                }                   

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
        [string]$ComponentName,

        [ValidateSet("SQLVM","SQLMI")]
        [string]$TargetType = "SQLVM",

        [string]$TenantId,
        [string]$SubscriptionId
    )
    

    # Propagate generation metadata into script scope
    $execRunId           = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:RunId        = $execRunId
    $script:RunLogFolder = Join-Path (Split-Path $GenResult.RunLogFolder -Parent) "${execRunId}_execution_logs"
    New-Item -ItemType Directory -Path $script:RunLogFolder -Force | Out-Null
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

    Execute-SqlScript -Server $TargetServerInstance -Database "master" `
                      -ScriptPath $OutputFile `
                      -TargetType $TargetType `
                      -TenantId $TenantId `
                      -SubscriptionId $SubscriptionId

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
#  ENTRA ID MAPPING HELPERS (for Managed Instance migrations)
#
#  These functions validate on-prem AD identities against Microsoft
#  Entra ID (Azure AD) and build lookup dictionaries for identity
#  mapping during MI security migration.
#
# #########################################################################

<#
.SYNOPSIS
    Connects to Azure for Entra ID lookups.
    Must be called once before Generate-SQLLoginsForMI.
#>
function Connect-EntraID {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$SubscriptionId
    )

    # Check if already connected to the correct tenant & subscription
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($ctx -and $ctx.Tenant.Id -eq $TenantId -and $ctx.Subscription.Id -eq $SubscriptionId) {
        # Verify a database.windows.net scoped token is actually available.
        # Conditional Access / MFA policies may require a separate token acquisition
        # even when the general Az context is already established.
        try {
            $testToken = Get-AzAccessToken -ResourceUrl "https://database.windows.net/" -ErrorAction Stop
            if ($testToken -and $testToken.Token) {
                Write-Log "Already connected to Azure Tenant: $TenantId, Subscription: $SubscriptionId. Skipping re-auth." "INFO"
                return
            }
        }
        catch {
            Write-Log "Azure context exists but database.windows.net token unavailable ($($_.Exception.Message)). Re-authenticating with SQL scope." "WARN"
        }
    }

    Write-Log "Connecting to Azure Tenant: $TenantId" "INFO"
    Connect-AzAccount -TenantId $TenantId -UseDeviceAuthentication -AuthScope "https://database.windows.net/"
    Set-AzContext -Subscription $SubscriptionId
    Write-Log "Azure context set. Subscription: $SubscriptionId" "SUCCESS"
}

<#
.SYNOPSIS
    Searches Entra ID for a group by display name.
    Falls back to SearchString if exact match fails.
#>
function Find-AzGroupRobust {
    param([Parameter(Mandatory = $true)][string]$AdGroupName)

    $g = Get-AzADGroup -DisplayName $AdGroupName -ErrorAction SilentlyContinue
    if ($g) { return $g }

    $cand = Get-AzADGroup -SearchString $AdGroupName -ErrorAction SilentlyContinue
    if ($cand) {
        $exact = $cand | Where-Object { $_.DisplayName -and ($_.DisplayName -ieq $AdGroupName) } | Select-Object -First 1
        if ($exact) { return $exact }
        return ($cand | Select-Object -First 1)
    }
    return $null
}

<#
.SYNOPSIS
    Strips the DOMAIN\ prefix from a principal name.
    Works with any domain prefix (USPG\, YOURDOM\, etc.).
#>
function Get-SamFromDomainPrincipal {
    param([Parameter(Mandatory = $true)][string]$PrincipalName)
    return ($PrincipalName -replace '^[^\\]+\\', '').Trim()
}

<#
.SYNOPSIS
    Resolves all DOMAIN\ principals from server logins and DB principals,
    validates them against on-prem AD and Entra ID, and returns two
    lookup hashtables: $AzureUserBySam and $AzureGroupBySam.
#>

function Build-EntraLookupTables {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceServerInstance,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()][string[]]$DatabaseList,

        [Parameter(Mandatory = $true)][string]$DomainPrefix
    )

    $domainPattern = "(?i)^$([regex]::Escape($DomainPrefix))\\"
    $DomainLiteral = Escape-SqlLiteral $DomainPrefix

    Write-Log "Build-EntraLookupTables: Collecting domain principals from source..." "INFO"

    # ── Collect ALL unique domain principal names (dp.name + sp.name) ──
    $allDomainNames = New-Object System.Collections.Generic.HashSet[string](
        [System.StringComparer]::OrdinalIgnoreCase
    )

    # ── FIX #3: Also collect server-level logins (sys.server_principals) ──
    #    This catches accounts like USPG\svc_sdwd that are server logins
    #    but whose dp.name in a database may lack the domain prefix.
    $serverLoginQuery = @"
SELECT DISTINCT name
FROM sys.server_principals
WHERE type IN ('U','G')
  AND name LIKE '$DomainLiteral\%'
  AND name NOT LIKE '##%'
  AND name NOT LIKE 'NT SERVICE\%'
  AND name NOT IN ('sa','BUILTIN\Administrators','NT AUTHORITY\SYSTEM')
"@

    try {
        $serverLogins = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database "master" `
            -Context "Fetch server-level domain logins for Entra lookup" -Query $serverLoginQuery

        foreach ($sl in $serverLogins) {
            [void]$allDomainNames.Add($sl.name)
        }
        Write-Log "  Server-level domain logins collected: $($serverLogins.Count)" "INFO"
    }
    catch {
        Write-Log "  Warning: Could not query server principals: $($_.Exception.Message)" "WARN"
    }

    # ── Collect domain principals from each database ──
    $resolvedDatabases = @($DatabaseList |
        Where-Object  { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() } |
        Select-Object  -Unique)

    # If "All" was requested, expand it
    if ($resolvedDatabases.Count -eq 1 -and $resolvedDatabases[0] -ieq "All") {
        $allDbResult = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database "master" `
            -Context "Fetch ONLINE databases for Entra lookup" -Query @"
SELECT name FROM sys.databases WHERE state_desc = 'ONLINE'
"@
        $resolvedDatabases = @($allDbResult.name)
    }

    foreach ($db in $resolvedDatabases) {
        # Query both dp.name AND sp.name (via sid join) per database
        $dbPrincipalQuery = @"
SELECT DISTINCT principalName
FROM (
    -- DB principal names with domain prefix
    SELECT dp.name AS principalName
    FROM sys.database_principals dp
    WHERE dp.type IN ('U','G')
      AND dp.name LIKE '$DomainLiteral\%'

    UNION

    -- Server login names (via sid join) where dp.name may differ
    SELECT sp.name AS principalName
    FROM sys.database_principals dp
    JOIN sys.server_principals sp ON dp.sid = sp.sid
    WHERE sp.type IN ('U','G')
      AND sp.name LIKE '$DomainLiteral\%'
) AS combined
"@

        try {
            $dbPrincipals = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch domain principals from [$db] for Entra lookup" `
                -ContinueOnError -Query $dbPrincipalQuery

            foreach ($row in $dbPrincipals) {
                [void]$allDomainNames.Add($row.principalName)
            }
        }
        catch {
            Write-Log "  Warning: Could not query principals in [$db]: $($_.Exception.Message)" "WARN"
        }
    }

    Write-Log "  Total unique domain principals to resolve: $($allDomainNames.Count)" "INFO"

    # ── Resolve each domain name → Entra identity ──
    $AzureUserBySam = [System.Collections.Generic.Dictionary[string,string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $AzureGroupBySam = [System.Collections.Generic.Dictionary[string,string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($domainName in $allDomainNames) {
        if ($domainName -notmatch $domainPattern) { continue }

        $sam = (Get-SamFromDomainPrincipal -PrincipalName $domainName).ToLower()

        # Skip if already resolved
        if ($AzureUserBySam.ContainsKey($sam) -or $AzureGroupBySam.ContainsKey($sam)) {
            continue
        }

        # ── Step 1: Validate in on-prem AD ──
        $adObj = $null
        try {
            $adObj = Get-ADObject -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "  AD lookup failed for ${sam}: $($_.Exception.Message)" "WARN"
        }

        if (-not $adObj) {
            Write-Log "  Not found in AD: $domainName (SAM: $sam)" "WARN"
            continue
        }

        # ── Step 2: Determine type and look up in Entra ──
        $adType = $adObj.ObjectClass  # 'user' or 'group'

        if ($adType -eq 'user') {
            try {
                $adUser = Get-ADUser -Identity $sam -Properties UserPrincipalName -ErrorAction SilentlyContinue
                if ($adUser -and $adUser.UserPrincipalName) {
                    $upn = $adUser.UserPrincipalName

                    # Look up in Entra (Azure AD)
                    $entraUser = Get-AzADUser -UserPrincipalName $upn -ErrorAction SilentlyContinue
                    if ($entraUser) {
                        $AzureUserBySam[$sam] = $entraUser.UserPrincipalName
                        Write-Log "  Mapped user: $domainName → $($entraUser.UserPrincipalName)" "INFO"
                    }
                    else {
                        # Try by mail / display name as fallback
                        $entraUser = Get-AzADUser -Filter "startswith(userPrincipalName,'$sam@')" -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($entraUser) {
                            $AzureUserBySam[$sam] = $entraUser.UserPrincipalName
                            Write-Log "  Mapped user (partial match): $domainName → $($entraUser.UserPrincipalName)" "INFO"
                        }
                        else {
                            Write-Log "  Entra user not found for: $domainName (UPN: $upn)" "WARN"
                        }
                    }
                }
                else {
                    Write-Log "  AD user has no UPN: $domainName" "WARN"
                }
            }
            catch {
                Write-Log "  Entra user lookup failed for ${sam}: $($_.Exception.Message)" "WARN"
            }
        }
        elseif ($adType -eq 'group') {
            try {
                $adGroup = Get-ADGroup -Identity $sam -ErrorAction SilentlyContinue
                if ($adGroup) {
                    # Look up in Entra by display name
                    $entraGroup = Get-AzADGroup -DisplayName $adGroup.Name -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($entraGroup) {
                        $AzureGroupBySam[$sam] = $entraGroup.DisplayName
                        Write-Log "  Mapped group: $domainName → $($entraGroup.DisplayName)" "INFO"
                    }
                    else {
                        Write-Log "  Entra group not found for: $domainName" "WARN"
                    }
                }
            }
            catch {
                Write-Log "  Entra group lookup failed for ${sam}: $($_.Exception.Message)" "WARN"
            }
        }
        else {
            Write-Log "  Unknown AD object type '$adType' for: $domainName" "WARN"
        }
    }

    Write-Log "Build-EntraLookupTables complete. Users: $($AzureUserBySam.Count), Groups: $($AzureGroupBySam.Count)" "INFO"

    return @{
        AzureUserBySam  = $AzureUserBySam
        AzureGroupBySam = $AzureGroupBySam
    }
}


function Get-TypeLabel ([string]$t, [string]$principalName = "") {
    if ($principalName -and $sqlLoginNames.Contains($principalName)) { return "SQL Login" }
    switch ($t) {
        'S' { "SQL Login" }
        'U' { "User" }
        'G' { "Group" }
        'R' { "Role" }
        default { "Unknown" }
    }
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

if (Test-Path $OutputFile) {
    Remove-Item $OutputFile -Force
    Write-Log "Existing output file deleted: $OutputFile" "WARN"
}

    #region ===================== LOG FOLDER SETUP ========================

# Skip logging for _ALL (unfiltered) versions - they are reference backups only
if (-not $Unfiltered) {
    $LogsRoot     = Join-Path $ComponentFolder "Logs"
    New-Item -ItemType Directory -Path $LogsRoot -Force | Out-Null

    $RunId        = Get-Date -Format "yyyyMMdd_HHmmss"
    $RunLogFolder = Join-Path $LogsRoot "${RunId}_generation_logs"
    New-Item -ItemType Directory -Path $RunLogFolder -Force | Out-Null

    $LogFile        = Join-Path $RunLogFolder "SecurityMigration_Generate.log"
    $TranscriptFile = Join-Path $RunLogFolder "Transcript.txt"

    $script:ActiveLogFile = $LogFile
}
else {
    $script:ActiveLogFile = $null
    $LogFile = $null
    $TranscriptFile = $null
}

#endregion

    # --- Start transcript ---
    if ($EnableTranscript -and -not $Unfiltered) {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
        try {
            Start-Transcript -Path $TranscriptFile -ErrorAction Stop | Out-Null
            Write-Log "Transcript started: $TranscriptFile" "INFO"
        }
        catch {
            Write-Log "Failed to start transcript. Error: $($_.Exception.Message)" "WARN"
        }
    }

 

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

        if ($EnableTranscript -and -not $Unfiltered) {
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
#  GENERATE-SQLLOGINSFORMI FUNCTION
#
#  Similar to Generate-SQLLogins but designed for Azure Managed Instance.
#  Connects to source SQL Server, extracts security objects, maps on-prem
#  AD (DOMAIN\) identities to Microsoft Entra ID, and generates
#  idempotent T-SQL using CREATE ... FROM EXTERNAL PROVIDER syntax.
#
#  Key differences from Generate-SQLLogins:
#    - Windows/AD logins → mapped to Entra, created FROM EXTERNAL PROVIDER
#    - SQL logins with password hashes are EXCLUDED (MI does not support
#      CREATE LOGIN ... HASHED for SQL auth)
#    - DB users mapped to AD → created FROM EXTERNAL PROVIDER
#    - Unmapped principals (not in Entra) are logged and skipped
#    - Generates CSV mapping reports alongside the SQL script
#
#  When -Unfiltered is specified, ALL principals are included and the
#  output file is suffixed with _ALL.
#
# #########################################################################


function Generate-SQLLoginsForMI {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceServerName,

        [Parameter(Mandatory = $true)]
        [string[]]$DatabaseList,

        [Parameter(Mandatory = $true)]
        [string]$Component,

        [Parameter(Mandatory = $true)]
        [string]$BaseFolder,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)][string]$DomainPrefix,

        [ValidateSet("All", "Server", "Database")]
        [string]$Scope = "All",

        [switch]$Unfiltered
    )

    #region ===================== CONFIGURATION ===========================

    $SourceServerInstance = $SourceServerName
    $EnableTranscript     = $true
    $domainPattern        = "(?i)^$([regex]::Escape($DomainPrefix))\\"

    if ($Unfiltered) { $Scope = 'All' }

    #endregion

    #region ===================== OUTPUT / PATH SETUP =====================

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

    # CSV report files (mapped + skipped + unmapped) - no _ALL suffix
    $mappedCsvFile   = Join-Path $ComponentFolder "$($ShortName)_${CleanComponent}_Mapped.csv"
    $skippedCsvFile  = Join-Path $ComponentFolder "$($ShortName)_${CleanComponent}_Skipped.csv"
    $unmappedCsvFile = Join-Path $ComponentFolder "$($ShortName)_${CleanComponent}_Unmapped.csv"
    foreach ($f in @($mappedCsvFile, $skippedCsvFile, $unmappedCsvFile)) {
        if (Test-Path $f) { Remove-Item $f -Force }
    }

    #endregion

    #region ===================== LOG FOLDER SETUP ========================

# Skip logging for _ALL (unfiltered) versions - they are reference backups only
if (-not $Unfiltered) {
    $LogsRoot     = Join-Path $ComponentFolder "Logs"
    New-Item -ItemType Directory -Path $LogsRoot -Force | Out-Null

    $RunId        = Get-Date -Format "yyyyMMdd_HHmmss"
    $RunLogFolder = Join-Path $LogsRoot "${RunId}_generation_logs"
    New-Item -ItemType Directory -Path $RunLogFolder -Force | Out-Null

    $LogFile        = Join-Path $RunLogFolder "SecurityMigration_Generate.log"
    $TranscriptFile = Join-Path $RunLogFolder "Transcript.txt"

    $script:ActiveLogFile = $LogFile
}
else {
    $script:ActiveLogFile = $null
    $LogFile = $null
    $TranscriptFile = $null
}

#endregion



    #region ===================== SQL SCRIPT STRING BUILDER ================

    $script:sb = New-Object System.Text.StringBuilder
    $itemCount = 0


    #endregion

    #region ===================== TRACKING & EARLY INIT ====================

    # --- Tracking arrays for CSV reports ---
    $mappedPrincipals   = [System.Collections.ArrayList]::new()
    $skippedPrincipals  = [System.Collections.ArrayList]::new()
    $unmappedPrincipals = [System.Collections.ArrayList]::new()

    # --- Initialize SQL login tracking sets EARLY (before Get-TypeLabel) ---
    $sqlLoginNames                = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $script:dbSqlLoginPrincipals  = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    #endregion

    #region ===================== HELPER: TYPE LABEL =======================

    function Get-TypeLabel ([string]$t, [string]$principalName = "") {
        if ($principalName) {
            if ($sqlLoginNames -and $sqlLoginNames.Contains($principalName)) { return "SQL Login" }
            if ($script:dbSqlLoginPrincipals -and $script:dbSqlLoginPrincipals.Contains($principalName)) { return "SQL Login" }
        }
        switch ($t) {
            'S' { "SQL Login" }
            'U' { "User" }
            'G' { "Group" }
            'R' { "Role" }
            default { "Unknown" }
        }
    }

    #endregion

    #region ===================== CONDITIONAL FILTERS =====================

    $serverPrincipalFilter = if ($Unfiltered) { "" } else { @"

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
    if ($EnableTranscript -and -not $Unfiltered) {
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
    Write-Log "===== SQL Logins for MI Generation Started ($modeLabel, Scope=$Scope) =====" "INFO"
    Write-Log "===== Script started. RunId folder: $RunLogFolder =====" "INFO"
    Write-Log "Source: $SourceServerInstance" "INFO"
    Write-Log "Output SQL file: $OutputFile" "INFO"
    Write-Log "Databases requested: $($DatabaseList -join ', ')" "INFO"

    # =====================================================================
    # PHASE 0: CONNECT TO ENTRA ID & BUILD LOOKUP TABLES
    # =====================================================================

    $allDbList = @(Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database 'master' `
        -Context 'Fetch ONLINE databases' -Query "SELECT name FROM sys.databases WHERE state_desc = 'ONLINE'")
    $SecurityDatabaseNames = @(Get-ServerObjectSecurityDatabaseNames -AvailableNames @($allDbList.name) `
        -DatabaseList $DatabaseList -Scope $Scope)

    Write-Log "Connecting to Entra ID for identity mapping..." "INFO"

    try {
        Connect-EntraID -TenantId $TenantId -SubscriptionId $SubscriptionId
    }
    catch {
        Write-Log "Entra ID connection failed: $($_.Exception.Message)" "ERROR"
        throw
    }

    Write-Log "Building Entra lookup tables from source server..." "INFO"

    $entraLookup = Build-EntraLookupTables `
        -SourceServerInstance $SourceServerInstance `
        -DatabaseList $SecurityDatabaseNames `
        -DomainPrefix $DomainPrefix

    $AzureUserBySam  = $entraLookup.AzureUserBySam
    $AzureGroupBySam = $entraLookup.AzureGroupBySam

    # --- Helper: resolve a domain principal to its Entra name ---
    function Resolve-ToEntra {
        param([string]$PrincipalName)

        if (-not $PrincipalName) { return $null }
        if ($PrincipalName -notmatch $domainPattern) { return $null }

        $samKey = (Get-SamFromDomainPrincipal -PrincipalName $PrincipalName).ToLower()

        if ($AzureUserBySam.ContainsKey($samKey)) {
            return [pscustomobject]@{ Name = $AzureUserBySam[$samKey]; Kind = "USER" }
        }
        if ($AzureGroupBySam.ContainsKey($samKey)) {
            return [pscustomobject]@{ Name = $AzureGroupBySam[$samKey]; Kind = "GROUP" }
        }
        return $null
    }

    # =====================================================================
    # PHASE 1: SERVER-LEVEL OBJECTS
    # =====================================================================

    if ($Scope -in @('All', 'Server', 'Database')) {

        #region --- SERVER LOGINS (Entra-mapped - FROM EXTERNAL PROVIDER) ---

        Write-Log "Starting section: SERVER LOGINS (Entra-mapped)" "INFO"

        $winLogins = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database "master" `
            -Context "Fetch Windows/AD logins" -Query @"
SELECT name, type
FROM sys.server_principals
WHERE type IN ('U','G')$serverPrincipalFilter
"@

        if ($winLogins) {
            Add-SectionHeader "SERVER LOGINS (ENTRA-MAPPED - EXTERNAL PROVIDER)"
            $emittedLogins = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

            foreach ($row in $winLogins) {
                $n = $row.name

                if ($n -match $domainPattern) {
                    $resolved = Resolve-ToEntra -PrincipalName $n
                    if ($resolved -and -not $emittedLogins.Contains($resolved.Name)) {
                        [void]$emittedLogins.Add($resolved.Name)

                        $nLit = Escape-SqlLiteral $resolved.Name
                        $nBr  = Escape-SqlBracket $resolved.Name

                        Add-Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$nLit')
BEGIN
    CREATE LOGIN [$nBr] FROM EXTERNAL PROVIDER;
END
GO
"@
                        $itemCount++

                        [void]$mappedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $n
                            EntraName       = $resolved.Name
                            Kind            = $resolved.Kind
                            Level           = "SERVER_LOGIN"
                            ResolvedVia     = "direct"
                            Type            = Get-TypeLabel $row.type $n
                        })
                    }
                    elseif (-not $resolved) {
                        Write-Log "Skipping unmapped Entra login: $n" "WARN"
                        [void]$skippedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $n; Level = "SERVER_LOGIN"
                            Reason = "Not confirmed in Entra ID"
                            Type   = Get-TypeLabel $row.type $n
                        })
                        [void]$unmappedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $n; Level = "SERVER_LOGIN"
                            Reason = "Not confirmed in Entra ID"
                            Type   = Get-TypeLabel $row.type $n
                        })
                    }
                }
                else {
                    if (-not $Unfiltered -and $n -like "*\*" -and -not (Test-ADPrincipalExists $n)) {
                        Write-Log "Skipping deleted AD login: $n" "WARN"
                        [void]$skippedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $n; Level = "SERVER_LOGIN"
                            Reason = "Deleted from AD"
                            Type   = Get-TypeLabel $row.type $n
                        })
                        continue
                    }
                    Write-Log "Skipping non-domain principal: $n" "WARN"
                    [void]$skippedPrincipals.Add([pscustomobject]@{
                        SourcePrincipal = $n; Level = "SERVER_LOGIN"
                        Reason = "Non-domain principal - not mapped to Entra"
                        Type   = Get-TypeLabel $row.type $n
                    })
                }
            }
        }

        #endregion

        #region --- SQL LOGINS (INFORMATIONAL ONLY for MI) ---

        Write-Log "Starting section: SQL LOGINS (informational)" "INFO"

        $sqlLoginFilter = if ($Unfiltered) { "" } else { @"

  AND name NOT LIKE '##%'
  AND name NOT LIKE 'NT SERVICE\%'
  AND name NOT IN ('sa','BUILTIN\Administrators','NT AUTHORITY\SYSTEM')
"@ }

        $sqlLogins = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database "master" `
            -Context "Fetch SQL logins" -Query @"
SELECT name FROM sys.sql_logins WHERE 1=1$sqlLoginFilter
"@

        # Populate the already-initialized $sqlLoginNames set
        if ($sqlLogins) {
            Add-SectionHeader "SQL LOGINS (INFORMATIONAL - MI does not support hashed password CREATE)"
            Add-Sql "/* NOTE: The following SQL logins exist on the source server."
            Add-Sql "   Azure Managed Instance supports SQL authentication but CREATE LOGIN"
            Add-Sql "   ... WITH PASSWORD = <hash> HASHED is NOT supported."
            Add-Sql "   These logins must be created manually with new passwords on MI."
            Add-Sql "   All dependent statements (server roles, server permissions, DB users,"
            Add-Sql "   DB role memberships, and DB permissions) for these SQL logins are also"
            Add-Sql "   commented out. Uncomment them after creating the logins manually. */"
            Add-Sql ""
            foreach ($row in $sqlLogins) {
                [void]$sqlLoginNames.Add($row.name)
                $nLit = Escape-SqlLiteral $row.name
                $nBr  = Escape-SqlBracket $row.name
                Add-Sql "-- SQL LOGIN (manual): [$nBr]"
                Add-Sql "-- IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$nLit')"
                Add-Sql "-- BEGIN"
                Add-Sql "--     CREATE LOGIN [$nBr] WITH PASSWORD = N'<SET_PASSWORD_HERE>';"
                Add-Sql "-- END"
                Add-Sql "-- GO"
                Add-Sql ""
            }
        }

        #endregion

        #region --- SERVER ROLE MEMBERSHIP (Entra-mapped) ---

        Write-Log "Starting section: SERVER ROLE MEMBERSHIP (Entra-mapped)" "INFO"

        $roleMembers = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database "master" `
            -Context "Fetch server role membership" -Query @"
SELECT r.name AS RoleName, m.name AS MemberName, m.type AS MemberType
FROM sys.server_role_members rm
JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id
JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id
WHERE m.type IN ('S','U','G')$memberFilter
"@

        if ($roleMembers) {
            Add-SectionHeader "SERVER ROLE MEMBERSHIP (ENTRA-MAPPED)"

            foreach ($rm in $roleMembers) {
                $role       = $rm.RoleName
                $mem        = $rm.MemberName
                $memberType = $rm.MemberType

                $effectiveMember = $mem
                if ($mem -match $domainPattern) {
                    $resolved = Resolve-ToEntra -PrincipalName $mem
                    if ($resolved) {
                        $effectiveMember = $resolved.Name
                        [void]$mappedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $mem; EntraName = $resolved.Name
                            Kind = $resolved.Kind; Level = "SERVER_ROLE"
                            ResolvedVia = "direct"
                            Type = Get-TypeLabel $memberType $mem
                        })
                    }
                    else {
                        Write-Log "Skipping unmapped Entra server role member: $mem" "WARN"
                        [void]$skippedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $mem; Level = "SERVER_ROLE"
                            Reason = "Not confirmed in Entra ID"
                            Type = Get-TypeLabel $memberType $mem
                        })
                        [void]$unmappedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $mem; Level = "SERVER_ROLE"
                            Reason = "Not confirmed in Entra ID"
                            Type = Get-TypeLabel $memberType $mem
                        })
                        continue
                    }
                }
                elseif (-not $Unfiltered -and $mem -like "*\*" -and -not (Test-ADPrincipalExists $mem)) {
                    Write-Log "Skipping deleted AD server role member: $mem" "WARN"
                    [void]$skippedPrincipals.Add([pscustomobject]@{
                        SourcePrincipal = $mem; Level = "SERVER_ROLE"
                        Reason = "Deleted from AD"
                        Type = Get-TypeLabel $memberType $mem
                    })
                    continue
                }

                $roleLit = Escape-SqlLiteral $role
                $memLit  = Escape-SqlLiteral $effectiveMember
                $roleBr  = Escape-SqlBracket $role
                $memBr   = Escape-SqlBracket $effectiveMember

                $isSqlLogin = ($memberType -eq 'S') -or $sqlLoginNames.Contains($mem)

                if ($isSqlLogin) {
                    Add-Sql "-- SQL LOGIN ROLE (manual): Uncomment after creating SQL login [$memBr]"
                    Add-Sql "-- IF NOT EXISTS ("
                    Add-Sql "--     SELECT 1"
                    Add-Sql "--     FROM sys.server_role_members rm"
                    Add-Sql "--     JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id"
                    Add-Sql "--     JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id"
                    Add-Sql "--     WHERE r.name = N'$roleLit' AND m.name = N'$memLit'"
                    Add-Sql "-- )"
                    Add-Sql "-- BEGIN"
                    Add-Sql "--     ALTER SERVER ROLE [$roleBr] ADD MEMBER [$memBr];"
                    Add-Sql "-- END"
                    Add-Sql "-- GO"
                    Add-Sql ""
                }
                else {
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
                }
                $itemCount++
            }
        }

        #endregion

        #region --- SERVER PERMISSIONS (Entra-mapped) ---

        Write-Log "Starting section: SERVER PERMISSIONS (Entra-mapped)" "INFO"

        $serverPerms = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database "master" `
            -Context "Fetch server permissions" -Query @"
SELECT sp.name, sp.type AS PrincipalType, perm.permission_name, perm.state_desc
FROM sys.server_permissions perm
JOIN sys.server_principals sp ON perm.grantee_principal_id = sp.principal_id
WHERE sp.type IN ('S','U','G')
  AND perm.state_desc IN ('GRANT','DENY','GRANT_WITH_GRANT_OPTION')$spFilter
"@

        if ($serverPerms) {
            Add-SectionHeader "SERVER PERMISSIONS (ENTRA-MAPPED)"

            foreach ($p in $serverPerms) {
                $principal     = $p.name
                $principalType = $p.PrincipalType
                $permName      = $p.permission_name
                $stateDesc     = $p.state_desc

                $effectivePrincipal = $principal
                if ($principal -match $domainPattern) {
                    $resolved = Resolve-ToEntra -PrincipalName $principal
                    if ($resolved) {
                        $effectivePrincipal = $resolved.Name
                        [void]$mappedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $principal; EntraName = $resolved.Name
                            Kind = $resolved.Kind; Level = "SERVER_PERMISSION"
                            ResolvedVia = "direct"
                            Type = Get-TypeLabel $principalType $principal
                        })
                    }
                    else {
                        Write-Log "Skipping unmapped Entra server perm principal: $principal" "WARN"
                        [void]$skippedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $principal; Level = "SERVER_PERMISSION"
                            Reason = "Not confirmed in Entra ID"
                            Type = Get-TypeLabel $principalType $principal
                        })
                        [void]$unmappedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $principal; Level = "SERVER_PERMISSION"
                            Reason = "Not confirmed in Entra ID"
                            Type = Get-TypeLabel $principalType $principal
                        })
                        continue
                    }
                }
                elseif (-not $Unfiltered -and $principal -like "*\*" -and -not (Test-ADPrincipalExists $principal)) {
                    Write-Log "Skipping deleted AD server perm principal: $principal" "WARN"
                    [void]$skippedPrincipals.Add([pscustomobject]@{
                        SourcePrincipal = $principal; Level = "SERVER_PERMISSION"
                        Reason = "Deleted from AD"
                        Type = Get-TypeLabel $principalType $principal
                    })
                    continue
                }

                $pLit    = Escape-SqlLiteral $effectivePrincipal
                $permLit = Escape-SqlLiteral $permName
                $pBr     = Escape-SqlBracket $effectivePrincipal

                $action      = if ($stateDesc -eq 'DENY') { "DENY" } else { "GRANT" }
                $grantOption = if ($stateDesc -eq 'GRANT_WITH_GRANT_OPTION') { " WITH GRANT OPTION" } else { "" }
                $stateCheck  = if ($stateDesc -eq 'DENY') { "perm.state = N'D'" }
                               elseif ($stateDesc -eq 'GRANT_WITH_GRANT_OPTION') { "perm.state = N'W'" }
                               else { "perm.state IN (N'G', N'W')" }

                $isSqlLogin = ($principalType -eq 'S') -or $sqlLoginNames.Contains($principal)

                if ($isSqlLogin) {
                    Add-Sql "-- SQL LOGIN PERMISSION (manual): Uncomment after creating SQL login [$pBr]"
                    Add-Sql "-- IF NOT EXISTS ("
                    Add-Sql "--     SELECT 1"
                    Add-Sql "--     FROM sys.server_permissions perm"
                    Add-Sql "--     JOIN sys.server_principals sp ON perm.grantee_principal_id = sp.principal_id"
                    Add-Sql "--     WHERE perm.permission_name = N'$permLit' AND sp.name = N'$pLit'"
                    Add-Sql "--       AND $stateCheck"
                    Add-Sql "-- )"
                    Add-Sql "-- BEGIN"
                    Add-Sql "--     $action $permName TO [$pBr]$grantOption;"
                    Add-Sql "-- END"
                    Add-Sql "-- GO"
                    Add-Sql ""
                }
                else {
                    Add-Sql @"
IF NOT EXISTS (
    SELECT 1
    FROM sys.server_permissions perm
    JOIN sys.server_principals sp ON perm.grantee_principal_id = sp.principal_id
    WHERE perm.permission_name = N'$permLit' AND sp.name = N'$pLit'
      AND $stateCheck
)
BEGIN
    $action $permName TO [$pBr]$grantOption;
END
GO
"@
                }
                $itemCount++
            }
        }

        #endregion
    }

    # =====================================================================
    # PHASE 2: DATABASE SELECTION
    # =====================================================================

    Write-Log "Resolving database list..." "INFO"

    $dbList = @($allDbList | Where-Object { $_.name -in $SecurityDatabaseNames })
    Write-Log "Security scope=$Scope; databases selected: $($SecurityDatabaseNames -join ', ')" "INFO"

    if (-not $dbList -or $dbList.Count -eq 0) {
        Write-Log "No databases selected after applying Scope=$Scope." "WARN"
    }

    # =====================================================================
    # PHASE 3: DATABASE-LEVEL OBJECTS (Entra-mapped)
    # =====================================================================

    foreach ($db in $dbList.name) {
        Write-Log "===== Starting DB: $db =====" "INFO"

        $dbPrincipalToEntra = [System.Collections.Generic.Dictionary[string,string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        # Reset per-DB SQL login principal tracking
        $script:dbSqlLoginPrincipals = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

        try {

            #region --- DB USERS MAPPED TO LOGINS (Entra) ---

            $dbMappedUsers = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch DB users mapped to server logins" -ContinueOnError -Query @"
SELECT dp.name AS UserName, sp.type AS LoginType, sp.name AS ServerLoginName
FROM sys.database_principals dp
JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.type IN ('S','U','G')$dbPrincipalFilter
"@

            if ($dbMappedUsers) {
                Add-SectionHeader "DATABASE USERS - MAPPED TO LOGINS (ENTRA)" $db
                $emittedDbUsers = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

                foreach ($u in $dbMappedUsers) {
                    $userName    = $u.UserName
                    $loginType   = $u.LoginType
                    $serverLogin = $u.ServerLoginName

                    # Track DB principals backed by SQL logins
                    if ($loginType -eq 'S' -or $sqlLoginNames.Contains($serverLogin) -or $sqlLoginNames.Contains($userName)) {
                        [void]$script:dbSqlLoginPrincipals.Add($userName)
                    }

                    $resolved    = $null
                    $resolvedVia = $null

                    if ($userName -match $domainPattern) {
                        $resolved = Resolve-ToEntra -PrincipalName $userName
                        if ($resolved) { $resolvedVia = "dp.name=$userName" }
                    }

                    if (-not $resolved -and $serverLogin -and $serverLogin -match $domainPattern) {
                        $resolved = Resolve-ToEntra -PrincipalName $serverLogin
                        if ($resolved) { $resolvedVia = "sp.name=$serverLogin (fallback)" }
                    }

                    if ($resolved) {
                        $dbPrincipalToEntra[$userName] = $resolved.Name

                        if (-not $emittedDbUsers.Contains($resolved.Name)) {
                            [void]$emittedDbUsers.Add($resolved.Name)

                            $userLit = Escape-SqlLiteral $resolved.Name
                            $userBr  = Escape-SqlBracket $resolved.Name

                            Add-Sql @"
USE [$db];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$userLit')
BEGIN
    CREATE USER [$userBr] FROM EXTERNAL PROVIDER;
END
GO
"@
                            $itemCount++
                        }

                        [void]$mappedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $userName; EntraName = $resolved.Name
                            Kind = $resolved.Kind; Level = "DB_USER_MAPPED"
                            Database = $db; ResolvedVia = $resolvedVia
                            Type = Get-TypeLabel $loginType $userName
                        })
                    }
                    elseif (
                        ($userName -match $domainPattern) -or
                        ($serverLogin -and $serverLogin -match $domainPattern)
                    ) {
                        Write-Log "Skipping unmapped Entra mapped user: $userName (ServerLogin: $serverLogin, DB: $db)" "WARN"
                        [void]$skippedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $userName; Level = "DB_USER_MAPPED"
                            Database = $db; Reason = "Not confirmed in Entra ID (ServerLogin: $serverLogin)"
                            Type = Get-TypeLabel $loginType $userName
                        })
                        [void]$unmappedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $userName; Level = "DB_USER_MAPPED"
                            Database = $db; Reason = "Not confirmed in Entra ID (ServerLogin: $serverLogin)"
                            Type = Get-TypeLabel $loginType $userName
                        })
                    }
                    else {
                        if (-not $Unfiltered -and $userName -like "*\*" -and -not (Test-ADPrincipalExists $userName)) {
                            Write-Log "Skipping deleted AD mapped user: $userName (DB: $db)" "WARN"
                            [void]$skippedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $userName; Level = "DB_USER_MAPPED"
                                Database = $db; Reason = "Deleted from AD"
                                Type = Get-TypeLabel $loginType $userName
                            })
                            continue
                        }

                        $userLit    = Escape-SqlLiteral $userName
                        $userBr     = Escape-SqlBracket $userName
                        $isSqlLogin = ($loginType -eq 'S') -or $sqlLoginNames.Contains($userName) -or $sqlLoginNames.Contains($serverLogin)

                        if ($isSqlLogin) {
                            Add-Sql "-- SQL LOGIN DB USER (manual): Uncomment after creating SQL login [$userBr]"
                            Add-Sql "-- USE [$db]; IF NOT EXISTS(SELECT 1 FROM sys.database_principals WHERE name = N'$userLit') CREATE USER [$userBr] FOR LOGIN [$userBr];"
                            Add-Sql "-- GO"
                            Add-Sql ""
                        }
                        else {
                            Add-Sql "USE [$db]; IF NOT EXISTS(SELECT 1 FROM sys.database_principals WHERE name = N'$userLit') CREATE USER [$userBr] FOR LOGIN [$userBr];"
                            Add-Sql "GO"
                        }
                        $itemCount++
                    }
                }
            }

            #endregion

            #region --- DB-ONLY USERS (Entra) ---

            $dbOnlyUsers = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch DB-only users" -ContinueOnError -Query @"
SELECT dp.name AS UserName, dp.type AS UserType
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.type IN ('S','U','G')
  AND sp.name IS NULL$dbPrincipalFilter
"@

            if ($dbOnlyUsers) {
                Add-SectionHeader "DATABASE USERS - DB ONLY (ENTRA)" $db
                $emittedDbOnlyUsers = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

                foreach ($u in $dbOnlyUsers) {
                    $userName = $u.UserName
                    $userType = $u.UserType

                    if ($userName -match $domainPattern) {
                        $resolved = Resolve-ToEntra -PrincipalName $userName
                        if ($resolved) {
                            $dbPrincipalToEntra[$userName] = $resolved.Name

                            if (-not $emittedDbOnlyUsers.Contains($resolved.Name)) {
                                [void]$emittedDbOnlyUsers.Add($resolved.Name)

                                $userLit = Escape-SqlLiteral $resolved.Name
                                $userBr  = Escape-SqlBracket $resolved.Name

                                Add-Sql @"
USE [$db];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$userLit')
BEGIN
    CREATE USER [$userBr] FROM EXTERNAL PROVIDER;
END
GO
"@
                                $itemCount++
                            }

                            [void]$mappedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $userName; EntraName = $resolved.Name
                                Kind = $resolved.Kind; Level = "DB_ONLY"
                                Database = $db; ResolvedVia = "direct"
                                Type = Get-TypeLabel $userType $userName
                            })
                        }
                        else {
                            Write-Log "Skipping unmapped Entra DB-only user: $userName (DB: $db)" "WARN"
                            [void]$skippedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $userName; Level = "DB_ONLY"
                                Database = $db; Reason = "Not confirmed in Entra ID"
                                Type = Get-TypeLabel $userType $userName
                            })
                            [void]$unmappedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $userName; Level = "DB_ONLY"
                                Database = $db; Reason = "Not confirmed in Entra ID"
                                Type = Get-TypeLabel $userType $userName
                            })
                        }
                    }
                    else {
                        if (-not $Unfiltered -and $userName -like "*\*" -and -not (Test-ADPrincipalExists $userName)) {
                            Write-Log "Skipping deleted AD DB-only user: $userName (DB: $db)" "WARN"
                            [void]$skippedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $userName; Level = "DB_ONLY"
                                Database = $db; Reason = "Deleted from AD"
                                Type = Get-TypeLabel $userType $userName
                            })
                            continue
                        }
                        $userLit = Escape-SqlLiteral $userName
                        $userBr  = Escape-SqlBracket $userName
                        Add-Sql "USE [$db]; IF NOT EXISTS(SELECT 1 FROM sys.database_principals WHERE name = N'$userLit') CREATE USER [$userBr] WITHOUT LOGIN;"
                        Add-Sql "GO"
                        $itemCount++
                    }
                }
            }

            #endregion

            #region --- CUSTOM DATABASE ROLES ---

            $customRoles = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch custom database roles" -ContinueOnError -Query @"
SELECT r.name AS RoleName, ISNULL(p.name, 'dbo') AS OwnerName
FROM sys.database_principals r
LEFT JOIN sys.database_principals p ON r.owning_principal_id = p.principal_id
WHERE r.type = 'R' AND r.is_fixed_role = 0 AND r.name NOT IN ('public')
"@

            if ($customRoles) {
                Add-SectionHeader "CUSTOM DATABASE ROLES" $db

                foreach ($cr in $customRoles) {
                    $roleLit  = Escape-SqlLiteral $cr.RoleName
                    $roleBr   = Escape-SqlBracket $cr.RoleName
                    $ownerBr  = Escape-SqlBracket $cr.OwnerName

                    Add-Sql @"
USE [$db];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$roleLit' AND type = 'R')
BEGIN
    CREATE ROLE [$roleBr] AUTHORIZATION [$ownerBr];
END
GO
"@
                    $itemCount++
                }
            }

            #endregion

            #region --- DB ROLE MEMBERSHIP (Entra-mapped) ---

            $dbRoleMembers = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch DB role membership" -ContinueOnError -Query @"
SELECT dr.name AS RoleName, dp.name AS UserName, dp.type AS MemberType
FROM sys.database_role_members drm
JOIN sys.database_principals dr ON drm.role_principal_id = dr.principal_id
JOIN sys.database_principals dp ON drm.member_principal_id = dp.principal_id
WHERE dp.type IN ('S','U','G','R')$dbPrincipalFilter
"@

            if ($dbRoleMembers) {
                Add-SectionHeader "DATABASE ROLE MEMBERSHIP (ENTRA-MAPPED)" $db

                foreach ($m in $dbRoleMembers) {
                    $role       = $m.RoleName
                    $user       = $m.UserName
                    $memberType = $m.MemberType

                    $effectiveUser = $user

                    if ($dbPrincipalToEntra.ContainsKey($user)) {
                        $effectiveUser = $dbPrincipalToEntra[$user]
                        [void]$mappedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $user; EntraName = $effectiveUser
                            Kind = "MAPPED_VIA_RENAME"; Level = "DB_ROLE_MEMBER"
                            Database = $db; ResolvedVia = "dbPrincipalToEntra"
                            Type = Get-TypeLabel $memberType $user
                        })
                    }
                    elseif ($user -match $domainPattern) {
                        $resolved = Resolve-ToEntra -PrincipalName $user
                        if ($resolved) {
                            $effectiveUser = $resolved.Name
                            [void]$mappedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $user; EntraName = $resolved.Name
                                Kind = $resolved.Kind; Level = "DB_ROLE_MEMBER"
                                Database = $db; ResolvedVia = "direct"
                                Type = Get-TypeLabel $memberType $user
                            })
                        }
                        else {
                            Write-Log "Skipping unmapped Entra role member: $user (DB: $db)" "WARN"
                            [void]$skippedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $user; Level = "DB_ROLE_MEMBER"
                                Database = $db; Reason = "Not confirmed in Entra ID"
                                Type = Get-TypeLabel $memberType $user
                            })
                            [void]$unmappedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $user; Level = "DB_ROLE_MEMBER"
                                Database = $db; Reason = "Not confirmed in Entra ID"
                                Type = Get-TypeLabel $memberType $user
                            })
                            continue
                        }
                    }
                    elseif (-not $Unfiltered -and $user -like "*\*" -and -not (Test-ADPrincipalExists $user)) {
                        Write-Log "Skipping deleted AD role member: $user (DB: $db)" "WARN"
                        [void]$skippedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $user; Level = "DB_ROLE_MEMBER"
                            Database = $db; Reason = "Deleted from AD"
                            Type = Get-TypeLabel $memberType $user
                        })
                        continue
                    }

                    $roleLit = Escape-SqlLiteral $role
                    $userLit = Escape-SqlLiteral $effectiveUser
                    $roleBr  = Escape-SqlBracket $role
                    $userBr  = Escape-SqlBracket $effectiveUser

                    $isSqlLogin = $sqlLoginNames.Contains($user) -or $script:dbSqlLoginPrincipals.Contains($user)

                    if ($isSqlLogin) {
                        Add-Sql "-- SQL LOGIN DB ROLE (manual): Uncomment after creating SQL login [$userBr]"
                        Add-Sql "-- USE [$db];"
                        Add-Sql "-- IF NOT EXISTS ("
                        Add-Sql "--     SELECT 1"
                        Add-Sql "--     FROM sys.database_role_members drm"
                        Add-Sql "--     JOIN sys.database_principals dr ON drm.role_principal_id = dr.principal_id"
                        Add-Sql "--     JOIN sys.database_principals dp ON drm.member_principal_id = dp.principal_id"
                        Add-Sql "--     WHERE dr.name = N'$roleLit' AND dp.name = N'$userLit'"
                        Add-Sql "-- )"
                        Add-Sql "-- BEGIN"
                        Add-Sql "--     ALTER ROLE [$roleBr] ADD MEMBER [$userBr];"
                        Add-Sql "-- END"
                        Add-Sql "-- GO"
                        Add-Sql ""
                    }
                    else {
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
                    }
                    $itemCount++
                }
            }

            #endregion

            #region --- DATABASE-LEVEL PERMISSIONS (Entra-mapped, class = 0) ---

            $dbLevelPerms = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch database-level permissions (class=0)" -ContinueOnError -Query @"
SELECT dp.name AS PrincipalName, dp.type AS PrincipalType, perm.permission_name, perm.state_desc
FROM sys.database_permissions perm
JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id
WHERE perm.class = 0 AND dp.type IN ('S','U','G','R')
  AND perm.state_desc IN ('GRANT','DENY','GRANT_WITH_GRANT_OPTION')$dbPrincipalFilter
"@

            if ($dbLevelPerms) {
                Add-SectionHeader "DATABASE-LEVEL PERMISSIONS (ENTRA-MAPPED)" $db

                foreach ($p in $dbLevelPerms) {
                    $pname         = $p.PrincipalName
                    $principalType = $p.PrincipalType
                    $permName      = $p.permission_name
                    $stateDesc     = $p.state_desc

                    $effectiveName = $pname

                    if ($dbPrincipalToEntra.ContainsKey($pname)) {
                        $effectiveName = $dbPrincipalToEntra[$pname]
                        [void]$mappedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $pname; EntraName = $effectiveName
                            Kind = "MAPPED_VIA_RENAME"; Level = "DB_PERMISSION"
                            Database = $db; ResolvedVia = "dbPrincipalToEntra"
                            Type = Get-TypeLabel $principalType $pname
                        })
                    }
                    elseif ($pname -match $domainPattern) {
                        $resolved = Resolve-ToEntra -PrincipalName $pname
                        if ($resolved) {
                            $effectiveName = $resolved.Name
                            [void]$mappedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $pname; EntraName = $resolved.Name
                                Kind = $resolved.Kind; Level = "DB_PERMISSION"
                                Database = $db; ResolvedVia = "direct"
                                Type = Get-TypeLabel $principalType $pname
                            })
                        }
                        else {
                            [void]$skippedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $pname; Level = "DB_PERMISSION"
                                Database = $db; Reason = "Not confirmed in Entra ID"
                                Type = Get-TypeLabel $principalType $pname
                            })
                            [void]$unmappedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $pname; Level = "DB_PERMISSION"
                                Database = $db; Reason = "Not confirmed in Entra ID"
                                Type = Get-TypeLabel $principalType $pname
                            })
                            continue
                        }
                    }
                    elseif (-not $Unfiltered -and $pname -like "*\*" -and -not (Test-ADPrincipalExists $pname)) {
                        [void]$skippedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $pname; Level = "DB_PERMISSION"
                            Database = $db; Reason = "Deleted from AD"
                            Type = Get-TypeLabel $principalType $pname
                        })
                        continue
                    }

                    $pLit    = Escape-SqlLiteral $effectiveName
                    $permLit = Escape-SqlLiteral $permName
                    $pBr     = Escape-SqlBracket $effectiveName

                    $action      = if ($stateDesc -eq 'DENY') { "DENY" } else { "GRANT" }
                    $grantOption = if ($stateDesc -eq 'GRANT_WITH_GRANT_OPTION') { " WITH GRANT OPTION" } else { "" }
                    $stateCheck  = if ($stateDesc -eq 'DENY') { "perm.state = N'D'" }
                                   elseif ($stateDesc -eq 'GRANT_WITH_GRANT_OPTION') { "perm.state = N'W'" }
                                   else { "perm.state IN (N'G', N'W')" }

                    $isSqlLogin = $sqlLoginNames.Contains($pname) -or $script:dbSqlLoginPrincipals.Contains($pname)

                    if ($isSqlLogin) {
                        Add-Sql "-- SQL LOGIN DB PERMISSION (manual): Uncomment after creating SQL login [$pBr]"
                        Add-Sql "-- USE [$db];"
                        Add-Sql "-- IF NOT EXISTS ("
                        Add-Sql "--     SELECT 1 FROM sys.database_permissions perm"
                        Add-Sql "--     JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id"
                        Add-Sql "--     WHERE dp.name = N'$pLit' AND perm.permission_name = N'$permLit'"
                        Add-Sql "--       AND perm.class = 0 AND $stateCheck"
                        Add-Sql "-- )"
                        Add-Sql "-- BEGIN"
                        Add-Sql "--     $action $permName TO [$pBr]$grantOption;"
                        Add-Sql "-- END"
                        Add-Sql "-- GO"
                        Add-Sql ""
                    }
                    else {
                        Add-Sql @"
USE [$db];
IF NOT EXISTS (
    SELECT 1 FROM sys.database_permissions perm
    JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id
    WHERE dp.name = N'$pLit' AND perm.permission_name = N'$permLit'
      AND perm.class = 0 AND $stateCheck
)
BEGIN
    $action $permName TO [$pBr]$grantOption;
END
GO
"@
                    }
                    $itemCount++
                }
            }

            #endregion

            #region --- SCHEMA-LEVEL PERMISSIONS (Entra-mapped, class = 3) ---

            $schemaPerms = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch schema-level permissions (class=3)" -ContinueOnError -Query @"
SELECT dp.name AS PrincipalName, dp.type AS PrincipalType, perm.permission_name, perm.state_desc,
       SCHEMA_NAME(perm.major_id) AS SchemaName
FROM sys.database_permissions perm
JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id
WHERE perm.class = 3 AND dp.type IN ('S','U','G','R')
  AND perm.state_desc IN ('GRANT','DENY','GRANT_WITH_GRANT_OPTION')$dbPrincipalFilter
"@

            if ($schemaPerms) {
                Add-SectionHeader "SCHEMA-LEVEL PERMISSIONS (ENTRA-MAPPED)" $db

                foreach ($sp in $schemaPerms) {
                    $pname         = $sp.PrincipalName
                    $principalType = $sp.PrincipalType
                    $permName      = $sp.permission_name
                    $stateDesc     = $sp.state_desc
                    $schName       = $sp.SchemaName

                    if ([string]::IsNullOrWhiteSpace($schName)) { continue }

                    $effectiveName = $pname

                    if ($dbPrincipalToEntra.ContainsKey($pname)) {
                        $effectiveName = $dbPrincipalToEntra[$pname]
                        [void]$mappedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $pname; EntraName = $effectiveName
                            Kind = "MAPPED_VIA_RENAME"; Level = "SCHEMA_PERMISSION"
                            Database = $db; ResolvedVia = "dbPrincipalToEntra"
                            Type = Get-TypeLabel $principalType $pname
                        })
                    }
                    elseif ($pname -match $domainPattern) {
                        $resolved = Resolve-ToEntra -PrincipalName $pname
                        if ($resolved) {
                            $effectiveName = $resolved.Name
                            [void]$mappedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $pname; EntraName = $resolved.Name
                                Kind = $resolved.Kind; Level = "SCHEMA_PERMISSION"
                                Database = $db; ResolvedVia = "direct"
                                Type = Get-TypeLabel $principalType $pname
                            })
                        }
                        else {
                            [void]$skippedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $pname; Level = "SCHEMA_PERMISSION"
                                Database = $db; Reason = "Not confirmed in Entra ID"
                                Type = Get-TypeLabel $principalType $pname
                            })
                            [void]$unmappedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $pname; Level = "SCHEMA_PERMISSION"
                                Database = $db; Reason = "Not confirmed in Entra ID"
                                Type = Get-TypeLabel $principalType $pname
                            })
                            continue
                        }
                    }
                    elseif (-not $Unfiltered -and $pname -like "*\*" -and -not (Test-ADPrincipalExists $pname)) {
                        [void]$skippedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $pname; Level = "SCHEMA_PERMISSION"
                            Database = $db; Reason = "Deleted from AD"
                            Type = Get-TypeLabel $principalType $pname
                        })
                        continue
                    }

                    $pLit    = Escape-SqlLiteral $effectiveName
                    $permLit = Escape-SqlLiteral $permName
                    $schLit  = Escape-SqlLiteral $schName
                    $pBr     = Escape-SqlBracket $effectiveName
                    $schBr   = Escape-SqlBracket $schName

                    $action      = if ($stateDesc -eq 'DENY') { "DENY" } else { "GRANT" }
                    $grantOption = if ($stateDesc -eq 'GRANT_WITH_GRANT_OPTION') { " WITH GRANT OPTION" } else { "" }
                    $stateCheck  = if ($stateDesc -eq 'DENY') { "perm.state = N'D'" }
                                   elseif ($stateDesc -eq 'GRANT_WITH_GRANT_OPTION') { "perm.state = N'W'" }
                                   else { "perm.state IN (N'G', N'W')" }

                    $isSqlLogin = $sqlLoginNames.Contains($pname) -or $script:dbSqlLoginPrincipals.Contains($pname)

                    if ($isSqlLogin) {
                        Add-Sql "-- SQL LOGIN SCHEMA PERMISSION (manual): Uncomment after creating SQL login [$pBr]"
                        Add-Sql "-- USE [$db];"
                        Add-Sql "-- IF NOT EXISTS ("
                        Add-Sql "--     SELECT 1 FROM sys.database_permissions perm"
                        Add-Sql "--     JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id"
                        Add-Sql "--     WHERE dp.name = N'$pLit' AND perm.permission_name = N'$permLit'"
                        Add-Sql "--       AND perm.class = 3 AND perm.major_id = SCHEMA_ID(N'$schLit') AND $stateCheck"
                        Add-Sql "-- )"
                        Add-Sql "-- BEGIN"
                        Add-Sql "--     $action $permName ON SCHEMA::[$schBr] TO [$pBr]$grantOption;"
                        Add-Sql "-- END"
                        Add-Sql "-- GO"
                        Add-Sql ""
                    }
                    else {
                        Add-Sql @"
USE [$db];
IF NOT EXISTS (
    SELECT 1 FROM sys.database_permissions perm
    JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id
    WHERE dp.name = N'$pLit' AND perm.permission_name = N'$permLit'
      AND perm.class = 3 AND perm.major_id = SCHEMA_ID(N'$schLit') AND $stateCheck
)
BEGIN
    $action $permName ON SCHEMA::[$schBr] TO [$pBr]$grantOption;
END
GO
"@
                    }
                    $itemCount++
                }
            }

            #endregion

            #region --- OBJECT & COLUMN-LEVEL PERMISSIONS (Entra-mapped, class = 1) ---

            $objPerms = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                -Context "Fetch object/column-level permissions (class=1)" -ContinueOnError -Query @"
SELECT dp.name AS PrincipalName, dp.type AS PrincipalType, perm.permission_name, perm.state_desc,
       SCHEMA_NAME(o.schema_id) AS SchemaName, o.name AS ObjName,
       c.name AS ColumnName, perm.minor_id
FROM sys.database_permissions perm
JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id
JOIN sys.objects o ON perm.major_id = o.object_id
LEFT JOIN sys.columns c ON perm.minor_id = c.column_id AND c.object_id = o.object_id
WHERE perm.class = 1 AND dp.type IN ('S','U','G','R')
  AND perm.state_desc IN ('GRANT','DENY','GRANT_WITH_GRANT_OPTION')$dbPrincipalFilter
"@

            if ($objPerms) {
                Add-SectionHeader "OBJECT & COLUMN-LEVEL PERMISSIONS (ENTRA-MAPPED)" $db

                foreach ($op in $objPerms) {
                    $pname         = $op.PrincipalName
                    $principalType = $op.PrincipalType
                    $permName      = $op.permission_name
                    $stateDesc     = $op.state_desc
                    $sch           = $op.SchemaName
                    $obj           = $op.ObjName
                    $colName       = $op.ColumnName
                    $minorId       = $op.minor_id

                    $effectiveName = $pname

                    if ($dbPrincipalToEntra.ContainsKey($pname)) {
                        $effectiveName = $dbPrincipalToEntra[$pname]
                        [void]$mappedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $pname; EntraName = $effectiveName
                            Kind = "MAPPED_VIA_RENAME"; Level = "OBJECT_PERMISSION"
                            Database = $db; ResolvedVia = "dbPrincipalToEntra"
                            Type = Get-TypeLabel $principalType $pname
                        })
                    }
                    elseif ($pname -match $domainPattern) {
                        $resolved = Resolve-ToEntra -PrincipalName $pname
                        if ($resolved) {
                            $effectiveName = $resolved.Name
                            [void]$mappedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $pname; EntraName = $resolved.Name
                                Kind = $resolved.Kind; Level = "OBJECT_PERMISSION"
                                Database = $db; ResolvedVia = "direct"
                                Type = Get-TypeLabel $principalType $pname
                            })
                        }
                        else {
                            [void]$skippedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $pname; Level = "OBJECT_PERMISSION"
                                Database = $db; Reason = "Not confirmed in Entra ID"
                                Type = Get-TypeLabel $principalType $pname
                            })
                            [void]$unmappedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $pname; Level = "OBJECT_PERMISSION"
                                Database = $db; Reason = "Not confirmed in Entra ID"
                                Type = Get-TypeLabel $principalType $pname
                            })
                            continue
                        }
                    }
                    elseif (-not $Unfiltered -and $pname -like "*\*" -and -not (Test-ADPrincipalExists $pname)) {
                        [void]$skippedPrincipals.Add([pscustomobject]@{
                            SourcePrincipal = $pname; Level = "OBJECT_PERMISSION"
                            Database = $db; Reason = "Deleted from AD"
                            Type = Get-TypeLabel $principalType $pname
                        })
                        continue
                    }

                    $pLit    = Escape-SqlLiteral $effectiveName
                    $permLit = Escape-SqlLiteral $permName
                    $pBr     = Escape-SqlBracket $effectiveName

                    $action      = if ($stateDesc -eq 'DENY') { "DENY" } else { "GRANT" }
                    $grantOption = if ($stateDesc -eq 'GRANT_WITH_GRANT_OPTION') { " WITH GRANT OPTION" } else { "" }
                    $stateCheck  = if ($stateDesc -eq 'DENY') { "perm.state = N'D'" }
                                   elseif ($stateDesc -eq 'GRANT_WITH_GRANT_OPTION') { "perm.state = N'W'" }
                                   else { "perm.state IN (N'G', N'W')" }

                    $isSqlLogin = $sqlLoginNames.Contains($pname) -or $script:dbSqlLoginPrincipals.Contains($pname)

                    if ([string]::IsNullOrWhiteSpace($sch) -or [string]::IsNullOrWhiteSpace($obj)) {
                        if ($isSqlLogin) {
                            Add-Sql "-- SQL LOGIN OBJECT PERMISSION (manual): Uncomment after creating SQL login [$pBr]"
                            Add-Sql "-- USE [$db];"
                            Add-Sql "-- IF NOT EXISTS ("
                            Add-Sql "--     SELECT 1 FROM sys.database_permissions perm"
                            Add-Sql "--     JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id"
                            Add-Sql "--     WHERE dp.name = N'$pLit' AND perm.permission_name = N'$permLit'"
                            Add-Sql "--       AND perm.class = 0 AND $stateCheck"
                            Add-Sql "-- )"
                            Add-Sql "-- BEGIN"
                            Add-Sql "--     $action $permName TO [$pBr]$grantOption;"
                            Add-Sql "-- END"
                            Add-Sql "-- GO"
                            Add-Sql ""
                        }
                        else {
                            Add-Sql @"
USE [$db];
IF NOT EXISTS (
    SELECT 1 FROM sys.database_permissions perm
    JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id
    WHERE dp.name = N'$pLit' AND perm.permission_name = N'$permLit'
      AND perm.class = 0 AND $stateCheck
)
BEGIN
    $action $permName TO [$pBr]$grantOption;
END
GO
"@
                        }
                        $itemCount++
                    }
                    elseif ($minorId -ne 0 -and -not [string]::IsNullOrWhiteSpace($colName)) {
                        $schBr  = Escape-SqlBracket $sch
                        $objBr  = Escape-SqlBracket $obj
                        $colBr  = Escape-SqlBracket $colName
                        $colLit = Escape-SqlLiteral $colName

                        if ($isSqlLogin) {
                            Add-Sql "-- SQL LOGIN COLUMN PERMISSION (manual): Uncomment after creating SQL login [$pBr]"
                            Add-Sql "-- USE [$db];"
                            Add-Sql "-- IF OBJECT_ID(N'[$schBr].[$objBr]') IS NOT NULL"
                            Add-Sql "-- AND NOT EXISTS ("
                            Add-Sql "--     SELECT 1 FROM sys.database_permissions perm"
                            Add-Sql "--     JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id"
                            Add-Sql "--     WHERE dp.name = N'$pLit' AND perm.permission_name = N'$permLit'"
                            Add-Sql "--       AND perm.class = 1 AND perm.major_id = OBJECT_ID(N'[$schBr].[$objBr]')"
                            Add-Sql "--       AND perm.minor_id = ("
                            Add-Sql "--           SELECT TOP 1 c.column_id FROM sys.columns c"
                            Add-Sql "--           WHERE c.object_id = OBJECT_ID(N'[$schBr].[$objBr]') AND c.name = N'$colLit'"
                            Add-Sql "--       )"
                            Add-Sql "--       AND $stateCheck"
                            Add-Sql "-- )"
                            Add-Sql "-- BEGIN"
                            Add-Sql "--     $action $permName ([$colBr]) ON [$schBr].[$objBr] TO [$pBr]$grantOption;"
                            Add-Sql "-- END"
                            Add-Sql "-- GO"
                            Add-Sql ""
                        }
                        else {
                            Add-Sql @"
USE [$db];
IF OBJECT_ID(N'[$schBr].[$objBr]') IS NOT NULL
AND NOT EXISTS (
    SELECT 1 FROM sys.database_permissions perm
    JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id
    WHERE dp.name = N'$pLit' AND perm.permission_name = N'$permLit'
      AND perm.class = 1 AND perm.major_id = OBJECT_ID(N'[$schBr].[$objBr]')
      AND perm.minor_id = (
          SELECT TOP 1 c.column_id FROM sys.columns c
          WHERE c.object_id = OBJECT_ID(N'[$schBr].[$objBr]') AND c.name = N'$colLit'
      )
      AND $stateCheck
)
BEGIN
    $action $permName ([$colBr]) ON [$schBr].[$objBr] TO [$pBr]$grantOption;
END
GO
"@
                        }
                        $itemCount++
                    }
                    else {
                        $schBr = Escape-SqlBracket $sch
                        $objBr = Escape-SqlBracket $obj

                        if ($isSqlLogin) {
                            Add-Sql "-- SQL LOGIN OBJECT PERMISSION (manual): Uncomment after creating SQL login [$pBr]"
                            Add-Sql "-- USE [$db];"
                            Add-Sql "-- IF OBJECT_ID(N'[$schBr].[$objBr]') IS NOT NULL"
                            Add-Sql "-- AND NOT EXISTS ("
                            Add-Sql "--     SELECT 1 FROM sys.database_permissions perm"
                            Add-Sql "--     JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id"
                            Add-Sql "--     WHERE dp.name = N'$pLit' AND perm.permission_name = N'$permLit'"
                            Add-Sql "--       AND perm.class = 1 AND perm.major_id = OBJECT_ID(N'[$schBr].[$objBr]')"
                            Add-Sql "--       AND perm.minor_id = 0 AND $stateCheck"
                            Add-Sql "-- )"
                            Add-Sql "-- BEGIN"
                            Add-Sql "--     $action $permName ON [$schBr].[$objBr] TO [$pBr]$grantOption;"
                            Add-Sql "-- END"
                            Add-Sql "-- GO"
                            Add-Sql ""
                        }
                        else {
                            Add-Sql @"
USE [$db];
IF OBJECT_ID(N'[$schBr].[$objBr]') IS NOT NULL
AND NOT EXISTS (
    SELECT 1 FROM sys.database_permissions perm
    JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id
    WHERE dp.name = N'$pLit' AND perm.permission_name = N'$permLit'
      AND perm.class = 1 AND perm.major_id = OBJECT_ID(N'[$schBr].[$objBr]')
      AND perm.minor_id = 0 AND $stateCheck
)
BEGIN
    $action $permName ON [$schBr].[$objBr] TO [$pBr]$grantOption;
END
GO
"@
                        }
                        $itemCount++
                    }
                }
            }

            #endregion

            #region --- MSDB SQL AGENT PERMISSIONS (Entra-mapped) ---

            if ($db -eq "msdb") {
                $agentProcPerms = Invoke-SqlcmdLogged -ServerInstance $SourceServerInstance -Database $db `
                    -Context "Fetch SQL Agent procedure permissions" -ContinueOnError -Query @"
SELECT dp.name AS PrincipalName, dp.type AS PrincipalType,
       OBJECT_NAME(perm.major_id) AS ProcName, perm.permission_name, perm.state_desc
FROM sys.database_permissions perm
JOIN sys.database_principals dp ON perm.grantee_principal_id = dp.principal_id
WHERE perm.major_id IN (
    OBJECT_ID('dbo.sp_start_job'), OBJECT_ID('dbo.sp_stop_job'),
    OBJECT_ID('dbo.sp_delete_job'), OBJECT_ID('dbo.sp_add_job'),
    OBJECT_ID('dbo.sp_update_job'), OBJECT_ID('dbo.sp_help_job'),
    OBJECT_ID('dbo.sp_help_jobhistory'), OBJECT_ID('dbo.sp_add_jobstep'),
    OBJECT_ID('dbo.sp_update_jobstep'), OBJECT_ID('dbo.sp_delete_jobstep'),
    OBJECT_ID('dbo.sp_add_jobschedule'), OBJECT_ID('dbo.sp_update_jobschedule'),
    OBJECT_ID('dbo.sp_delete_jobschedule')
)
AND perm.permission_name = 'EXECUTE'
AND perm.state_desc IN ('GRANT','DENY','GRANT_WITH_GRANT_OPTION')
"@

                if ($agentProcPerms) {
                    Add-SectionHeader "MSDB SQL AGENT PERMISSIONS (ENTRA-MAPPED)" $db

                    foreach ($perm in $agentProcPerms) {
                        $principal     = $perm.PrincipalName
                        $principalType = $perm.PrincipalType
                        $proc          = $perm.ProcName
                        $stateDesc     = $perm.state_desc

                        $effectiveName = $principal

                        if ($dbPrincipalToEntra.ContainsKey($principal)) {
                            $effectiveName = $dbPrincipalToEntra[$principal]
                            [void]$mappedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $principal; EntraName = $effectiveName
                                Kind = "MAPPED_VIA_RENAME"; Level = "MSDB_AGENT_PERMISSION"
                                Database = $db; ResolvedVia = "dbPrincipalToEntra"
                                Type = Get-TypeLabel $principalType $principal
                            })
                        }
                        elseif ($principal -match $domainPattern) {
                            $resolved = Resolve-ToEntra -PrincipalName $principal
                            if ($resolved) {
                                $effectiveName = $resolved.Name
                                [void]$mappedPrincipals.Add([pscustomobject]@{
                                    SourcePrincipal = $principal; EntraName = $resolved.Name
                                    Kind = $resolved.Kind; Level = "MSDB_AGENT_PERMISSION"
                                    Database = $db; ResolvedVia = "direct"
                                    Type = Get-TypeLabel $principalType $principal
                                })
                            }
                            else {
                                [void]$skippedPrincipals.Add([pscustomobject]@{
                                    SourcePrincipal = $principal; Level = "MSDB_AGENT_PERMISSION"
                                    Database = $db; Reason = "Not confirmed in Entra ID"
                                    Type = Get-TypeLabel $principalType $principal
                                })
                                [void]$unmappedPrincipals.Add([pscustomobject]@{
                                    SourcePrincipal = $principal; Level = "MSDB_AGENT_PERMISSION"
                                    Database = $db; Reason = "Not confirmed in Entra ID"
                                    Type = Get-TypeLabel $principalType $principal
                                })
                                continue
                            }
                        }
                        elseif (-not $Unfiltered -and $principal -like "*\*" -and -not (Test-ADPrincipalExists $principal)) {
                            [void]$skippedPrincipals.Add([pscustomobject]@{
                                SourcePrincipal = $principal; Level = "MSDB_AGENT_PERMISSION"
                                Database = $db; Reason = "Deleted from AD"
                                Type = Get-TypeLabel $principalType $principal
                            })
                            continue
                        }

                        $pLit   = Escape-SqlLiteral $effectiveName
                        $pBr    = Escape-SqlBracket $effectiveName
                        $procBr = Escape-SqlBracket $proc

                        $action      = if ($stateDesc -eq 'DENY') { "DENY" } else { "GRANT" }
                        $grantOption = if ($stateDesc -eq 'GRANT_WITH_GRANT_OPTION') { " WITH GRANT OPTION" } else { "" }
                        $stateCheck  = if ($stateDesc -eq 'DENY') { "state = N'D'" }
                                       elseif ($stateDesc -eq 'GRANT_WITH_GRANT_OPTION') { "state = N'W'" }
                                       else { "state IN (N'G', N'W')" }

                        $isSqlLogin = $sqlLoginNames.Contains($principal) -or $script:dbSqlLoginPrincipals.Contains($principal)

                        if ($isSqlLogin) {
                            Add-Sql "-- SQL LOGIN AGENT PERMISSION (manual): Uncomment after creating SQL login [$pBr]"
                            Add-Sql "-- USE [msdb];"
                            Add-Sql "-- IF NOT EXISTS ("
                            Add-Sql "--     SELECT 1 FROM sys.database_permissions"
                            Add-Sql "--     WHERE grantee_principal_id = USER_ID(N'$pLit')"
                            Add-Sql "--       AND permission_name = 'EXECUTE'"
                            Add-Sql "--       AND major_id = OBJECT_ID(N'dbo.$proc')"
                            Add-Sql "--       AND $stateCheck"
                            Add-Sql "-- )"
                            Add-Sql "-- BEGIN"
                            Add-Sql "--     $action EXECUTE ON [dbo].[$procBr] TO [$pBr]$grantOption;"
                            Add-Sql "-- END"
                            Add-Sql "-- GO"
                            Add-Sql ""
                        }
                        else {
                            Add-Sql @"
USE [msdb];
IF NOT EXISTS (
    SELECT 1 FROM sys.database_permissions
    WHERE grantee_principal_id = USER_ID(N'$pLit')
      AND permission_name = 'EXECUTE'
      AND major_id = OBJECT_ID(N'dbo.$proc')
      AND $stateCheck
)
BEGIN
    $action EXECUTE ON [dbo].[$procBr] TO [$pBr]$grantOption;
END
GO
"@
                        }
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
    # WRITE GENERATED SQL + CSV REPORTS
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

    # Export CSV reports
    if ($mappedPrincipals.Count -gt 0) {
        $mappedPrincipals | Export-Csv -Path $mappedCsvFile -NoTypeInformation -Encoding UTF8
        Write-Log "Mapped principals CSV: $mappedCsvFile ($($mappedPrincipals.Count) entries)" "INFO"
    }
    if ($skippedPrincipals.Count -gt 0) {
        $skippedPrincipals | Export-Csv -Path $skippedCsvFile -NoTypeInformation -Encoding UTF8
        Write-Log "Skipped principals CSV: $skippedCsvFile ($($skippedPrincipals.Count) entries)" "INFO"
    }
    if ($unmappedPrincipals.Count -gt 0) {
        $unmappedPrincipals | Export-Csv -Path $unmappedCsvFile -NoTypeInformation -Encoding UTF8
        Write-Log "Unmapped principals CSV: $unmappedCsvFile ($($unmappedPrincipals.Count) entries)" "INFO"
    }

    $elapsed = New-TimeSpan -Start $ScriptStart -End (Get-Date)
    Write-Log "===== Generation completed ($modeLabel, Scope=$Scope). Duration: $($elapsed.ToString()) =====" "INFO"

    if ($EnableTranscript -and -not $Unfiltered) {
    try { Stop-Transcript | Out-Null } catch {}
}

    Write-Log "===== SQL Security Migration for MI Completed ($modeLabel, Scope=$Scope) =====" "SUCCESS"
    $script:ActiveLogFile = $null

    Write-Host "  SQL File     : $OutputFile"       -ForegroundColor Cyan
    Write-Host "  Mapped CSV   : $mappedCsvFile"    -ForegroundColor Cyan
    Write-Host "  Skipped CSV  : $skippedCsvFile"   -ForegroundColor Cyan
    Write-Host "  Unmapped CSV : $unmappedCsvFile"  -ForegroundColor Yellow
    Write-Host "  Logs         : $RunLogFolder"     -ForegroundColor Cyan

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
    $EnableTranscript = $true

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
#region ===================== LOG FOLDER SETUP ========================

# Skip logging for _ALL (unfiltered) versions - they are reference backups only
if (-not $Unfiltered) {
    $LogsRoot     = Join-Path $ComponentFolder "Logs"
    New-Item -ItemType Directory -Path $LogsRoot -Force | Out-Null

    $RunId        = Get-Date -Format "yyyyMMdd_HHmmss"
    $RunLogFolder = Join-Path $LogsRoot "${RunId}_generation_logs"
    New-Item -ItemType Directory -Path $RunLogFolder -Force | Out-Null

    $LogFile        = Join-Path $RunLogFolder "SecurityMigration_Generate.log"
    $TranscriptFile = Join-Path $RunLogFolder "Transcript.txt"

    $script:ActiveLogFile = $LogFile
}
else {
    $script:ActiveLogFile = $null
    $LogFile = $null
    $TranscriptFile = $null
}

#endregion

    # --- Start transcript (skip for _ALL versions) ---
$modeLabel = if ($Unfiltered) { "UNFILTERED (ALL)" } else { "FILTERED" }

if ($EnableTranscript -and -not $Unfiltered) {
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
       if ($EnableTranscript -and -not $Unfiltered) {
        try { Stop-Transcript | Out-Null } catch {}
    }
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

    if ($EnableTranscript -and -not $Unfiltered) {
    try { Stop-Transcript | Out-Null } catch {}
}

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
    $EnableTranscript = $true

    $ShortName      = (($SourceServerName -split '\.')[0] -replace '[\\/:*?"<>|]', '_')
    $CleanComponent = $Component -replace '\s+', ''
    $suffix         = if ($Unfiltered) { "_ALL" } else { "" }
    $OutputFile     = Join-Path $ComponentFolder "$($ShortName)_$CleanComponent$suffix.sql"

    if (Test-Path $OutputFile) {
        Remove-Item $OutputFile -Force
        Write-Log "Existing file deleted: $OutputFile" "WARN"
    }

#region ===================== LOG FOLDER SETUP ========================

# Skip logging for _ALL (unfiltered) versions - they are reference backups only
if (-not $Unfiltered) {
    $LogsRoot     = Join-Path $ComponentFolder "Logs"
    New-Item -ItemType Directory -Path $LogsRoot -Force | Out-Null

    $RunId        = Get-Date -Format "yyyyMMdd_HHmmss"
    $RunLogFolder = Join-Path $LogsRoot "${RunId}_generation_logs"
    New-Item -ItemType Directory -Path $RunLogFolder -Force | Out-Null

    $LogFile        = Join-Path $RunLogFolder "SecurityMigration_Generate.log"
    $TranscriptFile = Join-Path $RunLogFolder "Transcript.txt"

    $script:ActiveLogFile = $LogFile
}
else {
    $script:ActiveLogFile = $null
    $LogFile = $null
    $TranscriptFile = $null
}

#endregion

    # --- Start transcript (skip for _ALL versions) ---
$modeLabel = if ($Unfiltered) { "UNFILTERED (ALL)" } else { "FILTERED" }

if ($EnableTranscript -and -not $Unfiltered) {
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
            if ($EnableTranscript -and -not $Unfiltered) {
        try { Stop-Transcript | Out-Null } catch {}
    }
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

    if ($EnableTranscript -and -not $Unfiltered) {
    try { Stop-Transcript | Out-Null } catch {}
}
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

        [switch]$Unfiltered,

        [ValidateSet("SQLVM","SQLMI")]
        [string]$TargetType = "SQLVM",

        [string]$JobOwnerUpnSuffix
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

# Skip logging for _ALL (unfiltered) versions - they are reference backups only
if (-not $Unfiltered) {
    $LogsRoot     = Join-Path $ComponentFolder "Logs"
    New-Item -ItemType Directory -Path $LogsRoot -Force | Out-Null

    $RunId        = Get-Date -Format "yyyyMMdd_HHmmss"
    $RunLogFolder = Join-Path $LogsRoot "${RunId}_generation_logs"
    New-Item -ItemType Directory -Path $RunLogFolder -Force | Out-Null

    $LogFile        = Join-Path $RunLogFolder "SecurityMigration_Generate.log"
    $TranscriptFile = Join-Path $RunLogFolder "Transcript.txt"

    $script:ActiveLogFile = $LogFile
}
else {
    $script:ActiveLogFile = $null
    $LogFile = $null
    $TranscriptFile = $null
}

#endregion



    #region ===================== SQL SCRIPT STRING BUILDER ================

    $script:sb = New-Object System.Text.StringBuilder

    #endregion

    # --- Start transcript ---
    # --- Start transcript (skip for _ALL versions) ---
$modeLabel = if ($Unfiltered) { "UNFILTERED (ALL)" } else { "FILTERED" }

if ($EnableTranscript -and -not $Unfiltered) {
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
            if ($EnableTranscript -and -not $Unfiltered) {
        try { Stop-Transcript | Out-Null } catch {}
    }
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

    # SQLMI: remove proxy only from jobstep statements
    if ($TargetType -eq "SQLMI" -and $cleanedIndividual -match 'sp_add_jobstep') {
        $cleanedIndividual = $cleanedIndividual -replace ",?\s*@proxy_name\s*=\s*N'[^'\r\n]*'", ''
        $cleanedIndividual = $cleanedIndividual -replace ",?\s*@proxy_name\s*=\s*NULL", ''
    }

    # SQLMI: owner must be UPN; safely capture only quoted owner value
    if ($TargetType -eq "SQLMI" -and $cleanedIndividual -match 'sp_add_job' -and $cleanedIndividual -match '@owner_login_name') {
    $cleanedIndividual = [regex]::Replace(
        $cleanedIndividual,
        "@owner_login_name\s*=\s*N'([^'\r\n]*)'",
        {
            param($m)
            $ownerRaw = $m.Groups[1].Value
            $ownerSam = ($ownerRaw -split '\\')[-1]

            if ($ownerSam -ieq 'sa') {
                "@owner_login_name=N'sa'"
            }
            elseif ($ownerSam -match '@') {
                $ownerEscaped = $ownerSam -replace "'", "''"
                "@owner_login_name=N'$ownerEscaped'"
            }
            elseif ($ownerRaw -match '\\') {
                if ([string]::IsNullOrWhiteSpace($JobOwnerUpnSuffix)) {
                    throw "JobOwnerUpnSuffix is required to map Windows job owner '$ownerRaw'."
                }
                $ownerEscaped = ($ownerSam + '@' + $JobOwnerUpnSuffix.TrimStart('@')) -replace "'", "''"
                "@owner_login_name=N'$ownerEscaped'"
            }
            else {
                $ownerEscaped = $ownerRaw -replace "'", "''"
                "@owner_login_name=N'$ownerEscaped'"
            }
        }
    )
}

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
                                        # Replace MSXOperator with DBA_Notifications
                    if ($cleanedLine -match 'MSXOperator') {
                        $cleanedLine = $cleanedLine -replace 'MSXOperator', 'DBA_Notifications'
                        Write-Log "Replaced 'MSXOperator' with 'DBA_Notifications' for job: $($job.Name)" "WARN"
                    }

                    if ($TargetType -eq "SQLMI" -and $cleanedLine -match 'sp_add_jobstep' -and $cleanedLine -match '@proxy_name') {
    $cleanedLine = $cleanedLine -replace ",?\s*@proxy_name\s*=\s*N'[^'\r\n]*'", ''
    $cleanedLine = $cleanedLine -replace ",?\s*@proxy_name\s*=\s*NULL", ''
    Write-Log "Removed @proxy_name parameter (not supported on MI) for job: $($job.Name)" "WARN"
}

if ($TargetType -eq "SQLMI" -and $cleanedLine -match 'sp_add_job' -and $cleanedLine -match '@owner_login_name') {
    $cleanedLine = [regex]::Replace(
        $cleanedLine,
        "@owner_login_name\s*=\s*N'([^'\r\n]*)'",
        {
            param($m)
            $ownerRaw = $m.Groups[1].Value
            $ownerSam = ($ownerRaw -split '\\')[-1]

            if ($ownerSam -ieq 'sa') {
                "@owner_login_name=N'sa'"
            }
            elseif ($ownerSam -match '@') {
                $ownerEscaped = $ownerSam -replace "'", "''"
                "@owner_login_name=N'$ownerEscaped'"
            }
            elseif ($ownerRaw -match '\\') {
                if ([string]::IsNullOrWhiteSpace($JobOwnerUpnSuffix)) {
                    throw "JobOwnerUpnSuffix is required to map Windows job owner '$ownerRaw'."
                }
                $ownerEscaped = ($ownerSam + '@' + $JobOwnerUpnSuffix.TrimStart('@')) -replace "'", "''"
                "@owner_login_name=N'$ownerEscaped'"
            }
            else {
                $ownerEscaped = $ownerRaw -replace "'", "''"
                "@owner_login_name=N'$ownerEscaped'"
            }
        }
    )
    Write-Log "Transformed @owner_login_name for SQLMI (kept 'sa', otherwise UPN) for job: $($job.Name)" "WARN"
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

    if ($EnableTranscript -and -not $Unfiltered) {
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




# #########################################################################
#
#  GENERATE-SQLDBMAIL FUNCTION
#
#  Connects to the source server's msdb database, reads Database Mail
#  configuration (accounts, profiles, profile-account associations,
#  principal-profile access, system parameters, and SQL Agent mail
#  integration), and generates an idempotent T-SQL migration script.
#
#  SMTP relay settings are supplied explicitly from the JSON configuration.
#
#  When -TargetType is SQLMI:
#    - sp_set_sqlagent_properties is NOT used (unsupported on MI)
#    - xp_instance_regwrite is NOT used (no registry on MI)
#    - SQL Agent on MI automatically uses the default public DB Mail
#      profile — Step 7 ensures that profile is set as default
#    - WindowsIntegrated auth accounts emit a warning (not supported)
#    - A network advisory comment is included in the output
#
#  When -Unfiltered is specified the output file is suffixed with _ALL.
#
# #########################################################################




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
    $SQLLoginsScope      = if ($row.SQLLoginsMigrationScope -match "^(?i)server$") { "Server" }
                           elseif ($row.SQLLoginsMigrationScope -match "^(?i)(database|db)$") { "Database" }
                           else { "All" }
    $SQLDBMailFlag       = ($row.SQLDBMailMigrationFlag            -match "^(?i)yes$")
    $script:SourceTrustServerCertificate = $row.SourceTrustServerCertificate
    $DomainPrefix = Get-ServerObjectDomainPrefix -SourceServerName $row.SourceServerName

    # --- Read and validate TargetType (SQLVM or SQLMI) ---
    # Dynamic property lookup: handles trailing spaces or variations in CSV header name
    $rawTargetType = ($row.PSObject.Properties |
        Where-Object { $_.Name.Trim() -ieq 'TargetType' } |
        Select-Object -First 1).Value

    $TargetType = if ($rawTargetType -and -not [string]::IsNullOrWhiteSpace($rawTargetType)) {
        $rawTargetType.Trim().ToUpper()
    } else { throw "TargetType is required. This entry point requires SQLMI." }

    if ($TargetType -ne "SQLMI") {
        throw "Invalid TargetType '$rawTargetType'. Use the AzSQLVM entry point for SQLVM migrations."
    }


    if (-not ($SQLLoginsFlag -or $SQLOperatorsFlag -or $SQLAlertsFlag -or $SQLAgentsFlag -or $SQLDBMailFlag)) {
        Write-Log "No components enabled (SQLLogins/SQLOperators/SQLAlerts/SQLAgentJobs/SQLDBMail) for Source [$($row.SourceServerName)]. Skipping row." "WARN"
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
    Write-Host "  TYPE   : $TargetType"   -ForegroundColor White -BackgroundColor DarkCyan
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
        if ($TargetType -eq "SQLMI") {
            $targetOk = Test-SqlMIConnection -ServerInstance $TargetServer `
                                             -TenantId       $row.TenantId `
                                             -SubscriptionId $row.SubscriptionId
        }
        else {
            $targetOk = Test-SqlServerConnection -ServerInstance $TargetServer
        }

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
            if ($TargetType -eq "SQLMI") {
                $componentsToExecute += @{
                    Name      = "SQL Logins MI"
                    Folder    = "SQL Logins MI"
                    CleanName = "SQLLoginsMI"
                }
            }
            else {
                $componentsToExecute += @{
                    Name      = "SQL Logins"
                    Folder    = "SQL Logins"
                    CleanName = "SQLLogins"
                }
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
            $componentsToExecute += @{
                Name      = "SQL DB Mail"
                Folder    = "SQL DB Mail"
                CleanName = "SQLDBMail"
            }
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
                $runLogFolder = Join-Path $logsRoot "${runId}_execution_logs"
                New-Item -ItemType Directory -Path $runLogFolder -Force | Out-Null

                $genResult = @{
                    RunId        = $runId
                    RunLogFolder = $runLogFolder
                    OutputFile   = $scriptFile
                    ItemCount    = 1
                }

                Write-Log "Proceeding with Target Execution for $($comp.Name) on $TargetServer (no confirmation prompt)" "INFO"

                

                $execResult = Invoke-TargetExecution `
                -GenResult       $genResult `
                -SourceServer    $SourceServer `
                -TargetServer    $TargetServer `
                -ComponentName   $comp.Name `
                -TargetType      $TargetType `
                -TenantId        $row.TenantId `
                -SubscriptionId  $row.SubscriptionId

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
        $targetOk = Test-SqlMIConnection -ServerInstance $TargetServer `
            -TenantId $row.TenantId -SubscriptionId $row.SubscriptionId
        if (-not $targetOk) {
            Write-Log "TARGET server validation failed for [$TargetServer]. Skipping this row." "ERROR"
            continue
        }
    }

    Write-Log "Pre-flight validation successful for the selected execution mode." "INFO"
    Write-Log "Executed by: $ExecutingUser" "INFO"
    Write-Host "Connection successful for Source=$SourceServer, Target=$TargetServer" -ForegroundColor Green

    #endregion

    # Base folder uses short instance name (no FQDN)
    $BaseFolder = Join-Path $OutputRoot $SourceInstanceName

    # =====================================================================
    # SQL MIGRATION PROCESSING   GENERATE + EXECUTE (NO PROMPTS)
    # =====================================================================
    # Normal flow: CSV flags control intent. If TargetExecutionFlag=Yes
    # and generation produces items, execution proceeds automatically.
    # No Y/N prompts   JSON Items are the source of truth.
    # =====================================================================


    # -----------------------------------------------------------------
    # SQL Logins (SQLVM or SQLMI based on TargetType)
    # -----------------------------------------------------------------
    if ($SQLLoginsFlag) {
    try {
        if ($TargetType -eq "SQLMI") {
            $loginComponent = "SQL Logins MI"

            $genResult = Generate-SQLLoginsForMI `
                -SourceServerName $SourceServer `
                -DatabaseList     ($row.SourceListofDatabases -split ",") `
                -Component        $loginComponent `
                -BaseFolder       $BaseFolder `
                -TenantId         $row.TenantId `
                -SubscriptionId   $row.SubscriptionId `
                -Scope            $SQLLoginsScope `
                -DomainPrefix     $DomainPrefix

            if ($TargetExecutionFlag -and $genResult.ItemCount -gt 0) {
           
                Write-Log "Executing SQL Logins MI on target [$TargetServer]..." "INFO"
                $execResult = Invoke-TargetExecution `
                    -GenResult       $genResult `
                    -SourceServer    $SourceServer `
                    -TargetServer    $TargetServer `
                    -ComponentName   $loginComponent `
                    -TargetType      $TargetType `
                    -TenantId        $row.TenantId `
                    -SubscriptionId  $row.SubscriptionId
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component $loginComponent -Status $execResult.Status `
                    -OutputFile $genResult.OutputFile -ErrorMessage $execResult.ErrorMessage `
                    -Mode "Generate+Execute"
            
            }
            elseif ($TargetExecutionFlag -and $genResult.ItemCount -eq 0) {
                Write-Log "No SQL Logins MI items found on source. Skipping target execution." "WARN"
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component $loginComponent -Status "SKIPPED" -Mode "Generate"
            }
            else {
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component $loginComponent -Status "SUCCESS" `
                    -OutputFile $genResult.OutputFile -Mode "Generate"
            }

            Write-Log "Generating unfiltered SQL Logins MI (_ALL)..." "INFO"
            Generate-SQLLoginsForMI `
                -SourceServerName $SourceServer `
                -DatabaseList     ($row.SourceListofDatabases -split ",") `
                -Component        $loginComponent `
                -BaseFolder       $BaseFolder `
                -TenantId         $row.TenantId `
                -SubscriptionId   $row.SubscriptionId `
                -Scope            $SQLLoginsScope  `
                -DomainPrefix     $DomainPrefix `
                -Unfiltered | Out-Null
        }
        else {
            $loginComponent = "SQL Logins"

            $genResult = Generate-SQLLogins `
                -SourceServerName $SourceServer `
                -DatabaseList     ($row.SourceListofDatabases -split ",") `
                -Component        $loginComponent `
                -BaseFolder       $BaseFolder `
                -Scope            $SQLLoginsScope

            if ($TargetExecutionFlag -and $genResult.ItemCount -gt 0) {
            
                Write-Log "Executing SQL Logins on target [$TargetServer]..." "INFO"
                $execResult = Invoke-TargetExecution `
                    -GenResult       $genResult `
                    -SourceServer    $SourceServer `
                    -TargetServer    $TargetServer `
                    -ComponentName   $loginComponent `
                    -TargetType      $TargetType `
                    -TenantId        $row.TenantId `
                    -SubscriptionId  $row.SubscriptionId
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component $loginComponent -Status $execResult.Status `
                    -OutputFile $genResult.OutputFile -ErrorMessage $execResult.ErrorMessage `
                    -Mode "Generate+Execute"
            
            }
            elseif ($TargetExecutionFlag -and $genResult.ItemCount -eq 0) {
                Write-Log "No SQL Logins items found on source. Skipping target execution." "WARN"
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component $loginComponent -Status "SKIPPED" -Mode "Generate"
            }
            else {
                Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                    -Component $loginComponent -Status "SUCCESS" `
                    -OutputFile $genResult.OutputFile -Mode "Generate"
            }

            Write-Log "Generating unfiltered SQL Logins (_ALL)..." "INFO"
            Generate-SQLLogins `
                -SourceServerName $SourceServer `
                -DatabaseList     ($row.SourceListofDatabases -split ",") `
                -Component        $loginComponent `
                -BaseFolder       $BaseFolder `
                -Scope            $SQLLoginsScope `
                -Unfiltered | Out-Null
        }
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
                -GenResult       $genResult `
                -SourceServer    $SourceServer `
                -TargetServer    $TargetServer `
                -ComponentName   "SQL Operators" `
                -TargetType      $TargetType `
                -TenantId        $row.TenantId `
                -SubscriptionId  $row.SubscriptionId
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
                -GenResult       $genResult `
                -SourceServer    $SourceServer `
                -TargetServer    $TargetServer `
                -ComponentName   "SQL Alerts" `
                -TargetType      $TargetType `
                -TenantId        $row.TenantId `
                -SubscriptionId  $row.SubscriptionId
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
                -TargetType       $TargetType `
                -JobOwnerUpnSuffix $row.JobOwnerUpnSuffix `
                -BaseFolder       $BaseFolder

            if ($TargetExecutionFlag -and $genResult.ItemCount -gt 0) {
           
                Write-Log "Executing SQL Agent Jobs on target [$TargetServer]..." "INFO"
                $execResult = Invoke-TargetExecution `
                -GenResult       $genResult `
                -SourceServer    $SourceServer `
                -TargetServer    $TargetServer `
                -ComponentName   "SQL Agents" `
                -TargetType      $TargetType `
                -TenantId        $row.TenantId `
                -SubscriptionId  $row.SubscriptionId
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
                -TargetType       $TargetType `
                -JobOwnerUpnSuffix $row.JobOwnerUpnSuffix `
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

    # -----------------------------------------------------------------
    # SQL DB Mail
    # -----------------------------------------------------------------
    if ($SQLDBMailFlag) {
    try {
        # --- Filtered version ---
        $genResult = Generate-SQLDBMail `
            -SourceServerName $SourceServer `
            -TargetServerName $TargetServer `
            -Component        "SQL DB Mail" `
            -BaseFolder       $BaseFolder `
            -TargetType       $TargetType `
            -SmtpServer       $row.SmtpServer `
            -SmtpPort         ([int]$row.SmtpPort)

        if ($TargetExecutionFlag -and $genResult -and $genResult.ItemCount -gt 0) {
     

            Write-Log "Executing SQL DB Mail on target [$TargetServer]..." "INFO"
            $execResult = Invoke-TargetExecution `
                -GenResult       $genResult `
                -SourceServer    $SourceServer `
                -TargetServer    $TargetServer `
                -ComponentName   "SQL DB Mail" `
                -TargetType      $TargetType `
                -TenantId        $row.TenantId `
                -SubscriptionId  $row.SubscriptionId

            Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                -Component "SQL DB Mail" -Status $execResult.Status `
                -OutputFile $genResult.OutputFile -ErrorMessage $execResult.ErrorMessage `
                -Mode "Generate+Execute"
        
        }
        elseif ($TargetExecutionFlag -and $genResult -and $genResult.ItemCount -eq 0) {
            Write-Log "No SQL DB Mail config found on source. Skipping target execution." "WARN"
            Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                -Component "SQL DB Mail" -Status "SKIPPED" -Mode "Generate"
        }
        else {
            Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
                -Component "SQL DB Mail" -Status "SUCCESS" `
                -OutputFile $genResult.OutputFile -Mode "Generate"
        }

        # --- Unfiltered _ALL version (reference only, never executed) ---
        Write-Log "Generating unfiltered SQL DB Mail (_ALL)..." "INFO"
        Generate-SQLDBMail `
            -SourceServerName $SourceServer `
            -TargetServerName $TargetServer `
            -Component        "SQL DB Mail" `
            -BaseFolder       $BaseFolder `
            -TargetType       $TargetType `
            -SmtpServer       $row.SmtpServer `
            -SmtpPort         ([int]$row.SmtpPort) `
            -Unfiltered | Out-Null
    }
    catch {
        Write-Log "SQL DB Mail FAILED for [$SourceServer]: $($_.Exception.Message)" "ERROR"
        Add-MigrationResult -SourceServer $SourceServer -TargetServer $TargetServer `
            -Component "SQL DB Mail" -Status "FAILED" -ErrorMessage $_.Exception.Message
        $script:ActiveLogFile = $null
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
        Write-Host "SQL DB Mail failed. Continuing with remaining components..." -ForegroundColor Yellow
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
