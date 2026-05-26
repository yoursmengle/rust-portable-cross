Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

$wrapperPath = Join-Path $toolkitRoot "tools\wrappers\arm-linux-musleabihf-gcc.cmd"
if (-not (Test-Path -LiteralPath $wrapperPath)) {
    throw "ARMv7 support is not installed. Missing wrapper: $wrapperPath"
}

$zigArPath = Join-Path $toolkitRoot "tools\wrappers\zig-ar.cmd"
$zigRanlibPath = Join-Path $toolkitRoot "tools\wrappers\zig-ranlib.cmd"
if (-not (Test-Path -LiteralPath $zigArPath)) {
    throw "Missing archive wrapper: $zigArPath"
}
if (-not (Test-Path -LiteralPath $zigRanlibPath)) {
    throw "Missing ranlib wrapper: $zigRanlibPath"
}

$env:CC_armv7_unknown_linux_musleabihf = "arm-linux-musleabihf-gcc.cmd"
$env:AR_armv7_unknown_linux_musleabihf = "zig-ar.cmd"
$env:RANLIB_armv7_unknown_linux_musleabihf = "zig-ranlib.cmd"
Set-Item -Path "Env:CC_armv7-unknown-linux-musleabihf" -Value "arm-linux-musleabihf-gcc.cmd"
Set-Item -Path "Env:AR_armv7-unknown-linux-musleabihf" -Value "zig-ar.cmd"
Set-Item -Path "Env:RANLIB_armv7-unknown-linux-musleabihf" -Value "zig-ranlib.cmd"

Sync-CargoConfig -Source $configSource -Destination $configTarget

cargo build --release --target armv7-unknown-linux-musleabihf
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed for armv7-unknown-linux-musleabihf with exit code $LASTEXITCODE."
}

Write-Host "Build output: $(Join-Path (Get-Location) 'target\armv7-unknown-linux-musleabihf\release')"
