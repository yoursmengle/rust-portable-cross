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
$script:RustTargetPayloadScriptPath = Join-Path $script:OfflineReleaseScriptRoot "rust_target_payload.ps1"
if (-not (Test-Path -LiteralPath $script:RustTargetPayloadScriptPath -PathType Leaf)) {
    throw "Missing Rust target payload helper: $script:RustTargetPayloadScriptPath"
}
. $script:RustTargetPayloadScriptPath
. (Join-Path $script:OfflineReleaseScriptRoot 'rust_payload_integrity.ps1')
. (Join-Path $script:OfflineReleaseScriptRoot 'rust_transaction.ps1')
$script:HostToolchain = "1.98.0-x86_64-pc-windows-msvc"
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
            "tools/rustup-home/toolchains/1.98.0-x86_64-pc-windows-msvc/lib/rustlib/armv7-unknown-linux-musleabihf",
            "tools/rustup-home/toolchains/1.98.0-x86_64-pc-windows-msvc/lib/rustlib/manifest-rust-std-armv7-unknown-linux-musleabihf"
        )
    }
    aarch64 = @{
        Triple = "aarch64-unknown-linux-musl"
        RustComponent = "rust-std-aarch64-unknown-linux-musl"
        BuildScripts = @("scripts/rust_build_aarch64.ps1")
        FilePaths = @(
            "tools/wrappers/aarch64-linux-musl-gcc.cmd",
            "tools/wrappers/aarch64-linux-musl-gcc.ps1",
            "tools/rustup-home/toolchains/1.98.0-x86_64-pc-windows-msvc/lib/rustlib/aarch64-unknown-linux-musl",
            "tools/rustup-home/toolchains/1.98.0-x86_64-pc-windows-msvc/lib/rustlib/manifest-rust-std-aarch64-unknown-linux-musl"
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
            "tools/rustup-home/toolchains/1.98.0-x86_64-pc-windows-msvc/lib/rustlib/thumbv7em-none-eabihf",
            "tools/rustup-home/toolchains/1.98.0-x86_64-pc-windows-msvc/lib/rustlib/manifest-rust-std-thumbv7em-none-eabihf"
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
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ManagedRoot
    )

    if (-not (Test-ManagedPathInsideRoot -Root $ManagedRoot -Path $Path) -or
        [string]::Equals([System.IO.Path]::GetFullPath($ManagedRoot).TrimEnd('\', '/'), [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a path outside the managed output root: $Path"
    }
    $relative = Get-RelativePath -BasePath $ManagedRoot -ChildPath $Path
    $null = Resolve-ManagedRelativePath -Root $ManagedRoot -RelativePath $relative
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
    $resolvedToolkitRoot = Assert-ManagedRootIsOrdinary -Path $resolvedToolkitRoot

    $resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        Join-Path $resolvedToolkitRoot "dist"
    }
    else {
        $OutputRoot
    }

    $resolvedOutputRoot = Assert-ManagedRootIsOrdinary -Path $resolvedOutputRoot
    if (Test-ManagedPathInsideRoot -Root $resolvedOutputRoot -Path $resolvedToolkitRoot) {
        throw "OutputRoot cannot be the toolkit root or its ancestor: $resolvedOutputRoot"
    }
    $stagingRoot = Resolve-ManagedRelativePath -Root $resolvedOutputRoot -RelativePath 'staging'
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

    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    $childFull = [System.IO.Path]::GetFullPath($ChildPath)
    $baseRoot = [System.IO.Path]::GetPathRoot($baseFull)
    $childRoot = [System.IO.Path]::GetPathRoot($childFull)
    if (-not [string]::Equals($baseRoot, $childRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $childFull.Replace('\', '/')
    }

    $separators = [char[]]@('\', '/')
    $baseTail = $baseFull.Substring($baseRoot.Length).Trim($separators)
    $childTail = $childFull.Substring($childRoot.Length).Trim($separators)
    $baseParts = if ($baseTail) { @($baseTail.Split($separators, [System.StringSplitOptions]::RemoveEmptyEntries)) } else { @() }
    $childParts = if ($childTail) { @($childTail.Split($separators, [System.StringSplitOptions]::RemoveEmptyEntries)) } else { @() }

    $sharedCount = 0
    while ($sharedCount -lt $baseParts.Count -and
        $sharedCount -lt $childParts.Count -and
        [string]::Equals($baseParts[$sharedCount], $childParts[$sharedCount], [System.StringComparison]::OrdinalIgnoreCase)) {
        $sharedCount++
    }

    $relativeParts = New-Object 'System.Collections.Generic.List[string]'
    for ($i = $sharedCount; $i -lt $baseParts.Count; $i++) { $relativeParts.Add('..') }
    for ($i = $sharedCount; $i -lt $childParts.Count; $i++) { $relativeParts.Add($childParts[$i]) }
    if ($relativeParts.Count -eq 0) { return '.' }
    return [string]::Join('/', $relativeParts.ToArray())
}

function Copy-FileToDestination {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$RecordedFiles,

        [Parameter(Mandatory = $true)]
        [string]$InstallRelativePath
    )

    $sourceRelative = Get-RelativePath -BasePath $SourceRoot -ChildPath $SourcePath
    $destinationRelative = Get-RelativePath -BasePath $DestinationRoot -ChildPath $DestinationPath
    $null = Resolve-ManagedRelativePath -Root $SourceRoot -RelativePath $sourceRelative -AllowInternalFileLink
    $null = Resolve-ManagedRelativePath -Root $DestinationRoot -RelativePath $destinationRelative
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

    $sourcePath = Resolve-ManagedRelativePath -Root $SourceRoot -RelativePath $RelativePath -AllowInternalFileLink
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Required path is missing: $sourcePath"
    }

    $item = Get-Item -LiteralPath $sourcePath
    if ($item.PSIsContainer) {
        $files = Get-ChildItem -LiteralPath $sourcePath -Recurse -File
        foreach ($file in $files) {
            $installRelativePath = Get-RelativePath -BasePath $SourceRoot -ChildPath $file.FullName
            $destinationPath = Join-Path $DestinationRoot $installRelativePath
            Copy-FileToDestination -SourcePath $file.FullName -DestinationPath $destinationPath -SourceRoot $SourceRoot -DestinationRoot $DestinationRoot -RecordedFiles $RecordedFiles -InstallRelativePath $installRelativePath
        }
        return
    }

    $relativeInstallPath = $RelativePath.Replace("\", "/")
    $targetPath = Join-Path $DestinationRoot $RelativePath
    Copy-FileToDestination -SourcePath $sourcePath -DestinationPath $targetPath -SourceRoot $SourceRoot -DestinationRoot $DestinationRoot -RecordedFiles $RecordedFiles -InstallRelativePath $relativeInstallPath
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
        Copy-FileToDestination -SourcePath $matchedFile.FullName -DestinationPath $destinationPath -SourceRoot $SourceRoot -DestinationRoot $DestinationRoot -RecordedFiles $RecordedFiles -InstallRelativePath $installRelativePath
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
        Copy-FileToDestination -SourcePath $file.FullName -DestinationPath $destinationPath -SourceRoot $Paths.ToolkitRoot -DestinationRoot $Paths.CoreRoot -RecordedFiles $RecordedFiles -InstallRelativePath $installRelativePath
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

    $toolsRoot = Join-Path $Paths.ToolkitRoot 'tools'
    $activeHome = Join-Path $toolsRoot 'rustup-home'
    Restore-PreviousManagedDirectory -ManagedRoot $toolsRoot -ActivePath $activeHome
    $toolchainRoot = Join-Path $activeHome "toolchains\$script:HostToolchain"
    $rustupCmd = Join-Path $Paths.ToolkitRoot "tools\cargo-home\bin\rustup.exe"
    if (-not (Test-Path -LiteralPath $toolchainRoot -PathType Container)) {
        throw "Managed toolchain is missing for target payload validation: $toolchainRoot"
    }

    $incomplete = New-Object 'System.Collections.Generic.List[object]'
    foreach ($payloadDefinition in (Get-RustTargetPayloadDefinitions).Values) {
        $payloadStatus = Get-RustTargetPayloadStatusFromToolchain -ToolchainRoot $toolchainRoot -TargetTriple $payloadDefinition.Triple
        if (-not $payloadStatus.IsComplete) {
            $incomplete.Add($payloadStatus)
        }
    }

    if ($incomplete.Count -eq 0) {
        return
    }

    if (-not (Test-Path -LiteralPath $rustupCmd -PathType Leaf)) {
        throw "Missing rustup executable required for auto-heal: $rustupCmd"
    }

    $missingTriples = @(
        $incomplete |
            Where-Object { $_.TargetTriple -ne $script:HostTriple } |
            ForEach-Object { $_.TargetTriple }
    )
    $hostIncomplete = @($incomplete | Where-Object { $_.TargetTriple -eq $script:HostTriple }).Count -gt 0
    Write-Step "Incomplete Rust target payloads detected for $(($incomplete | ForEach-Object { $_.TargetTriple }) -join ', '); attempting managed repair"

    foreach ($stale in @(Get-ChildItem -LiteralPath $toolsRoot -Directory -Filter 'rustup-home.next.*' -ErrorAction SilentlyContinue)) {
        Remove-TransactionDirectory -ManagedRoot $toolsRoot -Path $stale.FullName
    }
    $candidateHome = Join-Path $toolsRoot ('rustup-home.next.' + [guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $activeHome -Destination $candidateHome -Recurse -Force
    $candidateToolchainRoot = Join-Path $candidateHome "toolchains\$script:HostToolchain"
    $snapshot = @{}
    try {
        Set-ScopedEnvironmentVariable -Name "CARGO_HOME" -Value (Join-Path $Paths.ToolkitRoot "tools\cargo-home") -Snapshot $snapshot
        Set-ScopedEnvironmentVariable -Name "RUSTUP_HOME" -Value $candidateHome -Snapshot $snapshot
        Set-ScopedEnvironmentVariable -Name "RUSTUP_TOOLCHAIN" -Value $script:HostToolchain -Snapshot $snapshot

        if ([string]::IsNullOrWhiteSpace($env:RUSTUP_DIST_SERVER)) {
            Set-ScopedEnvironmentVariable -Name "RUSTUP_DIST_SERVER" -Value "https://rsproxy.cn" -Snapshot $snapshot
        }
        if ([string]::IsNullOrWhiteSpace($env:RUSTUP_UPDATE_ROOT)) {
            Set-ScopedEnvironmentVariable -Name "RUSTUP_UPDATE_ROOT" -Value "https://rsproxy.cn/rustup" -Snapshot $snapshot
        }

        if ($hostIncomplete) {
            # Remove first so a stale rustup record cannot short-circuit the repair.
            try {
                $global:LASTEXITCODE = 0
                & $rustupCmd component remove --toolchain $script:HostToolchain "rust-std-$script:HostTriple" 2>&1 | Out-Host
            }
            catch {
                Write-Verbose "Unable to remove stale rust-std metadata before repair: $($_.Exception.Message)"
            }
            try {
                & $rustupCmd component add --toolchain $script:HostToolchain "rust-std-$script:HostTriple"
            }
            catch {
                throw "rustup component add failed for ${script:HostTriple}: $($_.Exception.Message)"
            }
            if ($LASTEXITCODE -ne 0) {
                throw "rustup component add failed for $script:HostTriple with exit code $LASTEXITCODE"
            }
        }
        if ($missingTriples.Count -gt 0) {
            # Remove first so stale target records cannot short-circuit the repair.
            try {
                $global:LASTEXITCODE = 0
                & $rustupCmd target remove --toolchain $script:HostToolchain @($missingTriples) 2>&1 | Out-Host
            }
            catch {
                Write-Verbose "Unable to remove stale target metadata before repair: $($_.Exception.Message)"
            }
            try {
                & $rustupCmd target add --toolchain $script:HostToolchain @($missingTriples)
            }
            catch {
                throw "rustup target add failed for $($missingTriples -join ', '): $($_.Exception.Message)"
            }
            if ($LASTEXITCODE -ne 0) {
                throw "rustup target add failed for $($missingTriples -join ', ') with exit code $LASTEXITCODE"
            }
        }
        foreach ($payloadDefinition in (Get-RustTargetPayloadDefinitions).Values) {
            $payloadStatus = Get-RustTargetPayloadStatusFromToolchain -ToolchainRoot $candidateToolchainRoot -TargetTriple $payloadDefinition.Triple
            if (-not $payloadStatus.IsComplete) {
                throw (Format-RustTargetPayloadFailure -Status $payloadStatus)
            }
        }
        $expectedCommit = (Get-PayloadDependencyLock -ToolkitRoot $Paths.ToolkitRoot).rust.commit
        $candidateRustc = Join-Path $candidateToolchainRoot 'bin\rustc.exe'
        $rustcDetails = @(& $candidateRustc -vV 2>&1)
        if ($LASTEXITCODE -ne 0 -or $rustcDetails -notcontains "commit-hash: $expectedCommit") {
            throw 'Repaired Rust compiler does not match the dependency lock.'
        }
        Promote-ManagedDirectory -ManagedRoot $toolsRoot -ActivePath $activeHome -CandidatePath $candidateHome
    }
    finally {
        Restore-ScopedEnvironmentVariables -Snapshot $snapshot
        if (Test-Path -LiteralPath $candidateHome) {
            Remove-TransactionDirectory -ManagedRoot $toolsRoot -Path $candidateHome
        }
    }

    foreach ($payloadDefinition in (Get-RustTargetPayloadDefinitions).Values) {
        $payloadStatus = Get-RustTargetPayloadStatusFromToolchain -ToolchainRoot $toolchainRoot -TargetTriple $payloadDefinition.Triple
        if (-not $payloadStatus.IsComplete) {
            throw (Format-RustTargetPayloadFailure -Status $payloadStatus)
        }
    }
}

function Ensure-WindowsLinkInputs {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Paths
    )

    # Regenerated on every release so the shipped sysroot always matches the
    # bundled Zig it was derived from.
    $generator = Join-Path $Paths.ToolkitRoot "scripts\build_win_link_inputs.ps1"
    if (-not (Test-Path -LiteralPath $generator -PathType Leaf)) {
        throw "Required offline release input is missing: $generator"
    }

    Write-Step "Generating Windows link inputs for $script:HostTriple"
    $global:LASTEXITCODE = 0
    & $generator -ToolkitRoot $Paths.ToolkitRoot -Force
    if ($LASTEXITCODE -ne 0) {
        throw "Generating the Windows link inputs failed with exit code $LASTEXITCODE. The offline package would depend on a host Visual Studio installation."
    }
}

function Assert-WindowsSelfContainment {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Paths
    )

    # A package that silently rides on host tooling is the failure this check
    # exists to prevent, so it gates the release rather than merely reporting.
    $check = Join-Path $Paths.ToolkitRoot "check_tool_x64_win.ps1"
    if (-not (Test-Path -LiteralPath $check -PathType Leaf)) {
        throw "Required offline release input is missing: $check"
    }

    Write-Step "Verifying $script:HostTriple builds are self-contained"
    $global:LASTEXITCODE = 0
    $output = & $check *>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host "    $_" }

    if ($exitCode -ne 0) {
        throw "The self-containment check failed with exit code $exitCode. Aborting before writing the release package - see the check output above."
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
    $toolkitLock = Enter-ToolkitOperation -Root $paths.ToolkitRoot -Scope toolkit -Operation 'prepare-offline-release'
    $outputLock = $null
    $candidateStagingRoot = $null
    try {
    $outputLock = Enter-ToolkitOperation -Root $paths.OutputRoot -Scope staging -Operation 'prepare-offline-release'
    Ensure-Directory -Path $paths.OutputRoot
    $publishedStagingRoot = $paths.StagingRoot
    Restore-PreviousManagedDirectory -ManagedRoot $paths.OutputRoot -ActivePath $publishedStagingRoot
    foreach ($stale in @(Get-ChildItem -LiteralPath $paths.OutputRoot -Directory -Filter 'staging.next.*' -ErrorAction SilentlyContinue)) {
        Remove-ManagedPath -Path $stale.FullName -ManagedRoot $paths.OutputRoot
    }
    $candidateStagingRoot = Resolve-ManagedRelativePath -Root $paths.OutputRoot -RelativePath ('staging.next.' + [guid]::NewGuid().ToString('N'))
    $paths.StagingRoot = $candidateStagingRoot
    $paths.CoreRoot = Join-Path $candidateStagingRoot 'core'
    $paths.TargetsRoot = Join-Path $candidateStagingRoot 'targets'
    $paths.LayoutPath = Join-Path $paths.CoreRoot 'install-layout.json'

    foreach ($requiredPath in @(
        (Join-Path $paths.ToolkitRoot "scripts\rust_env.ps1"),
        (Join-Path $paths.ToolkitRoot "scripts\rust_target_payload.ps1"),
        (Join-Path $paths.ToolkitRoot "scripts\rust_path_boundary.ps1"),
        (Join-Path $paths.ToolkitRoot "scripts\rust_transaction.ps1"),
        (Join-Path $paths.ToolkitRoot "scripts\rust_payload_integrity.ps1"),
        (Join-Path $paths.ToolkitRoot "scripts\dependency-lock.json"),
        (Join-Path $paths.ToolkitRoot "scripts\rust_build_isolation.ps1"),
        (Join-Path $paths.ToolkitRoot "scripts\finalize_offline_install.ps1"),
        (Join-Path $paths.ToolkitRoot "scripts\rust_build_x64_win_native.ps1"),
        (Join-Path $paths.ToolkitRoot "scripts\build_win_link_inputs.ps1"),
        (Join-Path $paths.ToolkitRoot "test\fixtures\win_selfcontained\Cargo.toml"),
        (Join-Path $paths.ToolkitRoot "test\fixtures\release_smoke\Cargo.toml"),
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
    Ensure-WindowsLinkInputs -Paths $paths
    Assert-WindowsSelfContainment -Paths $paths

    Write-Step "Refreshing offline release staging under $($paths.StagingRoot)"
    Remove-ManagedPath -Path $paths.StagingRoot -ManagedRoot $paths.OutputRoot
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
        "scripts/rust_target_payload.ps1",
        "scripts/rust_path_boundary.ps1",
        "scripts/rust_transaction.ps1",
        "scripts/rust_payload_integrity.ps1",
        "scripts/dependency-lock.json",
        "scripts/rust_build_isolation.ps1",
        "scripts/finalize_offline_install.ps1",
        "scripts/rust_build_x64_win_native.ps1",
        "scripts/build_win_link_inputs.ps1",
        # The Windows link inputs and the fixture the self-containment check
        # builds. Both ship in core so every installation can build for
        # x86_64-pc-windows-msvc, and verify that it did so without host tooling.
        # U07 retains the previous published sysroot beside the active one for
        # crash recovery. Only the active directory belongs in a customer EXE.
        "tools/sysroot/x86_64-pc-windows-msvc",
        "test/fixtures/win_selfcontained/.gitignore",
        "test/fixtures/win_selfcontained/Cargo.lock",
        "test/fixtures/win_selfcontained/Cargo.toml",
        "test/fixtures/win_selfcontained/build.rs",
        "test/fixtures/win_selfcontained/csrc",
        "test/fixtures/win_selfcontained/src",
        "test/fixtures/release_smoke/.gitignore",
        "test/fixtures/release_smoke/Cargo.lock",
        "test/fixtures/release_smoke/Cargo.toml",
        "test/fixtures/release_smoke/build.rs",
        "test/fixtures/release_smoke/src",
        "test/fixtures/release_smoke/macro/Cargo.toml",
        "test/fixtures/release_smoke/macro/src",
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
    Copy-FileToDestination -SourcePath $paths.ReadmeSourcePath -DestinationPath $readmeTargetPath -SourceRoot $paths.ToolkitRoot -DestinationRoot $paths.CoreRoot -RecordedFiles $coreFiles -InstallRelativePath "docs/README-offline.md"

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

    $writtenLayout = Get-Content -LiteralPath $paths.LayoutPath -Raw | ConvertFrom-Json
    Write-Step 'Indexing and verifying staged payload contents'
    Assert-WindowsLinkInputProvenance -ToolkitRoot $paths.CoreRoot
    $null = New-PayloadIntegrityIndex -StagingRoot $paths.StagingRoot -SourceRoot $paths.ToolkitRoot -Layout $writtenLayout
    $null = Test-PayloadIntegrityIndex -StagingRoot $paths.StagingRoot -Layout $writtenLayout -RequireIndex

    Promote-ManagedDirectory -ManagedRoot $paths.OutputRoot -ActivePath $publishedStagingRoot -CandidatePath $candidateStagingRoot
    $paths.StagingRoot = $publishedStagingRoot
    $paths.CoreRoot = Join-Path $publishedStagingRoot 'core'
    $paths.TargetsRoot = Join-Path $publishedStagingRoot 'targets'
    $paths.LayoutPath = Join-Path $paths.CoreRoot 'install-layout.json'

    Write-Step "Offline release staging complete"
    foreach ($componentName in $layoutComponentFiles.Keys) {
        Write-Host ("  - {0}: {1} files" -f $componentName, $layoutComponentFiles[$componentName].Count)
    }

    return $paths
    }
    finally {
        try {
            if ($candidateStagingRoot -and (Test-Path -LiteralPath $candidateStagingRoot)) {
                Remove-ManagedPath -Path $candidateStagingRoot -ManagedRoot $paths.OutputRoot
            }
        }
        finally {
            Exit-ToolkitOperation -Handle $outputLock
            Exit-ToolkitOperation -Handle $toolkitLock
        }
    }
}

if ($env:RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN -ne "1") {
    Invoke-PrepareOfflineRelease -ToolkitRoot $ToolkitRoot -OutputRoot $OutputRoot -Version $Version | Out-Null
}
