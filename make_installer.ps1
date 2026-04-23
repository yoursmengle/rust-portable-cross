[CmdletBinding()]
param(
    [string]$Version = "0.1.0",
    [string]$IsccPath,
    [switch]$SkipStaging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$IssFile = Join-Path $RepoRoot "packaging\inno\rust_portable_cross.iss"
$StagingDir = Join-Path $RepoRoot "dist\staging"
$InstallerDir = Join-Path $RepoRoot "dist\installer"
$PrepareScript = Join-Path $RepoRoot "scripts\prepare_offline_release.ps1"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Resolve-IsccPath {
    param([string]$Override)

    if ($Override) {
        if (-not (Test-Path -LiteralPath $Override -PathType Leaf)) {
            throw "Specified ISCC path does not exist: $Override"
        }
        return (Resolve-Path -LiteralPath $Override).Path
    }

    $cmd = Get-Command -Name "ISCC.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 5\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 5\ISCC.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    throw "ISCC.exe not found. Install Inno Setup (https://jrsoftware.org/isdl.php) or pass -IsccPath."
}

if (-not (Test-Path -LiteralPath $IssFile)) {
    throw "Inno Setup script not found: $IssFile"
}

if (-not $SkipStaging) {
    Write-Step "Preparing offline release staging"
    $global:LASTEXITCODE = 0
    & $PrepareScript -Version $Version
    if ((Test-Path Variable:LASTEXITCODE) -and $LASTEXITCODE -ne 0) {
        throw "prepare_offline_release.ps1 failed with exit code $LASTEXITCODE"
    }
} else {
    Write-Step "Skipping staging refresh (-SkipStaging)"
    if (-not (Test-Path -LiteralPath (Join-Path $StagingDir "core\install-layout.json"))) {
        throw "Staging not found at $StagingDir. Remove -SkipStaging or run prepare_offline_release.ps1 first."
    }
}

$Iscc = Resolve-IsccPath -Override $IsccPath
Write-Step "Using Inno Setup compiler: $Iscc"

if (-not (Test-Path -LiteralPath $InstallerDir)) {
    New-Item -ItemType Directory -Path $InstallerDir -Force | Out-Null
}

Write-Step "Compiling installer from $IssFile"
$global:LASTEXITCODE = 0
& $Iscc "/DMyAppVersion=$Version" $IssFile
if ((Test-Path Variable:LASTEXITCODE) -and $LASTEXITCODE -ne 0) {
    throw "ISCC.exe failed with exit code $LASTEXITCODE"
}

$ExpectedExe = Join-Path $InstallerDir "rust-portable-cross-offline-$Version.exe"
if (Test-Path -LiteralPath $ExpectedExe) {
    Write-Step "Installer built successfully:"
    Write-Host "    $ExpectedExe" -ForegroundColor Green
} else {
    Write-Warning "Installer compilation reported success but expected output not found: $ExpectedExe"
}
