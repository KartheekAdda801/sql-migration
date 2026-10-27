#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

<#
.SYNOPSIS
    Shared server-object migration utilities, generators, and reporting helpers.
.DESCRIPTION
    Dot-source from a server-object entry point for shared SQL connections,
    escaping, logging, SQL assembly, generators, and execution reporting.
    Helpers use the caller's run state; platform-specific orchestration stays
    in the entry point.
.EXAMPLE
    . (Join-Path $PSScriptRoot 'Common\ServerObjects.Helpers.ps1')
.NOTES
    Loading this file does not connect to SQL Server or Azure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:SourceTrustServerCertificate = $false

#region Functions
function Move-ServerObjectJsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    for ($Attempt = 1; $Attempt -le 10; $Attempt++) {
        try {
            [IO.File]::Move($Source, $Destination, $true)
            return
        }
        catch [IO.IOException], [UnauthorizedAccessException] {
            $Code = $_.Exception.GetBaseException().HResult -band 0xffff
            if ($Attempt -eq 10 -or $Code -notin @(5, 32, 33)) {
                throw [IO.IOException]::new("Cannot atomically replace JSON report '$Destination': $($_.Exception.Message)", $_.Exception)
            }
            Write-Verbose "JSON report '$Destination' is locked; retrying atomic replacement ($Attempt/10)."
            Start-Sleep -Milliseconds 100
        }
    }
}

function Write-ServerObjectJsonResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][object[]]$Results = @(),
        [datetime]$Started,
        [bool]$RunCompleted,
        [string]$ErrorMessage,
        [switch]$Running
    )

    $FullPath = [IO.Path]::GetFullPath($Path)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($FullPath))
    $Summary = @{
        schemaVersion = 1; operation = 'MigrateServerObjects'
        status = $(if ($Running) { 'Running' } elseif ($RunCompleted -and @($Results | Where-Object Status -eq 'FAILED').Count -eq 0) { 'Succeeded' } else { 'Failed' })
        startedAt = $Started; completedAt = $(if ($Running) { $null } else { [datetime]::UtcNow })
        results = @($Results)
        generated = @($Results | Where-Object OutputFile | Select-Object -ExpandProperty OutputFile -Unique)
        executed = @($Results | Where-Object { $_.Status -eq 'SUCCESS' -and $_.Mode -like '*Execute*' } | Select-Object -ExpandProperty Component)
        errors = @($Results | Where-Object Status -eq 'FAILED' | Select-Object SourceServer, TargetServer, Component, ErrorMessage) +
            @($ErrorMessage | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ ErrorMessage = $_ } })
    }
    $TemporaryPath = "$FullPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($TemporaryPath, (ConvertTo-Json -InputObject $Summary -Depth 20), [Text.UTF8Encoding]::new($false))
        Move-ServerObjectJsonFile -Source $TemporaryPath -Destination $FullPath
    }
    finally {
        if ([IO.File]::Exists($TemporaryPath)) { [IO.File]::Delete($TemporaryPath) }
    }
}

function Get-ServerObjectDomainPrefix {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SourceServerName)
    ($SourceServerName.Trim() -split '\\', 2)[0]
}

function Get-ServerObjectSecurityDatabaseNames {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AvailableNames,
        [Parameter(Mandatory)][string[]]$DatabaseList,
        [ValidateSet('All', 'Server', 'Database', 'DB')][string]$Scope = 'All'
    )
    $Requested = @($DatabaseList | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    if (-not $Requested.Count -or $Requested -contains '' -or ('All' -in $Requested -and $Requested.Count -ne 1)) {
        throw 'SourceListofDatabases must contain explicit nonempty database names or All by itself.'
    }
    if ($Requested -notcontains 'All') {
        foreach ($Name in $Requested) {
            if ($Name -notin $AvailableNames) { throw "Selected database '$Name' is missing or offline." }
        }
    }
    $SystemNames = @('master', 'msdb', 'model', 'tempdb')
    @($AvailableNames | Where-Object {
        if ($Scope -eq 'Server') { $_ -in @('master', 'msdb') -and ($Requested -contains 'All' -or $_ -in $Requested) }
        elseif ($_ -in $SystemNames) { $Scope -eq 'All' }
        else { $Requested -contains 'All' -or $_ -in $Requested }
    } | Select-Object -Unique)
}

function Get-OutOfScopeJobDatabase {
    [CmdletBinding()]
    [OutputType([string])]
    param([object[]]$Steps, [string[]]$Databases)

    $Allowed = @($Databases) + @('master', 'model', 'msdb', 'tempdb')
    $Steps | Where-Object {
        $_.SubSystem -eq 'TransactSql' -and
        -not [string]::IsNullOrWhiteSpace($_.DatabaseName) -and $_.DatabaseName -notin $Allowed
    } | Select-Object -ExpandProperty DatabaseName -Unique
}

function Get-DisabledImportedJobSql {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$JobName)

    "USE [msdb];`nEXEC msdb.dbo.sp_update_job @job_name = N'$($JobName.Replace("'", "''"))', @enabled = 0;`nGO`n"
}

function Convert-DatabaseMailSender {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Value, [string]$SourceServerName, [string]$TargetServerName)

    $SourceShort = ($SourceServerName -split '[.\\]')[0]
    $TargetShort = ($TargetServerName -split '[.\\]')[0]
    if ([string]::IsNullOrWhiteSpace($SourceShort) -or [string]::IsNullOrWhiteSpace($TargetShort)) {
        throw 'Source and target server names are required for Database Mail rewriting.'
    }
    $Value.Replace($SourceShort, $TargetShort, [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-ServerObjectJobUpsertSql {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Sql)
    if (-not ('Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser' -as [type])) {
        $Module = Get-Module SqlServer -ListAvailable | Select-Object -First 1
        if (-not $Module) { throw 'SqlServer module is required to parse SQL Agent job scripts.' }
        Add-Type -Path (Join-Path $Module.ModuleBase 'coreclr\Microsoft.SqlServer.TransactSql.ScriptDom.dll') -ErrorAction Stop
    }
    # Rewrite EXEC nodes, never SQL text embedded inside a job step's command string.
    $Parser = [Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser]::new($true)
    $Reader = [IO.StringReader]::new($Sql)
    $Errors = $null
    try { $Tree = $Parser.Parse($Reader, [ref]$Errors) }
    finally { $Reader.Dispose() }
    if ($Errors.Count) { throw "Cannot parse SQL Agent script: $($Errors[0].Message)" }
    $Nodes = [Collections.Generic.Stack[object]]::new()
    $Nodes.Push($Tree)
    $Edits = [Collections.Generic.List[object]]::new()
    $Text = { param($Fragment) $Sql.Substring($Fragment.StartOffset, $Fragment.FragmentLength) }
    while ($Nodes.Count) {
        $Node = $Nodes.Pop()
        foreach ($Property in $Node.GetType().GetProperties()) {
            if ($Property.Name -eq 'ScriptTokenStream' -or $Property.GetIndexParameters().Count) { continue }
            $Value = $Property.GetValue($Node)
            if ($Value -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) { $Nodes.Push($Value) }
            elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
                foreach ($Child in $Value) {
                    if ($Child -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) { $Nodes.Push($Child) }
                }
            }
        }
        if ($Node -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.ExecuteStatement]) { continue }
        $Entity = $Node.ExecuteSpecification.ExecutableEntity
        if ($Entity -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.ExecutableProcedureReference]) { continue }
        $Reference = $Entity.ProcedureReference.ProcedureReference
        if (-not $Reference -or -not $Reference.Name) { continue }
        $Procedure = $Reference.Name.BaseIdentifier.Value
        if ($Procedure -notin @('sp_add_job', 'sp_add_jobstep', 'sp_add_jobschedule', 'sp_add_jobserver')) { continue }
        if (($Reference.Name.SchemaIdentifier -and $Reference.Name.SchemaIdentifier.Value -ne 'dbo') -or
            ($Reference.Name.DatabaseIdentifier -and $Reference.Name.DatabaseIdentifier.Value -ne 'msdb')) { continue }
        $Parameters = @{}
        foreach ($Parameter in $Entity.Parameters) {
            if (-not $Parameter.Variable) { throw "Named parameters are required for $Procedure." }
            $Parameters[$Parameter.Variable.Name.ToLowerInvariant()] = $Parameter
        }
        $Prefix = 'EXEC '
        if ($Node.ExecuteSpecification.Variable) { $Prefix += "$($Node.ExecuteSpecification.Variable.Name) = " }
        $Create = (& $Text $Node).TrimEnd().TrimEnd(';')
        $Assignments = [Collections.Generic.List[string]]::new()
        $JobId = if ($Parameters.ContainsKey('@job_id')) { & $Text $Parameters['@job_id'].ParameterValue } else { '' }
        switch ($Procedure) {
            sp_add_job {
                if (-not $Parameters.ContainsKey('@job_name')) { throw 'Job script is missing @job_name.' }
                $Name = & $Text $Parameters['@job_name'].ParameterValue
                foreach ($Parameter in $Entity.Parameters) {
                    if ($Parameter.Variable.Name -notin @('@job_name', '@job_id')) {
                        $Assignments.Add("$($Parameter.Variable.Name) = $(& $Text $Parameter.ParameterValue)")
                    }
                }
                if ($JobId) {
                    if ($Parameters['@job_id'].ParameterValue -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.VariableReference] -or
                        -not $Parameters['@job_id'].IsOutput) { throw 'Job creation requires a variable @job_id OUTPUT parameter.' }
                    $Assignments.Insert(0, "@job_id = $JobId")
                    $Lookup = "SET $JobId = NULL;`nSELECT $JobId = job_id FROM msdb.dbo.sysjobs WHERE name = $Name;"
                    $Condition = "$JobId IS NULL"
                }
                else {
                    $Assignments.Insert(0, "@job_name = $Name")
                    $Lookup = ''
                    $Condition = "NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = $Name)"
                }
                $Replacement = @"
$Lookup
IF $Condition
BEGIN
    $Create;
END
ELSE
BEGIN
    ${Prefix}msdb.dbo.sp_update_job $($Assignments -join ', ');
END
"@
            }
            sp_add_jobstep {
                if (-not $JobId -or -not $Parameters.ContainsKey('@step_id')) { throw 'Job step script requires @job_id and @step_id.' }
                $StepId = & $Text $Parameters['@step_id'].ParameterValue
                foreach ($Parameter in $Entity.Parameters) {
                    if ($Parameter.Variable.Name -ne '@step_uid') {
                        $Assignments.Add("$($Parameter.Variable.Name) = $(& $Text $Parameter.ParameterValue)")
                    }
                }
                $Replacement = @"
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps WHERE job_id = $JobId AND step_id = $StepId)
BEGIN
    ${Prefix}msdb.dbo.sp_update_jobstep $($Assignments -join ', ');
END
ELSE
BEGIN
    $Create;
END
"@
            }
            sp_add_jobschedule {
                if (-not $JobId -or -not $Parameters.ContainsKey('@name')) { throw 'Job schedule script requires @job_id and @name.' }
                $Name = & $Text $Parameters['@name'].ParameterValue
                $ScheduleId = "@MigrationSchedule$($Node.StartOffset)"
                $CreateParameters = [Collections.Generic.List[string]]::new()
                foreach ($Parameter in $Entity.Parameters) {
                    if ($Parameter.Variable.Name -notin @('@schedule_uid', '@schedule_id')) {
                        $Assignment = "$($Parameter.Variable.Name) = $(& $Text $Parameter.ParameterValue)"
                        $CreateParameters.Add($Assignment)
                        if ($Parameter.Variable.Name -notin @('@job_id', '@name')) { $Assignments.Add($Assignment) }
                    }
                }
                $Assignments.Insert(0, "@schedule_id = $ScheduleId")
                $Create = "${Prefix}msdb.dbo.sp_add_jobschedule $($CreateParameters -join ', ')"
                $Replacement = @"
DECLARE $ScheduleId int;
IF (SELECT COUNT(*) FROM msdb.dbo.sysschedules s
    JOIN msdb.dbo.sysjobschedules j ON j.schedule_id = s.schedule_id
    WHERE j.job_id = $JobId AND s.name = $Name) > 1
    THROW 51000, 'Multiple attached job schedules have the same name; resolve before rerunning.', 1;
SELECT $ScheduleId = s.schedule_id FROM msdb.dbo.sysschedules s
JOIN msdb.dbo.sysjobschedules j ON j.schedule_id = s.schedule_id
WHERE j.job_id = $JobId AND s.name = $Name;
IF $ScheduleId IS NULL
BEGIN
    $Create;
END
ELSE IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobschedules WHERE schedule_id = $ScheduleId AND job_id <> $JobId)
BEGIN
    EXEC msdb.dbo.sp_detach_schedule @job_id = $JobId, @schedule_id = $ScheduleId, @delete_unused_schedule = 0;
    IF @@ERROR <> 0 THROW 51000, 'Cannot detach shared schedule for this job.', 1;
    $Create;
END
ELSE
BEGIN
    ${Prefix}msdb.dbo.sp_update_schedule $($Assignments -join ', ');
END
"@
            }
            sp_add_jobserver {
                if (-not $JobId) { throw 'Job server script requires @job_id.' }
                $Replacement = @"
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobservers WHERE job_id = $JobId)
BEGIN
    $Create;
END
"@
            }
        }
        $Edits.Add([pscustomobject]@{ Start = $Node.StartOffset; Length = $Node.FragmentLength; Text = $Replacement })
    }
    foreach ($Edit in ($Edits | Sort-Object Start -Descending)) { $Sql = $Sql.Remove($Edit.Start, $Edit.Length).Insert($Edit.Start, $Edit.Text) }
    $Sql
}

function Generate-SQLDBMail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceServerName,
        [Parameter(Mandatory = $true)]
        [string]$TargetServerName,

        [Parameter(Mandatory = $true)]
        [string]$Component,

        [Parameter(Mandatory = $true)]
        [string]$BaseFolder,

        [ValidateSet("SQLVM","SQLMI")]
        [string]$TargetType = "SQLVM",

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SmtpServer,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$SmtpPort,

        [switch]$Unfiltered,
        [switch]$PreserveSourceSettings
    )

    # =====================================================================
    # FIXED SMTP RELAY SETTINGS
    # =====================================================================

    $FixedSmtpServer = $SmtpServer
    $FixedSmtpPort   = $SmtpPort

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
    Write-Log "===== SQL DB Mail Generation Started ($modeLabel) =====" "INFO"
    Write-Log "Source     : $SourceServerName" "INFO"
    Write-Log "TargetType : $TargetType" "INFO"
    Write-Log "SMTP Relay : ${FixedSmtpServer}:${FixedSmtpPort} (from config)" "INFO"
    Write-Log "Output     : $OutputFile" "INFO"

    # =====================================================================
    # SQL BUILDER
    # =====================================================================

    $script:sb = New-Object System.Text.StringBuilder
    $itemCount = 0

    Add-Sql "/* ========================================================="
    Add-Sql "   Database Mail Configuration Script ($modeLabel)"
    Add-Sql "   Source      : $SourceServerName"
    Add-Sql "   TargetType  : $TargetType"
    Add-Sql "   SMTP Relay  : ${FixedSmtpServer}:${FixedSmtpPort}"
    Add-Sql "   Generated   : $(Get-Date)"
    Add-Sql "========================================================= */"
    Add-Sql ""

    # =====================================================================
    # SQLMI ADVISORY HEADER
    # =====================================================================

    if ($TargetType -eq "SQLMI") {
        Add-Sql "/* ========================================================="
        Add-Sql "   AZURE SQL MANAGED INSTANCE — IMPORTANT NOTES"
        Add-Sql "   ---------------------------------------------------------"
        Add-Sql "   1. SMTP relay is set to ${FixedSmtpServer}:${FixedSmtpPort}."
        Add-Sql "      Ensure MI VNet can reach this relay (peering/private IP)."
        Add-Sql "   2. Windows Integrated authentication (@use_default_credentials=1)"
        Add-Sql "      is NOT supported on MI. Only Anonymous or Basic auth work."
        Add-Sql "      Accounts using Windows Integrated are commented out below."
        Add-Sql "   3. sp_set_sqlagent_properties and xp_instance_regwrite are"
        Add-Sql "      NOT supported on MI. SQL Agent on MI automatically uses"
        Add-Sql "      the default public Database Mail profile."
        Add-Sql "========================================================= */"
        Add-Sql ""
    }

    # =====================================================================
    # STEP 1: ENABLE DATABASE MAIL XPs (both SQLVM and SQLMI)
    # =====================================================================

    Add-Sql "/* ==================== ENABLE DATABASE MAIL XPs ==================== */"
    Add-Sql ""
    Add-Sql "EXEC sp_configure 'show advanced options', 1;"
    Add-Sql "RECONFIGURE;"
    Add-Sql "EXEC sp_configure 'Database Mail XPs', 1;"
    Add-Sql "RECONFIGURE;"
    Add-Sql "PRINT 'Database Mail XPs enabled.';"
    Add-Sql "GO"
    Add-Sql ""
    $itemCount++

    # =====================================================================
    # STEP 2: DATABASE MAIL ACCOUNTS
    # =====================================================================

    $accounts = Invoke-SqlcmdLogged `
        -ServerInstance $SourceServerName `
        -Database "msdb" `
        -Context "Fetch Database Mail Accounts" `
        -Query @"
SELECT
    a.account_id,
    a.name              AS AccountName,
    a.description,
    a.email_address,
    a.display_name,
    a.replyto_address,
    s.servertype,
    s.servername         AS mailserver_name,
    s.port,
    s.username,
    s.use_default_credentials,
    s.enable_ssl
FROM msdb.dbo.sysmail_account a
JOIN msdb.dbo.sysmail_server s ON a.account_id = s.account_id
ORDER BY a.name
"@

    if ($accounts -and @($accounts).Count -gt 0) {
        Add-Sql "/* ==================== DATABASE MAIL ACCOUNTS ==================== */"
        if (-not $PreserveSourceSettings) {
            Add-Sql "/* NOTE: SMTP server overridden to ${FixedSmtpServer}:${FixedSmtpPort}"
            Add-Sql "   for all accounts regardless of source configuration. */"
        }
        Add-Sql ""
        Write-Log "Found $(@($accounts).Count) mail account(s)" "INFO"

        foreach ($acc in $accounts) {
            $accName    = Escape-SqlLiteral $acc.AccountName
            $desc       = Escape-SqlLiteral $acc.description
            $email      = Escape-SqlLiteral $(if ($PreserveSourceSettings) { $acc.email_address } else { Convert-DatabaseMailSender -Value $acc.email_address -SourceServerName $SourceServerName -TargetServerName $TargetServerName })
            $display    = Escape-SqlLiteral $(if ($PreserveSourceSettings) { $acc.display_name } else { Convert-DatabaseMailSender -Value $acc.display_name -SourceServerName $SourceServerName -TargetServerName $TargetServerName })
            $replyTo    = Escape-SqlLiteral $acc.replyto_address
            $serverType = if ($acc.servertype) { Escape-SqlLiteral $acc.servertype } else { "SMTP" }
            $useDefCred = if ($acc.use_default_credentials -eq 1) { 1 } else { 0 }
            $enableSsl  = if ($acc.enable_ssl -eq 1) { 1 } else { 0 }
            $username   = if ($acc.username) { "N'$(Escape-SqlLiteral $acc.username)'" } else { "NULL" }

            # Override SMTP server and port with fixed values
            $mailServer = Escape-SqlLiteral $(if ($PreserveSourceSettings) { $acc.mailserver_name } else { $FixedSmtpServer })
            $port       = if ($PreserveSourceSettings) { $acc.port } else { $FixedSmtpPort }

            if (-not $PreserveSourceSettings -and ($acc.mailserver_name -ne $FixedSmtpServer -or $acc.port -ne $FixedSmtpPort)) {
                Write-Log "Account '$($acc.AccountName)': overriding SMTP from $($acc.mailserver_name):$($acc.port) -> ${FixedSmtpServer}:${FixedSmtpPort}" "WARN"
            }

            # Check for Windows Integrated on MI — not supported
            $isWindowsIntegrated = ($useDefCred -eq 1)
            $commentOut = (-not $PreserveSourceSettings -and $TargetType -eq "SQLMI" -and $isWindowsIntegrated)

            if ($commentOut) {
                Write-Log "Account '$($acc.AccountName)' uses Windows Integrated auth — commenting out for MI." "WARN"
                Add-Sql "/* WARNING: Account '$accName' uses @use_default_credentials=1 (Windows Integrated)."
                Add-Sql "   This is NOT supported on Azure SQL MI. Change to Anonymous or Basic auth."
                Add-Sql "   Uncomment and fix the authentication before executing. */"
                Add-Sql ""
            }

            Write-Log "Processing mail account: $($acc.AccountName)"

            $prefix = if ($commentOut) { "-- " } else { "" }

            Add-Sql "${prefix}USE [msdb];"
            Add-Sql "${prefix}IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = N'$accName')"
            Add-Sql "${prefix}BEGIN"
            Add-Sql "${prefix}    EXEC msdb.dbo.sysmail_add_account_sp"
            Add-Sql "${prefix}        @account_name            = N'$accName',"
            Add-Sql "${prefix}        @email_address           = N'$email',"
            Add-Sql "${prefix}        @display_name            = N'$display',"
            Add-Sql "${prefix}        @replyto_address         = N'$replyTo',"
            Add-Sql "${prefix}        @description             = N'$desc',"
            Add-Sql "${prefix}        @mailserver_name         = N'$mailServer',"
            Add-Sql "${prefix}        @mailserver_type         = N'$serverType',"
            Add-Sql "${prefix}        @port                    = $port,"
            Add-Sql "${prefix}        @username                = $username,"
            Add-Sql "${prefix}        @use_default_credentials = $useDefCred,"
            Add-Sql "${prefix}        @enable_ssl              = $enableSsl;"
            Add-Sql "${prefix}    PRINT 'Account created: $accName';"
            Add-Sql "${prefix}END"
            Add-Sql "${prefix}ELSE"
            Add-Sql "${prefix}BEGIN"
            Add-Sql "${prefix}    EXEC msdb.dbo.sysmail_update_account_sp"
            Add-Sql "${prefix}        @account_name            = N'$accName',"
            Add-Sql "${prefix}        @email_address           = N'$email',"
            Add-Sql "${prefix}        @display_name            = N'$display',"
            Add-Sql "${prefix}        @replyto_address         = N'$replyTo',"
            Add-Sql "${prefix}        @description             = N'$desc',"
            Add-Sql "${prefix}        @mailserver_name         = N'$mailServer',"
            Add-Sql "${prefix}        @mailserver_type         = N'$serverType',"
            Add-Sql "${prefix}        @port                    = $port,"
            Add-Sql "${prefix}        @username                = $username,"
            Add-Sql "${prefix}        @use_default_credentials = $useDefCred,"
            Add-Sql "${prefix}        @enable_ssl              = $enableSsl;"
            Add-Sql "${prefix}    PRINT 'Account updated: $accName';"
            Add-Sql "${prefix}END"
            Add-Sql "${prefix}GO"
            Add-Sql ""
            $itemCount++
        }
    }
    else {
        Write-Log "No Database Mail accounts found on source." "WARN"
    }

    # =====================================================================
    # STEP 3: DATABASE MAIL PROFILES
    # =====================================================================

    $profiles = Invoke-SqlcmdLogged `
        -ServerInstance $SourceServerName `
        -Database "msdb" `
        -Context "Fetch Database Mail Profiles" `
        -Query @"
SELECT profile_id, name AS ProfileName, description
FROM msdb.dbo.sysmail_profile
ORDER BY name
"@

    if ($profiles -and @($profiles).Count -gt 0) {
        Add-Sql "/* ==================== DATABASE MAIL PROFILES ==================== */"
        Add-Sql ""
        Write-Log "Found $(@($profiles).Count) mail profile(s)" "INFO"

        foreach ($prof in $profiles) {
            $profName = Escape-SqlLiteral $prof.ProfileName
            $profDesc = Escape-SqlLiteral $prof.description

            Write-Log "Processing mail profile: $($prof.ProfileName)"

            Add-Sql @"
USE [msdb];
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = N'$profName')
BEGIN
    EXEC msdb.dbo.sysmail_add_profile_sp
        @profile_name = N'$profName',
        @description  = N'$profDesc';
    PRINT 'Profile created: $profName';
END
ELSE
BEGIN
    EXEC msdb.dbo.sysmail_update_profile_sp
        @profile_name = N'$profName',
        @description = N'$profDesc';
END
GO

"@
            $itemCount++
        }
    }
    else {
        Write-Log "No Database Mail profiles found on source." "WARN"
    }

    # =====================================================================
    # STEP 4: PROFILE-ACCOUNT ASSOCIATIONS
    # =====================================================================

    $profileAccounts = Invoke-SqlcmdLogged `
        -ServerInstance $SourceServerName `
        -Database "msdb" `
        -Context "Fetch Profile-Account Associations" `
        -Query @"
SELECT
    p.name AS ProfileName,
    a.name AS AccountName,
    pa.sequence_number
FROM msdb.dbo.sysmail_profileaccount pa
JOIN msdb.dbo.sysmail_profile p ON pa.profile_id = p.profile_id
JOIN msdb.dbo.sysmail_account a ON pa.account_id = a.account_id
ORDER BY p.name, pa.sequence_number
"@

    if ($profileAccounts -and @($profileAccounts).Count -gt 0) {
        Add-Sql "/* ==================== PROFILE-ACCOUNT ASSOCIATIONS ==================== */"
        Add-Sql ""

        foreach ($pa in $profileAccounts) {
            $profName = Escape-SqlLiteral $pa.ProfileName
            $accName  = Escape-SqlLiteral $pa.AccountName
            $seqNum   = $pa.sequence_number

            Write-Log "Associating account '$($pa.AccountName)' -> profile '$($pa.ProfileName)' (seq: $seqNum)"

            Add-Sql @"
USE [msdb];
IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_profileaccount pa
    JOIN msdb.dbo.sysmail_profile p ON pa.profile_id = p.profile_id
    JOIN msdb.dbo.sysmail_account a ON pa.account_id = a.account_id
    WHERE p.name = N'$profName' AND a.name = N'$accName'
)
BEGIN
    EXEC msdb.dbo.sysmail_add_profileaccount_sp
        @profile_name    = N'$profName',
        @account_name    = N'$accName',
        @sequence_number = $seqNum;
    PRINT 'Associated [$accName] -> [$profName] (seq $seqNum)';
END
ELSE
BEGIN
    EXEC msdb.dbo.sysmail_update_profileaccount_sp
        @profile_name = N'$profName',
        @account_name = N'$accName',
        @sequence_number = $seqNum;
END
GO

"@
            $itemCount++
        }
    }

    # =====================================================================
    # STEP 5: PRINCIPAL-PROFILE ACCESS (public / default)
    # =====================================================================

    $principalProfiles = Invoke-SqlcmdLogged `
        -ServerInstance $SourceServerName `
        -Database "msdb" `
        -Context "Fetch Principal-Profile Associations" `
        -Query @"
SELECT
    p.name AS ProfileName,
    pp.is_default,
    CASE
        WHEN CAST(pp.principal_sid AS VARBINARY(85)) = 0x00 THEN 'public'
        ELSE SUSER_SNAME(pp.principal_sid)
    END AS PrincipalName
FROM msdb.dbo.sysmail_principalprofile pp
JOIN msdb.dbo.sysmail_profile p ON pp.profile_id = p.profile_id
ORDER BY p.name
"@

    if ($principalProfiles -and @($principalProfiles).Count -gt 0) {
        Add-Sql "/* ==================== PRINCIPAL-PROFILE ACCESS ==================== */"
        Add-Sql ""

        foreach ($pp in $principalProfiles) {
            $profName  = Escape-SqlLiteral $pp.ProfileName
            $principal = if ($pp.PrincipalName) { Escape-SqlLiteral $pp.PrincipalName } else { "public" }
            $isDefault = if ($pp.is_default -eq 1) { 1 } else { 0 }

            $existsCheck = if ($principal -eq "public") {
                "CAST(pp.principal_sid AS VARBINARY(85)) = 0x00"
            } else {
                "SUSER_SNAME(pp.principal_sid) = N'$principal'"
            }

            Write-Log "Granting profile '$($pp.ProfileName)' to '$principal' (default: $isDefault)"

            Add-Sql @"
USE [msdb];
IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_principalprofile pp
    JOIN msdb.dbo.sysmail_profile p ON pp.profile_id = p.profile_id
    WHERE p.name = N'$profName'
      AND $existsCheck
)
BEGIN
    EXEC msdb.dbo.sysmail_add_principalprofile_sp
        @profile_name   = N'$profName',
        @principal_name = N'$principal',
        @is_default     = $isDefault;
    PRINT 'Granted [$profName] to [$principal] (default: $isDefault)';
END
ELSE
BEGIN
    EXEC msdb.dbo.sysmail_update_principalprofile_sp
        @profile_name = N'$profName',
        @principal_name = N'$principal',
        @is_default = $isDefault;
END
GO

"@
            $itemCount++
        }
    }

    # =====================================================================
    # STEP 6: SYSTEM PARAMETERS (sysmail_configuration)
    # =====================================================================

    $sysParams = Invoke-SqlcmdLogged `
        -ServerInstance $SourceServerName `
        -Database "msdb" `
        -Context "Fetch Database Mail System Parameters" `
        -Query @"
SELECT paramname, paramvalue, description
FROM msdb.dbo.sysmail_configuration
ORDER BY paramname
"@

    if ($sysParams -and @($sysParams).Count -gt 0) {
        Add-Sql "/* ==================== DATABASE MAIL SYSTEM PARAMETERS ==================== */"
        Add-Sql ""

        foreach ($sp in $sysParams) {
            $paramName  = Escape-SqlLiteral $sp.paramname
            $paramValue = Escape-SqlLiteral $sp.paramvalue
            $paramDesc  = Escape-SqlLiteral $sp.description

            Add-Sql @"
USE [msdb];
EXEC msdb.dbo.sysmail_configure_sp
    @parameter_name  = N'$paramName',
    @parameter_value = N'$paramValue',
    @description     = N'$paramDesc';
GO

"@
            $itemCount++
        }
        Write-Log "Processed $(@($sysParams).Count) system parameter(s)" "INFO"
    }

    # =====================================================================
    # STEP 7: SQL SERVER AGENT MAIL INTEGRATION
    # =====================================================================

    $agentMailProfile = Invoke-SqlcmdLogged `
        -ServerInstance $SourceServerName `
        -Database "msdb" `
        -Context "Fetch SQL Agent Mail Profile" `
        -ContinueOnError `
        -Query @"
DECLARE @profile NVARCHAR(256);
EXEC master.dbo.xp_instance_regread
    N'HKEY_LOCAL_MACHINE',
    N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
    N'DatabaseMailProfile',
    @profile OUTPUT;
SELECT ISNULL(@profile, '') AS AgentMailProfile;
"@

    $agentProfile = if ($agentMailProfile -and $agentMailProfile.AgentMailProfile) {
        $agentMailProfile.AgentMailProfile
    } else { "" }

    if ($agentProfile) {
        $escapedAgentProfile = Escape-SqlLiteral $agentProfile

        Add-Sql "/* ==================== SQL SERVER AGENT MAIL INTEGRATION ==================== */"
        Add-Sql ""

        if ($TargetType -eq "SQLMI") {
            # MI does not support sp_set_sqlagent_properties or xp_instance_regwrite.
            # SQL Agent on MI automatically uses the default public Database Mail profile.
            # This block ensures the desired profile is set as the default public profile.

            Add-Sql @"
/* On Azure SQL MI, SQL Agent automatically uses the default public
   Database Mail profile. sp_set_sqlagent_properties and xp_instance_regwrite
   are NOT supported on MI.
   The block below ensures '$escapedAgentProfile' is set as the default
   public profile so SQL Agent picks it up automatically. */

USE [msdb];
IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_principalprofile pp
    JOIN msdb.dbo.sysmail_profile p ON pp.profile_id = p.profile_id
    WHERE p.name = N'$escapedAgentProfile'
      AND CAST(pp.principal_sid AS VARBINARY(85)) = 0x00
      AND pp.is_default = 1
)
BEGIN
    -- Remove default flag from any existing default public profile
    DECLARE @oldProfileId INT;
    SELECT @oldProfileId = pp.profile_id
    FROM msdb.dbo.sysmail_principalprofile pp
    WHERE CAST(pp.principal_sid AS VARBINARY(85)) = 0x00
      AND pp.is_default = 1;

    IF @oldProfileId IS NOT NULL
    BEGIN
        DECLARE @oldProfileName NVARCHAR(256);
        SELECT @oldProfileName = name FROM msdb.dbo.sysmail_profile WHERE profile_id = @oldProfileId;
        EXEC msdb.dbo.sysmail_update_principalprofile_sp
            @profile_name   = @oldProfileName,
            @principal_name = N'public',
            @is_default     = 0;
        PRINT 'Removed default flag from previous profile: ' + @oldProfileName;
    END

    -- Set the target profile as default public
    IF EXISTS (
        SELECT 1
        FROM msdb.dbo.sysmail_principalprofile pp
        JOIN msdb.dbo.sysmail_profile p ON pp.profile_id = p.profile_id
        WHERE p.name = N'$escapedAgentProfile'
          AND CAST(pp.principal_sid AS VARBINARY(85)) = 0x00
    )
    BEGIN
        EXEC msdb.dbo.sysmail_update_principalprofile_sp
            @profile_name   = N'$escapedAgentProfile',
            @principal_name = N'public',
            @is_default     = 1;
    END
    ELSE
    BEGIN
        EXEC msdb.dbo.sysmail_add_principalprofile_sp
            @profile_name   = N'$escapedAgentProfile',
            @principal_name = N'public',
            @is_default     = 1;
    END

    PRINT 'Set [$escapedAgentProfile] as default public profile for SQL Agent on MI.';
END
ELSE
    PRINT 'Profile [$escapedAgentProfile] is already the default public profile.';
GO

"@
            Write-Log "SQL Agent mail profile (MI mode): '$agentProfile' — ensured as default public profile." "INFO"
        }
        else {
            # SQLVM: use sp_set_sqlagent_properties and xp_instance_regwrite
            Add-Sql @"
USE [msdb];
EXEC msdb.dbo.sp_set_sqlagent_properties
    @email_save_in_sent_folder = 1;
GO

EXEC master.dbo.xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE',
    N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
    N'UseDatabaseMail', N'REG_DWORD', 1;
GO

EXEC master.dbo.xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE',
    N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
    N'DatabaseMailProfile', N'REG_SZ', N'$escapedAgentProfile';
GO

PRINT 'SQL Server Agent configured to use DB Mail profile: $escapedAgentProfile';
GO

"@
            Write-Log "SQL Agent mail profile (VM mode): $agentProfile" "INFO"
        }
        $itemCount++
    }
    else {
        Write-Log "No SQL Agent mail profile configured on source." "WARN"
    }

    # =====================================================================
    # WRITE FILE
    # =====================================================================

    if ($itemCount -eq 0) {
        Write-Log "No Database Mail configuration found on source. No output file written." "WARN"
    }
    else {
        $script:sb.ToString() | Out-File -FilePath $OutputFile -Encoding UTF8
        Write-Log "Database Mail script generated: $OutputFile ($itemCount item(s))" "INFO"
    }

    $elapsed = New-TimeSpan -Start $ScriptStart -End (Get-Date)
    Write-Log "===== Generation completed ($modeLabel). Duration: $($elapsed.ToString()) =====" "INFO"

    if ($EnableTranscript -and -not $Unfiltered) {
    try { Stop-Transcript | Out-Null } catch {}
}
    Write-Log "===== SQL DB Mail Generation Completed ($modeLabel) =====" "SUCCESS"
    $script:ActiveLogFile = $null

    return @{
        RunId        = $RunId
        RunLogFolder = $RunLogFolder
        OutputFile   = $OutputFile
        ItemCount    = $itemCount
    }
}
function Test-FileExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$FileType = "File"
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$FileType path is empty."
    }

    if (-not (Test-Path $Path)) {
        throw "$FileType not found: $Path"
    }

    if ((Get-Item $Path).PSIsContainer) {
        throw "$FileType path is a directory: $Path"
    }
}

<#
.SYNOPSIS
    Writes a timestamped, colour-coded message to the console and
    optionally appends it to the active log file.
#>
function Write-Log {
    param(
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO",

        [string]$LogFile = $script:ActiveLogFile
    )

    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    if ($Level -eq 'ERROR') { $script:MigrationHadErrors = $true }
    $color = switch ($Level) {
        "INFO"    { "Cyan"   }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red"    }
        "SUCCESS" { "Green"  }
    }

    Write-Host "$ts [$Level] $Message" -ForegroundColor $color

    if ($LogFile) {
        Add-Content -Path $LogFile -Value "$ts [$Level] $Message"
    }
}

<#
.SYNOPSIS
    Executes an encrypted Windows-authenticated query with the requested
    certificate policy. The default preserves legacy target behavior.
#>
function Invoke-SqlcmdSafe {
    param(
        [string]$ServerInstance,
        [string]$Database,
        [string]$Query,
        [bool]$TrustServerCertificate = $true
    )

    $cmd           = Get-Command Invoke-Sqlcmd -ErrorAction Stop
    $hasTrustParam = $cmd.Parameters.ContainsKey("TrustServerCertificate")

    if ($hasTrustParam) {
        $Encryption = if ($cmd.Parameters.ContainsKey('Encrypt')) {
            @{ Encrypt = 'Mandatory' }
        } else { @{ EncryptConnection = $true } }
        return Invoke-Sqlcmd -ServerInstance $ServerInstance `
                             -Database $Database `
                             -Query $Query `
                             @Encryption -TrustServerCertificate:$TrustServerCertificate `
                             -ErrorAction Stop
    }
    else {
        $cs = "Server=$ServerInstance;Database=$Database;" +
              "Integrated Security=True;Encrypt=True;TrustServerCertificate=$TrustServerCertificate;"
        return Invoke-Sqlcmd -ConnectionString $cs -Query $Query -ErrorAction Stop
    }
}

<#
.SYNOPSIS
    Quick connectivity check runs SELECT @@SERVERNAME against the
    target instance and returns $true / $false.
#>
function Test-SqlServerConnection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerInstance,

        [string]$Database = "master",
        [bool]$TrustServerCertificate = $true
    )

    try {
        Write-Log "Validating connectivity to [$ServerInstance]..." "INFO"
        Invoke-SqlcmdSafe -ServerInstance $ServerInstance `
                          -Database $Database `
                          -Query "SELECT @@SERVERNAME AS ServerName;" `
                          -TrustServerCertificate:$TrustServerCertificate | Out-Null
        Write-Log "Connection successful: [$ServerInstance]" "INFO"
        return $true
    }
    catch {
        Write-Log "Connection FAILED: [$ServerInstance]." "ERROR"
        return $false
    }
}

<#
.SYNOPSIS
    Returns $true when the given DOMAIN\SamAccountName can be resolved
    as either an AD user or an AD group.  Non-domain principals are
    assumed valid.
#>
function Test-ADPrincipalExists {
    param([string]$Principal)

    if ([string]::IsNullOrWhiteSpace($Principal)) { return $false }
    if ($Principal -notlike "*\*")                 { return $true  }

    $parts = $Principal.Split('\', 2)
    if ($parts.Count -lt 2) { return $false }
    $name = $parts[1]

    try { if (Get-ADUser  -Filter "SamAccountName -eq '$name'" -ErrorAction Stop) { return $true } } catch {}
    try { if (Get-ADGroup -Filter "SamAccountName -eq '$name'" -ErrorAction Stop) { return $true } } catch {}

    return $false
}

<#  Escape single-quotes for use inside N'...' string literals.  #>
function Escape-SqlLiteral {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value -replace "'", "''")
}

<#  Escape closing brackets for use inside [...] delimited identifiers.  #>
function Escape-SqlBracket {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value -replace "]", "]]")
}

<#  Convert a byte array to a 0x-prefixed hex string (SID / password hash).  #>
function Convert-BytesToHex {
    param([byte[]]$Bytes)
    if (-not $Bytes) { return $null }
    return "0x" + ([BitConverter]::ToString($Bytes) -replace "-", "")
}

<#
.SYNOPSIS
    Executes a query via Invoke-SqlcmdSafe and wraps the call with
    structured logging.  Optionally swallows errors when -ContinueOnError
    is specified.
#>
function Invoke-SqlcmdLogged {
    param(
        [string]$ServerInstance,
        [string]$Database,
        [string]$Query,
        [string]$Context = "Query",
        [switch]$ContinueOnError
    )

    try {
        Write-Log "Running [$Context] on DB [$Database]" "INFO"
        return Invoke-SqlcmdSafe -ServerInstance $ServerInstance `
                                 -Database $Database `
                                 -Query $Query `
                                 -TrustServerCertificate:$script:SourceTrustServerCertificate
    }
    catch {
        Write-Log "FAILED [$Context] on DB [$Database]. Error: $($_.Exception.Message)" "ERROR"
        if ($ContinueOnError) { return $null }
        throw
    }
}

<#
.SYNOPSIS
    Inspects a SQL batch for a USE [DbName] directive or a header comment
    containing "DATABASE: <name>".  Returns the database name the batch
    should be executed against, falling back to $DefaultDb.
#>
function Get-BatchTargetDatabase {
    param(
        [string]$BatchText,
        [string]$DefaultDb = "master"
    )

    if ([string]::IsNullOrWhiteSpace($BatchText)) { return $DefaultDb }

    # Check for USE [DatabaseName] statement
    $mUse = [regex]::Match($BatchText, "(?im)^\s*USE\s+\[(?<db>[^\]]+)\]\s*;?")
    if ($mUse.Success) { return $mUse.Groups["db"].Value }

    # Check for DATABASE: tag inside a block-comment header
    $mHdr = [regex]::Match(
        $BatchText,
        "(?im)^\s*/\*\s*={2,}.*?^\s*DATABASE:\s*(?<db>.+?)\s*$",
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if ($mHdr.Success) { return ($mHdr.Groups["db"].Value).Trim() }

    return $DefaultDb
}

function Add-Sql {
    param([string]$Text)
    [void]$script:sb.AppendLine($Text)
}

<#
.SYNOPSIS
    Writes a timestamped line to the console AND appends it to the
    execution text log file ($ExecTextLog).
#>
function Exec-LogText {
    param([string]$Message)

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message"
    Write-Host $line
    Add-Content $ExecTextLog $line
}

<#
.SYNOPSIS
    Appends a structured CSV row (batch-level) to the execution CSV log
    ($ExecCsvLog).  Creates the CSV header on first call.
#>
function Exec-LogCsvRow {
    param(
        [string]$Server,
        [string]$Database,
        [string]$Script,
        [int]$BatchNo,
        [string]$Status,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$ErrorMessage,
        [string]$BatchText
    )

    $duration  = [math]::Round(($EndTime - $StartTime).TotalSeconds, 2)
    $safeErr   = ($ErrorMessage -replace "`r|`n", " ") -replace '"', '""'
    $safeBatch = ($BatchText    -replace "`r|`n", " ") -replace '"', '""'

    # Create CSV header if file doesn't exist yet
    if (-not (Test-Path $ExecCsvLog)) {
        "RunId,Timestamp,Server,Database,Script,BatchNo,Status,StartTime,EndTime,DurationSec,ErrorMessage,BatchText" |
            Out-File $ExecCsvLog -Encoding UTF8
    }

    $row = '"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}","{8}","{9}","{10}","{11}"' -f `
        $RunId,
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
        $Server,
        $Database,
        $Script,
        $BatchNo,
        $Status,
        $StartTime.ToString("yyyy-MM-dd HH:mm:ss"),
        $EndTime.ToString("yyyy-MM-dd HH:mm:ss"),
        $duration,
        $safeErr,
        $safeBatch

    Add-Content $ExecCsvLog $row
}

function Invoke-SqlcmdTarget {
    param(
        [string]$Server,
        [string]$Database,
        [string]$Query,
        [PSCredential]$Credential = $null
    )

    $cmd           = Get-Command Invoke-Sqlcmd -ErrorAction Stop
    $hasTrustParam = $cmd.Parameters.ContainsKey("TrustServerCertificate")

    if ($hasTrustParam) {
        if ($null -ne $Credential) {
            Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $Query `
                          -Credential $Credential -TrustServerCertificate `
                          -QueryTimeout 0 -ErrorAction Stop
        }
        else {
            Invoke-Sqlcmd -ServerInstance $Server -Database $Database -Query $Query `
                          -TrustServerCertificate -QueryTimeout 0 -ErrorAction Stop
        }
    }
    else {
        if ($null -ne $Credential) {
            $u  = $Credential.UserName
            $p  = $Credential.GetNetworkCredential().Password
            $cs = "Server=$Server;Database=$Database;User ID=$u;Password=$p;" +
                  "Encrypt=True;TrustServerCertificate=True;"
        }
        else {
            $cs = "Server=$Server;Database=$Database;Integrated Security=True;" +
                  "Encrypt=True;TrustServerCertificate=True;"
        }
        Invoke-Sqlcmd -ConnectionString $cs -Query $Query -QueryTimeout 0 -ErrorAction Stop
    }
}

function Write-Summary {
    $rows = @()
    if (Test-Path $ExecCsvLog) {
        $rows = @(Import-Csv $ExecCsvLog | Where-Object { $_.RunId -eq $RunId })
    }

    $totalBatches   = $rows.Count
    $successBatches = @($rows | Where-Object { $_.Status -eq "SUCCESS" }).Count
    $failedBatches  = @($rows | Where-Object { $_.Status -eq "FAILED"  }).Count

    $totalFiles   = $Global:FileResults.Count
    $failedFiles  = @($Global:FileResults | Where-Object { $_.Status -eq "FAILED" }).Count
    $successFiles = $totalFiles - $failedFiles

    $totalExecutionTime = [math]::Round(
        (($rows | Measure-Object -Property DurationSec -Sum).Sum), 2
    )

    $summary  = @()
    $summary += "=" * 100
    $summary += "EXECUTION SUMMARY"
    $summary += "=" * 100
    $summary += "RunId Folder: $RunLogFolder"
    $summary += "Source: $SourceServerInstance"
    $summary += "TargetServer: $TargetServerInstance"
    $summary += "Total Files:     $totalFiles"
    $summary += "Files Succeeded: $successFiles"
    $summary += "Files Failed:    $failedFiles"
    $summary += "Total Batches:   $totalBatches"
    $summary += "Batches Success: $successBatches"
    $summary += "Batches Failed:  $failedBatches"
    $summary += "Total Exec Time (sec): $totalExecutionTime"
    $summary += "=" * 100
    $summary += ""
    $summary += "SUCCESSFUL FILES:"
    $summary += ($Global:FileResults | Where-Object { $_.Status -eq "SUCCESS" } |
                 Format-Table -AutoSize | Out-String)
    $summary += ""
    $summary += "FAILED FILES:"
    $summary += ($Global:FileResults | Where-Object { $_.Status -eq "FAILED" } |
                 Format-Table -AutoSize | Out-String)

    $summary | Out-File $ExecSummary -Encoding UTF8
    Exec-LogText "Summary written: $ExecSummary"
}

<#
.SYNOPSIS
    Creates an encrypted source SMO connection using an explicit certificate
    policy. Certificate validation is enabled by default.
#>
function Connect-SmoTrusted {
    param([string]$ServerInstance, [bool]$TrustServerCertificate = $false)

    $connString = "Server=$ServerInstance;Integrated Security=True;" +
                  "TrustServerCertificate=$TrustServerCertificate;Encrypt=True;"

    try {
        $sqlConn = New-Object Microsoft.Data.SqlClient.SqlConnection($connString)
    }
    catch {
        $sqlConn = New-Object System.Data.SqlClient.SqlConnection($connString)
    }

    $serverConn = New-Object Microsoft.SqlServer.Management.Common.ServerConnection($sqlConn)
    $smoServer  = New-Object Microsoft.SqlServer.Management.Smo.Server($serverConn)

    # Force a connection check to fail early if offline
    $smoServer.ConnectionContext.Connect() | Out-Null

    return $smoServer
}

<#
.SYNOPSIS
    Strips invalid file-system characters from a string so it can be
    used as a safe file name.
#>
function Get-SafeFileName {
    param([string]$FileName)

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $cleanName    = $FileName
    foreach ($char in $invalidChars) {
        $cleanName = $cleanName.Replace($char, '_')
    }
    return $cleanName
}

function Add-SectionHeader {
        param(
            [string]$title,
            [string]$db = $null
        )
        Add-Sql ""
        Add-Sql "/* ========================================================="
        if ($db) { Add-Sql "   DATABASE: $db" }
        Add-Sql "   SECTION: $title"
        Add-Sql "   ========================================================= */"
        Add-Sql ""
    }

function Add-MigrationResult {
    param(
        [string]$SourceServer,
        [string]$TargetServer,
        [string]$Component,
        [string]$Status,
        [int]$ItemCount = 0,
        [string]$OutputFile = "",
        [string]$ErrorMessage = "",
        [string]$Mode = "Generate+Execute"
    )
    $Global:MigrationResults.Add([PSCustomObject]@{
        Timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        SourceServer = $SourceServer
        TargetServer = $TargetServer
        Component    = $Component
        Status       = $Status
        ItemCount    = $ItemCount
        OutputFile   = $OutputFile
        ErrorMessage = $ErrorMessage
        Mode         = $Mode
        ExecutedBy   = $ExecutingUser
    }) | Out-Null
}

function Write-ServerMigrationSummary {
    param(
        [string]$BaseFolder,
        [string]$SourceServer,
        [string]$TargetServer
    )

    $ServerMasterLogFolder = Join-Path $BaseFolder "MasterLogs"
    New-Item -ItemType Directory -Path $ServerMasterLogFolder -Force | Out-Null

    $summaryRunId  = Get-Date -Format "yyyyMMdd_HHmmss"
    $summaryTxt    = Join-Path $ServerMasterLogFolder "MigrationSummary_$summaryRunId.txt"
    $summaryCsv    = Join-Path $ServerMasterLogFolder "MigrationSummary_$summaryRunId.csv"

    # Filter results for this server
    $serverResults = @($Global:MigrationResults | Where-Object {
        $_.SourceServer -eq $SourceServer -and $_.TargetServer -eq $TargetServer
    })

    $totalComponents = $serverResults.Count
    $successCount    = @($serverResults | Where-Object { $_.Status -eq "SUCCESS" }).Count
    $failedCount     = @($serverResults | Where-Object { $_.Status -eq "FAILED"  }).Count
    $skippedCount    = @($serverResults | Where-Object { $_.Status -eq "SKIPPED" }).Count

    $summary = @()
    $summary += ""
    $summary += "=" * 100
    $summary += "  SERVER MIGRATION SUMMARY"
    $summary += "=" * 100
    $summary += "  Run ID         : $MigrationRunId"
    $summary += "  Executed By    : $ExecutingUser"
    $summary += "  Run Date       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $summary += "  Source Server  : $SourceServer"
    $summary += "  Target Server  : $TargetServer"
    $summary += "=" * 100
    $summary += "  Total Components  : $totalComponents"
    $summary += "  Succeeded         : $successCount"
    $summary += "  Failed            : $failedCount"
    $summary += "  Skipped           : $skippedCount"
    $summary += "=" * 100
    $summary += ""
    $summary += "-" * 100
    $summary += "  DETAILED RESULTS"
    $summary += "-" * 100
    $summary += ($serverResults |
        Format-Table -Property SourceServer, TargetServer, Timestamp, Component, Status, Mode, ErrorMessage -AutoSize -Wrap |
        Out-String)
    $summary += ""

    if ($failedCount -gt 0) {
        $summary += "-" * 100
        $summary += "  FAILED COMPONENTS"
        $summary += "-" * 100
        # Updated
    # Updated
    $summary += ($serverResults | Where-Object { $_.Status -eq "FAILED" } |
            Format-Table -Property SourceServer, TargetServer, Component, ErrorMessage -AutoSize -Wrap |
            Out-String)
            }

    $summary += "=" * 100
    $summary += "  Summary Log : $summaryTxt"
    $summary += "=" * 100

    # Write to file
    $summary | Out-File $summaryTxt -Encoding UTF8

    # Export as CSV
    $serverResults | Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8

    # Display on console
    $summary | ForEach-Object {
        if ($_ -match "FAILED") { Write-Host $_ -ForegroundColor Red }
        elseif ($_ -match "SUCCESS") { Write-Host $_ -ForegroundColor Green }
        else { Write-Host $_ -ForegroundColor Cyan }
    }

    Write-Host ""
    Write-Host "Server summary : $summaryTxt" -ForegroundColor Cyan
    Write-Host "Server CSV     : $summaryCsv" -ForegroundColor Cyan
}
#endregion Functions

. (Join-Path $PSScriptRoot 'Configuration.Helpers.ps1')
. (Join-Path $PSScriptRoot 'ServerObjects.LoginProvisioning.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Preflight.Helpers.ps1')
