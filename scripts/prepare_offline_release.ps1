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
$script:HostToolchain = "stable-x86_64-pc-windows-msvc"
$script:HostTriple = "x86_64-pc-windows-msvc"
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
            "tools/rustup-home/toolchains/stable-x86_64-pc-windows-msvc/lib/rustlib/armv7-unknown-linux-musleabihf",
            "tools/rustup-home/toolchains/stable-x86_64-pc-windows-msvc/lib/rustlib/manifest-rust-std-armv7-unknown-linux-musleabihf"
        )
    }
    aarch64 = @{
        Triple = "aarch64-unknown-linux-musl"
        RustComponent = "rust-std-aarch64-unknown-linux-musl"
        BuildScripts = @("scripts/rust_build_aarch64.ps1")
        FilePaths = @(
            "tools/wrappers/aarch64-linux-musl-gcc.cmd",
            "tools/wrappers/aarch64-linux-musl-gcc.ps1",
            "tools/rustup-home/toolchains/stable-x86_64-pc-windows-msvc/lib/rustlib/aarch64-unknown-linux-musl",
            "tools/rustup-home/toolchains/stable-x86_64-pc-windows-msvc/lib/rustlib/manifest-rust-std-aarch64-unknown-linux-musl"
        )
    }
    thumbv7em = @{
        Triple = "thumbv7em-none-eabihf"
        RustComponent = "rust-std-thumbv7em-none-eabihf"
        BuildScripts = @("scripts/rust_build_thumbv7em.ps1")
        # Bare-metal target: links with the bundled rust-lld, so it ships no Zig
        # cross-compiler wrapper. Only the precompiled core/alloc rustlib and its
        # manifest are target-specific payloads.
        FilePaths = @(
            "tools/rustup-home/toolchains/stable-x86_64-pc-windows-msvc/lib/rustlib/thumbv7em-none-eabihf",
            "tools/rustup-home/toolchains/stable-x86_64-pc-windows-msvc/lib/rustlib/manifest-rust-std-thumbv7em-none-eabihf"
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

function Copy-RelativeGlobEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$RelativeGlob,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$RecordedFiles
    )

    $normalizedGlob = $RelativeGlob.Replace("/", "\\")
    $globPath = Join-Path $SourceRoot $normalizedGlob
    $matchedFiles = @(Get-ChildItem -Path $globPath -File -ErrorAction SilentlyContinue)

    if ($matchedFiles.Count -eq 0) {
        throw "Required path pattern matched no files: $globPath"
    }

    foreach ($matchedFile in $matchedFiles) {
        $installRelativePath = Get-RelativePath -BasePath $SourceRoot -ChildPath $matchedFile.FullName
        $destinationPath = Join-Path $DestinationRoot ($installRelativePath.Replace("/", "\\"))
        Copy-FileToDestination -SourcePath $matchedFile.FullName -DestinationPath $destinationPath -RecordedFiles $RecordedFiles -InstallRelativePath $installRelativePath
    }
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
        "lib/rustlib/manifest-rust-std-aarch64-unknown-linux-musl",
        "lib/rustlib/manifest-rust-std-thumbv7em-none-eabihf"
    )

    $excludedPrefixes = @(
        "lib/rustlib/armv7-unknown-linux-musleabihf/",
        "lib/rustlib/aarch64-unknown-linux-musl/",
        "lib/rustlib/thumbv7em-none-eabihf/"
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
        "cargo-$script:HostTriple",
        "rust-std-$script:HostTriple",
        "rustc-$script:HostTriple"
    )
}

function Set-ScopedEnvironmentVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [hashtable]$Snapshot
    )

    if (-not $Snapshot.ContainsKey($Name)) {
        if (Test-Path -LiteralPath "Env:$Name") {
            $Snapshot[$Name] = (Get-Item -LiteralPath "Env:$Name").Value
        }
        else {
            $Snapshot[$Name] = $null
        }
    }

    if ($null -eq $Value) {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -LiteralPath "Env:$Name" -Value $Value
    }
}

function Restore-ScopedEnvironmentVariables {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Snapshot
    )

    foreach ($name in $Snapshot.Keys) {
        $previousValue = $Snapshot[$name]
        if ($null -eq $previousValue) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -LiteralPath "Env:$name" -Value $previousValue
        }
    }
}

function Ensure-TargetRustStdPayloads {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Paths
    )

    $toolchainRustlibRoot = Join-Path $Paths.ToolkitRoot "tools\rustup-home\toolchains\$script:HostToolchain\lib\rustlib"
    $missingTriples = New-Object 'System.Collections.Generic.List[string]'

    foreach ($targetName in $script:TargetDefinitions.Keys) {
        $targetTriple = $script:TargetDefinitions[$targetName].Triple
        $tripleRoot = Join-Path $toolchainRustlibRoot $targetTriple
        $manifestPath = Join-Path $toolchainRustlibRoot ("manifest-rust-std-{0}" -f $targetTriple)
        if ((-not (Test-Path -LiteralPath $tripleRoot)) -or (-not (Test-Path -LiteralPath $manifestPath))) {
            $missingTriples.Add($targetTriple)
        }
    }

    if ($missingTriples.Count -eq 0) {
        return
    }

    $rustupCmd = Join-Path $Paths.ToolkitRoot "tools\cargo-home\bin\rustup.exe"
    if (-not (Test-Path -LiteralPath $rustupCmd -PathType Leaf)) {
        throw "Missing rustup executable required for auto-heal: $rustupCmd"
    }

    Write-Step "Missing rust-std payloads detected for $($missingTriples -join ', '); attempting rustup target add"

    $snapshot = @{}
    try {
        Set-ScopedEnvironmentVariable -Name "CARGO_HOME" -Value (Join-Path $Paths.ToolkitRoot "tools\cargo-home") -Snapshot $snapshot
        Set-ScopedEnvironmentVariable -Name "RUSTUP_HOME" -Value (Join-Path $Paths.ToolkitRoot "tools\rustup-home") -Snapshot $snapshot
        Set-ScopedEnvironmentVariable -Name "RUSTUP_TOOLCHAIN" -Value $script:HostToolchain -Snapshot $snapshot

        if ([string]::IsNullOrWhiteSpace($env:RUSTUP_DIST_SERVER)) {
            Set-ScopedEnvironmentVariable -Name "RUSTUP_DIST_SERVER" -Value "https://rsproxy.cn" -Snapshot $snapshot
        }
        if ([string]::IsNullOrWhiteSpace($env:RUSTUP_UPDATE_ROOT)) {
            Set-ScopedEnvironmentVariable -Name "RUSTUP_UPDATE_ROOT" -Value "https://rsproxy.cn/rustup" -Snapshot $snapshot
        }

        & $rustupCmd target add @($missingTriples)
        if ($LASTEXITCODE -ne 0) {
            throw "rustup target add failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Restore-ScopedEnvironmentVariables -Snapshot $snapshot
    }

    foreach ($targetTriple in $missingTriples) {
        $tripleRoot = Join-Path $toolchainRustlibRoot $targetTriple
        $manifestPath = Join-Path $toolchainRustlibRoot ("manifest-rust-std-{0}" -f $targetTriple)
        if ((-not (Test-Path -LiteralPath $tripleRoot)) -or (-not (Test-Path -LiteralPath $manifestPath))) {
            throw "Target payload is still missing after rustup target add: $targetTriple"
        }
    }
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
        (Join-Path $paths.ToolkitRoot "scripts\rust_build_isolation.ps1"),
        (Join-Path $paths.ToolkitRoot "scripts\finalize_offline_install.ps1"),
        (Join-Path $paths.ToolkitRoot "scripts\rust_build_x64_win_native.ps1"),
        (Join-Path $paths.ToolkitRoot "check_tool_armv7.ps1"),
        (Join-Path $paths.ToolkitRoot "check_tool_aarch64.ps1"),
        (Join-Path $paths.ToolkitRoot "check_tool_x64_win.ps1"),
        (Join-Path $paths.ToolkitRoot "check_tool_thumbv7em.ps1"),
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

    Ensure-TargetRustStdPayloads -Paths $paths

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
        "scripts/rust_build_isolation.ps1",
        "scripts/finalize_offline_install.ps1",
        "scripts/rust_build_x64_win_native.ps1",
        "sample/.cargo",
        "sample/.gitignore",
        "sample/Cargo.lock",
        "sample/Cargo.toml",
        "sample/src",
        "sample_embedded/.cargo",
        "sample_embedded/.gitignore",
        "sample_embedded/Cargo.lock",
        "sample_embedded/Cargo.toml",
        "sample_embedded/build.rs",
        "sample_embedded/link.x",
        "sample_embedded/make_image.ps1",
        "sample_embedded/README.md",
        "sample_embedded/src",
        "check_tool_armv7.ps1",
        "check_tool_aarch64.ps1",
        "check_tool_x64_win.ps1",
        "check_tool_thumbv7em.ps1",
        "tools/rustup",
        "tools/cargo-home/bin",
        "tools/zig",
        "tools/rustup-home/update-hashes/$script:HostToolchain"
    )) {
        Copy-RelativeEntry -SourceRoot $paths.ToolkitRoot -RelativePath $relativePath -DestinationRoot $paths.CoreRoot -RecordedFiles $coreFiles
    }

    foreach ($relativePath in @(
        "tools/wrappers/zig-ar.cmd",
        "tools/wrappers/zig-ar.ps1",
        "tools/wrappers/zig-ranlib.cmd",
        "tools/wrappers/zig-ranlib.ps1",
        "tools/wrappers/zig-lib.cmd",
        "tools/wrappers/zig-lib.ps1"
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
