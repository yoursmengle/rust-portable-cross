[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$env:RUST_PORTABLE_CROSS_SKIP_FINALIZE_INSTALL_MAIN = "1"
. "$PSScriptRoot\..\scripts\finalize_offline_install.ps1"

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        $Actual,

        [Parameter(Mandatory = $true)]
        $Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message`nExpected: $Expected`nActual: $Actual"
    }
}

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

function New-TestFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Content = "ok"
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Set-Content -LiteralPath $Path -Value $Content -Encoding ASCII
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("finalize-install-tests-" + [guid]::NewGuid().ToString("N"))

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $layout = [ordered]@{
        productName = "Rust Portable Cross"
        productVersion = "9.9.9"
        hostToolchain = "stable-x86_64-pc-windows-gnu"
        hostTriple = "x86_64-pc-windows-gnu"
        hostRustComponents = @(
            "rust-mingw-x86_64-pc-windows-gnu",
            "cargo-x86_64-pc-windows-gnu",
            "rust-std-x86_64-pc-windows-gnu",
            "rustc-x86_64-pc-windows-gnu"
        )
        targets = [ordered]@{
            armv7 = @{
                triple = "armv7-unknown-linux-musleabihf"
                rustComponent = "rust-std-armv7-unknown-linux-musleabihf"
            }
            aarch64 = @{
                triple = "aarch64-unknown-linux-musl"
                rustComponent = "rust-std-aarch64-unknown-linux-musl"
            }
            x64_win = @{
                triple = "x86_64-pc-windows-gnu"
                rustComponent = $null
            }
        }
        componentFiles = [ordered]@{
            core = @("tools/cargo-home/bin/cargo.exe")
            armv7 = @("scripts/rust_build_armv7.ps1")
            aarch64 = @("scripts/rust_build_aarch64.ps1")
            x64_win = @("scripts/rust_build_x64_win.ps1")
        }
    }

    $layout | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $tempRoot "install-layout.json") -Encoding ASCII
    New-TestFile -Path (Join-Path $tempRoot "tools\cargo-home\bin\cargo.exe")
    New-TestFile -Path (Join-Path $tempRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\placeholder.txt")
    New-TestFile -Path (Join-Path $tempRoot "scripts\rust_build_armv7.ps1")
    New-TestFile -Path (Join-Path $tempRoot "scripts\rust_build_aarch64.ps1")
    New-TestFile -Path (Join-Path $tempRoot "scripts\rust_build_x64_win.ps1")

    Invoke-FinalizeOfflineInstall -InstallRoot $tempRoot -SelectedComponents "armv7,x64_win" -InstallScope "perUser"

    $settingsContent = Get-Content -LiteralPath (Join-Path $tempRoot "tools\rustup-home\settings.toml") -Raw
    Assert-True -Condition ($settingsContent -match 'default_toolchain = "stable-x86_64-pc-windows-gnu"') -Message "finalize should write GNU rustup settings"

    $components = Get-Content -LiteralPath (Join-Path $tempRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\components")
    Assert-True -Condition ($components -contains "rust-std-armv7-unknown-linux-musleabihf") -Message "selected armv7 target should be added to the components file"
    Assert-True -Condition (-not ($components -contains "rust-std-aarch64-unknown-linux-musl")) -Message "unselected aarch64 target should be absent from the components file"

    $manifest = Get-Content -LiteralPath (Join-Path $tempRoot "install-manifest.json") -Raw | ConvertFrom-Json
    Assert-Equal -Actual $manifest.installScope -Expected "perUser" -Message "install scope should be recorded in the install manifest"
    Assert-True -Condition ($manifest.installedComponents -contains "core") -Message "core should always be recorded as installed"
    Assert-True -Condition ($manifest.installedComponents -contains "armv7") -Message "selected armv7 component should be recorded"
    Assert-True -Condition ($manifest.installedComponents -contains "x64_win") -Message "selected x64_win component should be recorded"

    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $tempRoot "scripts\rust_build_aarch64.ps1"))) -Message "finalize should remove files for deselected components"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $tempRoot "scripts\rust_build_armv7.ps1")) -Message "selected component files should remain installed"
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$compatRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("finalize-install-compat-tests-" + [guid]::NewGuid().ToString("N"))

try {
    New-Item -ItemType Directory -Path $compatRoot -Force | Out-Null

    $layout = [ordered]@{
        productName = "Rust Portable Cross"
        productVersion = "9.9.9"
        hostToolchain = "stable-x86_64-pc-windows-gnu"
        hostTriple = "x86_64-pc-windows-gnu"
        hostRustComponents = @(
            "rust-mingw-x86_64-pc-windows-gnu",
            "cargo-x86_64-pc-windows-gnu",
            "rust-std-x86_64-pc-windows-gnu",
            "rustc-x86_64-pc-windows-gnu"
        )
        targets = [ordered]@{
            armv7 = @{
                triple = "armv7-unknown-linux-musleabihf"
                rustComponent = "rust-std-armv7-unknown-linux-musleabihf"
            }
        }
        componentFiles = [ordered]@{
            core = @()
            armv7 = @()
        }
    }

    $layout | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $compatRoot "install-layout.json") -Encoding ASCII
    New-Item -ItemType Directory -Path (Join-Path $compatRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib") -Force | Out-Null

    $powershellExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $compatOutput = & $powershellExe -NoProfile -ExecutionPolicy Bypass -Command "& { Remove-Item Env:RUST_PORTABLE_CROSS_SKIP_FINALIZE_INSTALL_MAIN -ErrorAction SilentlyContinue; & '$PSScriptRoot\..\scripts\finalize_offline_install.ps1' -InstallRoot '$compatRoot' -SelectedComponents 'armv7' -InstallScope 'perUser' }" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Windows PowerShell compatibility finalize run failed.`n$($compatOutput -join [Environment]::NewLine)"
    }

    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $compatRoot "install-manifest.json")) -Message "Windows PowerShell compatibility run should produce an install manifest"
}
finally {
    Remove-Item -LiteralPath $compatRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "finalize_offline_install tests passed."
