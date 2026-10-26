#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

# Reuse the DMS credential provider so named-file precedence and validation stay identical.
. (Join-Path $PSScriptRoot '..\..\..\DataMigrationService\scripts\Common\Target.Helpers.ps1')

function Initialize-ServerObjectSqlCredentials {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Items, [Parameter(Mandatory)][string]$ConfigPath,
        [hashtable]$SqlCredentials = @{})
    $Resolved = @{}
    $Cache = @{}
    $Directory = Split-Path -Parent (Get-Item -LiteralPath $ConfigPath -ErrorAction Stop).FullName
    $CredentialFilePath = Join-Path $Directory 'password.local.json'
    foreach ($Item in $Items) {
        if ($Item.Activity -eq 'Generate' -or $Item.TargetSqlAuthType -ne 'SqlLogin') { continue }
        $Credential = $null
        if ($SqlCredentials.ContainsKey($Item.Id)) {
            $Credential = $SqlCredentials[$Item.Id]
        }
        else {
            $Key = "$($Item.TargetSqlHost)|$($Item.TargetSqlPort)|$($Item.credential)|$($Item.SqlCredentialPath)|$($Item.SqlCredentialMode)|$($Item.SqlUserName)|$($Item.SqlPasswordEnvironmentVariable)"
            if (-not $Cache.ContainsKey($Key)) {
                $CredentialItem = $Item.PSObject.Copy()
                if ($Item.SqlCredentialPath -and -not [IO.Path]::IsPathRooted($Item.SqlCredentialPath)) {
                    $CredentialItem.SqlCredentialPath = Join-Path $Directory $Item.SqlCredentialPath
                }
                $Cache[$Key] = Get-DMSSqlCredential -Item $CredentialItem -CredentialFilePath $CredentialFilePath
            }
            $Credential = $Cache[$Key]
        }
        if ($Credential -isnot [pscredential] -or [string]::IsNullOrWhiteSpace($Credential.UserName) -or
            $Credential.Password.Length -eq 0) {
            throw "Item '$($Item.Id)' requires a nonempty PSCredential for SQL authentication; no fallback is attempted."
        }
        $Resolved[$Item.Id] = $Credential
    }
    return ,$Resolved
}
