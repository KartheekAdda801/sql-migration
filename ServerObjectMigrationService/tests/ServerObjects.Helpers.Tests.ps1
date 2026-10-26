#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    $Scripts = Join-Path $PSScriptRoot '..\scripts'
    . (Join-Path $Scripts 'Common\ServerObjects.Helpers.ps1')
    . (Join-Path $Scripts 'Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1')
    function Get-SourceFunctions {
        param([string]$Path, [string[]]$Names)
        $Tokens = $null; $Errors = $null
        $Ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)
        if ($Errors.Count) { throw $Errors[0] }
        $Functions = @($Ast.FindAll({
            param($Node)
            $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -in $Names
        }, $true))
        foreach ($Name in $Names) {
            if ($Name -notin $Functions.Name) { throw "Function '$Name' not found in '$Path'." }
        }
        [scriptblock]::Create(($Functions.Extent.Text -join "`n"))
    }
    function Write-Log { param($Message, $Level) if ($Level -eq 'ERROR') { throw $Message } }
    function Invoke-SqlcmdLogged { param($ServerInstance, $Database, $Query, $Context) throw 'Unmocked SQL call' }
    function Connect-SmoTrusted { param($ServerInstance) throw 'Unmocked SQL call' }
}

Describe 'Shared server-object utilities' -Tag 'Unit' {
    It 'Defines shared functions once, only in the server-object helper' {
        $Names = @('Test-FileExists', 'Write-Log', 'Invoke-SqlcmdSafe', 'Test-SqlServerConnection',
            'Test-ADPrincipalExists', 'Escape-SqlLiteral', 'Escape-SqlBracket', 'Convert-BytesToHex',
            'Invoke-SqlcmdLogged', 'Get-BatchTargetDatabase', 'Add-Sql', 'Exec-LogText',
            'Exec-LogCsvRow', 'Invoke-SqlcmdTarget', 'Write-Summary', 'Connect-SmoTrusted',
            'Get-SafeFileName', 'Add-SectionHeader', 'Add-MigrationResult', 'Write-ServerMigrationSummary')
        foreach ($Path in @((Join-Path $Scripts 'Common\ServerObjects.Helpers.ps1'),
                (Join-Path $Scripts 'Invoke-MigrateServerObjects-OnPrem-AzSQLMI.ps1'),
                (Join-Path $Scripts 'Invoke-MigrateServerObjects-OnPrem-AzSQLVM.ps1'))) {
            $Tokens = $null; $Errors = $null
            $Ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)
            $Errors.Count | Should -Be 0
            $Functions = @($Ast.FindAll({
                param($Node)
                $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -in $Names
            }, $true))
            if ($Path -like '*Helpers.ps1') {
                foreach ($Name in $Names) { @($Functions | Where-Object Name -eq $Name).Count | Should -Be 1 }
            }
            else { $Functions.Count | Should -Be 0 }
        }
    }
    It 'Preserves escaping, SID encoding, and SQL batch routing' {
        Escape-SqlLiteral -Value "a'b" | Should -Be "a''b"
        Escape-SqlBracket -Value 'a]b' | Should -Be 'a]]b'
        Convert-BytesToHex -Bytes ([byte[]]@(0, 15, 255)) | Should -Be '0x000FFF'
        Get-BatchTargetDatabase -BatchText "USE [AppDb];`nSELECT 1;" | Should -Be 'AppDb'
        Get-BatchTargetDatabase -BatchText 'SELECT 1;' -DefaultDb 'Fallback' | Should -Be 'Fallback'
    }
    It 'Validates files without accepting directories or missing paths' {
        $File = New-Item -ItemType File -Path (Join-Path $TestDrive 'input.csv')
        { Test-FileExists -Path $File.FullName -FileType 'CSV' } | Should -Not -Throw
        { Test-FileExists -Path $TestDrive -FileType 'CSV' } | Should -Throw '*is a directory*'
        { Test-FileExists -Path (Join-Path $TestDrive 'missing.csv') -FileType 'CSV' } | Should -Throw '*not found*'
    }
    It 'Builds shared SQL sections in the caller script builder' {
        $Previous = $script:sb
        try {
            $script:sb = [Text.StringBuilder]::new()
            Add-SectionHeader -Title 'Permissions' -Db 'AppDb'
            Add-Sql -Text 'SELECT 1;'
            $Sql = $script:sb.ToString()
            $Sql | Should -Match 'DATABASE: AppDb'
            $Sql | Should -Match 'SECTION: Permissions'
            $Sql | Should -Match 'SELECT 1;'
        }
        finally { $script:sb = $Previous }
    }
    It 'Keeps caller log paths and error-state tracking' {
        . (Get-SourceFunctions -Path (Join-Path $Scripts 'Common\ServerObjects.Helpers.ps1') -Names @('Write-Log'))
        Mock Write-Host {}
        $Previous = $script:MigrationHadErrors
        try {
            $script:MigrationHadErrors = $false
            $LogFile = Join-Path $TestDrive 'migration.log'
            Write-Log -Message 'shared helper failure' -Level 'ERROR' -LogFile $LogFile
            $script:MigrationHadErrors | Should -BeTrue
            Get-Content -LiteralPath $LogFile | Should -Match '\[ERROR\] shared helper failure'
        }
        finally { $script:MigrationHadErrors = $Previous }
    }
}

Describe 'Source SQL certificate policies' -Tag 'Unit' {
    BeforeAll {
        . (Get-SourceFunctions -Path (Join-Path $Scripts 'Common\ServerObjects.Helpers.ps1') -Names @(
            'Invoke-SqlcmdLogged', 'Connect-SmoTrusted'))
        function Invoke-Sqlcmd {
            [CmdletBinding()]
            param($ServerInstance, $Database, $Query, $ConnectionString,
                [string]$Encrypt, [switch]$EncryptConnection, [switch]$TrustServerCertificate)
            throw 'Unmocked SQL call'
        }
    }
    BeforeEach {
        $PreviousTrust = $script:SourceTrustServerCertificate
        Mock Write-Log {}
        Mock Invoke-Sqlcmd { [pscustomobject]@{ Result = 'metadata' } }
    }
    AfterEach { $script:SourceTrustServerCertificate = $PreviousTrust }
    It 'Uses source trust <Trust> for metadata without disabling encryption' -ForEach @(
        @{ Trust = $false }, @{ Trust = $true }
    ) {
        $script:SourceTrustServerCertificate = $Trust
        (Invoke-SqlcmdLogged -ServerInstance source -Database AppDb -Query 'SELECT 1;').Result | Should -Be metadata
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
            $ServerInstance -eq 'source' -and $Encrypt -eq 'Mandatory' -and [bool]$TrustServerCertificate -eq $Trust
        }
    }
    It 'Preserves legacy target helper policy even when source validation is strict' {
        $script:SourceTrustServerCertificate = $false
        $null = Invoke-SqlcmdSafe -ServerInstance target -Database master -Query 'SELECT 1;'
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
            $ServerInstance -eq 'target' -and $Encrypt -eq 'Mandatory' -and $TrustServerCertificate
        }
    }
    It 'Uses the legacy encryption switch for cmdlets without Encrypt' {
        Mock Get-Command { [pscustomobject]@{ Parameters = @{ TrustServerCertificate = $null } } } -ParameterFilter { $Name -eq 'Invoke-Sqlcmd' }
        $null = Invoke-SqlcmdSafe -ServerInstance source -Database AppDb -Query 'SELECT 1;' -TrustServerCertificate $true
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
            $EncryptConnection -and -not $Encrypt -and $TrustServerCertificate
        }
    }
    It 'Uses an encrypted connection-string fallback with trust <Trust>' -ForEach @(
        @{ Trust = $false }, @{ Trust = $true }
    ) {
        Mock Get-Command { [pscustomobject]@{ Parameters = @{} } } -ParameterFilter { $Name -eq 'Invoke-Sqlcmd' }
        $null = Invoke-SqlcmdSafe -ServerInstance source -Database AppDb -Query 'SELECT 1;' -TrustServerCertificate $Trust
        Should -Invoke Invoke-Sqlcmd -Times 1 -Exactly -ParameterFilter {
            $Builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($ConnectionString)
            $Builder.Encrypt -and $Builder.TrustServerCertificate -eq $Trust -and $Builder.IntegratedSecurity
        }
    }
    It 'Uses an encrypted SMO connection with trust <Trust>' -ForEach @(
        @{ Trust = $false }, @{ Trust = $true }
    ) {
        $Context = [pscustomobject]@{}
        $Context | Add-Member -MemberType ScriptMethod -Name Connect -Value {}
        $Smo = [pscustomobject]@{ ConnectionContext = $Context }
        Mock New-Object { [pscustomobject]@{} } -ParameterFilter { $TypeName -eq 'Microsoft.Data.SqlClient.SqlConnection' }
        Mock New-Object { [pscustomobject]@{} } -ParameterFilter { $TypeName -eq 'Microsoft.SqlServer.Management.Common.ServerConnection' }
        Mock New-Object { $Smo } -ParameterFilter { $TypeName -eq 'Microsoft.SqlServer.Management.Smo.Server' }
        $null = Connect-SmoTrusted -ServerInstance source -TrustServerCertificate $Trust
        Should -Invoke New-Object -Times 1 -Exactly -ParameterFilter {
            if ($TypeName -ne 'Microsoft.Data.SqlClient.SqlConnection') { return $false }
            $Builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new([string]$ArgumentList[0])
            $Builder.Encrypt -and $Builder.TrustServerCertificate -eq $Trust -and $Builder.IntegratedSecurity
        }
    }
    It 'Resets the source policy for every legacy worker row on <Platform>' -ForEach @(
        @{ Platform = 'SQLVM' }, @{ Platform = 'SQLMI' }
    ) {
        $Tokens = $null; $Errors = $null
        $Ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $Scripts "Invoke-MigrateServerObjects-OnPrem-Az$Platform.ps1"), [ref]$Tokens, [ref]$Errors)
        $Assignment = @($Ast.FindAll({
            param($Node)
            $Node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $Node.Left.Extent.Text -eq '$script:SourceTrustServerCertificate'
        }, $true))
        $Assignment | Should -HaveCount 1
        foreach ($Trust in @($true, $false)) {
            $row = [pscustomobject]@{ SourceTrustServerCertificate = $Trust }
            . ([scriptblock]::Create($Assignment[0].Extent.Text))
            $script:SourceTrustServerCertificate | Should -Be $Trust
        }
        $SourceConnections = @($Ast.FindAll({
            param($Node)
            $Node -is [Management.Automation.Language.CommandAst] -and
            $Node.GetCommandName() -in @('Test-SqlServerConnection', 'Invoke-SqlcmdSafe', 'Connect-SmoTrusted') -and
            $Node.Extent.Text -match '-ServerInstance \$SourceServer'
        }, $true))
        $SourceConnections | Should -HaveCount 3
        foreach ($Connection in $SourceConnections) {
            $Connection.Extent.Text | Should -Match '-TrustServerCertificate:\$script:SourceTrustServerCertificate'
        }
    }
}

Describe 'Security scope and derived domain prefix' -Tag 'Unit' {
    It 'Derives <Expected> from source <Source>' -ForEach @(
        @{ Source = 'DESKTOP-SGA61QP\DMF'; Expected = 'DESKTOP-SGA61QP' },
        @{ Source = 'host'; Expected = 'host' },
        @{ Source = 'host.example.local\instance'; Expected = 'host.example.local' }
    ) {
        Get-ServerObjectDomainPrefix -SourceServerName $Source | Should -Be $Expected
    }
    It 'Selects exact security databases for scope <Scope> and list <List>' -ForEach @(
        @{ Scope = 'All'; List = @('AppDb'); Expected = @('master', 'msdb', 'model', 'tempdb', 'AppDb') },
        @{ Scope = 'Database'; List = @('AppDb'); Expected = @('AppDb') },
        @{ Scope = 'DB'; List = @('AppDb', 'msdb'); Expected = @('AppDb') },
        @{ Scope = 'All'; List = @('All'); Expected = @('master', 'msdb', 'model', 'tempdb', 'AppDb', 'OtherDb') },
        @{ Scope = 'Database'; List = @('All'); Expected = @('AppDb', 'OtherDb') },
        @{ Scope = 'Server'; List = @('AppDb'); Expected = @() }
    ) {
        $Names = @(Get-ServerObjectSecurityDatabaseNames -AvailableNames @('master', 'msdb', 'model', 'tempdb', 'AppDb', 'OtherDb') `
            -DatabaseList $List -Scope $Scope)
        $Names | Should -Be $Expected
    }
    It 'Rejects missing databases and ambiguous All lists' {
        { Get-ServerObjectSecurityDatabaseNames -AvailableNames AppDb -DatabaseList Missing -Scope All } | Should -Throw '*missing or offline*'
        { Get-ServerObjectSecurityDatabaseNames -AvailableNames AppDb -DatabaseList @('All', 'AppDb') } | Should -Throw '*All by itself*'
    }
}

Describe 'Generated security scope output' -Tag 'Unit' {
    It 'Generates server security and exact database users for <Platform> scope <Scope>' -ForEach @(
        @{ Platform = 'SQLVM'; Scope = 'Database' },
        @{ Platform = 'SQLVM'; Scope = 'All' },
        @{ Platform = 'SQLMI'; Scope = 'Database' },
        @{ Platform = 'SQLMI'; Scope = 'All' }
    ) {
        $Entry = Join-Path $Scripts "Invoke-MigrateServerObjects-OnPrem-Az$Platform.ps1"
        if ($Platform -eq 'SQLMI') {
            . (Get-SourceFunctions -Path $Entry -Names @('Generate-SQLLoginsForMI', 'Connect-EntraID', 'Build-EntraLookupTables', 'Get-SamFromDomainPrincipal'))
            Mock Connect-EntraID {}
            Mock Build-EntraLookupTables { @{ AzureUserBySam = @{ app = 'app@example.com' }; AzureGroupBySam = @{} } }
        }
        else { . (Get-SourceFunctions -Path $Entry -Names Generate-SQLLogins) }
        Mock Start-Transcript {}
        Mock Stop-Transcript {}
        Mock Write-Host {}
        Mock Test-ADPrincipalExists { $true }
        Mock Invoke-SqlcmdLogged {
            param($Context)
            switch ($Context) {
                'Fetch ONLINE databases' { @('master', 'msdb', 'model', 'tempdb', 'AppDb', 'OtherDb') | ForEach-Object { [pscustomobject]@{ name = $_ } } }
                'Fetch ONLINE databases including system DBs' { @('master', 'msdb', 'model', 'tempdb', 'AppDb', 'OtherDb') | ForEach-Object { [pscustomobject]@{ name = $_ } } }
                'Fetch Windows/AD logins' { [pscustomobject]@{ name = 'SRC\app'; type = 'U' } }
                'Fetch SQL logins' {
                    [pscustomobject]@{
                        name = 'source_sql_login'; sid = [byte[]]@(1, 2); password_hash = [byte[]]@(10, 11)
                        is_policy_checked = 1; is_expiration_checked = 0
                    }
                }
                'Fetch server role membership' { [pscustomobject]@{ RoleName = 'securityadmin'; MemberName = 'SRC\app'; MemberType = 'U' } }
                'Fetch server permissions' { [pscustomobject]@{ name = 'SRC\app'; permission_name = 'VIEW SERVER STATE'; PrincipalType = 'U'; state_desc = 'GRANT' } }
                'Fetch DB users mapped to server logins' { [pscustomobject]@{ UserName = 'SRC\app'; LoginName = 'SRC\app'; LoginType = 'U'; ServerLoginName = 'SRC\app' } }
            }
        }
        $Arguments = @{
            SourceServerName = 'SRC\instance'; DatabaseList = @('AppDb'); Component = 'Security'
            BaseFolder = Join-Path $TestDrive "$Platform-$Scope"; Scope = $Scope
        }
        $Info = if ($Platform -eq 'SQLMI') {
            Generate-SQLLoginsForMI @Arguments -DomainPrefix SRC -TenantId 'tenant' -SubscriptionId 'subscription'
        } else { Generate-SQLLogins @Arguments }
        $Sql = Get-Content -LiteralPath $Info.OutputFile -Raw
        $Sql | Should -Match 'CREATE LOGIN'
        $Sql | Should -Match 'ALTER SERVER ROLE \[securityadmin\]'
        $Sql | Should -Match 'GRANT VIEW SERVER STATE'
        if ($Platform -eq 'SQLVM') {
            $Sql | Should -Match 'CREATE LOGIN \[source_sql_login\]'
            $Sql | Should -Match 'WITH PASSWORD = 0x0A0B HASHED'
        }
        else {
            $Sql | Should -Match '(?m)^-- SQL LOGIN \(manual\): \[source_sql_login\]'
        }
        $Sql | Should -Match 'USE \[AppDb\].*CREATE USER|USE \[AppDb\];'
        $Sql | Should -Not -Match 'USE \[OtherDb\]'
        foreach ($Name in @('master', 'msdb', 'model', 'tempdb')) {
            $Pattern = 'USE \[' + $Name + '\];.*CREATE USER|USE \[' + $Name + '\];\r?\nIF NOT EXISTS \(SELECT 1 FROM sys.database_principals'
            if ($Scope -eq 'All') { $Sql | Should -Match $Pattern }
            else { $Sql | Should -Not -Match $Pattern }
        }
        Should -Invoke Invoke-SqlcmdLogged -Times 1 -Exactly -ParameterFilter { $Context -eq 'Fetch server role membership' }
        Should -Invoke Invoke-SqlcmdLogged -Times 0 -Exactly -ParameterFilter { $Database -eq 'OtherDb' }
        if ($Platform -eq 'SQLMI') {
            Should -Invoke Build-EntraLookupTables -Times 1 -Exactly -ParameterFilter {
                ($DatabaseList -contains 'msdb') -eq ($Scope -eq 'All') -and $DomainPrefix -eq 'SRC'
            }
        }
    }
}

Describe 'SQL Agent migration safeguards' -Tag 'Unit' {
    It 'Checks every T-SQL step, allowing system DBs and ignoring non-T-SQL step settings' {
        $Steps = @(
            @{ SubSystem = 'TransactSql'; DatabaseName = 'AppDb' }
            @{ SubSystem = 'TransactSql'; DatabaseName = 'OtherDb' }
            @{ SubSystem = 'TransactSql'; DatabaseName = 'master' }
            @{ SubSystem = 'PowerShell'; DatabaseName = 'Ignored' }
        )
        @(Get-OutOfScopeJobDatabase -Steps $Steps -Databases 'AppDb') | Should -Be @('OtherDb')
    }
    It 'Escapes disabled-job commands' {
        Get-DisabledImportedJobSql -JobName "job'name" | Should -Match "@job_name = N'job''name', @enabled = 0"
    }
    It 'Disables individual and combined <Platform> output and rejects mixed-scope jobs' -ForEach @(@{ Platform = 'SQLVM' }, @{ Platform = 'SQLMI' }) {
        . (Get-SourceFunctions -Path (Join-Path $Scripts "Invoke-MigrateServerObjects-OnPrem-Az$Platform.ps1") -Names @('Generate-SQLAgentJobs'))
        $Good = [pscustomobject]@{
            Name = 'AllowedJob'; IsEnabled = $true; OwnerLoginName = 'sa'; Category = 'Local'
            JobSteps = @(@{ SubSystem = 'TransactSql'; DatabaseName = 'AppDb' })
        }
        $Bad = [pscustomobject]@{
            Name = 'ForbiddenJob'; IsEnabled = $true; OwnerLoginName = 'sa'; Category = 'Local'
            JobSteps = @(@{ SubSystem = 'TransactSql'; DatabaseName = 'AppDb' }, @{ SubSystem = 'TransactSql'; DatabaseName = 'OtherDb' })
        }
        $Good | Add-Member -MemberType ScriptMethod -Name Script -Value { @("EXEC msdb.dbo.sp_add_job @job_name=N'AllowedJob', @enabled=$([int]$this.IsEnabled);") }
        $Bad | Add-Member -MemberType ScriptMethod -Name Script -Value { throw 'Out-of-scope jobs must not be scripted' }
        $script:SourceSmo = [pscustomobject]@{
            Information = @{ Version = '16.0' }; JobServer = @{ Jobs = @($Good, $Bad) }
            Databases = @(@{ Name = 'AppDb'; IsSystemObject = $false }, @{ Name = 'OtherDb'; IsSystemObject = $false })
        }
        Mock Connect-SmoTrusted { $script:SourceSmo }
        Mock New-Object { [pscustomobject]@{ Options = [pscustomobject]@{ ScriptDrops = $false; IncludeIfNotExists = $true } } } -ParameterFilter { $TypeName -like '*Scripter*' }
        Mock Start-Transcript {}
        Mock Stop-Transcript {}
        $Info = Generate-SQLAgentJobs -SourceServerName 'source' -DatabaseList 'AppDb' -Component 'SQL Agents' -BaseFolder (Join-Path $TestDrive $Platform)
        $Combined = Get-Content $Info.OutputFile -Raw
        $Individual = Get-Content (Join-Path (Split-Path $Info.OutputFile) 'Jobs\AllowedJob.sql') -Raw
        foreach ($Sql in @($Combined, $Individual)) {
            $Sql | Should -Match "@job_name = N'AllowedJob', @enabled = 0"
            $Sql | Should -Match "sp_add_job @job_name=N'AllowedJob', @enabled=0"
            $Sql | Should -Match 'sp_update_job @job_name ='
            $Sql | Should -Not -Match 'sp_delete_job'
            $Sql | Should -Not -Match 'ForbiddenJob'
        }
        $Info.ItemCount | Should -Be 1
        $Good.IsEnabled | Should -BeTrue
        Join-Path (Split-Path $Info.OutputFile) 'Jobs\ForbiddenJob.sql' | Should -Not -Exist
    }
}

Describe 'Rerunnable job SQL updates' -Tag 'Unit' {
    It 'Updates job definitions, steps, schedules and attachments without replacing job IDs or history' {
        $Sql = @'
DECLARE @ReturnCode int = 0, @jobId binary(16);
EXEC @ReturnCode = msdb.dbo.sp_add_job @job_name=N'Job O''Brien', @enabled=0, @description=N'new', @job_id=@jobId OUTPUT;
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_id=1, @step_name=N'new step', @command=N'PRINT ''EXEC msdb.dbo.sp_add_job @job_name=not_a_real_call'';', @database_name=N'AppDb';
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'Daily', @enabled=1, @freq_type=4, @schedule_uid=N'00000000-0000-0000-0000-000000000001';
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'Weekly', @enabled=1, @freq_type=8, @freq_interval=1;
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id=@jobId, @server_name=N'(local)';
'@
        $Updated = ConvertTo-ServerObjectJobUpsertSql -Sql $Sql
        $Updated | Should -Match "SELECT @jobId = job_id FROM msdb.dbo.sysjobs WHERE name = N'Job O''Brien'"
        $Updated | Should -Match 'IF @jobId IS NULL'
        $Updated | Should -Match 'sp_update_job @job_id = @jobId'
        $Updated | Should -Match 'sysjobsteps WHERE job_id = @jobId AND step_id = 1'
        $Updated | Should -Match 'sp_update_jobstep @job_id = @jobId, @step_id = 1'
        $Updated | Should -Match 'sp_update_schedule @schedule_id = @MigrationSchedule'
        $Updated | Should -Match 'job_id <> @jobId'
        $Updated | Should -Match 'sp_detach_schedule.*@delete_unused_schedule = 0'
        $Updated | Should -Match 'IF NOT EXISTS.*sysjobservers WHERE job_id = @jobId'
        $Updated | Should -Not -Match 'sp_delete_job|DROP |@schedule_uid'
        $Updated | Should -Match ([regex]::Escape("N'PRINT ''EXEC msdb.dbo.sp_add_job @job_name=not_a_real_call'';'"))
        @([regex]::Matches($Updated, 'DECLARE @MigrationSchedule\d+ int;')) | Should -HaveCount 2
        $Errors = $null
        $Parser = [Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser]::new($true)
        $Reader = [IO.StringReader]::new($Updated)
        try { $null = $Parser.Parse($Reader, [ref]$Errors) } finally { $Reader.Dispose() }
        $Errors | Should -BeNullOrEmpty
    }
    It 'Fails explicitly for malformed job SQL or unsupported unnamed arguments' {
        { ConvertTo-ServerObjectJobUpsertSql -Sql 'EXEC @broken syntax ???' } | Should -Throw '*Cannot parse*'
        { ConvertTo-ServerObjectJobUpsertSql -Sql "EXEC msdb.dbo.sp_add_job N'unnamed';" } | Should -Throw '*Named parameters*'
        { ConvertTo-ServerObjectJobUpsertSql -Sql "EXEC msdb.dbo.sp_add_jobstep @step_id=1;" } | Should -Throw '*requires @job_id*'
    }
}

Describe 'Database Mail shared SQL generation' -Tag 'Unit' {
    It 'Rewrites literal server names without regex or replacement-string interpretation' {
        Convert-DatabaseMailSender -Value 'SOURCE01 DBA <source01@example.local>' -SourceServerName 'source01.example.local\instance' -TargetServerName 'target$1.example.local' |
            Should -Be 'target$1 DBA <target$1@example.local>'
    }
    It 'Generates rewritten <Platform> accounts with the configured relay' -ForEach @(@{ Platform = 'SQLVM' }, @{ Platform = 'SQLMI' }) {
        Mock Start-Transcript {}
        Mock Stop-Transcript {}
        Mock Invoke-SqlcmdLogged {
            param($Context)
            if ($Context -eq 'Fetch Database Mail Profiles') { [pscustomobject]@{ ProfileName = 'Profile'; description = "New O'Brien" } }
            elseif ($Context -eq 'Fetch Profile-Account Associations') { [pscustomobject]@{ ProfileName = 'Profile'; AccountName = 'mail'; sequence_number = 2 } }
            elseif ($Context -eq 'Fetch Principal-Profile Associations') { [pscustomobject]@{ ProfileName = 'Profile'; PrincipalName = 'public'; is_default = 1 } }
            elseif ($Context -eq 'Fetch Database Mail Accounts') {
                [pscustomobject]@{
                    AccountName = 'mail'; description = ''; email_address = 'source01@example.local'
                    display_name = "source01 DBA's"; replyto_address = ''; servertype = 'SMTP'
                    mailserver_name = 'old-relay'; port = 25; username = ''; use_default_credentials = 0; enable_ssl = 1
                }
            }
        }
        $Info = Generate-SQLDBMail -SourceServerName 'source01.example.local' -TargetServerName 'target01.example.local' `
            -Component 'SQL DB Mail' -BaseFolder (Join-Path $TestDrive $Platform) -TargetType $Platform -SmtpServer 'relay.example.local' -SmtpPort 587
        $Sql = Get-Content $Info.OutputFile -Raw
        $Sql | Should -Match "@email_address\s*=\s*N'target01@example.local'"
        $Sql | Should -Match "@display_name\s*=\s*N'target01 DBA''s'"
        $Sql | Should -Match 'relay.example.local'
        $Sql | Should -Match '@port\s*=\s*587'
        $Sql | Should -Not -Match "@email_address\s*=\s*N'source01"
        $Sql | Should -Match 'sysmail_update_account_sp'
        $Sql | Should -Match "sysmail_update_profile_sp\s+@profile_name = N'Profile',\s+@description = N'New O''Brien'"
        $Sql | Should -Match 'sysmail_update_profileaccount_sp'
        $Sql | Should -Match '@sequence_number = 2'
        $Sql | Should -Match 'sysmail_update_principalprofile_sp'
        $Sql | Should -Match '@is_default = 1'
        $Sql | Should -Not -Match 'sysmail_delete_'
    }
}

Describe 'Mixed-target dispatch and JSON' -Tag 'Unit' {
    BeforeEach { Mock Write-Warning {} }
    It 'Routes each platform once, aggregates results and removes temporary files' {
        $script:TemporaryConfigs = @()
        Mock Invoke-ServerObjectPlatform {
            param($EntryPath, $ConfigPath, $OutputJsonPath)
            $script:TemporaryConfigs += $ConfigPath
            $Rows = @((Read-ServiceConfiguration -Path $ConfigPath).Items)
            $EntryPath | Should -Match ("Az" + $Rows[0].TargetType + '\.ps1$')
            Write-ServerObjectJsonResult -Path $OutputJsonPath -Started ([datetime]::UtcNow) -RunCompleted $true -Results @(
                [pscustomobject]@{ SourceServer = 'source'; TargetServer = $Rows[0].TargetType; Component = 'test'; Status = 'SUCCESS'; Mode = 'Generate'; OutputFile = ''; ErrorMessage = '' }
            )
        }

        $Results = [Collections.Generic.List[object]]::new()
        Invoke-ServerObjectBatch -Rows @([pscustomobject]@{ TargetType = 'SQLVM' }, [pscustomobject]@{ TargetType = 'SQLMI' }) -ScriptsPath $Scripts -Results $Results
        $Results.Count | Should -Be 2
        Should -Invoke Invoke-ServerObjectPlatform -Times 2 -Exactly
        foreach ($Path in $script:TemporaryConfigs) { Test-Path (Split-Path $Path) | Should -BeFalse }
    }
    It 'Validates all target types before invoking any platform' {
        Mock Invoke-ServerObjectPlatform {}
        $Results = [Collections.Generic.List[object]]::new()
        { Invoke-ServerObjectBatch -Rows @([pscustomobject]@{ TargetType = 'SQLVM' }, [pscustomobject]@{ TargetType = 'invalid' }) -ScriptsPath $Scripts -Results $Results } | Should -Throw '*TargetType*'
        Should -Invoke Invoke-ServerObjectPlatform -Times 0 -Exactly
    }
    It 'Continues with remaining platforms, records failures and cleans up' {
        $script:TemporaryConfigs = @()
        Mock Invoke-ServerObjectPlatform {
            param($EntryPath, $ConfigPath, $OutputJsonPath)
            $script:TemporaryConfigs += $ConfigPath
            if ($EntryPath -like '*AzSQLVM.ps1') { throw 'simulated VM failure' }
            Write-ServerObjectJsonResult -Path $OutputJsonPath -Started ([datetime]::UtcNow) -RunCompleted $true
        }
        $Results = [Collections.Generic.List[object]]::new()
        { Invoke-ServerObjectBatch -Rows @([pscustomobject]@{ TargetType = 'SQLVM' }, [pscustomobject]@{ TargetType = 'SQLMI' }) -ScriptsPath $Scripts -Results $Results } | Should -Throw '*platform migrations failed*'
        @($Results | Where-Object Status -eq 'FAILED').Count | Should -Be 1
        Should -Invoke Invoke-ServerObjectPlatform -Times 2 -Exactly
        foreach ($Path in $script:TemporaryConfigs) { Test-Path (Split-Path $Path) | Should -BeFalse }
    }
    It 'Rejects success without a child result file' {
        Mock Invoke-ServerObjectPlatform {}
        $Results = [Collections.Generic.List[object]]::new()
        { Invoke-ServerObjectBatch -Rows @([pscustomobject]@{ TargetType = 'SQLVM' }) -ScriptsPath $Scripts -Results $Results } | Should -Throw '*platform migrations failed*'
        $Results[0].ErrorMessage | Should -Match 'did not write'
    }
    It 'Writes stable result arrays and component error details' {
        $Path = Join-Path $TestDrive 'results\summary.json'
        Write-ServerObjectJsonResult -Path $Path -Started ([datetime]::UtcNow) -RunCompleted $false -ErrorMessage 'configuration failed'
        $Summary = Get-Content $Path -Raw | ConvertFrom-Json
        $Summary.results | Should -HaveCount 0
        $Summary.errors | Should -HaveCount 1
        $Summary.status | Should -Be 'Failed'
        Write-ServerObjectJsonResult -Path $Path -Started ([datetime]::UtcNow) -RunCompleted $true -Results @(
            [pscustomobject]@{ SourceServer = 's'; TargetServer = 't'; Component = 'jobs'; Status = 'FAILED'; Mode = 'Generate+Execute'; OutputFile = 'jobs.sql'; ErrorMessage = 'failure' }
        )
        $Summary = Get-Content $Path -Raw | ConvertFrom-Json
        $Summary.results | Should -HaveCount 1
        $Summary.status | Should -Be 'Failed'
        $Summary.errors[0].ErrorMessage | Should -Be 'failure'
    }
}

Describe 'Platform entry-point feature wiring' -Tag 'Unit' {
    It 'Wires <Platform> mail generation outside execute-only and removes separate identity generation' -ForEach @(@{ Platform = 'SQLVM' }, @{ Platform = 'SQLMI' }) {
        $Tokens = $null; $Errors = $null
        $Ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Scripts "Invoke-MigrateServerObjects-OnPrem-Az$Platform.ps1"), [ref]$Tokens, [ref]$Errors)
        $Calls = @($Ast.FindAll({
            param($Node)
            $Node -is [Management.Automation.Language.CommandAst] -and
            $Node.GetCommandName() -in @('Generate-ManagedIdentityAccess', 'Generate-SQLDBMail')
        }, $true))
        $Calls.Count | Should -BeGreaterOrEqual 1
        foreach ($Call in $Calls) { $Call.GetCommandName() | Should -Be Generate-SQLDBMail }
        foreach ($Call in $Calls) {
            $Parent = $Call.Parent
            while ($Parent) {
                if ($Parent -is [Management.Automation.Language.IfStatementAst]) {
                    $Parent.Clauses[0].Item1.Extent.Text | Should -Not -Be '$OnlyTargetExecutionFlag'
                }
                $Parent = $Parent.Parent
            }
            $Command = Get-Command $Call.GetCommandName()
            foreach ($Parameter in ($Call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })) {
                $Command.Parameters.ContainsKey($Parameter.ParameterName) | Should -BeTrue
            }
            if ($Call.GetCommandName() -eq 'Generate-SQLDBMail') {
                $Call.Extent.Text | Should -Match '\-TargetServerName \$TargetServer'
            }
        }
    }
}
