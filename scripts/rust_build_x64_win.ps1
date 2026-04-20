Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $env:RUST_PORTABLE_CROSS_ROOT -or -not $env:CARGO_HOME -or -not $env:RUSTUP_HOME) {
    throw "Toolkit environment is not active. Run .\scripts\rust_env.ps1 from the toolkit repository first."
}

if (-not (Test-Path -LiteralPath ".\Cargo.toml")) {
    throw "Cargo.toml not found in $(Get-Location). Change into a Rust project directory first."
}

# Windows host build uses Rust's built-in linker (no zig cc), so no custom
# cargo config is needed.  Remove any stale cross-compilation config that a
# previous build script may have copied into the project.
$cargoDir = Join-Path (Get-Location) ".cargo"
$configTarget = Join-Path $cargoDir "config.toml"
if (Test-Path -LiteralPath $configTarget) {
    Remove-Item -LiteralPath $configTarget -Force
}

cargo build --release
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed for Windows x64 with exit code $LASTEXITCODE."
}

Write-Host "Build output: $(Join-Path (Get-Location) 'target\release')"
