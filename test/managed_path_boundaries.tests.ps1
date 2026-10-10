[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\rust_target_payload.ps1')
$previousFinalizeSkip = [Environment]::GetEnvironmentVariable('RUST_PORTABLE_CROSS_SKIP_FINALIZE_INSTALL_MAIN', 'Process')
$previousReleaseSkip = [Environment]::GetEnvironmentVariable('RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN', 'Process')
try {
    $env:RUST_PORTABLE_CROSS_SKIP_FINALIZE_INSTALL_MAIN = '1'
    $env:RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN = '1'
    . (Join-Path $repoRoot 'scripts\finalize_offline_install.ps1')
    . (Join-Path $repoRoot 'scripts\prepare_offline_release.ps1')
}
finally {
    [Environment]::SetEnvironmentVariable('RUST_PORTABLE_CROSS_SKIP_FINALIZE_INSTALL_MAIN', $previousFinalizeSkip, 'Process')
    [Environment]::SetEnvironmentVariable('RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN', $previousReleaseSkip, 'Process')
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action | Out-Null }
    catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

$testBase = Join-Path ([System.IO.Path]::GetTempPath()) ('rpc-managed-tests-' + [guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $testBase 'kit'
$siblingRoot = Join-Path $testBase 'kit-other'
$junctionPath = Join-Path $installRoot 'junction'
try {
    New-Item -ItemType Directory -Path $installRoot, $siblingRoot -Force | Out-Null
    $sentinelPath = Join-Path $siblingRoot 'sentinel.txt'
    [System.IO.File]::WriteAllText($sentinelPath, 'must remain untouched')
    $sentinelHash = (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash

    if (Test-ManagedPathInsideRoot -Root $installRoot -Path $sentinelPath) {
        throw 'Sibling directory was accepted as inside the managed root.'
    }
    foreach ($relative in @('', '.', '..\kit-other\sentinel.txt', 'C:\outside.txt', '\\server\share\file',
        'safe\..\escape', 'file.txt:stream', 'folder//file', 'CON.txt')) {
        Assert-Throws -Action { Resolve-ManagedRelativePath -Root $installRoot -RelativePath $relative } -Message "Unsafe relative path was accepted: $relative"
    }

    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $junctionPath -Target $siblingRoot -ErrorAction Stop | Out-Null
        $junctionCreated = $true
    }
    catch {
        Write-Host 'Junction creation unavailable; traversal case skipped.'
    }
    if ($junctionCreated) {
        Assert-Throws -Action { Resolve-ManagedRelativePath -Root $installRoot -RelativePath 'junction\sentinel.txt' } -Message 'Junction traversal was accepted.'
        Assert-Throws -Action { Assert-ManagedRootIsOrdinary -Path (Join-Path $junctionPath 'subdir') } -Message 'Junction output root was accepted.'

        # Fast tree removal must delete a junction inside the tree without
        # following it, and must get past read-only files.
        $doomed = Join-Path $installRoot 'doomed'
        New-Item -ItemType Directory -Path (Join-Path $doomed 'nested') -Force | Out-Null
        $readOnlyFile = Join-Path $doomed 'nested\readonly.txt'
        [System.IO.File]::WriteAllText($readOnlyFile, 'x')
        [System.IO.File]::SetAttributes($readOnlyFile, [System.IO.FileAttributes]::ReadOnly)
        New-Item -ItemType Junction -Path (Join-Path $doomed 'nested\escape') -Target $siblingRoot | Out-Null
        Remove-ManagedPath -Path $doomed -ManagedRoot $installRoot
        if (Test-Path -LiteralPath $doomed) { throw 'Remove-ManagedPath left the tree behind.' }
        if (-not (Test-Path -LiteralPath $sentinelPath -PathType Leaf)) { throw 'Tree removal followed a junction out of the managed root.' }
    }

    $layout = [ordered]@{
        productName = 'Rust Portable Cross'
        productVersion = '1.0.0'
        hostToolchain = '1.98.0-x86_64-pc-windows-msvc'
        hostTriple = 'x86_64-pc-windows-msvc'
        hostRustComponents = @('rust-std-x86_64-pc-windows-msvc')
        targets = [ordered]@{
            armv7 = [ordered]@{ triple = 'armv7-unknown-linux-musleabihf'; rustComponent = 'rust-std-armv7-unknown-linux-musleabihf' }
        }
        componentFiles = [ordered]@{
            core = @('tools/cargo-home/bin/cargo.exe')
            armv7 = @('scripts/rust_build_armv7.ps1')
        }
    }
    $layoutPath = Join-Path $installRoot 'install-layout.json'
    $layout | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $layoutPath -Encoding ASCII
    $validLayout = Get-InstallLayout -InstallRoot $installRoot
    $null = @(Assert-InstallLayoutPreflight -InstallRoot $installRoot -Layout $validLayout -SelectedComponents @())
    $null = @(Assert-InstallLayoutPreflight -InstallRoot $installRoot -Layout $validLayout -SelectedComponents @('armv7'))

    foreach ($badPath in @('../kit-other/sentinel.txt', 'tools/cargo-home/bin/cargo.exe', 'C:/outside.txt', 'scripts/rust_build_armv7.ps1:stream')) {
        $layout.componentFiles.armv7 = @($badPath)
        $layout | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $layoutPath -Encoding ASCII
        Assert-Throws -Action { Invoke-FinalizeOfflineInstall -InstallRoot $installRoot -SelectedComponents '' -InstallScope 'perUser' } -Message "Finalizer accepted malicious component path: $badPath"
        if (Test-Path -LiteralPath (Join-Path $installRoot 'tools\rustup-home\settings.toml')) {
            throw 'Finalizer wrote settings before rejecting an invalid layout.'
        }
    }
    $layout.componentFiles.armv7 = @('scripts/rust_build_armv7.ps1')
    $layout | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $layoutPath -Encoding ASCII
    Assert-Throws -Action { Invoke-FinalizeOfflineInstall -InstallRoot $installRoot -SelectedComponents 'unknown' -InstallScope 'perUser' } -Message 'Unknown selected component was accepted.'

    Assert-Throws -Action { Get-OfflineReleasePaths -ToolkitRoot $installRoot -OutputRoot $testBase } -Message 'Output ancestor of the toolkit was accepted.'
    Assert-Throws -Action { Remove-ManagedPath -Path $sentinelPath -ManagedRoot $installRoot } -Message 'Cleanup accepted sibling path.'

    $triple = 'armv7-unknown-linux-musleabihf'
    $libdir = Join-Path $installRoot "tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\$triple\lib"
    New-Item -ItemType Directory -Path $libdir -Force | Out-Null
    $manifestPath = Join-Path (Split-Path -Parent (Split-Path -Parent $libdir)) "manifest-rust-std-$triple"
    Set-Content -LiteralPath $manifestPath -Value "file:lib/rustlib/$triple/lib/../../../../../../kit-other/sentinel.txt" -Encoding ASCII
    $status = Test-RustTargetPayload -TargetTriple $triple -Libdir $libdir -ManifestPath $manifestPath
    if ($status.IsComplete -or @($status.Invalid | Where-Object { $_ -like 'unsafe manifest path:*' }).Count -eq 0) {
        throw 'Rust target manifest traversal was not reported as invalid.'
    }
    if ((Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash -cne $sentinelHash) {
        throw 'Outside sentinel changed during rejected operations.'
    }
}
finally {
    $resolvedBase = [System.IO.Path]::GetFullPath($testBase)
    $temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedBase.StartsWith($temporaryBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedBase) -like 'rpc-managed-tests-*' -and
        (Test-Path -LiteralPath $resolvedBase -PathType Container)) {
        if (Test-Path -LiteralPath $junctionPath) {
            $junction = Get-Item -LiteralPath $junctionPath -Force
            if (($junction.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                throw "Expected a reparse point at test junction: $junctionPath"
            }
            [System.IO.Directory]::Delete($junctionPath)
        }
        Remove-Item -LiteralPath $resolvedBase -Recurse -Force
    }
}

Write-Host 'managed_path_boundaries tests passed.'
