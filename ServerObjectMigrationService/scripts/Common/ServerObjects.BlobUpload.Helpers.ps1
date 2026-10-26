#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT
#Requires -Version 7.0

#region Functions
function Get-ServerObjectSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $Algorithm = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($Algorithm.ComputeHash($Bytes)).Replace('-', '') }
    finally { $Algorithm.Dispose() }
}

function New-ServerObjectRunId {
    [CmdletBinding()]
    param()
    '{0}-{1}' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N')
}

function New-ServerObjectRunDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { throw "Run directory already exists: $Path" }
    $Directory = [IO.Directory]::CreateDirectory($Path)
    if ($IsWindows) {
        $Security = [Security.AccessControl.DirectorySecurity]::new()
        $Security.SetAccessRuleProtection($true, $false)
        $Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $Security.SetOwner($Sid)
        $Rule = [Security.AccessControl.FileSystemAccessRule]::new($Sid, 'FullControl',
            'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $Security.AddAccessRule($Rule)
        Set-Acl -LiteralPath $Directory.FullName -AclObject $Security -ErrorAction Stop
    }
    $Directory.FullName
}

function Get-ServerObjectBlobPrefix {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)
    ''
}

function Get-ServerObjectStorage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [switch]$Create)
    Import-Module Az.Accounts, Az.Storage -ErrorAction Stop
    $Context = Get-AzContext -ErrorAction Stop
    if (-not $Context -or $Context.Tenant.Id -ne $Item.TenantId) {
        throw "Authenticate to tenant '$($Item.TenantId)' with Connect-AzAccount first."
    }
    $null = Set-AzContext -TenantId $Item.TenantId -SubscriptionId $Item.SubscriptionId -Scope Process -Confirm:$false -WhatIf:$false -ErrorAction Stop
    $null = Get-AzStorageAccount -ResourceGroupName $Item.StorageResourceGroup -Name $Item.StorageAccountName -ErrorAction Stop
    $StorageContext = New-AzStorageContext -StorageAccountName $Item.StorageAccountName -UseConnectedAccount -ErrorAction Stop
    $Containers = @(Get-AzStorageContainer -Context $StorageContext -ErrorAction Stop | Where-Object Name -eq $Item.StorageContainer)
    if ($Containers.Count -gt 1) { throw 'Storage container lookup returned multiple matches.' }
    if (-not $Containers.Count) {
        if (-not $Item.CreateContainerIfMissing -or $Item.Activity -eq 'Execute') {
            throw "Snapshot container '$($Item.StorageContainer)' does not exist."
        }
        if (-not $Create) {
            Write-Warning "Private container '$($Item.StorageContainer)' will be created during generation; creation authorization is not proven by read-only preflight."
            return $null
        }
        $Containers = @(New-AzStorageContainer -Name $Item.StorageContainer -Context $StorageContext -Permission Off -ErrorAction Stop)
    }
    $Container = $Containers[0]
    if ([string]$Container.PublicAccess -notin @('Off', 'None', 'Private')) {
        throw "Snapshot container '$($Item.StorageContainer)' must be private. Public access is not changed automatically."
    }
    if (-not $Container.BlobContainerClient) { throw 'Az.Storage must expose BlobContainerClient; update the migration prerequisites.' }
    $Container.BlobContainerClient
}

function Read-ServerObjectBlob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Client, [Parameter(Mandatory)][string]$Name)
    $Response = $Client.GetBlobClient($Name).DownloadContent()
    return ,([byte[]]$Response.Value.Content.ToArray())
}

function Write-ServerObjectBlob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Client, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][byte[]]$Bytes)
    $Options = [Azure.Storage.Blobs.Models.BlobUploadOptions]::new()
    $Stream = [IO.MemoryStream]::new($Bytes, $false)
    try { $null = $Client.GetBlobClient($Name).Upload($Stream, $Options, [Threading.CancellationToken]::None) }
    finally { $Stream.Dispose() }
}

function Get-ServerObjectBlobNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Client, [AllowEmptyString()][string]$Prefix = '')
    $SearchPrefix = if ($Prefix) { "$Prefix/" } else { $null }
    foreach ($Blob in $Client.GetBlobs([Azure.Storage.Blobs.Models.BlobTraits]::None,
            [Azure.Storage.Blobs.Models.BlobStates]::None, $SearchPrefix, [Threading.CancellationToken]::None)) {
        $Blob.Name
    }
}

function Remove-ServerObjectBlob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Client, [Parameter(Mandatory)][string]$Name)
    $null = $Client.GetBlobClient($Name).DeleteIfExists()
}

function Resolve-ServerObjectBlobFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    $Segments = $RelativePath.Split('/')
    foreach ($Segment in $Segments) {
        if (-not $Segment -or $Segment -in @('.', '..') -or $Segment -match '[\\:*?"<>|\x00-\x1f]' -or
            $Segment -match '[. ]$' -or $Segment -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
            throw "Unsafe snapshot path '$RelativePath'."
        }
    }
    $FullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $FullPath = [IO.Path]::GetFullPath((Join-Path $Root ($Segments -join '\')))
    if (-not $FullPath.StartsWith($FullRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetExtension($FullPath) -ne '.sql') { throw "Unsafe SQL snapshot path '$RelativePath'." }
    $FullPath
}

function Publish-ServerObjectBlobSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Root
    )
    $Files = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop)
    if (@($Files | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
        throw 'Snapshot input cannot contain symbolic links or reparse points.'
    }
    $SqlFiles = @($Files | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.sql' } | Sort-Object FullName)
    $ExpectedPaths = @(Get-ServerObjectSnapshotPaths)
    if ($SqlFiles.Count -ne $ExpectedPaths.Count) { throw 'Generation must produce all seven All/Server snapshot SQL files, including empty components.' }
    foreach ($File in $SqlFiles) {
        $Relative = [IO.Path]::GetRelativePath($Root, $File.FullName).Replace('\', '/')
        $null = Resolve-ServerObjectBlobFile -Root $Root -RelativePath $Relative
        if ($Relative -cnotin $ExpectedPaths) { throw "Unexpected snapshot SQL path '$Relative'." }
    }
    $Client = Get-ServerObjectStorage -Item $Item -Create
    Reset-ServerObjectBlobContainer -Client $Client -Item $Item
    $Entries = [Collections.Generic.List[object]]::new()
    foreach ($File in $SqlFiles) {
        $Relative = [IO.Path]::GetRelativePath($Root, $File.FullName).Replace('\', '/')
        $null = Resolve-ServerObjectBlobFile -Root $Root -RelativePath $Relative
        $Bytes = [IO.File]::ReadAllBytes($File.FullName)
        $Hash = Get-ServerObjectSha256 -Bytes $Bytes
        Write-ServerObjectBlob -Client $Client -Name $Relative -Bytes $Bytes
        $Entries.Add([pscustomobject]@{ path = $Relative; length = $Bytes.LongLength; sha256 = $Hash })
    }
    $Manifest = [ordered]@{
        schemaVersion = 4; kind = 'SourceSnapshot'; runId = $RunId; createdUtc = [datetime]::UtcNow.ToString('o')
        source = $Item.SourceServerName; targetType = $Item.TargetType
        tenantId = $Item.TenantId; subscriptionId = $Item.SubscriptionId
        files = $Entries.ToArray()
    }
    $ManifestBytes = [Text.Encoding]::UTF8.GetBytes(($Manifest | ConvertTo-Json -Depth 20))
    # The manifest is the completion marker; partial uploads are never replayable.
    Write-ServerObjectBlob -Client $Client -Name 'manifest.json' -Bytes $ManifestBytes
    [IO.File]::WriteAllBytes((Join-Path $Root 'manifest.json'), $ManifestBytes)
    "https://$($Item.StorageAccountName).blob.core.windows.net/$($Item.StorageContainer)/manifest.json"
}

function Get-ServerObjectSnapshotPaths {
    [CmdletBinding()]
    param()
    foreach ($Component in @('SQLLogins', 'SQLAgentJobs', 'SQLOperators', 'SQLAlerts', 'SQLDBMail')) {
        "$Component/${Component}_Server.sql"
        if ($Component -in @('SQLLogins', 'SQLAgentJobs')) { "$Component/${Component}_All.sql" }
    }
}

function Reset-ServerObjectBlobContainer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Client, [Parameter(Mandatory)][object]$Item)
    $Names = @(Get-ServerObjectBlobNames -Client $Client)
    if ($Names.Count) {
        if ('manifest.json' -cnotin $Names) {
            throw "Refusing to replace nonempty container '$($Item.StorageContainer)' without an ownership manifest. Review/recover its contents manually."
        }
        $Previous = [Text.Encoding]::UTF8.GetString((Read-ServerObjectBlob -Client $Client -Name 'manifest.json')) |
            ConvertFrom-Json -ErrorAction Stop
        if ($Previous.schemaVersion -ne 4 -or $Previous.kind -ne 'SourceSnapshot' -or
            $Previous.source -ne $Item.SourceServerName -or $Previous.targetType -ne $Item.TargetType -or
            $Previous.tenantId -ne $Item.TenantId -or $Previous.subscriptionId -ne $Item.SubscriptionId) {
            throw "Refusing to replace container '$($Item.StorageContainer)': ownership/source/platform does not match."
        }
        $ManagedNames = @('manifest.json') + @(Get-ServerObjectSnapshotPaths)
        if (@($Names | Where-Object { $_ -cnotin $ManagedNames }).Count) {
            throw "Refusing to replace container '$($Item.StorageContainer)' containing unmanaged blobs."
        }
    }
    $null = $Client.DeleteIfExists($null, [Threading.CancellationToken]::None)
    $Deadline = [datetime]::UtcNow.AddMinutes(2)
    while ($true) {
        try {
            $null = $Client.CreateIfNotExists([Azure.Storage.Blobs.Models.PublicAccessType]::None,
                $null, [Threading.CancellationToken]::None)
            break
        }
        catch {
            $Cause = $_.Exception
            while ($Cause.InnerException) { $Cause = $Cause.InnerException }
            if (-not $Cause.PSObject.Properties['ErrorCode'] -or $Cause.ErrorCode -ne 'ContainerBeingDeleted' -or
                [datetime]::UtcNow -ge $Deadline) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

function Read-ServerObjectBlobSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)
    $Client = Get-ServerObjectStorage -Item $Item
    $ManifestBytes = Read-ServerObjectBlob -Client $Client -Name 'manifest.json'
    if ($ManifestBytes.Length -gt 10MB) { throw 'Snapshot manifest exceeds 10 MiB.' }
    $Manifest = [Text.Encoding]::UTF8.GetString($ManifestBytes) | ConvertFrom-Json -ErrorAction Stop
    if ($Manifest.schemaVersion -in @(1, 2, 3)) {
        throw "Unsupported snapshot manifest version $($Manifest.schemaVersion): regenerate the snapshot with the current security-scope and in-place update rules before execution."
    }
    if (($Manifest.schemaVersion -isnot [long] -and $Manifest.schemaVersion -isnot [int]) -or
        $Manifest.schemaVersion -ne 4 -or $Manifest.kind -ne 'SourceSnapshot' -or
        $Manifest.source -ne $Item.SourceServerName -or
        $Manifest.targetType -ne $Item.TargetType -or $Manifest.tenantId -ne $Item.TenantId -or
        $Manifest.subscriptionId -ne $Item.SubscriptionId -or -not @($Manifest.files).Count -or
        @($Manifest.files).Count -ne 7 -or $Manifest.files -isnot [array]) {
        throw 'Snapshot manifest is incomplete, unsupported, or belongs to another source/target/item.'
    }
    $Names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $Verified = [Collections.Generic.List[object]]::new()
    foreach ($Entry in $Manifest.files) {
        $null = Resolve-ServerObjectBlobFile -Root ([IO.Path]::GetTempPath()) -RelativePath $Entry.path
        if ($Entry.path -cnotin @(Get-ServerObjectSnapshotPaths) -or -not $Names.Add($Entry.path) -or $Entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
            $Entry.length -isnot [long] -and $Entry.length -isnot [int] -or $Entry.length -lt 0) {
            throw 'Snapshot contains duplicate paths or invalid file integrity metadata.'
        }
        $Bytes = Read-ServerObjectBlob -Client $Client -Name $Entry.path
        if ($Bytes.LongLength -ne $Entry.length -or
            (Get-ServerObjectSha256 -Bytes $Bytes) -ne $Entry.sha256) {
            throw "Snapshot integrity verification failed for '$($Entry.path)'. No target SQL was executed."
        }
        $Verified.Add([pscustomobject]@{ Path = $Entry.path; Bytes = $Bytes })
    }
    [pscustomobject]@{ Manifest = $Manifest; Files = $Verified.ToArray() }
}

function Save-ServerObjectBlobSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Snapshot, [Parameter(Mandatory)][string]$Root)
    foreach ($File in $Snapshot.Files) {
        $Path = Resolve-ServerObjectBlobFile -Root $Root -RelativePath $File.Path
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
        [IO.File]::WriteAllBytes($Path, $File.Bytes)
    }
}
#endregion Functions
