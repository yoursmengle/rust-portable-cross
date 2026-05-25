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

# Some crates (for example ring via cc-rs) look for CC/HOST_CC or target CC
# env vars and otherwise try plain gcc.exe from host PATH.
$wrapperName = "x86_64-w64-mingw32-gcc.cmd"
$env:CC = $wrapperName
$env:HOST_CC = $wrapperName
$env:CC_x86_64_pc_windows_gnu = $wrapperName
Set-Item -Path "Env:CC_x86_64-pc-windows-gnu" -Value $wrapperName

$zigArPath = Join-Path $toolkitRoot "tools\wrappers\zig-ar.cmd"
$zigRanlibPath = Join-Path $toolkitRoot "tools\wrappers\zig-ranlib.cmd"
$zigDlltoolPath = Join-Path $toolkitRoot "tools\wrappers\zig-dlltool.cmd"
if (-not (Test-Path -LiteralPath $zigArPath)) {
    throw "Missing archive wrapper: $zigArPath"
}
if (-not (Test-Path -LiteralPath $zigRanlibPath)) {
    throw "Missing ranlib wrapper: $zigRanlibPath"
}
if (-not (Test-Path -LiteralPath $zigDlltoolPath)) {
    throw "Missing dlltool wrapper: $zigDlltoolPath"
}

$env:AR = "zig-ar.cmd"
$env:RANLIB = "zig-ranlib.cmd"
$env:DLLTOOL = "zig-dlltool.cmd"
$env:AR_x86_64_pc_windows_gnu = "zig-ar.cmd"
$env:RANLIB_x86_64_pc_windows_gnu = "zig-ranlib.cmd"
$env:DLLTOOL_x86_64_pc_windows_gnu = "zig-dlltool.cmd"
Set-Item -Path "Env:AR_x86_64-pc-windows-gnu" -Value "zig-ar.cmd"
Set-Item -Path "Env:RANLIB_x86_64-pc-windows-gnu" -Value "zig-ranlib.cmd"
Set-Item -Path "Env:DLLTOOL_x86_64-pc-windows-gnu" -Value "zig-dlltool.cmd"

$x64Rustflags = "-C dlltool=zig-dlltool.cmd"
if ([string]::IsNullOrWhiteSpace($env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS)) {
    $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = $x64Rustflags
}
elseif ($env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS -notmatch [regex]::Escape("dlltool=zig-dlltool.cmd")) {
    $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = "$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS $x64Rustflags"
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
