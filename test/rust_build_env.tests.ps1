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
        -Condition ($beforeCargoBuild -match "rust_build_isolation\.ps1") `
        -Message "$ScriptPath should load the target environment isolation helper before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild.IndexOf("Clear-RustBuildEnvironment") -ge 0) `
        -Message "$ScriptPath should clear stale target environment before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild.IndexOf("Clear-RustBuildEnvironment") -lt $beforeCargoBuild.IndexOf("`$env:$LinkerEnvName")) `
        -Message "$ScriptPath should clear stale target environment before setting $LinkerEnvName."
    Assert-True `
        -Condition ($beforeCargoBuild -match 'Ensure-ZigDlltoolWrapper\s+-WrappersRoot') `
        -Message "$ScriptPath should ensure the Zig dlltool wrapper before cargo build."
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
        -Condition ($beforeCargoBuild -match "x86_64-pc-windows-gnu") `
        -Message "$ScriptPath should explicitly identify the Windows GNU host target."
    Assert-True `
        -Condition ($beforeCargoBuild -match ([regex]::Escape('$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "rust-lld"'))) `
        -Message "$ScriptPath should force Windows GNU host build scripts to use rust-lld before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match "link-self-contained=yes") `
        -Message "$ScriptPath should force Windows GNU host build scripts to use the portable self-contained CRT before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match "dlltool=zig-dlltool\.cmd") `
        -Message "$ScriptPath should keep the zig dlltool rustflag available for Windows GNU host build scripts."
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
        -Condition ($beforeCargoBuild -match ([regex]::Escape('$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "rust-lld"'))) `
        -Message "$ScriptPath should set the x64 Windows GNU linker before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match "rust_build_isolation\.ps1") `
        -Message "$ScriptPath should load the target environment isolation helper before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild.IndexOf("Clear-RustBuildEnvironment") -ge 0) `
        -Message "$ScriptPath should clear stale target environment before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild.IndexOf("Clear-RustBuildEnvironment") -lt $beforeCargoBuild.IndexOf('$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER')) `
        -Message "$ScriptPath should clear stale target environment before setting the x64 Windows GNU linker."
    Assert-True `
        -Condition ($beforeCargoBuild -match 'Ensure-ZigDlltoolWrapper\s+-WrappersRoot') `
        -Message "$ScriptPath should ensure the Zig dlltool wrapper before cargo build."
    Assert-True `
        -Condition ($body -match 'finally\s*\{\s*Restore-RustBuildEnvironment\s+-Snapshot\s+\$rustBuildEnvironmentSnapshot') `
        -Message "$ScriptPath should restore target environment in a finally block."
    Assert-True `
        -Condition ($beforeCargoBuild -match "link-self-contained=yes") `
        -Message "$ScriptPath should force the x64 Windows GNU target to use portable self-contained CRT before cargo build."
    Assert-True `
        -Condition ($beforeCargoBuild -match "dlltool=zig-dlltool\.cmd") `
        -Message "$ScriptPath should keep the zig dlltool rustflag for windows-targets before cargo build."
    Assert-True `
        -Condition ($body -match "cargo build --release --target x86_64-pc-windows-gnu") `
        -Message "$ScriptPath should build the approved x86_64-pc-windows-gnu target."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$isolationHelper = Join-Path $repoRoot "scripts\rust_build_isolation.ps1"
$isolationHelperBody = Get-Content -LiteralPath $isolationHelper -Raw -Encoding UTF8

Assert-True -Condition (Test-Path -LiteralPath $isolationHelper -PathType Leaf) -Message "Build isolation helper should exist."
Assert-True `
    -Condition ($isolationHelperBody -match 'Remove-Item\s+-LiteralPath\s+"Env:\$name"') `
    -Message "Build isolation helper should remove env vars instead of leaving empty-string values."
Assert-True `
    -Condition ($isolationHelperBody -match 'function Ensure-ZigDlltoolWrapper') `
    -Message "Build isolation helper should provide a Zig dlltool wrapper generator."
Assert-True `
    -Condition ($isolationHelperBody -match 'ZigSubcommand "dlltool"') `
    -Message "Build isolation helper should forward zig-dlltool to zig dlltool."
foreach ($envName in @(
    "CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER",
    "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER",
    "CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER",
    "CC_armv7-unknown-linux-musleabihf",
    "CC_aarch64-unknown-linux-musl",
    "CC_x86_64-pc-windows-gnu"
)) {
    Assert-True `
        -Condition ($isolationHelperBody -match [regex]::Escape($envName)) `
        -Message "Build isolation helper should isolate $envName."
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

Write-Host "rust_build_env tests passed."
