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

        [object]$Content = "ok"
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
        hostToolchain = "1.98.0-x86_64-pc-windows-msvc"
        hostTriple = "x86_64-pc-windows-msvc"
        hostRustComponents = @(
            "cargo-x86_64-pc-windows-msvc",
            "rust-std-x86_64-pc-windows-msvc",
            "rustc-x86_64-pc-windows-msvc"
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
        }
        componentFiles = [ordered]@{
            core = @("tools/cargo-home/bin/cargo.exe")
            armv7 = @("scripts/rust_build_armv7.ps1")
            aarch64 = @("scripts/rust_build_aarch64.ps1")
        }
    }

    $layout | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $tempRoot "install-layout.json") -Encoding ASCII
    New-TestFile -Path (Join-Path $tempRoot "tools\cargo-home\bin\cargo.exe")
    New-TestFile -Path (Join-Path $tempRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\placeholder.txt")
    New-TestFile -Path (Join-Path $tempRoot "scripts\rust_build_armv7.ps1")
    New-TestFile -Path (Join-Path $tempRoot "scripts\rust_build_aarch64.ps1")
    $staleWindowsHostTriple = "x86_64-pc-windows-" + "g" + "nu"
    $staleWindowsHostLinker = "x86_64-" + "w64-" + "min" + "gw32-gcc.cmd"
    $cargoConfigContent = @'
[build]
target = "__STALE_WINDOWS_HOST_TRIPLE__"
jobs = 2

[target.__STALE_WINDOWS_HOST_TRIPLE__]
linker = "__STALE_WINDOWS_HOST_LINKER__"

[target.x86_64-pc-windows-msvc]
linker = "rust-lld"

[target.aarch64-unknown-linux-musl]
linker = "aarch64-linux-musl-gcc.cmd"
'@
    $cargoConfigContent = $cargoConfigContent.
        Replace("__STALE_WINDOWS_HOST_TRIPLE__", $staleWindowsHostTriple).
        Replace("__STALE_WINDOWS_HOST_LINKER__", $staleWindowsHostLinker)
    New-TestFile -Path (Join-Path $tempRoot "config\.cargo\config.toml") -Content $cargoConfigContent

    Invoke-FinalizeOfflineInstall -InstallRoot $tempRoot -SelectedComponents "armv7" -InstallScope "perUser"

    $settingsContent = Get-Content -LiteralPath (Join-Path $tempRoot "tools\rustup-home\settings.toml") -Raw
    Assert-True -Condition ($settingsContent -match 'default_toolchain = "1.98.0-x86_64-pc-windows-msvc"') -Message "finalize should write pinned MSVC rustup settings"

    $components = Get-Content -LiteralPath (Join-Path $tempRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\components")
    Assert-True -Condition ($components -contains "rust-std-armv7-unknown-linux-musleabihf") -Message "selected armv7 target should be added to the components file"
    Assert-True -Condition (-not ($components -contains "rust-std-aarch64-unknown-linux-musl")) -Message "unselected aarch64 target should be absent from the components file"

    $cargoConfigContent = Get-Content -LiteralPath (Join-Path $tempRoot "config\.cargo\config.toml") -Raw
    Assert-True -Condition ($cargoConfigContent -notmatch [regex]::Escape($staleWindowsHostTriple)) -Message "finalize should remove stale non-MSVC Windows host Cargo config"
    Assert-True -Condition ($cargoConfigContent -notmatch [regex]::Escape($staleWindowsHostLinker)) -Message "finalize should remove stale non-MSVC Windows host linker config"
    Assert-True -Condition ($cargoConfigContent -notmatch "x86_64-pc-windows-msvc") -Message "finalize should remove stale Windows MSVC host Cargo config"
    Assert-True -Condition ($cargoConfigContent -match "jobs = 2") -Message "finalize should preserve unrelated build config"
    Assert-True -Condition ($cargoConfigContent -match "aarch64-unknown-linux-musl") -Message "finalize should preserve Linux target Cargo config"

    $manifest = Get-Content -LiteralPath (Join-Path $tempRoot "install-manifest.json") -Raw | ConvertFrom-Json
    Assert-Equal -Actual $manifest.installScope -Expected "perUser" -Message "install scope should be recorded in the install manifest"
    Assert-True -Condition ($manifest.installedComponents -contains "core") -Message "core should always be recorded as installed"
    Assert-True -Condition ($manifest.installedComponents -contains "armv7") -Message "selected armv7 component should be recorded"
    Assert-True -Condition (-not ($manifest.installedComponents -contains "x64_win")) -Message "removed x64_win component should not be recorded"

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
        hostToolchain = "1.98.0-x86_64-pc-windows-msvc"
        hostTriple = "x86_64-pc-windows-msvc"
        hostRustComponents = @(
            "cargo-x86_64-pc-windows-msvc",
            "rust-std-x86_64-pc-windows-msvc",
            "rustc-x86_64-pc-windows-msvc"
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
    New-Item -ItemType Directory -Path (Join-Path $compatRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib") -Force | Out-Null

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

$payloadRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("finalize-payload-tests-" + [guid]::NewGuid().ToString("N"))
try {
    $toolchainRoot = Join-Path $payloadRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc"
    $hostTriple = "x86_64-pc-windows-msvc"
    $hostFiles = @("libstd-test.rlib", "libstd-test.rmeta", "libcore-test.rlib", "liballoc-test.rlib", "libcompiler_builtins-test.rlib")
    $hostLibdir = Join-Path $toolchainRoot "lib\rustlib\$hostTriple\lib"
    foreach ($fileName in $hostFiles) {
        New-TestFile -Path (Join-Path $hostLibdir $fileName)
    }
    New-TestFile -Path (Join-Path $toolchainRoot "lib\rustlib\manifest-rust-std-$hostTriple") -Content @($hostFiles | ForEach-Object { "file:lib/rustlib/$hostTriple/lib/$_" })

    $hostStatus = Get-RustTargetPayloadStatusFromToolchain -ToolchainRoot $toolchainRoot -TargetTriple $hostTriple
    Assert-True -Condition $hostStatus.IsComplete -Message "installed validation should accept a complete hosted payload"

    Remove-Item -LiteralPath (Join-Path $hostLibdir "libstd-test.rlib") -Force
    $metadataOnlyStatus = Get-RustTargetPayloadStatusFromToolchain -ToolchainRoot $toolchainRoot -TargetTriple $hostTriple
    Assert-True -Condition (-not $metadataOnlyStatus.IsComplete) -Message "installed validation should reject a hosted payload without libstd"
    Assert-True -Condition ((Format-RustTargetPayloadFailure -Status $metadataOnlyStatus) -match "x86_64-pc-windows-msvc") -Message "metadata-only diagnostics should name the affected target"

    $thumbTriple = "thumbv7em-none-eabihf"
    $thumbFiles = @("libcore-test.rlib", "liballoc-test.rlib", "libcompiler_builtins-test.rlib")
    $thumbLibdir = Join-Path $toolchainRoot "lib\rustlib\$thumbTriple\lib"
    foreach ($fileName in $thumbFiles) {
        New-TestFile -Path (Join-Path $thumbLibdir $fileName)
    }
    New-TestFile -Path (Join-Path $toolchainRoot "lib\rustlib\manifest-rust-std-$thumbTriple") -Content @($thumbFiles | ForEach-Object { "file:lib/rustlib/$thumbTriple/lib/$_" })
    $thumbStatus = Get-RustTargetPayloadStatusFromToolchain -ToolchainRoot $toolchainRoot -TargetTriple $thumbTriple
    Assert-True -Condition $thumbStatus.IsComplete -Message "installed validation should accept thumb no_std without libstd"
}
finally {
    Remove-Item -LiteralPath $payloadRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$finalizeScriptBody = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\scripts\finalize_offline_install.ps1") -Raw -Encoding UTF8
Assert-True -Condition ($finalizeScriptBody -match "Get-RustTargetPayloadStatus") -Message "finalize validation should run the shared Rust target payload check"

Write-Host "finalize_offline_install tests passed."
