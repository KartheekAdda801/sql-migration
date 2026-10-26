#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    Import-Module Az.Storage -ErrorAction Stop
    if (-not ('SnapshotTestStorageException' -as [type])) {
        Add-Type -TypeDefinition @'
public sealed class SnapshotTestStorageException : System.Exception {
    public string ErrorCode { get; }
    public SnapshotTestStorageException(string message, string errorCode) : base(message) { ErrorCode = errorCode; }
}
'@
    }
    $Scripts = Join-Path $PSScriptRoot '..\scripts'
    . (Join-Path $Scripts 'Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1')
    function New-SnapshotTestBlock {
        param([string]$Component = 'SQLAgentJobs', [string]$Name = 'job', [bool]$Safe = $true,
            [bool]$Enabled = $true, [string[]]$Databases = @())
        [pscustomobject]@{ Component = $Component; Kind = 'Test'; Name = $Name; Database = ''
            ServerSafe = $Safe; SourceEnabled = $Enabled; DependsOnDatabases = $Databases
            Sql = "SELECT N'$Name';"; Metadata = @{} }
    }
    function New-SnapshotTestItem {
        $Item = @(Read-ServerObjectItems -Path (Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json'))[0]
        $Item.SourceListofDatabases = 'AppDb'
        $Item
    }
}

Describe 'Source snapshot SQL framing' {
    It 'Round trips SQL with embedded marker text without treating SQL strings as metadata' {
        $Block = New-SnapshotTestBlock
        $Block.Sql = "SELECT N'first`r`n-- SQLMIGRATION-BLOCK ZmFrZQ==`r`nlast';"
        $Path = Join-Path $TestDrive 'framed.sql'
        Write-ServerObjectSnapshotSql -Path $Path -Blocks @($Block)
        $Read = @(Read-ServerObjectSnapshotSql -Path $Path)
        $Read | Should -HaveCount 1
        $Read[0].Sql | Should -BeExactly $Block.Sql
        $Read[0].SourceEnabled | Should -BeTrue
    }
    It 'Writes a valid no-op file for an empty component' {
        $Path = Join-Path $TestDrive 'empty.sql'
        Write-ServerObjectSnapshotSql -Path $Path
        @(Read-ServerObjectSnapshotSql -Path $Path) | Should -HaveCount 0
    }
    It 'Rejects truncated SQL before returning any executable block' {
        $Path = Join-Path $TestDrive 'truncated.sql'
        Write-ServerObjectSnapshotSql -Path $Path -Blocks @(New-SnapshotTestBlock)
        $Text = [IO.File]::ReadAllText($Path)
        { Read-ServerObjectSnapshotSql -Text $Text.Substring(0, $Text.Length - 4) } | Should -Throw
    }
}

Describe 'Source alert dependency metadata' {
    It 'Treats SQL DBNull as no job/database dependency for ordinary server alerts' {
        Mock Invoke-SqlcmdLogged { @() }
        Mock Invoke-SqlcmdLogged {
            [pscustomobject]@{ name = 'server alert'; enabled = 1; JobName = [DBNull]::Value
                database_name = [DBNull]::Value; CategoryName = [DBNull]::Value }
        } -ParameterFilter { $Context -eq 'Extract all alerts' }
        $Blocks = @(Get-ServerObjectAgentSnapshotBlocks -Server source)
        $Blocks | Should -HaveCount 1
        $Blocks[0].ServerSafe | Should -BeTrue
        $Blocks[0].DependsOnDatabases | Should -HaveCount 0
        $Blocks[0].Sql | Should -Not -Match '@TargetJob'
    }
    It 'Captures user-database and job bindings instead of treating them as server-only' {
        Mock Invoke-SqlcmdLogged { @() }
        Mock Invoke-SqlcmdLogged {
            [pscustomobject]@{ name = 'dependent alert'; enabled = 1; JobName = 'daily job'
                database_name = 'AppDb'; CategoryName = 'Uncategorized' }
        } -ParameterFilter { $Context -eq 'Extract all alerts' }
        $Block = @(Get-ServerObjectAgentSnapshotBlocks -Server source)[0]
        $Block.ServerSafe | Should -BeFalse
        $Block.DependsOnDatabases | Should -Be @('AppDb')
        $Block.Sql | Should -Match '@TargetJob'
    }
}

Describe 'Complete source extraction' {
    BeforeEach {
        $Item = New-SnapshotTestItem
        $Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($Component in @('SQLLogins', 'SQLAgentJobs', 'SQLAlerts', 'SQLOperators', 'SQLDBMail')) {
            $Item."${Component}MigrationFlag" = 'No'
        }
        $Item.SQLLoginsMigrationScope = 'Server'
        $Item.SQLAgentJobsMigrationScope = 'Server'
        $Item.SQLAgentJobFilterCriteria = 'never-match'
        Mock Import-Module {}
        Mock Get-ServerObjectSecuritySnapshotBlocks { New-SnapshotTestBlock -Component SQLLogins -Name login }
        Mock Get-ServerObjectJobSnapshotBlocks {
            New-SnapshotTestBlock -Name enabled-server
            New-SnapshotTestBlock -Name disabled-server -Enabled $false
            New-SnapshotTestBlock -Name db-job -Safe $false -Databases @('OtherDb')
        }
        Mock Get-ServerObjectAgentSnapshotBlocks {}
        Mock Invoke-SqlcmdLogged { [pscustomobject]@{ name = 'AppDb' }; [pscustomobject]@{ name = 'OtherDb' } }
        Mock Generate-SQLDBMail { @{ ItemCount = 0 } }
        Mock Write-Log {}
    }
    It 'Extracts every component despite all execution flags being No, with seven exact flat paths' {
        $null = New-ServerObjectSourceSnapshot -Item $Item -Root $Root
        @(Get-ChildItem $Root -Recurse -File).Count | Should -Be 7
        foreach ($Relative in @(Get-ServerObjectSnapshotPaths)) {
            Test-Path (Join-Path $Root $Relative.Replace('/', '\')) | Should -BeTrue
        }
        Should -Invoke Get-ServerObjectSecuritySnapshotBlocks -Times 1 -Exactly
        Should -Invoke Get-ServerObjectJobSnapshotBlocks -Times 1 -Exactly
        Should -Invoke Get-ServerObjectAgentSnapshotBlocks -Times 1 -Exactly
        Should -Invoke Generate-SQLDBMail -Times 1 -Exactly -ParameterFilter { $PreserveSourceSettings -and $Unfiltered }
    }
    It 'Keeps disabled jobs and every database in All while Server contains only safe jobs' {
        $null = New-ServerObjectSourceSnapshot -Item $Item -Root $Root
        $All = @(Read-ServerObjectSnapshotSql -Path (Join-Path $Root 'SQLAgentJobs\SQLAgentJobs_All.sql'))
        $All.Name | Should -Be @('enabled-server', 'disabled-server', 'db-job')
        $All[1].SourceEnabled | Should -BeFalse
        @(Read-ServerObjectSnapshotSql -Path (Join-Path $Root 'SQLAgentJobs\SQLAgentJobs_Server.sql')).Name |
            Should -Be @('enabled-server', 'disabled-server')
        $Inventory = @(Read-ServerObjectSnapshotSql -Path (Join-Path $Root 'SQLLogins\SQLLogins_All.sql') | Where-Object Kind -eq Inventory)
        $Inventory[0].Metadata.Databases | Should -Be @('AppDb', 'OtherDb')
    }
    It 'Fails extraction rather than publishing a partially successful source snapshot' {
        Mock Get-ServerObjectSecuritySnapshotBlocks { throw 'Source permission denied' }
        { New-ServerObjectSourceSnapshot -Item $Item -Root $Root } | Should -Throw '*Source permission denied*'
        Should -Invoke Generate-SQLDBMail -Times 0 -Exactly
    }
}

Describe 'Source-free execution selection and preflight' {
    BeforeEach {
        $Item = New-SnapshotTestItem
        $Item.SQLLoginsMigrationFlag = 'No'
        $Item.SQLOperatorsMigrationFlag = 'No'
        $Item.SQLAlertsMigrationFlag = 'No'
        $Item.SQLDBMailMigrationFlag = 'No'
        $Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $Blocks = @(
            (New-SnapshotTestBlock -Name server),
            (New-SnapshotTestBlock -Name disabled -Enabled $false),
            (New-SnapshotTestBlock -Name app -Safe $false -Databases @('AppDb')),
            (New-SnapshotTestBlock -Name other -Safe $false -Databases @('OtherDb'))
        )
        Write-ServerObjectSnapshotSql -Path (Join-Path $Root 'SQLAgentJobs\SQLAgentJobs_All.sql') -Blocks $Blocks
        Write-ServerObjectSnapshotSql -Path (Join-Path $Root 'SQLAgentJobs\SQLAgentJobs_Server.sql') -Blocks @($Blocks[0], $Blocks[1])
        Mock Write-Log {}
        Mock Assert-ServerObjectSqlAccess {}
        Mock Invoke-ServerObjectPreflightQuery { [pscustomobject]@{ state_desc = 'ONLINE' } }
        Mock Get-ServerObjectSecuritySnapshotBlocks { throw 'Must not contact source' }
        Mock Get-ServerObjectJobSnapshotBlocks { throw 'Must not contact source' }
    }
    It 'Executes only source-enabled jobs within the current selected database scope' {
        @(Get-ServerObjectReplayBlocks -Item $Item -Root $Root).Name | Should -Be @('server', 'app')
        $Item.SQLAgentJobFilterCriteria = '^app$'
        @(Get-ServerObjectReplayBlocks -Item $Item -Root $Root).Name | Should -Be @('app')
    }
    It 'Uses the Server job file without checking absent user databases' {
        $Item.SQLAgentJobsMigrationScope = 'Server'
        @(Get-ServerObjectReplayBlocks -Item $Item -Root $Root).Name | Should -Be @('server')
        Assert-ServerObjectReplayTarget -Item $Item -Root $Root
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0 -Exactly
    }
    It 'Requires restored ONLINE databases for All execution without contacting source' {
        Assert-ServerObjectReplayTarget -Item $Item -Root $Root
        Should -Invoke Invoke-ServerObjectPreflightQuery -Times 1 -Exactly -ParameterFilter { $Server -eq 'vm.example,1433' -and $Query -match 'AppDb' }
        Should -Invoke Get-ServerObjectSecuritySnapshotBlocks -Times 0 -Exactly
        Mock Invoke-ServerObjectPreflightQuery { [pscustomobject]@{ state_desc = 'RESTORING' } }
        { Assert-ServerObjectReplayTarget -Item $Item -Root $Root } | Should -Throw '*restored and ONLINE*'
    }
    It 'Rejects unsafe blocks if a Server snapshot is inconsistent' {
        $Item.SQLAgentJobsMigrationScope = 'Server'
        Write-ServerObjectSnapshotSql -Path (Join-Path $Root 'SQLAgentJobs\SQLAgentJobs_Server.sql') -Blocks @($Blocks[2])
        { Get-ServerObjectReplayBlocks -Item $Item -Root $Root } | Should -Throw '*Unsafe object*'
    }
    It 'Keeps legacy DBA-ENABLED name selection at execution time only' {
        $Item.SQLAgentJobFilterCriteria = 'DBA-ENABLED'
        $Job = New-SnapshotTestBlock -Name 'DBA maintenance'
        Write-ServerObjectSnapshotSql -Path (Join-Path $Root 'SQLAgentJobs\SQLAgentJobs_All.sql') -Blocks @($Job, $Blocks[0])
        @(Get-ServerObjectReplayBlocks -Item $Item -Root $Root).Name | Should -Be @('DBA maintenance')
    }
}

Describe 'Execution-only SMTP override' {
    BeforeEach { $Item = New-SnapshotTestItem; $Item.SmtpServer = 'new-relay'; $Item.SmtpPort = 587 }
    It 'Changes only parsed SMTP procedure parameters, preserving source sender and unrelated literals' {
        $Sql = @'
EXEC msdb.dbo.sysmail_add_account_sp @account_name=N'old-relay',
 @email_address=N'source@example.com', @display_name=N'old-relay',
 @mailserver_name=N'old-relay', @port=25, @use_default_credentials=0;
SELECT N'@mailserver_name=N''old-relay'', @port=25';
'@
        $Result = ConvertTo-ServerObjectMailReplaySql -Sql $Sql -Item $Item
        $Result | Should -Match "@mailserver_name=N'new-relay'"
        $Result | Should -Match '@port=587'
        $Result | Should -Match "@account_name=N'old-relay'"
        $Result | Should -Match "@email_address=N'source@example.com'"
        $Result | Should -Match "@display_name=N'old-relay'"
        $Result | Should -Match "SELECT N'@mailserver_name=N''old-relay'', @port=25'"
    }
    It 'Refuses unsupported MI integrated SMTP authentication instead of commenting out accounts' {
        $Item.TargetType = 'SQLMI'
        { ConvertTo-ServerObjectMailReplaySql -Item $Item -Sql "EXEC msdb.dbo.sysmail_add_account_sp @mailserver_name=N'old', @port=25, @use_default_credentials=1;" } |
            Should -Throw '*Windows Integrated SMTP*'
    }
}

Describe 'Source container ownership and replacement' {
    BeforeEach {
        $Item = New-SnapshotTestItem
        $Client = [pscustomobject]@{ Deleted = 0; Created = 0 }
        $Client | Add-Member ScriptMethod DeleteIfExists { param($Conditions, $Cancellation) $this.Deleted++ }
        $Client | Add-Member ScriptMethod CreateIfNotExists { param($Access, $Metadata, $Cancellation) $this.Created++ }
        Mock Get-ServerObjectBlobNames { @() }
    }
    It 'Recreates an empty managed destination without changing its name' {
        Reset-ServerObjectBlobContainer -Item $Item -Client $Client
        $Client.Deleted | Should -Be 1
        $Client.Created | Should -Be 1
    }
    It 'Refuses any nonempty destination without a matching ownership manifest' {
        Mock Get-ServerObjectBlobNames { 'unrelated.sql' }
        { Reset-ServerObjectBlobContainer -Item $Item -Client $Client } | Should -Throw '*without an ownership manifest*'
        $Client.Deleted | Should -Be 0
    }
    It 'Refuses another source or unrelated blobs without deleting the container' {
        Mock Get-ServerObjectBlobNames { 'manifest.json' }
        Mock Read-ServerObjectBlob {
            return ,([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":4,"kind":"SourceSnapshot","source":"other","targetType":"SQLVM","tenantId":"wrong","subscriptionId":"wrong"}'))
        }
        { Reset-ServerObjectBlobContainer -Item $Item -Client $Client } | Should -Throw '*ownership/source/platform*'
        $Client.Deleted | Should -Be 0
    }
    It 'Recreates a matching managed container but refuses additional unmanaged content' {
        $Owned = @{ schemaVersion = 4; kind = 'SourceSnapshot'; source = $Item.SourceServerName
            targetType = $Item.TargetType; tenantId = $Item.TenantId; subscriptionId = $Item.SubscriptionId } |
            ConvertTo-Json -Compress
        Mock Get-ServerObjectBlobNames { 'manifest.json'; 'SQLLogins/SQLLogins_All.sql' }
        Mock Read-ServerObjectBlob { return ,([Text.Encoding]::UTF8.GetBytes($Owned)) }
        Reset-ServerObjectBlobContainer -Item $Item -Client $Client
        $Client.Deleted | Should -Be 1
        $Client.Created | Should -Be 1
        Mock Get-ServerObjectBlobNames { 'manifest.json'; 'foreign-data.txt' }
        { Reset-ServerObjectBlobContainer -Item $Item -Client $Client } | Should -Throw '*unmanaged blobs*'
        $Client.Deleted | Should -Be 1
    }
    It 'Retries only Azure ContainerBeingDeleted and surfaces every other storage error' {
        $Client | Add-Member ScriptMethod CreateIfNotExists {
            param($Access, $Metadata, $Cancellation)
            $this.Created++
            if ($this.Created -eq 1) { throw [SnapshotTestStorageException]::new('Container deletion is propagating.', 'ContainerBeingDeleted') }
        } -Force
        Mock Start-Sleep {}
        Reset-ServerObjectBlobContainer -Item $Item -Client $Client
        $Client.Created | Should -Be 2
        Should -Invoke Start-Sleep -Times 1 -Exactly
        $Client | Add-Member ScriptMethod CreateIfNotExists {
            param($Access, $Metadata, $Cancellation)
            throw [SnapshotTestStorageException]::new('Access denied.', 'AuthorizationPermissionMismatch')
        } -Force
        { Reset-ServerObjectBlobContainer -Item $Item -Client $Client } | Should -Throw '*Access denied*'
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }
    It 'Computes platform suffixes from all items even when only one item is selected' {
        $Path = Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json'
        (Read-ServerObjectItems -Path $Path -ItemId VM-Objects).StorageContainer | Should -Be 'source-instance-sqlobjects-sqlvm'
        (Read-ServerObjectItems -Path $Path -ItemId MI-Objects).StorageContainer | Should -Be 'source-instance-sqlobjects-sqlmi'
        Get-ServerObjectSourceContainerName -Source 'DESKTOP-SGA61QP\DMF' | Should -Be 'desktop-sga61qp-dmf-sqlobjects'
    }
}

Describe 'Source container naming' -Tag 'Unit' {
    It 'Places sqlobjects after the normalized instance and before <Platform>' -ForEach @(
        @{ Platform = 'SQLMI'; Expected = 'desktop-sga61qp-dmf-sqlobjects-sqlmi' },
        @{ Platform = 'SQLVM'; Expected = 'desktop-sga61qp-dmf-sqlobjects-sqlvm' }
    ) {
        Get-ServerObjectSourceContainerName -Source ' DESKTOP-SGA61QP\DMF ' -Platform $Platform |
            Should -BeExactly $Expected
    }

    Describe 'Independent replay validation and execution results' -Tag 'Unit' {
        BeforeEach {
            $Item = New-SnapshotTestItem
            $Item.SQLLoginsMigrationScope = 'Server'
            $Item.SQLAgentJobsMigrationScope = 'Server'
            $Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            foreach ($Component in @('SQLLogins', 'SQLDBMail', 'SQLOperators', 'SQLAgentJobs', 'SQLAlerts')) {
                $Item."${Component}MigrationFlag" = 'Yes'
                $Block = New-SnapshotTestBlock -Component $Component -Name "$Component-good"
                Write-ServerObjectSnapshotSql -Path (Join-Path $Root "$Component\${Component}_Server.sql") -Blocks @($Block)
                if ($Component -in @('SQLLogins', 'SQLAgentJobs')) {
                    Write-ServerObjectSnapshotSql -Path (Join-Path $Root "$Component\${Component}_All.sql") -Blocks @($Block)
                }
            }
            Mock Write-Log {}
            Mock Assert-ServerObjectSqlAccess {}
            Mock Invoke-ServerObjectPreflightQuery {
                if ($Query -match 'state_desc') { [pscustomobject]@{ state_desc = 'ONLINE' } }
                elseif ($Query -match "'bad'") { throw 'Simulated SQL object failure' }
            }
            Mock ConvertTo-ServerObjectSecurityReplaySql { $Block.Sql }
            Mock ConvertTo-ServerObjectJobReplaySql { $Block.Sql }
            Mock ConvertTo-ServerObjectMailReplaySql { $Sql }
        }
        It 'Continues objects within a failed component and subsequent dependent components' {
            $Jobs = @(
                (New-SnapshotTestBlock -Name bad),
                (New-SnapshotTestBlock -Name good)
            )
            Write-ServerObjectSnapshotSql -Path (Join-Path $Root 'SQLAgentJobs\SQLAgentJobs_Server.sql') -Blocks $Jobs
            $Results = @(Invoke-ServerObjectSnapshotReplay -Item $Item -Root $Root)
            $Results | Should -HaveCount 6
            $Jobs = @($Results | Where-Object Component -eq SQLAgentJobs)
            $Jobs.Status | Should -Be @('FAILED', 'SUCCESS')
            $Jobs[0].Phase | Should -Be Execution
            $Jobs[0].ErrorMessage | Should -Match "object='bad'.*target='vm.example,1433'.*Simulated SQL object failure"
            $Jobs[0].OutputFile | Should -BeLike '*SQLAgentJobs_Server.sql'
            ($Results | Where-Object Component -eq SQLAlerts).Status | Should -Be SUCCESS
            Should -Invoke Invoke-ServerObjectPreflightQuery -Times 6 -Exactly -ParameterFilter { $QueryTimeout -eq 0 }
        }
        It 'Records transformation errors as validation failures without blocking later components' {
            Mock ConvertTo-ServerObjectMailReplaySql { throw 'Unsupported SMTP authentication' }
            $Results = @(Invoke-ServerObjectSnapshotReplay -Item $Item -Root $Root)
            $Mail = $Results | Where-Object Component -eq SQLDBMail
            $Mail.Status | Should -Be FAILED
            $Mail.Phase | Should -Be Validation
            $Mail.ErrorMessage | Should -Match 'Unsupported SMTP authentication'
            @($Results | Where-Object Status -eq SUCCESS) | Should -HaveCount 4
        }
        It 'Contains offline-database validation failures to the component requesting All scope' {
            $Item.SQLLoginsMigrationScope = 'All'
            Mock Invoke-ServerObjectPreflightQuery {
                if ($Query -match 'state_desc') { [pscustomobject]@{ state_desc = 'RESTORING' } }
            }
            $Results = @(Invoke-ServerObjectSnapshotReplay -Item $Item -Root $Root)
            $Logins = $Results | Where-Object Component -eq SQLLogins
            $Logins.Status | Should -Be FAILED
            $Logins.Phase | Should -Be Validation
            $Logins.ErrorMessage | Should -Match 'restored and ONLINE'
            @($Results | Where-Object Status -eq SUCCESS) | Should -HaveCount 4
            Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0 -Exactly -ParameterFilter { $Query -match 'SQLLogins-good' }
        }
        It 'Reports each component validation failure without attempting unvalidated SQL' {
            Mock Assert-ServerObjectSqlAccess { throw 'Target access denied' }
            $Results = @(Invoke-ServerObjectSnapshotReplay -Item $Item -Root $Root)
            $Results | Should -HaveCount 5
            @($Results | Where-Object { $_.Status -eq 'FAILED' -and $_.Phase -eq 'Validation' }) | Should -HaveCount 5
            Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0 -Exactly
        }
        It 'Makes disabled and empty components visible as skipped results' {
            $Item.SQLDBMailMigrationFlag = 'No'
            Write-ServerObjectSnapshotSql -Path (Join-Path $Root 'SQLAgentJobs\SQLAgentJobs_Server.sql') -Blocks @()
            $Results = @(Invoke-ServerObjectSnapshotReplay -Item $Item -Root $Root)
            $Skipped = @($Results | Where-Object Status -eq SKIPPED)
            $Skipped | Should -HaveCount 2
            $Skipped.Detail | Should -Contain 'Disabled by configuration.'
            $Skipped.Detail | Should -Contain 'No eligible objects after scope and execution filtering.'
        }
        It 'Validates an in-memory snapshot without writes during preview with inherited WhatIf=<InheritedWhatIf>' -ForEach @(
            @{ InheritedWhatIf = $false }, @{ InheritedWhatIf = $true }
        ) {
            $Files = @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object {
                [pscustomobject]@{ Path = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
                    Bytes = [IO.File]::ReadAllBytes($_.FullName) }
            })
            $PreviewRoot = Join-Path $TestDrive 'preview-no-output'
            $Results = @(& {
                [CmdletBinding(SupportsShouldProcess)]
                param()
                Invoke-ServerObjectSnapshotReplay -Item $Item -Root $PreviewRoot -Snapshot ([pscustomobject]@{ Files = $Files }) -Preview
            } -WhatIf:$InheritedWhatIf)
            $Results.Status | Should -Be @('PreflightPassed', 'PreflightPassed', 'PreflightPassed', 'PreflightPassed', 'PreflightPassed')
            Test-Path -LiteralPath $PreviewRoot | Should -BeFalse
            Should -Invoke Invoke-ServerObjectPreflightQuery -Times 0 -Exactly
        }
        It 'Uses target trust <Trust> independently from source trust on <TargetType>' -ForEach @(
            @{ Trust = $true; TargetType = 'SQLVM' },
            @{ Trust = $false; TargetType = 'SQLMI' }
        ) {
            $Item.TargetType = $TargetType
            $Item.TargetTrustServerCertificate = $Trust
            $Item.SourceTrustServerCertificate = -not $Trust
            $null = Invoke-ServerObjectSnapshotReplay -Item $Item -Root $Root
            Should -Invoke Assert-ServerObjectSqlAccess -Times 5 -Exactly -ParameterFilter { $TrustServerCertificate -eq $Trust }
            Should -Invoke Invoke-ServerObjectPreflightQuery -Times 5 -Exactly -ParameterFilter { $TrustServerCertificate -eq $Trust }
        }
        It 'Forwards SQL credentials to every component validation and replay on <TargetType>' -ForEach @(
            @{ TargetType = 'SQLVM' }, @{ TargetType = 'SQLMI' }
        ) {
            $Item.TargetType = $TargetType
            $Item.TargetSqlAuthType = 'SqlLogin'
            $Credential = [pscredential]::new('offline-admin', (ConvertTo-SecureString 'offline-test-password' -AsPlainText -Force))
            $Results = @(Invoke-ServerObjectSnapshotReplay -Item $Item -Root $Root -SqlCredential $Credential)
            $Results.Status | Should -Be @('SUCCESS', 'SUCCESS', 'SUCCESS', 'SUCCESS', 'SUCCESS')
            Should -Invoke Assert-ServerObjectSqlAccess -Times 5 -Exactly -ParameterFilter {
                $SqlCredential.UserName -eq 'offline-admin' -and -not $TenantId
            }
            Should -Invoke Invoke-ServerObjectPreflightQuery -Times 5 -Exactly -ParameterFilter {
                $SqlCredential.UserName -eq 'offline-admin' -and -not $TenantId
            }
        }
    }
    It 'Normalizes repeated separators and retains a single-character source' {
        Get-ServerObjectSourceContainerName -Source ' --SERVER__INSTANCE-- ' | Should -BeExactly 'server-instance-sqlobjects'
        Get-ServerObjectSourceContainerName -Source 's' | Should -BeExactly 's-sqlobjects'
    }
    It 'Accepts 63 characters and rejects longer or empty normalized source names' {
        (Get-ServerObjectSourceContainerName -Source ('s' * 46) -Platform SQLMI).Length | Should -Be 63
        { Get-ServerObjectSourceContainerName -Source ('s' * 47) -Platform SQLMI } | Should -Throw '*maximum 63 characters*'
        { Get-ServerObjectSourceContainerName -Source ' \__ ' } | Should -Throw
    }
}
