[CmdletBinding()]
param(
    [string]$ProjectPath = ".",
    [switch]$DebugBuild
)

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

$toolkitRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $toolkitRoot "tools"
$cargoHome = Join-Path $toolsRoot "cargo-home"
$rustupHome = Join-Path $toolsRoot "rustup-home"
$rustupBinRoot = Join-Path $toolsRoot "rustup"
$zigRoot = Join-Path $toolsRoot "zig"
$wrappersRoot = Join-Path $toolsRoot "wrappers"
$rustSelfContainedBin = Join-Path $rustupHome "toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\x86_64-pc-windows-gnu\bin\self-contained"
$cargoExe = Join-Path $cargoHome "bin\cargo.exe"
$rustcExe = Join-Path $cargoHome "bin\rustc.exe"
$rustupExe = Join-Path $cargoHome "bin\rustup.exe"
$zigExe = Join-Path $zigRoot "zig.exe"

foreach ($requiredPath in @($cargoExe, $rustcExe, $rustupExe, $zigExe, $rustSelfContainedBin)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Missing required toolkit path: $requiredPath`nRun .\scripts\rust_setup.ps1 first."
    }
}

$resolvedProjectPath = [System.IO.Path]::GetFullPath($ProjectPath)
if (-not (Test-Path -LiteralPath (Join-Path $resolvedProjectPath "Cargo.toml") -PathType Leaf)) {
    throw "Cargo.toml not found under $resolvedProjectPath"
}

New-DirectoryIfMissing -Path $wrappersRoot

$nativeWrapperRoot = Join-Path ([System.IO.Path]::GetTempPath()) "rust-portable-cross-x64-native-wrapper"
New-DirectoryIfMissing -Path $nativeWrapperRoot

$x64WrapperPs1Path = Join-Path $nativeWrapperRoot "x64-windows-gnu-zig-cc.ps1"
$x64WrapperCmdPath = Join-Path $nativeWrapperRoot "x64-windows-gnu-zig-cc.cmd"
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

& '__ZIG_EXE__' cc -target x86_64-windows-gnu @filtered
exit $LASTEXITCODE
'@
$x64WrapperPs1Body = $x64WrapperPs1BodyTemplate.Replace('__ZIG_EXE__', $zigExeEscaped)
Set-Content -LiteralPath $x64WrapperPs1Path -Value $x64WrapperPs1Body -Encoding ASCII

$x64WrapperCmdBody = @(
    "@echo off",
    "powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0x64-windows-gnu-zig-cc.ps1`" %*"
) -join "`r`n"
Set-Content -LiteralPath $x64WrapperCmdPath -Value $x64WrapperCmdBody -Encoding ASCII

$zigLocalCache = Join-Path $toolsRoot "zig-local-cache"
$zigGlobalCache = Join-Path $toolsRoot "zig-global-cache"
New-DirectoryIfMissing -Path $zigLocalCache
New-DirectoryIfMissing -Path $zigGlobalCache

$env:RUST_PORTABLE_CROSS_ROOT = $toolkitRoot
$env:CARGO_HOME = $cargoHome
$env:RUSTUP_HOME = $rustupHome
$env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-gnu"
$env:ZIG_LOCAL_CACHE_DIR = $zigLocalCache
$env:ZIG_GLOBAL_CACHE_DIR = $zigGlobalCache
$env:PATH = "$nativeWrapperRoot;$PSScriptRoot;$wrappersRoot;$rustupBinRoot;$cargoHome\bin;$zigRoot;$rustSelfContainedBin;$env:PATH"

$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "rust-lld"
$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = Add-RustFlagIfMissing `
    -Existing $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS `
    -Flag "-C link-self-contained=yes"
$env:CC = "x64-windows-gnu-zig-cc.cmd"
$env:HOST_CC = "x64-windows-gnu-zig-cc.cmd"
$env:CC_x86_64_pc_windows_gnu = "x64-windows-gnu-zig-cc.cmd"
Set-Item -Path "Env:CC_x86_64-pc-windows-gnu" -Value "x64-windows-gnu-zig-cc.cmd"

if (Test-Path -LiteralPath (Join-Path $wrappersRoot "zig-ar.cmd")) {
    $env:AR = "zig-ar.cmd"
    $env:AR_x86_64_pc_windows_gnu = "zig-ar.cmd"
    Set-Item -Path "Env:AR_x86_64-pc-windows-gnu" -Value "zig-ar.cmd"
}

if (Test-Path -LiteralPath (Join-Path $wrappersRoot "zig-ranlib.cmd")) {
    $env:RANLIB = "zig-ranlib.cmd"
    $env:RANLIB_x86_64_pc_windows_gnu = "zig-ranlib.cmd"
    Set-Item -Path "Env:RANLIB_x86_64-pc-windows-gnu" -Value "zig-ranlib.cmd"
}

if (Test-Path -LiteralPath (Join-Path $wrappersRoot "zig-dlltool.cmd")) {
    $env:DLLTOOL = "zig-dlltool.cmd"
    $env:DLLTOOL_x86_64_pc_windows_gnu = "zig-dlltool.cmd"
    Set-Item -Path "Env:DLLTOOL_x86_64-pc-windows-gnu" -Value "zig-dlltool.cmd"

    $dlltoolRustflags = "-C dlltool=zig-dlltool.cmd"
    $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = Add-RustFlagIfMissing `
        -Existing $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS `
        -Flag $dlltoolRustflags
}

$buildProfile = if ($DebugBuild) { "debug" } else { "release" }

Push-Location $resolvedProjectPath
try {
    if ($DebugBuild) {
        cargo build --target x86_64-pc-windows-gnu
    }
    else {
        cargo build --release --target x86_64-pc-windows-gnu
    }

    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed for x86_64-pc-windows-gnu with exit code $LASTEXITCODE."
    }

    Write-Host "Build output: $(Join-Path (Get-Location) ('target\\x86_64-pc-windows-gnu\\' + $buildProfile))"
}
finally {
    Pop-Location
}
