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
    $legacyImportToolFunctionName = "Ensure-Zig" + "Dll" + "toolWrapper"
    Assert-True `
        -Condition ($beforeCargoBuild -match ([regex]::Escape("`$env:$LinkerEnvName = `"$LinkerValue`""))) `
        -Message "$ScriptPath should set $LinkerEnvName before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match "rust_build_isolation\.ps1") `
        -Message "$ScriptPath should load the target environment isolation helper before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild.IndexOf("Clear-RustBuildEnvironment") -ge 0) `
        -Message "$ScriptPath should clear stale target environment before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild.IndexOf("Clear-RustBuildEnvironment") -lt $beforeCargoBuild.IndexOf("`$env:$LinkerEnvName")) `
        -Message "$ScriptPath should clear stale target environment before setting $LinkerEnvName."
    Assert-True `
        -Condition ($beforeCargoBuild -notmatch ([regex]::Escape($legacyImportToolFunctionName) + '\s+-WrappersRoot')) `
        -Message "$ScriptPath should not ensure a legacy Windows import-library wrapper before cargo build."
    Assert-True `
        -Condition ($body -match 'finally\s*\{\s*Restore-RustBuildEnvironment\s+-Snapshot\s+\$rustBuildEnvironmentSnapshot') `
        -Message "$ScriptPath should restore target environment in a finally block."
    Assert-True `
        -Condition ($beforeCargoBuild -match ([regex]::Escape("`$env:$RustflagsEnvName = `"-C link-self-contained=no`""))) `
        -Message "$ScriptPath should set $RustflagsEnvName before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match 'Repair-CargoHostTargetConfig\s+-ToolkitRoot\s+\$toolkitRoot\s+-ProjectRoot\s+\(Get-Location\)\.Path') `
        -Message "$ScriptPath should sanitize Cargo config files before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match 'Initialize-WindowsHostLinkInputs\s+-ToolkitRoot\s+\$toolkitRoot') `
        -Message "$ScriptPath should initialize bundled Windows host link inputs before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild.IndexOf("Clear-RustBuildEnvironment") -lt $beforeCargoBuild.IndexOf("Initialize-WindowsHostLinkInputs")) `
        -Message "$ScriptPath should clear stale target environment before initializing Windows host link inputs."
}

function Assert-X64WinEnvBeforeCargoBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $body = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
    $cargoBuildIndex = $body.IndexOf("cargo build")

    Assert-True -Condition ($cargoBuildIndex -gt 0) -Message "$ScriptPath should invoke cargo build."

    $beforeCargoBuild = $body.Substring(0, $cargoBuildIndex)
    $projectResolveCall = '$resolvedProjectPath = Resolve-ProjectPath -Path $ProjectPath'
    $projectResolveIndex = $body.IndexOf($projectResolveCall)
    $cargoTomlCheckIndex = $body.IndexOf('Cargo.toml')

    Assert-True `
        -Condition ($body -match 'function Resolve-ProjectPath') `
        -Message "$ScriptPath should define a PowerShell-aware project path resolver."
    Assert-True `
        -Condition ($body -match 'GetUnresolvedProviderPathFromPSPath') `
        -Message "$ScriptPath should resolve relative project paths through the PowerShell session path."
    Assert-True `
        -Condition ($body -notmatch '\[System\.IO\.Path\]::GetFullPath\(\$ProjectPath\)') `
        -Message "$ScriptPath should not resolve ProjectPath through the .NET process current directory."
    Assert-True `
        -Condition ($projectResolveIndex -gt 0) `
        -Message "$ScriptPath should resolve ProjectPath through Resolve-ProjectPath."
    Assert-True `
        -Condition ($projectResolveIndex -lt $cargoTomlCheckIndex) `
        -Message "$ScriptPath should resolve ProjectPath before checking Cargo.toml."
    Assert-True `
        -Condition ($beforeCargoBuild -match 'Repair-CargoHostTargetConfig\s+-ToolkitRoot\s+\$toolkitRoot\s+-ProjectRoot\s+\$resolvedProjectPath') `
        -Message "$ScriptPath should sanitize Cargo config files before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match "rust_build_isolation\.ps1") `
        -Message "$ScriptPath should load the target environment isolation helper before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild.IndexOf("Clear-RustBuildEnvironment") -ge 0) `
        -Message "$ScriptPath should clear stale target environment before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match 'Initialize-WindowsHostLinkInputs\s+-ToolkitRoot\s+\$toolkitRoot') `
        -Message "$ScriptPath should initialize bundled Windows host link inputs before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild.IndexOf("Clear-RustBuildEnvironment") -lt $beforeCargoBuild.IndexOf("Initialize-WindowsHostLinkInputs")) `
        -Message "$ScriptPath should clear stale target environment before initializing Windows host link inputs."
    Assert-True `
        -Condition ($body -match 'finally\s*\{\s*Restore-RustBuildEnvironment\s+-Snapshot\s+\$rustBuildEnvironmentSnapshot') `
        -Message "$ScriptPath should restore target environment in a finally block."
    Assert-True `
        -Condition ($body -match "cargo build --release --target x86_64-pc-windows-msvc") `
        -Message "$ScriptPath should build the approved x86_64-pc-windows-msvc target."
    # The host C wrapper targets windows-gnu when the bundled link inputs are in
    # use: zig cc -target x86_64-windows-msvc needs Microsoft's headers, which the
    # toolkit cannot ship, so a crate with a C build script would fail on a machine
    # without Visual Studio even once the link inputs are present.
    Assert-True `
        -Condition ($body -match [regex]::Escape('$zigCcTarget = "x86_64-windows-gnu"')) `
        -Message "$ScriptPath should target windows-gnu for the host C wrapper."
    Assert-True `
        -Condition ($body -match 'cc -target __ZIG_TARGET__ @filtered') `
        -Message "$ScriptPath should pass the selected Zig target into the host C wrapper."
    $ambiguousWindowsZigTarget = "x86_64-windows"
    Assert-True `
        -Condition ($body -notmatch [regex]::Escape("cc -target $ambiguousWindowsZigTarget @filtered")) `
        -Message "$ScriptPath should not use Zig's ambiguous Windows C target."

    # +crt-static makes rustc emit /defaultlib:libcmt, MSVC's static CRT, which is
    # not redistributable and has no DLL to import from. Host /LIBPATH: and the
    # missing-sysroot throw live in the isolation helper, not this script.
    Assert-True `
        -Condition ($body -notmatch [regex]::Escape('-Flag "-C target-feature=+crt-static"')) `
        -Message "$ScriptPath should not request +crt-static against the bundled link inputs."
    Assert-True `
        -Condition ($body -notmatch [regex]::Escape('$useBundledLinkInputs')) `
        -Message "$ScriptPath should no longer carry the migration fallback for missing link inputs."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$isolationHelper = Join-Path $repoRoot "scripts\rust_build_isolation.ps1"
$isolationHelperBody = Get-Content -LiteralPath $isolationHelper -Raw -Encoding UTF8

Assert-True -Condition (Test-Path -LiteralPath $isolationHelper -PathType Leaf) -Message "Build isolation helper should exist."
Assert-True `
    -Condition ($isolationHelperBody -match 'Remove-Item\s+-LiteralPath\s+"Env:\$name"') `
    -Message "Build isolation helper should remove env vars instead of leaving empty-string values."
Assert-True `
    -Condition ($isolationHelperBody -notmatch [regex]::Escape(("Ensure-Zig" + "Dll" + "toolWrapper"))) `
    -Message "Build isolation helper should not provide a legacy Windows import-library wrapper generator."
Assert-True `
    -Condition ($isolationHelperBody -notmatch [regex]::Escape(('ZigSubcommand "' + "dll" + 'tool"'))) `
    -Message "Build isolation helper should not forward to the legacy Windows import-library tool."
foreach ($envName in @(
    "CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER",
    "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER",
    "CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER",
    "CC_armv7-unknown-linux-musleabihf",
    "CC_aarch64-unknown-linux-musl",
    "CC_x86_64-pc-windows-msvc"
)) {
    Assert-True `
        -Condition ($isolationHelperBody -match [regex]::Escape($envName)) `
        -Message "Build isolation helper should isolate $envName."
}

Assert-True `
    -Condition ($isolationHelperBody -match 'function Initialize-WindowsHostLinkInputs') `
    -Message "Build isolation helper should initialize bundled Windows host link inputs."
Assert-True `
    -Condition ($isolationHelperBody -match [regex]::Escape('-C link-arg=/LIBPATH:$winSysrootLib')) `
    -Message "Build isolation helper should put the bundled Windows link inputs ahead of any host library path."
Assert-True `
    -Condition ($isolationHelperBody -match [regex]::Escape('-C link-arg=rpc_winshim.lib')) `
    -Message "Build isolation helper should link the shim archive that supplies mainCRTStartup and __chkstk."
Assert-True `
    -Condition ($isolationHelperBody -match 'build_win_link_inputs\.ps1') `
    -Message "Build isolation helper should name the regeneration command when the link inputs are missing."
Assert-True `
    -Condition ($isolationHelperBody -notmatch [regex]::Escape('-Flag "-C target-feature=+crt-static"')) `
    -Message "Build isolation helper should not request +crt-static against the bundled link inputs."
Assert-True `
    -Condition ($isolationHelperBody -match 'function Repair-CargoHostTargetConfig') `
    -Message "Build isolation helper should provide Cargo host config repair."
Assert-True `
    -Condition ($isolationHelperBody -notmatch [regex]::Escape(("x86_64-pc-windows-" + "g" + "nu"))) `
    -Message "Cargo host config repair should not keep literal stale Windows non-MSVC host triples."
Assert-True `
    -Condition ($isolationHelperBody -match 'x86_64-pc-windows-msvc') `
    -Message "Cargo host config repair should detect stale Windows MSVC host config."

. $isolationHelper
$repairTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cargo-host-config-repair-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $repairTestRoot -Force | Out-Null
    $repairConfigPath = Join-Path $repairTestRoot "config.toml"
    $staleWindowsHostTriple = "x86_64-pc-windows-" + "g" + "nu"
    $staleWindowsHostLinker = "x86_64-" + "w64-" + "min" + "gw32-gcc.cmd"
    $repairConfigContent = @'
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
    $repairConfigContent = $repairConfigContent.
        Replace("__STALE_WINDOWS_HOST_TRIPLE__", $staleWindowsHostTriple).
        Replace("__STALE_WINDOWS_HOST_LINKER__", $staleWindowsHostLinker)
    Set-Content -LiteralPath $repairConfigPath -Value $repairConfigContent -Encoding ASCII

    Repair-CargoHostTargetConfigFile -ConfigPath $repairConfigPath | Out-Null

    $repairedContent = Get-Content -LiteralPath $repairConfigPath -Raw
    Assert-True -Condition ($repairedContent -notmatch [regex]::Escape($staleWindowsHostTriple)) -Message "Cargo repair should remove stale non-MSVC Windows host config."
    Assert-True -Condition ($repairedContent -notmatch [regex]::Escape($staleWindowsHostLinker)) -Message "Cargo repair should remove stale non-MSVC Windows host linker config."
    Assert-True -Condition ($repairedContent -notmatch "x86_64-pc-windows-msvc") -Message "Cargo repair should remove stale Windows MSVC host config."
    Assert-True -Condition ($repairedContent -match "jobs = 2") -Message "Cargo repair should preserve unrelated build config."
    Assert-True -Condition ($repairedContent -match "aarch64-unknown-linux-musl") -Message "Cargo repair should preserve Linux target config."
}
finally {
    Remove-Item -LiteralPath $repairTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Regression: a pathologically large config (e.g. a corrupt multi-MB global
# CARGO_HOME config) must be skipped, not read line by line, or finalization
# freezes the installer. Also verify the installer can scope repair to the
# toolkit and never touch the ambient CARGO_HOME.
$guardTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cargo-host-config-guard-" + [guid]::NewGuid().ToString("N"))
$savedCargoHome = $env:CARGO_HOME
try {
    New-Item -ItemType Directory -Path $guardTestRoot -Force | Out-Null

    $oversizedConfigPath = Join-Path $guardTestRoot "config.toml"
    $stream = [System.IO.File]::Create($oversizedConfigPath)
    try {
        $stream.SetLength(2MB)
    }
    finally {
        $stream.Dispose()
    }
    $oversizedBefore = (Get-Item -LiteralPath $oversizedConfigPath).Length

    $guardStart = [System.Diagnostics.Stopwatch]::StartNew()
    $oversizedRepaired = Repair-CargoHostTargetConfigFile -ConfigPath $oversizedConfigPath
    $guardStart.Stop()

    Assert-True -Condition ($oversizedRepaired -eq $false) -Message "Cargo repair should skip an oversized config without modifying it."
    Assert-True -Condition ((Get-Item -LiteralPath $oversizedConfigPath).Length -eq $oversizedBefore) -Message "Cargo repair should leave an oversized config untouched."
    Assert-True -Condition ($guardStart.Elapsed.TotalSeconds -lt 5) -Message "Cargo repair should reject an oversized config quickly."

    # Point the ambient CARGO_HOME at an oversized config; -SkipAmbientCargoHome
    # must keep the installer from ever reading it.
    $ambientCargoHome = Join-Path $guardTestRoot "ambient-cargo-home"
    New-Item -ItemType Directory -Path $ambientCargoHome -Force | Out-Null
    $ambientConfigPath = Join-Path $ambientCargoHome "config.toml"
    $ambientStream = [System.IO.File]::Create($ambientConfigPath)
    try {
        $ambientStream.SetLength(2MB)
    }
    finally {
        $ambientStream.Dispose()
    }
    $env:CARGO_HOME = $ambientCargoHome

    $skipStart = [System.Diagnostics.Stopwatch]::StartNew()
    Repair-CargoHostTargetConfig -ToolkitRoot $guardTestRoot -ProjectRoot "" -SkipAmbientCargoHome
    $skipStart.Stop()

    Assert-True -Condition ((Get-Item -LiteralPath $ambientConfigPath).Length -eq 2MB) -Message "Scoped repair should not modify the ambient CARGO_HOME config."
    Assert-True -Condition ($skipStart.Elapsed.TotalSeconds -lt 5) -Message "Scoped repair should not read the ambient CARGO_HOME config."
}
finally {
    if ($null -eq $savedCargoHome) {
        Remove-Item -LiteralPath "Env:CARGO_HOME" -ErrorAction SilentlyContinue
    }
    else {
        $env:CARGO_HOME = $savedCargoHome
    }
    Remove-Item -LiteralPath $guardTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

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

Assert-X64WinEnvBeforeCargoBuild `
    -ScriptPath (Join-Path $repoRoot "scripts\rust_build_x64_win_native.ps1")

function Assert-Thumbv7emEnvBeforeCargoBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $body = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
    $cargoBuildIndex = $body.IndexOf("cargo build")

    Assert-True -Condition ($cargoBuildIndex -gt 0) -Message "$ScriptPath should invoke cargo build."

    $beforeCargoBuild = $body.Substring(0, $cargoBuildIndex)
    Assert-True `
        -Condition ($beforeCargoBuild -match "rust_build_isolation\.ps1") `
        -Message "$ScriptPath should load the target environment isolation helper before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild.IndexOf("Clear-RustBuildEnvironment") -ge 0) `
        -Message "$ScriptPath should clear stale target environment before cargo build."
    Assert-True `
        -Condition ($body -match 'finally\s*\{\s*Restore-RustBuildEnvironment\s+-Snapshot\s+\$rustBuildEnvironmentSnapshot') `
        -Message "$ScriptPath should restore target environment in a finally block."
    Assert-True `
        -Condition ($beforeCargoBuild -match 'Initialize-WindowsHostLinkInputs\s+-ToolkitRoot\s+\$toolkitRoot') `
        -Message "$ScriptPath should initialize bundled Windows host link inputs before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild.IndexOf("Clear-RustBuildEnvironment") -lt $beforeCargoBuild.IndexOf("Initialize-WindowsHostLinkInputs")) `
        -Message "$ScriptPath should clear stale target environment before initializing Windows host link inputs."
    Assert-True `
        -Condition ($body -match "cargo build --release --target thumbv7em-none-eabihf") `
        -Message "$ScriptPath should build the bare-metal thumbv7em-none-eabihf target."
    # The bare-metal target links with rust-lld and must not wire a Zig/C cross
    # toolchain the way the musl targets do.
    Assert-True `
        -Condition ($body -notmatch "zig-ar\.cmd") `
        -Message "$ScriptPath should not wire a Zig archive wrapper for the bare-metal target."
    Assert-True `
        -Condition ($body -notmatch "CARGO_TARGET_THUMBV7EM_NONE_EABIHF_LINKER") `
        -Message "$ScriptPath should leave the thumbv7em linker at its rust-lld default."
}

Assert-Thumbv7emEnvBeforeCargoBuild `
    -ScriptPath (Join-Path $repoRoot "scripts\rust_build_thumbv7em.ps1")

Write-Host "rust_build_env tests passed."
