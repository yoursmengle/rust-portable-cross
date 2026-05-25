Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $root "tools"
$rustupBinRoot = Join-Path $toolsRoot "rustup"
$cargoHome = Join-Path $toolsRoot "cargo-home"
$rustupHome = Join-Path $toolsRoot "rustup-home"
$zigRoot = Join-Path $toolsRoot "zig"
$zigLocalCache = Join-Path $toolsRoot "zig-local-cache"
$zigGlobalCache = Join-Path $toolsRoot "zig-global-cache"
$wrappersRoot = Join-Path $toolsRoot "wrappers"
$rustSelfContainedBin = Join-Path $rustupHome "toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\x86_64-pc-windows-gnu\bin\self-contained"
$cargoExe = Join-Path $cargoHome "bin\cargo.exe"
$rustcExe = Join-Path $cargoHome "bin\rustc.exe"
$rustupExe = Join-Path $cargoHome "bin\rustup.exe"
$zigExe = Join-Path $zigRoot "zig.exe"
$requiredPaths = @(
    $cargoExe,
    $rustcExe,
    $rustupExe,
    $zigExe
)

foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing required toolkit file: $path`nRun .\scripts\rust_setup.ps1 first."
    }
}

if (-not (Test-Path -LiteralPath $rustSelfContainedBin -PathType Container)) {
    throw "Missing required toolkit directory: $rustSelfContainedBin`nRun .\scripts\rust_setup.ps1 first."
}

New-Item -ItemType Directory -Path $zigLocalCache -Force | Out-Null
New-Item -ItemType Directory -Path $zigGlobalCache -Force | Out-Null

$env:RUST_PORTABLE_CROSS_ROOT = $root
$env:CARGO_HOME = $cargoHome
$env:RUSTUP_HOME = $rustupHome
$env:ZIG_LOCAL_CACHE_DIR = $zigLocalCache
$env:ZIG_GLOBAL_CACHE_DIR = $zigGlobalCache
$env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-gnu"
$env:PATH = "$PSScriptRoot;$rustupBinRoot;$cargoHome\bin;$zigRoot;$wrappersRoot;$rustSelfContainedBin;$env:PATH"

$optionalWrapperMappings = @(
    @{
        WrapperPath = Join-Path $wrappersRoot "x86_64-w64-mingw32-gcc.cmd"
        EnvVar = "CC_x86_64_pc_windows_gnu"
        WrapperName = "x86_64-w64-mingw32-gcc.cmd"
    },
    @{
        WrapperPath = Join-Path $wrappersRoot "arm-linux-musleabihf-gcc.cmd"
        EnvVar = "CC_armv7_unknown_linux_musleabihf"
        WrapperName = "arm-linux-musleabihf-gcc.cmd"
    },
    @{
        WrapperPath = Join-Path $wrappersRoot "aarch64-linux-musl-gcc.cmd"
        EnvVar = "CC_aarch64_unknown_linux_musl"
        WrapperName = "aarch64-linux-musl-gcc.cmd"
    }
)

foreach ($mapping in $optionalWrapperMappings) {
    if (Test-Path -LiteralPath $mapping.WrapperPath) {
        Set-Item -Path "Env:$($mapping.EnvVar)" -Value $mapping.WrapperName
    }
    elseif (Test-Path -LiteralPath "Env:$($mapping.EnvVar)") {
        Remove-Item -LiteralPath "Env:$($mapping.EnvVar)"
    }
}

if (Test-Path -LiteralPath (Join-Path $wrappersRoot "zig-ar.cmd")) {
    $env:AR = "zig-ar.cmd"
    $env:AR_armv7_unknown_linux_musleabihf = "zig-ar.cmd"
    $env:AR_aarch64_unknown_linux_musl = "zig-ar.cmd"
    $env:AR_x86_64_pc_windows_gnu = "zig-ar.cmd"
    Set-Item -Path "Env:AR_armv7-unknown-linux-musleabihf" -Value "zig-ar.cmd"
    Set-Item -Path "Env:AR_aarch64-unknown-linux-musl" -Value "zig-ar.cmd"
    Set-Item -Path "Env:AR_x86_64-pc-windows-gnu" -Value "zig-ar.cmd"
}

if (Test-Path -LiteralPath (Join-Path $wrappersRoot "zig-ranlib.cmd")) {
    $env:RANLIB = "zig-ranlib.cmd"
    $env:RANLIB_armv7_unknown_linux_musleabihf = "zig-ranlib.cmd"
    $env:RANLIB_aarch64_unknown_linux_musl = "zig-ranlib.cmd"
    $env:RANLIB_x86_64_pc_windows_gnu = "zig-ranlib.cmd"
    Set-Item -Path "Env:RANLIB_armv7-unknown-linux-musleabihf" -Value "zig-ranlib.cmd"
    Set-Item -Path "Env:RANLIB_aarch64-unknown-linux-musl" -Value "zig-ranlib.cmd"
    Set-Item -Path "Env:RANLIB_x86_64-pc-windows-gnu" -Value "zig-ranlib.cmd"
}

if (Test-Path -LiteralPath (Join-Path $wrappersRoot "zig-dlltool.cmd")) {
    $env:DLLTOOL = "zig-dlltool.cmd"
    $env:DLLTOOL_x86_64_pc_windows_gnu = "zig-dlltool.cmd"
    Set-Item -Path "Env:DLLTOOL_x86_64-pc-windows-gnu" -Value "zig-dlltool.cmd"

    $x64Rustflags = "-C dlltool=zig-dlltool.cmd"
    if ([string]::IsNullOrWhiteSpace($env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS)) {
        $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = $x64Rustflags
    }
    elseif ($env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS -notmatch [regex]::Escape("dlltool=zig-dlltool.cmd")) {
        $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = "$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS $x64Rustflags"
    }
}

# Provide sane defaults for cc-rs crates when users invoke `cargo build`
# directly without target-specific scripts.
if (Test-Path -LiteralPath (Join-Path $wrappersRoot "x86_64-w64-mingw32-gcc.cmd")) {
    $env:CC = "x86_64-w64-mingw32-gcc.cmd"
    $env:HOST_CC = "x86_64-w64-mingw32-gcc.cmd"
}

Write-Host "RUST_PORTABLE_CROSS_ROOT=$env:RUST_PORTABLE_CROSS_ROOT"
Write-Host "CARGO_HOME=$env:CARGO_HOME"
Write-Host "RUSTUP_HOME=$env:RUSTUP_HOME"
Write-Host "ZIG_LOCAL_CACHE_DIR=$env:ZIG_LOCAL_CACHE_DIR"
Write-Host "ZIG_GLOBAL_CACHE_DIR=$env:ZIG_GLOBAL_CACHE_DIR"
& $cargoExe -V
& $rustcExe -V
& $rustupExe target list --installed
