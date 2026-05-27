[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-EnvBeforeCargoBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$LinkerEnvName,

        [Parameter(Mandatory = $true)]
        [string]$LinkerValue,

        [Parameter(Mandatory = $true)]
        [string]$RustflagsEnvName
    )

    $body = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
    $cargoBuildIndex = $body.IndexOf("cargo build")

    Assert-True -Condition ($cargoBuildIndex -gt 0) -Message "$ScriptPath should invoke cargo build."

    $beforeCargoBuild = $body.Substring(0, $cargoBuildIndex)
    Assert-True `
        -Condition ($beforeCargoBuild -match ([regex]::Escape("`$env:$LinkerEnvName = `"$LinkerValue`""))) `
        -Message "$ScriptPath should set $LinkerEnvName before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match ([regex]::Escape("`$env:$RustflagsEnvName = `"-C link-self-contained=no`""))) `
        -Message "$ScriptPath should set $RustflagsEnvName before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match 'Repair-CargoHostTargetConfig\s+-ToolkitRoot\s+\$toolkitRoot\s+-ProjectRoot\s+\(Get-Location\)\.Path') `
        -Message "$ScriptPath should sanitize Cargo config files before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match "x86_64-pc-windows-gnu") `
        -Message "$ScriptPath should explicitly identify the Windows GNU host target config to remove."
    Assert-True `
        -Condition ($beforeCargoBuild -match "Remove-EnvVarIfPresent\s+-Name\s+`"CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER`"") `
        -Message "$ScriptPath should remove stale Windows GNU host linker env before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match ([regex]::Escape("`$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = `"-C link-self-contained=yes`""))) `
        -Message "$ScriptPath should force Windows GNU host build scripts to use the portable self-contained CRT before cargo build."
}

$repoRoot = Split-Path -Parent $PSScriptRoot

Assert-EnvBeforeCargoBuild `
    -ScriptPath (Join-Path $repoRoot "scripts\rust_build_armv7.ps1") `
    -LinkerEnvName "CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER" `
    -LinkerValue "arm-linux-musleabihf-gcc.cmd" `
    -RustflagsEnvName "CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_RUSTFLAGS"

Assert-EnvBeforeCargoBuild `
    -ScriptPath (Join-Path $repoRoot "scripts\rust_build_aarch64.ps1") `
    -LinkerEnvName "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER" `
    -LinkerValue "aarch64-linux-musl-gcc.cmd" `
    -RustflagsEnvName "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS"

Write-Host "rust_build_env tests passed."
