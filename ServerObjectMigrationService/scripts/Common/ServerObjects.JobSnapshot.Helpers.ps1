# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

function Get-ServerObjectJobSqlTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Sql)

    if (-not ('Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser' -as [type])) {
        $Module = Get-Module SqlServer -ListAvailable | Select-Object -First 1
        if (-not $Module) { throw 'SqlServer module is required to parse SQL Agent job scripts.' }
        Add-Type -Path (Join-Path $Module.ModuleBase 'coreclr\Microsoft.SqlServer.TransactSql.ScriptDom.dll') -ErrorAction Stop
    }
    $Reader = [IO.StringReader]::new($Sql)
    $Errors = $null
    try {
        $Tree = [Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser]::new($true).Parse($Reader, [ref]$Errors)
    }
    finally { $Reader.Dispose() }
    if ($Errors.Count) { throw "Cannot parse SQL Agent script: $($Errors[0].Message)" }
    return $Tree
}

function Get-ServerObjectJobSqlNodes {
    param([Parameter(Mandatory)]$Tree)

    $Nodes = [Collections.Generic.Stack[object]]::new()
    $Nodes.Push($Tree)
    while ($Nodes.Count) {
        $Node = $Nodes.Pop()
        $Node
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
    }
}

function Get-ServerObjectJobSnapshotBlocks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server)

    $Source = Connect-SmoTrusted -ServerInstance $Server -TrustServerCertificate:$script:SourceTrustServerCertificate
    $Options = [Microsoft.SqlServer.Management.Smo.ScriptingOptions]::new()
    $Options.ScriptDrops = $false
    # Replay owns existence checks; an outer SMO guard would skip in-place updates.
    $Options.IncludeIfNotExists = $false
    $Owners = @(Invoke-SqlcmdLogged -ServerInstance $Server -Database master -Context 'JobSnapshot.Owners' -Query @'
SELECT name AS Name,type AS Type,CONVERT(bit,CASE WHEN type IN ('U','G') AND
 LEFT(name,CHARINDEX('\',name))=CONVERT(nvarchar(128),SERVERPROPERTY('MachineName'))+'\' THEN 1 ELSE 0 END) AS IsLocalWindowsPrincipal
FROM sys.server_principals;
'@)
    foreach ($Job in $Source.JobServer.Jobs) {
        # SMO exposes IsSystemObject on supported versions. Reserved product jobs are
        # an exact-name fallback; owner/category/disabled state never prove system origin.
        if ($Job.IsSystemObject -or $Job.Name -in @('syspolicy_purge_history', 'SSIS Server Maintenance Job')) { continue }
        $OwnerPrincipal = @($Owners | Where-Object Name -eq $Job.OwnerLoginName)
        $Databases = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $Warnings = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $Operators = @(
            foreach ($PropertyName in @('OperatorToEmail', 'OperatorToNetSend', 'OperatorToPage')) {
                $Property = $Job.PSObject.Properties[$PropertyName]
                if ($Property -and -not [string]::IsNullOrWhiteSpace([string]$Property.Value)) {
                    [string]$Property.Value
                    $null = $Warnings.Add("Job uses notification operator '$($Property.Value)'; notification configuration requires review.")
                }
            }
        )
        $Steps = @(
            foreach ($Step in $Job.JobSteps) {
                $Subsystem = [string]$Step.SubSystem
                $Context = [string]$Step.DatabaseName
                $Proxy = [string]$Step.ProxyName
                $StepLabel = "Step '$($Step.Name)'"
                if ($Context -and $Context -notin @('master', 'msdb', 'model', 'tempdb')) {
                    $null = $Databases.Add($Context)
                }
                if ($Proxy) { $null = $Warnings.Add("$StepLabel uses proxy '$Proxy'; provision its credential and permissions explicitly.") }
                if ($Subsystem -ne 'TransactSql' -and $Subsystem -ne 'TSQL') {
                    $null = $Warnings.Add("$StepLabel uses subsystem '$Subsystem'; external dependencies cannot be inferred.")
                }
                elseif ([string]::IsNullOrWhiteSpace([string]$Step.Command)) {
                    $null = $Warnings.Add("$StepLabel has no inspectable TSQL command.")
                }
                else {
                    try {
                        $Tree = Get-ServerObjectJobSqlTree -Sql ([string]$Step.Command)
                        foreach ($Node in (Get-ServerObjectJobSqlNodes -Tree $Tree)) {
                            $Type = $Node.GetType().Name
                            if ($Type -eq 'UseStatement') {
                                $Db = $Node.DatabaseName.Value
                                if ($Db -notin @('master', 'msdb', 'model', 'tempdb')) { $null = $Databases.Add($Db) }
                            }
                            if ($Node -is [Microsoft.SqlServer.TransactSql.ScriptDom.SchemaObjectName]) {
                                if ($Node.ServerIdentifier) { $null = $Warnings.Add("$StepLabel references a four-part name / remote server.") }
                                $Db = if ($Node.DatabaseIdentifier) { $Node.DatabaseIdentifier.Value } else { $Context }
                                if ($Db -and $Db -notin @('master', 'msdb', 'model', 'tempdb')) { $null = $Databases.Add($Db) }
                                if (-not $Node.SchemaIdentifier -or $Node.SchemaIdentifier.Value -notin @('sys', 'INFORMATION_SCHEMA')) {
                                    $null = $Warnings.Add("$StepLabel references an unresolved object; database context alone does not prove dependencies.")
                                }
                            }
                            if ($Type -eq 'ExecuteStatement') {
                                $null = $Warnings.Add("$StepLabel uses EXEC / dynamic SQL or an unresolved stored procedure; dependencies require review.")
                            }
                            if ($Node -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlStatement] -and
                                $Type -notin @('UseStatement', 'SelectStatement', 'DeclareVariableStatement', 'SetVariableStatement', 'PrintStatement')) {
                                $null = $Warnings.Add("$StepLabel contains '$Type'; not a proven self-contained system query.")
                            }
                            if ($Type -match 'OpenRowset|OpenQuery|AdHoc|Bulk|External|NextValue|SelectSetVariable' -or
                                ($Type -eq 'FunctionCall' -and $Node.CallTarget) -or
                                ($Type -eq 'SelectStatement' -and $Node.Into)) {
                                $null = $Warnings.Add("$StepLabel has external, mutable, or unresolved SQL dependencies ($Type).")
                            }
                        }
                    }
                    catch { $null = $Warnings.Add("$StepLabel cannot be classified: $($_.Exception.Message)") }
                }
                [pscustomobject]@{
                    Name = [string]$Step.Name; Subsystem = $Subsystem; Database = $Context
                    Proxy = $Proxy; Command = [string]$Step.Command
                }
            }
        )
        if (-not $Steps.Count) { $null = $Warnings.Add('Job has no inspectable steps.') }
        if ($Databases.Count) { $null = $Warnings.Add('Job references user database(s); selected database scope must be checked.') }
        # Script original state without mutating SMO properties or contacting a target.
        $Sql = @($Job.Script($Options)) -join "`r`nGO`r`n"
        if ([string]::IsNullOrWhiteSpace($Sql)) { throw "Source job '$($Job.Name)' returned an empty script." }
        [pscustomobject]@{
            Component = 'SQLAgentJobs'; Name = [string]$Job.Name; Kind = 'Job'; Database = ''
            ServerSafe = ($Warnings.Count -eq 0); DependsOnDatabases = [string[]]@($Databases | Sort-Object)
            SourceEnabled = [bool]$Job.IsEnabled; Sql = $Sql
            Metadata = [pscustomobject]@{
                Owner = [string]$Job.OwnerLoginName; Category = [string]$Job.Category
                OwnerType = if ($OwnerPrincipal.Count -eq 1) { [string]$OwnerPrincipal[0].Type } else { '' }
                OwnerIsLocal = ($OwnerPrincipal.Count -eq 1 -and [bool]$OwnerPrincipal[0].IsLocalWindowsPrincipal)
                Subsystems = [string[]]@($Steps.Subsystem | Sort-Object -Unique)
                DependencyWarnings = [string[]]@($Warnings | Sort-Object); Steps = $Steps
                NotificationOperators = [string[]]$Operators
            }
        }
    }
}

function ConvertTo-ServerObjectJobReplaySql {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Block, [Parameter(Mandatory)]$Item)

    $Name = [string]$Block.Name
    try {
        $Owner = [string]$Block.Metadata.Owner
        $MappedOwner = $Owner
        if ($Item.TargetType -eq 'SQLMI' -and ($Block.Metadata.OwnerType -in @('U', 'G') -or $Owner -match '\\')) {
            if ($Block.Metadata.OwnerType -notin @('U', 'G')) {
                throw "Windows job owner '$Owner' lacks captured user/group type; regenerate the source snapshot before Entra resolution."
            }
            $MappedOwner = Resolve-SecuritySnapshotEntraPrincipal $Owner $Block.Metadata.OwnerType $Item -IsLocal:([bool]$Block.Metadata.OwnerIsLocal)
        }
        if ($Item.TargetType -eq 'SQLMI') {
            foreach ($Subsystem in $Block.Metadata.Subsystems) {
                if ($Subsystem -notin @('TransactSql', 'TSQL')) { throw "SQLMI does not support subsystem '$Subsystem'; convert the job step before replay." }
            }
            foreach ($Step in $Block.Metadata.Steps) {
                if ($Step.Proxy) { throw "SQLMI job step '$($Step.Name)' uses proxy '$($Step.Proxy)'; remove or replace this dependency explicitly before replay." }
            }
        }
        $Sql = ConvertTo-ServerObjectJobUpsertSql -Sql ([string]$Block.Sql)
        $Tree = Get-ServerObjectJobSqlTree -Sql $Sql
        $Edits = [Collections.Generic.List[object]]::new()
        $JobStatements = 0
        foreach ($Node in (Get-ServerObjectJobSqlNodes -Tree $Tree)) {
            if ($Node -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.ExecuteStatement]) { continue }
            $Entity = $Node.ExecuteSpecification.ExecutableEntity
            if ($Entity -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.ExecutableProcedureReference]) { continue }
            $Reference = $Entity.ProcedureReference.ProcedureReference
            if (-not $Reference -or -not $Reference.Name) { continue }
            $Procedure = $Reference.Name.BaseIdentifier.Value
            if ($Reference.Name.ServerIdentifier -or
                ($Reference.Name.SchemaIdentifier -and $Reference.Name.SchemaIdentifier.Value -ne 'dbo') -or
                ($Reference.Name.DatabaseIdentifier -and $Reference.Name.DatabaseIdentifier.Value -ne 'msdb')) { continue }
            if ($Item.TargetType -eq 'SQLMI' -and $Procedure -in @('sp_add_jobstep', 'sp_update_jobstep')) {
                foreach ($Parameter in $Entity.Parameters) {
                    $ParameterName = [string]$Parameter.Variable.Name
                    if ($ParameterName -in @('@proxy_name', '@proxy_id')) {
                        $Value = $Parameter.ParameterValue
                        $NoProxy = $Value -is [Microsoft.SqlServer.TransactSql.ScriptDom.NullLiteral] -or
                            ($ParameterName -eq '@proxy_id' -and $Value -is [Microsoft.SqlServer.TransactSql.ScriptDom.IntegerLiteral] -and $Value.Value -eq '0') -or
                            ($ParameterName -eq '@proxy_name' -and $Value -is [Microsoft.SqlServer.TransactSql.ScriptDom.StringLiteral] -and $Value.Value -eq '')
                        if (-not $NoProxy) { throw "SQLMI script uses $ParameterName; resolve the unsupported or unresolved proxy explicitly." }
                    }
                    if ($ParameterName -eq '@subsystem' -and [string]$Parameter.ParameterValue.Value -ne 'TSQL') {
                        throw 'SQLMI script contains an unsupported or unresolved subsystem.'
                    }
                }
            }
            if ($Procedure -notin @('sp_add_job', 'sp_update_job')) { continue }
            $JobStatements++
            $HasEnabled = $false
            foreach ($Parameter in $Entity.Parameters) {
                if (-not $Parameter.Variable) { throw "Named parameters are required for $Procedure." }
                $Value = $Parameter.ParameterValue
                if ($Parameter.Variable.Name -eq '@enabled') {
                    $HasEnabled = $true
                    $Edits.Add([pscustomobject]@{ Start = $Value.StartOffset; Length = $Value.FragmentLength; Text = '0' })
                }
                if ($Parameter.Variable.Name -eq '@owner_login_name' -and $MappedOwner -ne $Owner) {
                    if ($Value -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.StringLiteral] -or $Value.Value -ne $Owner) {
                        throw "Script owner does not match captured owner '$Owner'."
                    }
                    $Edits.Add([pscustomobject]@{
                        Start = $Value.StartOffset; Length = $Value.FragmentLength
                        Text = "N'$(Escape-SqlLiteral -Value $MappedOwner)'"
                    })
                }
            }
            if (-not $HasEnabled) {
                $Last = $Entity.Parameters | Select-Object -Last 1
                if (-not $Last) { throw "$Procedure has no parameters." }
                $Edits.Add([pscustomobject]@{ Start = $Last.StartOffset + $Last.FragmentLength; Length = 0; Text = ', @enabled = 0' })
            }
        }
        if (-not $JobStatements) { throw 'Snapshot contains no recognized msdb job creation/update statement.' }
        foreach ($Edit in ($Edits | Sort-Object Start -Descending)) { $Sql = $Sql.Remove($Edit.Start, $Edit.Length).Insert($Edit.Start, $Edit.Text) }
        $OwnerGuard = ''
        if ($Item.TargetType -eq 'SQLMI' -and $MappedOwner -ne $Owner) {
            $ErrorText = Escape-SqlLiteral -Value "Job '$Name': mapped owner '$MappedOwner' is unresolved on target. Provision the Entra login before replay."
            $OwnerGuard = "IF SUSER_ID(N'$(Escape-SqlLiteral -Value $MappedOwner)') IS NULL THROW 51000, '$ErrorText', 1;`r`nGO`r`n"
        }
        return "$OwnerGuard$Sql`r`nGO`r`nEXEC msdb.dbo.sp_update_job @job_name = N'$(Escape-SqlLiteral -Value $Name)', @enabled = 0;`r`nGO"
    }
    catch { throw "Cannot replay SQL Agent job '$Name': $($_.Exception.Message)" }
}
