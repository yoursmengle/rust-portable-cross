Set-StrictMode -Version Latest
$pathBoundaryScript = Join-Path $PSScriptRoot 'rust_path_boundary.ps1'
if (-not (Test-Path -LiteralPath $pathBoundaryScript -PathType Leaf)) {
    throw "Missing managed path helper: $pathBoundaryScript"
}
. $pathBoundaryScript

# Rust target payload definitions are deliberately data-only. Callers choose the
# managed rustc and environment; this file never downloads or mutates toolchain state.
$script:RustTargetPayloadDefinitions = [ordered]@{
    host = [ordered]@{
        Triple = "x86_64-pc-windows-msvc"
        RustComponent = "rust-std-x86_64-pc-windows-msvc"
        RequiresStd = $true
        AnchorPatterns = @(
            "libstd-*.rlib",
            "libstd-*.rmeta",
            "libcore-*.rlib",
            "liballoc-*.rlib",
            "libcompiler_builtins-*.rlib"
        )
    }
    armv7 = [ordered]@{
        Triple = "armv7-unknown-linux-musleabihf"
        RustComponent = "rust-std-armv7-unknown-linux-musleabihf"
        RequiresStd = $true
        AnchorPatterns = @(
            "libstd-*.rlib",
            "libstd-*.rmeta",
            "libcore-*.rlib",
            "liballoc-*.rlib",
            "libcompiler_builtins-*.rlib"
        )
    }
    aarch64 = [ordered]@{
        Triple = "aarch64-unknown-linux-musl"
        RustComponent = "rust-std-aarch64-unknown-linux-musl"
        RequiresStd = $true
        AnchorPatterns = @(
            "libstd-*.rlib",
            "libstd-*.rmeta",
            "libcore-*.rlib",
            "liballoc-*.rlib",
            "libcompiler_builtins-*.rlib"
        )
    }
    thumbv7em = [ordered]@{
        Triple = "thumbv7em-none-eabihf"
        RustComponent = "rust-std-thumbv7em-none-eabihf"
        RequiresStd = $false
        AnchorPatterns = @(
            "libcore-*.rlib",
            "liballoc-*.rlib",
            "libcompiler_builtins-*.rlib"
        )
    }
}

function Get-RustTargetPayloadDefinitions {
    return $script:RustTargetPayloadDefinitions
}

function Get-RustTargetPayloadDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetTriple
    )

    foreach ($definition in $script:RustTargetPayloadDefinitions.Values) {
        if ($definition.Triple -eq $TargetTriple) {
            return $definition
        }
    }

    throw "Unsupported Rust target payload: $TargetTriple"
}

function Resolve-RustTargetLibdir {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RustcPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetTriple
    )

    if (-not (Test-Path -LiteralPath $RustcPath -PathType Leaf)) {
        throw "Managed rustc is missing: $RustcPath"
    }

    $global:LASTEXITCODE = 0
    $output = @(& $RustcPath --print target-libdir --target $TargetTriple 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "rustc could not resolve target libdir for ${TargetTriple}: $($output -join [Environment]::NewLine)"
    }

    $libdir = (($output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1).Trim())
    if ([string]::IsNullOrWhiteSpace($libdir)) {
        throw "rustc returned an empty target libdir for $TargetTriple"
    }

    return $libdir
}

function Test-RustTargetPayload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetTriple,

        [Parameter(Mandatory = $true)]
        [string]$Libdir,

        [string]$ManifestPath
    )

    $definition = Get-RustTargetPayloadDefinition -TargetTriple $TargetTriple
    $missing = New-Object 'System.Collections.Generic.List[string]'
    $empty = New-Object 'System.Collections.Generic.List[string]'
    $invalid = New-Object 'System.Collections.Generic.List[string]'
    $manifestEntries = New-Object 'System.Collections.Generic.List[string]'

    $resolvedLibdir = [System.IO.Path]::GetFullPath($Libdir)
    $targetRoot = Split-Path -Parent $resolvedLibdir
    $rustlibRoot = Split-Path -Parent $targetRoot
    $toolchainRoot = Split-Path -Parent (Split-Path -Parent $rustlibRoot)
    if (-not (Test-Path -LiteralPath $resolvedLibdir -PathType Container)) {
        $missing.Add("target libdir: $resolvedLibdir")
    }

    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Join-Path $rustlibRoot ("manifest-rust-std-{0}" -f $TargetTriple)
    }

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        $missing.Add("manifest: $ManifestPath")
    }
    else {
        $manifestLines = @(Get-Content -LiteralPath $ManifestPath -ErrorAction Stop)
        foreach ($line in $manifestLines) {
            if ($line -notmatch '^file:(.+)$') {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    $invalid.Add("manifest line: $line")
                }
                continue
            }

            $entry = $Matches[1].Trim()
            if ([string]::IsNullOrWhiteSpace($entry)) {
                $invalid.Add("manifest line: $line")
                continue
            }

            $manifestEntries.Add($entry)
            $marker = "lib/rustlib/$TargetTriple/lib/"
            if (-not $entry.StartsWith($marker, [System.StringComparison]::OrdinalIgnoreCase)) {
                $invalid.Add("manifest path outside target: $entry")
                continue
            }

            try {
                $candidate = Resolve-ManagedRelativePath -Root $toolchainRoot -RelativePath $entry
                if (-not (Test-ManagedPathInsideRoot -Root $resolvedLibdir -Path $candidate)) {
                    throw "path outside target libdir"
                }
            }
            catch {
                $invalid.Add("unsafe manifest path: $entry ($($_.Exception.Message))")
                continue
            }
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $missing.Add($entry)
            }
            elseif ((Get-Item -LiteralPath $candidate).Length -le 0) {
                $empty.Add($entry)
            }
        }

        if ($manifestEntries.Count -eq 0) {
            $invalid.Add("manifest contains no file entries")
        }
    }

    foreach ($pattern in $definition.AnchorPatterns) {
        $matches = @()
        if (Test-Path -LiteralPath $resolvedLibdir -PathType Container) {
            $matches = @(Get-ChildItem -LiteralPath $resolvedLibdir -File -Filter $pattern -ErrorAction SilentlyContinue)
        }

        if ($matches.Count -eq 0) {
            $missing.Add("anchor: $pattern")
        }
        elseif (-not @($matches | Where-Object { $_.Length -gt 0 })) {
            $empty.Add("anchor: $pattern")
        }
    }

    $problems = @($missing + $empty + $invalid)
    return [pscustomobject]@{
        TargetTriple    = $TargetTriple
        Libdir          = $resolvedLibdir
        ManifestPath    = $ManifestPath
        RequiresStd     = [bool]$definition.RequiresStd
        ManifestEntries = $manifestEntries.Count
        Missing         = @($missing)
        Empty           = @($empty)
        Invalid         = @($invalid)
        IsComplete      = ($problems.Count -eq 0)
    }
}

function Get-RustTargetPayloadStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RustcPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetTriple
    )

    $libdir = Resolve-RustTargetLibdir -RustcPath $RustcPath -TargetTriple $TargetTriple
    return Test-RustTargetPayload -TargetTriple $TargetTriple -Libdir $libdir
}

function Get-RustTargetPayloadStatusFromToolchain {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolchainRoot,

        [Parameter(Mandatory = $true)]
        [string]$TargetTriple
    )

    $libdir = Join-Path $ToolchainRoot ("lib\rustlib\{0}\lib" -f $TargetTriple)
    return Test-RustTargetPayload -TargetTriple $TargetTriple -Libdir $libdir
}

function Format-RustTargetPayloadFailure {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Status
    )

    $details = @($Status.Missing + $Status.Empty + $Status.Invalid)
    if ($details.Count -eq 0) {
        return "Rust target payload is complete: $($Status.TargetTriple) => $($Status.Libdir)"
    }

    return "Incomplete Rust target payload for $($Status.TargetTriple) at $($Status.Libdir): $($details -join '; ')"
}
