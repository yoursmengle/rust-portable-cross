[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:RUST_PORTABLE_CROSS_SKIP_BUILD_MAIN = '1'
. (Join-Path $PSScriptRoot '..\build.ps1')

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Expect-Failure { param([scriptblock]$Action, [string]$Match) $failed = $false; try { & $Action | Out-Null } catch { $failed = $_.Exception.Message.Contains($Match) }; Assert-True $failed "Expected failure containing '$Match'" }

$base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root = Join-Path $base ('rpc-publication-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $root 'repo'
try {
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    $installer = Join-Path $root 'rust-portable-cross-offline-1.0.0.exe'
    $bytes = New-Object byte[] ((24 * 1024 * 1024) + 17)
    for ($i = 0; $i -lt $bytes.Length; $i += 4096) { $bytes[$i] = [byte]($i % 251) }
    [IO.File]::WriteAllBytes($installer, $bytes)
    $web = Split-FileAndPublish -InstallerPath $installer -Version '1.0.0' -RepoPath $repo
    $manifestPath = Join-Path $web 'rust-portable-cross-offline.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-True ($manifest.partCount -eq 2) '24 MiB chunk boundary changed.'
    Assert-PublishedParts -Root $web -Manifest $manifest
    Assert-True ((Get-PartsRecombinedHash -Root $web -Names $manifest.partFileNames) -eq $manifest.originalHash) 'Published parts do not reassemble.'
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $oldPartHash = (Get-FileHash -LiteralPath (Join-Path $web $manifest.partFileNames[0]) -Algorithm SHA256).Hash
    $null = Split-FileAndPublish -InstallerPath $installer -Version '1.0.0' -RepoPath $repo
    Assert-True ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $manifestHash) 'Identical retry changed public manifest.'
    $bytes[0] = 99
    [IO.File]::WriteAllBytes($installer, $bytes)
    Expect-Failure { Split-FileAndPublish -InstallerPath $installer -Version '1.0.0' -RepoPath $repo } 'different installer bytes'
    Assert-True ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $manifestHash) 'Same-version conflict changed manifest.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $web $manifest.partFileNames[0]) -Algorithm SHA256).Hash -eq $oldPartHash) 'Same-version conflict overwrote an old part.'

    $nextInstaller = Join-Path $root 'rust-portable-cross-offline-1.0.1.exe'
    [IO.File]::WriteAllBytes($nextInstaller, $bytes)
    $conflictingPart = Join-Path $web 'rust-portable-cross-offline-1.0.1.exe.part002'
    Set-Content -LiteralPath $conflictingPart -Value 'conflict' -Encoding ASCII
    Expect-Failure { Split-FileAndPublish -InstallerPath $nextInstaller -Version '1.0.1' -RepoPath $repo } 'different bytes'
    Assert-True ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $manifestHash) 'Mid-publication failure changed manifest.'
    Remove-Item -LiteralPath $conflictingPart -Force
    $null = Split-FileAndPublish -InstallerPath $nextInstaller -Version '1.0.1' -RepoPath $repo
    $next = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-True ($next.version -eq '1.0.1') 'Successful retry did not publish new version.'
    Assert-PublishedParts -Root $web -Manifest $next
    Assert-True (Test-Path -LiteralPath (Join-Path $web $manifest.partFileNames[0])) 'Old-version parts were deleted.'
}
finally {
    $full = [IO.Path]::GetFullPath($root)
    $prefix = $base.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $full) -like 'rpc-publication-*' -and (Test-Path -LiteralPath $full)) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

Write-Host 'release_publish tests passed.'
