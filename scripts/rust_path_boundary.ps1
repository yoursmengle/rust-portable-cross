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

function Assert-ManagedRootIsOrdinary {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $volumeRoot = [System.IO.Path]::GetPathRoot($full)
    $tail = $full.Substring($volumeRoot.Length).Trim([char[]]@('\', '/'))
    $current = $volumeRoot
    if (-not $tail) { return $full }
    foreach ($segment in $tail.Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
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
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull ([string]::Join([System.IO.Path]::DirectorySeparatorChar, $segments))))
    if (-not (Test-ManagedPathInsideRoot -Root $rootFull -Path $candidate) -or
        [string]::Equals($rootFull.TrimEnd([char[]]@('\', '/')), $candidate.TrimEnd([char[]]@('\', '/')), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed path escapes its root: $RelativePath"
    }

    $current = $rootFull
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $current = Join-Path $current $segments[$i]
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { continue }

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
