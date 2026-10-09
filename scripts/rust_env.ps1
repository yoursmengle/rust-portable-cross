Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$rustTargetPayloadScript = Join-Path $PSScriptRoot "rust_target_payload.ps1"
if (-not (Test-Path -LiteralPath $rustTargetPayloadScript -PathType Leaf)) {
    throw "Missing Rust target payload helper: $rustTargetPayloadScript`nRun .\scripts\rust_setup.ps1 first."
}
. $rustTargetPayloadScript
$isolationScript = Join-Path $PSScriptRoot 'rust_build_isolation.ps1'
if (-not (Test-Path -LiteralPath $isolationScript -PathType Leaf)) {
    throw "Missing build isolation helper: $isolationScript"
}
. $isolationScript
$toolsRoot = Join-Path $root "tools"
$rustupBinRoot = Join-Path $toolsRoot "rustup"
$cargoHome = Join-Path $toolsRoot "cargo-home"
$rustupHome = Join-Path $toolsRoot "rustup-home"
$previousToolkitRoot = $env:RUST_PORTABLE_CROSS_ROOT
$zigRoot = Join-Path $toolsRoot "zig"
$zigLocalCache = Join-Path $toolsRoot "zig-local-cache"
$zigGlobalCache = Join-Path $toolsRoot "zig-global-cache"
$wrappersRoot = Join-Path $toolsRoot "wrappers"
$rustMsvcBin = Join-Path $rustupHome "toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\x86_64-pc-windows-msvc\bin"
$cargoExe = Join-Path $cargoHome "bin\cargo.exe"
$rustcExe = Join-Path $cargoHome "bin\rustc.exe"
$rustupExe = Join-Path $cargoHome "bin\rustup.exe"
$zigExe = Join-Path $zigRoot "zig.exe"
$requiredPaths = @(
    $cargoExe,
    $rustcExe,
    $rustupExe,
    $zigExe,
    $rustTargetPayloadScript
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
$env:RUSTUP_TOOLCHAIN = "1.98.0-x86_64-pc-windows-msvc"
$env:ZIG_LOCAL_CACHE_DIR = $zigLocalCache
$env:ZIG_GLOBAL_CACHE_DIR = $zigGlobalCache

Set-ToolkitPathPrefix -ToolkitRoot $root -PreviousToolkitRoot $previousToolkitRoot

foreach ($payloadDefinition in (Get-RustTargetPayloadDefinitions).Values) {
    try {
        $payloadStatus = Get-RustTargetPayloadStatus -RustcPath $rustcExe -TargetTriple $payloadDefinition.Triple
        if (-not $payloadStatus.IsComplete) {
            Write-Warning (Format-RustTargetPayloadFailure -Status $payloadStatus)
        }
    }
    catch {
        Write-Warning "Unable to validate Rust target payload $($payloadDefinition.Triple): $($_.Exception.Message)"
    }
}

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

# The unsuffixed AR / RANLIB are deliberately never set: cc-rs falls back to them
# for every target, including the host x86_64-pc-windows-msvc, where it calls the
# archiver lib.exe-style (-out:<path> -nologo). zig-ar is GNU-style and rejects
# that. Earlier activations did set them, so drop exactly those values; anything
# else belongs to the user and is kept.
$legacyGlobalArchivers = [ordered]@{
    AR = "zig-ar.cmd"
    RANLIB = "zig-ranlib.cmd"
}
foreach ($name in $legacyGlobalArchivers.Keys) {
    $current = [Environment]::GetEnvironmentVariable($name, "Process")
    if ([string]::IsNullOrEmpty($current)) {
        continue
    }
    if ($current -ieq $legacyGlobalArchivers[$name]) {
        Remove-Item -LiteralPath "Env:$name"
    }
    else {
        Write-Warning "$name is set to '$current'. cc-rs uses $name as the archiver for every target without an ${name}_<target> override, including the host x86_64-pc-windows-msvc; unset it if host crates with C sources fail to archive."
    }
}

if (Test-Path -LiteralPath (Join-Path $wrappersRoot "zig-ar.cmd")) {
    $env:AR_armv7_unknown_linux_musleabihf = "zig-ar.cmd"
    $env:AR_aarch64_unknown_linux_musl = "zig-ar.cmd"
    Set-Item -Path "Env:AR_armv7-unknown-linux-musleabihf" -Value "zig-ar.cmd"
    Set-Item -Path "Env:AR_aarch64-unknown-linux-musl" -Value "zig-ar.cmd"
}

if (Test-Path -LiteralPath (Join-Path $wrappersRoot "zig-ranlib.cmd")) {
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
$rustcVersion = [string]::Join([Environment]::NewLine, @(& $rustcExe -V 2>&1)).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Managed rustc could not be executed: $rustcVersion"
}
if ($rustcVersion -notmatch "^rustc 1\.98\.0(?:\s|$)") {
    throw "Expected pinned Rust 1.98.0, but managed rustc reported: $rustcVersion"
}

& $cargoExe -V
Write-Host $rustcVersion
& $rustupExe target list --installed
