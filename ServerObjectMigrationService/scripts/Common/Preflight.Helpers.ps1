#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

function Get-ServerObjectTargetAuth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [string]$TargetSqlAuthType = 'Auto',
        [bool]$TrustServerCertificate = $false, [pscredential]$SqlCredential)
    $Type = $TargetSqlAuthType
    if ($Type -eq 'Auto') { $Type = if ($Item.TargetType -eq 'SQLVM') { 'Windows' } else { 'Entra' } }
    $Auth = @{ TrustServerCertificate = $TrustServerCertificate }
    switch ($Type) {
        SqlLogin {
            if (-not $SqlCredential) { throw "SQL authentication requires a resolved credential for target '$($Item.TargetType)'; no worker prompt or fallback is allowed." }
            $Auth.SqlCredential = $SqlCredential
        }
        Windows {
            if ($Item.TargetType -ne 'SQLVM') { throw 'Windows integrated authentication requires a SQLVM target.' }
        }
        Entra { $Auth.TenantId = $Item.TenantId; $Auth.SubscriptionId = $Item.SubscriptionId }
        default { throw "Unsupported target authentication '$Type'." }
    }
    $Auth
}

function Invoke-ServerObjectPreflightQuery {
    [CmdletBinding()]
    param([string]$Server, [string]$Database = 'master', [string]$Query, [string]$TenantId, [string]$SubscriptionId,
        [bool]$TrustServerCertificate = $false, [int]$QueryTimeout = 30, [pscredential]$SqlCredential)

    $Arguments = @{
        ServerInstance = $Server; Database = $Database; Query = $Query
        ConnectionTimeout = 15; QueryTimeout = $QueryTimeout; ErrorAction = 'Stop'; AbortOnError = $true
        TrustServerCertificate = $TrustServerCertificate
    }
    if ((Get-Command Invoke-Sqlcmd -ErrorAction Stop).Parameters.ContainsKey('Encrypt')) {
        $Arguments.Encrypt = 'Mandatory'
    }
    else { $Arguments.EncryptConnection = $true }
    if ($SqlCredential -and $TenantId) { throw 'SQL credentials and Entra token authentication cannot be combined.' }
    if ($SqlCredential) { $Arguments.Credential = $SqlCredential }
    elseif ($TenantId) {
        Import-Module Az.Accounts -ErrorAction Stop
        $Context = Get-AzContext -ErrorAction Stop
        if (-not $Context -or $Context.Tenant.Id -ne $TenantId) {
            throw "Authenticate with Connect-AzAccount for tenant '$TenantId' before preflight."
        }
        $null = Set-AzContext -SubscriptionId $SubscriptionId -TenantId $TenantId -Scope Process -WhatIf:$false -Confirm:$false -ErrorAction Stop
        $Token = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/' -ErrorAction Stop).Token
        if ($Token -is [securestring] -and (Get-Command Invoke-Sqlcmd).Parameters['AccessToken'].ParameterType -eq [string]) {
            $Token = [Net.NetworkCredential]::new('', $Token).Password
        }
        $Arguments.AccessToken = $Token
    }
    try {
        Invoke-Sqlcmd @Arguments
    }
    catch {
        $Authentication = if ($SqlCredential) { 'SQL login' } elseif ($TenantId) { 'Microsoft Entra access token' } else { 'Windows integrated' }
        $Message = "SQL query failed: ServerInstance='$Server'; Database='$Database'; Authentication='$Authentication'; Encrypt=True; TrustServerCertificate=$TrustServerCertificate; ConnectionTimeout=15s; QueryTimeout=${QueryTimeout}s. $($_.Exception.Message)"
        $Exception = [InvalidOperationException]::new($Message, $_.Exception)
        $Details = [pscustomobject]@{ ServerInstance = $Server; Database = $Database; Authentication = $Authentication
            TrustServerCertificate = $TrustServerCertificate }
        $Record = [Management.Automation.ErrorRecord]::new($Exception, 'ServerObjectSqlPreflightFailed', $_.CategoryInfo.Category, $Details)
        $PSCmdlet.ThrowTerminatingError($Record)
    }
}

function Assert-ServerObjectSqlAccess {
    [CmdletBinding()]
    param(
        [string]$Server, [string]$Database = 'master', [string]$TenantId, [string]$SubscriptionId,
        [string[]]$ServerPermissions = @(), [string[]]$DatabasePermissions = @(),
        [switch]$RequireSysadmin, [switch]$RequireLoginHashes,
        [bool]$TrustServerCertificate = $false, [pscredential]$SqlCredential
    )

    $Arguments = @{ Server = $Server; Database = $Database; TenantId = $TenantId; SubscriptionId = $SubscriptionId
        TrustServerCertificate = $TrustServerCertificate; SqlCredential = $SqlCredential }
    $Access = @(Invoke-ServerObjectPreflightQuery @Arguments `
        -Query "SELECT IS_SRVROLEMEMBER('sysadmin') AS IsSysadmin, HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'CONNECT') AS CanConnect;")
    if ($Access.Count -ne 1 -or $Access[0].CanConnect -ne 1) {
        throw "Preflight cannot access '$Server' / '$Database'."
    }
    if ($Access[0].IsSysadmin -eq 1) { return }
    if ($RequireSysadmin) {
        throw "sysadmin is required on '$Server' to import Agent jobs, operators, alerts, or Database Mail configuration."
    }
    foreach ($Permission in $ServerPermissions) {
        $Literal = $Permission.Replace("'", "''")
        $Check = @(Invoke-ServerObjectPreflightQuery @Arguments -Query "SELECT HAS_PERMS_BY_NAME(NULL, NULL, '$Literal') AS Allowed;")
        if ($Check.Count -ne 1 -or $Check[0].Allowed -ne 1) { throw "Missing server permission '$Permission' on '$Server'." }
    }
    foreach ($Permission in $DatabasePermissions) {
        $Literal = $Permission.Replace("'", "''")
        $Check = @(Invoke-ServerObjectPreflightQuery @Arguments -Query "SELECT HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', '$Literal') AS Allowed;")
        if ($Check.Count -ne 1 -or $Check[0].Allowed -ne 1) { throw "Missing database permission '$Permission' on '$Server' / '$Database'." }
    }
    if ($RequireLoginHashes) {
        $Check = @(Invoke-ServerObjectPreflightQuery @Arguments -Query @"
SELECT CASE WHEN HAS_PERMS_BY_NAME(NULL, NULL, 'CONTROL SERVER') = 1
OR HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY CRYPTOGRAPHICALLY SECURED DEFINITION') = 1
THEN 1 ELSE 0 END AS Allowed;
"@)
        if ($Check.Count -ne 1 -or $Check[0].Allowed -ne 1) { throw "Cannot read SQL login password hashes on '$Server'." }
    }
}

function Resolve-ServerObjectExternalPrincipal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Login)
    switch ($Login.LoginType) {
        'EntraUser' {
            $Candidates = if ($Login.ObjectId) {
                @(Get-AzADUser -ObjectId $Login.ObjectId -ErrorAction Stop)
            } else { @(Get-AzADUser -UserPrincipalName $Login.LoginName -ErrorAction Stop) }
            $Matches = @($Candidates | Where-Object { $_.UserPrincipalName -eq $Login.LoginName })
        }
        'EntraGroup' {
            $Candidates = if ($Login.ObjectId) {
                @(Get-AzADGroup -ObjectId $Login.ObjectId -ErrorAction Stop)
            } else { @(Get-AzADGroup -DisplayName $Login.LoginName -ErrorAction Stop) }
            $Matches = @($Candidates | Where-Object { $_.DisplayName -eq $Login.LoginName })
        }
        'ManagedIdentity' {
            $Candidates = if ($Login.ObjectId) {
                @(Get-AzADServicePrincipal -ObjectId $Login.ObjectId -ErrorAction Stop)
            } else { @(Get-AzADServicePrincipal -DisplayName $Login.LoginName -ErrorAction Stop) }
            $Matches = @($Candidates | Where-Object {
                $_.DisplayName -eq $Login.LoginName -and $_.ServicePrincipalType -eq 'ManagedIdentity'
            })
        }
        default { throw "Cannot resolve external login type '$($Login.LoginType)'." }
    }
    if ($Matches.Count -ne 1) {
        throw "Cannot uniquely resolve $($Login.LoginType) '$($Login.LoginName)' in the selected tenant. Verify its name/type or specify ObjectId."
    }
    Assert-ServiceGuid -Name ObjectId -Value $Matches[0].Id
    if ($Login.ObjectId -and [guid]$Login.ObjectId -ne [guid]$Matches[0].Id) {
        throw "External identity ObjectId differs for '$($Login.LoginName)'."
    }
    ([guid]$Matches[0].Id).ToString()
}

function Invoke-ServerObjectPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][hashtable]$Options,
        [Parameter(Mandatory)][string]$ScriptsPath
    )

    if ($Options.ContainsKey('OutputJsonPath') -and $Options.OutputJsonPath) { Assert-ServiceOutputPath -Path $Options.OutputJsonPath }
    $Items = @($Configuration.Items)
    if ($Operation -eq 'Invoke-ProvisionLogins-AzSql') {
        Assert-ServiceFields -Items $Items -Required Application, TargetServerName, TargetServerFQDN, TargetType, TenantId, SubscriptionId, LoginName, LoginType, Database
        foreach ($Item in $Items) {
            Assert-ServiceGuid -Name TenantId -Value $Item.TenantId
            Assert-ServiceGuid -Name SubscriptionId -Value $Item.SubscriptionId
            $Domain = if ($Item.PSObject.Properties['TargetWindowsDomain']) { [string]$Item.TargetWindowsDomain } else { '' }
            Assert-ServerObjectLoginTarget -TargetType $Item.TargetType -LoginType $Item.LoginType -LoginName $Item.LoginName -TargetWindowsDomain $Domain
            if ($Item.ForcePasswordReset -isnot [bool] -or $Item.AccessType -isnot [array] -or
                @($Item.AccessType | Where-Object { $_ -isnot [string] -or $_ -notmatch '^[A-Za-z_ ]+$' -or [string]::IsNullOrWhiteSpace($_) }).Count) {
                throw "Invalid login type, reset setting, or access list for '$($Item.LoginName)'."
            }
            if ($Item.LoginType -eq 'SqlLogin') {
                Assert-ServiceFields -Items @($Item) -Required KeyVaultName, SecretName
            }
            elseif ($Item.LoginType -eq 'WindowsAD') {
                if (($Item.PSObject.Properties['ObjectId'] -and $Item.ObjectId) -or
                    ($Item.PSObject.Properties['SecretName'] -and $Item.SecretName) -or $Item.ForcePasswordReset) {
                    throw 'WindowsAD cannot specify ObjectId, SecretName or ForcePasswordReset.'
                }
            }
        }
        Assert-ServiceOutputPath -Path (Join-Path $Options.OutputRoot '.preflight')
        Import-Module SqlServer, Az.Accounts -ErrorAction Stop
        if (@($Items | Where-Object LoginType -eq 'SqlLogin').Count) { Import-Module Az.KeyVault -ErrorAction Stop }
        if (@($Items | Where-Object LoginType -in @('EntraUser', 'EntraGroup', 'ManagedIdentity')).Count) { Import-Module Az.Resources -ErrorAction Stop }
        foreach ($Item in $Items) {
            $Context = Get-AzContext -ErrorAction Stop
            if (-not $Context -or $Context.Tenant.Id -ne $Item.TenantId) { throw "Authenticate for tenant '$($Item.TenantId)' before preflight." }
            $null = Set-AzContext -SubscriptionId $Item.SubscriptionId -TenantId $Item.TenantId -Scope Process -WhatIf:$false -Confirm:$false -ErrorAction Stop
            if ($Item.LoginType -eq 'SqlLogin') {
                $Secret = Get-AzKeyVaultSecret -VaultName $Item.KeyVaultName -Name $Item.SecretName -ErrorAction Stop
                if (-not $Secret -or -not $Secret.SecretValue -or $Secret.SecretValue.Length -eq 0 -or
                    $Secret.Enabled -eq $false -or ($Secret.Expires -and $Secret.Expires -le [datetime]::UtcNow) -or
                    ($Secret.NotBefore -and $Secret.NotBefore -gt [datetime]::UtcNow)) {
                    throw "Key Vault secret '$($Item.SecretName)' is unavailable, disabled, empty, or expired."
                }
                $Secret = $null
            }
            elseif ($Item.LoginType -ne 'WindowsAD') {
                $Item.ObjectId = Resolve-ServerObjectExternalPrincipal -Login $Item
            }
            $HostName = [string]$Item.TargetServerFQDN
            $TargetTrust = $Options.ContainsKey('TargetTrustServerCertificate') -and $Options.TargetTrustServerCertificate
            $Type = if ($Options.ContainsKey('TargetSqlAuthType')) { $Options.TargetSqlAuthType } else { 'Auto' }
            $Credential = if ($Options.ContainsKey('SqlCredential')) { $Options.SqlCredential } else { $null }
            $Auth = Get-ServerObjectTargetAuth -Item $Item -TargetSqlAuthType $Type -TrustServerCertificate $TargetTrust -SqlCredential $Credential
            if ($Item.LoginType -eq 'WindowsAD') {
                $Query = Get-ServerObjectWindowsLoginValidationSql -LoginName $Item.LoginName -TargetWindowsDomain $Item.TargetWindowsDomain
                $null = Invoke-ServerObjectPreflightQuery -Server "$HostName,$($Options.SqlPort)" -Database master @Auth -Query $Query
            }
            if ($Options.ContainsKey('ServerOnly') -and $Options.ServerOnly) {
                Assert-ServerObjectSqlAccess -Server "$HostName,$($Options.SqlPort)" -Database master @Auth -ServerPermissions @('ALTER ANY LOGIN')
                continue
            }
            foreach ($Database in @(([string]$Item.Database -split ',').Trim())) {
                if (-not $Database) { throw 'Database cannot contain empty names.' }
                Assert-ServerObjectSqlAccess -Server "$HostName,$($Options.SqlPort)" -Database $Database @Auth `
                    -ServerPermissions @('ALTER ANY LOGIN') -DatabasePermissions @('CONTROL')
                $Allowed = @(Invoke-ServerObjectPreflightQuery -Server "$HostName,$($Options.SqlPort)" -Database $Database @Auth `
                    -Query @"
SELECT name COLLATE DATABASE_DEFAULT AS name FROM sys.database_principals WHERE type = 'R'
UNION
SELECT permission_name COLLATE DATABASE_DEFAULT AS name FROM sys.fn_builtin_permissions('DATABASE');
"@)
                foreach ($AccessType in @($Item.AccessType)) {
                    if (-not $AccessType -or $AccessType -notin $Allowed.name) { throw "Unknown database role or permission '$AccessType' in '$Database'." }
                }
            }
        }
        return
    }
    $Flags = @('SQLAgentJobsMigrationFlag', 'SQLLoginsMigrationFlag', 'SQLOperatorsMigrationFlag',
        'SQLAlertsMigrationFlag', 'TargetExecutionFlag', 'OnlyTargetExecutionFlag')
    Assert-ServiceFields -Items $Items -Required (@('SourceServerName', 'TargetServerName', 'SourceListofDatabases') + $Flags)
    foreach ($Item in $Items) {
        foreach ($Flag in $Flags) {
            if ($Item.$Flag -notin @('Yes', 'No')) { throw "$Flag must be Yes or No." }
        }
        if (-not $Item.PSObject.Properties['SourceTrustServerCertificate']) {
            $Item.PSObject.Properties.Add([Management.Automation.PSNoteProperty]::new('SourceTrustServerCertificate', $false))
        }
        if ($Item.SourceTrustServerCertificate -isnot [bool]) { throw 'SourceTrustServerCertificate must be Boolean.' }
        $Platform = if ($Operation -like '*AzSQLMI') { 'SQLMI' } elseif ($Operation -like '*AzSQLVM') { 'SQLVM' } else { [string]$Item.TargetType }
        if ($Platform -notin @('SQLMI', 'SQLVM')) { throw 'TargetType must be SQLMI or SQLVM.' }
        if ($Platform -eq 'SQLMI') {
            Assert-ServiceFields -Items @($Item) -Required TenantId, SubscriptionId, TargetType, SQLDBMailMigrationFlag
            if ($Item.TargetType -ne 'SQLMI') { throw 'The SQLMI entry point requires TargetType SQLMI.' }
            Assert-ServiceGuid -Name TenantId -Value $Item.TenantId
            Assert-ServiceGuid -Name SubscriptionId -Value $Item.SubscriptionId
        }
        elseif ($Item.PSObject.Properties['TargetType'] -and ([string]$Item.TargetType).Trim() -ne 'SQLVM') {
            throw 'The SQLVM entry point requires TargetType SQLVM when supplied.'
        }
        if (-not $Item.PSObject.Properties['SQLDBMailMigrationFlag']) {
            $Item.PSObject.Properties.Add([Management.Automation.PSNoteProperty]::new('SQLDBMailMigrationFlag', 'No'))
        }
        if ($Item.SQLDBMailMigrationFlag -notin @('Yes', 'No')) { throw 'SQLDBMailMigrationFlag must be Yes or No.' }
        if ($Item.SQLLoginsMigrationScope -notin @('All', 'Server', 'Database', 'DB')) { throw 'Invalid SQLLoginsMigrationScope.' }
        $DatabaseNames = @(([string]$Item.SourceListofDatabases -split ',').Trim())
        if (@($DatabaseNames | Where-Object { -not $_ }).Count -or ($DatabaseNames -contains 'All' -and $DatabaseNames.Count -ne 1)) {
            throw 'SourceListofDatabases must contain nonempty database names or All by itself.'
        }
        if ($Item.SQLAgentJobsMigrationFlag -eq 'Yes') { $null = [regex]::new([string]$Item.SQLAgentJobFilterCriteria) }
        if ($Item.SQLDBMailMigrationFlag -eq 'Yes') {
            Assert-ServiceFields -Items @($Item) -Required SmtpServer, SmtpPort
            $Port = 0
            if (-not [int]::TryParse([string]$Item.SmtpPort, [ref]$Port) -or $Port -lt 1 -or $Port -gt 65535) { throw 'Invalid SmtpPort.' }
        }
    }
    Import-Module SqlServer, ActiveDirectory -ErrorAction Stop
    if ($Operation -like '*AzSQLMI' -or @($Items | Where-Object TargetType -eq 'SQLMI').Count) {
        Import-Module Az.Accounts, Az.Resources -ErrorAction Stop
    }
    $Components = @{
        SQLLoginsMigrationFlag = @('SQL Logins', 'SQLLogins')
        SQLOperatorsMigrationFlag = @('SQL Operators', 'SQLOperators')
        SQLAlertsMigrationFlag = @('SQL Alerts', 'SQLAlerts')
        SQLAgentJobsMigrationFlag = @('SQL Agents', 'SQLAgents')
        SQLDBMailMigrationFlag = @('SQL DB Mail', 'SQLDBMail')
    }
    foreach ($Item in $Items) {
        if (-not @($Flags | Where-Object { $_ -notin @('TargetExecutionFlag', 'OnlyTargetExecutionFlag') -and $Item.$_ -eq 'Yes' }).Count -and
            $Item.SQLDBMailMigrationFlag -ne 'Yes') { continue }
        $Platform = if ($Operation -like '*AzSQLMI') { 'SQLMI' } elseif ($Operation -like '*AzSQLVM') { 'SQLVM' } else { [string]$Item.TargetType }
        $Parts = $Item.SourceServerName.Trim() -split '\\', 2
        $Suffix = ([string]$Item.SourceDomainSuffix).Trim().Trim('.')
        $HostName = $Parts[0]
        if ($Suffix -and $HostName -notmatch '\.') { $HostName = "$HostName.$Suffix" }
        $Source = if ($Parts.Count -eq 2) { "$HostName\$($Parts[1])" } else { $HostName }
        if ($Item.OnlyTargetExecutionFlag -ne 'Yes') {
            $SourceAuth = @{ TrustServerCertificate = $Item.SourceTrustServerCertificate }
            if ($Item.SourceTrustServerCertificate) {
                Write-Warning "Source '$Source': development certificate-trust override enabled. Encryption remains enabled, but certificate validation is skipped for source SQL connections only."
            }
            $CopyLoginHashes = $Item.SQLLoginsMigrationFlag -eq 'Yes'
            Assert-ServerObjectSqlAccess -Server $Source @SourceAuth -ServerPermissions @('VIEW ANY DEFINITION', 'VIEW ANY DATABASE') -RequireLoginHashes:$CopyLoginHashes
            $Databases = @(([string]$Item.SourceListofDatabases -split ',').Trim())
            $Existing = @(Invoke-ServerObjectPreflightQuery -Server $Source @SourceAuth -Query 'SELECT name, state_desc AS State FROM sys.databases;')
            if ($Databases -contains 'All') {
                if ($Databases.Count -ne 1) { throw 'All cannot be combined with database names.' }
                $Databases = @($Existing | Where-Object name -NotIn @('master', 'msdb', 'model', 'tempdb') | Select-Object -ExpandProperty name)
            }
            $SecurityDatabases = @(if ($Item.SQLLoginsMigrationFlag -eq 'Yes') {
                Get-ServerObjectSecurityDatabaseNames -AvailableNames @($Existing | Where-Object State -eq 'ONLINE' | Select-Object -ExpandProperty name) `
                    -DatabaseList $DatabaseNames -Scope $Item.SQLLoginsMigrationScope
            })
            foreach ($Database in @(@($Databases) + @($SecurityDatabases) | Select-Object -Unique)) {
                if (-not $Database -or $Database -notin $Existing.name -or
                    @($Existing | Where-Object { $_.name -eq $Database -and $_.State -ne 'ONLINE' }).Count) {
                    throw "Source database '$Database' is missing or offline on '$Source'."
                }
                $Permissions = if ($Database -in $SecurityDatabases) { @('VIEW DEFINITION') } else { @() }
                Assert-ServerObjectSqlAccess -Server $Source @SourceAuth -Database $Database -DatabasePermissions $Permissions
            }
            if ($Item.SQLAgentJobsMigrationFlag -eq 'Yes') {
                $null = Invoke-ServerObjectPreflightQuery -Server $Source @SourceAuth -Database msdb -Query 'SELECT TOP (1) job_id FROM dbo.sysjobs;'
            }
            if ($Item.SQLLoginsMigrationFlag -eq 'Yes') {
                $WindowsLogins = @(Invoke-ServerObjectPreflightQuery -Server $Source @SourceAuth `
                    -Query "SELECT name FROM sys.server_principals WHERE type IN ('U','G') AND name NOT LIKE 'NT SERVICE\%' AND name NOT LIKE 'NT AUTHORITY\%' AND name NOT LIKE 'BUILTIN\%';")
                foreach ($Domain in @($WindowsLogins | ForEach-Object { ($_.name -split '\\', 2)[0] } | Where-Object { $_ } | Select-Object -Unique)) {
                    if ($Domain -ne ($Parts[0] -split '\.')[0]) { $null = Get-ADDomain -Identity $Domain -ErrorAction Stop }
                }
            }
        }
        $Executing = $Item.TargetExecutionFlag -eq 'Yes' -or $Item.OnlyTargetExecutionFlag -eq 'Yes'
        if ($Executing) {
            $Auth = if ($Platform -eq 'SQLMI') { @{ TenantId = $Item.TenantId; SubscriptionId = $Item.SubscriptionId } } else { @{} }
            $RequiresSysadmin = $Item.SQLAgentJobsMigrationFlag -eq 'Yes' -or $Item.SQLOperatorsMigrationFlag -eq 'Yes' -or
                $Item.SQLAlertsMigrationFlag -eq 'Yes' -or $Item.SQLDBMailMigrationFlag -eq 'Yes'
            $LoginPermissions = if ($Item.SQLLoginsMigrationFlag -eq 'Yes') { @('ALTER ANY LOGIN') } else { @() }
            Assert-ServerObjectSqlAccess -Server $Item.TargetServerName @Auth -RequireSysadmin:$RequiresSysadmin -ServerPermissions $LoginPermissions
            $Names = @(([string]$Item.SourceListofDatabases -split ',').Trim())
            if ($Names -contains 'All') {
                $Names = if ($Item.OnlyTargetExecutionFlag -ne 'Yes') { @($Databases) } else {
                    @(Invoke-ServerObjectPreflightQuery -Server $Item.TargetServerName -Query 'SELECT name FROM sys.databases WHERE database_id > 4;' @Auth | Select-Object -ExpandProperty name)
                }
            }
            $TargetSecurityDatabases = @()
            if ($Item.SQLLoginsMigrationFlag -eq 'Yes') {
                if ($Item.OnlyTargetExecutionFlag -ne 'Yes') {
                    $TargetSecurityDatabases = @($SecurityDatabases)
                }
                else {
                    $SystemDatabases = @(Invoke-ServerObjectPreflightQuery -Server $Item.TargetServerName @Auth `
                        -Query "SELECT name FROM sys.databases WHERE database_id <= 4 AND state_desc = 'ONLINE';" |
                        Select-Object -ExpandProperty name)
                    $TargetSecurityDatabases = @(Get-ServerObjectSecurityDatabaseNames -AvailableNames @(@($Names) + $SystemDatabases) `
                        -DatabaseList $DatabaseNames -Scope $Item.SQLLoginsMigrationScope)
                }
            }
            foreach ($Name in @(@($Names) + $TargetSecurityDatabases | Select-Object -Unique)) {
                $DatabasePermissions = if ($Name -in $TargetSecurityDatabases) { @('CONTROL') } else { @() }
                Assert-ServerObjectSqlAccess -Server $Item.TargetServerName -Database $Name @Auth -DatabasePermissions $DatabasePermissions
            }
        }
        $OutputRoot = if ($Options.ContainsKey('OutputRoot') -and $Options.OutputRoot) {
            [string]$Options.OutputRoot
        } else { Join-Path $ScriptsPath "..\output\Az$Platform" }
        Assert-ServiceOutputPath -Path (Join-Path $OutputRoot '.preflight')
        if ($Item.OnlyTargetExecutionFlag -eq 'Yes') {
            $RequiredFiles = [Collections.Generic.List[string]]::new()
            $BaseFolder = Join-Path $OutputRoot ($Item.SourceServerName.Trim() -replace '[\\/:*?"<>|]', '_')
            $ShortName = (($Source -split '\.')[0] -replace '[\\/:*?"<>|]', '_')
            foreach ($Flag in $Components.Keys) {
                if ($Item.$Flag -ne 'Yes') { continue }
                $Component = $Components[$Flag]
                if ($Flag -eq 'SQLLoginsMigrationFlag' -and $Platform -eq 'SQLMI') { $Component = @('SQL Logins MI', 'SQLLoginsMI') }
                $RequiredFiles.Add((Join-Path (Join-Path $BaseFolder $Component[0]) "$($ShortName)_$($Component[1]).sql"))
            }
            foreach ($File in $RequiredFiles) {
                if ($Options.ContainsKey('BlobPreview') -and $Options.BlobPreview) {
                    $Relative = [IO.Path]::GetRelativePath($OutputRoot, $File).Replace('\', '/')
                    if ($Relative -notin $Options.BlobFiles) { throw "Required filtered SQL file '$Relative' is missing from the snapshot." }
                    if ($Relative -in $Options.BlobEmptyFiles) { throw "Required filtered SQL file '$Relative' is empty in the snapshot." }
                } else { Assert-ServiceReadableFile -Path $File }
            }
        }
    }
    Write-Warning 'Read-only preflight cannot guarantee later writes, AD/SMTP/target-host routing, or future availability. No SQL or output files were changed.'
}
