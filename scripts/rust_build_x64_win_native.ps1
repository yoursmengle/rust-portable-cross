[CmdletBinding()]
param(
    [string]$ProjectPath = ".",
    [switch]$DebugBuild
)

$env:RUSTUP_DIST_SERVER="https://mirrors.tuna.tsinghua.edu.cn/rustup"
$env:RUSTUP_UPDATE_ROOT="https://mirrors.tuna.tsinghua.edu.cn/rustup/rustup"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-DirectoryIfMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Add-RustFlagIfMissing {
    param(
        [AllowEmptyString()]
        [string]$Existing,

        [Parameter(Mandatory = $true)]
        [string]$Flag
    )

    if ([string]::IsNullOrWhiteSpace($Existing)) {
        return $Flag
    }
    if ($Existing -match [regex]::Escape($Flag)) {
        return $Existing
    }
    return "$Existing $Flag"
}

function Resolve-ProjectPath {
    param(
        [AllowEmptyString()]
        [string]$Path = "."
    )

    $candidate = if ([string]::IsNullOrWhiteSpace($Path)) { "." } else { $Path }

    try {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($candidate)
    }
    catch {
        throw "Unable to resolve project path '$candidate': $($_.Exception.Message)"
    }
}

$toolkitRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $toolkitRoot "tools"
$cargoHome = Join-Path $toolsRoot "cargo-home"
$rustupHome = Join-Path $toolsRoot "rustup-home"
$rustupBinRoot = Join-Path $toolsRoot "rustup"
$zigRoot = Join-Path $toolsRoot "zig"
$wrappersRoot = Join-Path $toolsRoot "wrappers"
$rustMsvcBin = Join-Path $rustupHome "toolchains\stable-x86_64-pc-windows-msvc\lib\rustlib\x86_64-pc-windows-msvc\bin"
$cargoExe = Join-Path $cargoHome "bin\cargo.exe"
$rustcExe = Join-Path $cargoHome "bin\rustc.exe"
$rustupExe = Join-Path $cargoHome "bin\rustup.exe"
$zigExe = Join-Path $zigRoot "zig.exe"
$winSysrootLib = Join-Path $toolsRoot "sysroot\x86_64-pc-windows-msvc\lib"

foreach ($requiredPath in @($cargoExe, $rustcExe, $rustupExe, $zigExe, $rustMsvcBin)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Missing required toolkit path: $requiredPath`nRun .\scripts\rust_setup.ps1 first."
    }
}

# The bundled Windows link inputs. Without these the link falls back to whatever
# Visual Studio happens to be on the machine, which is exactly the host
# dependency this toolkit exists to avoid.
$script:RequiredWinLinkInputs = @(
    "kernel32.lib",
    "ntdll.lib",
    "userenv.lib",
    "ws2_32.lib",
    "dbghelp.lib",
    "msvcrt.lib",
    "rpc_winshim.lib"
)

function Test-WindowsLinkInputs {
    param([Parameter(Mandatory = $true)][string]$LibRoot)

    if (-not (Test-Path -LiteralPath $LibRoot -PathType Container)) {
        return @{ Complete = $false; Missing = @($script:RequiredWinLinkInputs) }
    }

    $missing = @($script:RequiredWinLinkInputs | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $LibRoot $_) -PathType Leaf)
    })

    return @{ Complete = ($missing.Count -eq 0); Missing = $missing }
}

$winLinkInputs = Test-WindowsLinkInputs -LibRoot $winSysrootLib

if (-not $winLinkInputs.Complete) {
    # No fallback to host Visual Studio: silently riding on whatever libraries the
    # machine happens to have is the failure this toolkit exists to prevent, and it
    # would make a developer machine and a bare machine link differently.
    throw @"
The bundled Windows link inputs are missing or incomplete, so this build cannot proceed.

  Expected under: $winSysrootLib
  Missing:        $($winLinkInputs.Missing -join ', ')

Regenerate them with:
  .\scripts\build_win_link_inputs.ps1

This is a missing set of link inputs, not a missing linker: the bundled rust-lld does the
linking and needs no separate installation.
"@
}

$resolvedProjectPath = Resolve-ProjectPath -Path $ProjectPath
if (-not (Test-Path -LiteralPath (Join-Path $resolvedProjectPath "Cargo.toml") -PathType Leaf)) {
    throw "Cargo.toml not found under $resolvedProjectPath"
}

$isolationScript = Join-Path $PSScriptRoot "rust_build_isolation.ps1"
if (-not (Test-Path -LiteralPath $isolationScript -PathType Leaf)) {
    throw "Missing build isolation helper: $isolationScript"
}
. $isolationScript

$rustBuildEnvironmentSnapshot = Save-RustBuildEnvironment
try {
Clear-RustBuildEnvironment

New-DirectoryIfMissing -Path $wrappersRoot

$nativeWrapperRoot = Join-Path ([System.IO.Path]::GetTempPath()) "rust-portable-cross-x64-native-wrapper"
New-DirectoryIfMissing -Path $nativeWrapperRoot

$x64WrapperPs1Path = Join-Path $nativeWrapperRoot "x64-windows-msvc-zig-cc.ps1"
$x64WrapperCmdPath = Join-Path $nativeWrapperRoot "x64-windows-msvc-zig-cc.cmd"
$zigExeEscaped = $zigExe -replace "'", "''"

$x64WrapperPs1BodyTemplate = @'
$filtered = New-Object 'System.Collections.Generic.List[string]'
$skipNext = $false

foreach ($a in $args) {
    if ($skipNext) {
        $skipNext = $false
        continue
    }

    $arg = [string]$a
    $normalizedArg = $arg.Trim('"')

    if ($normalizedArg.StartsWith('--target=')) {
        continue
    }
    if ($normalizedArg -eq '--target' -or $normalizedArg -eq '-target') {
        $skipNext = $true
        continue
    }

    $filtered.Add($arg)
}

& '__ZIG_EXE__' cc -target __ZIG_TARGET__ @filtered
exit $LASTEXITCODE
'@
# `zig cc -target x86_64-windows-msvc` needs MSVC's headers, which we cannot
# ship - so a crate with a C build script would still fail on a bare machine even
# with the link inputs in place. Targeting windows-gnu uses the mingw-w64 headers
# and libc that Zig bundles in full. The objects are C-ABI compatible with the
# MSVC-ABI Rust objects, and both sides resolve the CRT to ucrtbase.dll.
$zigCcTarget = "x86_64-windows-gnu"
$x64WrapperPs1Body = $x64WrapperPs1BodyTemplate.
    Replace('__ZIG_EXE__', $zigExeEscaped).
    Replace('__ZIG_TARGET__', $zigCcTarget)
Set-Content -LiteralPath $x64WrapperPs1Path -Value $x64WrapperPs1Body -Encoding ASCII

$x64WrapperCmdBody = @(
    "@echo off",
    "powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0x64-windows-msvc-zig-cc.ps1`" %*"
) -join "`r`n"
Set-Content -LiteralPath $x64WrapperCmdPath -Value $x64WrapperCmdBody -Encoding ASCII

$zigLocalCache = Join-Path $toolsRoot "zig-local-cache"
$zigGlobalCache = Join-Path $toolsRoot "zig-global-cache"
New-DirectoryIfMissing -Path $zigLocalCache
New-DirectoryIfMissing -Path $zigGlobalCache

$env:RUST_PORTABLE_CROSS_ROOT = $toolkitRoot
$env:CARGO_HOME = $cargoHome
$env:RUSTUP_HOME = $rustupHome
$env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-msvc"
$env:ZIG_LOCAL_CACHE_DIR = $zigLocalCache
$env:ZIG_GLOBAL_CACHE_DIR = $zigGlobalCache
$env:PATH = "$nativeWrapperRoot;$PSScriptRoot;$wrappersRoot;$rustupBinRoot;$cargoHome\bin;$zigRoot;$rustMsvcBin;$env:PATH"

Repair-CargoHostTargetConfig -ToolkitRoot $toolkitRoot -ProjectRoot $resolvedProjectPath
$env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER = "rust-lld"
$env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS = Add-RustFlagIfMissing `
    -Existing $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS `
    -Flag "-C linker-flavor=lld-link"
# Note: +crt-static is deliberately not set. It makes rustc emit /defaultlib:libcmt,
# MSVC's static CRT, which is not redistributable and has no DLL to import from. The
# bundled inputs use the dynamic UCRT instead - ucrtbase.dll is an operating system
# component on Windows 10 and later, so the produced executable still needs nothing
# installed alongside it.

# rustc injects the host Visual Studio / Windows SDK LIB into the linker process from
# its own registry probe and offers no switch to stop it. lld-link searches /LIBPATH:
# before LIB, so naming the bundled sysroot here makes it win on any machine, with or
# without Visual Studio installed.
$env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS = Add-RustFlagIfMissing `
    -Existing $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS `
    -Flag "-C link-arg=/LIBPATH:$winSysrootLib"

# Supplies mainCRTStartup, atexit, _fltused, the TLS directory, __chkstk and the
# type_info vtable - the symbols no Windows DLL exports.
$env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS = Add-RustFlagIfMissing `
    -Existing $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS `
    -Flag "-C link-arg=rpc_winshim.lib"
$env:CC = "x64-windows-msvc-zig-cc.cmd"
$env:HOST_CC = "x64-windows-msvc-zig-cc.cmd"
$env:CC_x86_64_pc_windows_msvc = "x64-windows-msvc-zig-cc.cmd"
Set-Item -Path "Env:CC_x86_64-pc-windows-msvc" -Value "x64-windows-msvc-zig-cc.cmd"

if (Test-Path -LiteralPath (Join-Path $wrappersRoot "zig-lib.cmd")) {
    $env:AR = "zig-lib.cmd"
    $env:AR_x86_64_pc_windows_msvc = "zig-lib.cmd"
    Set-Item -Path "Env:AR_x86_64-pc-windows-msvc" -Value "zig-lib.cmd"
}

if (Test-Path -LiteralPath (Join-Path $wrappersRoot "zig-ranlib.cmd")) {
    $env:RANLIB = "zig-ranlib.cmd"
    $env:RANLIB_x86_64_pc_windows_msvc = "zig-ranlib.cmd"
    Set-Item -Path "Env:RANLIB_x86_64-pc-windows-msvc" -Value "zig-ranlib.cmd"
}

$buildProfile = if ($DebugBuild) { "debug" } else { "release" }

Push-Location $resolvedProjectPath
try {
    if ($DebugBuild) {
        cargo build --target x86_64-pc-windows-msvc
    }
    else {
        cargo build --release --target x86_64-pc-windows-msvc
    }

    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed for x86_64-pc-windows-msvc with exit code $LASTEXITCODE."
    }

    Write-Host "Build output: $(Join-Path (Get-Location) ('target\\x86_64-pc-windows-msvc\\' + $buildProfile))"
}
finally {
    Pop-Location
}
}
finally {
    Restore-RustBuildEnvironment -Snapshot $rustBuildEnvironmentSnapshot
}
