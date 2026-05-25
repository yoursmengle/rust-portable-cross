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

$wrapperPath = Join-Path $toolkitRoot "tools\wrappers\aarch64-linux-musl-gcc.cmd"
if (-not (Test-Path -LiteralPath $wrapperPath)) {
    throw "AArch64 support is not installed. Missing wrapper: $wrapperPath"
}

$zigArPath = Join-Path $toolkitRoot "tools\wrappers\zig-ar.cmd"
$zigRanlibPath = Join-Path $toolkitRoot "tools\wrappers\zig-ranlib.cmd"
if (-not (Test-Path -LiteralPath $zigArPath)) {
    throw "Missing archive wrapper: $zigArPath"
}
if (-not (Test-Path -LiteralPath $zigRanlibPath)) {
    throw "Missing ranlib wrapper: $zigRanlibPath"
}

$env:CC_aarch64_unknown_linux_musl = "aarch64-linux-musl-gcc.cmd"
$env:AR_aarch64_unknown_linux_musl = "zig-ar.cmd"
$env:RANLIB_aarch64_unknown_linux_musl = "zig-ranlib.cmd"
Set-Item -Path "Env:CC_aarch64-unknown-linux-musl" -Value "aarch64-linux-musl-gcc.cmd"
Set-Item -Path "Env:AR_aarch64-unknown-linux-musl" -Value "zig-ar.cmd"
Set-Item -Path "Env:RANLIB_aarch64-unknown-linux-musl" -Value "zig-ranlib.cmd"

New-Item -ItemType Directory -Path $cargoDir -Force | Out-Null
Copy-Item -LiteralPath $configSource -Destination $configTarget -Force

cargo build --release --target aarch64-unknown-linux-musl
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed for aarch64-unknown-linux-musl with exit code $LASTEXITCODE."
}

Write-Host "Build output: $(Join-Path (Get-Location) 'target\aarch64-unknown-linux-musl\release')"
