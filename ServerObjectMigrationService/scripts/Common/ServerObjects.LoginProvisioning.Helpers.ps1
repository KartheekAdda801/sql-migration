#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

#region Functions
function Assert-ServerObjectLoginTarget {
    <#
    .SYNOPSIS
        Validates principal types independently of administrative connection authentication.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$TargetType,
        [Parameter(Mandatory)][string]$LoginType,
        [Parameter(Mandatory)][string]$LoginName,
        [string]$TargetWindowsDomain = ''
    )
    $Allowed = switch ($TargetType) {
        SQLVM { @('SqlLogin', 'WindowsAD') }
        SQLMI { @('SqlLogin', 'EntraUser', 'EntraGroup', 'ManagedIdentity') }
        default { throw 'Login provisioning requires SQLVM or SQLMI.' }
    }
    if ($LoginType -notin $Allowed) { throw "Login Type '$LoginType' is not supported on $TargetType." }
    if ($LoginType -eq 'WindowsAD') {
        # The operator supplies the expected domain, not SourceDomainSuffix or
        # a DNS suffix. Target-side validation compares it with DEFAULT_DOMAIN().
        if ($TargetWindowsDomain -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,14}$') {
            throw 'WindowsAD requires TargetWindowsDomain: the verified NetBIOS domain of the target SQL VM.'
        }
        if ($LoginName -notmatch '^[^\\/@\s]+\x5c[^\\/@\s]+$' -or
            ($LoginName -split '\\', 2)[0] -ine $TargetWindowsDomain) {
            throw "WindowsAD requires a DOMAIN\user in TargetWindowsDomain '$TargetWindowsDomain'; UPNs, local accounts and other domains are not supported."
        }
    }
}

function Get-ServerObjectWindowsLoginValidationSql {
    <#
    .SYNOPSIS
        Generates read-only target default-domain, AD user and SID validation.
    .DESCRIPTION
        Compares the expected domain with SQL Server's DEFAULT_DOMAIN().
        The operator must independently verify the correct target domain.
        xp_logininfo can return no rows for an account without SQL access.
        Creation therefore also verifies the Windows user type transactionally.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$LoginName,
        [Parameter(Mandatory)][string]$TargetWindowsDomain
    )
    Assert-ServerObjectLoginTarget -TargetType SQLVM -LoginType WindowsAD -LoginName $LoginName -TargetWindowsDomain $TargetWindowsDomain
    $Literal = "N'" + $LoginName.Replace("'", "''") + "'"
    $DomainLiteral = "N'" + $TargetWindowsDomain.Replace("'", "''") + "'"
    @"
DECLARE @TargetDefaultDomain nvarchar(128) = DEFAULT_DOMAIN();
IF NULLIF(LTRIM(RTRIM(@TargetDefaultDomain)), N'') IS NULL
    THROW 51000, 'Target SQL Server did not report a default Windows domain.', 1;
IF @TargetDefaultDomain COLLATE Latin1_General_100_CI_AS <> $DomainLiteral COLLATE Latin1_General_100_CI_AS
    THROW 51000, 'Target SQL Server default Windows domain does not match TargetWindowsDomain.', 1;
DECLARE @Account TABLE (
    [account name] nvarchar(128), [type] varchar(8), [privilege] varchar(9),
    [mapped login name] nvarchar(128), [permission path] nvarchar(128)
);
INSERT INTO @Account EXEC master.dbo.xp_logininfo @acctname = $Literal;
IF EXISTS (SELECT 1 FROM @Account WHERE [type] <> 'user' OR [account name] <> $Literal)
    THROW 51000, 'WindowsAD must resolve to a Windows domain user on the target, not a group.', 1;
DECLARE @ExpectedSid varbinary(85) = SUSER_SID($Literal, 1);
IF @ExpectedSid IS NULL
    THROW 51000, 'WindowsAD user could not be resolved on the target.', 1;
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = $Literal AND (type <> 'U' OR sid <> @ExpectedSid))
    THROW 51000, 'Existing WindowsAD login has a different type or SID.', 1;
"@
}
#endregion Functions
