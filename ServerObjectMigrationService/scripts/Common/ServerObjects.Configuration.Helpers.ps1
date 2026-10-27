#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

#region Functions
function Get-ServerObjectSourceContainerName {
    [CmdletBinding()]
    param([string]$Source, [string]$Platform = '')
    $Name = ($Source.Trim().ToLowerInvariant() -replace '[^a-z0-9-]', '-' -replace '-+', '-').Trim('-') + '-sqlobjects'
    if ($Platform) { $Name += '-' + $Platform.ToLowerInvariant() }
    if ($Name.Length -gt 63 -or $Name -notmatch '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$' -or $Name -match '--') {
        throw "Source '$Source' cannot form an unambiguous Azure container name (maximum 63 characters)."
    }
    $Name
}

function Get-ServerObjectSourceEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)
    $Parts = $Item.SourceServerName.Trim() -split '\\', 2
    $HostName = $Parts[0]
    $Suffix = ([string]$Item.SourceDomainSuffix).Trim().Trim('.')
    if ($Suffix -and $HostName -notmatch '\.') { $HostName += ".$Suffix" }
    if ($Parts.Count -eq 2) { "$HostName\$($Parts[1])" } else { $HostName }
}

function Get-ServerObjectDefaults {
    [CmdletBinding()]
    param()
    @{
        Enabled = $true; Activity = 'Generate'; Application = 'MigrationDemo'
        SourceServerName = ''; SourceDomainSuffix = ''; SourceListofDatabases = ''
        SourceTrustServerCertificate = $false
        TargetTrustServerCertificate = $false
        TargetSqlAuthType = 'Auto'; credential = ''; SqlCredentialMode = 'Interactive'
        SqlCredentialPath = ''; SqlUserName = ''; SqlPasswordEnvironmentVariable = ''
        TargetName = ''; TargetType = ''; TargetSqlHost = ''; TargetSqlPort = 0; TargetWindowsDomain = ''
        TenantId = ''; SubscriptionId = ''; JobOwnerUpnSuffix = ''; EntraIdentityMappings = @{}
        SQLAgentJobFilterCriteria = '.*'; SQLAgentJobsMigrationFlag = 'Yes'; SQLAgentJobsMigrationScope = 'All'
        SQLLoginsMigrationFlag = 'Yes'; SQLLoginsMigrationScope = 'All'
        SQLOperatorsMigrationFlag = 'Yes'; SQLAlertsMigrationFlag = 'Yes'
        SQLDBMailMigrationFlag = 'No'; SmtpServer = ''; SmtpPort = ''
        StorageAccountName = ''; StorageResourceGroup = ''; StorageContainer = ''
        CreateContainerIfMissing = $false
        KeyVaultName = ''; Logins = @(); ProvisionLogins = $false
    }
}

function ConvertTo-ServerObjectLogins {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)
    if ($Item.Logins -isnot [array]) { throw "Logins must be an array on '$($Item.Id)'." }
    $Names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Login in $Item.Logins) {
        if ($Login -isnot [Collections.IDictionary]) { throw "Each login on '$($Item.Id)' must be an object." }
        foreach ($Key in $Login.Keys) {
            if ($Key -notin @('Name', 'Type', 'SecretName', 'ForcePasswordReset', 'AccessType', 'Databases', 'ObjectId')) {
                throw "Unknown login property '$Key' on '$($Item.Id)'."
            }
        }
        if ($Login.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Login.Name) -or
            $Login.Name.Trim().Length -gt 128 -or $Login.Name -match '[\x00-\x1f]' -or -not $Names.Add($Login.Name.Trim())) {
            throw "Each login on '$($Item.Id)' needs a unique nonempty Name (maximum 128 characters)."
        }
        Assert-ServerObjectLoginTarget -TargetType $Item.TargetType -LoginType $Login.Type -LoginName $Login.Name.Trim() `
            -TargetWindowsDomain $Item.TargetWindowsDomain
        if ($Login.Type -eq 'WindowsAD' -and $Login.Contains('ObjectId')) {
            throw 'WindowsAD cannot specify ObjectId; Windows AD resolution uses the target domain and Windows SID.'
        }
        if (-not $Login.Contains('AccessType') -or $Login.AccessType -isnot [array] -or
            @($Login.AccessType | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) -or $_ -notmatch '^[A-Za-z_ ]+$' }).Count) {
            throw "AccessType must be an array of role/permission names for '$($Login.Name)'; use [] for no additional grants."
        }
        if ($Login.Contains('Databases') -and ($Login.Databases -isnot [array] -or -not $Login.Databases.Count -or
            @($Login.Databases | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) -or $_ -eq 'All' }).Count)) {
            throw "Databases must be a nonempty array of explicit names for '$($Login.Name)'."
        }
        if ($Login.Type -eq 'SqlLogin') {
            if ([string]::IsNullOrWhiteSpace($Item.KeyVaultName) -or $Login.SecretName -isnot [string] -or
                $Login.SecretName -notmatch '^[A-Za-z0-9-]{1,127}$') {
                throw "SQL login '$($Login.Name)' requires KeyVaultName and a valid SecretName."
            }
            if ($Login.Contains('ObjectId')) { throw 'ObjectId is only supported for external logins.' }
            if ($Login.Contains('ForcePasswordReset') -and $Login.ForcePasswordReset -isnot [bool]) {
                throw "ForcePasswordReset must be Boolean for '$($Login.Name)'."
            }
        }
        elseif ($Login.Contains('SecretName') -or $Login.Contains('ForcePasswordReset')) {
            throw "External login '$($Login.Name)' cannot specify SecretName or ForcePasswordReset."
        }
        $ObjectId = ''
        if ($Login.Contains('ObjectId')) {
            Assert-ServiceGuid -Name ObjectId -Value $Login.ObjectId
            $ObjectId = ([guid]$Login.ObjectId).ToString()
        }
        [pscustomobject]@{
            Name = $Login.Name.Trim(); Type = $Login.Type
            SecretName = if ($Login.Type -eq 'SqlLogin') { $Login.SecretName } else { '' }
            ForcePasswordReset = $Login.Type -eq 'SqlLogin' -and $Login.Contains('ForcePasswordReset') -and $Login.ForcePasswordReset
            AccessType = @($Login.AccessType | ForEach-Object { $_.Trim() } | Select-Object -Unique)
            Databases = @(if ($Login.Contains('Databases')) { $Login.Databases | ForEach-Object { $_.Trim() } | Select-Object -Unique })
            ObjectId = $ObjectId
        }
    }
}

function Read-ServerObjectItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ItemId = @(),
        [string]$Activity
    )
    $Configuration = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($Configuration -isnot [System.Collections.IDictionary] -or
        ($Configuration.schemaVersion -isnot [long] -and $Configuration.schemaVersion -isnot [int]) -or $Configuration.schemaVersion -ne 2 -or
        ($Configuration.Contains('Common') -and $Configuration.Common -isnot [System.Collections.IDictionary]) -or
        $Configuration.Items -isnot [array] -or -not $Configuration.Items.Count) {
        throw 'Server-object configuration requires numeric schemaVersion 2 and a nonempty Items array; optional legacy Common must be an object.'
    }
    foreach ($Key in $Configuration.Keys) {
        if ($Key -notin @('schemaVersion', 'Common', 'Items', '_comment')) { throw "Unknown configuration property '$Key'." }
    }
    $Common = if ($Configuration.Contains('Common')) { $Configuration.Common } else { @{} }
    $Defaults = Get-ServerObjectDefaults
    foreach ($Key in $Common.Keys) {
        if ($Key -in @('Logins', 'ProvisionLogins')) { throw "'$Key' must be configured on Items, not Common." }
        if (-not $Defaults.ContainsKey($Key)) { throw "Unknown Common property '$Key'." }
    }
    $Ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $Resolved = [Collections.Generic.List[object]]::new()
    foreach ($Item in $Configuration.Items) {
        if ($Item -isnot [System.Collections.IDictionary] -or
            $Item.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or -not $Ids.Add($Item.Id)) {
            throw 'Each item needs a unique Id containing letters, digits, underscores or hyphens (maximum 64 characters).'
        }
        foreach ($Key in $Item.Keys) {
            if ($Key -notin @('Id', 'Enabled') -and -not $Defaults.ContainsKey($Key)) { throw "Unknown item property '$Key'." }
        }
        $Values = $Defaults.Clone()
        foreach ($Layer in @($Common, $Item)) {
            foreach ($Key in $Layer.Keys) {
                $Value = $Layer[$Key]
                if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) { continue }
                if ($Value -is [string]) {
                    $Values[$Key] = $Value.Trim()
                }
                else {
                    $Values[$Key] = $Value
                }
            }
        }
        $Values.Id = $Item.Id
        if ($Values.EntraIdentityMappings -isnot [Collections.IDictionary]) {
            throw "EntraIdentityMappings must be an object keyed by exact source identity on '$($Item.Id)'."
        }
        foreach ($Key in $Values.EntraIdentityMappings.Keys) {
            if ([string]::IsNullOrWhiteSpace($Key) -or
                $Values.EntraIdentityMappings[$Key] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($Values.EntraIdentityMappings[$Key])) {
                throw "EntraIdentityMappings requires nonempty source names and target UPN/display-name strings on '$($Item.Id)'."
            }
        }
        $Platforms = @($Configuration.Items | ForEach-Object {
            $Candidate = @{}
            foreach ($Name in @('SourceServerName', 'StorageAccountName', 'TargetType')) {
                $Candidate[$Name] = if ($_.Contains($Name) -and -not [string]::IsNullOrWhiteSpace($_[$Name])) {
                    $_[$Name]
                } elseif ($Common.Contains($Name)) { $Common[$Name] } else { '' }
            }
            if ($Candidate.SourceServerName -eq $Values.SourceServerName -and
                $Candidate.StorageAccountName -eq $Values.StorageAccountName) { $Candidate.TargetType }
        } | Select-Object -Unique)
        if ($Values.SourceServerName) {
            $PlatformSuffix = if ($Platforms.Count -gt 1) { $Values.TargetType } else { '' }
            $Values.StorageContainer = Get-ServerObjectSourceContainerName -Source $Values.SourceServerName -Platform $PlatformSuffix
        }
        if ($Values.Enabled -isnot [bool]) { throw "Enabled must be Boolean on '$($Item.Id)'." }
        if (-not $Values.Enabled -or ($ItemId -and $Item.Id -notin $ItemId)) { continue }
        if ($Activity) { $Values.Activity = $Activity }
        if ($Values.Activity -eq 'ProvisionSqlLogins') { $Values.Activity = 'ProvisionLogins' }
        if ($Values.Activity -notin @('Generate', 'GenerateAndExecute', 'Execute', 'ProvisionLogins')) {
            throw "Unsupported Activity '$($Values.Activity)' on '$($Item.Id)'."
        }
        if ($Values.TargetType -notin @('SQLVM', 'SQLMI')) { throw "TargetType must be SQLVM or SQLMI on '$($Item.Id)'." }
        if ($Values.TargetSqlAuthType -eq 'Windows') {
            throw "Replace TargetSqlAuthType 'Windows' with 'WindowsAD' on '$($Item.Id)'."
        }
        if ($Values.TargetSqlAuthType -notin @('Auto', 'WindowsAD', 'Entra', 'SqlLogin')) {
            throw "TargetSqlAuthType must be Auto, WindowsAD, Entra or SqlLogin on '$($Item.Id)'."
        }
        if ($Values.TargetType -eq 'SQLMI' -and $Values.TargetSqlAuthType -eq 'WindowsAD') {
            throw "Use Entra or SqlLogin target authentication for SQLMI item '$($Item.Id)'."
        }
        if ($Values.SqlCredentialMode -notin @('Interactive', 'Configured')) {
            throw "SqlCredentialMode must be Interactive or Configured on '$($Item.Id)'."
        }
        foreach ($Name in @('credential', 'SqlCredentialPath', 'SqlUserName', 'SqlPasswordEnvironmentVariable')) {
            if ($Values[$Name] -isnot [string]) { throw "$Name must be a string on '$($Item.Id)'." }
        }
        Assert-ServiceFields -Items @([pscustomobject]$Values) -Required TargetName, TargetSqlHost, TenantId, SubscriptionId
        Assert-ServiceGuid -Name TenantId -Value $Values.TenantId
        Assert-ServiceGuid -Name SubscriptionId -Value $Values.SubscriptionId
        if ($Values.TargetSqlHost -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$' -or
            $Values.TargetSqlPort -isnot [long] -and $Values.TargetSqlPort -isnot [int] -or
            $Values.TargetSqlPort -lt 1 -or $Values.TargetSqlPort -gt 65535) {
            throw "Configure a hostname (without tcp: or port) and numeric TargetSqlPort from 1 to 65535 on '$($Item.Id)'."
        }
        foreach ($Flag in @('CreateContainerIfMissing', 'ProvisionLogins', 'SourceTrustServerCertificate', 'TargetTrustServerCertificate')) {
            if ($Values[$Flag] -isnot [bool]) { throw "$Flag must be Boolean on '$($Item.Id)'." }
        }
        $Values.Logins = @(ConvertTo-ServerObjectLogins -Item ([pscustomobject]$Values))
        if ($Values.Activity -ne 'ProvisionLogins') {
            Assert-ServiceFields -Items @([pscustomobject]$Values) -Required SourceServerName, SourceListofDatabases, StorageAccountName, StorageResourceGroup, StorageContainer
            if ($Values.StorageAccountName -cnotmatch '^[a-z0-9]{3,24}$' -or
                $Values.StorageContainer -cnotmatch '^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$' -or $Values.StorageContainer -match '--') {
                throw "Invalid storage account or container on '$($Item.Id)'."
            }
            foreach ($ScopeName in @('SQLLoginsMigrationScope', 'SQLAgentJobsMigrationScope')) {
                if ($Values[$ScopeName] -notin @('Server', 'All')) { throw "$ScopeName must be Server or All on '$($Item.Id)'." }
            }
            foreach ($FlagName in @('SQLLoginsMigrationFlag', 'SQLAgentJobsMigrationFlag', 'SQLOperatorsMigrationFlag',
                    'SQLAlertsMigrationFlag', 'SQLDBMailMigrationFlag')) {
                if ($Values[$FlagName] -notin @('Yes', 'No')) { throw "$FlagName must be Yes or No on '$($Item.Id)'." }
            }
            if ($Values.Activity -in @('Execute', 'GenerateAndExecute')) {
                try { $null = [regex]::new($Values.SQLAgentJobFilterCriteria) }
                catch { throw "Invalid SQLAgentJobFilterCriteria on '$($Item.Id)': $($_.Exception.Message)" }
                if ($Values.SQLDBMailMigrationFlag -eq 'Yes' -and
                    (-not $Values.SmtpServer -or $Values.SmtpPort -notmatch '^\d+$' -or
                    [int]$Values.SmtpPort -lt 1 -or [int]$Values.SmtpPort -gt 65535)) {
                    throw "Database Mail execution requires SmtpServer and SmtpPort (1-65535) on '$($Item.Id)'."
                }
            }
        }
        if ($Values.ProvisionLogins -or $Values.Activity -eq 'ProvisionLogins') {
            if (-not $Values.ProvisionLogins) { throw "Set ProvisionLogins to true on '$($Item.Id)' before running its provisioning activity." }
            Assert-ServiceFields -Items @([pscustomobject]$Values) -Required SourceListofDatabases
            if (-not $Values.Logins.Count) { throw "ProvisionLogins requires item-specific Logins on '$($Item.Id)'." }
            $null = @(Get-ServerObjectProvisioningItems -Item ([pscustomobject]$Values))
        }
        $Resolved.Add([pscustomobject]$Values)
    }
    foreach ($Id in $ItemId) {
        if ($Id -notin @($Resolved | ForEach-Object { $_.Id })) { throw "ItemId '$Id' is unknown or disabled." }
    }
    if (-not $Resolved.Count) { throw 'No enabled items selected.' }
    $Resolved.ToArray()
}

function ConvertTo-ServerObjectLegacyItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [switch]$Execution)
    $Row = [ordered]@{}
    foreach ($Name in @('Application', 'SourceServerName', 'SourceDomainSuffix', 'SourceTrustServerCertificate', 'TargetTrustServerCertificate', 'TargetType', 'TenantId', 'SubscriptionId',
            'SourceListofDatabases', 'SQLAgentJobFilterCriteria', 'SQLAgentJobsMigrationFlag',
            'SQLLoginsMigrationFlag', 'SQLLoginsMigrationScope', 'SQLOperatorsMigrationFlag', 'SQLAlertsMigrationFlag',
            'SQLDBMailMigrationFlag', 'JobOwnerUpnSuffix', 'SmtpServer', 'SmtpPort')) {
        $Row[$Name] = $Item.$Name
    }
    $Row.TargetServerName = "tcp:$($Item.TargetSqlHost),$($Item.TargetSqlPort)"
    $Row.TargetExecutionFlag = 'No'
    $Row.OnlyTargetExecutionFlag = if ($Execution) { 'Yes' } else { 'No' }
    [pscustomobject]$Row
}

function Get-ServerObjectProvisioningItems {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)
    $Scope = @(($Item.SourceListofDatabases -split ',').Trim())
    if (-not $Scope.Count -or @($Scope | Where-Object { -not $_ -or $_ -eq 'All' }).Count) {
        throw 'ProvisionLogins requires explicit nonempty database names, not All.'
    }
    foreach ($Login in $Item.Logins) {
        Assert-ServerObjectLoginTarget -TargetType $Item.TargetType -LoginType $Login.Type -LoginName $Login.Name `
            -TargetWindowsDomain $Item.TargetWindowsDomain
        $Databases = if ($Login.Databases.Count) { @($Login.Databases) } else { $Scope }
        foreach ($Database in $Databases) {
            if ($Database -notin $Scope) { throw "Login '$($Login.Name)' requests database '$Database' outside the item's database scope." }
            [pscustomobject]@{
                Application = $Item.Application; TargetServerName = $Item.TargetName
                TargetServerFQDN = $Item.TargetSqlHost; TargetType = $Item.TargetType
                TargetWindowsDomain = $Item.TargetWindowsDomain
                TenantId = $Item.TenantId; SubscriptionId = $Item.SubscriptionId
                LoginName = $Login.Name; LoginType = $Login.Type; ObjectId = $Login.ObjectId
                KeyVaultName = $Item.KeyVaultName; SecretName = $Login.SecretName
                ForcePasswordReset = $Login.ForcePasswordReset
                Database = $Database; AccessType = @($Login.AccessType)
            }
        }
    }
}
#endregion Functions
