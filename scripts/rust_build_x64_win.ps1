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

$wrapperPath = Join-Path $toolkitRoot "tools\wrappers\x86_64-w64-mingw32-gcc.cmd"
if (-not (Test-Path -LiteralPath $wrapperPath)) {
    throw "x64_win support is not installed. Missing wrapper: $wrapperPath"
}

$selfContainedLibDir = Join-Path $toolkitRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\x86_64-pc-windows-gnu\lib\self-contained"
$libpthread = Join-Path $selfContainedLibDir "libpthread.a"
$libpthreadCompatAlias = Join-Path $selfContainedLibDir "libpthread.a.lib"
if ((Test-Path -LiteralPath $libpthread) -and -not (Test-Path -LiteralPath $libpthreadCompatAlias)) {
    Copy-Item -LiteralPath $libpthread -Destination $libpthreadCompatAlias -Force
}

New-Item -ItemType Directory -Path $cargoDir -Force | Out-Null
Copy-Item -LiteralPath $configSource -Destination $configTarget -Force

cargo build --release --target x86_64-pc-windows-gnu
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed for x86_64-pc-windows-gnu with exit code $LASTEXITCODE."
}

Write-Host "Build output: $(Join-Path (Get-Location) 'target\x86_64-pc-windows-gnu\release')"
