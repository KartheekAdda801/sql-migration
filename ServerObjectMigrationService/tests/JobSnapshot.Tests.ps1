#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    Import-Module SqlServer -ErrorAction Stop
    . (Join-Path $PSScriptRoot '..\scripts\Common\ServerObjects.Helpers.ps1')
    . (Join-Path $PSScriptRoot '..\scripts\Common\ServerObjects.SecuritySnapshot.Helpers.ps1')
    . (Join-Path $PSScriptRoot '..\scripts\Common\ServerObjects.JobSnapshot.Helpers.ps1')
    function New-TestStep {
        param($Command = 'SELECT 1;', $Database = 'master', $Subsystem = 'TransactSql', $Proxy = '')
        [pscustomobject]@{ Name = 'step'; Command = $Command; DatabaseName = $Database; SubSystem = $Subsystem; ProxyName = $Proxy }
    }
    function New-TestJob {
        param($Name = 'job', $Enabled = $true, $Steps = @((New-TestStep)), $Owner = 'sa')
        $Job = [pscustomobject]@{
            Name = $Name; IsEnabled = $Enabled; OwnerLoginName = $Owner; Category = 'DBA'
            JobSteps = $Steps
        }
        $Job | Add-Member ScriptMethod Script {
            param($Options)
            if ($Options.ScriptDrops) { throw 'Unexpected drop scripting' }
            if ($Options.IncludeIfNotExists) { throw 'Outer existence guards would prevent job updates' }
            "EXEC msdb.dbo.sp_add_job @job_name=N'$($this.Name)', @enabled=$([int]$this.IsEnabled), @owner_login_name=N'$($this.OwnerLoginName)';"
        }
        $Job
    }
    function New-TestReplayBlock {
        param($Owner = 'sa')
        [pscustomobject]@{
            Name = "job's name"; SourceEnabled = $true
            Metadata = [pscustomobject]@{ Owner = $Owner; OwnerType = $(if ($Owner -match '\\') { 'U' } else { 'S' }); Subsystems = @('TransactSql'); Steps = @() }
            Sql = @"
DECLARE @jobId uniqueidentifier;
EXEC msdb.dbo.sp_add_job @job_name=N'job''s name', @enabled=1, @owner_login_name=N'$Owner', @job_id=@jobId OUTPUT;
EXEC msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_id=1, @step_name=N'step', @subsystem=N'TSQL',
    @command=N'EXEC msdb.dbo.sp_update_job @job_name=N''embedded'', @enabled=1; SELECT ''@owner_login_name=N''''DOMAIN\embedded'''''';';
EXEC msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'daily', @enabled=1, @freq_type=4, @freq_interval=1;
EXEC msdb.dbo.sp_add_jobserver @job_id=@jobId;
"@
        }
    }
    $script:SourceTrustServerCertificate = $true
    $script:VmItem = [pscustomobject]@{ TargetType = 'SQLVM'; JobOwnerUpnSuffix = '' }
}

Describe 'Source-only SQL Agent snapshot' -Tag Unit {
    BeforeEach {
        $script:Jobs = @()
        Mock Connect-SmoTrusted { [pscustomobject]@{ JobServer = [pscustomobject]@{ Jobs = $script:Jobs } } }
        Mock Invoke-SqlcmdLogged { @() }
    }
    It 'Captures enabled and disabled jobs without name/database filtering or source mutation' {
        $script:Jobs = @(
            (New-TestJob -Name 'DBA-ENABLED' -Enabled $true),
            (New-TestJob -Name 'other' -Enabled $false -Steps @((New-TestStep -Database 'NotSelected')))
        )
        $Blocks = @(Get-ServerObjectJobSnapshotBlocks -Server 'source\instance')
        $Blocks.Count | Should -Be 2
        $Blocks[0].SourceEnabled | Should -BeTrue
        $Blocks[0].Sql | Should -Match '@enabled=1'
        $Blocks[1].SourceEnabled | Should -BeFalse
        $Blocks[1].Sql | Should -Match '@enabled=0'
        $script:Jobs[0].IsEnabled | Should -BeTrue
        $Blocks[0].Component | Should -Be 'SQLAgentJobs'
        $Blocks[0].Kind | Should -Be 'Job'
        $Blocks[0].Database | Should -Be ''
        $Blocks[0].Metadata.Owner | Should -Be 'sa'
        $Blocks[0].Metadata.Category | Should -Be 'DBA'
        $Copy = $Blocks | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $Copy[0].Metadata.Steps[0].Command | Should -Be 'SELECT 1;'
        Should -Invoke Connect-SmoTrusted -Times 1 -Exactly -ParameterFilter {
            $ServerInstance -eq 'source\instance' -and $TrustServerCertificate
        }
    }
    It 'Returns no blocks for an empty source' {
        @(Get-ServerObjectJobSnapshotBlocks -Server source).Count | Should -Be 0
    }
    It 'Excludes system metadata and exact platform jobs but retains user jobs owned by sa' {
        $System = New-TestJob -Name 'metadata-system'
        $System | Add-Member NoteProperty IsSystemObject $true
        $script:Jobs = @($System, (New-TestJob -Name 'syspolicy_purge_history'),
            (New-TestJob -Name 'SSIS Server Maintenance Job'),
            (New-TestJob -Name 'user-system-service-admin' -Owner sa -Enabled $false))
        $Blocks = @(Get-ServerObjectJobSnapshotBlocks source)
        $Blocks.Name | Should -Be @('user-system-service-admin')
        $Blocks[0].SourceEnabled | Should -BeFalse
        $Blocks[0].Metadata.Owner | Should -Be sa
    }
    It 'Captures group and local owner metadata without translating the raw job script' {
        $script:Jobs = @((New-TestJob -Owner 'SOURCE\group'))
        Mock Invoke-SqlcmdLogged {
            [pscustomobject]@{ Name = 'SOURCE\group'; Type = 'G'; IsLocalWindowsPrincipal = $true }
        } -ParameterFilter { $Context -eq 'JobSnapshot.Owners' }
        $Block = Get-ServerObjectJobSnapshotBlocks source
        $Block.Metadata.OwnerType | Should -Be G
        $Block.Metadata.OwnerIsLocal | Should -BeTrue
        $Block.Sql | Should -Match 'SOURCE\\group'
    }
    It 'Does not claim empty jobs or notification dependencies are self-contained' {
        $Job = New-TestJob -Steps @()
        $script:Jobs = @($Job)
        (Get-ServerObjectJobSnapshotBlocks -Server source).ServerSafe | Should -BeFalse
        $Job = New-TestJob
        $Job | Add-Member NoteProperty OperatorToEmail 'DBA email'
        $script:Jobs = @($Job)
        $Block = Get-ServerObjectJobSnapshotBlocks -Server source
        $Block.ServerSafe | Should -BeFalse
        $Block.Metadata.NotificationOperators | Should -Contain 'DBA email'
        $Block.Metadata.DependencyWarnings -join ' ' | Should -Match 'notification configuration'
    }
    It 'Proves only simple self-contained system queries safe' {
        $script:Jobs = @((New-TestJob -Steps @((New-TestStep -Command 'USE master; SELECT name FROM sys.databases;'))))
        $Block = Get-ServerObjectJobSnapshotBlocks -Server source
        $Block.ServerSafe | Should -BeTrue
        @($Block.DependsOnDatabases).Count | Should -Be 0
        @($Block.Metadata.DependencyWarnings).Count | Should -Be 0
    }
    It 'Collects USE and three/four-part database references as well as step context' {
        $script:Jobs = @((New-TestJob -Steps @((New-TestStep -Database 'ContextOnly' -Command @'
USE [App One];
SELECT * FROM [OtherDb].[dbo].[t];
SELECT * FROM [Linked].[RemoteDb].[dbo].[t];
'@))))
        $Block = Get-ServerObjectJobSnapshotBlocks -Server source
        $Block.ServerSafe | Should -BeFalse
        $Block.DependsOnDatabases | Should -Contain 'ContextOnly'
        $Block.DependsOnDatabases | Should -Contain 'App One'
        $Block.DependsOnDatabases | Should -Contain 'OtherDb'
        $Block.DependsOnDatabases | Should -Contain 'RemoteDb'
        $Block.Metadata.DependencyWarnings -join ' ' | Should -Match 'remote server'
    }
    It 'Keeps uncertain jobs with actionable warnings: <Reason>' -TestCases @(
        @{ Command = 'EXEC master.dbo.ArbitraryProc;'; Subsystem = 'TransactSql'; Proxy = ''; Reason = 'unresolved stored procedure' }
        @{ Command = "EXEC(N'USE HiddenDb; SELECT 1;');"; Subsystem = 'TransactSql'; Proxy = ''; Reason = 'dynamic SQL' }
        @{ Command = 'SELECT * FROM dbo.Synonym;'; Subsystem = 'TransactSql'; Proxy = ''; Reason = 'context alone' }
        @{ Command = 'SELECT ???'; Subsystem = 'TransactSql'; Proxy = ''; Reason = 'cannot be classified' }
        @{ Command = 'echo hello'; Subsystem = 'CmdExec'; Proxy = ''; Reason = 'external dependencies' }
        @{ Command = 'Get-Date'; Subsystem = 'PowerShell'; Proxy = ''; Reason = 'external dependencies' }
        @{ Command = '/SQL package'; Subsystem = 'SSIS'; Proxy = ''; Reason = 'external dependencies' }
        @{ Command = 'SELECT 1;'; Subsystem = 'TransactSql'; Proxy = 'credential'; Reason = 'uses proxy' }
        @{ Command = "SELECT * FROM OPENROWSET('provider','connection','query') t;"; Subsystem = 'TransactSql'; Proxy = ''; Reason = 'external' }
        @{ Command = 'SELECT 1 INTO master.dbo.NewTable;'; Subsystem = 'TransactSql'; Proxy = ''; Reason = 'mutable' }
    ) {
        param($Command, $Subsystem, $Proxy, $Reason)
        $script:Jobs = @((New-TestJob -Steps @((New-TestStep -Command $Command -Subsystem $Subsystem -Proxy $Proxy))))
        $Blocks = @(Get-ServerObjectJobSnapshotBlocks -Server source)
        $Blocks.Count | Should -Be 1
        $Blocks[0].ServerSafe | Should -BeFalse
        $Blocks[0].Metadata.DependencyWarnings -join ' ' | Should -Match $Reason
    }
}

Describe 'Offline SQL Agent replay' -Tag Unit {
    BeforeEach {
        Mock Connect-SmoTrusted { throw 'Replay must not connect to the source' }
    }
    It 'Upserts in place, disables create and existing-job updates, and preserves embedded commands' {
        $Block = New-TestReplayBlock
        $Sql = ConvertTo-ServerObjectJobReplaySql -Block $Block -Item $script:VmItem
        $Sql | Should -Match 'sp_update_jobstep'
        $Sql | Should -Match 'sp_update_schedule'
        $Sql | Should -Match 'sysjobservers'
        $Sql | Should -Not -Match 'sp_delete_job'
        $Sql | Should -Match "@job_name = N'job''s name', @enabled = 0"
        $Nodes = @(Get-ServerObjectJobSqlNodes -Tree (Get-ServerObjectJobSqlTree -Sql $Sql))
        $Jobs = @($Nodes | Where-Object {
            $_ -is [Microsoft.SqlServer.TransactSql.ScriptDom.ExecuteStatement] -and
            $_.ExecuteSpecification.ExecutableEntity.ProcedureReference.ProcedureReference.Name.BaseIdentifier.Value -in @('sp_add_job', 'sp_update_job')
        })
        $Jobs.Count | Should -BeGreaterOrEqual 3
        foreach ($Job in $Jobs) {
            @($Job.ExecuteSpecification.ExecutableEntity.Parameters | Where-Object { $_.Variable.Name -eq '@enabled' })[0].ParameterValue.Value | Should -Be '0'
        }
        $Commands = @($Nodes | Where-Object {
            $_ -is [Microsoft.SqlServer.TransactSql.ScriptDom.ExecuteParameter] -and $_.Variable.Name -eq '@command'
        })
        $Commands.Count | Should -Be 2
        foreach ($Command in $Commands) {
            $Command.ParameterValue.Value | Should -Match "@enabled=1"
            $Command.ParameterValue.Value | Should -Match 'DOMAIN\\embedded'
        }
        # Repeated generation has no target/source side effects and keeps the shared upsert logic.
        (ConvertTo-ServerObjectJobReplaySql -Block $Block -Item $script:VmItem) | Should -BeExactly $Sql
        Should -Invoke Connect-SmoTrusted -Times 0
    }
    It 'Uses the shared upsert helper' {
        Mock ConvertTo-ServerObjectJobUpsertSql { param($Sql) $Sql }
        $null = ConvertTo-ServerObjectJobReplaySql -Block (New-TestReplayBlock) -Item $script:VmItem
        Should -Invoke ConvertTo-ServerObjectJobUpsertSql -Times 1 -Exactly
    }
    It 'Preserves domain job owners on SQLVM without Entra lookup' {
        Mock Resolve-SecuritySnapshotEntraPrincipal { throw 'VM must not resolve Entra identities' }
        $Block = New-TestReplayBlock -Owner 'DOMAIN\owner'
        $Sql = ConvertTo-ServerObjectJobReplaySql $Block $script:VmItem
        $Sql | Should -Match "@owner_login_name = N'DOMAIN\\owner'"
        Should -Invoke Resolve-SecuritySnapshotEntraPrincipal -Times 0
    }
    It 'Resolves job-owner groups as groups rather than manufacturing a user UPN' {
        Mock Resolve-SecuritySnapshotEntraPrincipal { 'Reviewed Group' }
        $Block = New-TestReplayBlock -Owner 'DOMAIN\group'
        $Block.Metadata.OwnerType = 'G'
        $Sql = ConvertTo-ServerObjectJobReplaySql $Block ([pscustomobject]@{ TargetType = 'SQLMI' })
        $Sql | Should -Match "@owner_login_name = N'Reviewed Group'"
        Should -Invoke Resolve-SecuritySnapshotEntraPrincipal -Times 1 -Exactly -ParameterFilter { $Type -eq 'G' }
    }
    It 'Inserts disabled state when add/update statements omit enabled' {
        $Block = New-TestReplayBlock
        $Block.Sql = "EXEC msdb.dbo.sp_add_job @job_name=N'j'; EXEC msdb.dbo.sp_update_job @job_name=N'j';"
        $Sql = ConvertTo-ServerObjectJobReplaySql -Block $Block -Item $script:VmItem
        ([regex]::Matches($Sql, '@enabled\s*=\s*0')).Count | Should -Be 4
        { Get-ServerObjectJobSqlTree -Sql $Sql } | Should -Not -Throw
    }
    It 'Requires an explicit suffix for Windows owners with job/owner context' {
        $Item = [pscustomobject]@{ TargetType = 'SQLMI'; JobOwnerUpnSuffix = '' }
        Mock Resolve-SecuritySnapshotEntraPrincipal { throw "Cannot map Windows user 'DOMAIN\owner': supply a valid JobOwnerUpnSuffix." }
        { ConvertTo-ServerObjectJobReplaySql -Block (New-TestReplayBlock -Owner 'DOMAIN\owner') -Item $Item } |
            Should -Throw "*job's name*DOMAIN\owner*JobOwnerUpnSuffix*"
        Should -Invoke Connect-SmoTrusted -Times 0
    }
    It 'Uses the verified Entra resolver for Windows owners and retains the target login guard' {
        $Item = [pscustomobject]@{ TargetType = 'SQLMI'; JobOwnerUpnSuffix = '@example.com' }
        Mock Resolve-SecuritySnapshotEntraPrincipal { 'owner@example.com' }
        $Block = New-TestReplayBlock -Owner 'DOMAIN\owner'
        $Sql = ConvertTo-ServerObjectJobReplaySql -Block $Block -Item $Item
        $Sql | Should -Match "SUSER_ID\(N'owner@example.com'\) IS NULL THROW"
        $Sql | Should -Match "job''s name.*unresolved on target"
        $Sql | Should -Match "@owner_login_name = N'owner@example.com'"
        $Sql | Should -Match 'DOMAIN\\embedded'
        $Block.Sql | Should -Match 'DOMAIN\\owner'
        { Get-ServerObjectJobSqlTree -Sql $Sql } | Should -Not -Throw
        Should -Invoke Connect-SmoTrusted -Times 0
        Should -Invoke Resolve-SecuritySnapshotEntraPrincipal -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'DOMAIN\owner' -and $Type -eq 'U'
        }
    }
    It 'Rejects MI unsupported subsystems and proxies rather than removing them' {
        $Item = [pscustomobject]@{ TargetType = 'SQLMI'; JobOwnerUpnSuffix = '' }
        $Block = New-TestReplayBlock
        $Block.Metadata.Subsystems = @('PowerShell')
        { ConvertTo-ServerObjectJobReplaySql -Block $Block -Item $Item } | Should -Throw '*PowerShell*convert*'
        $Block.Metadata.Subsystems = @('TransactSql')
        $Block.Metadata.Steps = @([pscustomobject]@{ Name = 'proxy step'; Proxy = 'credential' })
        { ConvertTo-ServerObjectJobReplaySql -Block $Block -Item $Item } | Should -Throw '*proxy step*credential*explicitly*'
    }
    It 'Also rejects unsupported MI script parameters if metadata is missing them' {
        $Item = [pscustomobject]@{ TargetType = 'SQLMI'; JobOwnerUpnSuffix = '' }
        $Block = New-TestReplayBlock
        $Block.Sql = $Block.Sql.Replace("@subsystem=N'TSQL'", "@subsystem=N'CmdExec'")
        { ConvertTo-ServerObjectJobReplaySql -Block $Block -Item $Item } | Should -Throw '*unsupported*subsystem*'
        $Block.Sql = (New-TestReplayBlock).Sql.Replace("@subsystem=N'TSQL'", "@subsystem=N'TSQL', @proxy_name=N'credential'")
        { ConvertTo-ServerObjectJobReplaySql -Block $Block -Item $Item } | Should -Throw '*unsupported*proxy*'
        $Block.Sql = (New-TestReplayBlock).Sql.Replace("@subsystem=N'TSQL'", "@subsystem=N'TSQL', @proxy_id=@unresolved")
        { ConvertTo-ServerObjectJobReplaySql -Block $Block -Item $Item } | Should -Throw '*unresolved proxy*'
    }
    It 'Fails malformed snapshot scripts with job context' {
        $Block = New-TestReplayBlock
        $Block.Sql = 'EXEC @bad syntax ???'
        { ConvertTo-ServerObjectJobReplaySql -Block $Block -Item $script:VmItem } | Should -Throw "*job's name*Cannot parse*"
    }
}
