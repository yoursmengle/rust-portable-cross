Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'rust_transaction.ps1')

function Assert-PublishedParts {
    param([string]$Root, [object]$Manifest)

    if ($Manifest.partCount -ne @($Manifest.partFileNames).Count -or
        $Manifest.partCount -ne @($Manifest.partFileSizes).Count -or
        $Manifest.partCount -ne @($Manifest.partFileHashes).Count) {
        throw 'Published part manifest arrays have inconsistent lengths.'
    }
    [long]$total = 0
    for ($i = 0; $i -lt $Manifest.partCount; $i++) {
        $name = [string]$Manifest.partFileNames[$i]
        $path = Resolve-ManagedRelativePath -Root $Root -RelativePath $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing published part: $name" }
        $file = Get-Item -LiteralPath $path
        if ($file.Length -ne [long]$Manifest.partFileSizes[$i] -or
            -not [string]::Equals((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash,
                [string]$Manifest.partFileHashes[$i], [StringComparison]::OrdinalIgnoreCase)) {
            throw "Published part integrity mismatch: $name"
        }
        $total += $file.Length
    }
    if ($total -ne [long]$Manifest.originalSize) { throw 'Published part total size does not match installer size.' }
}

function Get-PartsRecombinedHash {
    param([string]$Root, [string[]]$Names)

    $sha = [Security.Cryptography.SHA256]::Create()
    $buffer = New-Object byte[] (1024 * 1024)
    try {
        foreach ($name in $Names) {
            $path = Resolve-ManagedRelativePath -Root $Root -RelativePath $name
            $stream = [IO.File]::OpenRead($path)
            try {
                while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $null = $sha.TransformBlock($buffer, 0, $count, $buffer, 0)
                }
            }
            finally { $stream.Dispose() }
        }
        $null = $sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Invoke-SplitPublication {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { throw "Installer output not found: $InstallerPath" }
    $chunkSize = 24 * 1024 * 1024
    $webDownloadDir = Join-Path (Split-Path -Parent $RepoPath) 'output\rust-portable-cross'
    New-Item -ItemType Directory -Path $webDownloadDir -Force | Out-Null
    $webDownloadDir = Assert-ManagedRootIsOrdinary -Path $webDownloadDir
    $privateRoot = Resolve-ManagedRelativePath -Root $webDownloadDir -RelativePath ('.publish-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $privateRoot -Force | Out-Null
    $publicationLock = $null
    try {
        $fileName = [IO.Path]::GetFileName($InstallerPath)
        $originalSize = (Get-Item -LiteralPath $InstallerPath).Length
        $originalHash = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $partNames = New-Object 'System.Collections.Generic.List[string]'
        $partSizes = New-Object 'System.Collections.Generic.List[long]'
        $partHashes = New-Object 'System.Collections.Generic.List[string]'
        $buffer = New-Object byte[] $chunkSize
        $stream = [IO.File]::OpenRead($InstallerPath)
        try {
            $index = 1
            while ($true) {
                $count = 0
                while ($count -lt $buffer.Length) {
                    $read = $stream.Read($buffer, $count, $buffer.Length - $count)
                    if ($read -eq 0) { break }
                    $count += $read
                }
                if ($count -eq 0) { break }
                $name = '{0}.part{1:D3}' -f $fileName, $index
                $partPath = Resolve-ManagedRelativePath -Root $privateRoot -RelativePath $name
                $partStream = [IO.File]::Create($partPath)
                try { $partStream.Write($buffer, 0, $count) }
                finally { $partStream.Dispose() }
                $partNames.Add($name)
                $partSizes.Add([long]$count)
                $partHashes.Add((Get-FileHash -LiteralPath $partPath -Algorithm SHA256).Hash.ToLowerInvariant())
                $index++
            }
        }
        finally { $stream.Dispose() }
        if ($partNames.Count -eq 0) { throw 'Installer is empty; no parts were produced.' }
        if ((Get-PartsRecombinedHash -Root $privateRoot -Names $partNames.ToArray()) -ne $originalHash) {
            throw 'Private parts do not reconstruct the installer SHA-256.'
        }
        $manifest = [ordered]@{
            originalFileName = $fileName
            version = $Version
            originalSize = $originalSize
            originalHash = $originalHash
            partCount = $partNames.Count
            partFileNames = $partNames.ToArray()
            partFileSizes = $partSizes.ToArray()
            partFileHashes = $partHashes.ToArray()
        }
        $publicationLock = Enter-ToolkitOperation -Root $webDownloadDir -Scope publication -Operation "publish-$Version"
        $manifestPath = Join-Path $webDownloadDir 'rust-portable-cross-offline.json'
        $previous = $null
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $previous = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            if ($previous.version -eq $Version -and
                $previous.originalHash -eq $originalHash -and
                [long]$previous.originalSize -eq [long]$originalSize -and
                $previous.originalFileName -eq $fileName) {
                # The same installer again: nothing to change, but prove what is there.
                Assert-PublishedParts -Root $webDownloadDir -Manifest $previous
                if ((Get-PartsRecombinedHash -Root $webDownloadDir -Names @($previous.partFileNames)) -ne $originalHash) {
                    throw 'Existing same-version parts do not reconstruct the installer SHA-256.'
                }
                return $webDownloadDir
            }
            if ($previous.version -eq $Version) {
                # A rebuild never reproduces the same bytes (timestamps, regenerated
                # link inputs), so building a version twice has to be able to replace it.
                Write-Warning "Version $Version was already published with a different installer; replacing it."
            }
        }

        # Part names carry the installer file name, so a part already at one of these
        # names belongs to an earlier build of this same version. Each one is set
        # aside before the new part moves in, and every step is recorded so a failure
        # puts the previous parts - and with them the previous manifest's promise -
        # back exactly as they were.
        $replacedRoot = Join-Path $privateRoot 'replaced'
        New-Item -ItemType Directory -Path $replacedRoot -Force | Out-Null
        $undo = New-Object 'System.Collections.Generic.Stack[object]'
        try {
            $stale = @(Get-ChildItem -LiteralPath $webDownloadDir -File -Filter "$fileName.part*" |
                Where-Object { $_.Name -match '\.part\d+$' -and $partNames -notcontains $_.Name })
            foreach ($file in $stale) {
                # A longer earlier build left parts this one does not have.
                $backup = Join-Path $replacedRoot $file.Name
                [IO.File]::Move($file.FullName, $backup)
                $undo.Push(@{ From = $backup; To = $file.FullName })
            }
            for ($i = 0; $i -lt $partNames.Count; $i++) {
                $name = $partNames[$i]
                $destination = Resolve-ManagedRelativePath -Root $webDownloadDir -RelativePath $name
                $privatePart = Resolve-ManagedRelativePath -Root $privateRoot -RelativePath $name
                if (Test-Path -LiteralPath $destination -PathType Leaf) {
                    if ((Get-Item -LiteralPath $destination).Length -eq $partSizes[$i] -and
                        [string]::Equals((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash,
                            $partHashes[$i], [StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }
                    $backup = Join-Path $replacedRoot $name
                    [IO.File]::Move($destination, $backup)
                    $undo.Push(@{ From = $backup; To = $destination })
                }
                [IO.File]::Move($privatePart, $destination)
                $undo.Push(@{ Remove = $destination })
            }
            Assert-PublishedParts -Root $webDownloadDir -Manifest ([pscustomobject]$manifest)
            if ((Get-PartsRecombinedHash -Root $webDownloadDir -Names $partNames.ToArray()) -ne $originalHash) {
                throw 'Published parts do not reconstruct the installer SHA-256.'
            }
            $privateManifest = Join-Path $privateRoot 'manifest.json'
            $manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $privateManifest -Encoding UTF8
            if (Test-Path -LiteralPath $manifestPath) {
                [IO.File]::Replace($privateManifest, $manifestPath, (Join-Path $privateRoot 'previous-manifest.json'))
            }
            else { Move-Item -LiteralPath $privateManifest -Destination $manifestPath }
        }
        catch {
            # The manifest is replaced last, so reaching here means it still names the
            # previous set. Undo in reverse so that set is whole again.
            while ($undo.Count -gt 0) {
                $step = $undo.Pop()
                try {
                    if ($step.ContainsKey('Remove')) {
                        if (Test-Path -LiteralPath $step.Remove) { [IO.File]::Delete($step.Remove) }
                    }
                    else { [IO.File]::Move($step.From, $step.To) }
                }
                catch { Write-Warning "Could not restore a previously published part: $($_.Exception.Message)" }
            }
            throw
        }
        return $webDownloadDir
    }
    finally {
        try { Exit-ToolkitOperation -Handle $publicationLock }
        finally {
            if (Test-Path -LiteralPath $privateRoot) {
                Remove-TransactionDirectory -ManagedRoot $webDownloadDir -Path $privateRoot
            }
        }
    }
}
