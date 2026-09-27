Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN = '1'
. (Join-Path $PSScriptRoot '..\scripts\prepare_offline_release.ps1')

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $message = ''
    try { & $Action }
    catch { $message = $_.Exception.Message }
    if ($message -notmatch $Pattern) { throw "Expected /$Pattern/, got: $message" }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workRoot = Join-Path $repoRoot ('dist\u09-cache-tests-' + [guid]::NewGuid().ToString('N'))
try {
    $toolkit = Join-Path $workRoot 'toolkit'
    $sample = Join-Path $toolkit 'sample'
    New-Item -ItemType Directory -Path $sample -Force | Out-Null
    $archive = Join-Path $workRoot 'tiny.crate'
    Set-Content -LiteralPath $archive -Value 'known archive bytes' -Encoding ASCII
    $digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $lock = @"
version = 4

[[package]]
name = "tiny"
version = "1.2.3"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "$digest"

[[package]]
name = "local-sample"
version = "0.1.0"
"@
    Set-Content -LiteralPath (Join-Path $sample 'Cargo.lock') -Value $lock -Encoding UTF8
    $packages = @(Get-SampleRegistryPackages -ToolkitRoot $toolkit)
    if ($packages.Count -ne 1 -or $packages[0].name -ne 'tiny') { throw 'Lockfile registry selection is wrong.' }
    if ((Assert-LockedSampleArchive -Package $packages[0] -ArchivePath $archive) -ne $digest) {
        throw 'Correct locked archive was rejected.'
    }
    Add-Content -LiteralPath $archive -Value 'corruption'
    Assert-Throws -Action { Assert-LockedSampleArchive -Package $packages[0] -ArchivePath $archive } -Pattern 'checksum mismatch: tiny@1.2.3'
    Remove-Item -LiteralPath $archive
    Assert-Throws -Action { Assert-LockedSampleArchive -Package $packages[0] -ArchivePath $archive } -Pattern 'Missing locked sample crate tiny@1.2.3'
    if ((Get-CratesIoSparseIndexPath -Name 'tiny') -ne 'ti/ny/tiny' -or
        (Get-CratesIoSparseIndexPath -Name 'cc') -ne '2/cc') {
        throw 'Sparse index path selection is wrong.'
    }
    'offline_sample_cache tests passed.'
}
finally {
    if (Test-Path -LiteralPath $workRoot) {
        $resolved = [IO.Path]::GetFullPath($workRoot)
        $dist = [IO.Path]::GetFullPath((Join-Path $repoRoot 'dist'))
        if (-not (Test-ManagedPathInsideRoot -Root $dist -Path $resolved)) {
            throw "Refusing to remove test path outside dist: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
