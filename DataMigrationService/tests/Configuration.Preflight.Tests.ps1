#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    $Workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $DataScripts = Join-Path $PSScriptRoot '..\scripts'
    . (Join-Path $DataScripts 'Common\Migration.Helpers.ps1')
    $Entries = @(
        foreach ($Package in @('DataMigrationService')) {
            Get-ChildItem -LiteralPath (Join-Path $Workspace "$Package\scripts") -Filter '*.ps1' -File |
                Where-Object BaseName -ne 'Invoke-RestoreDMS'
        }
    )
    function Get-EntryGateway {
        param([IO.FileInfo]$File)
        $Tokens = $null; $Errors = $null
        $Ast = [Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$Tokens, [ref]$Errors)
        if ($Errors.Count) { throw $Errors[0] }
        $Source = $Ast.Extent.Text
        $Start = $Source.IndexOf('#region Configuration and preflight')
        $End = $Source.IndexOf('#endregion Configuration and preflight')
        if ($Start -lt 0 -or $End -le $Start) { throw "Missing preflight gateway in '$File'." }
        [scriptblock]::Create(($Ast.ParamBlock.Attributes.Extent.Text -join "`n") + "`n" + $Ast.ParamBlock.Extent.Text + "`n" +
            $Source.Substring($Start, $End - $Start) + "`n`$script:ExecutionStarted = `$true")
    }
    function Invoke-ServerObjectPreflight { [CmdletBinding()]param($Operation, $Configuration, $Options, $ScriptsPath) throw 'Unmocked preflight' }
    function Get-AzContext { [CmdletBinding()]param() throw 'Unmocked Azure call' }
    function Set-AzContext { [CmdletBinding(SupportsShouldProcess)]param($SubscriptionId, $Scope) throw 'Unmocked Azure call' }
    function Get-AzResource { [CmdletBinding()]param($ResourceId, [switch]$ExpandProperties) throw 'Unmocked Azure call' }
    function Get-AzStorageAccountKey { [CmdletBinding()]param($ResourceGroupName, $Name) throw 'Unmocked Azure call' }
    function Get-AzDataMigrationSqlService { [CmdletBinding()]param($Name, $ResourceGroupName) throw 'Unmocked Azure call' }
    function New-AzDataMigrationToSqlManagedInstance {
        [CmdletBinding()]param($AzureBlobAuthType, $AzureBlobIdentityType, $AzureBlobUserAssignedIdentity, $AzureBlobAccountKey)
        throw 'Unexpected mutation'
    }
    function Write-TestConfiguration {
        param([string]$Path, [object[]]$Items = @(), [hashtable]$Settings = @{})
        @{ schemaVersion = 1; Settings = $Settings; Items = @($Items) } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path
    }
    function Get-EntryTestConfigurationPath {
        param([IO.FileInfo]$Entry)
        $Original = Join-Path $Entry.DirectoryName ("..\config\" + $Entry.BaseName + '.config.json')
        if (Test-Path -LiteralPath $Original) { return $Original }
        throw "Missing config for '$($Entry.Name)'."
    }
}

Describe 'Schema-one upload entry configuration contract' -Tag 'Unit' {
    It 'Supplies matching or shared JSON configuration for every entry point, with no CSV configs' {
        $Entries | Should -HaveCount 1
        foreach ($Entry in $Entries) {
            $Folder = Join-Path $Entry.DirectoryName '..\config'
            $Path = Get-EntryTestConfigurationPath -Entry $Entry
            $Configuration = Read-ServiceConfiguration -Path $Path -Operation $Entry.BaseName
            $Command = Get-Command -Name $Entry.FullName
            $Resolved = Resolve-ServiceSettings -Configuration $Configuration -Command $Command -Overrides @{ ConfigPath = $Path }
            $Resolved.Keys.Count | Should -Be $Configuration.Settings.PSObject.Properties.Name.Count
            $Declared = @($Command.ScriptBlock.Ast.ParamBlock.Parameters |
                ForEach-Object { $_.Name.VariablePath.UserPath } | Where-Object { $_ -ne 'ConfigPath' })
            ($Configuration.Settings.PSObject.Properties.Name | Sort-Object) -join ',' |
                Should -Be (($Declared | Sort-Object) -join ',')
            $Command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $Command.Parameters.ContainsKey('LogDirectory') | Should -BeFalse
            @(Get-ChildItem -LiteralPath $Folder -Filter '*.csv').Count | Should -Be 0
        }
    }
    It 'Keeps explicit overrides above JSON settings and keeps omitted options at parameter defaults' {
        $Entry = $Entries | Where-Object BaseName -eq 'Invoke-CopyBackup-OnPrem-AzureBlob'
        $Configuration = [pscustomobject]@{ Settings = [pscustomobject]@{ Overwrite = 'false'; CheckLatestBak = 'N' } }
        $Result = Resolve-ServiceSettings -Configuration $Configuration -Command (Get-Command $Entry.FullName) `
            -Overrides @{ ConfigPath = 'test.json'; Overwrite = 'true' }
        $Result.Overwrite | Should -Be 'true'
        $Result.CheckLatestBak | Should -Be 'N'
        $Result.ContainsKey('TimestampPattern') | Should -BeFalse
    }
    It 'Rejects misspelled options, safety overrides, invalid ranges, and string switches' {
        $Entry = $Entries | Where-Object BaseName -eq 'Invoke-CopyBackup-OnPrem-AzureBlob'
        foreach ($Settings in @(@{ TypoOption = 'x' }, @{ WhatIf = $false }, @{ Confirm = $false },
                @{ CheckLatestBak = 'Invalid' }, @{ Overwrite = 'Invalid' }, @{ IncludeLogsAtSameTimestamp = 'false' })) {
            $Configuration = [pscustomobject]@{ Settings = [pscustomobject]$Settings }
            { Resolve-ServiceSettings -Configuration $Configuration -Command (Get-Command $Entry.FullName) -Overrides @{ ConfigPath = 'test.json' } } |
                Should -Throw
        }
    }
    It 'Preserves explicit false switch overrides instead of falling back to JSON true' {
        $Entry = $Entries | Where-Object BaseName -eq 'Invoke-CopyBackup-OnPrem-AzureBlob'
        $Configuration = [pscustomobject]@{ Settings = [pscustomobject]@{ IncludeLogsAtSameTimestamp = $true } }
        $Result = Resolve-ServiceSettings -Configuration $Configuration -Command (Get-Command $Entry.FullName) -Overrides @{ IncludeLogsAtSameTimestamp = $false }
        $Result.IncludeLogsAtSameTimestamp.IsPresent | Should -BeFalse
    }
    It 'Rejects malformed JSON, wrong schema, unknown root keys, and scalar Items' {
        $Path = Join-Path $TestDrive 'invalid.json'
        foreach ($Text in @('{', '{"Settings":{}}', '{"schemaVersion":1,"Settings":{},"Typo":[]}',
                '{"schemaVersion":1,"Settings":{},"Items":{}}')) {
            Set-Content -LiteralPath $Path -Value $Text
            { Read-ServiceConfiguration -Path $Path } | Should -Throw
        }
    }
}

Describe 'Schema-one upload entry gateway safety' -Tag 'Unit' {
    BeforeEach {
        $script:ExecutionStarted = $false
        Mock Invoke-DataMigrationPreflight {}
        Mock Invoke-ServerObjectPreflight {}
        Mock Write-Host {}
    }
    It 'Runs preflight but never enters the work body or writes output when WhatIf is supplied' {
        foreach ($Entry in $Entries) {
            $Path = Get-EntryTestConfigurationPath -Entry $Entry
            $Gateway = Get-EntryGateway -File $Entry
            $script:ExecutionStarted = $false
            & $Gateway -ConfigPath $Path -WhatIf
            $script:ExecutionStarted | Should -BeFalse -Because $Entry.Name
        }
        Should -Invoke Invoke-DataMigrationPreflight -Times 1 -Exactly
        Should -Invoke Invoke-ServerObjectPreflight -Times 0 -Exactly
        Should -Invoke Invoke-DataMigrationPreflight -Times 1 -Exactly -ParameterFilter {
            $Operation -eq 'Invoke-CopyBackup-OnPrem-AzureBlob' -and $Options.AzCopyPath -like '*azcopy.exe' -and
            $Options.SubscriptionId -eq 'cd7743ef-8ddc-4254-b715-2c79c8ab4126'
        }
    }
    It 'Aborts every entry before its work body when preflight fails' {
        Mock Invoke-DataMigrationPreflight { throw 'Access denied during preflight' }
        Mock Invoke-ServerObjectPreflight { throw 'Access denied during preflight' }
        foreach ($Entry in $Entries) {
            $Path = Get-EntryTestConfigurationPath -Entry $Entry
            $Gateway = Get-EntryGateway -File $Entry
            $script:ExecutionStarted = $false
            { & $Gateway -ConfigPath $Path -Confirm:$false } | Should -Throw '*Access denied during preflight*'
            $script:ExecutionStarted | Should -BeFalse -Because $Entry.Name
        }
    }
    It 'Executes only after successful validation and preserves explicit overrides' {
        $Entry = $Entries | Where-Object BaseName -eq 'Invoke-CopyBackup-OnPrem-AzureBlob'
        $Path = Join-Path $TestDrive 'restore.json'
        Write-TestConfiguration -Path $Path -Settings @{ CheckLatestBak = 'N' }
        $Gateway = Get-EntryGateway -File $Entry
        & $Gateway -ConfigPath $Path -CheckLatestBak Y -Confirm:$false
        $script:ExecutionStarted | Should -BeTrue
        Should -Invoke Invoke-DataMigrationPreflight -Times 1 -Exactly -ParameterFilter {
            $Options.CheckLatestBak -eq 'Y' -and $Options.Overwrite -eq 'true'
        }
    }
}

Describe 'Read-only data-migration preflight' -Tag 'Unit' {
    BeforeEach {
        Mock Import-Module {}
        Mock Get-AzContext { [pscustomobject]@{ Subscription = 'authenticated' } }
        Mock Set-AzContext {}
        Mock Assert-ServiceStorage { [pscustomobject]@{ Name = 'db_20261019_010000.bak' } }
        Mock Assert-ServiceTcpEndpoint {}
        Mock Get-AzResource {
            [pscustomobject]@{ Properties = @{ fullyQualifiedDomainName = 'target.example' }; Identity = @{ PrincipalId = 'identity' } }
        }
        Mock Get-AzDataMigrationSqlService { [pscustomobject]@{ ProvisioningState = 'Succeeded' } }
        Mock Get-AzStorageAccountKey { @([pscustomobject]@{ Value = 'test-key' }) }
        Mock Write-Host {}
        Mock Write-Warning {}
        $Options = @{
            OutputJsonPath = ''; TimestampPattern = ''; TimestampFormat = ''; AzCopyPath = ''
            CheckLatestBak = 'N'; BlobAuthType = 'AccountKey'; BlobIdentityType = 'SystemAssigned'
            BlobUserAssignedIdentity = ''; TargetSqlPort = 1433
        }
        $Shared = Read-ServiceConfiguration -Path (Join-Path $DataScripts '..\config\Invoke-RestoreDMS.config.json')
        $Shared.Common.Activity = 'Restore'
        $Shared.Items = @($Shared.Items | Where-Object TargetType -eq 'SQLMI')
        $Restore = ConvertTo-DMSItemConfiguration -Item @(Resolve-DMSConfigurationItems -Configuration $Shared)[0]
        $Second = $Restore.Items[0] | ConvertTo-Json | ConvertFrom-Json
        $Second.SrcDatabaseName = 'second-db'
        $Second.TrgDatabaseName = 'second-db'
        $Second.BackupStorageContainerName = 'second-db'
        $Restore.Items = @($Restore.Items[0], $Second)
    }
    It 'Checks every restore target before allowing work and rejects a later network failure' {
        foreach ($Item in $Restore.Items) {
            $Item | Add-Member -NotePropertyName TrgSQLVM -NotePropertyValue 'target-vm'
            $Item | Add-Member -NotePropertyName TrgSQLVMResourceGroup -NotePropertyValue 'target-rg'
        }
        Mock Assert-ServiceTcpEndpoint {
            if (++$script:NetworkCalls -eq 2) { throw 'Target network is unavailable' }
        }
        $script:NetworkCalls = 0
        { Invoke-DataMigrationPreflight -Operation 'Restore-SQLVM' -Configuration $Restore -Options $Options } |
            Should -Throw '*Target network is unavailable*'
        Should -Invoke Assert-ServiceStorage -Times 2 -Exactly
        Should -Invoke Assert-ServiceTcpEndpoint -Times 2 -Exactly
    }
    It 'Rejects an invalid later restore row before contacting any resource' {
        $Restore.Items[1].TrgDatabaseName = '<database>'
        { Invoke-DataMigrationPreflight -Operation 'Restore-SQLMI' -Configuration $Restore -Options $Options } |
            Should -Throw '*TrgDatabaseName*'
        Should -Invoke Import-Module -Times 0 -Exactly
        Should -Invoke Get-AzResource -Times 0 -Exactly
    }
    It 'Allows Blob-based <Platform> restores with integration runtime state <RuntimeState>' -ForEach @(
        @{ Platform = 'SQLMI'; RuntimeState = 'Offline' }
        @{ Platform = 'SQLMI'; RuntimeState = $null }
        @{ Platform = 'SQLVM'; RuntimeState = 'Offline' }
        @{ Platform = 'SQLVM'; RuntimeState = $null }
    ) {
        if ($Platform -eq 'SQLVM') {
            foreach ($Item in $Restore.Items) {
                $Item | Add-Member -NotePropertyName TrgSQLVM -NotePropertyValue 'target-vm'
                $Item | Add-Member -NotePropertyName TrgSQLVMResourceGroup -NotePropertyValue 'target-rg'
            }
        }
        Mock Get-AzDataMigrationSqlService {
            [pscustomobject]@{ ProvisioningState = 'Succeeded'; IntegrationRuntimeState = $RuntimeState }
        }
        Invoke-DataMigrationPreflight -Operation "Restore-$Platform" -Configuration $Restore -Options $Options
        Should -Invoke Assert-ServiceTcpEndpoint -Times 2 -Exactly
    }
    It 'Reports missing SQL migration services separately from runtime state' {
        Mock Get-AzDataMigrationSqlService { $null }
        { Invoke-DataMigrationPreflight -Operation 'Restore-SQLMI' -Configuration $Restore -Options $Options } |
            Should -Throw '*DMS SQL service*was not returned*'
        Should -Invoke Assert-ServiceTcpEndpoint -Times 0 -Exactly
    }
    It 'Rejects unsuccessfully provisioned DMS services' {
        Mock Get-AzDataMigrationSqlService { [pscustomobject]@{ ProvisioningState = 'Failed' } }
        { Invoke-DataMigrationPreflight -Operation 'Restore-SQLMI' -Configuration $Restore -Options $Options } |
            Should -Throw '*not successfully provisioned*'
    }
    It 'Rejects a DMS service in a different region' {
        Mock Get-AzDataMigrationSqlService { [pscustomobject]@{ ProvisioningState = 'Succeeded'; Location = 'different-region' } }
        { Invoke-DataMigrationPreflight -Operation 'Restore-SQLMI' -Configuration $Restore -Options $Options } |
            Should -Throw '*Location does not match*'
    }
    It 'Rejects missing target identities and unreadable storage rather than falling back' {
        $Options.BlobAuthType = 'ManagedIdentity'
        Mock Get-AzResource { [pscustomobject]@{ Properties = @{ fullyQualifiedDomainName = 'target.example' }; Identity = @{} } }
        { Invoke-DataMigrationPreflight -Operation 'Restore-SQLMI' -Configuration $Restore -Options $Options } |
            Should -Throw '*identity is not enabled*'
        Mock Assert-ServiceStorage { throw 'Blob access denied' }
        { Invoke-DataMigrationPreflight -Operation 'Restore-SQLMI' -Configuration $Restore -Options $Options } |
            Should -Throw '*Blob access denied*'
    }
    It 'Uses the current Azure context for key retrieval without requiring target identities' {
        Mock Get-AzResource { [pscustomobject]@{ Properties = @{ fullyQualifiedDomainName = 'target.example' }; Identity = @{} } }
        Invoke-DataMigrationPreflight -Operation 'Restore-SQLMI' -Configuration $Restore -Options $Options
        Should -Invoke Get-AzStorageAccountKey -Times 2 -Exactly
    }
    It 'Validates MI system identity without requesting keys even when shared-key access is disabled' {
        $Options.BlobAuthType = 'ManagedIdentity'
        Mock Get-AzResource {
            [pscustomobject]@{
                Properties = @{ fullyQualifiedDomainName = 'target.example'; allowSharedKeyAccess = $false }
                Identity = @{ PrincipalId = 'mi-system-identity' }
            }
        }
        Mock Get-AzStorageAccountKey { throw 'Managed identity must not retrieve account keys' }
        Invoke-DataMigrationPreflight -Operation 'Restore-SQLMI' -Configuration $Restore -Options $Options
        Should -Invoke Get-AzStorageAccountKey -Times 0 -Exactly
        Should -Invoke Assert-ServiceTcpEndpoint -Times 2 -Exactly
        Should -Invoke Write-Warning -Times 0 -Exactly -ParameterFilter { $Message -like '*TEMPORARY TEST BYPASS*' }
    }
    It 'Checks the configured <Platform> hostname and port rather than the resource endpoint or 1433' -ForEach @(
        @{ Platform = 'SQLVM'; HostName = 'vm.custom.example'; Port = 15433 }
        @{ Platform = 'SQLMI'; HostName = 'mi.public.example.database.windows.net'; Port = 3342 }
    ) {
        foreach ($Item in $Restore.Items) {
            $Item.TargetSqlHost = $HostName
            if ($Platform -eq 'SQLVM') {
                $Item | Add-Member -NotePropertyName TrgSQLVM -NotePropertyValue 'target-vm'
                $Item | Add-Member -NotePropertyName TrgSQLVMResourceGroup -NotePropertyValue 'target-rg'
            }
        }
        $Options.TargetSqlPort = $Port
        Invoke-DataMigrationPreflight -Operation "Restore-$Platform" -Configuration $Restore -Options $Options
        Should -Invoke Assert-ServiceTcpEndpoint -Times 2 -Exactly -ParameterFilter {
            $HostName -eq $Restore.Items[0].TargetSqlHost -and $Port -eq $Options.TargetSqlPort
        }
    }
    It 'Stops MI restore preflight on a configured public-endpoint connection failure' {
        $Options.TargetSqlPort = 3342
        Mock Assert-ServiceTcpEndpoint { throw 'Configured MI endpoint is unreachable' }
        { Invoke-DataMigrationPreflight -Operation 'Restore-SQLMI' -Configuration $Restore -Options $Options } |
            Should -Throw '*Configured MI endpoint is unreachable*'
    }
    It 'Rejects missing configured hosts before contacting Azure, even when the resource has a hostname' {
        $Restore.Items[1].TargetSqlHost = ''
        { Invoke-DataMigrationPreflight -Operation 'Restore-SQLMI' -Configuration $Restore -Options $Options } |
            Should -Throw '*TargetSqlHost*'
        Should -Invoke Get-AzResource -Times 0 -Exactly
        Should -Invoke Assert-ServiceTcpEndpoint -Times 0 -Exactly
    }
    It 'Rejects shared-key-disabled storage before retrieving a key' {
        Mock Get-AzResource { [pscustomobject]@{ Properties = @{ allowSharedKeyAccess = $false } } }
        { Invoke-DataMigrationPreflight -Operation 'Restore-SQLMI' -Configuration $Restore -Options $Options } |
            Should -Throw '*Shared-key access is disabled*'
        Should -Invoke Get-AzStorageAccountKey -Times 0 -Exactly
    }
    It 'Rejects empty keys before submitting a migration' {
        Mock Get-AzStorageAccountKey { @() }
        { Invoke-DataMigrationPreflight -Operation 'Restore-SQLMI' -Configuration $Restore -Options $Options } |
            Should -Throw '*No account key*'
    }
    It 'Validates every selected disk or share root before storage or upload work' {
        $Folder = Join-Path $TestDrive 'source\full'
        $null = New-Item -ItemType Directory -Path $Folder -Force
        Set-Content -LiteralPath (Join-Path $Folder 'db_20261019_010000.bak') -Value 'backup'
        $Copy = Read-ServiceConfiguration -Path (Join-Path $DataScripts '..\config\Invoke-CopyBackup-OnPrem-AzureBlob.config.json')
        $Copy.Items += ($Copy.Items[0] | ConvertTo-Json | ConvertFrom-Json)
        $Copy.Items | ForEach-Object { $_.IsActive = 'Y'; $_.BackupRootPath = Split-Path $Folder }
        $Copy.Items[1].BackupRootPath = Join-Path $TestDrive 'missing-share'
        { Invoke-DataMigrationPreflight -Operation 'Invoke-CopyBackup-OnPrem-AzureBlob' -Configuration $Copy -Options $Options } |
            Should -Throw
        Should -Invoke Import-Module -Times 0 -Exactly
        Should -Invoke Assert-ServiceStorage -Times 0 -Exactly
    }
    It 'Stops the real copy gateway when a later container denies access, before entering upload work' {
        $Folder = Join-Path $TestDrive 'copy\full'
        $null = New-Item -ItemType Directory -Path $Folder -Force
        Set-Content -LiteralPath (Join-Path $Folder 'db_20261019_010000.bak') -Value 'backup'
        $Executable = Join-Path $TestDrive 'azcopy.exe'
        Set-Content -LiteralPath $Executable -Value 'offline executable placeholder'
        $Copy = Read-ServiceConfiguration -Path (Join-Path $DataScripts '..\config\Invoke-CopyBackup-OnPrem-AzureBlob.config.json')
        $Second = $Copy.Items[0] | ConvertTo-Json | ConvertFrom-Json
        $Second.SrcDatabaseName = 'CDC_Director_PRO'
        $Second.BackupContainerName = 'desktop-sga61qp-dmf-cdc-director-pro'
        $Copy.Items += $Second
        $Copy.Items | ForEach-Object { $_.IsActive = 'Y'; $_.BackupRootPath = Split-Path $Folder }
        $Path = Join-Path $TestDrive 'copy.json'
        Write-TestConfiguration -Path $Path -Items $Copy.Items -Settings @{ AzCopyPath = $Executable }
        Mock Assert-DataMigrationAzCopyAccess {}
        Mock Assert-ServiceStorage { throw 'Second container access denied' } -ParameterFilter { $Container -like '*cdc-director-pro' }
        $Entry = $Entries | Where-Object BaseName -eq 'Invoke-CopyBackup-OnPrem-AzureBlob'
        $Gateway = Get-EntryGateway -File $Entry
        $script:ExecutionStarted = $false
        { & $Gateway -ConfigPath $Path -Confirm:$false } | Should -Throw '*Second container access denied*'
        $script:ExecutionStarted | Should -BeFalse
        Should -Invoke Assert-ServiceStorage -Times 2 -Exactly
        Should -Invoke Assert-DataMigrationAzCopyAccess -Times 1 -Exactly
    }
}
