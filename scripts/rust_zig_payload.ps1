Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'rust_path_boundary.ps1')

# The bundled Zig serves exactly three C targets - arm-linux-musleabihf,
# aarch64-linux-musl and x86_64-windows-gnu (host C code) - plus its built-in
# ar / ranlib / lib / dlltool. Its lib\ directory also carries headers and libc
# sources for every other platform Zig can target: about 40% of the ~15k files,
# each of which is copied, hashed, compressed and installed on every release.
#
# Everything those three targets can reach is kept, including the whole C++
# runtime, std and compiler-rt. Only other platforms' files are removed.

$script:ZigLibcIncludeKeep = @(
    'any-linux-any',
    'any-windows-any',
    'generic-musl',
    'arm-linux-any',
    'arm-linux-musl',
    'aarch64-linux-any',
    'aarch64-linux-musl'
)

# Whole libc implementations for platforms the toolkit does not target.
$script:ZigLibcRemove = @('glibc', 'wasi', 'darwin')

# musl keeps one directory per architecture under arch\ and wherever a source
# directory has an architecture-specific override. arm, aarch64 and generic stay.
$script:ZigMuslArchRemove = @(
    'i386', 'loongarch64', 'm68k', 'mips', 'mips64', 'mipsn32', 'powerpc', 'powerpc64',
    'riscv32', 'riscv64', 's390x', 'x86_64', 'x32', 'microblaze', 'or1k', 'sh'
)

# mingw import definitions: x86_64 uses lib-common and lib64.
$script:ZigMingwRemove = @('lib32', 'libarm32')

function Get-UnusedZigPayloadDirectories {
    param([Parameter(Mandatory = $true)][string]$ZigRoot)

    $root = [System.IO.Path]::GetFullPath($ZigRoot).TrimEnd([char[]]@('\', '/'))
    $libc = Join-Path $root 'lib\libc'
    $include = Join-Path $libc 'include'
    $musl = Join-Path $libc 'musl'

    # No libc tree at all means there is nothing to prune (a stub Zig in a test
    # toolkit, for instance).
    if (-not [System.IO.Directory]::Exists($libc)) { return @() }

    # Refuse to guess on a layout this list was not written for.
    foreach ($required in @((Join-Path $root 'lib\std'), $musl, (Join-Path $libc 'mingw')) +
        @($script:ZigLibcIncludeKeep | ForEach-Object { Join-Path $include $_ })) {
        if (-not [System.IO.Directory]::Exists($required)) {
            throw "Unexpected Zig layout, refusing to prune: missing $required"
        }
    }

    $unused = New-Object 'System.Collections.Generic.List[string]'
    foreach ($directory in [System.IO.Directory]::GetDirectories($include)) {
        if ($script:ZigLibcIncludeKeep -notcontains [System.IO.Path]::GetFileName($directory)) { $unused.Add($directory) }
    }
    foreach ($name in $script:ZigLibcRemove) { $unused.Add((Join-Path $libc $name)) }
    foreach ($name in $script:ZigMingwRemove) { $unused.Add((Join-Path $libc "mingw\$name")) }
    foreach ($directory in [System.IO.Directory]::GetDirectories($musl, '*', [System.IO.SearchOption]::AllDirectories)) {
        if ($script:ZigMuslArchRemove -contains [System.IO.Path]::GetFileName($directory)) { $unused.Add($directory) }
    }

    return @($unused | Where-Object { [System.IO.Directory]::Exists($_) } | Sort-Object -Unique)
}

# Removes the files of platforms the toolkit does not target. Safe to repeat: an
# already pruned tree has nothing left to remove. Returns the number of
# directories removed.
function Remove-UnusedZigPayload {
    param([Parameter(Mandatory = $true)][string]$ZigRoot)

    $root = Assert-ManagedRootIsOrdinary -Path $ZigRoot
    $removed = 0
    foreach ($directory in (Get-UnusedZigPayloadDirectories -ZigRoot $root)) {
        # A nested match disappears with its parent.
        if (-not [System.IO.Directory]::Exists($directory)) { continue }
        if (-not (Test-ManagedPathInsideRoot -Root $root -Path $directory)) {
            throw "Refusing to remove a path outside the Zig root: $directory"
        }
        Remove-ManagedTree -Path $directory
        $removed++
    }
    return $removed
}
