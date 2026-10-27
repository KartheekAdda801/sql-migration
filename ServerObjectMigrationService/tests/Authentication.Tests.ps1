#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Invoke-MigrateServerObjects-OnPrem-AzSQL.ps1')
    $FixtureConfig = Join-Path $PSScriptRoot 'Fixtures\ServerObjects.config.json'
}

Describe 'Config-driven target SQL credentials' -Tag 'Unit' {
    BeforeEach {
        $Directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($Directory)
        $Config = Join-Path $Directory 'objects.config.json'
        Copy-Item -LiteralPath $FixtureConfig -Destination $Config
        $Items = @(Read-ServerObjectItems -Path $Config -Activity Execute)
        foreach ($Item in $Items) {
            $Item.TargetSqlAuthType = 'SqlLogin'
            $Item.credential = 'sql_admin'
        }
        $Credential = [pscredential]::new('offline-admin', (ConvertTo-SecureString 'offline-test-password' -AsPlainText -Force))
        $script:PromptCredential = $Credential
        Mock Get-Credential { $script:PromptCredential }
        Mock Test-DMSInteractiveSession { $true }
    }
    It 'Reads named credentials beside the selected config for both target platforms without prompting' {
        @{ credentials = @{ sql_admin = @{ username = 'offline-admin'; password = 'offline-test-password' } } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Directory 'password.local.json')
        $Resolved = Initialize-ServerObjectSqlCredentials -Items $Items -ConfigPath $Config
        foreach ($Item in $Items) {
            $Resolved[$Item.Id] | Should -BeOfType ([pscredential])
            $Resolved[$Item.Id].UserName | Should -BeExactly 'offline-admin'
            $Resolved[$Item.Id].GetNetworkCredential().Password | Should -BeExactly 'offline-test-password'
            $Item.PSObject.Properties.Name | Should -Not -Contain SqlCredential
        }
        Should -Invoke Get-Credential -Times 0 -Exactly
    }
    It 'Never falls back to a prompt for a missing named entry' {
        '{"credentials":{}}' | Set-Content -LiteralPath (Join-Path $Directory 'password.local.json')
        { Initialize-ServerObjectSqlCredentials -Items $Items -ConfigPath $Config } | Should -Throw '*was not found*'
        Should -Invoke Get-Credential -Times 0 -Exactly
    }
    It 'Reports malformed credential JSON without including its password content' {
        '{"credentials":{"password":"DO_NOT_LOG_THIS",}' | Set-Content -LiteralPath (Join-Path $Directory 'password.local.json')
        $Failure = try { Initialize-ServerObjectSqlCredentials -Items $Items -ConfigPath $Config } catch { $_ }
        $Failure.Exception.Message | Should -Match 'invalid JSON'
        $Failure.Exception.Message | Should -Not -Match DO_NOT_LOG_THIS
    }
    It 'Accepts explicit per-item overrides before consulting a missing named file' {
        $Resolved = Initialize-ServerObjectSqlCredentials -Items $Items -ConfigPath $Config `
            -SqlCredentials @{ 'VM-Objects' = $Credential; 'MI-Objects' = $Credential }
        $Resolved.Count | Should -Be 2
        $Resolved['VM-Objects'] | Should -Be $Credential
        Should -Invoke Get-Credential -Times 0 -Exactly
    }
    It 'Prompts for each endpoint in interactive mode when no named reference is configured' {
        foreach ($Item in $Items) { $Item.credential = ''; $Item.SqlCredentialMode = 'Interactive' }
        $Resolved = Initialize-ServerObjectSqlCredentials -Items $Items -ConfigPath $Config
        $Resolved.Count | Should -Be 2
        Should -Invoke Get-Credential -Times 2 -Exactly
    }
    It 'Stops on interactive cancellation instead of starting workers' {
        $Items[0].credential = ''
        Mock Get-Credential { $null }
        { Initialize-ServerObjectSqlCredentials -Items @($Items[0]) -ConfigPath $Config } | Should -Throw '*canceled*'
    }
    It 'Fails clearly when a noninteractive worker has no configured credential' {
        $Items[0].credential = ''
        Mock Test-DMSInteractiveSession { $false }
        { Initialize-ServerObjectSqlCredentials -Items @($Items[0]) -ConfigPath $Config } | Should -Throw '*No background credential prompt*'
        Should -Invoke Get-Credential -Times 0 -Exactly
    }
    It 'Resolves encrypted credential paths relative to config without modifying the item' {
        $Items[0].credential = ''
        $Items[0].SqlCredentialMode = 'Configured'
        $Items[0].SqlCredentialPath = 'admin.clixml'
        $Credential | Export-Clixml -LiteralPath (Join-Path $Directory 'admin.clixml')
        $Resolved = Initialize-ServerObjectSqlCredentials -Items @($Items[0]) -ConfigPath $Config
        $Resolved['VM-Objects'].UserName | Should -BeExactly 'offline-admin'
        $Items[0].SqlCredentialPath | Should -BeExactly 'admin.clixml'
        Should -Invoke Get-Credential -Times 0 -Exactly
    }
    It 'Never resolves target credentials for Generate even with missing named references' {
        foreach ($Item in $Items) { $Item.Activity = 'Generate'; $Item.ProvisionLogins = $true }
        (Initialize-ServerObjectSqlCredentials -Items $Items -ConfigPath $Config).Count | Should -Be 0
        Should -Invoke Get-Credential -Times 0 -Exactly
    }
    It 'Preserves default Windows VM and Entra MI authentication' {
        $Items = @(Read-ServerObjectItems -Path $Config -Activity Execute)
        (Initialize-ServerObjectSqlCredentials -Items $Items -ConfigPath $Config).Count | Should -Be 0
        $VmAuth = Get-ServerObjectTargetAuth -Item $Items[0]
        $VmAuth.ContainsKey('SqlCredential') | Should -BeFalse
        $VmAuth.ContainsKey('TenantId') | Should -BeFalse
        $MiAuth = Get-ServerObjectTargetAuth -Item $Items[1]
        $MiAuth.TenantId | Should -Be $Items[1].TenantId
        Should -Invoke Get-Credential -Times 0 -Exactly
    }
    It 'Requires resolved credentials for SQL authentication with no platform fallback' {
        { Get-ServerObjectTargetAuth -Item $Items[0] -TargetSqlAuthType SqlLogin } | Should -Throw '*no worker prompt or fallback*'
    }
    It 'Accepts explicit WindowsAD authentication on VM without credentials or Entra tokens' {
        $Json = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
        $Json.Items[0] | Add-Member TargetSqlAuthType WindowsAD
        $Json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Config
        $Vm = @(Read-ServerObjectItems -Path $Config -Activity Execute)[0]
        $Vm.TargetSqlAuthType | Should -Be WindowsAD
        (Initialize-ServerObjectSqlCredentials -Items @($Vm) -ConfigPath $Config).Count | Should -Be 0
        $Auth = Get-ServerObjectTargetAuth -Item $Vm -TargetSqlAuthType $Vm.TargetSqlAuthType
        $Auth.ContainsKey('SqlCredential') | Should -BeFalse
        $Auth.ContainsKey('TenantId') | Should -BeFalse
        Should -Invoke Get-Credential -Times 0 -Exactly
    }
    It 'Rejects the old Windows configuration value with replacement guidance' {
        $Json = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
        $Json.Items[0] | Add-Member TargetSqlAuthType Windows
        $Json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Config
        { Read-ServerObjectItems -Path $Config } | Should -Throw "*Replace TargetSqlAuthType 'Windows' with 'WindowsAD'*"
    }
    It 'Rejects WindowsAD in target authentication resolution for MI' {
        { Get-ServerObjectTargetAuth -Item $Items[1] -TargetSqlAuthType WindowsAD } |
            Should -Throw '*requires a SQLVM target*'
    }
    It 'Rejects WindowsAD authentication on MI while accepting interactive SQL mode in JSON' {
        $Json = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
        $Json.Items[1] | Add-Member TargetSqlAuthType WindowsAD
        $Json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Config
        { Read-ServerObjectItems -Path $Config } | Should -Throw '*Use Entra or SqlLogin*'
        $Json.Items[1].TargetSqlAuthType = 'SqlLogin'
        $Json.Items[1] | Add-Member SqlCredentialMode Interactive
        $Json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Config
        @(Read-ServerObjectItems -Path $Config)[1].SqlCredentialMode | Should -Be Interactive
    }
}
