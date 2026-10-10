Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:RUST_PORTABLE_CROSS_SKIP_BUILD_MAIN = '1'
. (Join-Path $PSScriptRoot '..\build.ps1')

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $message = ''
    try { & $Action }
    catch { $message = $_.Exception.Message }
    if ($message -notmatch $Pattern) { throw "Expected error /$Pattern/, got: $message" }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('release-validation-tests-' + [guid]::NewGuid().ToString('N'))
try {
    $staging = Join-Path $work 'staging'
    $core = Join-Path $staging 'core'
    $target = Join-Path $staging 'targets\armv7'
    New-Item -ItemType Directory -Path (Join-Path $core 'scripts'), $target -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $core 'scripts\shared.txt') -Value 'shared' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $target 'arm.txt') -Value 'armv7' -Encoding ASCII
    foreach ($name in @('aarch64', 'thumbv7em')) { New-Item -ItemType Directory -Path (Join-Path $staging "targets\$name") -Force | Out-Null }
    $layout = [ordered]@{
        productVersion = '1.2.3'; hostToolchain = '1.98.0-x86_64-pc-windows-msvc'; hostTriple = 'x86_64-pc-windows-msvc'
        componentFiles = [ordered]@{ core = @('scripts/shared.txt'); armv7 = @('arm.txt'); aarch64 = @(); thumbv7em = @() }
        targets = [ordered]@{
            armv7 = @{ triple = 'armv7-unknown-linux-musleabihf' }
            aarch64 = @{ triple = 'aarch64-unknown-linux-musl' }
            thumbv7em = @{ triple = 'thumbv7em-none-eabihf' }
        }
    }
    $layout | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $core 'install-layout.json') -Encoding ASCII
    $before = (Get-FileHash -LiteralPath (Join-Path $core 'install-layout.json') -Algorithm SHA256).Hash
    Assert-Throws -Action { $null = Get-ReleaseLayout -StagingRoot $staging -Version '1.2.4' } -Pattern 'version or host toolchain mismatch'
    if ((Get-FileHash -LiteralPath (Join-Path $core 'install-layout.json') -Algorithm SHA256).Hash -ne $before) { throw 'Stale staging check modified the layout.' }
    Assert-Throws -Action { $null = Assert-StagedRelease -StagingRoot $staging -Version '1.2.3' } -Pattern 'Missing payload integrity index'
    Assert-Throws -Action { $null = Assert-InstallerOutput -InstallerPath (Join-Path $work 'missing.exe') } -Pattern 'expected output not found'
    Assert-Throws -Action { Invoke-DisposableInstallerValidation -InstallerPath (Join-Path $work 'missing.exe') -Version '1.2.3' -WorkRoot $work } -Pattern 'Installer output not found'

    # Use a tiny but genuine index to verify that a byte change stops release
    # validation before any public manifest could be touched.
    function Assert-PayloadRustIdentity { param([string]$ToolkitRoot, [string]$ExpectedCommit) }
    function Assert-WindowsLinkInputProvenance { param([string]$ToolkitRoot) }
    $files = @(
        'scripts/shared.txt', 'install-layout.json', 'scripts/dependency-lock.json',
        'tools/cargo-home/bin/rustup.exe', 'tools/zig/zig.exe',
        'tools/rustup-home/toolchains/1.98.0-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/bin/rust-objcopy.exe',
        'test/fixtures/release_smoke/macro/src/lib.rs',
        'test/fixtures/win_selfcontained/build.rs'
    )
    foreach ($relative in $files) {
        $path = Join-Path $core $relative
        $parent = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $path)) { Set-Content -LiteralPath $path -Value $relative -Encoding ASCII }
    }
    $rustupHash = (Get-FileHash -LiteralPath (Join-Path $core 'tools/cargo-home/bin/rustup.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    $zigHash = (Get-FileHash -LiteralPath (Join-Path $core 'tools/zig/zig.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    [ordered]@{
        rust = @{ release = '1.98.0'; host = 'x86_64-pc-windows-msvc'; commit = ('a' * 40) }
        rustupBootstrap = @{ sha256 = $rustupHash }
        zigArchive = @{ executableSha256 = $zigHash }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $core 'scripts/dependency-lock.json') -Encoding ASCII
    $layout.componentFiles.core = $files
    $layout | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $core 'install-layout.json') -Encoding ASCII
    $writtenLayout = Get-Content -LiteralPath (Join-Path $core 'install-layout.json') -Raw | ConvertFrom-Json
    $null = New-PayloadIntegrityIndex -StagingRoot $staging -Layout $writtenLayout
    $null = Assert-StagedRelease -StagingRoot $staging -Version '1.2.3'
    $publicManifest = Join-Path $work 'public-manifest.json'
    Set-Content -LiteralPath $publicManifest -Value '{"version":"old"}' -Encoding ASCII
    $manifestHash = (Get-FileHash -LiteralPath $publicManifest -Algorithm SHA256).Hash
    Add-Content -LiteralPath (Join-Path $core 'test/fixtures/release_smoke/macro/src/lib.rs') -Value 'tampered'
    Assert-Throws -Action { $null = Assert-StagedRelease -StagingRoot $staging -Version '1.2.3' } -Pattern 'Payload integrity mismatch'
    Set-Content -LiteralPath (Join-Path $core 'test/fixtures/release_smoke/macro/src/lib.rs') -Value 'test/fixtures/release_smoke/macro/src/lib.rs' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $core 'tools/zig/unindexed.txt') -Value 'extra' -Encoding ASCII
    Assert-Throws -Action { $null = Assert-StagedRelease -StagingRoot $staging -Version '1.2.3' } -Pattern 'Unindexed staged file'
    Assert-Throws -Action { Invoke-ReleaseSmokeProcess -InstallRoot (Join-Path $work 'missing-install') -Version '1.2.3' 2>$null } -Pattern 'Installed release smoke failed'
    if ((Get-FileHash -LiteralPath $publicManifest -Algorithm SHA256).Hash -ne $manifestHash) { throw 'Failed release gate changed the public manifest.' }

    # A short parent is used and created; one too deep for Inno's MAX_PATH budget falls back to TEMP.
    $shortParent = Join-Path ([IO.Path]::GetPathRoot($work)) ('rv' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    try {
        $resolved = Get-DisposableInstallParent -InstallParent $shortParent
        if (-not [string]::Equals($resolved.TrimEnd('\'), $shortParent, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $shortParent -PathType Container)) { throw "Short install parent was not used: $resolved" }
    }
    finally { if (Test-Path -LiteralPath $shortParent) { Remove-Item -LiteralPath $shortParent -Force } }
    $deepParent = Join-Path $work ('deep-' + ('x' * 40))
    $fallback = Get-DisposableInstallParent -InstallParent $deepParent 3>$null
    if (-not [string]::Equals($fallback.TrimEnd('\'), [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Path -LiteralPath $deepParent)) { throw "A too-deep install parent must fall back to TEMP: $fallback" }

    $script:stagedIntegrityChecks = 0
    $script:installerChecks = 0
    $script:installParent = $null
    function Assert-StagedRelease { param([string]$StagingRoot, [string]$Version) $script:stagedIntegrityChecks++ }
    function Invoke-DisposableInstallerValidation {
        param([string]$InstallerPath, [string]$Version, [string]$WorkRoot, [string]$InstallParent)
        $script:installerChecks++
        $script:installParent = $InstallParent
    }

    # The staged check is read-only; installation is proven once, on the compiled EXE.
    Invoke-StagedBuildValidation -StagingRoot $staging -Version '1.2.3'
    if ($script:stagedIntegrityChecks -ne 1) { throw 'Every build must check staged integrity.' }
    foreach ($removed in @('Invoke-StagedInstallValidation', 'New-StagedInstallView')) {
        if (Get-Command -Name $removed -ErrorAction SilentlyContinue) { throw "$removed must not come back: it duplicates the installed-EXE validation." }
    }

    Invoke-InstallerBuildValidation -InstallerPath 'installer.exe' -Version '1.2.3' -WorkRoot $work -InstallParent 'X:\v' -SkipInstallValidation
    if ($script:installerChecks -ne 0) { throw 'Fast build mode must skip disposable installer install/uninstall validation.' }
    Invoke-InstallerBuildValidation -InstallerPath 'installer.exe' -Version '1.2.3' -WorkRoot $work -InstallParent 'X:\v'
    if ($script:installerChecks -ne 1) { throw 'Default build mode must run disposable installer validation.' }
    if ($script:installParent -ne 'X:\v') { throw 'The build must pass its short install parent to installer validation.' }
    'release_validation tests passed.'
}
finally {
    if (Test-Path -LiteralPath $work) {
        $parent = Split-Path -Parent $work
        $full = Assert-TransactionChildPath -ManagedRoot $parent -Path $work
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
