[CmdletBinding()]
param(
    [string]$Version,
    [string]$IsccPath,
    [switch]$SkipStaging,
    # Also install the compiled EXE into a disposable directory and run the offline
    # smoke builds against it. Off by default: it takes longer than the rest of the
    # build put together.
    [switch]$ValidateInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$IssFile = Join-Path $RepoRoot "packaging\inno\rust_portable_cross.iss"
$StagingDir = Join-Path $RepoRoot "dist\staging"
$InstallerDir = Join-Path $RepoRoot "dist\installer"
$PrepareScript = Join-Path $RepoRoot "scripts\prepare_offline_release.ps1"
. (Join-Path $RepoRoot 'scripts\release_publish.ps1')
. (Join-Path $RepoRoot 'scripts\release_validation.ps1')

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Split-FileAndPublish {
    param(
        [string]$InstallerPath,
        [string]$Version,
        [string]$RepoPath
    )

    return Invoke-SplitPublication -InstallerPath $InstallerPath -Version $Version -RepoPath $RepoPath
}

function Get-InstallerExportDirectory {
    param([string]$RepoPath)

    return Join-Path (Split-Path -Parent $RepoPath) "output"
}

function Copy-BuiltInstallerArtifact {
    param(
        [string]$InstallerPath,
        [string]$RepoPath
    )

    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        throw "Installer output not found: $InstallerPath"
    }

    $exportDir = Get-InstallerExportDirectory -RepoPath $RepoPath
    if (-not (Test-Path -LiteralPath $exportDir)) {
        New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
    }

    $destinationPath = Join-Path $exportDir ([IO.Path]::GetFileName($InstallerPath))
    Copy-Item -LiteralPath $InstallerPath -Destination $destinationPath -Force
    return $destinationPath
}

function Assert-InstallerOutput {
    param([string]$InstallerPath)
    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        throw "Installer compilation reported success but expected output not found: $InstallerPath"
    }
    return $InstallerPath
}

function Invoke-StagedBuildValidation {
    param([string]$StagingRoot, [string]$Version)

    # Staging is checked read-only here. Whether the payload installs and builds is
    # proven on the compiled EXE, by Invoke-InstallerBuildValidation, on request.
    Write-Step 'Verifying staged release payload'
    $null = Assert-StagedRelease -StagingRoot $StagingRoot -Version $Version
}

function Invoke-InstallerBuildValidation {
    param([string]$InstallerPath, [string]$Version, [string]$WorkRoot, [string]$InstallParent, [switch]$ValidateInstall)

    if (-not $ValidateInstall) {
        Write-Step 'Not installing or validating the compiled EXE (pass -ValidateInstall to do so)'
        return
    }
    Write-Step 'Installing and verifying the compiled EXE in a disposable location'
    Invoke-DisposableInstallerValidation -InstallerPath $InstallerPath -Version $Version -WorkRoot $WorkRoot -InstallParent $InstallParent
}

function Get-VersionFromGitTag {
    param([string]$RepoPath)

    $git = Get-Command -Name "git" -ErrorAction SilentlyContinue
    if (-not $git) {
        throw "Version was not specified and 'git' is not available on PATH to derive it from the latest tag."
    }

    Push-Location -LiteralPath $RepoPath
    try {
        $tag = & $git.Source describe --tags --abbrev=0 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tag)) {
            $tag = & $git.Source tag --list --sort=-v:refname | Select-Object -First 1
        }
    }
    finally {
        Pop-Location
    }

    if ([string]::IsNullOrWhiteSpace($tag)) {
        throw "No git tag found. Create a tag like 'v1.0.0' or pass -Version explicitly."
    }

    $tag = $tag.Trim()
    $normalized = if ($tag.StartsWith("v") -or $tag.StartsWith("V")) { $tag.Substring(1) } else { $tag }

    if ($normalized -notmatch '^\d+\.\d+\.\d+$') {
        throw "Latest git tag '$tag' is not a valid version (expected 'vX.Y.Z' or 'X.Y.Z'). Pass -Version explicitly to override."
    }

    return $normalized
}

if ($env:RUST_PORTABLE_CROSS_SKIP_BUILD_MAIN -ne '1') {
if ([string]::IsNullOrWhiteSpace($Version)) {
    Write-Step "Resolving version from latest git tag"
    $Version = Get-VersionFromGitTag -RepoPath $RepoRoot
    Write-Host "    Using version $Version" -ForegroundColor Green
}
else {
    $trimmed = $Version.Trim()
    if ($trimmed.StartsWith("v") -or $trimmed.StartsWith("V")) {
        $trimmed = $trimmed.Substring(1)
    }
    if ($trimmed -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid -Version '$Version' (expected 'vX.Y.Z' or 'X.Y.Z')."
    }
    $Version = $trimmed
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

$ValidationRoot = Join-Path $RepoRoot 'dist\release-validation'
# Short on purpose (Inno's MAX_PATH budget) and under dist\, so one antivirus
# exclusion on dist\ covers staging and the disposable install alike.
$ValidationInstallParent = Join-Path $RepoRoot 'dist\v'
Invoke-StagedBuildValidation -StagingRoot $StagingDir -Version $Version

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
$null = Assert-InstallerOutput -InstallerPath $ExpectedExe

Invoke-InstallerBuildValidation -InstallerPath $ExpectedExe -Version $Version -WorkRoot $ValidationRoot -InstallParent $ValidationInstallParent -ValidateInstall:$ValidateInstall

$CopiedExe = Copy-BuiltInstallerArtifact -InstallerPath $ExpectedExe -RepoPath $RepoRoot
Write-Step "Installer built successfully:"
Write-Host "    $ExpectedExe" -ForegroundColor Green
Write-Host "    Copied to $CopiedExe" -ForegroundColor Green

Write-Step "Publishing split parts to web assets directory"
$WebDir = Split-FileAndPublish -InstallerPath $CopiedExe -Version $Version -RepoPath $RepoRoot
Write-Host "    Parts and manifest written to $WebDir" -ForegroundColor Green
}
