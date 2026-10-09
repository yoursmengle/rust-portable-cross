[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# A host (x86_64-pc-windows-msvc) build that compiles C through cc-rs, run with plain
# cargo from a shell activated by rust_env.ps1 - the way users run it, rather than
# through a rust_build_*.ps1 that clears the environment first. sample's locked
# ring dependency builds a C static library with cc-rs, which archives it with a
# lib.exe-style call (-out:<path> -nologo). A GNU-style AR leaked by activation
# fails that call with "ar: error: unknown option n".
#
# Activation promises no Visual Studio-free host C build (rust_build_x64_win_native.ps1
# does), so this check needs an MSVC C toolchain for cc-rs to discover.

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$rustEnv = Join-Path $repoRoot "scripts\rust_env.ps1"

$provisioningPaths = @(
    "tools\cargo-home\bin\cargo.exe",
    "tools\cargo-home\bin\rustc.exe",
    "tools\cargo-home\bin\rustup.exe",
    "tools\zig\zig.exe"
)
$missing = @($provisioningPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot $_)) })
if ($missing.Count -gt 0) {
    Write-Host "SKIP: toolkit is not provisioned (missing $($missing -join ', '))"
    exit 3
}

function Test-MsvcCToolchain {
    if (Get-Command cl.exe -CommandType Application -ErrorAction SilentlyContinue) { return $true }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return $false }
    $installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($installation | Out-String)))
}

if (-not (Test-MsvcCToolchain)) {
    Write-Host "SKIP: no MSVC C toolchain for cc-rs to discover (activated-shell host C builds use Visual Studio)"
    exit 3
}

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rpc-activated-host-cc-" + [Guid]::NewGuid().ToString("N"))
$projectRoot = Join-Path $workRoot "sample"
New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
try {
    foreach ($item in @("Cargo.toml", "Cargo.lock", "src", ".cargo")) {
        $source = Join-Path $repoRoot "sample\$item"
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $projectRoot -Recurse -Force
        }
    }

    $child = @'
param([string]$RustEnv, [string]$ProjectRoot, [string]$TargetDir)
$ErrorActionPreference = "Stop"
# Only what activation sets may be in play, not whatever this runner inherited.
foreach ($name in @("AR", "RANLIB", "CC", "CARGO_BUILD_TARGET")) {
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
}
. $RustEnv *> $null
$env:CARGO_TARGET_DIR = $TargetDir
Set-Location -LiteralPath $ProjectRoot
& cargo build --offline --locked -p ring 2>&1 | ForEach-Object { "$_" }
exit $LASTEXITCODE
'@
    $childPath = Join-Path $workRoot "activated-build.ps1"
    [System.IO.File]::WriteAllText($childPath, $child, (New-Object System.Text.UTF8Encoding($false)))

    $output = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $childPath `
        -RustEnv $rustEnv -ProjectRoot $projectRoot -TargetDir (Join-Path $workRoot "target") 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($output -match 'unknown option') {
        throw "the activated host build routed cc-rs's archive call to a GNU-style archiver:`n$output"
    }
    if ($exitCode -ne 0) {
        throw "cargo build of ring for the host failed in an activated shell (exit $exitCode):`n$output"
    }
}
finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "activated host cc-rs build passed."
