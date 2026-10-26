#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

function ConvertTo-ServerObjectSqlValue {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -is [DBNull]) { return 'NULL' }
    if ($Value -is [bool]) { return [string][int]$Value }
    if ($Value -is [ValueType]) { return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture) }
    "N'$(Escape-SqlLiteral ([string]$Value))'"
}

function Get-ServerObjectAgentSnapshotBlocks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server)
    $Operators = @(Invoke-SqlcmdLogged -ServerInstance $Server -Database msdb -Context 'Extract all operators' -Query 'SELECT o.*, c.name AS category_name FROM dbo.sysoperators o LEFT JOIN dbo.syscategories c ON o.category_id=c.category_id AND c.category_class=3 ORDER BY o.name;')
    foreach ($Operator in $Operators) {
        $Parameters = @('name', 'enabled', 'email_address', 'pager_address', 'weekday_pager_start_time',
            'weekday_pager_end_time', 'saturday_pager_start_time', 'saturday_pager_end_time',
            'sunday_pager_start_time', 'sunday_pager_end_time', 'pager_days', 'netsend_address', 'category_name')
        $Arguments = @($Parameters | Where-Object { $Operator.PSObject.Properties[$_] } | ForEach-Object {
            "@$_ = $(ConvertTo-ServerObjectSqlValue $Operator.$_)"
        }) -join ",`r`n    "
        $Name = Escape-SqlLiteral $Operator.name
        $Sql = "USE [msdb];`r`nIF EXISTS (SELECT 1 FROM dbo.sysoperators WHERE name=N'$Name')`r`n    EXEC dbo.sp_update_operator $Arguments;`r`nELSE`r`n    EXEC dbo.sp_add_operator $Arguments;`r`n"
        [pscustomobject]@{ Component = 'SQLOperators'; Name = $Operator.name; Kind = 'Operator'; Database = ''
            ServerSafe = $true; DependsOnDatabases = @(); SourceEnabled = $true; Sql = $Sql; Metadata = @{} }
    }
    $Alerts = @(Invoke-SqlcmdLogged -ServerInstance $Server -Database msdb -Context 'Extract all alerts' -Query @'
SELECT a.*, j.name AS JobName, c.name AS CategoryName
FROM dbo.sysalerts a LEFT JOIN dbo.sysjobs j ON a.job_id=j.job_id
LEFT JOIN dbo.syscategories c ON a.category_id=c.category_id AND c.category_class=2 ORDER BY a.name;
'@)
    $Notifications = @(Invoke-SqlcmdLogged -ServerInstance $Server -Database msdb -Context 'Extract alert notifications' -Query @'
SELECT a.name AS AlertName, o.name AS OperatorName, n.notification_method
FROM dbo.sysnotifications n JOIN dbo.sysalerts a ON n.alert_id=a.id
JOIN dbo.sysoperators o ON n.operator_id=o.id;
'@)
    foreach ($Alert in $Alerts) {
        $JobNameValue = if ($Alert.JobName -is [DBNull]) { '' } else { [string]$Alert.JobName }
        $DatabaseNameValue = if ($Alert.database_name -is [DBNull]) { '' } else { [string]$Alert.database_name }
        $Parameters = @('name', 'enabled', 'message_id', 'severity', 'database_name', 'delay_between_responses',
            'notification_message', 'include_event_description', 'performance_condition', 'event_description_keyword', 'wmi_namespace', 'wmi_query')
        $Arguments = @($Parameters | Where-Object { $Alert.PSObject.Properties[$_] } | ForEach-Object {
            "@$_ = $(ConvertTo-ServerObjectSqlValue $Alert.$_)"
        }) -join ",`r`n    "
        if ($Alert.CategoryName) { $Arguments += ", @category_name=$(ConvertTo-ServerObjectSqlValue $Alert.CategoryName)" }
        $Preamble = ''
        if ($JobNameValue) {
            $JobName = Escape-SqlLiteral $JobNameValue
            $Preamble = "DECLARE @TargetJob uniqueidentifier=(SELECT job_id FROM dbo.sysjobs WHERE name=N'$JobName');`r`nIF @TargetJob IS NULL THROW 51000, 'Alert requires target job $JobName.', 1;`r`n"
            $Arguments += ', @job_id=@TargetJob'
        }
        $Name = Escape-SqlLiteral $Alert.name
        $Sql = "USE [msdb];`r`n${Preamble}IF EXISTS (SELECT 1 FROM dbo.sysalerts WHERE name=N'$Name')`r`n    EXEC dbo.sp_update_alert $Arguments;`r`nELSE`r`n    EXEC dbo.sp_add_alert $Arguments;`r`n"
        foreach ($Notification in @($Notifications | Where-Object AlertName -eq $Alert.name)) {
            $OperatorName = Escape-SqlLiteral $Notification.OperatorName
            $Method = [int]$Notification.notification_method
            $Sql += @"
IF EXISTS (SELECT 1 FROM dbo.sysnotifications n JOIN dbo.sysalerts a ON n.alert_id=a.id JOIN dbo.sysoperators o ON n.operator_id=o.id WHERE a.name=N'$Name' AND o.name=N'$OperatorName')
    EXEC dbo.sp_update_notification @alert_name=N'$Name', @operator_name=N'$OperatorName', @notification_method=$Method;
ELSE
    EXEC dbo.sp_add_notification @alert_name=N'$Name', @operator_name=N'$OperatorName', @notification_method=$Method;

"@
        }
        $Databases = @(if ($DatabaseNameValue -and $DatabaseNameValue -notin @('master', 'model', 'msdb', 'tempdb')) { $DatabaseNameValue })
        [pscustomobject]@{ Component = 'SQLAlerts'; Name = $Alert.name; Kind = 'Alert'; Database = ''
            ServerSafe = -not $Databases.Count -and -not $JobNameValue; DependsOnDatabases = $Databases
            SourceEnabled = $true; Sql = $Sql; Metadata = @{ JobName = $JobNameValue } }
    }
}

function Write-ServerObjectSnapshotSql {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyCollection()][object[]]$Blocks = @())
    $Builder = [Text.StringBuilder]::new("-- SQLMIGRATION-SNAPSHOT 4`r`n")
    foreach ($Block in $Blocks) {
        $Header = [ordered]@{}
        foreach ($Property in $Block.PSObject.Properties) {
            if ($Property.Name -ne 'Sql') { $Header[$Property.Name] = $Property.Value }
        }
        $Header.SqlLength = $Block.Sql.Length
        $Encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Header | ConvertTo-Json -Depth 30 -Compress)))
        $null = $Builder.Append("-- SQLMIGRATION-BLOCK $Encoded`r`n").Append($Block.Sql).Append("`r`n")
    }
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Builder.ToString(), [Text.UTF8Encoding]::new($false))
}

function Read-ServerObjectSnapshotSql {
    [CmdletBinding()]
    param([string]$Path, [string]$Text)
    if (-not $PSBoundParameters.ContainsKey('Text')) { $Text = [IO.File]::ReadAllText($Path) }
    $Prefix = "-- SQLMIGRATION-SNAPSHOT 4`r`n"
    if (-not $Text.StartsWith($Prefix, [StringComparison]::Ordinal)) { throw "Unsupported SQL snapshot '$Path'; regenerate." }
    $Offset = $Prefix.Length
    while ($Offset -lt $Text.Length) {
        $End = $Text.IndexOf("`r`n", $Offset, [StringComparison]::Ordinal)
        if ($End -lt 0) { throw "Truncated snapshot metadata in '$Path'." }
        $Header = $Text.Substring($Offset, $End - $Offset)
        if ($Header -cnotmatch '^-- SQLMIGRATION-BLOCK ([A-Za-z0-9+/=]+)$') { throw "Invalid snapshot block in '$Path'." }
        $Block = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) | ConvertFrom-Json -Depth 30 -ErrorAction Stop
        $Offset = $End + 2
        if ($Block.SqlLength -isnot [long] -and $Block.SqlLength -isnot [int] -or $Block.SqlLength -lt 0 -or
            $Block.SqlLength -gt $Text.Length - $Offset - 2) { throw "Invalid SQL block length in '$Path'." }
        $Block | Add-Member -NotePropertyName Sql -NotePropertyValue $Text.Substring($Offset, $Block.SqlLength)
        $Offset += $Block.SqlLength
        if ($Text.Substring($Offset, 2) -cne "`r`n") { throw "Invalid SQL block separator in '$Path'." }
        $Offset += 2
        $Block
    }
}

function New-ServerObjectSourceSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$Root)
    Import-Module SqlServer -ErrorAction Stop
    $script:SourceTrustServerCertificate = $Item.SourceTrustServerCertificate
    $Server = Get-ServerObjectSourceEndpoint -Item $Item
    $Blocks = [Collections.Generic.List[object]]::new()
    foreach ($Block in @(Get-ServerObjectSecuritySnapshotBlocks -Server $Server)) { $Blocks.Add($Block) }
    foreach ($Block in @(Get-ServerObjectJobSnapshotBlocks -Server $Server)) { $Blocks.Add($Block) }
    foreach ($Block in @(Get-ServerObjectAgentSnapshotBlocks -Server $Server)) { $Blocks.Add($Block) }
    $Databases = @(Invoke-SqlcmdLogged -ServerInstance $Server -Database master -Context 'Capture complete database inventory' -Query 'SELECT name FROM sys.databases WHERE database_id > 4 AND source_database_id IS NULL ORDER BY name;' |
        ForEach-Object { [string]$_.name })
    $Blocks.Add([pscustomobject]@{ Component = 'SQLLogins'; Kind = 'Inventory'; Name = 'Source databases'; Database = ''
        ServerSafe = $false; DependsOnDatabases = @(); SourceEnabled = $true; Sql = '-- Source database inventory.'
        Metadata = @{ Databases = $Databases } })
    $MailRoot = Join-Path (Split-Path -Parent $Root) 'MailExtraction'
    $ActiveLog = $script:ActiveLogFile
    try {
        $Mail = Generate-SQLDBMail -SourceServerName $Server -TargetServerName $Server -Component SQLDBMail `
            -BaseFolder $MailRoot -TargetType $Item.TargetType -SmtpServer 'source-settings-preserved' -SmtpPort 25 `
            -Unfiltered -PreserveSourceSettings
    }
    finally { $script:ActiveLogFile = $ActiveLog }
    $MailSql = if ($Mail.ItemCount -gt 0) { [IO.File]::ReadAllText($Mail.OutputFile) } else { '-- No Database Mail configuration on source.' }
    $Blocks.Add([pscustomobject]@{ Component = 'SQLDBMail'; Kind = 'DatabaseMail'; Name = 'Database Mail'; Database = ''
        ServerSafe = $true; DependsOnDatabases = @(); SourceEnabled = $true; Sql = $MailSql; Metadata = @{} })
    foreach ($Relative in @(Get-ServerObjectSnapshotPaths)) {
        $Component, $FileName = $Relative.Split('/')
        $Selected = @($Blocks | Where-Object { $_.Component -eq $Component -and
            ($FileName.EndsWith('_All.sql', [StringComparison]::Ordinal) -or $_.ServerSafe -or $Component -eq 'SQLAlerts') })
        Write-ServerObjectSnapshotSql -Path (Join-Path $Root ($Relative.Replace('/', '\'))) -Blocks $Selected
        [pscustomobject]@{ Component = $Component; Mode = 'Generate'; Status = 'SUCCESS'; OutputFile = $Relative; ItemCount = $Selected.Count }
    }
    # Raw snapshots are already written. This target-specific, read-only report is
    # deliberately separate from immutable source metadata and Blob SQL files.
    Export-ServerObjectMissingEntraIdentities -Item $Item -Blocks $Blocks.ToArray() -Root $Root
}

function ConvertTo-ServerObjectMailReplaySql {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Sql, [Parameter(Mandatory)][object]$Item)
    # Initialize ScriptDom through the existing parser-backed job helper.
    $null = ConvertTo-ServerObjectJobUpsertSql -Sql 'SELECT 1;'
    $Parser = [Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser]::new($true)
    $Reader = [IO.StringReader]::new($Sql)
    $Errors = $null
    try { $Tree = $Parser.Parse($Reader, [ref]$Errors) } finally { $Reader.Dispose() }
    if ($Errors.Count) { throw "Cannot parse Database Mail snapshot: $($Errors[0].Message)" }
    $Nodes = [Collections.Generic.Stack[object]]::new()
    $Nodes.Push($Tree)
    $Edits = [Collections.Generic.List[object]]::new()
    while ($Nodes.Count) {
        $Node = $Nodes.Pop()
        foreach ($Property in $Node.GetType().GetProperties()) {
            if ($Property.Name -eq 'ScriptTokenStream' -or $Property.GetIndexParameters().Count) { continue }
            $Value = $Property.GetValue($Node)
            if ($Value -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) { $Nodes.Push($Value) }
            elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
                foreach ($Child in $Value) { if ($Child -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) { $Nodes.Push($Child) } }
            }
        }
        if ($Node -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.ExecuteStatement]) { continue }
        $Entity = $Node.ExecuteSpecification.ExecutableEntity
        if ($Entity -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.ExecutableProcedureReference]) { continue }
        $Reference = $Entity.ProcedureReference.ProcedureReference
        if (-not $Reference -or -not $Reference.Name -or $Reference.Name.BaseIdentifier.Value -notin @('sysmail_add_account_sp', 'sysmail_update_account_sp')) { continue }
        foreach ($Parameter in $Entity.Parameters) {
            if (-not $Parameter.Variable) { throw 'Database Mail replay requires named account parameters.' }
            $Replacement = switch ($Parameter.Variable.Name.ToLowerInvariant()) {
                '@mailserver_name' { ConvertTo-ServerObjectSqlValue $Item.SmtpServer }
                '@port' { [string][int]$Item.SmtpPort }
            }
            if ($Replacement) {
                $Edits.Add([pscustomobject]@{ Offset = $Parameter.ParameterValue.StartOffset
                    Length = $Parameter.ParameterValue.FragmentLength; Text = $Replacement })
            }
            if ($Item.TargetType -eq 'SQLMI' -and $Parameter.Variable.Name -eq '@use_default_credentials' -and
                $Sql.Substring($Parameter.ParameterValue.StartOffset, $Parameter.ParameterValue.FragmentLength) -eq '1') {
                throw 'Database Mail uses Windows Integrated SMTP credentials, which SQL MI cannot replay; configure a supported SMTP authentication method on the source before extraction.'
            }
        }
    }
    foreach ($Edit in @($Edits | Sort-Object Offset -Descending)) { $Sql = $Sql.Remove($Edit.Offset, $Edit.Length).Insert($Edit.Offset, $Edit.Text) }
    $Sql
}

function Get-ServerObjectReplayBlocks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$Root,
        [string[]]$Components = @('SQLLogins', 'SQLDBMail', 'SQLOperators', 'SQLAgentJobs', 'SQLAlerts'),
        [object]$Snapshot)
    $Scope = @(($Item.SourceListofDatabases -split ',').Trim())
    foreach ($Component in $Components) {
        if ($Item."${Component}MigrationFlag" -ne 'Yes') { continue }
        $Level = if ($Component -in @('SQLLogins', 'SQLAgentJobs')) { $Item."${Component}MigrationScope" } else { 'Server' }
        $Path = Join-Path $Root "$Component\${Component}_$Level.sql"
        $Arguments = @{ Path = $Path }
        if ($Snapshot) {
            $Files = @($Snapshot.Files | Where-Object Path -eq "$Component/${Component}_$Level.sql")
            if ($Files.Count -ne 1) { throw "Snapshot lacks $Component/${Component}_$Level.sql." }
            $Arguments.Text = [Text.Encoding]::UTF8.GetString($Files[0].Bytes)
        }
        foreach ($Block in @(Read-ServerObjectSnapshotSql @Arguments)) {
            if ($Block.Component -ne $Component) { throw "Snapshot component mismatch in '$Path'." }
            if ($Component -in @('SQLLogins', 'SQLAgentJobs') -and $Level -eq 'Server' -and -not $Block.ServerSafe) {
                throw "Unsafe object '$($Block.Name)' in Server snapshot '$Path'. Regenerate the snapshot."
            }
            if ($Block.Kind -eq 'Inventory') { continue }
            $JobMatches = if ($Item.SQLAgentJobFilterCriteria -eq 'DBA-ENABLED') { $Block.Name -like 'DBA*' }
                else { $Block.Name -match $Item.SQLAgentJobFilterCriteria }
            if ($Component -eq 'SQLAgentJobs' -and (-not $Block.SourceEnabled -or -not $JobMatches)) {
                Write-Log "Skipping job '$($Block.Name)': disabled on source or excluded by execution regex." WARN
                continue
            }
            if ($Component -eq 'SQLAlerts' -and -not $Block.ServerSafe -and $Item.SQLAgentJobsMigrationScope -eq 'Server') {
                Write-Log "Deferring alert '$($Block.Name)': database/job dependency requires All execution." WARN
                continue
            }
            $Dependencies = @($Block.DependsOnDatabases | Where-Object { $_ -notin @('', 'master', 'model', 'msdb', 'tempdb') })
            if ($Block.Database -and $Block.Database -notin @('master', 'model', 'msdb', 'tempdb')) { $Dependencies += $Block.Database }
            if ('All' -notin $Scope -and @($Dependencies | Where-Object { $_ -notin $Scope }).Count) {
                Write-Log "Skipping $Component '$($Block.Name)': outside selected databases ($($Dependencies -join ', '))." WARN
                continue
            }
            $Block
        }
    }
}

function Assert-ServerObjectReplayTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [string]$Root, [object]$Snapshot,
        [ValidateSet('', 'SQLLogins', 'SQLDBMail', 'SQLOperators', 'SQLAgentJobs', 'SQLAlerts')][string]$Component = '',
        [pscredential]$SqlCredential)
    $Auth = Get-ServerObjectTargetAuth -Item $Item -TargetSqlAuthType $Item.TargetSqlAuthType `
        -TrustServerCertificate $Item.TargetTrustServerCertificate -SqlCredential $SqlCredential
    $Endpoint = "$($Item.TargetSqlHost),$($Item.TargetSqlPort)"
    Assert-ServerObjectSqlAccess -Server $Endpoint @Auth -RequireSysadmin
    $All = ($Component -in @('', 'SQLLogins') -and $Item.SQLLoginsMigrationFlag -eq 'Yes' -and $Item.SQLLoginsMigrationScope -eq 'All') -or
        ($Component -in @('', 'SQLAgentJobs') -and $Item.SQLAgentJobsMigrationFlag -eq 'Yes' -and $Item.SQLAgentJobsMigrationScope -eq 'All')
    if ($All) {
        $Databases = @(($Item.SourceListofDatabases -split ',').Trim())
        if ('All' -in $Databases) {
            $Arguments = if ($Snapshot) {
                $File = @($Snapshot.Files | Where-Object Path -eq 'SQLLogins/SQLLogins_All.sql')
                if ($File.Count -ne 1) { throw 'Snapshot lacks SQLLogins_All.sql.' }
                @{ Text = [Text.Encoding]::UTF8.GetString($File[0].Bytes) }
            } elseif ($Root) { @{ Path = (Join-Path $Root 'SQLLogins\SQLLogins_All.sql') } }
            else { throw 'All-database replay requires a verified source snapshot.' }
            $Inventory = @(Read-ServerObjectSnapshotSql @Arguments | Where-Object Kind -eq 'Inventory')
            if ($Inventory.Count -ne 1) { throw 'Snapshot lacks its complete source database inventory; regenerate.' }
            $Databases = @($Inventory[0].Metadata.Databases)
        }
        foreach ($Database in $Databases) {
            if (-not $Database) { throw 'Execution database selection contains an empty name.' }
            $State = @(Invoke-ServerObjectPreflightQuery -Server $Endpoint @Auth -Query "SELECT state_desc FROM sys.databases WHERE name=N'$(Escape-SqlLiteral $Database)';")
            if ($State.Count -ne 1 -or $State[0].state_desc -ne 'ONLINE') { throw "All replay requires target database '$Database' restored and ONLINE." }
        }
    }
}

function Invoke-ServerObjectSnapshotReplay {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$Root,
        [switch]$Preview, [object]$Snapshot, [pscredential]$SqlCredential)
    $IdentityReport = $null
    if ($Item.TargetType -eq 'SQLMI') {
        $SelectedBlocks = @(Get-ServerObjectReplayBlocks -Item $Item -Root $Root -Snapshot $Snapshot)
        $IdentityReport = Export-ServerObjectMissingEntraIdentities -Item $Item -Blocks $SelectedBlocks -Root $Root -Replay -Preview:$Preview
        $IdentityReport
    }
    $Auth = Get-ServerObjectTargetAuth -Item $Item -TargetSqlAuthType $Item.TargetSqlAuthType `
        -TrustServerCertificate $Item.TargetTrustServerCertificate -SqlCredential $SqlCredential
    if ($Item.TargetTrustServerCertificate) {
        Write-Log "Item '$($Item.Id)' explicitly bypasses target certificate validation for '$($Item.TargetSqlHost),$($Item.TargetSqlPort)'; encryption remains required. Use a trusted SQL certificate for production." WARN
    }
    foreach ($Component in @('SQLLogins', 'SQLDBMail', 'SQLOperators', 'SQLAgentJobs', 'SQLAlerts')) {
        $Level = if ($Component -in @('SQLLogins', 'SQLAgentJobs')) { $Item."${Component}MigrationScope" } else { 'Server' }
        $Path = Join-Path $Root "$Component\${Component}_$Level.sql"
        if ($Item."${Component}MigrationFlag" -ne 'Yes') {
            [pscustomobject]@{ Component = $Component; Name = ''; Database = ''; Mode = 'Execute'
                Phase = 'Selection'; Status = 'SKIPPED'; OutputFile = $Path; ErrorMessage = ''; Detail = 'Disabled by configuration.' }
            continue
        }
        try {
            if ($IdentityReport -and $Component -in $IdentityReport.AffectedComponents) {
                throw "Component '$Component' has unresolved Entra dependencies. $($IdentityReport.ErrorMessage)"
            }
            Write-Log "Validating item '$($Item.Id)', component '$Component', file '$Path', target '$($Item.TargetSqlHost),$($Item.TargetSqlPort)'." INFO
            Assert-ServerObjectReplayTarget -Item $Item -Root $Root -Snapshot $Snapshot -Component $Component -SqlCredential $SqlCredential
            $Blocks = @(Get-ServerObjectReplayBlocks -Item $Item -Root $Root -Snapshot $Snapshot -Components $Component)
        }
        catch {
            $Message = "Validation failed: item='$($Item.Id)', component='$Component', file='$Path', source='$($Item.SourceServerName)', target='$($Item.TargetSqlHost),$($Item.TargetSqlPort)'. $($_.Exception.Message)"
            Write-Log $Message ERROR
            [pscustomobject]@{ Component = $Component; Name = ''; Database = ''; Mode = 'Execute'
                Phase = 'Validation'; Status = 'FAILED'; OutputFile = $Path; ErrorMessage = $Message
                ErrorId = $_.FullyQualifiedErrorId; ScriptStackTrace = $_.ScriptStackTrace }
            continue
        }
        if (-not $Blocks.Count) {
            Write-Log "Item '$($Item.Id)', component '$Component': no eligible objects after scope and execution filtering." INFO
            [pscustomobject]@{ Component = $Component; Name = ''; Database = ''; Mode = 'Execute'
                Phase = 'Selection'; Status = 'SKIPPED'; OutputFile = $Path; ErrorMessage = ''; Detail = 'No eligible objects after scope and execution filtering.' }
        }
        foreach ($Block in $Blocks) {
            $Phase = 'Validation'
            try {
                $Sql = switch ($Component) {
                    SQLLogins { ConvertTo-ServerObjectSecurityReplaySql -Block $Block -Item $Item }
                    SQLAgentJobs { ConvertTo-ServerObjectJobReplaySql -Block $Block -Item $Item }
                    SQLDBMail { ConvertTo-ServerObjectMailReplaySql -Sql $Block.Sql -Item $Item }
                    default { $Block.Sql }
                }
                $Status = 'PreflightPassed'
                if (-not $Preview) {
                    $Phase = 'Execution'
                    Write-Log "Executing item '$($Item.Id)', component '$Component', object '$($Block.Name)', database '$($Block.Database)', file '$Path' on '$($Item.TargetSqlHost),$($Item.TargetSqlPort)'." INFO
                    Invoke-ServerObjectPreflightQuery -Server "$($Item.TargetSqlHost),$($Item.TargetSqlPort)" -Database master -Query $Sql -QueryTimeout 0 @Auth | Out-Null
                    $Status = 'SUCCESS'
                }
                [pscustomobject]@{ Component = $Component; Name = $Block.Name; Database = $Block.Database; Mode = 'Execute'
                    Phase = $Phase; Status = $Status; OutputFile = $Path; ErrorMessage = '' }
            }
            catch {
                $Message = "$Phase failed: item='$($Item.Id)', component='$Component', object='$($Block.Name)', file='$Path', source='$($Item.SourceServerName)', target='$($Item.TargetSqlHost),$($Item.TargetSqlPort)', database='$($Block.Database)'. $($_.Exception.Message)"
                Write-Log $Message ERROR
                [pscustomobject]@{ Component = $Component; Name = $Block.Name; Database = $Block.Database; Mode = 'Execute'
                    Phase = $Phase; Status = 'FAILED'; OutputFile = $Path; ErrorMessage = $Message
                    ErrorId = $_.FullyQualifiedErrorId; ScriptStackTrace = $_.ScriptStackTrace }
            }
        }
    }
}
