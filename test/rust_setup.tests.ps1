[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$env:RUST_PORTABLE_CROSS_SKIP_MAIN = "1"
. "$PSScriptRoot\..\scripts\rust_setup.ps1"

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
$expectedScriptRoot = Join-Path $PSScriptRoot "..\scripts"
Assert-Equal -Actual $resolvedPaths.ScriptRoot -Expected (Resolve-Path -LiteralPath $expectedScriptRoot).Path -Message "script root should point at the scripts directory"
Assert-Equal -Actual $resolvedPaths.ToolkitRoot -Expected (Split-Path -Parent (Resolve-Path -LiteralPath $expectedScriptRoot).Path) -Message "toolkit root should be the parent of the scripts directory"

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

$payloadTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rust-payload-tests-" + [guid]::NewGuid().ToString("N"))

function New-PayloadTestFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [object]$Content = "payload"
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Set-Content -LiteralPath $Path -Value $Content -Encoding ASCII
}

try {
    $hostTriple = "x86_64-pc-windows-msvc"
    $toolchainRoot = Join-Path $payloadTempRoot "toolchains\1.98.0-x86_64-pc-windows-msvc"
    $hostLibdir = Join-Path $toolchainRoot "lib\rustlib\$hostTriple\lib"
    $hostFiles = @("libstd-test.rlib", "libstd-test.rmeta", "libcore-test.rlib", "liballoc-test.rlib", "libcompiler_builtins-test.rlib")
    foreach ($fileName in $hostFiles) {
        New-PayloadTestFile -Path (Join-Path $hostLibdir $fileName)
    }
    $hostManifest = Join-Path $toolchainRoot "lib\rustlib\manifest-rust-std-$hostTriple"
    New-PayloadTestFile -Path $hostManifest -Content @($hostFiles | ForEach-Object { "file:lib/rustlib/$hostTriple/lib/$_" })

    $complete = Get-RustTargetPayloadStatusFromToolchain -ToolchainRoot $toolchainRoot -TargetTriple $hostTriple
    Assert-True -Condition $complete.IsComplete -Message "a complete hosted fixture payload should pass"

    Remove-Item -LiteralPath (Join-Path $hostLibdir "libstd-test.rlib") -Force
    $missingStd = Get-RustTargetPayloadStatusFromToolchain -ToolchainRoot $toolchainRoot -TargetTriple $hostTriple
    Assert-True -Condition (-not $missingStd.IsComplete) -Message "a hosted payload without libstd should fail"
    Assert-True -Condition (($missingStd.Missing -join "|") -match "libstd-test\.rlib|libstd-\*\.rlib") -Message "missing libstd should be named"
    New-PayloadTestFile -Path (Join-Path $hostLibdir "libstd-test.rlib")

    Remove-Item -LiteralPath (Join-Path $hostLibdir "libcore-test.rlib") -Force
    $missingSupport = Get-RustTargetPayloadStatusFromToolchain -ToolchainRoot $toolchainRoot -TargetTriple $hostTriple
    Assert-True -Condition (-not $missingSupport.IsComplete) -Message "a hosted payload without libcore should fail"
    Assert-True -Condition (($missingSupport.Missing -join "|") -match "libcore-test\.rlib|libcore-\*\.rlib") -Message "missing support library should be named"
    New-PayloadTestFile -Path (Join-Path $hostLibdir "libcore-test.rlib")
    [System.IO.File]::WriteAllText((Join-Path $hostLibdir "libstd-test.rlib"), "")
    $emptyStd = Get-RustTargetPayloadStatusFromToolchain -ToolchainRoot $toolchainRoot -TargetTriple $hostTriple
    Assert-True -Condition (-not $emptyStd.IsComplete) -Message "an empty hosted libstd file should fail"
    Assert-True -Condition (($emptyStd.Empty -join "|") -match "libstd-test\.rlib|libstd-\*\.rlib") -Message "empty libstd should be named"
    New-PayloadTestFile -Path (Join-Path $hostLibdir "libstd-test.rlib")

    $thumbTriple = "thumbv7em-none-eabihf"
    $thumbLibdir = Join-Path $toolchainRoot "lib\rustlib\$thumbTriple\lib"
    $thumbFiles = @("libcore-test.rlib", "liballoc-test.rlib", "libcompiler_builtins-test.rlib")
    foreach ($fileName in $thumbFiles) {
        New-PayloadTestFile -Path (Join-Path $thumbLibdir $fileName)
    }
    $thumbManifest = Join-Path $toolchainRoot "lib\rustlib\manifest-rust-std-$thumbTriple"
    New-PayloadTestFile -Path $thumbManifest -Content @($thumbFiles | ForEach-Object { "file:lib/rustlib/$thumbTriple/lib/$_" })
    $thumbStatus = Get-RustTargetPayloadStatusFromToolchain -ToolchainRoot $toolchainRoot -TargetTriple $thumbTriple
    Assert-True -Condition $thumbStatus.IsComplete -Message "thumb no_std payload should pass without libstd"
}
finally {
    Remove-Item -LiteralPath $payloadTempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$setupScriptBody = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\scripts\rust_setup.ps1") -Raw -Encoding UTF8
Assert-True -Condition ($setupScriptBody -match [regex]::Escape("1.98.0-x86_64-pc-windows-msvc")) -Message "setup should install the pinned Rust 1.98.0 toolchain."
Assert-True -Condition ($setupScriptBody -match 'Expected pinned Rust 1\.98\.0') -Message "setup should reject a managed rustc with the wrong version."
Assert-True -Condition ($setupScriptBody -match '"default"') -Message "setup should persist the pinned toolchain as rustup default."
Assert-True -Condition ($setupScriptBody -match 'Install-PinnedRustToolchain') -Message "setup should retry the pinned toolchain across configured distribution servers."
Assert-True -Condition ($setupScriptBody -match 'zig-lib\.ps1') -Message "setup should generate the MSVC-compatible zig-lib wrapper."
Assert-True -Condition ($setupScriptBody -notmatch [regex]::Escape(("zig-" + "dll" + "tool"))) -Message "setup should not generate the legacy Windows import-library wrapper."
Assert-True -Condition ($setupScriptBody -notmatch [regex]::Escape(("x86_64-" + "w64"))) -Message "setup should not generate non-MSVC Windows host wrappers."

Assert-True -Condition ($setupScriptBody -match [regex]::Escape("'--fix-cortex-a53-'")) -Message "setup should strip the Cortex-A53 erratum linker flag that zig cc rejects."
Assert-True -Condition ($setupScriptBody -match 'Convert-ResponseFile') -Message "setup should filter linker args inside rustc @response files, not just argv."
Assert-True -Condition ($setupScriptBody -match 'New-WrapperCmdBody') -Message "setup should build every .cmd shim from a single definition."
Assert-True -Condition ($setupScriptBody -match [regex]::Escape('for %%I in (pwsh.exe) do set')) -Message "generated .cmd shims should prefer PowerShell 7 when it is available."
Assert-True -Condition ($setupScriptBody -match 'component\s+remove') -Message "setup should remove stale host rust-std metadata before repairing it."
Assert-True -Condition ($setupScriptBody -match 'target\s+remove') -Message "setup should remove stale target metadata before repairing it."

# rustc spills the link command line into an @response file, so a wrapper that only
# filters argv silently does nothing. Exercise the shipped wrapper end to end.
$aarch64Wrapper = Join-Path $PSScriptRoot "..\tools\wrappers\aarch64-linux-musl-gcc.ps1"
$zigExeForWrapper = Join-Path $PSScriptRoot "..\tools\zig\zig.exe"
if ((Test-Path -LiteralPath $aarch64Wrapper -PathType Leaf) -and (Test-Path -LiteralPath $zigExeForWrapper -PathType Leaf)) {
    $wrapperTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rpc-wrapper-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $wrapperTempRoot -Force | Out-Null
    $previousZigLocalCache = $env:ZIG_LOCAL_CACHE_DIR
    $previousZigGlobalCache = $env:ZIG_GLOBAL_CACHE_DIR
    try {
        $env:ZIG_LOCAL_CACHE_DIR = (Resolve-Path (Join-Path $PSScriptRoot "..\tools")).Path + "\zig-local-cache"
        $env:ZIG_GLOBAL_CACHE_DIR = (Resolve-Path (Join-Path $PSScriptRoot "..\tools")).Path + "\zig-global-cache"

        $responsePath = Join-Path $wrapperTempRoot "linker-arguments"
        [System.IO.File]::WriteAllText($responsePath, "-Wl,--fix-cortex-a53-843419`n--version")

        $wrapperOutput = & $aarch64Wrapper "@$responsePath" 2>&1 | Out-String
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "aarch64 wrapper should succeed despite the Cortex-A53 erratum flag.`n$wrapperOutput"
        Assert-True -Condition ($wrapperOutput -notmatch 'unsupported linker arg') -Message "aarch64 wrapper should strip linker args zig cc rejects.`n$wrapperOutput"
        Assert-True -Condition (Test-Path -LiteralPath "$responsePath.zig-cc" -PathType Leaf) -Message "aarch64 wrapper should rewrite the response file it was handed."
        Assert-Equal -Actual ([System.IO.File]::ReadAllText("$responsePath.zig-cc")) -Expected "--version" -Message "rewritten response file should keep every argument zig cc accepts."
    }
    finally {
        $env:ZIG_LOCAL_CACHE_DIR = $previousZigLocalCache
        $env:ZIG_GLOBAL_CACHE_DIR = $previousZigGlobalCache
        Remove-Item -LiteralPath $wrapperTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
else {
    Write-Host "Skipping aarch64 wrapper behaviour test: the toolkit wrapper or zig.exe is not installed."
}

Write-Host "rust_setup tests passed."
