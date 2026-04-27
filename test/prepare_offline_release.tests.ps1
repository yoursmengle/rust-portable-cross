[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$env:RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN = "1"
. "$PSScriptRoot\..\scripts\prepare_offline_release.ps1"

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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("offline-release-tests-" + [guid]::NewGuid().ToString("N"))
$toolkitRoot = Join-Path $tempRoot "toolkit"
$distRoot = Join-Path $tempRoot "dist"

try {
    New-TestFile -Path (Join-Path $toolkitRoot "docs\customer\README-offline.md")
    New-TestFile -Path (Join-Path $toolkitRoot "config\.cargo\config.toml")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_env.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\finalize_offline_install.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_build_armv7.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_build_aarch64.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_build_x64_win.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup\rustup.exe")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\cargo-home\bin\cargo.exe")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\cargo-home\bin\rustc.exe")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\cargo-home\bin\rustup.exe")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\zig\zig.exe")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\arm-linux-musleabihf-gcc.cmd")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\arm-linux-musleabihf-gcc.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\aarch64-linux-musl-gcc.cmd")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\aarch64-linux-musl-gcc.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\x86_64-w64-mingw32-gcc.cmd")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\x86_64-w64-mingw32-gcc.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\update-hashes\stable-x86_64-pc-windows-gnu")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\bin\rustc.exe")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\x86_64-pc-windows-gnu\lib\std.rlib")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\manifest-rust-std-x86_64-pc-windows-gnu")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\components")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\armv7-unknown-linux-musleabihf\lib\std.rlib")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\manifest-rust-std-armv7-unknown-linux-musleabihf")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\aarch64-unknown-linux-musl\lib\std.rlib")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\manifest-rust-std-aarch64-unknown-linux-musl")

    Invoke-PrepareOfflineRelease -ToolkitRoot $toolkitRoot -OutputRoot $distRoot -Version "1.2.3" | Out-Null

    $coreRoot = Join-Path $distRoot "staging\core"
    $targetsRoot = Join-Path $distRoot "staging\targets"

    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "scripts\rust_env.ps1")) -Message "core payload should contain rust_env.ps1"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "scripts\finalize_offline_install.ps1")) -Message "core payload should contain finalize_offline_install.ps1"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "docs\README-offline.md")) -Message "core payload should contain the customer README"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "Activate Rust Portable Cross.ps1")) -Message "core payload should contain the activation entry script"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\x86_64-pc-windows-gnu\lib\std.rlib")) -Message "core payload should contain the host rustlib"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $coreRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\armv7-unknown-linux-musleabihf"))) -Message "core payload should exclude the armv7 rustlib directory"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $coreRoot "tools\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\components"))) -Message "core payload should exclude the generated rustup components file"

    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "armv7\scripts\rust_build_armv7.ps1")) -Message "armv7 payload should contain its build script"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "armv7\tools\wrappers\arm-linux-musleabihf-gcc.cmd")) -Message "armv7 payload should contain its wrapper"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "aarch64\scripts\rust_build_aarch64.ps1")) -Message "aarch64 payload should contain its build script"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "x64_win\scripts\rust_build_x64_win.ps1")) -Message "x64_win payload should contain its build script"

    $layout = Get-Content -LiteralPath (Join-Path $coreRoot "install-layout.json") -Raw | ConvertFrom-Json -Depth 6
    Assert-Equal -Actual $layout.productVersion -Expected "1.2.3" -Message "layout should preserve the requested version"
    Assert-Equal -Actual $layout.hostToolchain -Expected "stable-x86_64-pc-windows-gnu" -Message "layout should record the GNU host toolchain"
    Assert-Equal -Actual $layout.defaultComponents.Count -Expected 1 -Message "layout should keep a single default component"
    Assert-Equal -Actual $layout.defaultComponents[0] -Expected "armv7" -Message "layout should default to armv7"
    Assert-True -Condition ($layout.componentFiles.armv7 -contains "scripts/rust_build_armv7.ps1") -Message "layout should record armv7-owned files"
    Assert-True -Condition ($layout.componentFiles.aarch64 -contains "scripts/rust_build_aarch64.ps1") -Message "layout should record aarch64-owned files"
    Assert-True -Condition ($layout.componentFiles.x64_win -contains "scripts/rust_build_x64_win.ps1") -Message "layout should record x64_win-owned files"
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "prepare_offline_release tests passed."
