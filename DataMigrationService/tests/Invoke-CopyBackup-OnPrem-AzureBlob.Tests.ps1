#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    $ServiceRoot = Split-Path $PSScriptRoot -Parent
    $ScriptPath = Join-Path $ServiceRoot 'scripts\Invoke-CopyBackup-OnPrem-AzureBlob.ps1'
    . (Join-Path $ServiceRoot 'scripts\Common\Migration.Helpers.ps1')
    $Tokens = $null; $Errors = $null
    $Ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$Tokens, [ref]$Errors)
    if ($Errors.Count) { throw $Errors[0] }
    $Functions = @('Get-TimestampFromName', 'Get-LatestByFolderAndExt', 'Get-LatestDiffAfter',
        'Get-LogsAfter', 'Update-CheckLatestBakReport', 'Confirm-ContainerExists', 'Test-BlobExists', 'Invoke-AzCopyUpload')
    . ([scriptblock]::Create(($Ast.FindAll({
        param($Node)
        $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -in $Functions
    }, $true).Extent.Text -join "`n")))
    $Source = $Ast.Extent.Text
    $ValidationStart = $Source.IndexOf('$requiredColumns =')
    $ValidationEnd = $Source.IndexOf('# ------------------------ AzCopy authentication')
    if ($ValidationStart -lt 0 -or $ValidationEnd -le $ValidationStart) { throw 'CSV validation block not found.' }
    $ValidateMetadata = [scriptblock]::Create($Source.Substring($ValidationStart, $ValidationEnd - $ValidationStart))
    $UploadStatement = $Ast.Find({
        param($Node)
        $Node -is [Management.Automation.Language.IfStatementAst] -and
        $Node.Clauses[0].Item1.Extent.Text -eq "`$CheckLatestBak -ne 'Y'"
    }, $true)
    if (-not $UploadStatement) { throw 'Upload processing block not found.' }
    $ProcessUploads = [scriptblock]::Create($UploadStatement.Extent.Text)
    function Write-Log { param($Message, $Level) }
}

Describe 'Backup-copy reference schema' -Tag 'Unit' {
    BeforeEach {
        $Metadata = @([pscustomobject][ordered]@{
            SrcServerName = 'source\instance'; SrcDatabaseName = 'AppDb'
            BackupRootPath = $TestDrive; IsActive = 'N'
            BackupStorageAccountName = 'demostorage'
        })
    }
    It 'Exposes source mappings without configurable containers and matches both restore targets' {
        $Rows = @((Read-ServiceConfiguration -Path (Join-Path $ServiceRoot 'config\Invoke-CopyBackup-OnPrem-AzureBlob.config.json')).Items)
        ($Rows[0].PSObject.Properties.Name -join ',') |
            Should -Be 'SrcServerName,SrcDatabaseName,BackupRootPath,IsActive,BackupStorageAccountName'
        # Inspect the public source mapping independently of executor-specific authentication settings.
        $Shared = Get-Content -LiteralPath (Join-Path $ServiceRoot 'config\Invoke-RestoreDMS.config.json') -Raw | ConvertFrom-Json
        $Restore = @($Shared.Items)
        @($Restore.TargetType | Sort-Object -Unique) | Should -Be @('SQLMI', 'SQLVM')
        foreach ($Item in $Restore) {
            $Row = $Rows | Where-Object { $_.SrcDatabaseName -eq $Item.SrcDatabaseName -and $_.SrcServerName -eq $Item.SrcServerName }
            $Row | Should -Not -BeNullOrEmpty
            (Get-ContainerName $Row.SrcServerName $Row.SrcDatabaseName) |
                Should -Be (Get-ContainerName $Item.SrcServerName $Item.SrcDatabaseName)
            $Item.PSObject.Properties.Name | Should -Not -Contain 'BackupStorageContainerName'
        }
    }
    It 'Accepts the renamed input schema' {
        { . $ValidateMetadata } | Should -Not -Throw
    }
    It 'Allows container derivation without a container column' {
        $Metadata = @($Metadata[0] | Select-Object SrcServerName, SrcDatabaseName, BackupRootPath, IsActive, BackupStorageAccountName)
        { . $ValidateMetadata } | Should -Not -Throw
    }
    It 'Rejects obsolete explicit and blank container overrides' -ForEach @(
        @{ Value = '' }, @{ Value = 'custom-container' }
    ) {
        $Metadata[0] | Add-Member -NotePropertyName BackupContainerName -NotePropertyValue $Value
        { . $ValidateMetadata } | Should -Throw '*Remove it*SrcServerName/SrcDatabaseName*'
    }
    It 'Rejects old input headers explicitly' {
        $Metadata = @([pscustomobject]@{
            RootPath = $TestDrive; StorageAccountName = 'storage'; ServerName = 'source'; DatabaseName = 'db'; Active = 'Y'
        })
        { . $ValidateMetadata } | Should -Throw '*SrcServerName, SrcDatabaseName, BackupRootPath, IsActive*'
    }
    It 'Rejects the previous storage headers even when the source columns are current' {
        $Metadata = @([pscustomobject]@{
            SrcServerName = 'source'; SrcDatabaseName = 'db'; BackupRootPath = $TestDrive; IsActive = 'N'
            StorageAccountName = 'storage'; ContainerName = 'container'
        })
        { . $ValidateMetadata } | Should -Throw '*BackupStorageAccountName*'
    }
    It 'Rejects a missing renamed required field' -ForEach @(
        @{ Column = 'SrcServerName' }, @{ Column = 'SrcDatabaseName' }, @{ Column = 'BackupRootPath' },
        @{ Column = 'IsActive' }, @{ Column = 'BackupStorageAccountName' }
    ) {
        $Metadata[0].PSObject.Properties.Remove($Column)
        { . $ValidateMetadata } | Should -Throw "*$Column*"
    }
    It 'Rejects invalid IsActive values instead of defaulting to uploads' -ForEach @(
        @{ Value = '' }, @{ Value = 'Yes' }, @{ Value = 'invalid' }
    ) {
        $Metadata[0].IsActive = $Value
        { . $ValidateMetadata } | Should -Throw '*IsActive must be Y or N*'
    }
}

Describe 'AzCopy container creation outcomes' -Tag 'Unit' {
    BeforeAll {
        function Invoke-TestAzCopy { throw 'Unmocked AzCopy' }
    }
    BeforeEach {
        $script:AzCopyExe = 'Invoke-TestAzCopy'
        $script:LogFile = Join-Path $TestDrive 'azcopy.log'
        Mock Write-Host {}
        Mock Write-Log {}
    }
    It 'Accepts successful creation and the explicit existing-container response' -ForEach @(
        @{ Code = 0; Output = 'Created' }
        @{ Code = 1; Output = 'RESPONSE Status: 409 ContainerAlreadyExists' }
    ) {
        Mock Invoke-TestAzCopy { $global:LASTEXITCODE = $Code; $Output }
        { Confirm-ContainerExists -ContainerUrl 'https://demostorage.blob.core.windows.net/source-appdb' } | Should -Not -Throw
        Should -Invoke Invoke-TestAzCopy -Times 1 -Exactly -ParameterFilter {
            $args[0] -eq 'make' -and $args[1] -eq 'https://demostorage.blob.core.windows.net/source-appdb'
        }
    }
    It 'Propagates creation authorization and network failures' -ForEach @(
        @{ Output = 'AuthorizationPermissionMismatch' }
        @{ Output = 'Network connection failed' }
    ) {
        Mock Invoke-TestAzCopy { $global:LASTEXITCODE = 1; $Output }
        { Confirm-ContainerExists -ContainerUrl 'https://demostorage.blob.core.windows.net/source-appdb' } |
            Should -Throw '*could not create container*permissions*'
    }
}

Describe 'Missing-container copy lifecycle' -Tag 'Unit' {
    BeforeAll {
        function Invoke-TestAzCopy { throw 'Unmocked AzCopy' }
        function Get-AzContext { [CmdletBinding()]param() throw 'Unmocked Azure call' }
        function New-AzStorageContext { [CmdletBinding()]param($StorageAccountName, [switch]$UseConnectedAccount) throw 'Unmocked Azure call' }
        function Get-AzStorageContainer { [CmdletBinding()]param($Context) throw 'Unmocked Azure call' }
        function Get-AzStorageBlob { [CmdletBinding()]param($Container, $Context) throw 'Unmocked Azure call' }
    }
    BeforeEach {
        $Root = Join-Path $TestDrive 'backups'
        $LogDirectory = Join-Path $TestDrive 'logs'
        $null = New-Item -ItemType Directory -Path (Join-Path $Root 'full') -Force
        $Backup = New-Item -ItemType File -Path (Join-Path $Root 'full\AppDb_20261019_010000.bak') -Force
        Set-Content -LiteralPath $Backup.FullName -Value 'backup'
        $script:AzCopyExe = 'Invoke-TestAzCopy'
        $script:LogFile = Join-Path $TestDrive 'azcopy.log'
        $script:ContainerReady = $false
        $script:CopySequence = [Collections.Generic.List[string]]::new()
        Mock Write-Log {}
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Import-Module {}
        Mock Get-AzContext { [pscustomobject]@{ Subscription = 'authenticated' } }
        Mock Assert-ServiceTcpEndpoint {}
        Mock New-AzStorageContext { 'connected-context' }
        Mock Get-AzStorageContainer { @() }
        Mock Get-AzStorageBlob { throw 'The destination does not exist until live copy creates it' }
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-TestAzCopy' } } -ParameterFilter { $Name -eq 'azcopy' }
        Mock Invoke-TestAzCopy {
            $script:CopySequence.Add([string]$args[0])
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'make') { $script:ContainerReady = $true }
            elseif ($args[0] -eq 'copy' -and -not $script:ContainerReady) { throw 'Copy started before make' }
            elseif ($args[0] -eq 'list' -and $args[1] -like '*/source*' -and -not $script:ContainerReady) {
                throw 'Preflight must list the account when the destination is missing'
            }
        }
        $CheckLatestBak = 'N'; $Overwrite = 'true'
        $TimestampPattern = ''; $TimestampFormat = ''
        [switch]$IncludeLogsAtSameTimestamp = $false
    }
    It 'Preflights a missing destination then makes and uploads to <Expected>' -ForEach @(
        @{ Server = 'SoUrCe'; Expected = 'source-appdb' }
        @{ Server = 'SoUrCe\InStAnCe'; Expected = 'source-instance-appdb' }
    ) {
        $Metadata = @([pscustomobject]@{
            SrcServerName = $Server; SrcDatabaseName = 'AppDb'; BackupRootPath = $Root
            IsActive = 'Y'; BackupStorageAccountName = 'demostorage'
        })
        $Configuration = [pscustomobject]@{ Items = $Metadata }
        Invoke-DataMigrationPreflight -Operation 'Invoke-CopyBackup-OnPrem-AzureBlob' -Configuration $Configuration `
            -Options @{ CheckLatestBak = 'N' }
        $script:ContainerReady | Should -BeFalse
        . $ValidateMetadata
        . $ProcessUploads
        $script:CopySequence -join ',' | Should -Be 'list,make,list,copy'
        Should -Invoke Invoke-TestAzCopy -Times 1 -Exactly -ParameterFilter {
            $args[0] -eq 'make' -and $args[1] -eq "https://demostorage.blob.core.windows.net/$Expected"
        }
        Should -Invoke Invoke-TestAzCopy -Times 1 -Exactly -ParameterFilter {
            $args[0] -eq 'copy' -and $args[1] -eq $Backup.FullName -and
            $args[2] -eq "https://demostorage.blob.core.windows.net/$Expected"
        }
        $SuccessCount | Should -Be 1
        $FailureCount | Should -Be 0
    }
}

Describe 'Backup upload runtime' -Tag 'Unit' {
    BeforeEach {
        $Root = Join-Path $TestDrive 'backups'
        $LogDirectory = Join-Path $TestDrive 'logs'
        $null = New-Item -ItemType Directory -Path (Join-Path $Root 'full') -Force
        $Backup = New-Item -ItemType File -Path (Join-Path $Root 'full\AppDb_20261019_010000.bak') -Force
        $Metadata = @([pscustomobject][ordered]@{
            SrcServerName = 'source\instance'; SrcDatabaseName = 'AppDb'
            BackupRootPath = $Root; IsActive = 'Y'
            BackupStorageAccountName = 'demostorage'
        })
        $CheckLatestBak = 'N'
        $Overwrite = 'false'
        $TimestampPattern = ''; $TimestampFormat = ''
        [switch]$IncludeLogsAtSameTimestamp = $false
        Mock Write-Log {}
        Mock Confirm-ContainerExists {}
        Mock Invoke-AzCopyUpload {
            param($SourcePath)
            [pscustomobject]@{ SourcePath = $SourcePath; Status = 'Success'; ErrorMessage = '' }
        }
    }
    It 'Uploads from BackupRootPath to the source-derived destination and preserves report fields' {
        . $ValidateMetadata
        . $ProcessUploads
        Should -Invoke Invoke-AzCopyUpload -Times 1 -Exactly -ParameterFilter {
            $SourcePath -eq $Backup.FullName -and $DestBaseUrl -eq 'https://demostorage.blob.core.windows.net/source-instance-appdb'
        }
        $ReportEntries | Should -HaveCount 1
        $ReportEntries[0].ServerName | Should -Be 'source\instance'
        $ReportEntries[0].DatabaseName | Should -Be 'AppDb'
        $ReportEntries[0].RootPath | Should -Be $Root
        $ReportEntries[0].StorageAccountName | Should -Be 'demostorage'
        $ReportEntries[0].ContainerName | Should -Be 'source-instance-appdb'
        $SuccessCount | Should -Be 1
        $FailureCount | Should -Be 0
    }
    It 'Does not upload rows with IsActive=N' {
        $Metadata[0].IsActive = 'N'
        . $ValidateMetadata
        . $ProcessUploads
        Should -Invoke Invoke-AzCopyUpload -Times 0 -Exactly
        Should -Invoke Confirm-ContainerExists -Times 0 -Exactly
        $ReportEntries | Should -HaveCount 0
    }
    It 'Creates the derived container before upload for <Server>' -ForEach @(
        @{ Server = 'SoUrCe'; Expected = 'source-appdb' }
        @{ Server = 'SoUrCe\InStAnCe'; Expected = 'source-instance-appdb' }
    ) {
        $Metadata[0].SrcServerName = $Server
        $script:ContainerReady = $false
        Mock Confirm-ContainerExists { $script:ContainerReady = $true }
        Mock Invoke-AzCopyUpload {
            if (-not $script:ContainerReady) { throw 'Upload preceded container creation' }
            [pscustomobject]@{ SourcePath = $SourcePath; Status = 'Success'; ErrorMessage = '' }
        }
        . $ValidateMetadata
        . $ProcessUploads
        Should -Invoke Confirm-ContainerExists -Times 1 -Exactly -ParameterFilter {
            $ContainerUrl -eq "https://demostorage.blob.core.windows.net/$Expected"
        }
        Should -Invoke Invoke-AzCopyUpload -Times 1 -Exactly -ParameterFilter {
            $DestBaseUrl -eq "https://demostorage.blob.core.windows.net/$Expected"
        }
    }
    It 'Reports creation permission failures and never uploads to an uncreated container' {
        Mock Confirm-ContainerExists { throw 'Container creation denied' }
        $Failure = $null
        try { . $ProcessUploads } catch { $Failure = $_ }
        $Failure.Exception.Message | Should -BeLike '*1 backup-copy row(s) failed*'
        $FailureCount | Should -Be 1
        Should -Invoke Invoke-AzCopyUpload -Times 0 -Exactly
        Should -Invoke Write-Log -Times 1 -ParameterFilter { $Message -like '*Container creation denied*' }
    }
    It 'Reads the renamed fields in availability mode, including inactive rows, without uploading' {
        $Metadata[0].IsActive = 'N'
        $CheckLatestBak = 'Y'
        . $ValidateMetadata
        $ReportEntries = @(Update-CheckLatestBakReport -Metadata $Metadata -LogDirectory $LogDirectory)
        . $ProcessUploads
        $ReportEntries | Should -HaveCount 1
        $ReportEntries[0].LatestFullBak | Should -Be $Backup.Name
        $ReportEntries[0].ServerName | Should -Be 'source\instance'
        $ReportEntries[0].DatabaseName | Should -Be 'AppDb'
        $ReportEntries[0].RootPath | Should -Be $Root
        Should -Invoke Invoke-AzCopyUpload -Times 0 -Exactly
    }
}
