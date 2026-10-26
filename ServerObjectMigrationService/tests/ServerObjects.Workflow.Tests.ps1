#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    $Scripts = Join-Path $PSScriptRoot '..\scripts'
    . (Join-Path $Scripts 'Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1')
    $OperationalConfig = Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json'
    $PSDefaultParameterValues = @{ 'Invoke-ServerObjectWorkflow:ThrottleLimit' = 1 }
    $SqlCredential = $null
    function New-TestConfiguration {
        param($Change)
        $Json = Get-Content -LiteralPath $OperationalConfig -Raw | ConvertFrom-Json -AsHashtable
        & $Change $Json
        $Path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        $Json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
        $Path
    }
}

Describe 'Server-object script layout' -Tag 'Unit' {
    It 'Loads <Name> from scripts rather than Common without running its work body' -ForEach @(
        @{ Name = 'Invoke-MigrateServerObjects-OnPrem-AzSQLMI.ps1' },
        @{ Name = 'Invoke-MigrateServerObjects-OnPrem-AzSQLVM.ps1' },
        @{ Name = 'Invoke-ProvisionLogins-AzSql.ps1' }
    ) {
        $Entry = Join-Path $Scripts $Name
        Test-Path -LiteralPath $Entry -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Scripts "Common\$Name") | Should -BeFalse
        { & { . $Entry -ConfigPath 'not-read-when-dot-sourced.json' } } | Should -Not -Throw
    }
}

Describe 'Reviewed Entra identity mapping configuration' -Tag 'Unit' {
    It 'Preserves exact reviewed source-to-target mappings without modifying provisioning definitions' {
        $Path = New-TestConfiguration {
            param($Json)
            $Json.Items[0].EntraIdentityMappings = @{ 'SOURCE\local' = 'reviewed@cloud.example'; 'DOMAIN\Team' = 'Reviewed Team' }
        }
        $Items = @(Read-ServerObjectItems -Path $Path)
        $Items[0].EntraIdentityMappings['SOURCE\local'] | Should -Be 'reviewed@cloud.example'
        $Items[0].EntraIdentityMappings['DOMAIN\Team'] | Should -Be 'Reviewed Team'
    }
    It 'Rejects invalid mapping shape <Value>' -ForEach @(
        @{ Value = @('not-an-object') }, @{ Value = @{ 'SOURCE\local' = 42 } }, @{ Value = @{ 'SOURCE\local' = '' } }
    ) {
        $Path = New-TestConfiguration { param($Json) $Json.Items[0].EntraIdentityMappings = $Value }
        { Read-ServerObjectItems -Path $Path } | Should -Throw '*EntraIdentityMappings*'
    }
}

Describe 'WhatIf item selection and preflight diagnostics' -Tag 'Unit' {
    BeforeAll {
        $PreviewConfiguration = Join-Path $TestDrive 'preview.config.json'
        @{
            schemaVersion = 2
            Common = @{
                TenantId = 'b7d7daca-8689-49f9-8a9b-d20adf81c78b'
                SubscriptionId = 'cd7743ef-8ddc-4254-b715-2c79c8ab4126'
                StorageAccountName = 'teststorage'; StorageResourceGroup = 'test-rg'
            }
            Items = @(@{
                Id = 'VM-Objects'; Enabled = $true; TargetType = 'SQLVM'; TargetName = 'target-vm'
                TargetSqlHost = 'target.example'; TargetSqlPort = 1433
                SourceServerName = 'source\instance'; SourceListofDatabases = 'AppDb'
                StorageContainer = 'test-objects'; ProvisionLogins = $true
                Logins = @(@{ Name = 'user@example.com'; Type = 'EntraUser'; AccessType = @('db_datareader') })
            })
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $PreviewConfiguration
    }
    BeforeEach {
        Mock Assert-ServiceOutputPath {}
        Mock Get-ServerObjectStorage {}
        Mock Import-Module {}
        Mock Assert-ServerObjectSqlAccess {}
        Mock Assert-ServerObjectReplayTarget {}
        Mock Invoke-ServerObjectSnapshotReplay { [pscustomobject]@{ Component = 'SQLOperators'; Status = 'PreflightPassed' } }
        Mock Invoke-ServerObjectWorker {}
        Mock Invoke-ServerObjectProvisioning {}
        Mock Publish-ServerObjectBlobSnapshot {}
        Mock Write-Host {}
    }
    It 'Selects a valid item under inherited WhatIf for <Activity>' -ForEach @(
        @{ Activity = 'ProvisionLogins' }, @{ Activity = 'Generate' }, @{ Activity = 'Execute' }
    ) {
        $Item = & {
            [CmdletBinding(SupportsShouldProcess)]
            param()
            Set-StrictMode -Version Latest
            Read-ServerObjectItems -Path $PreviewConfiguration -ItemId VM-Objects -Activity $Activity
        } -WhatIf
        $Item.Id | Should -Be VM-Objects
        $Item.Activity | Should -Be $Activity
    }
    It 'Still rejects genuinely unknown item IDs under inherited WhatIf' {
        {
            & {
                [CmdletBinding(SupportsShouldProcess)]
                param()
                Read-ServerObjectItems -Path $PreviewConfiguration -ItemId Missing
            } -WhatIf
        } | Should -Throw "*ItemId 'Missing' is unknown or disabled*"
    }
    It 'Preserves snapshot paths and empty-file checks under inherited WhatIf' {
        $Items = @(Read-ServerObjectItems -Path $PreviewConfiguration -ItemId VM-Objects -Activity Execute)
        Mock Read-ServerObjectBlobSnapshot {
            [pscustomobject]@{ Files = @(
                [pscustomobject]@{ Path = 'source/a.sql'; Bytes = [byte[]]@(1) },
                [pscustomobject]@{ Path = 'source/empty.sql'; Bytes = [byte[]]@() }
            ) }
        }
        Mock Invoke-ServerObjectPreflight {
            if ($Operation -like '*SQLVM') {
                $Options.BlobFiles | Should -Be @('source/a.sql', 'source/empty.sql')
                $Options.BlobEmptyFiles | Should -Be @('source/empty.sql')
            }
        }
        $Results = @(& {
            [CmdletBinding(SupportsShouldProcess)]
            param()
            Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot (Join-Path $TestDrive 'no-output') -Preview
        } -WhatIf)
        $Results[0].Status | Should -Be PreflightPassed
        Should -Invoke Invoke-ServerObjectSnapshotReplay -Times 1 -Exactly -ParameterFilter {
            $Preview -and $Snapshot.Files.Count -eq 2
        }
        Should -Invoke Invoke-ServerObjectWorker -Times 0 -Exactly
        Should -Invoke Invoke-ServerObjectProvisioning -Times 0 -Exactly
        Should -Invoke Publish-ServerObjectBlobSnapshot -Times 0 -Exactly
    }
    It 'Records provisioning validation details without terminating the item plan' {
        $Items = @(Read-ServerObjectItems -Path $PreviewConfiguration -ItemId VM-Objects -Activity ProvisionLogins)
        Mock Invoke-ServerObjectPreflight { throw [TimeoutException]::new('Original network timeout') }
        $Plan = New-ServerObjectItemPlan -Item $Items[0] -ScriptsPath $Scripts -RunRoot $TestDrive
        $Failure = $Plan.ProvisioningError
        $Failure.Component | Should -Be ProvisionLogins
        $Failure.Phase | Should -Be Validation
        $Failure.Status | Should -Be FAILED
        $Failure.ErrorMessage | Should -Match "item='VM-Objects'"
        $Failure.ErrorMessage | Should -Match "target='target.example,1433'"
        $Failure.ErrorMessage | Should -Match "databases='AppDb'"
        $Failure.ErrorMessage | Should -Match 'Original network timeout'
        $Failure.ErrorMessage | Should -Not -Match 'SecretName|AccessToken|user@example.com'
        Should -Invoke Invoke-ServerObjectProvisioning -Times 0 -Exactly
    }
}

Describe 'Consolidated server-object configuration' -Tag 'Unit' {
    It 'Defaults target certificate validation to strict independently of source trust' {
        foreach ($Item in @(Read-ServerObjectItems -Path $OperationalConfig)) {
            $Item.TargetTrustServerCertificate | Should -BeFalse
            (ConvertTo-ServerObjectLegacyItem -Item $Item).TargetTrustServerCertificate | Should -BeFalse
        }
    }
    It 'Inherits target trust while preserving an explicit strict item override' {
        $Path = New-TestConfiguration {
            param($J)
            $J.Common.TargetTrustServerCertificate = $true
            $J.Items[1].TargetTrustServerCertificate = $false
        }
        $Items = @(Read-ServerObjectItems -Path $Path)
        $Items[0].TargetTrustServerCertificate | Should -BeTrue
        $Items[1].TargetTrustServerCertificate | Should -BeFalse
        $Items[0].SourceTrustServerCertificate | Should -BeFalse
    }
    It 'Defaults source certificate validation to strict and transfers the policy to worker rows' {
        foreach ($Item in @(Read-ServerObjectItems -Path $OperationalConfig)) {
            $Item.SourceTrustServerCertificate | Should -BeFalse
            (ConvertTo-ServerObjectLegacyItem -Item $Item).SourceTrustServerCertificate | Should -BeFalse
        }
    }
    It 'Inherits source trust from Common but preserves an explicit false item override' {
        $Path = New-TestConfiguration {
            param($J)
            $J.Common.SourceTrustServerCertificate = $true
            $J.Items[0].SourceTrustServerCertificate = $false
        }
        $Items = @(Read-ServerObjectItems -Path $Path)
        $Items[0].SourceTrustServerCertificate | Should -BeFalse
        $Items[1].SourceTrustServerCertificate | Should -BeTrue
        (ConvertTo-ServerObjectLegacyItem -Item $Items[1]).SourceTrustServerCertificate | Should -BeTrue
    }
    It 'Configures both targets and both databases, with generate-first and no target mutation flags' {
        $Json = Get-Content -LiteralPath $OperationalConfig -Raw | ConvertFrom-Json -AsHashtable
        $Json.Common.KeyVaultName | Should -Be ak-personal-kv
        $Json.Common.Enabled | Should -BeTrue
        $Json.Common.StorageAccountName | Should -Be akpersonalsa
        $Json.Items[0].Contains('TenantId') | Should -BeFalse
        $Json.Items[0].Contains('DomainPrefix') | Should -BeFalse
        $Json.Items[0].Contains('ManagedIdentityName') | Should -BeFalse
        $Items = @(Read-ServerObjectItems -Path $OperationalConfig)
        $Items.Id | Should -Be @('VM-Objects', 'MI-Objects')
        foreach ($Item in $Items) {
            $Item.Activity | Should -Be Generate
            $Item.SourceListofDatabases | Should -Be 'MIGRDEMO,CDC_Director_PRO'
            $Item.KeyVaultName | Should -Be ak-personal-kv
            $Item.ProvisionLogins | Should -BeFalse
            $ConfiguredItem = $Json.Items | Where-Object Id -eq $Item.Id
            $Item.Logins.Name | Should -Be @($ConfiguredItem.Logins.Name)
            $Item.Logins[0].SecretName | Should -Be sql-dbmigration-pwd
            $Item.Logins[1].AccessType | Should -Be @('db_datawriter')
            $Item.Logins[0].ForcePasswordReset | Should -BeFalse
            $Item.SQLDBMailMigrationFlag | Should -Be No
            foreach ($Name in @('SQLLoginsMigrationFlag', 'SQLAgentJobsMigrationFlag', 'SQLOperatorsMigrationFlag', 'SQLAlertsMigrationFlag')) {
                $Item.$Name | Should -Be Yes
            }
            $Legacy = ConvertTo-ServerObjectLegacyItem -Item $Item
            $Legacy.TargetExecutionFlag | Should -Be No
            $Legacy.OnlyTargetExecutionFlag | Should -Be No
        }
        $Items[0].SQLLoginsMigrationScope | Should -Be All
        $Items[1].SQLLoginsMigrationScope | Should -Be All
    }
    It 'Inherits empty/null item properties and honors explicit false' {
        $Path = New-TestConfiguration {
            param($Json)
            $Json.Common.Activity = 'Generate'
            $Json.Common.Application = 'MigrationDemo'
            $Json.Items[0].Activity = ''
            $Json.Items[0].Application = $null
            $Json.Items[0].CreateContainerIfMissing = $false
            $Json.Items[1].Logins[0].AccessType = @('db_datawriter', 'EXECUTE')
        }
        $Items = @(Read-ServerObjectItems -Path $Path)
        $Items[0].Activity | Should -Be Generate
        $Items[0].Application | Should -Be MigrationDemo
        $Items[0].CreateContainerIfMissing | Should -BeFalse
        $Items[1].CreateContainerIfMissing | Should -BeTrue
        $Items[1].Logins[0].AccessType | Should -Be @('db_datawriter', 'EXECUTE')
        $Items[0].Logins[0].AccessType | Should -Be @('db_datareader')
    }
    It 'Keeps source servers and database scopes independent between items with shared Common' {
        $Path = New-TestConfiguration {
            param($Json)
            $Json.Items[0].SourceServerName = 'different-source'
            $Json.Items[0].SourceListofDatabases = 'different-database'
            $Json.Items[0].Logins = @()
        }
        $Items = @(Read-ServerObjectItems -Path $Path)
        $Items[0].SourceServerName | Should -Be different-source
        $Items[0].SourceListofDatabases | Should -Be different-database
        $Items[1].SourceServerName | Should -Be 'source\instance'
        $Items[1].SourceListofDatabases | Should -Be 'MIGRDEMO,CDC_Director_PRO'
    }
    It 'Supports omitted Common when each item supplies all required settings' {
            $Path = New-TestConfiguration {
                param($Json)
                foreach ($Item in $Json.Items) {
                    foreach ($Key in $Json.Common.Keys) {
                        if (-not $Item.Contains($Key)) { $Item[$Key] = $Json.Common[$Key] }
                    }
                }
                $Json.Remove('Common')
            }
            @(Read-ServerObjectItems -Path $Path).Count | Should -Be 2
        }
    It 'Inherits shared settings only for omitted, null, or blank item values and preserves false' {
            $Path = New-TestConfiguration {
                param($Json)
                $Json.Common.Activity = 'Execute'
                $Json.Common.SmtpServer = 'common-relay'
                $Json.Common.SmtpPort = '25'
                $Json.Items[0].Activity = ' '
                $Json.Items[0].KeyVaultName = ''
                $Json.Items[0].TenantId = $null
                $Json.Items[0].SmtpServer = 'item-relay'
                $Json.Items[0].SmtpPort = ''
                $Json.Items[0].CreateContainerIfMissing = $false
                $Json.Items[1].KeyVaultName = 'other-vault'
            }
            $Items = @(Read-ServerObjectItems -Path $Path)
            $Items[0].Activity | Should -Be Execute
            $Items[1].Activity | Should -Be Generate
            $Items[0].KeyVaultName | Should -Be ak-personal-kv
            $Items[1].KeyVaultName | Should -Be other-vault
            $Items[0].SmtpServer | Should -Be item-relay
            $Items[0].SmtpPort | Should -Be '25'
            $Items[0].CreateContainerIfMissing | Should -BeFalse
            $Items[0].TenantId | Should -Be 'b7d7daca-8689-49f9-8a9b-d20adf81c78b'
            (Read-ServerObjectItems -Path $Path -ItemId VM-Objects -Activity Generate).Activity | Should -Be Generate
        }
    It 'Inherits Common.Enabled but lets an explicit item true or false override it' {
            $Path = New-TestConfiguration {
                param($Json)
                $Json.Common.Enabled = $false
                $Json.Items[0].Enabled = ''
                $Json.Items[1].Enabled = $true
            }
            @(Read-ServerObjectItems -Path $Path).Id | Should -Be @('MI-Objects')
            $Path = New-TestConfiguration {
                param($Json)
                $Json.Items[0].Enabled = $false
                $Json.Items[1].Enabled = $null
            }
            @(Read-ServerObjectItems -Path $Path).Id | Should -Be @('MI-Objects')
        }
    It 'Selects one target and executes its current snapshot without a run ID' {
        $Item = Read-ServerObjectItems -Path $OperationalConfig -ItemId VM-Objects -Activity Execute
        $Item.Id | Should -Be VM-Objects
        $Item.PSObject.Properties.Name | Should -Not -Contain SnapshotRunId
        (ConvertTo-ServerObjectLegacyItem -Item $Item -Execution).OnlyTargetExecutionFlag | Should -Be Yes
    }
    It 'Preserves a single-login array without converting it to a scalar' {
        $Path = New-TestConfiguration {
            param($Json)
            $Json.Items[0].Logins = @($Json.Items[0].Logins[0])
        }
        $Item = Read-ServerObjectItems -Path $Path -ItemId VM-Objects
        @($Item.Logins).Count | Should -Be 1
        $Item.Logins[0].Name | Should -Be dbmigration
    }
    It 'Rejects <Case> before any platform invocation' -ForEach @(
        @{ Case = 'duplicate IDs'; Change = { param($J) $J.Items[1].Id = $J.Items[0].Id } },
        @{ Case = 'unknown properties'; Change = { param($J) $J.Common.Password = 'never-allowed' } },
        @{ Case = 'string Booleans'; Change = { param($J) $J.Items[0].Enabled = 'false' } },
        @{ Case = 'string ports'; Change = { param($J) $J.Items[0].TargetSqlPort = '1433' } },
        @{ Case = 'overlong derived container'; Change = { param($J) $J.Items[0].SourceServerName = ('x' * 70) } },
        @{ Case = 'removed snapshot run selector'; Change = { param($J) $J.Common.SnapshotRunId = 'old' } },
        @{ Case = 'removed permission export'; Change = { param($J) $J.Items[0].Activity = 'ExportPermissions' } },
        @{ Case = 'shared login list'; Change = { param($J) $J.Common.Logins = @() } },
        @{ Case = 'removed domain prefix'; Change = { param($J) $J.Items[0].DomainPrefix = 'old' } },
        @{ Case = 'removed identity name'; Change = { param($J) $J.Items[0].ManagedIdentityName = 'old' } },
        @{ Case = 'removed identity roles'; Change = { param($J) $J.Common.ManagedIdentityRoles = 'db_datareader' } },
        @{ Case = 'removed identity permissions'; Change = { param($J) $J.Common.ManagedIdentityPermissions = 'EXECUTE' } },
        @{ Case = 'invalid shared enabled'; Change = { param($J) $J.Common.Enabled = 'false'; $J.Items[0].Remove('Enabled') } },
        @{ Case = 'shared provisioning flag'; Change = { param($J) $J.Common.ProvisionLogins = $true } },
        @{ Case = 'string provisioning flag'; Change = { param($J) $J.Items[0].ProvisionLogins = 'true' } },
        @{ Case = 'string source trust'; Change = { param($J) $J.Items[0].SourceTrustServerCertificate = 'true' } },
        @{ Case = 'numeric source trust'; Change = { param($J) $J.Common.SourceTrustServerCertificate = 1 } },
        @{ Case = 'string target trust'; Change = { param($J) $J.Items[0].TargetTrustServerCertificate = 'true' } },
        @{ Case = 'numeric target trust'; Change = { param($J) $J.Common.TargetTrustServerCertificate = 1 } },
        @{ Case = 'scalar login list'; Change = { param($J) $J.Items[0].Logins = 'user' } },
        @{ Case = 'duplicate login names'; Change = { param($J) $J.Items[0].Logins[1].Name = 'DBMIGRATION' } },
        @{ Case = 'unknown login type'; Change = { param($J) $J.Items[0].Logins[0].Type = 'Windows' } },
        @{ Case = 'unknown login property'; Change = { param($J) $J.Items[0].Logins[0].Password = 'not-allowed' } },
        @{ Case = 'missing SQL secret'; Change = { param($J) $J.Items[0].Logins[0].Remove('SecretName') } },
        @{ Case = 'missing SQL vault'; Change = { param($J) $J.Items[0].Remove('KeyVaultName'); $J.Common.Remove('KeyVaultName') } },
        @{ Case = 'scalar permissions'; Change = { param($J) $J.Items[0].Logins[0].AccessType = 'db_datareader' } },
        @{ Case = 'invalid permission syntax'; Change = { param($J) $J.Items[0].Logins[0].AccessType = @('SELECT; DROP USER') } },
        @{ Case = 'non-Boolean reset'; Change = { param($J) $J.Items[0].Logins[0].ForcePasswordReset = 'true' } },
        @{ Case = 'external login secret'; Change = { param($J) $J.Items[0].Logins[2].SecretName = 'not-used' } },
        @{ Case = 'external password reset'; Change = { param($J) $J.Items[0].Logins[2].ForcePasswordReset = $false } },
        @{ Case = 'invalid identity GUID'; Change = { param($J) $J.Items[0].Logins[2].ObjectId = 'wrong' } },
        @{ Case = 'SQL identity GUID'; Change = { param($J) $J.Items[0].Logins[0].ObjectId = [guid]::NewGuid().ToString() } },
        @{ Case = 'provisioning without flag approval'; Change = { param($J) $J.Items[0].Activity = 'ProvisionLogins' } },
        @{ Case = 'provisioning without logins'; Change = { param($J) $J.Items[0].ProvisionLogins = $true; $J.Items[0].Logins = @() } },
        @{ Case = 'provisioning All databases'; Change = { param($J) $J.Items[0].ProvisionLogins = $true; $J.Items[0].SourceListofDatabases = 'All' } },
        @{ Case = 'out-of-scope login database'; Change = { param($J) $J.Items[0].ProvisionLogins = $true; $J.Items[0].Logins[0].Databases = @('other') } },
        @{ Case = 'legacy schema'; Change = { param($J) $J.schemaVersion = 1 } }
        @{ Case = 'string schema version'; Change = { param($J) $J.schemaVersion = '2' } }
    ) {
        $Path = New-TestConfiguration $Change
        { Read-ServerObjectItems -Path $Path } | Should -Throw
    }
    It 'Rejects unknown or disabled selected IDs' {
        { Read-ServerObjectItems -Path $OperationalConfig -ItemId missing } | Should -Throw '*unknown or disabled*'
        $Path = New-TestConfiguration { param($J) $J.Items[0].Enabled = $false }
        { Read-ServerObjectItems -Path $Path -ItemId VM-Objects } | Should -Throw '*unknown or disabled*'
    }
    It 'Converts Key Vault provisioning for both targets without treating the secret as connection authentication' {
        $Path = New-TestConfiguration { param($J) foreach ($Item in $J.Items) { $Item.ProvisionLogins = $true } }
        foreach ($Item in @(Read-ServerObjectItems -Path $Path -Activity ProvisionLogins)) {
            $Rows = @(Get-ServerObjectProvisioningItems -Item $Item)
            $Rows | Should -HaveCount 6
            $Rows[0].Database | Should -Be MIGRDEMO
            $Rows[1].Database | Should -Be CDC_Director_PRO
            $Rows.LoginName | Select-Object -Unique | Should -Be @($Item.Logins.Name)
            $Rows[0].TargetServerFQDN | Should -Be $Item.TargetSqlHost
            $Rows[0].TargetType | Should -Be $Item.TargetType
            $Rows[0].PSObject.Properties.Name | Should -Not -Contain Password
        }
    }
    It 'Supports per-login database scopes, independent resets and access, and empty grant lists' {
        $Path = New-TestConfiguration {
            param($J)
            $J.Items[0].ProvisionLogins = $true
            $J.Items[0].Logins[0].ForcePasswordReset = $true
            $J.Items[0].Logins[1].Databases = @('MIGRDEMO')
            $J.Items[0].Logins[1].AccessType = @()
        }
        $Item = Read-ServerObjectItems -Path $Path -ItemId VM-Objects -Activity ProvisionSqlLogins
        $Item.Activity | Should -Be ProvisionLogins
        $Rows = @(Get-ServerObjectProvisioningItems -Item $Item)
        $Rows | Should -HaveCount 5
        $Rows[0].ForcePasswordReset | Should -BeTrue
        $Rows[2].ForcePasswordReset | Should -BeFalse
        $Rows[2].AccessType | Should -HaveCount 0
        $Rows[2].Database | Should -Be MIGRDEMO
    }
}

Describe 'Current private Blob snapshots' -Tag 'Unit' {
    BeforeEach {
        $Item = Read-ServerObjectItems -Path $OperationalConfig -ItemId VM-Objects
        $RunId = New-ServerObjectRunId
        $Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($Relative in @(Get-ServerObjectSnapshotPaths)) {
            $Path = Join-Path $Root ($Relative.Replace('/', '\'))
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
            Set-Content -LiteralPath $Path -Value 'SELECT 1;'
        }
        Set-Content -LiteralPath (Join-Path $Root 'credential.local.json') -Value '{"not":"an artifact"}'
        $script:Blobs = @{}
        $script:UploadOrder = @()
        Mock Get-ServerObjectStorage { [pscustomobject]@{ Test = $true } }
        Mock Reset-ServerObjectBlobContainer { $script:Blobs.Clear() }
        Mock Write-ServerObjectBlob {
            param($Client, $Name, $Bytes)
            $script:Blobs[$Name] = $Bytes.Clone()
            $script:UploadOrder += $Name
        }
        Mock Read-ServerObjectBlob {
            param($Client, $Name)
            if (-not $script:Blobs.ContainsKey($Name)) { throw 'Blob missing' }
            return ,([byte[]]$script:Blobs[$Name])
        }
        Mock Get-ServerObjectBlobNames {
            param($Client, $Prefix)
            @($script:Blobs.Keys | Where-Object { $_.StartsWith("$Prefix/") })
        }
        Mock Remove-ServerObjectBlob { param($Client, $Name) $script:Blobs.Remove($Name) }
    }
    It 'Preserves all seven flat SQL files, publishes manifest last, and excludes local credentials/logs' {
        $Uri = Publish-ServerObjectBlobSnapshot -Item $Item -RunId $RunId -Root $Root
        $Uri | Should -Match '/source-instance-sqlobjects-sqlvm/manifest.json$'
        $script:Blobs.Count | Should -Be 8
        $script:UploadOrder[-1] | Should -Be 'manifest.json'
        $Snapshot = Read-ServerObjectBlobSnapshot -Item $Item
        $Snapshot.Files | Should -HaveCount 7
        $Snapshot.Manifest.schemaVersion | Should -Be 4
        $Destination = Join-Path $TestDrive 'replay'
        Save-ServerObjectBlobSnapshot -Snapshot $Snapshot -Root $Destination
        Get-Content -LiteralPath (Join-Path $Destination 'SQLLogins\SQLLogins_All.sql') | Should -Be 'SELECT 1;'
    }
    It 'Rejects tampered file bytes before replay' {
        $null = Publish-ServerObjectBlobSnapshot -Item $Item -RunId $RunId -Root $Root
        $Key = 'SQLLogins/SQLLogins_All.sql'
        $script:Blobs[$Key] = [Text.Encoding]::UTF8.GetBytes('SELECT 9;')
        { Read-ServerObjectBlobSnapshot -Item $Item } | Should -Throw '*integrity verification failed*'
    }
    It 'Records source trust without making a connection-only change invalidate replay' {
        $Item.SourceTrustServerCertificate = $true
        $null = Publish-ServerObjectBlobSnapshot -Item $Item -RunId $RunId -Root $Root
        $Item.SourceTrustServerCertificate = $false
        $Snapshot = Read-ServerObjectBlobSnapshot -Item $Item
        $Snapshot.Manifest.PSObject.Properties.Name | Should -Not -Contain configuration
        $Snapshot.Files | Should -HaveCount 7
    }
    It 'Does not bind the snapshot to the target hostname or optional source trust setting' {
        $null = Publish-ServerObjectBlobSnapshot -Item $Item -RunId $RunId -Root $Root
        $Key = $script:UploadOrder[-1]
        $Manifest = [Text.Encoding]::UTF8.GetString($script:Blobs[$Key]) | ConvertFrom-Json
        $Manifest.PSObject.Properties.Name | Should -Not -Contain targetHost
        $script:Blobs[$Key] = [Text.Encoding]::UTF8.GetBytes(($Manifest | ConvertTo-Json -Depth 20))
        (Read-ServerObjectBlobSnapshot -Item $Item).Files | Should -HaveCount 7
    }
    It 'Rejects snapshot version <Version> from before current scope and update rules' -ForEach @(@{ Version = 1 }, @{ Version = 2 }, @{ Version = 3 }) {
        $null = Publish-ServerObjectBlobSnapshot -Item $Item -RunId $RunId -Root $Root
        $Key = 'manifest.json'
        $Manifest = [Text.Encoding]::UTF8.GetString($script:Blobs[$Key]) | ConvertFrom-Json
        $Manifest.schemaVersion = $Version
        $script:Blobs[$Key] = [Text.Encoding]::UTF8.GetBytes(($Manifest | ConvertTo-Json -Depth 20))
        { Read-ServerObjectBlobSnapshot -Item $Item } | Should -Throw '*unsupported*'
    }
    It 'Allows execution-time database, scope and target endpoint changes' -ForEach @(
        @{ Field = 'SourceListofDatabases'; Value = 'another' },
        @{ Field = 'TargetSqlHost'; Value = 'other.example' },
        @{ Field = 'SQLLoginsMigrationScope'; Value = 'Server' }
    ) {
        $null = Publish-ServerObjectBlobSnapshot -Item $Item -RunId $RunId -Root $Root
        $Item.$Field = $Value
        { Read-ServerObjectBlobSnapshot -Item $Item } | Should -Not -Throw
    }
    It 'Rejects duplicate or unsafe manifest paths and malformed hashes' -ForEach @(
        @{ Change = { param($M) $M.files[0].path = '../outside.sql' } },
        @{ Change = { param($M) $M.files[0].path = $M.files[1].path } },
        @{ Change = { param($M) $M.files[0].sha256 = 'wrong' } }
    ) {
        $null = Publish-ServerObjectBlobSnapshot -Item $Item -RunId $RunId -Root $Root
        $Key = $script:UploadOrder[-1]
        $M = [Text.Encoding]::UTF8.GetString($script:Blobs[$Key]) | ConvertFrom-Json
        & $Change $M
        $script:Blobs[$Key] = [Text.Encoding]::UTF8.GetBytes(($M | ConvertTo-Json -Depth 20))
        { Read-ServerObjectBlobSnapshot -Item $Item } | Should -Throw
    }
    It 'Allows enabling or disabling execution components because every component was captured' {
        $null = Publish-ServerObjectBlobSnapshot -Item $Item -RunId $RunId -Root $Root
        $Item.SQLAgentJobsMigrationFlag = 'No'
        { Read-ServerObjectBlobSnapshot -Item $Item } | Should -Not -Throw
        $Item.SQLDBMailMigrationFlag = 'Yes'
        { Read-ServerObjectBlobSnapshot -Item $Item } | Should -Not -Throw
    }
    It 'Never publishes the completion marker after a failed SQL upload' {
        Mock Write-ServerObjectBlob { throw 'Upload denied' } -ParameterFilter { $Name -like '*.sql' }
        { Publish-ServerObjectBlobSnapshot -Item $Item -RunId $RunId -Root $Root } | Should -Throw '*Upload denied*'
        Should -Invoke Write-ServerObjectBlob -Times 0 -Exactly -ParameterFilter { $Name -like '*manifest.json' }
    }
    It 'Separates platform containers without a history or run-ID folder' {
        $Other = Read-ServerObjectItems -Path $OperationalConfig -ItemId MI-Objects
        $Item.StorageContainer | Should -Not -Be $Other.StorageContainer
        Get-ServerObjectBlobPrefix -Item $Item | Should -Be ''
    }
    It 'Replaces the managed snapshot without accumulating SQL files or run folders' {
        $First = Publish-ServerObjectBlobSnapshot -Item $Item -RunId $RunId -Root $Root
        Set-Content -LiteralPath (Join-Path $Root 'SQLLogins\SQLLogins_All.sql') -Value 'SELECT 3;'
        $Second = Publish-ServerObjectBlobSnapshot -Item $Item -RunId (New-ServerObjectRunId) -Root $Root
        $Second | Should -Be $First
        $script:Blobs.Count | Should -Be 8
        [Text.Encoding]::UTF8.GetString($script:Blobs['SQLLogins/SQLLogins_All.sql']) | Should -Match 'SELECT 3'
    }
    It 'Invalidates a previous manifest when replacement fails, preventing partial replay' {
        $null = Publish-ServerObjectBlobSnapshot -Item $Item -RunId $RunId -Root $Root
        Mock Write-ServerObjectBlob { throw 'Upload denied' } -ParameterFilter { $Name -like '*.sql' }
        { Publish-ServerObjectBlobSnapshot -Item $Item -RunId (New-ServerObjectRunId) -Root $Root } | Should -Throw '*Upload denied*'
        { Read-ServerObjectBlobSnapshot -Item $Item } | Should -Throw '*Blob missing*'
    }
    It 'Rejects Windows traversal, devices and alternate data streams: <Path>' -ForEach @(
        @{ Path = '../a.sql' }, @{ Path = '/a.sql' }, @{ Path = 'C:/a.sql' },
        @{ Path = 'dir\a.sql' }, @{ Path = 'CON.sql' }, @{ Path = 'dir/NUL.sql' },
        @{ Path = 'a.sql:secret' }, @{ Path = 'dir./a.sql' }, @{ Path = 'a.txt' }
    ) {
        { Resolve-ServerObjectBlobFile -Root $TestDrive -RelativePath $Path } | Should -Throw
    }
}

Describe 'Independent item validation and end-to-end orchestration' -Tag 'Unit' {
    BeforeEach {
        $Items = @(Read-ServerObjectItems -Path $OperationalConfig)
        $Output = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Get-ServerObjectStorage { [pscustomobject]@{} }
        Mock Import-Module {}
        Mock Assert-ServerObjectSqlAccess {}
        Mock Assert-ServerObjectReplayTarget {}
        Mock Invoke-ServerObjectPreflight {}
        Mock Invoke-ServerObjectWorker { [pscustomobject]@{ Status = 'SUCCESS'; Component = 'logins' } }
        Mock Invoke-ServerObjectProvisioning {}
        Mock Publish-ServerObjectBlobSnapshot { 'https://example/manifest.json' }
        Mock Write-Host {}
        Mock Write-Warning {}
    }
    It 'Previews all targets without local outputs, containers, uploads, workers or secret provisioning' {
        $Results = @(Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output -Preview)
        $Results | Should -HaveCount 2
        $Results.Status | Should -Be @('PreflightPassed', 'PreflightPassed')
        Test-Path -LiteralPath $Output | Should -BeFalse
        Should -Invoke Invoke-ServerObjectWorker -Times 0 -Exactly
        Should -Invoke Publish-ServerObjectBlobSnapshot -Times 0 -Exactly
        Should -Invoke Get-ServerObjectStorage -Times 0 -Exactly -ParameterFilter { $Create }
    }
    It 'Records a later preflight failure without blocking the valid item' {
        Mock Get-ServerObjectStorage { throw 'MI denied' } -ParameterFilter { $Item.TargetType -eq 'SQLMI' }
        { Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output } | Should -Throw '*MI denied*'
        Test-Path -LiteralPath $Output | Should -BeTrue
        Should -Invoke Invoke-ServerObjectWorker -Times 1 -Exactly -ParameterFilter { $Item.TargetType -eq 'SQLVM' }
        Should -Invoke Invoke-ServerObjectWorker -Times 0 -Exactly -ParameterFilter { $Item.TargetType -eq 'SQLMI' }
    }
    It 'Generates and snapshots each target separately and records run IDs persistently' {
        $Results = @(Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output)
        $Results | Should -HaveCount 2
        $Results.Status | Should -Be @('SUCCESS', 'SUCCESS')
        $Results[0].OutputFile | Should -Not -Be $Results[1].OutputFile
        $Results[0].RunId | Should -Be $Results[1].RunId
        $Report = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $Results[0].OutputFile) 'results.json') -Raw | ConvertFrom-Json
        $Report.status | Should -Be Succeeded
        $Report.results.BlobManifest | Should -HaveCount 2
        Should -Invoke Invoke-ServerObjectWorker -Times 0 -Exactly -ParameterFilter { $Execution }
    }
    It 'Does not execute after an snapshot failure and still processes the other target' {
        $Items[0].Activity = 'GenerateAndExecute'
        Mock Publish-ServerObjectBlobSnapshot { throw 'Snapshot denied' } -ParameterFilter { $Item.TargetType -eq 'SQLVM' }
        { Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output } | Should -Throw '*items failed*'
        Should -Invoke Invoke-ServerObjectWorker -Times 2 -Exactly
        Should -Invoke Invoke-ServerObjectWorker -Times 0 -Exactly -ParameterFilter { $Execution }
        $Report = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $Output -Recurse -Filter results.json)[0].FullName -Raw | ConvertFrom-Json
        $Report.status | Should -Be Failed
        $Report.results[0].ErrorMessage | Should -Be 'Snapshot denied'
        $Report.results[1].Status | Should -Be SUCCESS
    }
    It 'Verifies each snapshot before executing its item without blocking other items' {
        foreach ($Item in $Items) { $Item.Activity = 'Execute' }
        Mock Read-ServerObjectBlobSnapshot { [pscustomobject]@{ Files = @([pscustomobject]@{ Path = 'source/logins.sql'; Bytes = [byte[]]@(1) }) } }
        Mock Read-ServerObjectBlobSnapshot { throw 'MI snapshot corrupt' } -ParameterFilter { $Item.TargetType -eq 'SQLMI' }
        { Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output } | Should -Throw '*MI snapshot corrupt*'
        Should -Invoke Invoke-ServerObjectWorker -Times 1 -Exactly -ParameterFilter { $Item.TargetType -eq 'SQLVM' -and $Execution }
        Should -Invoke Invoke-ServerObjectWorker -Times 0 -Exactly -ParameterFilter { $Item.TargetType -eq 'SQLMI' }
    }
    It 'Replays verified snapshot bytes before calling the execute-only worker' {
        $Items = @($Items[0])
        $Items[0].Activity = 'Execute'
        $script:ReplayOrder = @()
        Mock Read-ServerObjectBlobSnapshot {
            [pscustomobject]@{ Files = @([pscustomobject]@{ Path = 'source/logins.sql'; Bytes = [Text.Encoding]::UTF8.GetBytes('SELECT 1;') }) }
        }
        Mock Save-ServerObjectBlobSnapshot { $script:ReplayOrder += 'Save' }
        Mock Invoke-ServerObjectWorker { $script:ReplayOrder += 'Execute'; [pscustomobject]@{ Status = 'SUCCESS' } } -ParameterFilter { $Execution }
        $Results = @(Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output)
        $script:ReplayOrder | Should -Be @('Save', 'Execute')
        $Results[0].PSObject.Properties.Name | Should -Not -Contain SnapshotRunId
        Should -Invoke Publish-ServerObjectBlobSnapshot -Times 0 -Exactly
    }
    It 'Snapshots and verifies before executing combined mode' {
        $Items = @($Items[0])
        $Items[0].Activity = 'GenerateAndExecute'
        $script:CombinedOrder = @()
        Mock Invoke-ServerObjectWorker {
            $script:CombinedOrder += $(if ($Execution) { 'Execute' } else { 'Generate' })
            [pscustomobject]@{ Status = 'SUCCESS' }
        }
        Mock Publish-ServerObjectBlobSnapshot { $script:CombinedOrder += 'Upload'; 'https://example/manifest.json' }
        Mock Read-ServerObjectBlobSnapshot { $script:CombinedOrder += 'Verify'; [pscustomobject]@{ Files = @() } }
        Mock Save-ServerObjectBlobSnapshot { $script:CombinedOrder += 'Save' }
        $null = Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output
        $script:CombinedOrder | Should -Be @('Generate', 'Upload', 'Verify', 'Save', 'Execute')
    }
    It 'Previews provisioning without creating outputs or invoking a provisioning worker' {
        foreach ($Item in $Items) { $Item.Activity = 'ProvisionLogins'; $Item.ProvisionLogins = $true }
        Mock Invoke-ServerObjectProvisioning {}
        $null = Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output -Preview
        Test-Path -LiteralPath $Output | Should -BeFalse
        Should -Invoke Invoke-ServerObjectProvisioning -Times 0 -Exactly
        Should -Invoke Get-ServerObjectStorage -Times 0 -Exactly
        Should -Invoke Invoke-ServerObjectPreflight -Times 2 -Exactly -ParameterFilter { $Operation -eq 'Invoke-ProvisionLogins-AzSql' }
    }
    It 'Provisions directly without source extraction or storage access in provisioning-only mode' {
        $Items = @($Items[0])
        $Items[0].Activity = 'ProvisionLogins'
        $Items[0].ProvisionLogins = $true
        $null = Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output
        Should -Invoke Invoke-ServerObjectProvisioning -Times 1 -Exactly
        Should -Invoke Invoke-ServerObjectWorker -Times 0 -Exactly
        Should -Invoke Get-ServerObjectStorage -Times 0 -Exactly
        Should -Invoke Publish-ServerObjectBlobSnapshot -Times 0 -Exactly
    }
    It 'Keeps provisioning disabled unless explicitly enabled on an item' {
        $null = Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output
        Should -Invoke Invoke-ServerObjectProvisioning -Times 0 -Exactly
    }
    It 'Provisions after verifying source SQL and before execution, in an unsnapshotd folder' {
        $Items = @($Items[0])
        $Items[0].ProvisionLogins = $true
        $Items[0].Activity = 'GenerateAndExecute'
        $script:StepOrder = @()
        Mock Invoke-ServerObjectWorker {
            $Root | Should -BeLike '*\SourceObjects'
            $script:StepOrder += $(if ($Execution) { 'Execute' } else { 'Generate' })
            [pscustomobject]@{ Status = 'SUCCESS' }
        }
        Mock Publish-ServerObjectBlobSnapshot {
            $Root | Should -BeLike '*\SourceObjects'
            $script:StepOrder += 'Upload'
            'https://example/manifest.json'
        }
        Mock Read-ServerObjectBlobSnapshot { $script:StepOrder += 'Verify'; [pscustomobject]@{ Files = @() } }
        Mock Save-ServerObjectBlobSnapshot { $script:StepOrder += 'Save' }
        Mock Invoke-ServerObjectProvisioning {
            $Root | Should -BeLike '*\Provisioning'
            $script:StepOrder += 'Provision'
        }
        $null = Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output
        $script:StepOrder | Should -Be @('Generate', 'Upload', 'Verify', 'Save', 'Provision', 'Execute')
    }
    It 'Continues snapshot replay on both targets after provisioning validation fails on one' {
        foreach ($Item in $Items) { $Item.ProvisionLogins = $true; $Item.Activity = 'Execute' }
        Mock Read-ServerObjectBlobSnapshot { [pscustomobject]@{ Files = @() } }
        Mock Save-ServerObjectBlobSnapshot {}
        Mock Invoke-ServerObjectPreflight { throw 'Identity not found' } -ParameterFilter {
            $Operation -eq 'Invoke-ProvisionLogins-AzSql' -and $Configuration.Items[0].TargetType -eq 'SQLMI'
        }
        { Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output } | Should -Throw '*Identity not found*'
        Should -Invoke Invoke-ServerObjectProvisioning -Times 1 -Exactly -ParameterFilter { $Item.TargetType -eq 'SQLVM' }
        Should -Invoke Invoke-ServerObjectWorker -Times 1 -Exactly -ParameterFilter { $Item.TargetType -eq 'SQLVM' }
        Should -Invoke Invoke-ServerObjectWorker -Times 1 -Exactly -ParameterFilter { $Item.TargetType -eq 'SQLMI' -and $Execution }
        Should -Invoke Invoke-ServerObjectProvisioning -Times 0 -Exactly -ParameterFilter { $Item.TargetType -eq 'SQLMI' }
        Test-Path -LiteralPath $Output | Should -BeTrue
        $Report = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $Output -Recurse -Filter results.json)[0].FullName -Raw | ConvertFrom-Json
        $Report.results[1].Status | Should -Be FAILED
        $Report.results[1].Components.Status | Should -Contain SUCCESS
        $Report.results[1].Components.Status | Should -Contain FAILED
    }
    It 'Retains provisioning execution failures and replay results and fails the overall run last' {
        $Items = @($Items[0])
        $Items[0].Activity = 'Execute'
        $Items[0].ProvisionLogins = $true
        Mock Read-ServerObjectBlobSnapshot { [pscustomobject]@{ Files = @() } }
        Mock Save-ServerObjectBlobSnapshot {}
        Mock Invoke-ServerObjectProvisioning { throw 'Provisioning execution denied' }
        Mock Invoke-ServerObjectWorker {
            [pscustomobject]@{ Component = 'SQLLogins'; Status = 'FAILED'; ErrorMessage = 'Login replay denied'; Phase = 'Execution' }
            [pscustomobject]@{ Component = 'SQLOperators'; Status = 'SUCCESS'; ErrorMessage = ''; Phase = 'Execution' }
        }
        { Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output } |
            Should -Throw '*Provisioning execution denied*Login replay denied*'
        Should -Invoke Invoke-ServerObjectWorker -Times 1 -Exactly -ParameterFilter { $Execution }
        $Report = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $Output -Recurse -Filter results.json)[0].FullName -Raw | ConvertFrom-Json
        $Report.status | Should -Be Failed
        $Report.results[0].Components.Status | Should -Be @('FAILED', 'FAILED', 'SUCCESS')
        $Log = Get-Content -LiteralPath (Join-Path $Report.results[0].OutputFile 'migration.log') -Raw
        $Log | Should -Match "component='SQLOperators': SUCCESS=1; FAILED=0"
        $Log | Should -Match 'Provisioning execution denied'
    }
    It 'Passes a separate SQL credential to provisioning validation, provisioning and replay without adding it to reports' {
        $Items = @($Items[0])
        $Items[0].Activity = 'Execute'
        $Items[0].ProvisionLogins = $true
        $Items[0].TargetSqlAuthType = 'SqlLogin'
        $Credential = [pscredential]::new('offline-admin', (ConvertTo-SecureString 'offline-test-password' -AsPlainText -Force))
        Mock Read-ServerObjectBlobSnapshot { [pscustomobject]@{ Files = @() } }
        Mock Save-ServerObjectBlobSnapshot {}
        $null = Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output `
            -SqlCredentials @{ 'VM-Objects' = $Credential }
        Should -Invoke Invoke-ServerObjectPreflight -Times 1 -Exactly -ParameterFilter {
            $Options.TargetSqlAuthType -eq 'SqlLogin' -and $Options.SqlCredential.UserName -eq 'offline-admin'
        }
        Should -Invoke Invoke-ServerObjectProvisioning -Times 1 -Exactly -ParameterFilter { $SqlCredential.UserName -eq 'offline-admin' }
        Should -Invoke Invoke-ServerObjectWorker -Times 1 -Exactly -ParameterFilter { $Execution -and $SqlCredential.UserName -eq 'offline-admin' }
        $Report = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $Output -Recurse -Filter results.json)[0].FullName -Raw
        $Report | Should -Not -Match 'offline-admin|offline-test-password|SqlCredential'
    }
    It 'Never preflights or provisions target logins during Generate even when explicitly enabled' {
        foreach ($Item in $Items) { $Item.ProvisionLogins = $true; $Item.Activity = 'Generate' }
        $null = Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $Scripts -OutputRoot $Output
        Should -Invoke Invoke-ServerObjectPreflight -Times 0 -Exactly
        Should -Invoke Invoke-ServerObjectProvisioning -Times 0 -Exactly
        Should -Invoke Assert-ServerObjectReplayTarget -Times 0 -Exactly
        Should -Invoke Invoke-ServerObjectWorker -Times 2 -Exactly -ParameterFilter { -not $Execution }
    }
}

Describe 'Concurrent independent item processes' -Tag 'Unit' {
    BeforeEach {
        $FixtureScripts = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures')).Path
        $Output = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $Items = @(Read-ServerObjectItems -Path $OperationalConfig)
        foreach ($Item in $Items) { $Item | Add-Member -NotePropertyName CheckConcurrent -NotePropertyValue $false }
        Mock Export-ServerObjectAzureContext { '' }
        Mock Write-Host {}
        Mock Write-Warning {}
    }
    It 'Runs two real worker processes concurrently and preserves config order in the report' {
        foreach ($Item in $Items) { $Item.CheckConcurrent = $true }
        $Items[0].SourceTrustServerCertificate = $true
        $Results = @(Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $FixtureScripts -OutputRoot $Output -ThrottleLimit 10)
        $Results.ItemId | Should -Be @('VM-Objects', 'MI-Objects')
        $Results.Status | Should -Be @('SUCCESS', 'SUCCESS')
        $Workers = @($Results | ForEach-Object { $_.Components[0] })
        $Workers[0].ProcessId | Should -Not -Be $Workers[1].ProcessId
        $Workers[0].ProcessId | Should -Not -Be $PID
        $Workers[0].SourceTrustServerCertificate | Should -BeTrue
        $Workers[1].SourceTrustServerCertificate | Should -BeFalse
        [Math]::Max($Workers[0].Started, $Workers[1].Started) | Should -BeLessThan ([Math]::Min($Workers[0].Finished, $Workers[1].Finished))
        $Report = Get-Content (Join-Path (Split-Path $Results[0].OutputFile) results.json) -Raw | ConvertFrom-Json
        $Report.results.ItemId | Should -Be @('VM-Objects', 'MI-Objects')
        $Report.status | Should -Be Succeeded
    }
    It 'Enforces a maximum of two overlapping workers across four items' {
        $Template = $Items[0] | ConvertTo-Json -Depth 20
        $Items = @(1..4 | ForEach-Object {
            $Item = $Template | ConvertFrom-Json
            $Item.Id = "item$_"; $Item.TargetSqlHost = "target$_.example"; $Item.CheckConcurrent = $true
            $Item.SourceServerName = "source$_"; $Item.StorageContainer = "source$_-sqlobjects"
            $Item
        })
        $Results = @(Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $FixtureScripts -OutputRoot $Output -ThrottleLimit 2)
        $Events = @($Results | ForEach-Object {
            [pscustomobject]@{ Time = $_.Components[0].Started; Delta = 1 }
            [pscustomobject]@{ Time = $_.Components[0].Finished; Delta = -1 }
        } | Sort-Object Time)
        $Count = 0; $Maximum = 0
        foreach ($Event in $Events) { $Count += $Event.Delta; $Maximum = [Math]::Max($Maximum, $Count) }
        $Maximum | Should -Be 2
    }
    It 'Continues other items after a <Failure> failure and persists both results' -ForEach @(
        @{ Failure = 'preflight'; Id = 'preflight-failure'; Message = 'SQL preflight timeout' },
        @{ Failure = 'runtime'; Id = 'runtime-failure'; Message = 'Simulated SQL execution failure' }
    ) {
        $Items[0].Id = $Id
        { Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $FixtureScripts -OutputRoot $Output -ThrottleLimit 2 } |
            Should -Throw "*$Message*"
        $Report = Get-Content (Get-ChildItem -LiteralPath $Output -Recurse -Filter results.json).FullName -Raw | ConvertFrom-Json
        $Report.status | Should -Be Failed
        $Report.results.ItemId | Should -Be @($Id, 'MI-Objects')
        $Report.results.Status | Should -Be @('FAILED', 'SUCCESS')
        $Report.results[0].ErrorMessage | Should -Match $Message
        $Report.results[1].Components[0].ProcessId | Should -Not -Be $PID
    }
    It 'Records a crashed item process without losing the successful peer result' {
        Mock Start-ServerObjectItemJob { Start-Job { throw 'Item process crashed before initialization' } } -ParameterFilter { $Item.Id -eq 'VM-Objects' }
        { Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $FixtureScripts -OutputRoot $Output -ThrottleLimit 2 } | Should -Throw '*Item process crashed*'
        $Report = Get-Content (Get-ChildItem -LiteralPath $Output -Recurse -Filter results.json).FullName -Raw | ConvertFrom-Json
        $Report.results.Status | Should -Be @('FAILED', 'SUCCESS')
        $Report.results[0].ErrorMessage | Should -Match 'Item process crashed'
    }
    It 'Cleans up the temporary Azure profile even if item process creation fails' {
        Mock Export-ServerObjectAzureContext {
            [IO.File]::WriteAllText($Path, 'fixture profile')
            $Path
        }
        Mock Start-ServerObjectItemJob { throw 'Cannot start item process' }
        { Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $FixtureScripts -OutputRoot $Output -ThrottleLimit 2 } | Should -Throw '*Cannot start item process*'
        @(Get-ChildItem -LiteralPath $Output -Recurse -Filter azure.context.json) | Should -HaveCount 0
        $Report = Get-Content (Get-ChildItem -LiteralPath $Output -Recurse -Filter results.json).FullName -Raw | ConvertFrom-Json
        $Report.results.Status | Should -Be @('FAILED', 'FAILED')
    }
    It 'Rejects overlapping endpoints before creating outputs but permits serial execution' {
        $Items[1].TargetSqlHost = $Items[0].TargetSqlHost.ToUpperInvariant()
        $Items[1].TargetSqlPort = $Items[0].TargetSqlPort
        { Invoke-ServerObjectWorkflow -Items $Items -ScriptsPath $FixtureScripts -OutputRoot $Output -ThrottleLimit 10 } |
            Should -Throw '*distinct target SQL endpoints*'
        $Output | Should -Not -Exist
        { Assert-ServerObjectItemTargets -Items $Items -ThrottleLimit 1 } | Should -Not -Throw
    }
}

Describe 'Default entry-point execution mode' -Tag 'Unit' {
    BeforeAll {
        $Tokens = $null; $Errors = $null
        $Ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Scripts 'Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1'), [ref]$Tokens, [ref]$Errors)
        $EntryBlock = [scriptblock]::Create($Ast.EndBlock.Statements[-1].Extent.Text.Replace('$PSScriptRoot', '$Scripts'))
        function Invoke-TestServerObjectEntry {
            [CmdletBinding(SupportsShouldProcess)]
            param([switch]$Foreground, [string]$Activity, [string]$RunDirectory, [string]$WorkerRequestPath,
                [string]$ConfigPath = $OperationalConfig, [string]$OutputJsonPath, [string[]]$ItemId,
                [string]$OutputRoot = $TestDrive, [int]$ThrottleLimit = 10, [int]$MonitorIntervalSeconds = 5)
            & $EntryBlock
        }
    }
    BeforeEach {
        $EntryItems = @(Read-ServerObjectItems -Path $OperationalConfig)
        Mock Read-ServerObjectItems { $EntryItems }
        Mock Start-ServerObjectBackgroundRun {}
        Mock Invoke-ServerObjectWorkflow {}
        Mock Get-ServerObjectRunStatus {}
        Mock Watch-ServerObjectRun {}
    }
    It 'Defaults to background execution with ten concurrent items' {
        Invoke-TestServerObjectEntry
        Should -Invoke Start-ServerObjectBackgroundRun -Times 1 -Exactly -ParameterFilter { $ThrottleLimit -eq 10 -and $Items.Count -eq 2 }
        Should -Invoke Invoke-ServerObjectWorkflow -Times 0 -Exactly
    }
    It 'Runs foreground only when explicitly requested' {
        Invoke-TestServerObjectEntry -Foreground
        Should -Invoke Invoke-ServerObjectWorkflow -Times 1 -Exactly -ParameterFilter { -not $Preview }
        Should -Invoke Start-ServerObjectBackgroundRun -Times 0 -Exactly
    }
    It 'Keeps WhatIf foreground and read-only instead of launching background processes' {
        Invoke-TestServerObjectEntry -WhatIf
        Should -Invoke Invoke-ServerObjectWorkflow -Times 1 -Exactly -ParameterFilter { $Preview }
        Should -Invoke Start-ServerObjectBackgroundRun -Times 0 -Exactly
    }
    It 'Reads status without loading operational configuration or launching work' {
        Invoke-TestServerObjectEntry -Activity Status -RunDirectory test-run
        Should -Invoke Get-ServerObjectRunStatus -Times 1 -Exactly -ParameterFilter { $RunDirectory -eq 'test-run' }
        Should -Invoke Read-ServerObjectItems -Times 0 -Exactly
        Should -Invoke Start-ServerObjectBackgroundRun -Times 0 -Exactly
    }
    It 'Monitors without launching another migration' {
        Invoke-TestServerObjectEntry -Activity Monitor -RunDirectory test-run -MonitorIntervalSeconds 2
        Should -Invoke Watch-ServerObjectRun -Times 1 -Exactly -ParameterFilter { $RunDirectory -eq 'test-run' -and $MonitorIntervalSeconds -eq 2 }
        Should -Invoke Start-ServerObjectBackgroundRun -Times 0 -Exactly
    }
}

Describe 'Persistent background runs and monitoring' -Tag 'Unit' {
    BeforeEach {
        $FixtureScripts = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures')).Path
        $Output = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $Items = @(Read-ServerObjectItems -Path $OperationalConfig -ItemId VM-Objects)
        Mock Export-ServerObjectAzureContext { '' }
        Mock Write-Host {}
        Mock Write-Warning {}
    }
    It 'Starts a responsive independent background process and reports completion without SQL or Azure calls' {
        $Items = @(Read-ServerObjectItems -Path $OperationalConfig)
        foreach ($Item in $Items) {
            $Item | Add-Member -NotePropertyName CheckConcurrent -NotePropertyValue $true
            $Item.Activity = 'Execute'; $Item.ProvisionLogins = $false; $Item.TargetSqlAuthType = 'SqlLogin'
        }
        $Items[0].SourceTrustServerCertificate = $true
        $Credential = [pscredential]::new('offline-admin', (ConvertTo-SecureString 'offline-test-password' -AsPlainText -Force))
        $Run = Start-ServerObjectBackgroundRun -Items $Items -ScriptsPath $FixtureScripts -OutputRoot $Output -ThrottleLimit 10 `
            -SqlCredentials @{ 'VM-Objects' = $Credential; 'MI-Objects' = $Credential }
        try {
            $Run.ProcessId | Should -Not -Be $PID
            $Run.StatePath | Should -Exist
            $Run.ResultsPath | Should -Exist
            $Deadline = [datetime]::UtcNow.AddSeconds(30)
            do {
                $State = Get-ServerObjectRunStatus -OutputRoot $Output -RunDirectory $Run.RunDirectory
                if ($State.Status -ne 'Running') { break }
                Start-Sleep -Milliseconds 100
            } while ([datetime]::UtcNow -lt $Deadline)
            $State.Status | Should -Be Succeeded -Because "$($State.ErrorMessage); $($State.Results | ConvertTo-Json -Depth 8 -Compress)"
            $State.Results.ItemId | Should -Be @('VM-Objects', 'MI-Objects')
            $State.Results.Status | Should -Be @('SUCCESS', 'SUCCESS')
            $State.Results[0].Components[0].SourceTrustServerCertificate | Should -BeTrue
            $State.Results[1].Components[0].SourceTrustServerCertificate | Should -BeFalse
            foreach ($Result in $State.Results) { $Result.Components[0].CredentialUser | Should -BeExactly 'offline-admin' }
            foreach ($Path in @($Run.ResultsPath, $Run.LogPath, $Run.ErrorLogPath)) {
                Get-Content -LiteralPath $Path -Raw | Should -Not -Match 'offline-test-password'
            }
            foreach ($Result in $State.Results) { $Result.Components[0].ProcessId | Should -Not -Be $Run.ProcessId }
            (Get-ServerObjectRunStatus -OutputRoot $Output).RunDirectory | Should -Be $Run.RunDirectory
            Join-Path $Run.RunDirectory request.clixml | Should -Not -Exist
            Join-Path $Run.RunDirectory bootstrap.context.json | Should -Not -Exist
        }
        finally {
            $Process = Get-Process -Id $Run.ProcessId -ErrorAction SilentlyContinue
            if ($Process) { Wait-Process -Id $Run.ProcessId -Timeout 30 -ErrorAction Stop }
        }
    }
    It 'Persists launcher failure and removes bootstrap artifacts when process startup fails' {
        Mock Start-Process { throw 'Cannot start worker' }
        { Start-ServerObjectBackgroundRun -Items $Items -ScriptsPath $FixtureScripts -OutputRoot $Output } | Should -Throw '*Cannot start worker*'
        $State = Get-ServerObjectRunStatus -OutputRoot $Output
        $State.Status | Should -Be Failed
        $State.ErrorMessage | Should -Match 'Cannot start worker'
        Join-Path $State.RunDirectory request.clixml | Should -Not -Exist
    }
    It 'Encrypts the temporary credential handoff and excludes secrets from process arguments' {
        $Credential = [pscredential]::new('offline-admin', (ConvertTo-SecureString 'offline-test-password' -AsPlainText -Force))
        Mock Start-Process {
            $Request = Get-ChildItem -LiteralPath $Output -Recurse -Filter request.clixml
            $Text = Get-Content -LiteralPath $Request.FullName -Raw
            $Text | Should -Not -Match 'offline-test-password'
            $Imported = Import-Clixml -LiteralPath $Request.FullName
            $Imported.Parameters.SqlCredentials['VM-Objects'].GetNetworkCredential().Password | Should -BeExactly 'offline-test-password'
            $Command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            $Command | Should -Not -Match 'offline-admin|offline-test-password|SqlCredentials'
            throw 'Verified encrypted handoff'
        }
        { Start-ServerObjectBackgroundRun -Items $Items -ScriptsPath $FixtureScripts -OutputRoot $Output `
            -SqlCredentials @{ 'VM-Objects' = $Credential } } | Should -Throw '*Verified encrypted handoff*'
    }
    It 'Reports interrupted processes explicitly and rejects unknown item selectors' {
        $Directory = Join-Path $Output run
        $null = New-ServerObjectRunDirectory -Path $Directory
        Write-ServerObjectRunState -Directory $Directory -Status Running
        $StateFile = Join-Path $Directory run.json
        $State = Get-Content $StateFile -Raw | ConvertFrom-Json
        $State.ProcessStartedUtc = '2000-01-01T00:00:00.0000000Z'
        $State | ConvertTo-Json | Set-Content $StateFile
        $Results = @(New-ServerObjectItemResult -Item $Items[0] -RunRoot $Directory -RunId run -Status Running)
        Write-ServerObjectJsonResult -Path (Join-Path $Directory results.json) -Started ([datetime]::UtcNow) -Results $Results -Running
        $Status = Get-ServerObjectRunStatus -OutputRoot $Output -ItemId VM-Objects
        $Status.Status | Should -Be Interrupted
        $Status.ErrorMessage | Should -Match 'Verify target SQL state'
        { Get-ServerObjectRunStatus -OutputRoot $Output -ItemId Missing } | Should -Throw '*not part of this run*'
    }
    It 'Pins monitoring to one run and waits until the complete run finishes' {
        $script:Poll = 0
        Mock Start-Sleep {}
        Mock Get-ServerObjectRunStatus {
            $script:Poll++
            [pscustomobject]@{ Status = $(if ($script:Poll -eq 1) { 'Running' } else { 'Succeeded' })
                RunDirectory = 'pinned-run'; Results = @(); ErrorMessage = '' }
        }
        (Watch-ServerObjectRun -OutputRoot $Output -MonitorIntervalSeconds 1).Status | Should -Be Succeeded
        Should -Invoke Start-Sleep -Times 1 -Exactly
        Should -Invoke Get-ServerObjectRunStatus -Times 1 -Exactly -ParameterFilter { $RunDirectory -eq 'pinned-run' }
    }
}

Describe 'Snapshot container privacy and runtime creation' -Tag 'Unit' {
    BeforeAll {
        function Get-AzContext { [CmdletBinding()]param() throw 'Unmocked Azure call' }
        function Set-AzContext { [CmdletBinding(SupportsShouldProcess)]param($TenantId, $SubscriptionId, $Scope) throw 'Unmocked Azure call' }
        function Get-AzStorageAccount { [CmdletBinding()]param($ResourceGroupName, $Name) throw 'Unmocked Azure call' }
        function New-AzStorageContext { [CmdletBinding()]param($StorageAccountName, [switch]$UseConnectedAccount) throw 'Unmocked Azure call' }
        function Get-AzStorageContainer { [CmdletBinding()]param($Context) throw 'Unmocked Azure call' }
        function New-AzStorageContainer { [CmdletBinding()]param($Name, $Context, $Permission) throw 'Unmocked Azure call' }
    }
    BeforeEach {
        $Item = Read-ServerObjectItems -Path $OperationalConfig -ItemId VM-Objects
        Mock Import-Module {}
        Mock Get-AzContext { [pscustomobject]@{ Tenant = @{ Id = 'b7d7daca-8689-49f9-8a9b-d20adf81c78b' } } }
        Mock Set-AzContext {}
        Mock Get-AzStorageAccount { [pscustomobject]@{} }
        Mock New-AzStorageContext { [pscustomobject]@{} }
        Mock Get-AzStorageContainer {
            [pscustomobject]@{ Name = 'source-instance-sqlobjects-sqlvm'; PublicAccess = 'Off'; BlobContainerClient = [pscustomobject]@{ Marker = 'private' } }
        }
        Mock New-AzStorageContainer {
            [pscustomobject]@{ Name = 'source-instance-sqlobjects-sqlvm'; PublicAccess = 'Off'; BlobContainerClient = [pscustomobject]@{ Marker = 'created' } }
        }
        Mock Write-Warning {}
    }
    It 'Uses the connected Azure account without requesting account keys' {
        (Get-ServerObjectStorage -Item $Item).Marker | Should -Be private
        Should -Invoke New-AzStorageContext -Times 1 -Exactly -ParameterFilter { $UseConnectedAccount }
        Should -Invoke New-AzStorageContainer -Times 0 -Exactly
    }
    It 'Refuses an already-public container instead of silently changing permissions' {
        Mock Get-AzStorageContainer { [pscustomobject]@{ Name = 'source-instance-sqlobjects-sqlvm'; PublicAccess = 'Blob' } }
        { Get-ServerObjectStorage -Item $Item -Create } | Should -Throw '*must be private*'
        Should -Invoke New-AzStorageContainer -Times 0 -Exactly
    }
    It 'Does not create a missing container during read-only checks' {
        Mock Get-AzStorageContainer { @() }
        Get-ServerObjectStorage -Item $Item | Should -BeNullOrEmpty
        Should -Invoke New-AzStorageContainer -Times 0 -Exactly
    }
    It 'Creates only an authorized missing private container without unsupported confirmation parameters' {
        Mock Get-AzStorageContainer { @() }
        (Get-ServerObjectStorage -Item $Item -Create).Marker | Should -Be created
        Should -Invoke New-AzStorageContainer -Times 1 -Exactly -ParameterFilter { $Permission -eq 'Off' }
    }
    It 'Surfaces container creation failures without reporting a completed upload' {
        Mock Get-AzStorageContainer { @() }
        Mock New-AzStorageContainer { throw 'Container creation denied' }
        { Get-ServerObjectStorage -Item $Item -Create } | Should -Throw '*Container creation denied*'
        Should -Invoke New-AzStorageContainer -Times 1 -Exactly -ParameterFilter { $Permission -eq 'Off' }
    }
    It 'Refuses missing containers when creation is disabled or when replaying' -ForEach @(
        @{ Replay = $false }, @{ Replay = $true }
    ) {
        Mock Get-AzStorageContainer { @() }
        if ($Replay) { $Item.Activity = 'Execute' } else { $Item.CreateContainerIfMissing = $false }
        { Get-ServerObjectStorage -Item $Item -Create } | Should -Throw '*does not exist*'
        Should -Invoke New-AzStorageContainer -Times 0 -Exactly
    }
    It 'Surfaces storage access errors without creating a fallback container' {
        Mock Get-AzStorageContainer { throw 'Storage access denied' }
        { Get-ServerObjectStorage -Item $Item -Create } | Should -Throw '*Storage access denied*'
        Should -Invoke New-AzStorageContainer -Times 0 -Exactly
    }
    It 'Requires the configured tenant instead of initiating an interactive Azure login' {
        Mock Get-AzContext { [pscustomobject]@{ Tenant = @{ Id = 'wrong' } } }
        { Get-ServerObjectStorage -Item $Item } | Should -Throw '*Authenticate to tenant*'
        Should -Invoke Get-AzStorageAccount -Times 0 -Exactly
    }
}

Describe 'Provisioning worker target settings' -Tag 'Unit' {
    BeforeAll {
        $StubScripts = Join-Path $TestDrive 'provisioning-stub'
        $null = [IO.Directory]::CreateDirectory($StubScripts)
        @'
[CmdletBinding(SupportsShouldProcess)]
param($ConfigPath, $SqlPort, $OutputRoot, [switch]$ServerOnly,
    [bool]$TargetTrustServerCertificate, [switch]$UseWindowsAuthentication, $TargetSqlAuthType, [pscredential]$SqlCredential)
@{ Port = $SqlPort; Trust = $TargetTrustServerCertificate; Windows = [bool]$UseWindowsAuthentication
    AuthType = $TargetSqlAuthType; CredentialUser = if ($SqlCredential) { $SqlCredential.UserName } else { '' }
    ServerOnly = [bool]$ServerOnly; Rows = @((Get-Content $ConfigPath -Raw | ConvertFrom-Json).Items).Count } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputRoot 'worker-settings.json')
'@ | Set-Content -LiteralPath (Join-Path $StubScripts 'Invoke-ProvisionLogins-AzSql.ps1')
    }
    It 'Forwards trust=<Trust> and the correct authentication to <Id>' -ForEach @(
        @{ Id = 'VM-Objects'; Trust = $true; Windows = $true; Port = 1433 },
        @{ Id = 'MI-Objects'; Trust = $false; Windows = $false; Port = 3342 }
    ) {
        $Item = Read-ServerObjectItems -Path $OperationalConfig -ItemId $Id
        $Item.TargetTrustServerCertificate = $Trust
        $Item.SQLLoginsMigrationScope = 'Server'
        $Root = Join-Path $TestDrive $Id
        $null = [IO.Directory]::CreateDirectory($Root)
        Invoke-ServerObjectProvisioning -Item $Item -Root $Root -ScriptsPath $StubScripts
        $Settings = Get-Content -LiteralPath (Join-Path $Root 'worker-settings.json') -Raw | ConvertFrom-Json
        $Settings.Trust | Should -Be $Trust
        $Settings.Windows | Should -Be $Windows
        $Settings.Port | Should -Be $Port
        $Settings.ServerOnly | Should -BeTrue
        $Settings.Rows | Should -BeGreaterThan 0
        Test-Path -LiteralPath (Join-Path $Root 'provision.config.json') | Should -BeFalse
    }
    It 'Forwards SQL credentials and disables integrated authentication on <Id>' -ForEach @(
        @{ Id = 'VM-Objects' }, @{ Id = 'MI-Objects' }
    ) {
        $Item = Read-ServerObjectItems -Path $OperationalConfig -ItemId $Id
        $Item.TargetSqlAuthType = 'SqlLogin'
        $Credential = [pscredential]::new('offline-admin', (ConvertTo-SecureString 'offline-test-password' -AsPlainText -Force))
        $Root = Join-Path $TestDrive "$Id-sql"
        $null = [IO.Directory]::CreateDirectory($Root)
        Invoke-ServerObjectProvisioning -Item $Item -Root $Root -ScriptsPath $StubScripts -SqlCredential $Credential
        $Settings = Get-Content -LiteralPath (Join-Path $Root 'worker-settings.json') -Raw | ConvertFrom-Json
        $Settings.AuthType | Should -Be SqlLogin
        $Settings.Windows | Should -BeFalse
        $Settings.CredentialUser | Should -BeExactly 'offline-admin'
    }
}

Describe 'Provisioning SqlClient connections' -Tag 'Unit' {
    BeforeAll {
        $Tokens = $null; $Errors = $null
        $Ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Scripts 'Invoke-ProvisionLogins-AzSql.ps1'), [ref]$Tokens, [ref]$Errors)
        $Functions = @($Ast.FindAll({
            param($Node)
            $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $Node.Name -in @('Invoke-SqlNonQuery', 'Invoke-SqlScalar')
        }, $true))
        . ([scriptblock]::Create(($Functions.Extent.Text -join "`n")))
    }
    BeforeEach {
        $SqlCredential = $null
        $script:TestCommand = [pscustomobject]@{ CommandText = ''; CommandTimeout = 0 }
        $script:TestCommand | Add-Member ScriptMethod ExecuteNonQuery { 1 }
        $script:TestCommand | Add-Member ScriptMethod ExecuteScalar { 42 }
        $script:TestConnection = [pscustomobject]@{ ConnectionString = ''; AccessToken = ''; Credential = $null; Opened = $false
            Disposed = $false; Command = $script:TestCommand; SqlPasswordReadOnly = $false; SqlPasswordMatches = $false }
        $script:TestConnection | Add-Member ScriptMethod Open {
            $this.Opened = $true
            if ($this.Credential) {
                $this.SqlPasswordReadOnly = $this.Credential.Password.IsReadOnly()
                $this.SqlPasswordMatches = [Net.NetworkCredential]::new('', $this.Credential.Password).Password -eq 'offline-test-password'
            }
        }
        $script:TestConnection | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        $script:TestConnection | Add-Member ScriptMethod CreateCommand { $this.Command }
        Mock New-Object { $script:TestConnection } -ParameterFilter { $TypeName -eq 'System.Data.SqlClient.SqlConnection' }
    }
    It 'Runs <Function> using valid keywords with Windows=<Windows> and trust=<Trust>' -ForEach @(
        @{ Function = 'Invoke-SqlNonQuery'; Windows = $false; Trust = $false },
        @{ Function = 'Invoke-SqlNonQuery'; Windows = $true; Trust = $true },
        @{ Function = 'Invoke-SqlNonQuery'; Windows = $true; Trust = $false },
        @{ Function = 'Invoke-SqlNonQuery'; Windows = $false; Trust = $true },
        @{ Function = 'Invoke-SqlScalar'; Windows = $false; Trust = $false },
        @{ Function = 'Invoke-SqlScalar'; Windows = $true; Trust = $true },
        @{ Function = 'Invoke-SqlScalar'; Windows = $true; Trust = $false },
        @{ Function = 'Invoke-SqlScalar'; Windows = $false; Trust = $true }
    ) {
        $UseWindowsAuthentication = $Windows
        $TargetTrustServerCertificate = $Trust
        $Output = & $Function -ServerName 'target.example' -Port 3342 -Database 'master' -AccessToken 'offline-token' -Sql 'SELECT 42;'
        $Builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($script:TestConnection.ConnectionString)
        $Builder['Data Source'] | Should -Be 'tcp:target.example,3342'
        $Builder['Initial Catalog'] | Should -Be master
        $Builder['Encrypt'] | Should -BeTrue
        $Builder['TrustServerCertificate'] | Should -Be $Trust
        $Builder['Integrated Security'] | Should -Be $Windows
        $Builder['Connect Timeout'] | Should -Be 30
        $script:TestConnection.Opened | Should -BeTrue
        $script:TestConnection.Disposed | Should -BeTrue
        $script:TestConnection.AccessToken | Should -Be $(if ($Windows) { '' } else { 'offline-token' })
        $script:TestCommand.CommandTimeout | Should -Be 120
        $script:TestCommand.CommandText | Should -Be 'SELECT 42;'
        if ($Function -eq 'Invoke-SqlScalar') { $Output | Should -Be 42 }
        else { $Output | Should -BeNullOrEmpty }
    }
    It 'Runs <Function> with a read-only SQL credential instead of integrated authentication or a token' -ForEach @(
        @{ Function = 'Invoke-SqlNonQuery' }, @{ Function = 'Invoke-SqlScalar' }
    ) {
        $SqlCredential = [pscredential]::new('offline-admin', (ConvertTo-SecureString 'offline-test-password' -AsPlainText -Force))
        $UseWindowsAuthentication = $false
        $TargetTrustServerCertificate = $false
        $Output = & $Function -ServerName target -Port 1433 -Database master -AccessToken '' -Sql 'SELECT 42;'
        $Builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($script:TestConnection.ConnectionString)
        $Builder['Integrated Security'] | Should -BeFalse
        $Builder['Password'] | Should -BeNullOrEmpty
        $script:TestConnection.AccessToken | Should -BeNullOrEmpty
        $script:TestConnection.Credential.UserId | Should -BeExactly 'offline-admin'
        $script:TestConnection.SqlPasswordReadOnly | Should -BeTrue
        $script:TestConnection.SqlPasswordMatches | Should -BeTrue
        $script:TestConnection.Disposed | Should -BeTrue
        $SqlCredential.GetNetworkCredential().Password | Should -BeExactly 'offline-test-password'
        $script:TestCommand.CommandTimeout | Should -Be 120
        $script:TestCommand.CommandText | Should -Be 'SELECT 42;'
        if ($Function -eq 'Invoke-SqlScalar') { $Output | Should -Be 42 }
        else { $Output | Should -BeNullOrEmpty }
    }
    It 'Reports SQL connection failures with safe endpoint diagnostics for <Function>' -ForEach @(
        @{ Function = 'Invoke-SqlNonQuery' }, @{ Function = 'Invoke-SqlScalar' }
    ) {
        $UseWindowsAuthentication = $false
        $TargetTrustServerCertificate = $false
        $script:TestConnection | Add-Member ScriptMethod Open { throw 'Simulated connection failure' } -Force
        $Failure = $null
        try { & $Function -ServerName target.example -Port 3342 -Database master -AccessToken 'TOKEN_MUST_NOT_APPEAR' -Sql 'SQL_MUST_NOT_APPEAR' }
        catch { $Failure = $_ }
        $Failure.Exception.Message | Should -Match "ServerInstance='target.example,3342'; Database='master'"
        $Failure.Exception.Message | Should -Match 'Encrypt=True; TrustServerCertificate=False'
        $Failure.Exception.Message | Should -Match 'Simulated connection failure'
        $Failure.Exception.Message | Should -Not -Match 'TOKEN_MUST_NOT_APPEAR|SQL_MUST_NOT_APPEAR'
        $script:TestConnection.Disposed | Should -BeTrue
    }
}

Describe 'Private provisioning business logic' -Tag 'Unit' {
    BeforeAll {
        $Tokens = $null; $Errors = $null
        $Ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Scripts 'Invoke-ProvisionLogins-AzSql.ps1'), [ref]$Tokens, [ref]$Errors)
        $Errors.Count | Should -Be 0
        $Names = @('Quote-SqlIdentifier', 'Quote-SqlString', 'Invoke-SqlNonQuery', 'Invoke-SqlScalar', 'New-OrUpdate-SqlLogin', 'Ensure-ExternalLogin', 'Ensure-DatabaseUserAndAccess')
        $Functions = @($Ast.FindAll({
            param($Node)
            $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -in $Names
        }, $true))
        . ([scriptblock]::Create(($Functions.Extent.Text -join "`n")))
    }
    BeforeEach {
        Mock Invoke-SqlNonQuery {}
        Mock Invoke-SqlScalar { 1 }
    }
    It 'Accepts an empty SQL token for Windows authentication and does not reset existing passwords' {
        New-OrUpdate-SqlLogin -ServerName target -Port 1433 -AccessToken '' -LoginName dbmigration `
            -Password 'offline-test-value' -ResetIfExists:$false | Should -Be AlreadyExists
        Should -Invoke Invoke-SqlNonQuery -Times 0 -Exactly
    }
    It 'Creates a missing SQL login using an escaped runtime password without emitting SQL' {
        Mock Invoke-SqlScalar { 0 } -ParameterFilter { $Sql -like '*FROM sys.sql_logins*' }
        $Result = New-OrUpdate-SqlLogin -ServerName target -Port 1433 -AccessToken '' -LoginName 'reader]login' `
            -Password "offline'test" -ResetIfExists:$false
        $Result | Should -Be Created
        Should -Invoke Invoke-SqlNonQuery -Times 1 -Exactly -ParameterFilter {
            $Sql.Contains("PASSWORD = N'offline''test'") -and $Sql.Contains('[reader]]login]')
        }
    }
    It 'Rejects a conflicting existing database-user SID/type before granting access' {
        Mock Invoke-SqlScalar { 0 } -ParameterFilter { $Sql -like '*sid = SUSER_SID*' }
        { Ensure-DatabaseUserAndAccess -ServerName target -Port 1433 -Database app -AccessToken '' `
            -LoginName dbmigration -AccessTypes db_datareader } | Should -Throw '*SID/type conflict*'
        Should -Invoke Invoke-SqlNonQuery -Times 0 -Exactly
    }
    It 'Leaves already mapped users and existing role memberships unchanged' {
        $Result = Ensure-DatabaseUserAndAccess -ServerName target -Port 3342 -Database app -AccessToken 'offline-token' `
            -LoginName dbmigration -AccessTypes db_datareader
        $Result.UserAction | Should -Be AlreadyExists
        $Result.AccessActions[0].Action | Should -Be AlreadyAssigned
        Should -Invoke Invoke-SqlNonQuery -Times 0 -Exactly
    }
    It 'Resets only a SQL login whose individual reset setting is true' {
        New-OrUpdate-SqlLogin -ServerName target -Port 3342 -AccessToken 'offline-token' -LoginName dbtestuser `
            -Password 'offline-test-value' -ResetIfExists:$true | Should -Be PasswordReset
        Should -Invoke Invoke-SqlNonQuery -Times 1 -Exactly -ParameterFilter { $Sql -like '*ALTER LOGIN [dbtestuser]*' -or $Sql.Contains('ALTER LOGIN [dbtestuser]') }
    }
    It 'Rejects a SQL login name already used by a non-SQL principal' {
        Mock Invoke-SqlScalar { 0 } -ParameterFilter { $Sql -like "*type <> 'S'*" }
        { New-OrUpdate-SqlLogin -ServerName target -Port 1433 -AccessToken '' -LoginName conflict `
            -Password 'offline-test-value' -ResetIfExists:$false } | Should -Throw '*not a SQL login*'
        Should -Invoke Invoke-SqlNonQuery -Times 0 -Exactly
    }
    It 'Accepts an already matching external principal of type <PrincipalType>' -ForEach @(
        @{ PrincipalType = 'E' }, @{ PrincipalType = 'X' }
    ) {
        Ensure-ExternalLogin -ServerName target -Port 3342 -AccessToken 'offline-token' -LoginName 'external]name' `
            -ObjectId 'ec787112-0f22-4785-89a5-cb9ee4807a96' -PrincipalType $PrincipalType | Should -Be AlreadyExists
        Should -Invoke Invoke-SqlNonQuery -Times 0 -Exactly
        Should -Invoke Invoke-SqlScalar -Times 1 -Exactly -ParameterFilter {
            $Sql.Contains("type = '$PrincipalType'") -and $Sql.Contains('sid = 0x127178EC220F854789A5CB9EE4807A96')
        }
    }
    It 'Creates an external login and verifies its identity before any database grants' {
        Mock Invoke-SqlScalar { 0 } -ParameterFilter { $Sql -notlike '*AND sid =*' }
        Ensure-ExternalLogin -ServerName target -Port 1433 -AccessToken '' -LoginName 'external]name' `
            -ObjectId 'ec787112-0f22-4785-89a5-cb9ee4807a96' | Should -Be Created
        Should -Invoke Invoke-SqlNonQuery -Times 1 -Exactly -ParameterFilter { $Sql -eq 'CREATE LOGIN [external]]name] FROM EXTERNAL PROVIDER;' }
    }
    It 'Fails for an external identity mismatch without granting access' {
        Mock Invoke-SqlScalar { 0 } -ParameterFilter { $Sql -like '*AND sid =*' }
        { Ensure-ExternalLogin -ServerName target -Port 1433 -AccessToken '' -LoginName 'external' `
            -ObjectId 'ec787112-0f22-4785-89a5-cb9ee4807a96' } | Should -Throw '*different type or ObjectId/SID*'
        Should -Invoke Invoke-SqlNonQuery -Times 0 -Exactly
    }
    It 'Validates database users against the appropriate external principal type <PrincipalType>' -ForEach @(
        @{ PrincipalType = 'E' }, @{ PrincipalType = 'X' }
    ) {
        $null = Ensure-DatabaseUserAndAccess -ServerName target -Port 3342 -Database app -AccessToken 'offline-token' `
            -LoginName external -AccessTypes @() -PrincipalType $PrincipalType
        Should -Invoke Invoke-SqlScalar -Times 1 -Exactly -ParameterFilter { $Sql.Contains("type = '$PrincipalType'") }
        Should -Invoke Invoke-SqlNonQuery -Times 0 -Exactly
    }
}
