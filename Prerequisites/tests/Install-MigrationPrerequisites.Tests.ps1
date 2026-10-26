#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    Import-Module PowerShellGet -ErrorAction Stop
    . (Join-Path $PSScriptRoot '..\Install-MigrationPrerequisites.ps1')
}

Describe 'Migration prerequisite setup' -Tag 'Unit' {
    BeforeEach {
        Mock Get-Module { [pscustomobject]@{ Name = $Name; Version = [version]'1.0' } }
        Mock Import-Module {}
        Mock Install-Module {}
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Get-Command {
            [pscustomobject]@{
                Parameters = @{ AzureBlobAccountKey = $true; AzureBlobAuthType = $true; AzureBlobIdentityType = $true; AzureBlobContainerName = $true; AzureBlobStorageAccountResourceId = $true }
            }
        }
    }

    It 'checks the SQL VM restore and target-preflight modules without installing' {
        Invoke-MigrationPrerequisiteSetup -Workload SqlVmRestore
        Should -Invoke Import-Module -Times 6 -Exactly
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'SqlServer' }
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Az.SqlVirtualMachine' }
        Should -Invoke Install-Module -Times 0 -Exactly
    }

    It 'does not require the SQL VM module for SQL MI restore' {
        Invoke-MigrationPrerequisiteSetup -Workload SqlMiRestore
        Should -Invoke Import-Module -Times 6 -Exactly
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'SqlServer' }
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Az.Sql' }
        Should -Invoke Import-Module -Times 0 -Exactly -ParameterFilter { $Name -eq 'Az.SqlVirtualMachine' }
    }

    It 'fails check-only mode when a module is missing' {
        Mock Get-Module { @() } -ParameterFilter { $Name -eq 'Az.Accounts' }
        { Invoke-MigrationPrerequisiteSetup -Workload MigrationControl } | Should -Throw '*Az.Accounts*missing*'
        Should -Invoke Install-Module -Times 0 -Exactly
    }

    It 'installs only missing modules for the current user' {
        Mock Get-Module { @() } -ParameterFilter { $Name -eq 'Az.Accounts' }
        Invoke-MigrationPrerequisiteSetup -Workload MigrationControl -Install
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Az.Accounts' -and $Scope -eq 'CurrentUser' -and $Repository -eq 'PSGallery'
        }
    }

    It 'does not install or import missing modules under WhatIf' {
        Mock Get-Module { @() }
        Invoke-MigrationPrerequisiteSetup -Workload SqlVmRestore -Install -WhatIf
        Should -Invoke Install-Module -Times 0 -Exactly
        Should -Invoke Import-Module -Times 0 -Exactly
        Should -Invoke Write-Warning -Times 1 -Exactly
    }

    It 'does not require or install ActiveDirectory for the source snapshot workflow' {
        Mock Get-Module { @() } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        { Invoke-MigrationPrerequisiteSetup -Workload ServerObjects -Install } | Should -Not -Throw
        Should -Invoke Get-Module -Times 0 -Exactly -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Should -Invoke Import-Module -Times 0 -Exactly -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Should -Invoke Install-Module -Times 0 -Exactly
    }

    It 'propagates installation errors' {
        Mock Get-Module { @() }
        Mock Install-Module { throw 'Gallery unavailable' }
        { Invoke-MigrationPrerequisiteSetup -Workload MigrationControl -Install } | Should -Throw '*Gallery unavailable*'
    }

    It 'propagates import errors' {
        Mock Import-Module { throw 'Module import failed' }
        { Invoke-MigrationPrerequisiteSetup -Workload MigrationControl } | Should -Throw '*Module import failed*'
    }

    It 'rejects a DMS version without account-key restore parameters' {
        Mock Get-Command { [pscustomobject]@{ Parameters = @{} } }
        { Invoke-MigrationPrerequisiteSetup -Workload SqlVmRestore } | Should -Throw '*default AccountKey restore flow*No authentication fallback*'
    }
    It 'requires managed-identity parameters for SQL MI without requiring an account-key parameter' {
        Mock Get-Command {
            [pscustomobject]@{ Parameters = @{ AzureBlobAuthType = $true; AzureBlobIdentityType = $true; AzureBlobContainerName = $true; AzureBlobStorageAccountResourceId = $true } }
        }
        { Invoke-MigrationPrerequisiteSetup -Workload SqlMiRestore } | Should -Not -Throw
    }
    It 'rejects a SQL MI command that only supports account keys without falling back' {
        Mock Get-Command {
            [pscustomobject]@{ Parameters = @{ AzureBlobAccountKey = $true; AzureBlobContainerName = $true; AzureBlobStorageAccountResourceId = $true } }
        }
        { Invoke-MigrationPrerequisiteSetup -Workload SqlMiRestore } | Should -Throw '*default ManagedIdentity restore flow*No authentication fallback*'
    }

    It 'reports missing AzCopy for copy workflows' {
        Mock Get-Command { $null }
        { Invoke-MigrationPrerequisiteSetup -Workload BackupUpload } | Should -Throw '*AzCopy is missing*'
    }

    It 'validates AzCopy version <Version> with exit code <ExitCode>' -ForEach @(
        @{ Version = '10.30.0'; ExitCode = 0; Valid = $true }
        @{ Version = '9.0.0'; ExitCode = 0; Valid = $false }
        @{ Version = '10.30.0'; ExitCode = 1; Valid = $false }
    ) {
        $script:AzCopyFixture = Join-Path $TestDrive 'azcopy-fixture.ps1'
        Set-Content -LiteralPath $script:AzCopyFixture -Value "'azcopy version $Version'; `$global:LASTEXITCODE = $ExitCode"
        Mock Get-Command { [pscustomobject]@{ Source = $script:AzCopyFixture } }
        if ($Valid) {
            { Invoke-MigrationPrerequisiteSetup -Workload BackupUpload } | Should -Not -Throw
        }
        else {
            { Invoke-MigrationPrerequisiteSetup -Workload BackupUpload } | Should -Throw '*AzCopy v10+ is required*'
        }
    }

    It 'deduplicates dependencies across all workloads' {
        $script:AzCopyFixture = Join-Path $TestDrive 'azcopy-fixture.ps1'
        Set-Content -LiteralPath $script:AzCopyFixture -Value "'azcopy version 10.30.0'; `$global:LASTEXITCODE = 0"
        Mock Get-Command {
            if ($Name -eq 'azcopy') { return [pscustomobject]@{ Source = $script:AzCopyFixture } }
            [pscustomobject]@{
                Parameters = @{ AzureBlobAccountKey = $true; AzureBlobAuthType = $true; AzureBlobIdentityType = $true; AzureBlobContainerName = $true; AzureBlobStorageAccountResourceId = $true }
            }
        }
        Invoke-MigrationPrerequisiteSetup -Workload All
        Should -Invoke Import-Module -Times 8 -Exactly
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Az.Accounts' }
    }

    It 'includes SQL, Key Vault, and directory dependencies for <Workload>' -ForEach @(
        @{ Workload = 'LoginProvisioning' }, @{ Workload = 'SqlAuthLogins' }
    ) {
        Invoke-MigrationPrerequisiteSetup -Workload $Workload
        Should -Invoke Import-Module -Times 4 -Exactly
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Az.KeyVault' }
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Az.Resources' }
    }
}
