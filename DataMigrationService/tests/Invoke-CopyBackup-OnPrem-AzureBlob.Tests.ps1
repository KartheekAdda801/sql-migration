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
        'Get-LogsAfter', 'Update-CheckLatestBakReport', 'Confirm-ContainerExists', 'Invoke-AzCopyUpload')
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
            BackupStorageAccountName = 'demostorage'; BackupContainerName = 'demo-container'
        })
    }
    It 'Uses exactly the requested reference header order and preserves demo values' {
        $Rows = @((Read-ServiceConfiguration -Path (Join-Path $ServiceRoot 'config\Invoke-CopyBackup-OnPrem-AzureBlob.config.json')).Items)
        ($Rows[0].PSObject.Properties.Name -join ',') |
            Should -Be 'SrcServerName,SrcDatabaseName,BackupRootPath,IsActive,BackupStorageAccountName,BackupContainerName'
        $Rows | Should -HaveCount 1
        foreach ($Row in $Rows) {
            $Row.SrcServerName | Should -Be 'DESKTOP-SGA61QP\DMF'
            $Row.BackupRootPath | Should -Be ('C:\Backups\DESKTOP-SGA61QP$DMF\' + $Row.SrcDatabaseName)
            $Row.IsActive | Should -Be 'Y'
            $Row.BackupStorageAccountName | Should -Be 'akpersonalsa'
            $Shared = Read-ServiceConfiguration -Path (Join-Path $ServiceRoot 'config\Invoke-RestoreDMS.config.json')
            $Shared.Items = @($Shared.Items | Where-Object TargetType -eq 'SQLMI')
            $Shared.Common.Activity = 'Restore'
            $Restore = @(Resolve-DMSConfigurationItems -Configuration $Shared |
                Where-Object SrcDatabaseName -eq $Row.SrcDatabaseName)
            $Restore | Should -HaveCount 1
            $Row.BackupContainerName | Should -Be $Restore[0].BackupStorageContainerName
        }
    }
    It 'Accepts the renamed input schema' {
        { . $ValidateMetadata } | Should -Not -Throw
    }
    It 'Allows container derivation when the optional column is omitted' {
        $Metadata = @($Metadata[0] | Select-Object SrcServerName, SrcDatabaseName, BackupRootPath, IsActive, BackupStorageAccountName)
        { . $ValidateMetadata } | Should -Not -Throw
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

Describe 'Renamed fields in availability and upload processing' -Tag 'Unit' {
    BeforeEach {
        $Root = Join-Path $TestDrive 'backups'
        $LogDirectory = Join-Path $TestDrive 'logs'
        $null = New-Item -ItemType Directory -Path (Join-Path $Root 'full') -Force
        $Backup = New-Item -ItemType File -Path (Join-Path $Root 'full\AppDb_20261019_010000.bak') -Force
        $Metadata = @([pscustomobject][ordered]@{
            SrcServerName = 'source\instance'; SrcDatabaseName = 'AppDb'
            BackupRootPath = $Root; IsActive = 'Y'
            BackupStorageAccountName = 'demostorage'; BackupContainerName = 'demo-container'
        })
        $CheckLatestBak = 'N'
        $Overwrite = 'false'
        $TimestampPattern = ''; $TimestampFormat = ''
        [switch]$IncludeLogsAtSameTimestamp = $false
        Mock Confirm-ContainerExists {}
        Mock Invoke-AzCopyUpload {
            param($SourcePath)
            [pscustomobject]@{ SourcePath = $SourcePath; Status = 'Success'; ErrorMessage = '' }
        }
    }
    It 'Uploads from BackupRootPath to the configured destination and preserves report fields' {
        . $ValidateMetadata
        . $ProcessUploads
        Should -Invoke Invoke-AzCopyUpload -Times 1 -Exactly -ParameterFilter {
            $SourcePath -eq $Backup.FullName -and $DestBaseUrl -eq 'https://demostorage.blob.core.windows.net/demo-container'
        }
        $ReportEntries | Should -HaveCount 1
        $ReportEntries[0].ServerName | Should -Be 'source\instance'
        $ReportEntries[0].DatabaseName | Should -Be 'AppDb'
        $ReportEntries[0].RootPath | Should -Be $Root
        $ReportEntries[0].StorageAccountName | Should -Be 'demostorage'
        $ReportEntries[0].ContainerName | Should -Be 'demo-container'
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
    It 'Derives a container from SrcServerName and SrcDatabaseName when omitted' {
        $Metadata[0].PSObject.Properties.Remove('BackupContainerName')
        . $ValidateMetadata
        . $ProcessUploads
        Should -Invoke Confirm-ContainerExists -Times 1 -Exactly -ParameterFilter {
            $ContainerUrl -eq 'https://demostorage.blob.core.windows.net/source-instance-appdb'
        }
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
