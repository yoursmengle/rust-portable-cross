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
$cargoExe = Join-Path $cargoHome "bin\cargo.exe"
$rustcExe = Join-Path $cargoHome "bin\rustc.exe"
$rustupExe = Join-Path $cargoHome "bin\rustup.exe"
$zigExe = Join-Path $zigRoot "zig.exe"
$requiredPaths = @(
    $cargoExe,
    $rustcExe,
    $rustupExe,
    $zigExe,
    (Join-Path $wrappersRoot "arm-linux-musleabihf-gcc.cmd"),
    (Join-Path $wrappersRoot "aarch64-linux-musl-gcc.cmd")
)

foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing required toolkit file: $path`nRun .\scripts\rust_setup.ps1 first."
    }
}

New-Item -ItemType Directory -Path $zigLocalCache -Force | Out-Null
New-Item -ItemType Directory -Path $zigGlobalCache -Force | Out-Null

$env:RUST_PORTABLE_CROSS_ROOT = $root
$env:CARGO_HOME = $cargoHome
$env:RUSTUP_HOME = $rustupHome
$env:ZIG_LOCAL_CACHE_DIR = $zigLocalCache
$env:ZIG_GLOBAL_CACHE_DIR = $zigGlobalCache
$env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-gnu"
$env:CC_armv7_unknown_linux_musleabihf = "arm-linux-musleabihf-gcc.cmd"
$env:CC_aarch64_unknown_linux_musl = "aarch64-linux-musl-gcc.cmd"
$env:PATH = "$PSScriptRoot;$rustupBinRoot;$cargoHome\bin;$zigRoot;$wrappersRoot;$env:PATH"

Write-Host "RUST_PORTABLE_CROSS_ROOT=$env:RUST_PORTABLE_CROSS_ROOT"
Write-Host "CARGO_HOME=$env:CARGO_HOME"
Write-Host "RUSTUP_HOME=$env:RUSTUP_HOME"
Write-Host "ZIG_LOCAL_CACHE_DIR=$env:ZIG_LOCAL_CACHE_DIR"
Write-Host "ZIG_GLOBAL_CACHE_DIR=$env:ZIG_GLOBAL_CACHE_DIR"
& $cargoExe -V
& $rustcExe -V
& $rustupExe target list --installed
