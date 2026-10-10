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
    Assert-True ($web -eq (Join-Path $root 'output\rust-portable-cross')) 'Published files were written to the wrong output directory.'
    $manifestPath = Join-Path $web 'rust-portable-cross-offline.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-True ($manifest.partCount -eq 2) '24 MiB chunk boundary changed.'
    Assert-PublishedParts -Root $web -Manifest $manifest
    Assert-True ((Get-PartsRecombinedHash -Root $web -Names $manifest.partFileNames) -eq $manifest.originalHash) 'Published parts do not reassemble.'
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $oldPartHash = (Get-FileHash -LiteralPath (Join-Path $web $manifest.partFileNames[0]) -Algorithm SHA256).Hash
    $null = Split-FileAndPublish -InstallerPath $installer -Version '1.0.0' -RepoPath $repo
    Assert-True ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $manifestHash) 'Identical retry changed public manifest.'
    # An injected failure after parts have been swapped must put the previous
    # version back: same manifest, same part bytes, nothing left over.
    $bytes[0] = 99
    [IO.File]::WriteAllBytes($installer, $bytes)
    $realAssert = ${function:Assert-PublishedParts}
    function Assert-PublishedParts { param([string]$Root, [object]$Manifest) throw 'injected verification failure' }
    try { Expect-Failure { Split-FileAndPublish -InstallerPath $installer -Version '1.0.0' -RepoPath $repo 3>$null } 'injected verification failure' }
    finally { Set-Item -Path Function:Assert-PublishedParts -Value $realAssert }
    Assert-True ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $manifestHash) 'A failed replacement changed the manifest.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $web $manifest.partFileNames[0]) -Algorithm SHA256).Hash -eq $oldPartHash) 'A failed replacement did not restore the old part.'
    Assert-PublishedParts -Root $web -Manifest $manifest
    Assert-True (@(Get-ChildItem -LiteralPath $web -Force -Directory -Filter '.publish-*').Count -eq 0) 'A failed replacement left its private directory behind.'

    # Building the same version again produces different bytes; it replaces the
    # published set, including a part the shorter rebuild no longer has.
    $shorter = New-Object byte[] (1024 * 1024)
    for ($i = 0; $i -lt $shorter.Length; $i += 4096) { $shorter[$i] = [byte](($i + 7) % 251) }
    [IO.File]::WriteAllBytes($installer, $shorter)
    $warnings = @(Split-FileAndPublish -InstallerPath $installer -Version '1.0.0' -RepoPath $repo 3>&1 |
        Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    Assert-True ($warnings.Count -eq 1 -and $warnings[0].Message -match 'replacing it') 'Replacing a published version must say so.'
    $rebuilt = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-True ($rebuilt.version -eq '1.0.0' -and $rebuilt.partCount -eq 1) 'The same-version rebuild was not published.'
    Assert-True ($rebuilt.originalHash -eq (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()) 'The manifest does not describe the rebuilt installer.'
    Assert-PublishedParts -Root $web -Manifest $rebuilt
    Assert-True ((Get-PartsRecombinedHash -Root $web -Names @($rebuilt.partFileNames)) -eq $rebuilt.originalHash) 'Rebuilt parts do not reassemble.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $web $manifest.partFileNames[1]))) 'A part the rebuild no longer has was left published.'
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash

    # A stray file at a new version's part name is an earlier build's leftover, and
    # is replaced rather than blocking the publication.
    $nextInstaller = Join-Path $root 'rust-portable-cross-offline-1.0.1.exe'
    [IO.File]::WriteAllBytes($nextInstaller, $bytes)
    $conflictingPart = Join-Path $web 'rust-portable-cross-offline-1.0.1.exe.part002'
    Set-Content -LiteralPath $conflictingPart -Value 'conflict' -Encoding ASCII
    $null = Split-FileAndPublish -InstallerPath $nextInstaller -Version '1.0.1' -RepoPath $repo
    $next = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-True ($next.version -eq '1.0.1') 'The new version was not published.'
    Assert-PublishedParts -Root $web -Manifest $next
    Assert-True ((Get-PartsRecombinedHash -Root $web -Names @($next.partFileNames)) -eq $next.originalHash) 'New-version parts do not reassemble.'
    Assert-True (Test-Path -LiteralPath (Join-Path $web $rebuilt.partFileNames[0])) "Another version's parts were deleted."
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
