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

        [object]$Content = "ok"
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
    New-TestFile -Path (Join-Path $toolkitRoot "sample\.cargo\config.toml")
    New-TestFile -Path (Join-Path $toolkitRoot "sample\.gitignore") -Content "target/"
    New-TestFile -Path (Join-Path $toolkitRoot "sample\Cargo.lock")
    New-TestFile -Path (Join-Path $toolkitRoot "sample\Cargo.toml")
    New-TestFile -Path (Join-Path $toolkitRoot "sample\src\main.rs")
    New-TestFile -Path (Join-Path $toolkitRoot "sample\target\release\sample.exe") -Content "do not stage"
    New-TestFile -Path (Join-Path $toolkitRoot "sample_embedded\.cargo\config.toml")
    New-TestFile -Path (Join-Path $toolkitRoot "sample_embedded\.gitignore") -Content "target/"
    New-TestFile -Path (Join-Path $toolkitRoot "sample_embedded\Cargo.lock")
    New-TestFile -Path (Join-Path $toolkitRoot "sample_embedded\Cargo.toml")
    New-TestFile -Path (Join-Path $toolkitRoot "sample_embedded\build.rs")
    New-TestFile -Path (Join-Path $toolkitRoot "sample_embedded\link.x")
    New-TestFile -Path (Join-Path $toolkitRoot "sample_embedded\make_image.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "sample_embedded\README.md")
    New-TestFile -Path (Join-Path $toolkitRoot "sample_embedded\src\lib.rs")
    New-TestFile -Path (Join-Path $toolkitRoot "sample_embedded\src\main.rs")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_env.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_target_payload.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_path_boundary.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_payload_integrity.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\dependency-lock.json") -Content (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\dependency-lock.json') -Raw)
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_build_isolation.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\finalize_offline_install.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_build_x64_win_native.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_build_armv7.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_build_aarch64.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\rust_build_thumbv7em.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "check_tool_armv7.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "check_tool_aarch64.ps1")

    # The release pipeline runs these two for real, so the fixture needs scripts
    # that behave rather than placeholder text. The generator stands in for
    # build_win_link_inputs.ps1 by writing the sysroot it would produce.
    New-TestFile -Path (Join-Path $toolkitRoot "scripts\build_win_link_inputs.ps1") -Content @'
[CmdletBinding()]
param([string]$ToolkitRoot, [string]$Arch = "x86_64", [switch]$Force)
$sysroot = Join-Path $ToolkitRoot "tools\sysroot\x86_64-pc-windows-msvc"
$libRoot = Join-Path $sysroot "lib"
New-Item -ItemType Directory -Path $libRoot -Force | Out-Null
$records = @()
foreach ($name in @("kernel32", "ntdll", "userenv", "ws2_32", "dbghelp", "advapi32", "user32", "ole32", "oleaut32", "shell32", "bcrypt", "msvcrt", "rpc_winshim")) {
    $path = Join-Path $libRoot "$name.lib"
    Set-Content -LiteralPath $path -Value "stub-$name" -Encoding ASCII
    $records += [ordered]@{
        file = "tools/sysroot/x86_64-pc-windows-msvc/lib/$name.lib"
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
[ordered]@{ triple = 'x86_64-pc-windows-msvc'; zigVersion = '0.13.0'; files = $records } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $sysroot "PROVENANCE.json") -Encoding UTF8
exit 0
'@

    New-TestFile -Path (Join-Path $toolkitRoot "check_tool_x64_win.ps1") -Content @'
[CmdletBinding()]
param([switch]$SkipNegativeTest)
exit 0
'@

    New-TestFile -Path (Join-Path $toolkitRoot "test\fixtures\win_selfcontained\.gitignore") -Content "target/"
    New-TestFile -Path (Join-Path $toolkitRoot "test\fixtures\win_selfcontained\Cargo.lock")
    New-TestFile -Path (Join-Path $toolkitRoot "test\fixtures\win_selfcontained\Cargo.toml")
    New-TestFile -Path (Join-Path $toolkitRoot "test\fixtures\win_selfcontained\build.rs")
    New-TestFile -Path (Join-Path $toolkitRoot "test\fixtures\win_selfcontained\csrc\probe.c")
    New-TestFile -Path (Join-Path $toolkitRoot "test\fixtures\win_selfcontained\src\main.rs")
    New-TestFile -Path (Join-Path $toolkitRoot "check_tool_thumbv7em.ps1")

    # Development-time gate files: present in the source tree, and expected to stay
    # out of everything a customer receives.
    New-TestFile -Path (Join-Path $toolkitRoot "ci.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot ".githooks\pre-commit")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup\rustup.exe")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\cargo-home\bin\cargo.exe")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\cargo-home\bin\rustc.exe")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\cargo-home\bin\rustup.exe")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\zig\zig.exe")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\arm-linux-musleabihf-gcc.cmd")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\arm-linux-musleabihf-gcc.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\aarch64-linux-musl-gcc.cmd")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\aarch64-linux-musl-gcc.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\zig-ar.cmd")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\zig-ar.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\zig-ranlib.cmd")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\zig-ranlib.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\zig-lib.cmd")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\zig-lib.ps1")
    $legacyImportToolBase = "zig-" + "dll" + "tool"
    $legacyHostWrapperBase = "x86_64-" + "w64-" + "min" + "gw32-gcc"
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\$legacyImportToolBase.cmd")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\$legacyImportToolBase.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\$legacyHostWrapperBase.cmd")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\wrappers\$legacyHostWrapperBase.ps1")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\update-hashes\1.98.0-x86_64-pc-windows-msvc")
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\bin\rustc.exe")
    $hostRustlib = Join-Path $toolkitRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\x86_64-pc-windows-msvc\lib"
    foreach ($fileName in @("libstd-test.rlib", "libstd-test.rmeta", "libcore-test.rlib", "liballoc-test.rlib", "libcompiler_builtins-test.rlib")) {
        New-TestFile -Path (Join-Path $hostRustlib $fileName)
    }
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\manifest-rust-std-x86_64-pc-windows-msvc") -Content @(
        "file:lib/rustlib/x86_64-pc-windows-msvc/lib/libstd-test.rlib",
        "file:lib/rustlib/x86_64-pc-windows-msvc/lib/libstd-test.rmeta",
        "file:lib/rustlib/x86_64-pc-windows-msvc/lib/libcore-test.rlib",
        "file:lib/rustlib/x86_64-pc-windows-msvc/lib/liballoc-test.rlib",
        "file:lib/rustlib/x86_64-pc-windows-msvc/lib/libcompiler_builtins-test.rlib"
    )
    New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\components")
    foreach ($targetFixture in @(
        @{ Triple = "armv7-unknown-linux-musleabihf"; Files = @("libstd-test.rlib", "libstd-test.rmeta", "libcore-test.rlib", "liballoc-test.rlib", "libcompiler_builtins-test.rlib") },
        @{ Triple = "aarch64-unknown-linux-musl"; Files = @("libstd-test.rlib", "libstd-test.rmeta", "libcore-test.rlib", "liballoc-test.rlib", "libcompiler_builtins-test.rlib") },
        @{ Triple = "thumbv7em-none-eabihf"; Files = @("libcore-test.rlib", "liballoc-test.rlib", "libcompiler_builtins-test.rlib") }
    )) {
        $targetRustlib = Join-Path $toolkitRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\$($targetFixture.Triple)\lib"
        foreach ($fileName in $targetFixture.Files) {
            New-TestFile -Path (Join-Path $targetRustlib $fileName)
        }
        $manifestLines = @($targetFixture.Files | ForEach-Object { "file:lib/rustlib/$($targetFixture.Triple)/lib/$_" })
        New-TestFile -Path (Join-Path $toolkitRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\manifest-rust-std-$($targetFixture.Triple)") -Content $manifestLines
    }

    function Get-ManagedRustCommit { param([string]$ToolkitRoot) return '88d9e12ae178fab0fb5cc050a94da85685d449ea' }
    Invoke-PrepareOfflineRelease -ToolkitRoot $toolkitRoot -OutputRoot $distRoot -Version "1.2.3" | Out-Null

    $coreRoot = Join-Path $distRoot "staging\core"
    $targetsRoot = Join-Path $distRoot "staging\targets"

    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "scripts\rust_env.ps1")) -Message "core payload should contain rust_env.ps1"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "scripts\rust_path_boundary.ps1")) -Message "core payload should contain the managed path helper"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "scripts\rust_payload_integrity.ps1")) -Message "core payload should contain the integrity helper"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "payload-integrity.json")) -Message "core payload should contain its integrity index"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "scripts\rust_build_isolation.ps1")) -Message "core payload should contain rust_build_isolation.ps1"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "scripts\build_win_link_inputs.ps1")) -Message "core payload should contain build_win_link_inputs.ps1"
    foreach ($linkInput in @("kernel32.lib", "ntdll.lib", "userenv.lib", "ws2_32.lib", "dbghelp.lib", "msvcrt.lib", "rpc_winshim.lib")) {
        Assert-True `
            -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "tools\sysroot\x86_64-pc-windows-msvc\lib\$linkInput")) `
            -Message "core payload should contain the bundled Windows link input $linkInput"
    }
    Assert-True `
        -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "test\fixtures\win_selfcontained\src\main.rs")) `
        -Message "core payload should contain the self-containment fixture"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "scripts\finalize_offline_install.ps1")) -Message "core payload should contain finalize_offline_install.ps1"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "scripts\rust_build_x64_win_native.ps1")) -Message "core payload should contain the native x64 helper script"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "docs\README-offline.md")) -Message "core payload should contain the customer README"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "sample\Cargo.toml")) -Message "core payload should contain the sample manifest"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "sample\Cargo.lock")) -Message "core payload should contain the sample lockfile"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "sample\.cargo\config.toml")) -Message "core payload should contain the sample cargo config"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "sample\src\main.rs")) -Message "core payload should contain the sample source"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $coreRoot "sample\target"))) -Message "core payload should not contain sample build artifacts"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "sample_embedded\Cargo.toml")) -Message "core payload should contain the embedded sample manifest"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "sample_embedded\src\lib.rs")) -Message "core payload should contain the embedded sample source"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "check_tool_thumbv7em.ps1")) -Message "core payload should contain the thumbv7em check tool"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "Activate Rust Portable Cross.ps1")) -Message "core payload should contain the activation entry script"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "tools\wrappers\zig-ar.cmd")) -Message "core payload should contain zig wrapper cmd scripts"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "tools\wrappers\zig-ranlib.ps1")) -Message "core payload should contain zig wrapper ps1 scripts"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "tools\wrappers\zig-lib.cmd")) -Message "core payload should contain the MSVC-compatible zig-lib wrapper"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $coreRoot "tools\wrappers\$legacyImportToolBase.cmd"))) -Message "core payload should not contain legacy Windows import-library wrappers"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $coreRoot "tools\wrappers\$legacyHostWrapperBase.cmd"))) -Message "core payload should not contain non-MSVC Windows host wrappers"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $coreRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\x86_64-pc-windows-msvc\lib\libstd-test.rlib")) -Message "core payload should contain the host rustlib"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $coreRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\armv7-unknown-linux-musleabihf"))) -Message "core payload should exclude the armv7 rustlib directory"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $coreRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\thumbv7em-none-eabihf"))) -Message "core payload should exclude the thumbv7em rustlib directory"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $coreRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\components"))) -Message "core payload should exclude the generated rustup components file"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $coreRoot "ci.ps1"))) -Message "core payload should not contain the development commit gate"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $coreRoot ".githooks"))) -Message "core payload should not contain the development git hooks"

    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "armv7\scripts\rust_build_armv7.ps1")) -Message "armv7 payload should contain its build script"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "armv7\tools\wrappers\arm-linux-musleabihf-gcc.cmd")) -Message "armv7 payload should contain its wrapper"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "armv7\tools\wrappers\arm-linux-musleabihf-gcc.ps1")) -Message "armv7 payload should contain its PowerShell wrapper"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "aarch64\scripts\rust_build_aarch64.ps1")) -Message "aarch64 payload should contain its build script"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "aarch64\tools\wrappers\aarch64-linux-musl-gcc.cmd")) -Message "aarch64 payload should contain its wrapper"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "aarch64\tools\wrappers\aarch64-linux-musl-gcc.ps1")) -Message "aarch64 payload should contain its PowerShell wrapper"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "thumbv7em\scripts\rust_build_thumbv7em.ps1")) -Message "thumbv7em payload should contain its build script"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "thumbv7em\tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\thumbv7em-none-eabihf\lib\libcore-test.rlib")) -Message "thumbv7em payload should contain its rustlib"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $targetsRoot "thumbv7em\tools\wrappers"))) -Message "thumbv7em payload should not ship a Zig cross-compiler wrapper"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $targetsRoot "x64_win"))) -Message "staging should not create an x64_win payload"

    $layout = Get-Content -LiteralPath (Join-Path $coreRoot "install-layout.json") -Raw | ConvertFrom-Json -Depth 6
    Assert-Equal -Actual $layout.productVersion -Expected "1.2.3" -Message "layout should preserve the requested version"
    Assert-Equal -Actual $layout.hostToolchain -Expected "1.98.0-x86_64-pc-windows-msvc" -Message "layout should record the pinned MSVC host toolchain"
    Assert-Equal -Actual $layout.defaultComponents.Count -Expected 1 -Message "layout should keep a single default component"
    Assert-Equal -Actual $layout.defaultComponents[0] -Expected "armv7" -Message "layout should default to armv7"
    Assert-True -Condition ($layout.componentFiles.core -contains "tools/wrappers/zig-ar.cmd") -Message "layout should record core zig wrapper files"
    Assert-True -Condition ($layout.componentFiles.core -contains "tools/wrappers/zig-lib.cmd") -Message "layout should record core MSVC archive wrapper files"
    Assert-True -Condition (-not ($layout.componentFiles.core -contains "tools/wrappers/$legacyImportToolBase.cmd")) -Message "layout should not record legacy Windows import-library wrapper files"
    Assert-True -Condition (-not ($layout.componentFiles.core -contains "tools/wrappers/$legacyHostWrapperBase.cmd")) -Message "layout should not record non-MSVC Windows host wrapper files"
    Assert-True -Condition ($layout.componentFiles.core -contains "scripts/rust_build_isolation.ps1") -Message "layout should record the build isolation helper"
    Assert-True -Condition ($layout.componentFiles.core -contains "scripts/rust_build_x64_win_native.ps1") -Message "layout should record the native x64 helper script"
    Assert-True -Condition ($layout.componentFiles.core -contains "sample/Cargo.toml") -Message "layout should record sample files"
    Assert-True -Condition (-not ($layout.componentFiles.core -contains "sample/target/release/sample.exe")) -Message "layout should not record sample build artifacts"
    Assert-True -Condition ($layout.componentFiles.armv7 -contains "scripts/rust_build_armv7.ps1") -Message "layout should record armv7-owned files"
    Assert-True -Condition ($layout.componentFiles.armv7 -contains "tools/wrappers/arm-linux-musleabihf-gcc.ps1") -Message "layout should record armv7 PowerShell wrapper"
    Assert-True -Condition ($layout.componentFiles.aarch64 -contains "scripts/rust_build_aarch64.ps1") -Message "layout should record aarch64-owned files"
    Assert-True -Condition ($layout.componentFiles.aarch64 -contains "tools/wrappers/aarch64-linux-musl-gcc.ps1") -Message "layout should record aarch64 PowerShell wrapper"
    Assert-True -Condition ($layout.componentFiles.thumbv7em -contains "scripts/rust_build_thumbv7em.ps1") -Message "layout should record thumbv7em-owned files"
    Assert-Equal -Actual $layout.targets.thumbv7em.triple -Expected "thumbv7em-none-eabihf" -Message "layout should record the thumbv7em triple"
    Assert-Equal -Actual $layout.targets.thumbv7em.rustComponent -Expected "rust-std-thumbv7em-none-eabihf" -Message "layout should record the thumbv7em rust component"
    Assert-True -Condition (-not ($layout.componentFiles.PSObject.Properties.Name -contains "x64_win")) -Message "layout should not record a removed x64_win component"
    Assert-True -Condition ($layout.componentFiles.core -contains "scripts/rust_target_payload.ps1") -Message "layout should record the shared Rust target payload helper"

    Remove-Item -LiteralPath (Join-Path $hostRustlib "libstd-test.rlib") -Force
    $repairOutput = $null
    try {
        Invoke-PrepareOfflineRelease -ToolkitRoot $toolkitRoot -OutputRoot $distRoot -Version "1.2.4" | Out-Null
    }
    catch {
        $repairOutput = $_.Exception.Message
    }
    Assert-True -Condition ($repairOutput -match "x86_64-pc-windows-msvc|rustup component add") -Message "release staging should name an incomplete hosted payload when repair cannot run"
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "prepare_offline_release tests passed."
