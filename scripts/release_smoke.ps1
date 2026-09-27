[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$InstallRoot, [Parameter(Mandatory = $true)][string]$Version)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$install = [IO.Path]::GetFullPath($InstallRoot)
$layoutPath = Join-Path $install 'install-layout.json'
if (-not (Test-Path -LiteralPath $layoutPath -PathType Leaf)) { throw "Missing installed layout: $layoutPath" }
$layout = Get-Content -LiteralPath $layoutPath -Raw | ConvertFrom-Json
if ($layout.productVersion -ne $Version) { throw "Installed product version mismatch: $($layout.productVersion)" }

$system = Join-Path $env:WINDIR 'System32'
$env:PATH = @(
    (Join-Path $install 'scripts'),
    (Join-Path $install 'tools\cargo-home\bin'),
    (Join-Path $install 'tools\zig'),
    (Join-Path $install 'tools\wrappers'),
    (Join-Path $install 'tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\x86_64-pc-windows-msvc\bin'),
    $system, $env:WINDIR, (Join-Path $system 'WindowsPowerShell\v1.0'),
    (Join-Path $env:ProgramFiles 'PowerShell\7')
) -join ';'
$env:RUSTUP_AUTO_INSTALL = '0'
$env:CARGO_NET_OFFLINE = 'true'
$env:HTTP_PROXY = 'http://127.0.0.1:9'
$env:HTTPS_PROXY = 'http://127.0.0.1:9'
$env:ALL_PROXY = 'http://127.0.0.1:9'
$env:NO_PROXY = ''
foreach ($name in @('RUSTC', 'RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER', 'CARGO_BUILD_RUSTC', 'CARGO_BUILD_RUSTC_WRAPPER')) {
    Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
}

$env:RUST_PORTABLE_CROSS_SKIP_FINALIZE_INSTALL_MAIN = '1'
. (Join-Path $install 'scripts\finalize_offline_install.ps1')
$null = Test-PayloadIntegrityIndex -InstallRoot $install -Layout $layout -RequireIndex
Test-OfflineInstall -InstallRoot $install -Layout $layout -SelectedComponents @('armv7', 'aarch64', 'thumbv7em')
Assert-WindowsLinkInputProvenance -ToolkitRoot $install
$warning = Join-Path $install 'install-validation-warning.txt'
if (Test-Path -LiteralPath $warning) { throw "Installer reported validation warning: $warning" }

. (Join-Path $install 'scripts\rust_env.ps1')
if (-not [string]::Equals($env:RUST_PORTABLE_CROSS_ROOT.TrimEnd('\'), $install.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Activation selected a different toolkit root.'
}
$cargo = (Get-Command cargo -ErrorAction Stop).Source
if (-not [string]::Equals($cargo, (Join-Path $install 'tools\cargo-home\bin\cargo.exe'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Activation resolved external cargo: $cargo"
}

$fixture = Join-Path $install 'test\fixtures\release_smoke'
foreach ($entry in @(
    @{ Name = 'ARMv7'; Script = 'rust_build_armv7.ps1'; Triple = 'armv7-unknown-linux-musleabihf' },
    @{ Name = 'AArch64'; Script = 'rust_build_aarch64.ps1'; Triple = 'aarch64-unknown-linux-musl' }
)) {
    Push-Location -LiteralPath $fixture
    try {
        & (Join-Path $install ('scripts\' + $entry.Script))
        if ($LASTEXITCODE -ne 0) { throw "$($entry.Name) release smoke failed ($LASTEXITCODE)" }
        $binary = Join-Path $fixture "target\$($entry.Triple)\release\release_smoke"
        if (-not (Test-Path -LiteralPath $binary -PathType Leaf) -or (Get-Item -LiteralPath $binary).Length -eq 0) {
            throw "$($entry.Name) release smoke output is missing: $binary"
        }
    }
    finally { Pop-Location }
}

& (Join-Path $install 'scripts\rust_build_x64_win_native.ps1') -ProjectPath (Join-Path $install 'test\fixtures\win_selfcontained')
if ($LASTEXITCODE -ne 0) { throw "Windows release smoke failed ($LASTEXITCODE)" }
$windowsExe = Join-Path $install 'test\fixtures\win_selfcontained\target\x86_64-pc-windows-msvc\release\win_selfcontained.exe'
if (-not (Test-Path -LiteralPath $windowsExe -PathType Leaf)) { throw "Windows release smoke output is missing: $windowsExe" }
$windowsOutput = @(& $windowsExe 2>&1)
if ($LASTEXITCODE -ne 0 -or $windowsOutput -notcontains 'SELFCONTAINED OK') {
    throw "Windows release smoke executable failed: $($windowsOutput -join [Environment]::NewLine)"
}
& (Join-Path $install 'sample_embedded\make_image.ps1')
if ($LASTEXITCODE -ne 0) { throw "Embedded release smoke failed ($LASTEXITCODE)" }
foreach ($extension in @('bin', 'hex')) {
    $image = Join-Path $install "sample_embedded\sample_embedded.$extension"
    if (-not (Test-Path -LiteralPath $image -PathType Leaf) -or (Get-Item -LiteralPath $image).Length -eq 0) {
        throw "Missing embedded release smoke output: $image"
    }
}
Write-Host "Release smoke passed for $install"
