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

function Test-CargoHostTargetSectionName {
    param([AllowEmptyString()][string]$SectionName)

    $name = ([string]$SectionName).Trim()
    return ($name -match "^(?i)target\.(['""]?)x86_64-pc-windows-gnu\1$")
}

function Repair-CargoHostTargetConfigFile {
    param([AllowEmptyString()][string]$ConfigPath)

    if ([string]::IsNullOrWhiteSpace($ConfigPath) -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return
    }

    $lines = @(Get-Content -LiteralPath $ConfigPath -Encoding UTF8)
    $kept = New-Object System.Collections.Generic.List[string]
    $insideRemovedSection = $false
    $removed = $false

    foreach ($line in $lines) {
        if ([string]$line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $insideRemovedSection = Test-CargoHostTargetSectionName -SectionName $Matches[1]
            if ($insideRemovedSection) {
                $removed = $true
                continue
            }
        }

        if ($insideRemovedSection) {
            continue
        }

        $kept.Add([string]$line) | Out-Null
    }

    if ($removed) {
        Set-Content -LiteralPath $ConfigPath -Value $kept.ToArray() -Encoding UTF8
        Write-Host "Removed Windows GNU host Cargo target config: $ConfigPath"
    }
}

function Repair-CargoHostTargetConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolkitRoot,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    Repair-CargoHostTargetConfigFile -ConfigPath (Join-Path $ToolkitRoot "config\.cargo\config.toml")

    if (-not [string]::IsNullOrWhiteSpace([string]$env:CARGO_HOME)) {
        Repair-CargoHostTargetConfigFile -ConfigPath (Join-Path ([string]$env:CARGO_HOME) "config.toml")
        Repair-CargoHostTargetConfigFile -ConfigPath (Join-Path ([string]$env:CARGO_HOME) "config")
    }

    $projectCargoDir = Join-Path $ProjectRoot ".cargo"
    Repair-CargoHostTargetConfigFile -ConfigPath (Join-Path $projectCargoDir "config.toml")
    Repair-CargoHostTargetConfigFile -ConfigPath (Join-Path $projectCargoDir "config")
}

function Remove-EnvVarIfPresent {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (Test-Path -LiteralPath "Env:$Name") {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    }
}

$rustBuildEnvironmentSnapshot = Save-RustBuildEnvironment
try {
Clear-RustBuildEnvironment

$wrappersRoot = Join-Path $toolkitRoot "tools\wrappers"
$wrapperPath = Join-Path $wrappersRoot "aarch64-linux-musl-gcc.cmd"
if (-not (Test-Path -LiteralPath $wrapperPath)) {
    throw "AArch64 support is not installed. Missing wrapper: $wrapperPath"
}

$zigArPath = Join-Path $wrappersRoot "zig-ar.cmd"
$zigRanlibPath = Join-Path $wrappersRoot "zig-ranlib.cmd"
if (-not (Test-Path -LiteralPath $zigArPath)) {
    throw "Missing archive wrapper: $zigArPath"
}
if (-not (Test-Path -LiteralPath $zigRanlibPath)) {
    throw "Missing ranlib wrapper: $zigRanlibPath"
}
Ensure-ZigDlltoolWrapper -WrappersRoot $wrappersRoot

Repair-CargoHostTargetConfig -ToolkitRoot $toolkitRoot -ProjectRoot (Get-Location).Path
$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "rust-lld"
$hostRustflags = "-C link-self-contained=yes"
if (Test-Path -LiteralPath (Join-Path $wrappersRoot "zig-dlltool.cmd")) {
    $env:DLLTOOL_x86_64_pc_windows_gnu = "zig-dlltool.cmd"
    Set-Item -Path "Env:DLLTOOL_x86_64-pc-windows-gnu" -Value "zig-dlltool.cmd"
    $hostRustflags = Add-RustBuildFlagIfMissing -Existing $hostRustflags -Flag "-C dlltool=zig-dlltool.cmd"
}
$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = $hostRustflags

$env:CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER = "aarch64-linux-musl-gcc.cmd"
$env:CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS = "-C link-self-contained=no"
$env:CC_aarch64_unknown_linux_musl = "aarch64-linux-musl-gcc.cmd"
$env:AR_aarch64_unknown_linux_musl = "zig-ar.cmd"
$env:RANLIB_aarch64_unknown_linux_musl = "zig-ranlib.cmd"
Set-Item -Path "Env:CC_aarch64-unknown-linux-musl" -Value "aarch64-linux-musl-gcc.cmd"
Set-Item -Path "Env:AR_aarch64-unknown-linux-musl" -Value "zig-ar.cmd"
Set-Item -Path "Env:RANLIB_aarch64-unknown-linux-musl" -Value "zig-ranlib.cmd"

Sync-CargoConfig -Source $configSource -Destination $configTarget

cargo build --release --target aarch64-unknown-linux-musl
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed for aarch64-unknown-linux-musl with exit code $LASTEXITCODE."
}

Write-Host "Build output: $(Join-Path (Get-Location) 'target\aarch64-unknown-linux-musl\release')"
}
finally {
    Restore-RustBuildEnvironment -Snapshot $rustBuildEnvironmentSnapshot
}
