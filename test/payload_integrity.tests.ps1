[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$env:RUST_PORTABLE_CROSS_SKIP_MAIN = '1'
$env:RUST_PORTABLE_CROSS_SKIP_FINALIZE_INSTALL_MAIN = '1'
. (Join-Path $repo 'scripts\rust_setup.ps1')
. (Join-Path $repo 'scripts\finalize_offline_install.ps1')
. (Join-Path $repo 'scripts\rust_payload_integrity.ps1')

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Expect-Failure { param([scriptblock]$Action, [string]$Match) $failed = $false; try { & $Action } catch { $failed = $_.Exception.Message.Contains($Match) }; Assert-True $failed "Expected failure containing '$Match'" }
function Get-ManagedRustCommit { param([string]$ToolkitRoot) return '88d9e12ae178fab0fb5cc050a94da85685d449ea' }

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root = Join-Path $tempBase ('rpc-integrity-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $html = Join-Path $root 'rustup-init.exe'
    Set-Content -LiteralPath $html -Value '<html>wrong mirror</html>' -Encoding ASCII
    $lock = Get-DependencyLock
    Assert-True (-not (Test-LockedDownload -Path $html -ExpectedSha256 $lock.rustupBootstrap.sha256)) 'Mirror HTML passed bootstrap lock.'
    $zip = Join-Path $root 'zig.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipSource = Join-Path $root 'zip-source'
    New-Item -ItemType Directory -Path $zipSource | Out-Null
    Set-Content -LiteralPath (Join-Path $zipSource 'zig.exe') -Value 'wrong version' -Encoding ASCII
    [IO.Compression.ZipFile]::CreateFromDirectory($zipSource, $zip)
    Assert-True (Test-ZipArchive -Path $zip) 'Test ZIP was not structurally valid.'
    Assert-True (-not (Test-LockedDownload -Path $zip -ExpectedSha256 $lock.zigArchive.sha256 -Zip)) 'Wrong-version valid ZIP passed digest lock.'
    $golden = Join-Path $root 'approved.bin'
    Set-Content -LiteralPath $golden -Value 'approved bootstrap bytes' -Encoding ASCII
    $goldenHash = (Get-FileHash -LiteralPath $golden -Algorithm SHA256).Hash
    function Invoke-FileDownload {
        param([string]$Uri, [string]$Destination)
        if ($Uri -eq 'test://bad') { Set-Content -LiteralPath $Destination -Value '<html>wrong mirror</html>' -Encoding ASCII }
        else { Copy-Item -LiteralPath $golden -Destination $Destination }
    }
    $cached = Join-Path $root 'cached.bin'
    Copy-Item -LiteralPath $html -Destination $cached
    Ensure-Download -Uris @('test://bad', 'test://good') -Destination $cached -Label 'test bootstrap' `
        -ValidateFile { param($Path) Test-LockedDownload -Path $Path -ExpectedSha256 $goldenHash }
    Assert-True ((Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash -eq $goldenHash) 'Damaged cache was not replaced with approved bytes.'

    $staging = Join-Path $root 'staging'
    $core = Join-Path $staging 'core'
    $arm = Join-Path $staging 'targets\armv7'
    $targetFile = 'tools/rustup-home/toolchains/1.98.0-x86_64-pc-windows-msvc/lib/rustlib/armv7-unknown-linux-musleabihf/lib/target.rlib'
    New-Item -ItemType Directory -Path (Join-Path $core 'scripts'),$arm -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'scripts\dependency-lock.json') -Destination (Join-Path $core 'scripts\dependency-lock.json')
    Set-Content -LiteralPath (Join-Path $core 'data.bin') -Value 'core bytes' -Encoding ASCII
    New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $arm $targetFile)) -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $arm $targetFile) -Value 'target bytes' -Encoding ASCII
    $layout = [ordered]@{ productVersion = '1.0.0'; targets = [ordered]@{ armv7 = @{ triple = 'armv7-unknown-linux-musleabihf' } }; componentFiles = [ordered]@{ core = @('data.bin', 'install-layout.json'); armv7 = @($targetFile) } }
    $layoutPath = Join-Path $core 'install-layout.json'
    $layout | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $layoutPath -Encoding UTF8
    $parsed = Get-Content -LiteralPath $layoutPath -Raw | ConvertFrom-Json
    $null = New-PayloadIntegrityIndex -StagingRoot $staging -Layout $parsed
    Assert-True (Test-PayloadIntegrityIndex -StagingRoot $staging -Layout $parsed -RequireIndex) 'Fresh staging integrity check failed.'
    Set-Content -LiteralPath (Join-Path $arm $targetFile) -Value 'modified but nonempty' -Encoding ASCII
    Expect-Failure { Test-PayloadIntegrityIndex -StagingRoot $staging -Layout $parsed -RequireIndex } 'target.rlib'
    Set-Content -LiteralPath (Join-Path $arm $targetFile) -Value 'target bytes' -Encoding ASCII

    $installed = Join-Path $root 'installed'
    Copy-Item -LiteralPath $core -Destination $installed -Recurse
    $installedTarget = Join-Path $installed $targetFile
    New-Item -ItemType Directory -Path (Split-Path -Parent $installedTarget) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $arm $targetFile) -Destination $installedTarget
    Assert-True (Test-PayloadIntegrityIndex -InstallRoot $installed -Layout $parsed) 'Installed payload integrity check failed.'
    Set-Content -LiteralPath $installedTarget -Value 'modified but nonempty' -Encoding ASCII
    Expect-Failure { Invoke-FinalizeOfflineInstall -InstallRoot $installed -SelectedComponents 'armv7' -InstallScope 'perUser' } 'target.rlib'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installed 'tools\cargo-home'))) 'Finalizer modified files before integrity rejection.'
    Remove-Item -LiteralPath (Join-Path $installed 'payload-integrity.json') -Force
    Assert-True (-not (Test-PayloadIntegrityIndex -InstallRoot $installed -Layout $parsed)) 'Legacy payload was not accepted.'

    $sysroot = Join-Path $root 'provenance\tools\sysroot\x86_64-pc-windows-msvc'
    $libRoot = Join-Path $sysroot 'lib'
    New-Item -ItemType Directory -Path $libRoot -Force | Out-Null
    $records = @()
    foreach ($name in @('kernel32', 'ntdll', 'userenv', 'ws2_32', 'dbghelp', 'advapi32', 'user32', 'ole32', 'oleaut32', 'shell32', 'bcrypt', 'msvcrt', 'rpc_winshim')) {
        $path = Join-Path $libRoot "$name.lib"
        Set-Content -LiteralPath $path -Value $name -Encoding ASCII
        $records += [ordered]@{ file = "tools/sysroot/x86_64-pc-windows-msvc/lib/$name.lib"; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    [ordered]@{ triple = 'x86_64-pc-windows-msvc'; zigVersion = '0.13.0'; files = $records } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $sysroot 'PROVENANCE.json') -Encoding UTF8
    Assert-WindowsLinkInputProvenance -ToolkitRoot (Join-Path $root 'provenance')
    Set-Content -LiteralPath (Join-Path $libRoot 'user32.lib') -Value 'wrong but nonempty' -Encoding ASCII
    Expect-Failure { Assert-WindowsLinkInputProvenance -ToolkitRoot (Join-Path $root 'provenance') } 'user32.lib'
}
finally {
    $full = [IO.Path]::GetFullPath($root)
    $prefix = $tempBase.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $full) -like 'rpc-integrity-*' -and (Test-Path -LiteralPath $full)) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

Write-Host 'payload_integrity tests passed.'
