[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$env:RUST_PORTABLE_CROSS_SKIP_MAIN = "1"
. "$PSScriptRoot\rust_setup.ps1"

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

$resolvedPaths = Get-RustToolkitPaths
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($resolvedPaths.ScriptPath)) -Message "script path should resolve when the setup script is dot-sourced"
Assert-Equal -Actual $resolvedPaths.ScriptRoot -Expected $PSScriptRoot -Message "script root should point at the scripts directory"
Assert-Equal -Actual $resolvedPaths.ToolkitRoot -Expected (Split-Path -Parent $PSScriptRoot) -Message "toolkit root should be the parent of the scripts directory"

$rustupUris = @(Get-DownloadUriList `
    -PrimaryUri "" `
    -MirrorUris @(
        "https://mirror.sjtu.edu.cn/rust-static/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe",
        "https://rsproxy.cn/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe"
    ) `
    -ProxyPrefix "" `
    -FallbackUri "https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe")

Assert-Equal -Actual $rustupUris.Count -Expected 3 -Message "rustup candidate count should include mirrors plus fallback"
Assert-Equal -Actual $rustupUris[0] -Expected "https://mirror.sjtu.edu.cn/rust-static/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe" -Message "rustup should prefer the first mainland mirror"
Assert-Equal -Actual $rustupUris[1] -Expected "https://rsproxy.cn/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe" -Message "rustup should fall back to the second mainland mirror before official"
Assert-Equal -Actual $rustupUris[2] -Expected "https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe" -Message "rustup should keep the official URL as final fallback"

$zigUris = @(Get-DownloadUriList `
    -PrimaryUri "" `
    -MirrorUris @(
        "https://mirrors.sjtug.sjtu.edu.cn/zig/download/0.13.0/zig-windows-x86_64-0.13.0.zip",
        "https://ziglang.org/download/0.13.0/zig-windows-x86_64-0.13.0.zip"
    ) `
    -ProxyPrefix "" `
    -FallbackUri "https://ziglang.org/download/0.13.0/zig-windows-x86_64-0.13.0.zip")

Assert-Equal -Actual $zigUris.Count -Expected 2 -Message "zig duplicate official URL should be de-duplicated while preserving mirror plus fallback"
Assert-Equal -Actual $zigUris[0] -Expected "https://mirrors.sjtug.sjtu.edu.cn/zig/download/0.13.0/zig-windows-x86_64-0.13.0.zip" -Message "zig should prefer the mainland mirror when available"
Assert-Equal -Actual $zigUris[1] -Expected "https://ziglang.org/download/0.13.0/zig-windows-x86_64-0.13.0.zip" -Message "zig should keep the official URL as final fallback"

$configuredMirrorUris = @(Get-ConfiguredMirrorUris `
    -DefaultMirrorUris @(
        "https://default.example/download/tool.zip"
    ) `
    -MirrorUrls " https://mirror-a.example/download/tool.zip ; https://mirror-b.example/download/tool.zip " `
    -MirrorBase "https://ignored.example" `
    -RelativePath "download/tool.zip")

Assert-Equal -Actual $configuredMirrorUris.Count -Expected 4 -Message "configured mirror list should include explicit URLs, derived base URL, and default mirrors"
Assert-Equal -Actual $configuredMirrorUris[0] -Expected "https://mirror-a.example/download/tool.zip" -Message "explicit mirror URLs should be tried first"
Assert-Equal -Actual $configuredMirrorUris[1] -Expected "https://mirror-b.example/download/tool.zip" -Message "multiple explicit mirror URLs should preserve order"
Assert-Equal -Actual $configuredMirrorUris[2] -Expected "https://ignored.example/download/tool.zip" -Message "mirror base should be appended after explicit URLs"
Assert-Equal -Actual $configuredMirrorUris[3] -Expected "https://default.example/download/tool.zip" -Message "default mirrors should remain as the last mainland choices before the official fallback"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rust-setup-tests-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $validZipPath = Join-Path $tempRoot "valid.zip"
    $validZipSource = Join-Path $tempRoot "valid-src"
    New-Item -ItemType Directory -Path $validZipSource -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $validZipSource "payload.txt") -Value "ok" -Encoding ASCII
    Compress-Archive -LiteralPath (Join-Path $validZipSource "payload.txt") -DestinationPath $validZipPath

    $invalidZipPath = Join-Path $tempRoot "invalid.zip"
    Set-Content -LiteralPath $invalidZipPath -Value "not a zip archive" -Encoding ASCII

    Assert-True -Condition (Test-ZipArchive -Path $validZipPath) -Message "valid zip archives should pass integrity validation"
    Assert-True -Condition (-not (Test-ZipArchive -Path $invalidZipPath)) -Message "corrupt zip archives should fail integrity validation"
    Assert-True -Condition (-not (Test-ZipArchive -Path (Join-Path $tempRoot "missing.zip"))) -Message "missing zip archives should fail integrity validation"
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "rust_setup tests passed."
