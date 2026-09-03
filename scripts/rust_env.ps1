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
$rustMsvcBin = Join-Path $rustupHome "toolchains\stable-x86_64-pc-windows-msvc\lib\rustlib\x86_64-pc-windows-msvc\bin"
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

if (-not (Test-Path -LiteralPath (Join-Path $rustMsvcBin "rust-lld.exe") -PathType Leaf)) {
    throw "Missing required toolkit file: $(Join-Path $rustMsvcBin 'rust-lld.exe')`nRun .\scripts\rust_setup.ps1 first."
}

# The linker above is only half of what a host x86_64-pc-windows-msvc link needs;
# the other half is the import libraries it consumes. Warn rather than throw:
# rust_env is used for rustc -V and listing targets, not only for cargo builds.
# Every toolkit cargo build that links a host artifact needs these inputs,
# including thumbv7em / armv7 / aarch64 (cargo still compiles build.rs and
# proc-macros for the host).
$winSysrootLib = Join-Path $toolsRoot "sysroot\x86_64-pc-windows-msvc\lib"
$missingWinLinkInputs = @(
    @("kernel32.lib", "ntdll.lib", "userenv.lib", "ws2_32.lib", "dbghelp.lib", "msvcrt.lib", "rpc_winshim.lib") |
        Where-Object { -not (Test-Path -LiteralPath (Join-Path $winSysrootLib $_) -PathType Leaf) }
)
if ($missingWinLinkInputs.Count -gt 0) {
    Write-Warning "Missing Windows link inputs under $winSysrootLib ($($missingWinLinkInputs -join ', ')).`nEvery toolkit cargo build that links a host artifact (x86_64-pc-windows-msvc, plus thumbv7em / armv7 / aarch64 host build scripts) will fail until these are regenerated with .\scripts\build_win_link_inputs.ps1"
}

New-Item -ItemType Directory -Path $zigLocalCache -Force | Out-Null
New-Item -ItemType Directory -Path $zigGlobalCache -Force | Out-Null

$env:RUST_PORTABLE_CROSS_ROOT = $root
$env:CARGO_HOME = $cargoHome
$env:RUSTUP_HOME = $rustupHome
$env:ZIG_LOCAL_CACHE_DIR = $zigLocalCache
$env:ZIG_GLOBAL_CACHE_DIR = $zigGlobalCache
$env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-msvc"
$env:PATH = "$PSScriptRoot;$rustupBinRoot;$cargoHome\bin;$zigRoot;$wrappersRoot;$rustMsvcBin;$env:PATH"

$optionalWrapperMappings = @(
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
    Set-Item -Path "Env:AR_armv7-unknown-linux-musleabihf" -Value "zig-ar.cmd"
    Set-Item -Path "Env:AR_aarch64-unknown-linux-musl" -Value "zig-ar.cmd"
}

if (Test-Path -LiteralPath (Join-Path $wrappersRoot "zig-ranlib.cmd")) {
    $env:RANLIB = "zig-ranlib.cmd"
    $env:RANLIB_armv7_unknown_linux_musleabihf = "zig-ranlib.cmd"
    $env:RANLIB_aarch64_unknown_linux_musl = "zig-ranlib.cmd"
    Set-Item -Path "Env:RANLIB_armv7-unknown-linux-musleabihf" -Value "zig-ranlib.cmd"
    Set-Item -Path "Env:RANLIB_aarch64-unknown-linux-musl" -Value "zig-ranlib.cmd"
}

Write-Host "RUST_PORTABLE_CROSS_ROOT=$env:RUST_PORTABLE_CROSS_ROOT"
Write-Host "CARGO_HOME=$env:CARGO_HOME"
Write-Host "RUSTUP_HOME=$env:RUSTUP_HOME"
Write-Host "ZIG_LOCAL_CACHE_DIR=$env:ZIG_LOCAL_CACHE_DIR"
Write-Host "ZIG_GLOBAL_CACHE_DIR=$env:ZIG_GLOBAL_CACHE_DIR"
& $cargoExe -V
& $rustcExe -V
& $rustupExe target list --installed
