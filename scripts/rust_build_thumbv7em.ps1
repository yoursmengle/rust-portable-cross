Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$env:RUSTUP_DIST_SERVER="https://mirrors.tuna.tsinghua.edu.cn/rustup"
$env:RUSTUP_UPDATE_ROOT="https://mirrors.tuna.tsinghua.edu.cn/rustup/rustup"

if (-not $env:RUST_PORTABLE_CROSS_ROOT -or -not $env:CARGO_HOME -or -not $env:RUSTUP_HOME) {
    throw "Toolkit environment is not active. Run .\scripts\rust_env.ps1 from the toolkit repository first."
}

if (-not (Test-Path -LiteralPath ".\Cargo.toml")) {
    throw "Cargo.toml not found in $(Get-Location). Change into a Rust project directory first."
}

$toolkitRoot = $env:RUST_PORTABLE_CROSS_ROOT
$configSource = Join-Path $toolkitRoot "config\.cargo\config.toml"
$cargoDir = Join-Path (Get-Location) ".cargo"
$configTarget = Join-Path $cargoDir "config.toml"

if (-not (Test-Path -LiteralPath $configSource)) {
    throw "Missing toolkit Cargo config at $configSource"
}

$isolationScript = Join-Path $PSScriptRoot "rust_build_isolation.ps1"
if (-not (Test-Path -LiteralPath $isolationScript -PathType Leaf)) {
    throw "Missing build isolation helper: $isolationScript"
}
. $isolationScript

function Sync-CargoConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $destinationDir = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Write-Host "Detected existing project Cargo config, keep unchanged: $Destination"
        return
    }
    elseif (Test-Path -LiteralPath $Destination) {
        throw "Cargo config path exists but is not a file: $Destination"
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

$rustBuildEnvironmentSnapshot = Save-RustBuildEnvironment
$windowsHostCargoConfig = $null
try {
Clear-RustBuildEnvironment

# thumbv7em-none-eabihf is a bare-metal (no_std) ARM Cortex-M4F/M7 target. It
# links with the bundled rust-lld and needs no external C cross-toolchain, no
# Zig wrapper, and no CC/AR/RANLIB overrides. Only the Windows MSVC host build
# scripts and proc-macros need a linker, so we still force rust-lld there.
Repair-CargoHostTargetConfig -ToolkitRoot $toolkitRoot -ProjectRoot (Get-Location).Path
Initialize-WindowsHostLinkInputs -ToolkitRoot $toolkitRoot
$windowsHostCargoConfig = New-WindowsHostCargoConfigFile -ToolkitRoot $toolkitRoot

Sync-CargoConfig -Source $configSource -Destination $configTarget

cargo build --release --target thumbv7em-none-eabihf --config $windowsHostCargoConfig
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed for thumbv7em-none-eabihf with exit code $LASTEXITCODE."
}

Write-Host "Build output: $(Join-Path (Get-Location) 'target\thumbv7em-none-eabihf\release')"
}
finally {
    if ($windowsHostCargoConfig -and (Test-Path -LiteralPath $windowsHostCargoConfig)) {
        Remove-Item -LiteralPath $windowsHostCargoConfig -Force -ErrorAction SilentlyContinue
    }
    Restore-RustBuildEnvironment -Snapshot $rustBuildEnvironmentSnapshot
}
