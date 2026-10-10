Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'rust_path_boundary.ps1')

function Get-PayloadFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Get-PayloadDependencyLock {
    param([Parameter(Mandatory = $true)][string]$ToolkitRoot)

    $lockPath = Join-Path $ToolkitRoot 'scripts\dependency-lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw "Missing payload dependency lock: $lockPath"
    }
    return Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
}

function Get-ManagedRustCommit {
    param([Parameter(Mandatory = $true)][string]$ToolkitRoot)

    $rustcPath = Join-Path $ToolkitRoot 'tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\bin\rustc.exe'
    if (-not (Test-Path -LiteralPath $rustcPath -PathType Leaf)) {
        throw "Managed rustc is missing: $rustcPath"
    }
    $output = @(& $rustcPath -vV 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Managed rustc -vV failed: $rustcPath" }
    $commitLine = @($output | Where-Object { [string]$_ -match '^commit-hash: ([a-fA-F0-9]{40})$' })
    if ($commitLine.Count -ne 1) { throw 'Managed rustc did not report a single commit hash.' }
    return ([string]$commitLine[0]).Substring('commit-hash: '.Length).ToLowerInvariant()
}

function Get-PayloadComponentRoot {
    param([string]$StagingRoot, [string]$InstallRoot, [string]$Component)

    if ($StagingRoot) {
        if ($Component -eq 'core') { return Join-Path $StagingRoot 'core' }
        return Join-Path (Join-Path $StagingRoot 'targets') $Component
    }
    return $InstallRoot
}

function Assert-PayloadRustIdentity {
    param([string]$ToolkitRoot, [string]$ExpectedCommit)

    $lock = Get-PayloadDependencyLock -ToolkitRoot $ToolkitRoot
    if ($lock.rust.release -ne '1.98.0' -or
        $lock.rust.host -ne 'x86_64-pc-windows-msvc' -or
        $lock.rust.commit -ne $ExpectedCommit) {
        throw 'Payload index and dependency lock disagree on the Rust release.'
    }
    $actualCommit = Get-ManagedRustCommit -ToolkitRoot $ToolkitRoot
    if ($actualCommit -ne $ExpectedCommit) {
        throw "Managed Rust compiler commit mismatch: expected $ExpectedCommit, got $actualCommit"
    }
}

function New-PayloadIntegrityIndex {
    param(
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [string]$SourceRoot,
        [Parameter(Mandatory = $true)][object]$Layout
    )

    $staging = Assert-ManagedRootIsOrdinary -Path $StagingRoot
    $core = Join-Path $staging 'core'
    $lock = Get-PayloadDependencyLock -ToolkitRoot $core
    Assert-PayloadRustIdentity -ToolkitRoot $core -ExpectedCommit ([string]$lock.rust.commit)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($component in @($Layout.componentFiles.PSObject.Properties | Sort-Object Name)) {
        $componentRoot = Get-PayloadComponentRoot -StagingRoot $staging -Component $component.Name
        foreach ($relative in @($component.Value | Sort-Object)) {
            $path = Resolve-ManagedRelativePath -Root $componentRoot -RelativePath ([string]$relative)
            # [IO.FileInfo] rather than Test-Path / Get-Item: this loop runs once per
            # payload file (~16k), where the cmdlets' per-call cost dominated.
            $file = [IO.FileInfo]::new($path)
            if (-not $file.Exists) { throw "Missing staged payload file: $($component.Name)/$relative" }
            if ($SourceRoot -and $relative -notin @('Activate Rust Portable Cross.ps1', 'install-layout.json', 'docs/sample-dependencies.json')) {
                $sourceRelative = if ($relative -eq 'docs/README-offline.md') { 'docs/customer/README-offline.md' } else { [string]$relative }
                $sourcePath = Resolve-ManagedRelativePath -Root $SourceRoot -RelativePath $sourceRelative -AllowInternalFileLink
                $source = [IO.FileInfo]::new($sourcePath)
                if (-not $source.Exists) { throw "Missing source payload file: $($component.Name)/$relative" }
                # The source is compared by size, not re-hashed: reading all ~16k source
                # files again cost minutes whenever an on-access scanner had not seen
                # them recently, and the digest below is of the bytes that actually ship.
                # A link's own length is not its target's, so links are not compared.
                if (($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and $source.Length -ne $file.Length) {
                    throw "Staged payload file differs in size from its source: $($component.Name)/$relative"
                }
            }
            $entries.Add([ordered]@{
                component = [string]$component.Name
                path = [string]$relative
                size = [long]$file.Length
                sha256 = Get-PayloadFileHash -Path $path
            })
        }
    }
    $index = [ordered]@{
        formatVersion = 1
        productVersion = [string]$Layout.productVersion
        rustcCommit = [string]$lock.rust.commit
        files = $entries.ToArray()
    }
    $indexPath = Join-Path $core 'payload-integrity.json'
    $index | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $indexPath -Encoding UTF8
    return $indexPath
}

function Test-PayloadIntegrityIndex {
    param(
        [string]$StagingRoot,
        [string]$InstallRoot,
        [Parameter(Mandatory = $true)][object]$Layout,
        [switch]$RequireIndex
    )

    if ([bool]$StagingRoot -eq [bool]$InstallRoot) { throw 'Specify exactly one payload root.' }
    $root = if ($StagingRoot) { Assert-ManagedRootIsOrdinary -Path $StagingRoot } else { Assert-ManagedRootIsOrdinary -Path $InstallRoot }
    $core = Get-PayloadComponentRoot -StagingRoot $StagingRoot -InstallRoot $InstallRoot -Component 'core'
    $indexPath = Join-Path $core 'payload-integrity.json'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        if ($RequireIndex) { throw "Missing payload integrity index: $indexPath" }
        return $false
    }
    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
    if ($index.formatVersion -ne 1 -or $index.productVersion -ne $Layout.productVersion -or
        $index.rustcCommit -notmatch '^[a-f0-9]{40}$') {
        throw 'Payload integrity index header does not match the install layout.'
    }
    Assert-PayloadRustIdentity -ToolkitRoot $core -ExpectedCommit ([string]$index.rustcCommit)

    $expected = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($component in $Layout.componentFiles.PSObject.Properties) {
        foreach ($relative in @($component.Value)) {
            $key = "$($component.Name)/$relative"
            if (-not $expected.Add($key)) { throw "Duplicate payload layout entry: $key" }
        }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($index.files)) {
        $name = [string]$entry.component
        $relative = [string]$entry.path
        $key = "$name/$relative"
        if (-not $expected.Contains($key) -or -not $seen.Add($key)) { throw "Unexpected or duplicate payload index entry: $key" }
        if ($entry.sha256 -notmatch '^[a-f0-9]{64}$' -or [long]$entry.size -lt 0) { throw "Invalid payload index hash or size: $key" }
        $componentRoot = Get-PayloadComponentRoot -StagingRoot $StagingRoot -InstallRoot $InstallRoot -Component $name
        $path = Resolve-ManagedRelativePath -Root $componentRoot -RelativePath $relative
        $file = [IO.FileInfo]::new($path)
        if (-not $file.Exists) { throw "Missing payload file: $key" }
        if ([long]$file.Length -ne [long]$entry.size -or
            -not [string]::Equals((Get-PayloadFileHash -Path $path), [string]$entry.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Payload integrity mismatch: $key"
        }
    }
    if ($seen.Count -ne $expected.Count) { throw "Payload integrity index lacks $($expected.Count - $seen.Count) layout file(s)." }
    return $true
}

function Assert-WindowsLinkInputProvenance {
    param([Parameter(Mandatory = $true)][string]$ToolkitRoot, [string]$SysrootRoot)

    $sysroot = if ($SysrootRoot) { $SysrootRoot } else { Join-Path $ToolkitRoot 'tools\sysroot\x86_64-pc-windows-msvc' }
    $libRoot = Join-Path $sysroot 'lib'
    $provenancePath = Join-Path $sysroot 'PROVENANCE.json'
    if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf)) {
        throw "Missing Windows link input provenance: $provenancePath"
    }
    $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
    $expectedNames = @(
        'kernel32.lib', 'ntdll.lib', 'userenv.lib', 'ws2_32.lib',
        'dbghelp.lib', 'advapi32.lib', 'user32.lib', 'ole32.lib',
        'oleaut32.lib', 'shell32.lib', 'bcrypt.lib', 'msvcrt.lib',
        'rpc_winshim.lib'
    )
    if ($provenance.triple -ne 'x86_64-pc-windows-msvc' -or $provenance.zigVersion -ne '0.13.0' -or
        @($provenance.files).Count -ne $expectedNames.Count) {
        throw 'Windows link input provenance has unexpected target, Zig version, or file count.'
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($provenance.files)) {
        $name = [System.IO.Path]::GetFileName([string]$record.file)
        if ($expectedNames -notcontains $name -or -not $seen.Add($name) -or
            [string]$record.file -ne "tools/sysroot/x86_64-pc-windows-msvc/lib/$name" -or
            [string]$record.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
            throw "Invalid Windows link input provenance record: $($record.file)"
        }
        $path = Resolve-ManagedRelativePath -Root $libRoot -RelativePath $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            -not [string]::Equals((Get-PayloadFileHash -Path $path),
                [string]$record.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Windows link input digest mismatch: $name"
        }
    }
    if ($seen.Count -ne $expectedNames.Count) { throw 'Windows link input provenance is incomplete.' }
}
