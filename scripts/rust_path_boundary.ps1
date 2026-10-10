Set-StrictMode -Version Latest

# Compare complete Windows path segments, never a bare textual prefix.
function Test-ManagedPathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if ([string]::Equals($rootFull, $pathFull.TrimEnd([char[]]@('\', '/')), [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    return $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

# Attributes of the entry itself, without following a final link, or $null when
# nothing is there. Release staging resolves every payload file several times, so
# this runs hundreds of thousands of times per build: [IO.File]::GetAttributes
# costs microseconds where Get-Item costs about a millisecond.
function Get-ManagedEntryAttributes {
    param([Parameter(Mandatory = $true)][string]$Path)

    try { return [System.IO.File]::GetAttributes($Path) }
    catch { return $null }
}

function Assert-ManagedRootIsOrdinary {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $volumeRoot = [System.IO.Path]::GetPathRoot($full)
    $tail = $full.Substring($volumeRoot.Length).Trim([char[]]@('\', '/'))
    $current = $volumeRoot.TrimEnd([char[]]@('\', '/'))
    if (-not $tail) { return $full }
    foreach ($segment in $tail.Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $current = $current + [System.IO.Path]::DirectorySeparatorChar + $segment
        $attributes = Get-ManagedEntryAttributes -Path $current
        # Nothing can exist below a missing segment.
        if ($null -eq $attributes) { break }
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Managed root traverses a reparse point: $current"
        }
    }
    return $full
}

function Resolve-ManagedRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RelativePath,
        [switch]$AllowInternalFileLink
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '^[A-Za-z]:' -or
        $RelativePath -match '[:*?"<>|]' -or
        $RelativePath.IndexOf([char]0) -ge 0) {
        throw "Unsafe managed relative path: $RelativePath"
    }

    $segments = @($RelativePath.Split([char[]]@('\', '/')))
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..' -or
            $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw "Unsafe managed relative path segment '$segment' in: $RelativePath"
        }
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $candidate = [System.IO.Path]::GetFullPath($rootFull.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar + [string]::Join([System.IO.Path]::DirectorySeparatorChar, $segments))
    if (-not (Test-ManagedPathInsideRoot -Root $rootFull -Path $candidate) -or
        [string]::Equals($rootFull.TrimEnd([char[]]@('\', '/')), $candidate.TrimEnd([char[]]@('\', '/')), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed path escapes its root: $RelativePath"
    }

    $current = $rootFull.TrimEnd([char[]]@('\', '/'))
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $current = $current + [System.IO.Path]::DirectorySeparatorChar + $segments[$i]
        # Get-ManagedEntryAttributes, inlined: this loop is the hottest in a release build.
        $attributes = $null
        try { $attributes = [System.IO.File]::GetAttributes($current) } catch { }
        # Nothing can exist below a missing segment.
        if ($null -eq $attributes) { break }
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { continue }

        # Only a reparse point - rare - pays for Get-Item's link details.
        $item = Get-Item -LiteralPath $current -Force
        $isFinal = ($i -eq $segments.Count - 1)
        if ($isFinal -and $AllowInternalFileLink -and -not $item.PSIsContainer -and $item.LinkType -eq 'SymbolicLink' -and $item.Target) {
            $target = @($item.Target)[0]
            $targetPath = if ([System.IO.Path]::IsPathRooted($target)) { $target } else { Join-Path (Split-Path -Parent $current) $target }
            $targetFull = [System.IO.Path]::GetFullPath($targetPath)
            if ((Test-ManagedPathInsideRoot -Root $rootFull -Path $targetFull) -and
                (Test-Path -LiteralPath $targetFull -PathType Leaf) -and
                (((Get-Item -LiteralPath $targetFull -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) {
                continue
            }
        }
        throw "Managed path traverses a reparse point: $current"
    }

    return $candidate
}

# Deletes a file or directory tree with one native recursive delete. The old
# per-file PowerShell loop spent ~30 s on the ~16k-file payload; this takes ~2 s.
# A link inside the tree is removed without descending into its target. Read-only
# entries (cargo and Inno both leave some) and files a just-exited process still
# holds are handled by clearing read-only and retrying.
function Remove-ManagedTree {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    for ($attempt = 1; ; $attempt++) {
        $attributes = $null
        try { $attributes = [System.IO.File]::GetAttributes($full) } catch { }
        if ($null -eq $attributes) { return }
        try {
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                [System.IO.Directory]::Delete($full, $true)
            }
            else {
                [System.IO.File]::SetAttributes($full, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Delete($full)
            }
            return
        }
        catch {
            if ($attempt -ge 5) { throw }
            Clear-ManagedTreeReadOnly -Path $full
            Start-Sleep -Milliseconds 300
        }
    }
}

# Walks the tree without following links and clears read-only, which blocks the
# native recursive delete.
function Clear-ManagedTreeReadOnly {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.Directory]::Exists($Path)) { return }
    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pending.Push([System.IO.DirectoryInfo]::new($Path))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        foreach ($entry in $directory.EnumerateFileSystemInfos()) {
            try {
                if (($entry.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                    $entry.Attributes = $entry.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                }
            }
            catch { }
            if ($entry -is [System.IO.DirectoryInfo] -and
                ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                $pending.Push($entry)
            }
        }
    }
}
