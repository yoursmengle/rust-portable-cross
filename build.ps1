[CmdletBinding()]
param(
    [string]$Version,
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

function Split-FileAndPublish {
    param(
        [string]$InstallerPath,
        [string]$Version,
        [string]$RepoPath
    )

    $chunkSize = 24 * 1024 * 1024  # 24 MB

    $webDownloadDir = Join-Path (Split-Path -Parent $RepoPath) "web_hec_ai_studio\assets\download"
    if (-not (Test-Path -LiteralPath $webDownloadDir)) {
        New-Item -ItemType Directory -Path $webDownloadDir -Force | Out-Null
    }

    $fileName    = [IO.Path]::GetFileName($InstallerPath)
    $originalSize = (Get-Item -LiteralPath $InstallerPath).Length
    $origHash    = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLower()

    $partNames  = [System.Collections.Generic.List[string]]::new()
    $partSizes  = [System.Collections.Generic.List[long]]::new()
    $partHashes = [System.Collections.Generic.List[string]]::new()

    $buffer  = New-Object byte[] $chunkSize
    $partIdx = 1

    $inStream = [System.IO.File]::OpenRead($InstallerPath)
    try {
        while ($true) {
            $bytesRead = $inStream.Read($buffer, 0, $chunkSize)
            if ($bytesRead -eq 0) { break }

            $partName = '{0}.part{1:D3}' -f $fileName, $partIdx
            $partPath = Join-Path $webDownloadDir $partName

            $outStream = [System.IO.File]::Create($partPath)
            try {
                $outStream.Write($buffer, 0, $bytesRead)
            } finally {
                $outStream.Close()
            }

            $partNames.Add($partName)
            $partSizes.Add([long]$bytesRead)
            $partHashes.Add((Get-FileHash -LiteralPath $partPath -Algorithm SHA256).Hash.ToLower())

            $partIdx++
        }
    } finally {
        $inStream.Close()
    }

    $manifest = [ordered]@{
        originalFileName = $fileName
        version          = $Version
        originalSize     = $originalSize
        originalHash     = $origHash
        partCount        = $partNames.Count
        partFileNames    = $partNames.ToArray()
        partFileSizes    = $partSizes.ToArray()
        partFileHashes   = $partHashes.ToArray()
    }

    $jsonPath = Join-Path $webDownloadDir "rust-portable-cross-offline.json"
    $manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    return $webDownloadDir
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
    $CopiedExe = Copy-BuiltInstallerArtifact -InstallerPath $ExpectedExe -RepoPath $RepoRoot
    Write-Step "Installer built successfully:"
    Write-Host "    $ExpectedExe" -ForegroundColor Green
    Write-Host "    Copied to $CopiedExe" -ForegroundColor Green

    Write-Step "Publishing split parts to web assets directory"
    $WebDir = Split-FileAndPublish -InstallerPath $CopiedExe -Version $Version -RepoPath $RepoRoot
    Write-Host "    Parts and manifest written to $WebDir" -ForegroundColor Green
} else {
    Write-Warning "Installer compilation reported success but expected output not found: $ExpectedExe"
}
