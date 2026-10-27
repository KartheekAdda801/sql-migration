#Requires -Modules Pester
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Invoke-RestoreDMS.ps1')
    function Save-AzContext { [CmdletBinding(SupportsShouldProcess)]param($Path, [switch]$Force) throw 'Unmocked Azure context export' }
    function Import-AzContext { [CmdletBinding()]param($Path, $Scope) throw 'Unmocked Azure context import' }
    function Disable-AzContextAutosave { [CmdletBinding()]param($Scope) throw 'Unmocked Azure context change' }
}

Describe 'Process-isolated parallel submissions' -Tag 'Unit' {
    BeforeEach {
        $Config = Read-ServiceConfiguration (Join-Path $PSScriptRoot 'Fixtures\Restore.config.json')
        $Plan = @(New-DMSItemPlan -Items @(Resolve-DMSConfigurationItems $Config))
        Mock Write-DMSPlanResults {}
        Mock Write-Warning {}
    }
    It 'Starts all batch workers concurrently and waits for creation only, not restore completion' {
        $Fixture = Join-Path $TestDrive 'worker.ps1'
        @(
            'function Disable-AzContextAutosave { param($Scope) }'
            'function Import-AzContext { param($Path, $Scope) }'
            'function Start-DMSItemRestore {'
            '[CmdletBinding(SupportsShouldProcess)]param($Entry, $SqlCredential)'
            'if ($SqlCredential -isnot [pscredential] -or $SqlCredential.UserName -ne "test-login") { throw "Credential handoff failed" }'
            '$Directory = Split-Path -Parent $PSCommandPath'
            '[IO.File]::WriteAllText((Join-Path $Directory ($Entry.Item.Id + ".started")), "started")'
            '$Deadline = [datetime]::UtcNow.AddSeconds(30)'
            'while (@(Get-ChildItem -LiteralPath $Directory -Filter "*.started").Count -lt 2) {'
            'if ([datetime]::UtcNow -gt $Deadline) { throw "Workers were not started concurrently" }'
            'Start-Sleep -Milliseconds 50'
            '}'
            '[pscustomobject]@{ Status = "Submitted" }'
            '}'
        ) | Set-Content -LiteralPath $Fixture
        $Credential = [pscredential]::new('test-login', (ConvertTo-SecureString 'fake-password' -AsPlainText -Force))
        Invoke-DMSRestoreBatch -Plan $Plan -ContextPath 'offline-fixture' -ReportPlan $Plan -EntryScript $Fixture `
            -SqlCredentials @{ 'VM-MIGRDEMO' = $Credential; 'MI-MIGRDEMO' = $Credential } -Confirm
        $Plan.Result.Status | Should -Be @('Submitted', 'Submitted')
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.started') | Should -HaveCount 2
        @(Get-Job) | Where-Object { $_.State -eq 'Running' } | Should -HaveCount 0
    }
    It 'Does not launch a job or write reports during a direct batch preview' {
        Mock Start-Job { throw 'Unexpected worker launch' }
        Invoke-DMSRestoreBatch -Plan $Plan -ContextPath 'offline-fixture' -ReportPlan $Plan -WhatIf -Confirm
        $Plan.Result.Status | Should -Be @('WhatIf', 'WhatIf')
        Should -Invoke Start-Job -Times 0 -Exactly
        Should -Invoke Write-DMSPlanResults -Times 0 -Exactly
    }
    It 'Starts VM and MI workers concurrently and lets MI submit when VM fails' {
        $Plan[0].Item.TargetSqlAuthType = 'WindowsAD'
        $Fixture = Join-Path $TestDrive 'mixed-result-worker.ps1'
        [IO.File]::WriteAllText((Join-Path $TestDrive 'expected-identity.txt'), [Security.Principal.WindowsIdentity]::GetCurrent().Name)
        @(
            'function Disable-AzContextAutosave { param($Scope) }'
            'function Import-AzContext { param($Path, $Scope) }'
            'function Start-DMSItemRestore {'
            '[CmdletBinding(SupportsShouldProcess)]param($Entry, $SqlCredential)'
            '$Directory = Split-Path -Parent $PSCommandPath'
            '$Expected = [IO.File]::ReadAllText((Join-Path $Directory "expected-identity.txt"))'
            'if ([Security.Principal.WindowsIdentity]::GetCurrent().Name -ne $Expected) { throw "Windows executor identity changed" }'
            '[IO.File]::WriteAllText((Join-Path $Directory ($Entry.Item.Id + ".concurrent")), "started")'
            '$Deadline = [datetime]::UtcNow.AddSeconds(30)'
            'while (@(Get-ChildItem -LiteralPath $Directory -Filter "*.concurrent").Count -lt 2) {'
            'if ([datetime]::UtcNow -gt $Deadline) { throw "Restore workers were not concurrent" }'
            'Start-Sleep -Milliseconds 50'
            '}'
            'if ($Entry.Item.TargetType -eq "SQLVM") {'
            'if ($Entry.Item.TargetSqlAuthType -ne "WindowsAD") { throw "WindowsAD setting was not handed off" }'
            'throw "VM SQL login failed"'
            '}'
            '[pscustomobject]@{ Status = "Submitted" }'
            '}'
        ) | Set-Content -LiteralPath $Fixture
        Invoke-DMSRestoreBatch -Plan $Plan -ContextPath 'offline-context' -ReportPlan $Plan -EntryScript $Fixture
        $Plan.Result.Status | Should -Be @('SubmissionUnverified', 'Submitted')
        $Plan[0].Result.Error | Should -Be 'VM SQL login failed'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.concurrent') | Should -HaveCount 2
        @(Get-Job) | Where-Object { $_.State -eq 'Running' } | Should -HaveCount 0
    }
    It 'Does not launch workers for items that failed validation or overwrite their error' {
        foreach ($Entry in $Plan) {
            $Entry.Result.Status = 'Failed'
            $Entry.Result.Error = 'Original SQL validation failure'
        }
        Mock Start-Job { throw 'Failed items must not start a worker' }
        Invoke-DMSRestoreBatch -Plan $Plan -ContextPath 'offline-context' -ReportPlan $Plan
        $Plan.Result.Status | Should -Be @('Failed', 'Failed')
        $Plan.Result.Error | Should -Be @('Original SQL validation failure', 'Original SQL validation failure')
        Should -Invoke Start-Job -Times 0 -Exactly
    }
    It 'Rejects batches larger than 10 before starting any job' {
        Mock Start-Job { throw 'Unexpected worker launch' }
        { Invoke-DMSRestoreBatch -Plan (@($Plan[0]) * 11) -ContextPath 'offline-fixture' -ReportPlan $Plan } | Should -Throw '*cannot exceed 10*'
        Should -Invoke Start-Job -Times 0 -Exactly
    }
    It 'Records worker failures as unverified rather than pretending the migration succeeded' {
        $Fixture = Join-Path $TestDrive 'failing-worker.ps1'
        @(
            'function Disable-AzContextAutosave { param($Scope) }'
            'function Import-AzContext { param($Path, $Scope) }'
            'function Start-DMSItemRestore { [CmdletBinding(SupportsShouldProcess)]param($Entry, $SqlCredential); throw "Submission failed" }'
        ) | Set-Content -LiteralPath $Fixture
        Invoke-DMSRestoreBatch -Plan $Plan -ContextPath 'offline-fixture' -ReportPlan $Plan -EntryScript $Fixture
        $Plan.Result.Status | Should -Be @('SubmissionUnverified', 'SubmissionUnverified')
        $Plan[0].Result.Error | Should -Be 'Submission failed'
        Should -Invoke Write-Warning -Times 2 -Exactly
    }
}

Describe 'Persistent background execution' -Tag 'Unit' {
    BeforeEach {
        $Directory = New-DMSRunDirectory -RootDirectory $TestDrive
        $Config = Read-ServiceConfiguration (Join-Path $PSScriptRoot 'Fixtures\Restore.config.json')
        $Plan = @(New-DMSItemPlan -Items @(Resolve-DMSConfigurationItems $Config))
        Mock Save-AzContext { [IO.File]::WriteAllText($Path, 'offline-context') }
        Mock Disable-AzContextAutosave {}
        Mock Import-AzContext {}
    }
    It 'Protects the run directory from inherited access by other users' {
        $Acl = Get-Acl -LiteralPath $Directory
        $Acl.AreAccessRulesProtected | Should -BeTrue
        $User = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $Rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $Rules | Should -HaveCount 1
        $Rules[0].IdentityReference.Value | Should -Be $User
    }
    It 'Launches an actual hidden independent process and returns persistent log/status locations' {
        $Fixture = Join-Path $TestDrive 'background.ps1'
        @(
            'param([string]$WorkerRequestPath)'
            '$Request = Import-Clixml -LiteralPath $WorkerRequestPath'
            'if ($Request.SqlCredentials["VM-MIGRDEMO"] -isnot [pscredential]) { throw "Encrypted credential handoff failed" }'
            '$Directory = Split-Path -Parent $WorkerRequestPath'
            'Remove-Item -LiteralPath $WorkerRequestPath'
            'Remove-Item -LiteralPath $Request.ContextPath'
            '[IO.File]::WriteAllText((Join-Path $Directory "execution.log"), "Offline worker running")'
            '[IO.File]::WriteAllText((Join-Path $Directory "run.json"), ''{"Status":"Running"}'')'
            'Start-Sleep -Seconds 3'
            '[IO.File]::WriteAllText((Join-Path $Directory "run.json"), ''{"Status":"Succeeded"}'')'
        ) | Set-Content -LiteralPath $Fixture
        $Credential = [pscredential]::new('test-login', (ConvertTo-SecureString 'fake-password' -AsPlainText -Force))
        $Result = Start-DMSBackgroundRun -Plan $Plan -Directory $Directory -MaxConcurrentRestores 10 -MaxConcurrentCutover 5 `
            -SqlCredentials @{ 'VM-MIGRDEMO' = $Credential } -EntryScript $Fixture
        $Result.ProcessId | Should -BeGreaterThan 0
        $Result.LogPath | Should -Exist
        $Result.StatePath | Should -Exist
        $Process = Get-Process -Id $Result.ProcessId -ErrorAction SilentlyContinue
        if ($Process) { $Process.WaitForExit(15000) | Should -BeTrue }
        (Get-Content -LiteralPath $Result.StatePath -Raw | ConvertFrom-Json).Status | Should -Be 'Succeeded'
        Test-Path -LiteralPath (Join-Path $Directory 'request.clixml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Directory 'azure.context.json') | Should -BeFalse
    }
    It 'Cleans secret handoff files if process creation fails' {
        Mock Start-Process { throw 'Process launch denied' }
        { Start-DMSBackgroundRun -Plan $Plan -Directory $Directory -MaxConcurrentRestores 10 -MaxConcurrentCutover 5 } | Should -Throw '*Process launch denied*'
        Test-Path -LiteralPath (Join-Path $Directory 'request.clixml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Directory 'azure.context.json') | Should -BeFalse
    }
    It 'Records foreground failures persistently and cleans exported context without swallowing the error' {
        Mock Invoke-DMSPreparedPlan { throw 'Offline failure' }
        { Invoke-DMSRun -Plan $Plan -Directory $Directory -MaxConcurrentRestores 10 -MaxConcurrentCutover 5 } | Should -Throw '*Offline failure*'
        $State = Get-Content -LiteralPath (Join-Path $Directory 'run.json') -Raw | ConvertFrom-Json
        $State.Status | Should -Be 'Failed'
        $State.Error | Should -Be 'Offline failure'
        Test-Path -LiteralPath (Join-Path $Directory 'azure.context.json') | Should -BeFalse
    }
}
