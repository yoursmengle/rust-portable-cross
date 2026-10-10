[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The Zig prune must remove only other platforms' files, keep everything the three
# toolkit targets use, refuse a layout it does not recognise, and never leave its root.

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\rust_zig_payload.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestFile {
    param([string]$Path)
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    [System.IO.File]::WriteAllText($Path, 'x')
}

$base = Join-Path ([System.IO.Path]::GetTempPath()) ('rpc-zig-payload-' + [guid]::NewGuid().ToString('N'))
try {
    $zig = Join-Path $base 'zig'
    $kept = @(
        'zig.exe',
        'lib\std\std.zig',
        'lib\compiler_rt\divti3.zig',
        'lib\include\stddef.h',
        'lib\libcxx\include\vector',
        'lib\libunwind\src\libunwind.cpp',
        'lib\libc\include\any-linux-any\linux\can.h',
        'lib\libc\include\any-windows-any\windows.h',
        'lib\libc\include\generic-musl\stdio.h',
        'lib\libc\include\arm-linux-any\asm\unistd.h',
        'lib\libc\include\arm-linux-musl\bits\alltypes.h',
        'lib\libc\include\aarch64-linux-any\asm\unistd.h',
        'lib\libc\include\aarch64-linux-musl\bits\alltypes.h',
        'lib\libc\musl\arch\arm\crt_arch.h',
        'lib\libc\musl\arch\aarch64\crt_arch.h',
        'lib\libc\musl\arch\generic\bits\errno.h',
        'lib\libc\musl\src\string\memcpy.c',
        'lib\libc\musl\src\string\arm\memcpy.S',
        'lib\libc\musl\src\string\aarch64\memcpy.S',
        'lib\libc\mingw\crt\crtexe.c',
        'lib\libc\mingw\lib-common\kernel32.def.in',
        'lib\libc\mingw\lib64\ws2_32.def'
    )
    $removed = @(
        'lib\libc\include\any-macos-any\mach\mach.h',
        'lib\libc\include\generic-glibc\stdio.h',
        'lib\libc\include\x86_64-linux-gnu\bits\wordsize.h',
        'lib\libc\include\x86_64-linux-musl\bits\alltypes.h',
        'lib\libc\include\wasm-wasi-musl\stdio.h',
        'lib\libc\include\riscv64-linux-musl\bits\alltypes.h',
        'lib\libc\glibc\csu\elf-init.c',
        'lib\libc\wasi\libc-top-half\x.c',
        'lib\libc\darwin\libSystem.tbd',
        'lib\libc\musl\arch\x86_64\crt_arch.h',
        'lib\libc\musl\arch\mips\crt_arch.h',
        'lib\libc\musl\src\string\x86_64\memcpy.s',
        'lib\libc\musl\src\math\i386\sqrt.c',
        'lib\libc\mingw\lib32\kernel32.def',
        'lib\libc\mingw\libarm32\kernel32.def'
    )
    foreach ($relative in $kept + $removed) { New-TestFile -Path (Join-Path $zig $relative) }

    # A neighbour that shares the root's name as a prefix must be untouched.
    $sibling = Join-Path $base 'zig-other\lib\libc\glibc\keep.c'
    New-TestFile -Path $sibling

    $count = Remove-UnusedZigPayload -ZigRoot $zig
    Assert-True ($count -gt 0) 'The prune removed nothing from an unpruned tree.'
    foreach ($relative in $kept) {
        Assert-True (Test-Path -LiteralPath (Join-Path $zig $relative) -PathType Leaf) "The prune removed a file the toolkit targets need: $relative"
    }
    foreach ($relative in $removed) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $zig $relative))) "The prune kept another platform's file: $relative"
    }
    Assert-True (Test-Path -LiteralPath $sibling -PathType Leaf) 'The prune touched a directory outside the Zig root.'
    Assert-True ((Remove-UnusedZigPayload -ZigRoot $zig) -eq 0) 'Pruning an already pruned tree must remove nothing.'

    # A libc tree missing something the kept targets need is not a layout to guess at.
    $odd = Join-Path $base 'odd'
    New-TestFile -Path (Join-Path $odd 'lib\std\std.zig')
    New-TestFile -Path (Join-Path $odd 'lib\libc\glibc\x.c')
    $threw = $false
    try { $null = Remove-UnusedZigPayload -ZigRoot $odd } catch { $threw = $_.Exception.Message -match 'Unexpected Zig layout' }
    Assert-True $threw 'An unrecognised Zig layout was pruned instead of refused.'
    Assert-True (Test-Path -LiteralPath (Join-Path $odd 'lib\libc\glibc\x.c')) 'A refused layout was modified.'

    # A Zig with no libc tree (a stub in a test toolkit) has nothing to prune.
    $stub = Join-Path $base 'stub'
    New-TestFile -Path (Join-Path $stub 'zig.exe')
    Assert-True ((Remove-UnusedZigPayload -ZigRoot $stub) -eq 0) 'A Zig without a libc tree must be left alone.'

    Write-Host 'zig_payload tests passed.'
}
finally {
    if (Test-Path -LiteralPath $base) { Remove-ManagedTree -Path $base }
}
