# Wrapper: forwards args to zig cc (x86_64-windows-gnu), filtering flags
# that rustc injects for x86_64-pc-windows-gnu but zig's LLD does not support.
# Also add Rust's bundled self-contained MinGW prefixes so host link does not
# depend on any system GCC installation.
$unsupported = @(
    '-Wl,--disable-auto-image-base',
    '-Wl,-Bdynamic'
)

$selfContainedBinDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\x86_64-pc-windows-gnu\bin\self-contained"))
$selfContainedLibDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\x86_64-pc-windows-gnu\lib\self-contained"))
$selfContainedGcc = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\x86_64-pc-windows-gnu\bin\self-contained\x86_64-w64-mingw32-gcc.exe"))
$filteredArgs = New-Object 'System.Collections.Generic.List[string]'
$skipNext = $false
$requiresGccLinkFallback = $false

foreach ($a in $args) {
    $arg = [string]$a
    $normalizedArg = $arg.Trim('"')

    if ($skipNext) {
        $skipNext = $false
        continue
    }

    if ($normalizedArg -in $unsupported) {
        continue
    }

    # cc-rs may pass the Rust 4-tuple target, which zig rejects.
    if ($normalizedArg.StartsWith('--target=')) {
        continue
    }
    if ($normalizedArg -eq '--target' -or $normalizedArg -eq '-target') {
        $skipNext = $true
        continue
    }

    if ($normalizedArg -eq '-l:libpthread.a') {
        $filteredArgs.Add((Join-Path $selfContainedLibDir 'libpthread.a'))
        continue
    }

    # rustc uses `-Wl,<path>\\list.def` when linking proc-macro DLLs; zig's
    # linker frontend rejects this form, so fallback to the bundled GCC linker.
    if ($normalizedArg -match 'list\.def$') {
        $requiresGccLinkFallback = $true
    }

    $filteredArgs.Add($arg)
}

if ($requiresGccLinkFallback) {
    & $selfContainedGcc "-B$selfContainedBinDir" "-L$selfContainedLibDir" @filteredArgs
}
else {
    & $selfContainedGcc "-B$selfContainedBinDir" "-L$selfContainedLibDir" @filteredArgs
}
exit $LASTEXITCODE
