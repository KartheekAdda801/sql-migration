#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

function Read-ServiceConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $Configuration = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $Configuration -or $Configuration.schemaVersion -ne 1 -or
        $Configuration.Settings -isnot [pscustomobject]) {
        throw "Configuration '$Path' must contain schemaVersion 1 and a Settings object."
    }
    foreach ($Property in $Configuration.PSObject.Properties.Name) {
        if ($Property -notin @('schemaVersion', 'Settings', 'Items', '_comment')) {
            throw "Unknown configuration property '$Property' in '$Path'."
        }
    }
    if ($Configuration.PSObject.Properties['Items'] -and $Configuration.Items -isnot [array]) {
        throw "Items must be a JSON array in '$Path'."
    }
    return $Configuration
}

function Resolve-ServiceSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][Management.Automation.CommandInfo]$Command,
        [Parameter(Mandatory)][Collections.IDictionary]$Overrides
    )

    $Reserved = @('ConfigPath', 'WhatIf', 'Confirm', 'Verbose', 'Debug', 'ErrorAction',
        'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable', 'WarningVariable',
        'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')
    $Values = @{}
    foreach ($Property in $Configuration.Settings.PSObject.Properties) {
        if ($Property.Name -in $Reserved -or -not $Command.Parameters.ContainsKey($Property.Name)) {
            throw "Unknown or reserved setting '$($Property.Name)' for '$($Command.Name)'."
        }
        $Type = $Command.Parameters[$Property.Name].ParameterType
        if ($Type -eq [switch] -and $Property.Value -isnot [bool]) {
            throw "Setting '$($Property.Name)' must be a JSON boolean."
        }
        $Values[$Property.Name] = $Property.Value
    }
    foreach ($Name in $Overrides.Keys) {
        if ($Name -notin $Reserved) { $Values[$Name] = $Overrides[$Name] }
    }
    $Parameters = @($Command.ScriptBlock.Ast.ParamBlock.Parameters |
        Where-Object { $_.Name.VariablePath.UserPath -ne 'ConfigPath' } |
        ForEach-Object { $_.Extent.Text }) -join ",`n"
    $Binder = [scriptblock]::Create("[CmdletBinding()]param($Parameters)`nreturn ,`$PSBoundParameters")
    $Bound = & $Binder @Values
    $Result = @{}
    foreach ($Name in $Bound.Keys) {
        if ($Name -notin $Reserved) { $Result[$Name] = $Bound[$Name] }
    }
    return $Result
}

function Get-ServiceOptions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Management.Automation.CommandInfo]$Command)

    $Options = @{}
    foreach ($Name in $Command.Parameters.Keys) {
        $Variable = Get-Variable -Name $Name -Scope 1 -ErrorAction SilentlyContinue
        if ($Variable) { $Options[$Name] = $Variable.Value }
    }
    return $Options
}

function Assert-ServiceFields {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Items, [Parameter(Mandatory)][string[]]$Required)

    if (-not $Items.Count) { throw 'Configuration Items must contain at least one item.' }
    $Index = 0
    foreach ($Item in $Items) {
        $Index++
        foreach ($Name in $Required) {
            $Property = $Item.PSObject.Properties[$Name]
            if (-not $Property -or [string]::IsNullOrWhiteSpace([string]$Property.Value) -or
                [string]$Property.Value -match '[<>]') {
                throw "Preflight item ${Index}: '$Name' is missing, empty, or a placeholder."
            }
        }
    }
}

function Assert-ServiceReadableFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($Stream.Length -eq 0) { throw "Source file is empty: $Path" }
        $null = $Stream.ReadByte()
    }
    finally { $Stream.Dispose() }
}

function Assert-ServiceOutputPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $FullPath = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $FullPath -PathType Container) { throw "Output file path is a directory: $FullPath" }
    if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
        if ((Get-Item -LiteralPath $FullPath -ErrorAction Stop).IsReadOnly) { throw "Output file is read-only: $FullPath" }
    }
    $Parent = [IO.Path]::GetDirectoryName($FullPath)
    while (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
        $Next = [IO.Path]::GetDirectoryName($Parent)
        if (-not $Next -or $Next -eq $Parent) { throw "No accessible output parent for '$Path'." }
        $Parent = $Next
    }
    $null = Get-Item -LiteralPath $Parent -ErrorAction Stop
    if ($IsWindows) { $null = Get-Acl -LiteralPath $Parent -ErrorAction Stop }
}

function Assert-ServiceGuid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)

    $Guid = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$Guid) -or $Guid -eq [guid]::Empty) {
        throw "$Name must be a non-empty GUID."
    }
}
