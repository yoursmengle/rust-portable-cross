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

Repair-CargoHostTargetConfig -ToolkitRoot $toolkitRoot -ProjectRoot (Get-Location).Path
Remove-EnvVarIfPresent -Name "CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER"
Remove-EnvVarIfPresent -Name "CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS"

$env:CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER = "arm-linux-musleabihf-gcc.cmd"
$env:CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_RUSTFLAGS = "-C link-self-contained=no"
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
