# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Captures security independently of execution configuration; replay never reads the source.
.DESCRIPTION
Requires the caller's Escape-SqlLiteral, Escape-SqlBracket and Invoke-SqlcmdLogged.
Extraction requires sysadmin to avoid catalog-visibility omissions and buffers all blocks
until every online database has been read successfully. Unsupported principal/securable
types fail closed (catalog queries require SQL Server 2016 or newer). Password hashes in
the returned objects must be protected as secrets. Contained password users, application
roles, credential-backed logins and availability-group permissions require a separately
reviewed migration and abort capture. WITHOUT LOGIN users require a restored database
because supported DDL cannot reproduce their SID.
Database scopes are explicit, including system databases. Login defaults are captured but
creation deliberately uses master; changing defaults is a separate post-restore decision.
SQLMI Windows mapping uses only the current, verified Azure context and exact Entra lookups.
It never changes that context or consults AD. SQLMI platform/version incompatibilities
(including password-hash versions or external-provider support) fail at execution, not skip.
Windows mapping requires Az.Accounts/Az.Resources and uses WITH OBJECT_ID to pin the
resolved identity. Unmatched Windows groups require an exact, unique Entra display name;
database-only Windows users additionally require the resolved target login to be provisioned.
#>

function ConvertTo-SecuritySnapshotHex {
    param($Value, [string]$Description)
    if ($Value -is [byte[]]) { return '0x' + [BitConverter]::ToString($Value).Replace('-', '') }
    if ([string]$Value -match '^0x(?:[0-9a-fA-F]{2})+$') { return [string]$Value }
    throw "Security snapshot cannot read $Description. Use a source sysadmin with password-hash visibility."
}

function ConvertFrom-SecuritySnapshotExternalSid {
    param($Sid)
    $Hex = ConvertTo-SecuritySnapshotHex $Sid 'external principal SID'
    if ($Hex.Length -ne 34) { throw 'External principal SID must contain a 16-byte Entra object ID; extraction cannot safely resolve this identity by display name.' }
    $Bytes = [byte[]]::new(16)
    for ($Index = 0; $Index -lt 16; $Index++) { $Bytes[$Index] = [Convert]::ToByte($Hex.Substring(2 + 2 * $Index, 2), 16) }
    ([guid]::new($Bytes)).ToString()
}

function New-SecuritySnapshotBlock {
    param([string]$Name, [string]$Kind, [string]$Database = '', [hashtable]$Metadata)
    $Block = [pscustomobject][ordered]@{
        Component = 'SQLLogins'
        Name = $Name
        Kind = $Kind
        Database = $Database
        ServerSafe = ($Database -eq '' -or $Database -in @('master', 'msdb', 'model', 'tempdb'))
        DependsOnDatabases = @($(if ($Database) { $Database }))
        SourceEnabled = $true
        Sql = ''
        Metadata = [pscustomobject]$Metadata
    }
    $Block.Sql = ConvertTo-ServerObjectSecurityReplaySql -Block $Block -Item ([pscustomobject]@{ TargetType = 'SQLVM' }) -SourceFaithful
    $Block
}

function Get-SecuritySnapshotPermissionTarget {
    param($Row, [switch]$ServerScope)
    $Q = { param($Name) '[' + (Escape-SqlBracket ([string]$Name)) + ']' }
    $Class = [int]$Row.Class
    if ($ServerScope) {
        switch ($Class) {
            100 { return '' }
            101 { return "$($Row.SecurableType)::$(& $Q $Row.SecurableName)" }
            105 { return "ENDPOINT::$(& $Q $Row.SecurableName)" }
            default { throw "Unsupported server permission class $Class ($($Row.ClassDescription)); extraction aborted." }
        }
    }
    switch ($Class) {
        0 { return '' }
        1 {
            if (-not $Row.SchemaName -or -not $Row.SecurableName) { throw 'An object permission could not be resolved; extraction aborted.' }
            $Target = "OBJECT::$(& $Q $Row.SchemaName).$(& $Q $Row.SecurableName)"
            if ([int]$Row.MinorId -gt 0) {
                if (-not $Row.ColumnName) { throw 'A column permission could not be resolved; extraction aborted.' }
                $Target += " ($(& $Q $Row.ColumnName))"
            }
            return $Target
        }
        3 { $Type = 'SCHEMA' }
        4 { $Type = [string]$Row.SecurableType }
        5 { $Type = 'ASSEMBLY' }
        6 { $Type = 'TYPE' }
        10 { $Type = 'XML SCHEMA COLLECTION' }
        15 { $Type = 'MESSAGE TYPE' }
        16 { $Type = 'CONTRACT' }
        17 { $Type = 'SERVICE' }
        18 { $Type = 'REMOTE SERVICE BINDING' }
        19 { $Type = 'ROUTE' }
        23 { $Type = 'FULLTEXT CATALOG' }
        24 { $Type = 'SYMMETRIC KEY' }
        25 { $Type = 'CERTIFICATE' }
        26 { $Type = 'ASYMMETRIC KEY' }
        29 { $Type = 'FULLTEXT STOPLIST' }
        31 { $Type = 'SEARCH PROPERTY LIST' }
        32 { $Type = 'DATABASE SCOPED CREDENTIAL' }
        default { throw "Unsupported database permission class $Class ($($Row.ClassDescription)); extraction aborted." }
    }
    if (-not $Row.SecurableName -or -not $Type) { throw "Unresolved permission class $Class; extraction aborted." }
    $Name = & $Q $Row.SecurableName
    if ($Class -in @(6, 10)) { $Name = "$(& $Q $Row.SchemaName).$Name" }
    "${Type}::$Name"
}

function Get-OrderedSecuritySnapshotPermissions {
    param([AllowEmptyCollection()][object[]]$Rows)
    $Pending = [Collections.Generic.List[object]]::new()
    foreach ($Row in @($Rows | Sort-Object @{
        Expression = { if ($_.State -eq 'W' -or $_.PermissionName -in @('CONTROL', 'CONTROL SERVER')) { 0 } else { 1 } }
    }, Class, MinorId, GranteeName, PermissionName)) { $Pending.Add($Row) }
    while ($Pending.Count) {
        $Ready = $null
        foreach ($Row in $Pending) {
            $Dependencies = @($Pending | Where-Object {
                $Other = $_
                if ([object]::ReferenceEquals($Other, $Row)) { return $false }
                # Preserve object-level grants/denials before their column exceptions.
                if ([int]$Row.Class -eq 1 -and [int]$Row.MinorId -gt 0 -and
                    [int]$Other.Class -eq 1 -and [int]$Other.MinorId -eq 0 -and
                    $Other.GranteeName -eq $Row.GranteeName -and
                    $Other.SchemaName -eq $Row.SchemaName -and $Other.SecurableName -eq $Row.SecurableName -and
                    $Other.PermissionName -eq $Row.PermissionName) { return $true }
                if ($Other.GranteeName -ne $Row.GrantorName -or $Other.State -notin @('G', 'W')) { return $false }
                $CanGrant = $Other.State -eq 'W' -and $Other.PermissionName -eq $Row.PermissionName
                $CanGrant = $CanGrant -or $Other.PermissionName -in @('CONTROL', 'CONTROL SERVER')
                if (-not $CanGrant) { return $false }
                if ([int]$Other.Class -in @(0, 100)) { return $true }
                if ([int]$Other.Class -eq 3 -and $Other.SecurableName -eq $Row.SchemaName) { return $true }
                [int]$Other.Class -eq [int]$Row.Class -and $Other.SchemaName -eq $Row.SchemaName -and
                    $Other.SecurableName -eq $Row.SecurableName -and [int]$Other.MinorId -le [int]$Row.MinorId
            })
            if (-not $Dependencies.Count) { $Ready = $Row; break }
        }
        if ($null -eq $Ready) { throw 'Cyclic explicit permission/grantor dependencies require a reviewed replay order; extraction aborted.' }
        $Pending.Remove($Ready) | Out-Null
        $Ready
    }
}

function Get-ServerObjectSecuritySnapshotBlocks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server)

    $Blocks = [Collections.Generic.List[object]]::new()
    $Read = {
        param($Database, $Query, $Context)
        $Rows = @(Invoke-SqlcmdLogged -ServerInstance $Server -Database $Database -Query $Query -Context "SecuritySnapshot.$Context" -ErrorAction Stop)
        foreach ($Row in $Rows) {
            $Values = [ordered]@{}
            if ($Row -is [System.Data.DataRow]) {
                foreach ($Column in $Row.Table.Columns) {
                    $Value = $Row[$Column.ColumnName]
                    $Values[$Column.ColumnName] = if ($Value -is [DBNull]) { $null } else { $Value }
                }
            }
            else {
                foreach ($Property in $Row.PSObject.Properties) {
                    $Values[$Property.Name] = if ($Property.Value -is [DBNull]) { $null } else { $Property.Value }
                }
            }
            [pscustomobject]$Values
        }
    }
    $Access = @(& $Read 'master' @'
SELECT IS_SRVROLEMEMBER(N'sysadmin') AS IsSysadmin;
'@ 'Access')
    if ($Access.Count -ne 1 -or [int]$Access[0].IsSysadmin -ne 1) {
        throw 'Complete security extraction requires a source sysadmin (all catalogs and SQL password hashes).'
    }
    $Principals = @(& $Read 'master' @'
SELECT p.principal_id AS PrincipalId, p.name AS Name, p.type AS Type,
 p.is_fixed_role AS IsFixedRole, p.is_disabled AS IsDisabled,
 CONVERT(varchar(max),p.sid,1) AS Sid, p.default_database_name AS DefaultDatabase,
 p.default_language_name AS DefaultLanguage, s.is_policy_checked AS PolicyChecked,
 s.is_expiration_checked AS ExpirationChecked,
 CONVERT(varchar(max),s.password_hash,1) AS PasswordHash,
 CONVERT(int,LOGINPROPERTY(p.name,'IsMustChange')) AS MustChange,
 owner.name AS OwnerName, c.name AS CredentialName
FROM sys.server_principals p
LEFT JOIN sys.sql_logins s ON p.principal_id=s.principal_id
LEFT JOIN sys.server_principals owner ON owner.principal_id=p.owning_principal_id
LEFT JOIN sys.credentials c ON c.credential_id=p.credential_id
ORDER BY CASE WHEN p.type='R' THEN 1 ELSE 0 END,p.name;
'@ 'ServerPrincipals')
    $Protected = @{}
    $ServerTypes = @{}
    foreach ($P in $Principals) { $ServerTypes[[string]$P.Name] = [string]$P.Type }
    foreach ($P in $Principals) {
        $M = @{
            Name = [string]$P.Name; Type = [string]$P.Type; Sid = [string]$P.Sid
            DefaultDatabase = [string]$P.DefaultDatabase; DefaultLanguage = [string]$P.DefaultLanguage
            IsDisabled = [bool]$P.IsDisabled; PolicyChecked = [bool]$P.PolicyChecked
            ExpirationChecked = [bool]$P.ExpirationChecked; PasswordHash = [string]$P.PasswordHash
            OwnerName = [string]$P.OwnerName; IsFixedRole = ([bool]$P.IsFixedRole -or $P.Name -eq 'public')
            PrincipalId = [int]$P.PrincipalId
        }
        if ([int]$P.PrincipalId -eq 1 -or $P.Name -match '^(##|NT SERVICE\\|NT AUTHORITY\\|BUILTIN\\)') {
            $M.Reason = 'Internal or machine-bound principal: captured for review, never recreated or modified.'
            $Protected[[string]$P.Name] = $true
            $Blocks.Add((New-SecuritySnapshotBlock $P.Name 'ProtectedPrincipal' '' $M))
            continue
        }
        if ($P.Type -notin @('S', 'U', 'G', 'E', 'X', 'R')) { throw "Unsupported server principal '$($P.Name)' type '$($P.Type)' (certificate/asymmetric logins require separately reviewed key material)." }
        if ($P.CredentialName) { throw "Login '$($P.Name)' uses credential '$($P.CredentialName)'; credential secret extraction is unsupported." }
        if ($P.Type -eq 'S') {
            $M.Sid = ConvertTo-SecuritySnapshotHex $P.Sid "SID for $($P.Name)"
            $M.PasswordHash = ConvertTo-SecuritySnapshotHex $P.PasswordHash "password hash for $($P.Name)"
            if ($P.MustChange) { throw "Login '$($P.Name)' has MUST_CHANGE; hashed password replay cannot preserve that state." }
        }
        if ($P.Type -in @('E', 'X')) { $M.EntraObjectId = ConvertFrom-SecuritySnapshotExternalSid $P.Sid }
        $Kind = if ($P.Type -eq 'R') { 'ServerRole' } else { 'Login' }
        $Blocks.Add((New-SecuritySnapshotBlock $P.Name $Kind '' $M))
    }
    foreach ($P in $Principals | Where-Object { $_.Type -eq 'R' -and -not $_.IsFixedRole -and $_.Name -ne 'public' -and $_.OwnerName }) {
        $Blocks.Add((New-SecuritySnapshotBlock $P.Name 'ServerRoleOwner' '' @{
            Name = [string]$P.Name; OwnerName = [string]$P.OwnerName
            OwnerType = [string]$ServerTypes[[string]$P.OwnerName]
        }))
    }
    $Memberships = @(& $Read 'master' @'
SELECT r.name AS RoleName,m.name AS MemberName FROM sys.server_role_members rm
JOIN sys.server_principals r ON r.principal_id=rm.role_principal_id
JOIN sys.server_principals m ON m.principal_id=rm.member_principal_id ORDER BY r.name,m.name;
'@ 'ServerMemberships')
    foreach ($R in $Memberships) {
        $Blocks.Add((New-SecuritySnapshotBlock "$($R.RoleName)/$($R.MemberName)" 'ServerMembership' '' @{
            RoleName = [string]$R.RoleName; MemberName = [string]$R.MemberName
            MemberType = [string]$ServerTypes[[string]$R.MemberName]
            Protected = [bool]$Protected.ContainsKey([string]$R.MemberName)
        }))
    }
    $Permissions = @(& $Read 'master' @'
SELECT p.class AS Class,p.class_desc AS ClassDescription,p.state AS State,CAST(0 AS int) AS MinorId,
 p.permission_name AS PermissionName,g.name AS GranteeName,a.name AS GrantorName,
 CASE p.class WHEN 101 THEN s.name COLLATE DATABASE_DEFAULT
 WHEN 105 THEN e.name COLLATE DATABASE_DEFAULT END AS SecurableName,
 CASE WHEN s.type='R' THEN 'SERVER ROLE' ELSE 'LOGIN' END AS SecurableType
FROM sys.server_permissions p
JOIN sys.server_principals g ON g.principal_id=p.grantee_principal_id
JOIN sys.server_principals a ON a.principal_id=p.grantor_principal_id
LEFT JOIN sys.server_principals s ON p.class=101 AND s.principal_id=p.major_id
LEFT JOIN sys.endpoints e ON p.class=105 AND e.endpoint_id=p.major_id
ORDER BY g.name,p.class,p.major_id,p.permission_name,a.name;
'@ 'ServerPermissions')
    foreach ($R in @(Get-OrderedSecuritySnapshotPermissions -Rows $Permissions)) {
        $Target = Get-SecuritySnapshotPermissionTarget $R -ServerScope
        if ([int]$R.Class -ne 100 -and -not $R.SecurableName) { throw "Unresolved server permission for '$($R.GranteeName)'." }
        $Blocks.Add((New-SecuritySnapshotBlock "$($R.GranteeName)/$($R.PermissionName)/$Target" 'ServerPermission' '' @{
            GranteeName = [string]$R.GranteeName; GrantorName = [string]$R.GrantorName
            PermissionName = [string]$R.PermissionName; State = [string]$R.State
            Class = [int]$R.Class; Target = $Target; SecurableName = [string]$R.SecurableName
            SecurableType = [string]$R.SecurableType
            GranteeType = [string]$ServerTypes[[string]$R.GranteeName]
            GrantorType = [string]$ServerTypes[[string]$R.GrantorName]
            SecurablePrincipalType = [string]$ServerTypes[[string]$R.SecurableName]
            Protected = [bool]$Protected.ContainsKey([string]$R.GranteeName)
        }))
    }
    $Databases = @(& $Read 'master' @'
SELECT d.name AS Name,HAS_DBACCESS(d.name) AS HasAccess,p.name AS OwnerName,
 CONVERT(varchar(max),d.owner_sid,1) AS OwnerSid
FROM sys.databases d LEFT JOIN sys.server_principals p ON p.sid=d.owner_sid
WHERE d.state=0 ORDER BY d.database_id;
'@ 'Databases')
    foreach ($D in $Databases) {
        $Db = [string]$D.Name
        if ([int]$D.HasAccess -ne 1) { throw "Online database '$Db' is inaccessible; security snapshot aborted." }
        if ($D.OwnerSid -and -not $D.OwnerName) { throw "Database '$Db' has an unresolved owner SID '$($D.OwnerSid)'; resolve ownership before capture." }
        if ($D.OwnerName) {
            $Blocks.Add((New-SecuritySnapshotBlock $Db 'DatabaseOwner' $Db @{
                Name = $Db; OwnerName = [string]$D.OwnerName; OwnerSid = [string]$D.OwnerSid
                OwnerType = [string]$ServerTypes[[string]$D.OwnerName]
                Protected = ($Db -in @('master', 'msdb', 'model', 'tempdb') -or $Protected.ContainsKey([string]$D.OwnerName))
            }))
        }
        $Users = @(& $Read $Db @'
SELECT p.principal_id AS PrincipalId,p.name AS Name,p.type AS Type,
 p.authentication_type_desc AS AuthenticationType,p.is_fixed_role AS IsFixedRole,
 CONVERT(varchar(max),p.sid,1) AS Sid,p.default_schema_name AS DefaultSchema,
 l.name AS LoginName,l.type AS LoginType,o.name AS OwnerName,
 COALESCE(c.name COLLATE DATABASE_DEFAULT,k.name COLLATE DATABASE_DEFAULT) AS KeyName
FROM sys.database_principals p
LEFT JOIN sys.server_principals l ON l.sid=p.sid AND p.type<>'R'
LEFT JOIN sys.database_principals o ON o.principal_id=p.owning_principal_id
LEFT JOIN sys.certificates c ON p.type='C' AND c.sid=p.sid
LEFT JOIN sys.asymmetric_keys k ON p.type='K' AND k.sid=p.sid
ORDER BY CASE WHEN p.type='R' THEN 1 ELSE 0 END,p.name;
'@ 'DatabasePrincipals')
        foreach ($P in $Users) {
            $M = @{
                Name = [string]$P.Name; Type = [string]$P.Type; Sid = [string]$P.Sid
                AuthenticationType = [string]$P.AuthenticationType; IsFixedRole = ([bool]$P.IsFixedRole -or $P.Name -eq 'public')
                DefaultSchema = [string]$P.DefaultSchema; LoginName = [string]$P.LoginName
                LoginType = [string]$P.LoginType; OwnerName = [string]$P.OwnerName; KeyName = [string]$P.KeyName
            }
            if ($P.Type -in @('E', 'X')) { $M.EntraObjectId = ConvertFrom-SecuritySnapshotExternalSid $P.Sid }
            if ($P.Type -eq 'S' -and $P.AuthenticationType -eq 'NONE') { $M.RequiresRestoredDatabase = $true }
            if ($P.Name -match '^(##|NT SERVICE\\|NT AUTHORITY\\)' -or ([int]$P.PrincipalId -le 4 -and $P.Type -ne 'R')) {
                $M.Reason = 'Built-in database identity: creation is protected; explicit permissions are captured separately.'
                $Blocks.Add((New-SecuritySnapshotBlock $P.Name 'ProtectedPrincipal' $Db $M))
                continue
            }
            if ($P.Type -notin @('S', 'U', 'G', 'E', 'X', 'R', 'C', 'K')) { throw "Unsupported database principal '$Db/$($P.Name)' type '$($P.Type)'." }
            if ($P.Type -eq 'S' -and $P.AuthenticationType -eq 'DATABASE') { throw "Contained SQL user '$Db/$($P.Name)' password hash is not exposed by supported catalogs; extraction aborted." }
            if ($P.Type -eq 'S' -and $P.AuthenticationType -ne 'NONE' -and -not $P.LoginName) {
                throw "Orphaned user '$Db/$($P.Name)' has no source login for SID '$($P.Sid)'; restore its login before capture."
            }
            if ($P.Type -in @('U', 'G') -and -not $P.LoginName) { $M.WindowsWithoutLogin = $true }
            $Kind = if ($P.Type -eq 'R') { 'DatabaseRole' } else { 'DatabaseUser' }
            $Blocks.Add((New-SecuritySnapshotBlock $P.Name $Kind $Db $M))
        }
        foreach ($P in $Users | Where-Object { $_.Type -eq 'R' -and -not $_.IsFixedRole -and $_.Name -ne 'public' -and $_.OwnerName }) {
            $Blocks.Add((New-SecuritySnapshotBlock $P.Name 'DatabaseRoleOwner' $Db @{ Name = [string]$P.Name; OwnerName = [string]$P.OwnerName }))
        }
        $Schemas = @(& $Read $Db @'
SELECT s.name AS Name,p.name AS OwnerName FROM sys.schemas s
JOIN sys.database_principals p ON p.principal_id=s.principal_id
ORDER BY s.name;
'@ 'SchemaOwners')
        foreach ($S in $Schemas) {
            $Blocks.Add((New-SecuritySnapshotBlock $S.Name 'SchemaOwner' $Db @{
                Name = [string]$S.Name; OwnerName = [string]$S.OwnerName
                Protected = ($S.Name -in @('dbo', 'guest', 'sys', 'INFORMATION_SCHEMA'))
            }))
        }
        $Objects = @(& $Read $Db @'
SELECT s.name AS SchemaName,o.name AS Name,p.name AS OwnerName FROM sys.objects o
JOIN sys.schemas s ON s.schema_id=o.schema_id
JOIN sys.database_principals p ON p.principal_id=o.principal_id
WHERE o.is_ms_shipped=0 ORDER BY s.name,o.name;
'@ 'ObjectOwners')
        foreach ($O in $Objects) {
            $Blocks.Add((New-SecuritySnapshotBlock "$($O.SchemaName).$($O.Name)" 'ObjectOwner' $Db @{
                Name = [string]$O.Name; SchemaName = [string]$O.SchemaName; OwnerName = [string]$O.OwnerName
            }))
        }
        $Members = @(& $Read $Db @'
SELECT r.name AS RoleName,m.name AS MemberName FROM sys.database_role_members rm
JOIN sys.database_principals r ON r.principal_id=rm.role_principal_id
JOIN sys.database_principals m ON m.principal_id=rm.member_principal_id ORDER BY r.name,m.name;
'@ 'DatabaseMemberships')
        foreach ($R in $Members) {
            $Blocks.Add((New-SecuritySnapshotBlock "$($R.RoleName)/$($R.MemberName)" 'DatabaseMembership' $Db @{
                RoleName = [string]$R.RoleName; MemberName = [string]$R.MemberName
                Protected = ($R.MemberName -match '^(##|NT SERVICE\\|NT AUTHORITY\\)')
            }))
        }
        # Catalog name columns can have different collations even within a system database.
        $Permissions = @(& $Read $Db @'
SELECT p.class AS Class,p.class_desc AS ClassDescription,p.major_id AS MajorId,
 p.minor_id AS MinorId,p.state AS State,p.permission_name AS PermissionName,
 g.name AS GranteeName,a.name AS GrantorName,
 CASE p.class WHEN 1 THEN OBJECT_SCHEMA_NAME(p.major_id) COLLATE DATABASE_DEFAULT
 WHEN 6 THEN SCHEMA_NAME(t.schema_id) COLLATE DATABASE_DEFAULT
 WHEN 10 THEN SCHEMA_NAME(x.schema_id) COLLATE DATABASE_DEFAULT END AS SchemaName,
 CASE p.class WHEN 1 THEN OBJECT_NAME(p.major_id) COLLATE DATABASE_DEFAULT
 WHEN 3 THEN sc.name COLLATE DATABASE_DEFAULT WHEN 4 THEN dp.name COLLATE DATABASE_DEFAULT
 WHEN 5 THEN ass.name COLLATE DATABASE_DEFAULT WHEN 6 THEN t.name COLLATE DATABASE_DEFAULT
 WHEN 10 THEN x.name COLLATE DATABASE_DEFAULT WHEN 15 THEN mt.name COLLATE DATABASE_DEFAULT
 WHEN 16 THEN ct.name COLLATE DATABASE_DEFAULT WHEN 17 THEN sv.name COLLATE DATABASE_DEFAULT
 WHEN 18 THEN rb.name COLLATE DATABASE_DEFAULT WHEN 19 THEN rt.name COLLATE DATABASE_DEFAULT
 WHEN 23 THEN fc.name COLLATE DATABASE_DEFAULT WHEN 24 THEN sk.name COLLATE DATABASE_DEFAULT
 WHEN 25 THEN ce.name COLLATE DATABASE_DEFAULT WHEN 26 THEN ak.name COLLATE DATABASE_DEFAULT
 WHEN 29 THEN fs.name COLLATE DATABASE_DEFAULT WHEN 31 THEN sl.name COLLATE DATABASE_DEFAULT
 WHEN 32 THEN cr.name COLLATE DATABASE_DEFAULT END AS SecurableName,
 CASE dp.type WHEN 'R' THEN 'ROLE' WHEN 'A' THEN 'APPLICATION ROLE' ELSE 'USER' END AS SecurableType,
 COL_NAME(p.major_id,p.minor_id) AS ColumnName
FROM sys.database_permissions p
JOIN sys.database_principals g ON g.principal_id=p.grantee_principal_id
JOIN sys.database_principals a ON a.principal_id=p.grantor_principal_id
LEFT JOIN sys.schemas sc ON p.class=3 AND sc.schema_id=p.major_id
LEFT JOIN sys.database_principals dp ON p.class=4 AND dp.principal_id=p.major_id
LEFT JOIN sys.assemblies ass ON p.class=5 AND ass.assembly_id=p.major_id
LEFT JOIN sys.types t ON p.class=6 AND t.user_type_id=p.major_id
LEFT JOIN sys.xml_schema_collections x ON p.class=10 AND x.xml_collection_id=p.major_id
LEFT JOIN sys.service_message_types mt ON p.class=15 AND mt.message_type_id=p.major_id
LEFT JOIN sys.service_contracts ct ON p.class=16 AND ct.service_contract_id=p.major_id
LEFT JOIN sys.services sv ON p.class=17 AND sv.service_id=p.major_id
LEFT JOIN sys.remote_service_bindings rb ON p.class=18 AND rb.remote_service_binding_id=p.major_id
LEFT JOIN sys.routes rt ON p.class=19 AND rt.route_id=p.major_id
LEFT JOIN sys.fulltext_catalogs fc ON p.class=23 AND fc.fulltext_catalog_id=p.major_id
LEFT JOIN sys.symmetric_keys sk ON p.class=24 AND sk.symmetric_key_id=p.major_id
LEFT JOIN sys.certificates ce ON p.class=25 AND ce.certificate_id=p.major_id
LEFT JOIN sys.asymmetric_keys ak ON p.class=26 AND ak.asymmetric_key_id=p.major_id
LEFT JOIN sys.fulltext_stoplists fs ON p.class=29 AND fs.stoplist_id=p.major_id
LEFT JOIN sys.registered_search_property_lists sl ON p.class=31 AND sl.property_list_id=p.major_id
LEFT JOIN sys.database_scoped_credentials cr ON p.class=32 AND cr.credential_id=p.major_id
ORDER BY g.name,p.class,p.major_id,p.minor_id,p.permission_name,a.name;
'@ 'DatabasePermissions')
        foreach ($R in @(Get-OrderedSecuritySnapshotPermissions -Rows $Permissions)) {
            $Target = Get-SecuritySnapshotPermissionTarget $R
            $Blocks.Add((New-SecuritySnapshotBlock "$($R.GranteeName)/$($R.PermissionName)/$Target" 'DatabasePermission' $Db @{
                GranteeName = [string]$R.GranteeName; GrantorName = [string]$R.GrantorName
                PermissionName = [string]$R.PermissionName; State = [string]$R.State
                Class = [int]$R.Class; MinorId = [int]$R.MinorId; Target = $Target
                SecurableName = [string]$R.SecurableName; SecurableType = [string]$R.SecurableType
                Protected = ($R.GranteeName -match '^(##|NT SERVICE\\|NT AUTHORITY\\)')
            }))
        }
    }
    $Blocks.ToArray()
}

function Resolve-SecuritySnapshotEntraPrincipal {
    param([string]$Name, [string]$Type, $Item, [switch]$PassThru)
    if ($Type -notin @('U', 'G')) { return $Name }
    $Context = Get-AzContext -ErrorAction Stop
    if (-not $Item.TenantId -or -not $Item.SubscriptionId -or
        [string]$Context.Tenant.Id -ne [string]$Item.TenantId -or
        [string]$Context.Subscription.Id -ne [string]$Item.SubscriptionId) {
        throw "Windows principal '$Name' requires an authenticated Azure context matching configured TenantId and SubscriptionId; no context is changed automatically."
    }
    if ($Name -match '^(NT SERVICE|NT AUTHORITY|BUILTIN)\\') { throw "Machine-bound principal '$Name' cannot be mapped to Entra." }
    if ($Type -eq 'U') {
        $Upn = $Name
        if ($Name -notmatch '^[^\\@\s]+@[^\\@\s]+\.[^\\@\s]+$') {
            $Suffix = [string]$Item.JobOwnerUpnSuffix
            $Suffix = $Suffix.TrimStart('@')
            if ($Suffix -notmatch '^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$' -or
                $Name -notmatch '^[^\\]+\\([^\\@\s]+)$') {
                throw "Cannot map Windows user '$Name': supply a valid JobOwnerUpnSuffix or capture a valid UPN; AD/source lookup is forbidden."
            }
            $Account = ($Name -split '\\', 2)[1]
            $Upn = "$Account@$Suffix"
        }
        $Candidates = @(Get-AzADUser -UserPrincipalName $Upn -ErrorAction Stop | Where-Object { $_.UserPrincipalName -eq $Upn })
        if ($Candidates.Count -ne 1) { throw "Entra UPN '$Upn' for '$Name' resolved to $($Candidates.Count) users; provide a unique valid UPN/suffix." }
        $ResolvedName = [string]$Candidates[0].UserPrincipalName
        $ResolvedId = [string]$Candidates[0].Id
    }
    else {
        # Use the full captured name: dropping the Windows domain would guess an identity.
        $Candidates = @(Get-AzADGroup -DisplayName $Name -ErrorAction Stop | Where-Object { $_.DisplayName -eq $Name })
        if ($Candidates.Count -ne 1) {
            throw "Windows group '$Name' has no unique exact Entra display-name match. Provision/rename an unambiguous Entra group before replay; domain stripping and AD lookup are forbidden."
        }
        $ResolvedName = [string]$Candidates[0].DisplayName
        $ResolvedId = [string]$Candidates[0].Id
    }
    if ($PassThru) {
        $ObjectId = [guid]::Empty
        if (-not [guid]::TryParse($ResolvedId, [ref]$ObjectId) -or $ObjectId -eq [guid]::Empty) {
            throw "Entra lookup for '$Name' did not return a valid object ID; replay aborted."
        }
        return [pscustomobject]@{ Name = $ResolvedName; ObjectId = $ObjectId.ToString() }
    }
    $ResolvedName
}

function ConvertTo-ServerObjectSecurityReplaySql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Block,
        [Parameter(Mandatory)]$Item,
        [switch]$SourceFaithful
    )
    if ($Item.TargetType -notin @('SQLVM', 'SQLMI')) { throw "Unsupported security replay TargetType '$($Item.TargetType)'." }
    $M = $Block.Metadata
    if (-not $M) { throw "Security block '$($Block.Name)' lacks persisted Metadata; recapture the source." }
    $Q = { param($Name) '[' + (Escape-SqlBracket ([string]$Name)) + ']' }
    $L = { param($Name) "N'$(Escape-SqlLiteral ([string]$Name))'" }
    $Db = if ($Block.Database) { [string]$Block.Database } else { 'master' }
    $Prefix = "USE $(& $Q $Db);`n"
    $Name = [string]$M.Name
    $N = & $Q $Name
    $NL = & $L $Name
    if ($Block.Kind -eq 'ProtectedPrincipal' -or $M.Protected) {
        return $Prefix + "PRINT $(& $L "Protected source security entry '$($Block.Name)' retained in snapshot metadata; no target changes.");"
    }
    $IsMi = $Item.TargetType -eq 'SQLMI' -and -not $SourceFaithful
    switch ($Block.Kind) {
        Login {
            $Type = [string]$M.Type
            if ($IsMi -and $Type -in @('U', 'G')) {
                $Resolved = Resolve-SecuritySnapshotEntraPrincipal $Name $Type $Item -PassThru
                $Name = $Resolved.Name
                $N = & $Q $Name; $NL = & $L $Name
                $Create = "CREATE LOGIN $N FROM EXTERNAL PROVIDER WITH OBJECT_ID = '$($Resolved.ObjectId)';"
            }
            elseif ($Type -eq 'S') {
                $Sid = ConvertTo-SecuritySnapshotHex $M.Sid "SID for $Name"
                $Hash = ConvertTo-SecuritySnapshotHex $M.PasswordHash "password hash for $Name"
                $Policy = if ($M.PolicyChecked) { 'ON' } else { 'OFF' }
                $Expiry = if ($M.ExpirationChecked) { 'ON' } else { 'OFF' }
                $Create = "CREATE LOGIN $N WITH PASSWORD = $Hash HASHED, SID = $Sid, DEFAULT_DATABASE = [master], CHECK_POLICY = $Policy, CHECK_EXPIRATION = $Expiry"
                if ($M.DefaultLanguage) { $Create += ", DEFAULT_LANGUAGE = $(& $Q $M.DefaultLanguage)" }
                $Create += ';'
            }
            elseif ($Type -in @('U', 'G')) {
                $Create = "CREATE LOGIN $N FROM WINDOWS WITH DEFAULT_DATABASE = [master]"
                if ($M.DefaultLanguage) { $Create += ", DEFAULT_LANGUAGE = $(& $Q $M.DefaultLanguage)" }
                $Create += ';'
            }
            elseif ($Type -in @('E', 'X')) {
                $ObjectId = ConvertFrom-SecuritySnapshotExternalSid $M.Sid
                $Create = "CREATE LOGIN $N FROM EXTERNAL PROVIDER WITH OBJECT_ID = '$ObjectId';"
            }
            else { throw "Unsupported login type '$Type'." }
            # Never reset an existing login password, SID, enabled state, or defaults.
            $Disable = if ($M.IsDisabled) { "`nALTER LOGIN $N DISABLE;" } else { '' }
            return $Prefix + "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = $NL)`nBEGIN`n$Create$Disable`nEND;"
        }
        { $_ -in @('ServerRole', 'DatabaseRole') } {
            $Scope = if ($Block.Kind -eq 'ServerRole') { 'SERVER ' } else { '' }
            $Catalog = if ($Scope) { 'server' } else { 'database' }
            if ($M.IsFixedRole) { return $Prefix + "IF NOT EXISTS (SELECT 1 FROM sys.${Catalog}_principals WHERE name = $NL AND type = 'R') THROW 51000, N'Required built-in role is missing on target.', 1;" }
            $Authorization = if ($Scope) { '' } else { ' AUTHORIZATION [dbo]' }
            return $Prefix + "IF NOT EXISTS (SELECT 1 FROM sys.${Catalog}_principals WHERE name = $NL) CREATE ${Scope}ROLE $N$Authorization;"
        }
        { $_ -in @('ServerRoleOwner', 'DatabaseRoleOwner') } {
            $Scope = if ($Block.Kind -eq 'ServerRoleOwner') { 'SERVER ROLE' } else { 'ROLE' }
            $Owner = [string]$M.OwnerName
            if ($IsMi -and $Block.Kind -eq 'ServerRoleOwner') { $Owner = Resolve-SecuritySnapshotEntraPrincipal $Owner $M.OwnerType $Item }
            return $Prefix + "ALTER AUTHORIZATION ON ${Scope}::$N TO $(& $Q $Owner);"
        }
        SchemaOwner {
            return $Prefix + "ALTER AUTHORIZATION ON SCHEMA::$N TO $(& $Q $M.OwnerName);"
        }
        ObjectOwner {
            return $Prefix + "ALTER AUTHORIZATION ON OBJECT::$(& $Q $M.SchemaName).$N TO $(& $Q $M.OwnerName);"
        }
        DatabaseOwner {
            $Owner = [string]$M.OwnerName
            if ($IsMi) { $Owner = Resolve-SecuritySnapshotEntraPrincipal $Owner $M.OwnerType $Item }
            return $Prefix + "ALTER AUTHORIZATION ON DATABASE::$N TO $(& $Q $Owner);"
        }
        { $_ -in @('ServerMembership', 'DatabaseMembership') } {
            $ServerScope = $Block.Kind -eq 'ServerMembership'
            $Catalog = if ($ServerScope) { 'server' } else { 'database' }
            $Scope = if ($ServerScope) { 'SERVER ' } else { '' }
            $Member = [string]$M.MemberName
            if ($IsMi -and $ServerScope) { $Member = Resolve-SecuritySnapshotEntraPrincipal $Member $M.MemberType $Item }
            return $Prefix + @"
IF NOT EXISTS (SELECT 1 FROM sys.${Catalog}_role_members rm
JOIN sys.${Catalog}_principals r ON r.principal_id=rm.role_principal_id
JOIN sys.${Catalog}_principals m ON m.principal_id=rm.member_principal_id
WHERE r.name=$(& $L $M.RoleName) AND m.name=$(& $L $Member))
ALTER ${Scope}ROLE $(& $Q $M.RoleName) ADD MEMBER $(& $Q $Member);
"@
        }
        DatabaseUser {
            $Options = if ($M.DefaultSchema) { " WITH DEFAULT_SCHEMA = $(& $Q $M.DefaultSchema)" } else { '' }
            $Sid = ConvertTo-SecuritySnapshotHex $M.Sid "database SID for $Name"
            if ($M.LoginName -or ($IsMi -and $M.WindowsWithoutLogin)) {
                $Login = if ($M.LoginName) { [string]$M.LoginName } else { $Name }
                $LoginType = if ($M.LoginName) { [string]$M.LoginType } else { [string]$M.Type }
                if ($IsMi -and $LoginType -in @('U', 'G')) { $Login = Resolve-SecuritySnapshotEntraPrincipal $Login $LoginType $Item }
                $LoginL = & $L $Login; $LoginQ = & $Q $Login
                $Remap = if ($IsMi -and $LoginType -in @('U', 'G')) { "ALTER USER $N WITH LOGIN = $LoginQ;" } else { '' }
                $SidGuard = if (-not $Remap) { "IF SUSER_SID($LoginL) <> $Sid THROW 51000, N'Target login SID differs from captured source; existing login was not overwritten. Reconcile explicitly before database replay.', 1;" } else { '' }
                return $Prefix + @"
IF SUSER_ID($LoginL) IS NULL THROW 51000, N'Required target login is missing. Provision the resolved login before replaying this database user.', 1;
$SidGuard
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name=$NL AND sid<>$Sid AND sid<>SUSER_SID($LoginL))
    THROW 51000, N'Existing database user SID conflicts with captured source and target login; manual review required.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name=$NL)
    CREATE USER $N FOR LOGIN $LoginQ$Options;
$Remap
"@
            }
            if ($M.WindowsWithoutLogin) {
                if ($Name -notmatch '^[^\\]+\\[^\\]+$') { throw "Windows user '$Name' has no login and no captured DOMAIN\account identity; a reviewed identity mapping is required." }
                $Create = "CREATE USER $N$Options;"
            }
            elseif ($M.Type -in @('E', 'X')) {
                $ObjectId = ConvertFrom-SecuritySnapshotExternalSid $M.Sid
                $With = " WITH OBJECT_ID = '$ObjectId'"
                if ($M.DefaultSchema) { $With += ", DEFAULT_SCHEMA = $(& $Q $M.DefaultSchema)" }
                $Create = "CREATE USER $N FROM EXTERNAL PROVIDER$With;"
            }
            elseif ($M.Type -in @('C', 'K') -and $M.KeyName) {
                $KeyType = if ($M.Type -eq 'C') { 'CERTIFICATE' } else { 'ASYMMETRIC KEY' }
                $Create = "CREATE USER $N FROM $KeyType $(& $Q $M.KeyName);"
            }
            elseif ($M.AuthenticationType -eq 'NONE') {
                return $Prefix + @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name=$NL AND sid=$Sid)
    THROW 51000, N'WITHOUT LOGIN user requires its restored source database to preserve SID; supported CREATE USER cannot reproduce it.', 1;
"@
            }
            else { throw "Database user '$($Block.Database)/$Name' cannot be replayed from captured metadata." }
            return $Prefix + @"
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name=$NL AND sid<>$Sid)
    THROW 51000, N'Existing database user SID conflicts with captured source; manual review required.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name=$NL) $Create
"@
        }
        { $_ -in @('ServerPermission', 'DatabasePermission') } {
            if ($M.PermissionName -notmatch '^[A-Z][A-Z0-9 ]*$') { throw "Invalid permission name '$($M.PermissionName)'." }
            $Target = [string]$M.Target
            $GranteeName = [string]$M.GranteeName
            $GrantorName = [string]$M.GrantorName
            if ($IsMi -and $Block.Kind -eq 'ServerPermission') {
                $GranteeName = Resolve-SecuritySnapshotEntraPrincipal $GranteeName $M.GranteeType $Item
                $GrantorName = Resolve-SecuritySnapshotEntraPrincipal $GrantorName $M.GrantorType $Item
                if ([int]$M.Class -eq 101 -and $M.SecurablePrincipalType -in @('U', 'G')) {
                    $Principal = Resolve-SecuritySnapshotEntraPrincipal $M.SecurableName $M.SecurablePrincipalType $Item
                    $Target = "LOGIN::$(& $Q $Principal)"
                }
            }
            $On = if ($Target) { " ON $Target" } else { '' }
            $Grantee = & $Q $GranteeName
            $Grantor = if ($GrantorName) { " AS $(& $Q $GrantorName)" } else { '' }
            switch ([string]$M.State) {
                G { $Statement = "GRANT $($M.PermissionName)$On TO $Grantee$Grantor;" }
                W { $Statement = "GRANT $($M.PermissionName)$On TO $Grantee WITH GRANT OPTION$Grantor;" }
                D { $Statement = "DENY $($M.PermissionName)$On TO $Grantee$Grantor;" }
                R { $Statement = "REVOKE $($M.PermissionName)$On FROM $Grantee$Grantor;" }
                default { throw "Unsupported permission state '$($M.State)'." }
            }
            return $Prefix + $Statement
        }
        default { throw "Unsupported security snapshot kind '$($Block.Kind)'." }
    }
}
