#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1')
    function Get-AzContext { [CmdletBinding()] param() throw 'Unmocked directory context' }
    function Get-AzADUser { [CmdletBinding()] param($UserPrincipalName) throw 'Unmocked directory lookup' }
    function Get-AzADGroup { [CmdletBinding()] param($DisplayName) throw 'Unmocked directory lookup' }
    function New-IdentityBlock {
        param($Name = 'DOMAIN\alice', $Type = 'U', $Kind = 'Login', $Database = '')
        [pscustomobject]@{
            Component = 'SQLLogins'; Kind = $Kind; Name = $Name; Database = $Database
            ServerSafe = -not $Database; DependsOnDatabases = @($Database); SourceEnabled = $true
            Sql = '-- raw source'; Metadata = [pscustomobject]@{ Name = $Name; Type = $Type; Sid = '0x00112233' }
        }
    }
}

Describe 'Read-only SQLMI identity report' -Tag Unit {
    BeforeEach {
        $Root = Join-Path $TestDrive "$([guid]::NewGuid())\SourceObjects"
        $Item = [pscustomobject]@{
            Id = 'test'; Activity = 'Generate'; TargetType = 'SQLMI'; SourceServerName = 'SOURCE'
            TenantId = 'tenant'; SubscriptionId = 'subscription'; JobOwnerUpnSuffix = 'cloud.example'
            EntraIdentityMappings = @{}; TargetSqlAuthType = 'SqlLogin'; TargetTrustServerCertificate = $false
            TargetSqlHost = 'target'; TargetSqlPort = 1433; SourceListofDatabases = 'All'
            SQLLoginsMigrationFlag = 'Yes'; SQLLoginsMigrationScope = 'All'
            SQLAgentJobsMigrationFlag = 'Yes'; SQLAgentJobsMigrationScope = 'All'; SQLAgentJobFilterCriteria = '.*'
            SQLDBMailMigrationFlag = 'No'; SQLAlertsMigrationFlag = 'No'; SQLOperatorsMigrationFlag = 'No'
        }
        Mock Write-Log {}
        Mock Get-AzContext {
            [pscustomobject]@{ Tenant = @{ Id = 'tenant' }; Subscription = @{ Id = 'subscription' } }
        }
        Mock Get-AzADUser { @() }
        Mock Get-AzADGroup { @() }
        Mock Assert-ServerObjectReplayTarget { throw 'No target connection permitted in this test' }
        Mock Invoke-ServerObjectPreflightQuery { throw 'No SQL permitted in this test' }
        Mock Get-ServerObjectTargetAuth { @{} }
        $Alice = New-IdentityBlock
        $Group = New-IdentityBlock 'DOMAIN\Team' G
    }
    It 'Preserves SQLVM Windows users and groups without any directory access or report' {
        $Item.TargetType = 'SQLVM'
        $Result = Export-ServerObjectMissingEntraIdentities $Item @($Alice, $Group) $Root
        $Result | Should -BeNullOrEmpty
        foreach ($Block in @($Alice, $Group)) {
            (ConvertTo-ServerObjectSecurityReplaySql $Block $Item) | Should -Match 'FROM WINDOWS'
            $Block.Metadata.Name | Should -Match '^DOMAIN\\'
        }
        Test-Path (Split-Path -Parent $Root) | Should -BeFalse
        Should -Invoke Get-AzContext -Times 0
        Should -Invoke Get-AzADUser -Times 0
        Should -Invoke Get-AzADGroup -Times 0
    }
    It 'Resolves users and groups, pins IDs for replay and preserves raw identity metadata' {
        Mock Get-AzADUser { [pscustomobject]@{ UserPrincipalName = 'alice@cloud.example'; Id = '11111111-1111-1111-1111-111111111111' } }
        Mock Get-AzADGroup { [pscustomobject]@{ DisplayName = 'DOMAIN\Team'; Id = '22222222-2222-2222-2222-222222222222' } }
        $Before = @($Alice, $Group) | ConvertTo-Json -Depth 10
        $Result = Export-ServerObjectMissingEntraIdentities $Item @($Alice, $Group) $Root
        $Result.Status | Should -Be SUCCESS
        @(Import-Csv $Result.OutputFile).Count | Should -Be 0
        (ConvertTo-ServerObjectSecurityReplaySql $Alice $Item) | Should -Match "alice@cloud.example.*FROM EXTERNAL PROVIDER WITH OBJECT_ID = '11111111-1111-1111-1111-111111111111'"
        (ConvertTo-ServerObjectSecurityReplaySql $Group $Item) | Should -Match 'DOMAIN\\Team.*FROM EXTERNAL PROVIDER'
        (@($Alice, $Group) | ConvertTo-Json -Depth 10) | Should -BeExactly $Before
        Should -Invoke Get-AzADUser -Times 1 -Exactly
        Should -Invoke Get-AzADGroup -Times 1 -Exactly -ParameterFilter { $DisplayName -eq 'DOMAIN\Team' }
    }
    It 'Collects all failures, deduplicates identities and preserves dependency contexts and error categories' {
        $User = New-IdentityBlock 'alias' U DatabaseUser AppDb
        $User.Metadata | Add-Member NoteProperty LoginName 'DOMAIN\alice'
        $User.Metadata | Add-Member NoteProperty LoginType U
        $Job = New-IdentityBlock 'user-job' G Job
        $Job.Component = 'SQLAgentJobs'
        $Job.Metadata = @{ Owner = 'DOMAIN\Team'; OwnerType = 'G' }
        $Denied = New-IdentityBlock 'DOMAIN\denied'
        Mock Get-AzADUser { throw 'directory authorization denied' } -ParameterFilter { $UserPrincipalName -eq 'denied@cloud.example' }
        Mock Get-AzADGroup {
            [pscustomobject]@{ DisplayName = 'DOMAIN\Team'; Id = '11111111-1111-1111-1111-111111111111' }
            [pscustomobject]@{ DisplayName = 'DOMAIN\Team'; Id = '22222222-2222-2222-2222-222222222222' }
        }
        $Result = Export-ServerObjectMissingEntraIdentities $Item @($Alice, $User, $Group, $Job, $Denied) $Root
        $Rows = @(Import-Csv $Result.OutputFile)
        $Rows.Count | Should -Be 3
        $Result.Status | Should -Be FAILED
        @($Rows.FailureReason | Sort-Object) | Should -Be @('Ambiguous', 'DirectoryAccessError', 'NotFound')
        $Missing = $Rows | Where-Object SourceIdentity -eq 'DOMAIN\alice'
        $Missing.DependencyContexts | Should -Match 'AppDb/DatabaseUser/alias'
        $Missing.DependencyContexts | Should -Match 'SQLLogins//Login/DOMAIN\\alice'
        $Missing.AttemptedMapping | Should -Be 'alice@cloud.example'
        ($Rows | Where-Object SourceIdentity -eq 'DOMAIN\Team').Components | Should -Match 'SQLAgentJobs'
        $Rows[0].PSObject.Properties.Name | Should -Be @('SourceIdentity', 'PrincipalType', 'Components', 'DependencyContexts', 'AttemptedMapping', 'FailureReason', 'ErrorMessage')
        Should -Invoke Get-AzADUser -Times 2 -Exactly
        Should -Invoke Get-AzADGroup -Times 1 -Exactly
        { ConvertTo-ServerObjectSecurityReplaySql $Alice $Item } | Should -Throw '*resolved to 0*'
        Should -Invoke Get-AzADUser -Times 2 -Exactly
    }
    It 'Does not invent a tenant suffix' {
        $Item.JobOwnerUpnSuffix = ''
        $Result = Export-ServerObjectMissingEntraIdentities $Item @($Alice) $Root
        (Import-Csv $Result.OutputFile).FailureReason | Should -Be ExplicitMappingRequired
        Should -Invoke Get-AzADUser -Times 0
    }
    It 'Requires explicit mappings for local users even when a suffix was supplied' {
        $Local = New-IdentityBlock 'SOURCE\alice'
        $Local.Metadata | Add-Member NoteProperty IsLocalWindowsPrincipal $true
        $Result = Export-ServerObjectMissingEntraIdentities $Item @($Local) $Root
        (Import-Csv $Result.OutputFile).FailureReason | Should -Be ExplicitMappingRequired
        Should -Invoke Get-AzADUser -Times 0
        $Item.EntraIdentityMappings['SOURCE\alice'] = 'reviewed@cloud.example'
        Mock Get-AzADUser { [pscustomobject]@{ UserPrincipalName = 'reviewed@cloud.example'; Id = '11111111-1111-1111-1111-111111111111' } }
        $Result = Export-ServerObjectMissingEntraIdentities $Item @($Local) $Root
        $Result.Status | Should -Be SUCCESS
        Should -Invoke Get-AzADUser -Times 1 -Exactly -ParameterFilter { $UserPrincipalName -eq 'reviewed@cloud.example' }
    }
    It 'Uses exact reviewed group mappings rather than stripping the Windows domain' {
        $Item.EntraIdentityMappings['DOMAIN\Team'] = 'Reviewed Team'
        Mock Get-AzADGroup { [pscustomobject]@{ DisplayName = 'Reviewed Team'; Id = '22222222-2222-2222-2222-222222222222' } }
        (Export-ServerObjectMissingEntraIdentities $Item @($Group) $Root).Status | Should -Be SUCCESS
        Should -Invoke Get-AzADGroup -Times 1 -Exactly -ParameterFilter { $DisplayName -eq 'Reviewed Team' }
    }
    It 'Distinguishes directory context failures from missing identities and continues through all identities' {
        Mock Get-AzContext { throw 'network unavailable' }
        $Result = Export-ServerObjectMissingEntraIdentities $Item @($Alice, $Group) $Root
        $Rows = @(Import-Csv $Result.OutputFile)
        $Rows.Count | Should -Be 2
        @($Rows.FailureReason | Sort-Object -Unique) | Should -Be @('DirectoryAccessError')
        Should -Invoke Get-AzADUser -Times 0
        Should -Invoke Get-AzADGroup -Times 0
    }
    It 'Rejects directory responses without a valid object ID' {
        Mock Get-AzADUser { [pscustomobject]@{ UserPrincipalName = 'alice@cloud.example'; Id = '' } }
        $Result = Export-ServerObjectMissingEntraIdentities $Item @($Alice) $Root
        (Import-Csv $Result.OutputFile).FailureReason | Should -Be InvalidDirectoryResponse
    }
    It 'Reports unknown legacy Windows job owner types instead of assuming they are users' {
        $Job = New-IdentityBlock 'user-job' U Job
        $Job.Component = 'SQLAgentJobs'; $Job.Metadata = @{ Owner = 'DOMAIN\unknown' }
        $Result = Export-ServerObjectMissingEntraIdentities $Item @($Job) $Root
        (Import-Csv $Result.OutputFile).FailureReason | Should -Be ExplicitMappingRequired
        Should -Invoke Get-AzADUser -Times 0
    }
    It 'Fails every affected replay component before target access and reports all missing dependencies' {
        $Item.Activity = 'Execute'
        $Job = New-IdentityBlock 'user-job' G Job
        $Job.Component = 'SQLAgentJobs'; $Job.Metadata = @{ Owner = 'DOMAIN\Team'; OwnerType = 'G' }
        Write-ServerObjectSnapshotSql (Join-Path $Root 'SQLLogins\SQLLogins_All.sql') @($Alice)
        Write-ServerObjectSnapshotSql (Join-Path $Root 'SQLAgentJobs\SQLAgentJobs_All.sql') @($Job)
        $Results = @(Invoke-ServerObjectSnapshotReplay $Item $Root)
        @($Results | Where-Object Status -eq FAILED).Count | Should -Be 3
        @($Results | Where-Object Status -eq SUCCESS).Count | Should -Be 0
        $Report = $Results | Where-Object Component -eq EntraIdentityMapping
        @(Import-Csv $Report.OutputFile).Count | Should -Be 2
        $Report.OutputFile | Should -Match 'MissingEntraIdentities.Replay.csv$'
        Should -Invoke Assert-ServerObjectReplayTarget -Times 0
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0
    }
    It 'Does not write reports during preview' {
        $Result = Export-ServerObjectMissingEntraIdentities $Item @($Alice) $Root -Replay -Preview
        $Result.Status | Should -Be FAILED
        Test-Path (Split-Path -Parent $Root) | Should -BeFalse
    }
    It 'Runs the report after MI Generate without changing raw snapshots or contacting target SQL' {
        Mock Import-Module {}
        Mock Get-ServerObjectSecuritySnapshotBlocks { $Alice }
        Mock Get-ServerObjectJobSnapshotBlocks {}
        Mock Get-ServerObjectAgentSnapshotBlocks {}
        Mock Invoke-SqlcmdLogged { [pscustomobject]@{ name = 'AppDb' } }
        Mock Generate-SQLDBMail { @{ ItemCount = 0 } }
        $Results = @(New-ServerObjectSourceSnapshot $Item $Root)
        @($Results | Where-Object Mode -eq Generate | Where-Object Component -ne EntraIdentityMapping).Count | Should -Be 7
        $Report = $Results | Where-Object Component -eq EntraIdentityMapping
        $Report.Status | Should -Be FAILED
        $Report.OutputFile | Should -Be (Join-Path (Split-Path -Parent $Root) 'MissingEntraIdentities.csv')
        foreach ($Level in @('Server', 'All')) {
            $Captured = @(Read-ServerObjectSnapshotSql (Join-Path $Root "SQLLogins\SQLLogins_$Level.sql") |
                Where-Object Kind -eq Login)
            $Captured[0].Metadata.Name | Should -Be 'DOMAIN\alice'
            $Captured[0].Sql | Should -Be '-- raw source'
        }
        Should -Invoke Assert-ServerObjectReplayTarget -Times 0
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0
    }
    It 'Keeps report paths in item failure results even if publication fails after generation' {
        $Item.Id = Split-Path -Leaf (Split-Path -Parent $Root)
        Mock New-ServerObjectItemPlan {
            [pscustomobject]@{ Root = (Split-Path -Parent $Root); SourceRoot = $Root; ProvisionRoot = '' }
        }
        Mock Invoke-ServerObjectWorker {
            Export-ServerObjectMissingEntraIdentities $Item @($Alice) $Root
        }
        Mock Publish-ServerObjectBlobSnapshot { throw 'storage denied' }
        Mock Write-Host {}
        $Result = Invoke-ServerObjectItem -Item $Item -ScriptsPath $TestDrive -RunRoot $TestDrive -RunId test
        $Result.Status | Should -Be FAILED
        $Result.Components[0].OutputFile | Should -Match 'MissingEntraIdentities.csv$'
        $Result.IdentityReports | Should -Contain $Result.Components[0].OutputFile
        $Result.ErrorMessage | Should -Match 'storage denied'
    }
}
