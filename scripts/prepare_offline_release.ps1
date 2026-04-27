[CmdletBinding()]
param(
    [string]$ToolkitRoot,
    [string]$OutputRoot,
    [string]$Version = "0.1.0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:OfflineReleaseScriptPath = $PSCommandPath
$script:OfflineReleaseScriptRoot = $PSScriptRoot
$script:OfflineReleaseToolkitRoot = if ($script:OfflineReleaseScriptRoot) { Split-Path -Parent $script:OfflineReleaseScriptRoot } else { $null }
$script:HostToolchain = "stable-x86_64-pc-windows-gnu"
$script:HostTriple = "x86_64-pc-windows-gnu"
$script:ProductName = "Rust Portable Cross"
$script:DefaultComponents = @("armv7")
$script:TargetDefinitions = [ordered]@{
    armv7 = @{
        Triple = "armv7-unknown-linux-musleabihf"
        RustComponent = "rust-std-armv7-unknown-linux-musleabihf"
        BuildScripts = @("scripts/rust_build_armv7.ps1")
        FilePaths = @(
            "tools/wrappers/arm-linux-musleabihf-gcc.cmd",
            "tools/wrappers/arm-linux-musleabihf-gcc.ps1",
            "tools/rustup-home/toolchains/stable-x86_64-pc-windows-gnu/lib/rustlib/armv7-unknown-linux-musleabihf",
            "tools/rustup-home/toolchains/stable-x86_64-pc-windows-gnu/lib/rustlib/manifest-rust-std-armv7-unknown-linux-musleabihf"
        )
    }
    aarch64 = @{
        Triple = "aarch64-unknown-linux-musl"
        RustComponent = "rust-std-aarch64-unknown-linux-musl"
        BuildScripts = @("scripts/rust_build_aarch64.ps1")
        FilePaths = @(
            "tools/wrappers/aarch64-linux-musl-gcc.cmd",
            "tools/wrappers/aarch64-linux-musl-gcc.ps1",
            "tools/rustup-home/toolchains/stable-x86_64-pc-windows-gnu/lib/rustlib/aarch64-unknown-linux-musl",
            "tools/rustup-home/toolchains/stable-x86_64-pc-windows-gnu/lib/rustlib/manifest-rust-std-aarch64-unknown-linux-musl"
        )
    }
    x64_win = @{
        Triple = $script:HostTriple
        RustComponent = $null
        BuildScripts = @("scripts/rust_build_x64_win.ps1")
        FilePaths = @(
            "tools/wrappers/x86_64-w64-mingw32-gcc.cmd",
            "tools/wrappers/x86_64-w64-mingw32-gcc.ps1"
        )
    }
}

function Write-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "==> $Message"
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Remove-ManagedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        $files = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            try {
                [System.IO.File]::SetAttributes($file.FullName, [System.IO.FileAttributes]::Normal)
            }
            catch {
            }
        }

        $files = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
        foreach ($file in $files) {
            $removed = $false
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                try {
                    Remove-Item -LiteralPath $file.FullName -Force
                    $removed = $true
                    break
                }
                catch {
                    if ($attempt -eq 5) {
                        throw
                    }

                    Start-Sleep -Milliseconds 300
                }
            }

            if (-not $removed) {
                throw "Unable to remove file: $($file.FullName)"
            }
        }

        $directories = Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
        foreach ($directory in $directories) {
            if ((Get-ChildItem -LiteralPath $directory.FullName -Force | Measure-Object).Count -eq 0) {
                Remove-Item -LiteralPath $directory.FullName -Force
            }
        }

        Remove-Item -LiteralPath $Path -Force
    }
}

function Get-OfflineReleasePaths {
    param(
        [string]$ToolkitRoot,
        [string]$OutputRoot
    )

    $resolvedToolkitRoot = if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) { $script:OfflineReleaseToolkitRoot } else { $ToolkitRoot }
    if ([string]::IsNullOrWhiteSpace($resolvedToolkitRoot)) {
        throw "Unable to resolve toolkit root."
    }

    $resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        Join-Path $resolvedToolkitRoot "dist"
    }
    else {
        $OutputRoot
    }

    $stagingRoot = Join-Path $resolvedOutputRoot "staging"
    $coreRoot = Join-Path $stagingRoot "core"
    $targetsRoot = Join-Path $stagingRoot "targets"

    return @{
        ToolkitRoot = $resolvedToolkitRoot
        OutputRoot = $resolvedOutputRoot
        StagingRoot = $stagingRoot
        CoreRoot = $coreRoot
        TargetsRoot = $targetsRoot
        LayoutPath = Join-Path $coreRoot "install-layout.json"
        ReadmeSourcePath = Join-Path $resolvedToolkitRoot "docs\customer\README-offline.md"
        FinalizeScriptPath = Join-Path $resolvedToolkitRoot "scripts\finalize_offline_install.ps1"
    }
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$ChildPath
    )

    return [System.IO.Path]::GetRelativePath($BasePath, $ChildPath).Replace("\", "/")
}

function Copy-FileToDestination {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$RecordedFiles,

        [Parameter(Mandatory = $true)]
        [string]$InstallRelativePath
    )

    Ensure-Directory -Path (Split-Path -Parent $DestinationPath)
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    $RecordedFiles.Add($InstallRelativePath.Replace("\", "/"))
}

function Copy-RelativeEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$RecordedFiles
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Required path is missing: $sourcePath"
    }

    $item = Get-Item -LiteralPath $sourcePath
    if ($item.PSIsContainer) {
        $files = Get-ChildItem -LiteralPath $sourcePath -Recurse -File
        foreach ($file in $files) {
            $installRelativePath = Get-RelativePath -BasePath $SourceRoot -ChildPath $file.FullName
            $destinationPath = Join-Path $DestinationRoot $installRelativePath
            Copy-FileToDestination -SourcePath $file.FullName -DestinationPath $destinationPath -RecordedFiles $RecordedFiles -InstallRelativePath $installRelativePath
        }
        return
    }

    $relativeInstallPath = $RelativePath.Replace("\", "/")
    $targetPath = Join-Path $DestinationRoot $RelativePath
    Copy-FileToDestination -SourcePath $sourcePath -DestinationPath $targetPath -RecordedFiles $RecordedFiles -InstallRelativePath $relativeInstallPath
}

function Copy-HostToolchainCore {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Paths,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$RecordedFiles
    )

    $toolchainRoot = Join-Path $Paths.ToolkitRoot "tools\rustup-home\toolchains\$script:HostToolchain"
    if (-not (Test-Path -LiteralPath $toolchainRoot)) {
        throw "Host toolchain is missing: $toolchainRoot"
    }

    $excludedRelativePaths = @(
        "lib/rustlib/components",
        "lib/rustlib/manifest-rust-std-armv7-unknown-linux-musleabihf",
        "lib/rustlib/manifest-rust-std-aarch64-unknown-linux-musl"
    )

    $excludedPrefixes = @(
        "lib/rustlib/armv7-unknown-linux-musleabihf/",
        "lib/rustlib/aarch64-unknown-linux-musl/"
    )

    $files = Get-ChildItem -LiteralPath $toolchainRoot -Recurse -File
    foreach ($file in $files) {
        $toolchainRelativePath = Get-RelativePath -BasePath $toolchainRoot -ChildPath $file.FullName
        $normalizedRelativePath = $toolchainRelativePath.Replace("\", "/")

        if ($excludedRelativePaths -contains $normalizedRelativePath) {
            continue
        }

        $isExcluded = $false
        foreach ($excludedPrefix in $excludedPrefixes) {
            if ($normalizedRelativePath.StartsWith($excludedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isExcluded = $true
                break
            }
        }
        if ($isExcluded) {
            continue
        }

        $installRelativePath = "tools/rustup-home/toolchains/$script:HostToolchain/$normalizedRelativePath"
        $destinationPath = Join-Path $Paths.CoreRoot ($installRelativePath.Replace("/", "\"))
        Copy-FileToDestination -SourcePath $file.FullName -DestinationPath $destinationPath -RecordedFiles $RecordedFiles -InstallRelativePath $installRelativePath
    }
}

function New-ActivationScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $content = @(
        '$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path',
        '. (Join-Path $installRoot "scripts\rust_env.ps1")',
        'Write-Host ""',
        'Write-Host "Rust Portable Cross environment is active."',
        'Write-Host "See docs\README-offline.md for target-specific build steps."'
    ) -join "`r`n"

    Ensure-Directory -Path (Split-Path -Parent $DestinationPath)
    Set-Content -LiteralPath $DestinationPath -Value $content -Encoding ASCII
}

function Get-HostRustComponents {
    return @(
        "rust-mingw-$script:HostTriple",
        "cargo-$script:HostTriple",
        "rust-std-$script:HostTriple",
        "rustc-$script:HostTriple"
    )
}

function New-InstallLayout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [hashtable]$ComponentFiles
    )

    $targetMetadata = [ordered]@{}
    foreach ($targetName in $script:TargetDefinitions.Keys) {
        $targetDefinition = $script:TargetDefinitions[$targetName]
        $targetMetadata[$targetName] = [ordered]@{
            triple = $targetDefinition.Triple
            rustComponent = $targetDefinition.RustComponent
        }
    }

    return [ordered]@{
        productName = $script:ProductName
        productVersion = $Version
        generatedAt = (Get-Date).ToString("o")
        hostToolchain = $script:HostToolchain
        hostTriple = $script:HostTriple
        defaultComponents = $script:DefaultComponents
        hostRustComponents = @(Get-HostRustComponents)
        targets = $targetMetadata
        componentFiles = $ComponentFiles
    }
}

function Invoke-PrepareOfflineRelease {
    param(
        [string]$ToolkitRoot,
        [string]$OutputRoot,
        [string]$Version
    )

    $paths = Get-OfflineReleasePaths -ToolkitRoot $ToolkitRoot -OutputRoot $OutputRoot

    foreach ($requiredPath in @(
        (Join-Path $paths.ToolkitRoot "scripts\rust_env.ps1"),
        (Join-Path $paths.ToolkitRoot "scripts\finalize_offline_install.ps1"),
        (Join-Path $paths.ToolkitRoot "tools\cargo-home\bin\cargo.exe"),
        (Join-Path $paths.ToolkitRoot "tools\cargo-home\bin\rustc.exe"),
        (Join-Path $paths.ToolkitRoot "tools\cargo-home\bin\rustup.exe"),
        (Join-Path $paths.ToolkitRoot "tools\zig\zig.exe"),
        $paths.ReadmeSourcePath
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required offline release input is missing: $requiredPath"
        }
    }

    Write-Step "Refreshing offline release staging under $($paths.StagingRoot)"
    Remove-ManagedPath -Path $paths.StagingRoot
    Ensure-Directory -Path $paths.OutputRoot
    Ensure-Directory -Path $paths.CoreRoot
    Ensure-Directory -Path $paths.TargetsRoot

    $coreFiles = New-Object 'System.Collections.Generic.List[string]'
    $componentFiles = [ordered]@{
        core = $coreFiles
    }

    foreach ($targetName in $script:TargetDefinitions.Keys) {
        $componentRoot = Join-Path $paths.TargetsRoot $targetName
        Ensure-Directory -Path $componentRoot
        $componentFiles[$targetName] = New-Object 'System.Collections.Generic.List[string]'
    }

    Write-Step "Copying shared core files"
    foreach ($relativePath in @(
        "config",
        "scripts/rust_env.ps1",
        "scripts/finalize_offline_install.ps1",
        "tools/rustup",
        "tools/cargo-home/bin",
        "tools/zig",
        "tools/rustup-home/update-hashes/$script:HostToolchain"
    )) {
        Copy-RelativeEntry -SourceRoot $paths.ToolkitRoot -RelativePath $relativePath -DestinationRoot $paths.CoreRoot -RecordedFiles $coreFiles
    }

    Copy-HostToolchainCore -Paths $paths -RecordedFiles $coreFiles

    $readmeTargetPath = Join-Path $paths.CoreRoot "docs\README-offline.md"
    Copy-FileToDestination -SourcePath $paths.ReadmeSourcePath -DestinationPath $readmeTargetPath -RecordedFiles $coreFiles -InstallRelativePath "docs/README-offline.md"

    $activationTargetPath = Join-Path $paths.CoreRoot "Activate Rust Portable Cross.ps1"
    New-ActivationScript -DestinationPath $activationTargetPath
    $coreFiles.Add("Activate Rust Portable Cross.ps1")

    Write-Step "Copying target-specific payloads"
    foreach ($targetName in $script:TargetDefinitions.Keys) {
        $definition = $script:TargetDefinitions[$targetName]
        $recordedFiles = $componentFiles[$targetName]
        $componentRoot = Join-Path $paths.TargetsRoot $targetName

        foreach ($buildScript in $definition.BuildScripts) {
            Copy-RelativeEntry -SourceRoot $paths.ToolkitRoot -RelativePath $buildScript -DestinationRoot $componentRoot -RecordedFiles $recordedFiles
        }

        foreach ($relativePath in $definition.FilePaths) {
            Copy-RelativeEntry -SourceRoot $paths.ToolkitRoot -RelativePath $relativePath -DestinationRoot $componentRoot -RecordedFiles $recordedFiles
        }
    }

    Write-Step "Writing install layout metadata"
    $coreFiles.Add("install-layout.json")
    $layoutComponentFiles = [ordered]@{}
    foreach ($componentName in $componentFiles.Keys) {
        $layoutComponentFiles[$componentName] = @($componentFiles[$componentName] | Sort-Object)
    }

    $layout = New-InstallLayout -Version $Version -ComponentFiles $layoutComponentFiles
    $layout | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $paths.LayoutPath -Encoding ASCII

    Write-Step "Offline release staging complete"
    foreach ($componentName in $layoutComponentFiles.Keys) {
        Write-Host ("  - {0}: {1} files" -f $componentName, $layoutComponentFiles[$componentName].Count)
    }

    return $paths
}

if ($env:RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN -ne "1") {
    Invoke-PrepareOfflineRelease -ToolkitRoot $ToolkitRoot -OutputRoot $OutputRoot -Version $Version | Out-Null
}
