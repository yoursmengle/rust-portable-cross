[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:RustToolkitScriptPath = $PSCommandPath
$script:RustToolkitScriptRoot = $PSScriptRoot
$script:RustToolkitRoot = if ($script:RustToolkitScriptRoot) { Split-Path -Parent $script:RustToolkitScriptRoot } else { $null }
$rustTargetPayloadScript = Join-Path $script:RustToolkitScriptRoot "rust_target_payload.ps1"
if (-not (Test-Path -LiteralPath $rustTargetPayloadScript -PathType Leaf)) {
    throw "Missing Rust target payload helper: $rustTargetPayloadScript"
}
. $rustTargetPayloadScript

# Download override knobs:
# - RUST_PORTABLE_CROSS_RUSTUP_INIT_URL / RUST_PORTABLE_CROSS_ZIG_URL: highest-priority direct download URL
# - RUST_PORTABLE_CROSS_RUSTUP_MIRRORS / RUST_PORTABLE_CROSS_ZIG_MIRRORS: mainland mirror URL list, split by ; , or newline
# - RUST_PORTABLE_CROSS_RUSTUP_MIRROR_BASE / RUST_PORTABLE_CROSS_ZIG_MIRROR_BASE: mainland mirror base URL, joined with the built-in relative path
# - RUST_PORTABLE_CROSS_DOWNLOAD_PROXY_PREFIX: optional proxy prefix inserted before the official upstream URL
# - RUST_PORTABLE_CROSS_WGET_PATH: optional absolute path to wget executable for download backend override
# - RUST_PORTABLE_CROSS_DOWNLOAD_RETRIES: retry count for wget/curl download backends (default: 6)
# - RUST_PORTABLE_CROSS_CURL_IP_MODE: optional curl IP mode (4, 6, or auto)
# Download order is always: direct override -> mainland mirrors -> proxy -> official upstream fallback.

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
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @()
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
}

function Get-NativeOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @()
    )

    $output = & $FilePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }

    return @($output)
}

function Get-RustupDistServerCandidates {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($server in @(
        $env:RUSTUP_DIST_SERVER,
        "https://rsproxy.cn",
        "https://mirror.sjtu.edu.cn/rust-static",
        "https://static.rust-lang.org"
    )) {
        if ([string]::IsNullOrWhiteSpace($server)) {
            continue
        }

        $normalized = $server.Trim().TrimEnd('/')
        if (-not $candidates.Contains($normalized)) {
            $candidates.Add($normalized)
        }
    }

    return @($candidates)
}

function Install-PinnedRustToolchain {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RustupPath,

        [Parameter(Mandatory = $true)]
        [string]$Toolchain
    )

    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($server in (Get-RustupDistServerCandidates)) {
        $env:RUSTUP_DIST_SERVER = $server
        try {
            Invoke-Native -FilePath $RustupPath -Arguments @(
                "toolchain",
                "install",
                $Toolchain,
                "--profile",
                "minimal",
                "--no-self-update"
            )
            return
        }
        catch {
            $failures.Add("${server}: $($_.Exception.Message)")
            Write-Warning "Rust $Toolchain is unavailable from $server. Trying the next distribution server."
        }
    }

    throw "Unable to install pinned Rust toolchain $Toolchain from any configured distribution server:`n$($failures -join [Environment]::NewLine)"
}

function Add-PathEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Entry
    )

    $pathEntries = @($env:PATH -split ";")
    if ($pathEntries -notcontains $Entry) {
        $env:PATH = "$Entry;$env:PATH"
    }
}

function Test-ZipArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $archive.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $downloadRetries = 6
    $parsedDownloadRetries = 0
    if ([int]::TryParse($env:RUST_PORTABLE_CROSS_DOWNLOAD_RETRIES, [ref]$parsedDownloadRetries) -and $parsedDownloadRetries -ge 1) {
        $downloadRetries = $parsedDownloadRetries
    }

    $wgetCommand = $null
    if (-not [string]::IsNullOrWhiteSpace($env:RUST_PORTABLE_CROSS_WGET_PATH) -and (Test-Path -LiteralPath $env:RUST_PORTABLE_CROSS_WGET_PATH)) {
        $wgetCommand = Get-Item -LiteralPath $env:RUST_PORTABLE_CROSS_WGET_PATH
    }
    if (-not $wgetCommand) {
        $wgetCommand = Get-Command "wget.exe" -ErrorAction SilentlyContinue
    }
    if (-not $wgetCommand) {
        $wgetCommand = Get-Command "wget" -CommandType Application -ErrorAction SilentlyContinue
    }

    if ($wgetCommand) {
        $wgetSource = if ($wgetCommand.PSObject.Properties.Name -contains "Source") { $wgetCommand.Source } else { $wgetCommand.FullName }
        Invoke-Native -FilePath $wgetSource -Arguments @(
            "--tries", "$downloadRetries",
            "--waitretry", "2",
            "--timeout", "30",
            "--read-timeout", "300",
            "--continue",
            "-O", $Destination,
            $Uri
        )
        return
    }

    $curlCommand = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    if ($curlCommand) {
        $curlArguments = @(
            "-L",
            "--fail",
            "--silent",
            "--show-error",
            "--retry", "$downloadRetries",
            "--retry-delay", "2",
            "--connect-timeout", "30",
            "--speed-time", "60",
            "--speed-limit", "1024",
            "-C", "-",
            "-o", $Destination,
            $Uri
        )

        if ($env:RUST_PORTABLE_CROSS_CURL_IP_MODE -eq "4") {
            $curlArguments = @("--ipv4") + $curlArguments
        }
        elseif ($env:RUST_PORTABLE_CROSS_CURL_IP_MODE -eq "6") {
            $curlArguments = @("--ipv6") + $curlArguments
        }

        Invoke-Native -FilePath $curlCommand.Source -Arguments $curlArguments
        return
    }

    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $Uri -OutFile $Destination
}

function Ensure-Download {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Uris,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [scriptblock]$ValidateFile = { param($Path) $true },

        [string]$InvalidCacheMessage = "Cached file failed validation"
    )

    $hasCachedFile = Test-Path -LiteralPath $Destination
    if ($hasCachedFile -and -not (& $ValidateFile $Destination)) {
        Write-Warning "${InvalidCacheMessage}: $Destination. Deleting cached file and retrying download."
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        $hasCachedFile = $false
    }

    if (-not $hasCachedFile) {
        $failures = @()
        foreach ($uri in $Uris) {
            if ([string]::IsNullOrWhiteSpace($uri)) {
                continue
            }

            $temporaryDestination = "{0}.{1}.tmp" -f $Destination, ([guid]::NewGuid().ToString("N"))
            try {
                Write-Step "Downloading $Label from $uri"
                Invoke-FileDownload -Uri $uri -Destination $temporaryDestination

                if (-not (& $ValidateFile $temporaryDestination)) {
                    throw "Downloaded file failed validation"
                }

                Move-Item -LiteralPath $temporaryDestination -Destination $Destination -Force
                return
            }
            catch {
                $failures += "${uri}: $($_.Exception.Message)"
                if (Test-Path -LiteralPath $temporaryDestination) {
                    Remove-Item -LiteralPath $temporaryDestination -Force -ErrorAction SilentlyContinue
                }
            }
        }

        throw "Failed to download $Label.`n$($failures -join [Environment]::NewLine)"
    }
    else {
        Write-Step "Using cached $Label"
    }
}

function Get-DownloadUriList {
    param(
        [string]$PrimaryUri,
        [string[]]$MirrorUris = @(),
        [string]$ProxyPrefix,
        [string]$FallbackUri
    )

    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in @($PrimaryUri)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not $candidates.Contains($candidate)) {
            $candidates.Add($candidate)
        }
    }

    foreach ($candidate in $MirrorUris) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not $candidates.Contains($candidate)) {
            $candidates.Add($candidate)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ProxyPrefix) -and -not [string]::IsNullOrWhiteSpace($FallbackUri)) {
        $proxyUri = '{0}{1}' -f $ProxyPrefix, $FallbackUri
        if (-not $candidates.Contains($proxyUri)) {
            $candidates.Add($proxyUri)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($FallbackUri) -and -not $candidates.Contains($FallbackUri)) {
        $candidates.Add($FallbackUri)
    }

    return @($candidates)
}

function Join-Uri {
    param(
        [string]$Base,
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($Base) -or [string]::IsNullOrWhiteSpace($RelativePath)) {
        return $null
    }

    return '{0}/{1}' -f $Base.TrimEnd('/'), $RelativePath.TrimStart('/')
}

function Get-ConfiguredMirrorUris {
    param(
        [string[]]$DefaultMirrorUris = @(),
        [string]$MirrorUrls,
        [string]$MirrorBase,
        [string]$RelativePath
    )

    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in (($MirrorUrls -split '[;,\r\n]') | ForEach-Object { $_.Trim() })) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not $candidates.Contains($candidate)) {
            $candidates.Add($candidate)
        }
    }

    $derivedMirrorUri = Join-Uri -Base $MirrorBase -RelativePath $RelativePath
    if (-not [string]::IsNullOrWhiteSpace($derivedMirrorUri) -and -not $candidates.Contains($derivedMirrorUri)) {
        $candidates.Add($derivedMirrorUri)
    }

    foreach ($candidate in $DefaultMirrorUris) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not $candidates.Contains($candidate)) {
            $candidates.Add($candidate)
        }
    }

    return @($candidates)
}

function Get-RustToolkitPaths {
    if ([string]::IsNullOrWhiteSpace($script:RustToolkitScriptRoot) -or [string]::IsNullOrWhiteSpace($script:RustToolkitRoot)) {
        throw "Rust toolkit script paths are not initialized."
    }

    return @{
        ScriptPath = $script:RustToolkitScriptPath
        ScriptRoot = $script:RustToolkitScriptRoot
        ToolkitRoot = $script:RustToolkitRoot
    }
}

function Assert-SetupFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Setup did not produce $Description`: $Path"
    }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -gt 0) {
        return
    }

    # rustup may create zero-length Windows symlink entries for cargo/rustc.
    # The target, rather than the link entry, carries the executable bytes.
    if ($file.LinkType -eq 'SymbolicLink' -and $file.Target) {
        $target = @($file.Target)[0]
        $targetPath = if ([System.IO.Path]::IsPathRooted($target)) {
            $target
        }
        else {
            Join-Path (Split-Path -Parent $Path) $target
        }
        if ((Test-Path -LiteralPath $targetPath -PathType Leaf) -and
            (Get-Item -LiteralPath $targetPath).Length -gt 0) {
            return
        }
    }

    throw "Setup produced an empty $Description`: $Path"
}

function Get-SetupWindowsLinkInputStatus {
    param([Parameter(Mandatory = $true)][string]$ToolkitRoot)

    $sysrootRoot = Join-Path $ToolkitRoot 'tools\sysroot\x86_64-pc-windows-msvc'
    $libraryRoot = Join-Path $sysrootRoot 'lib'
    $requiredLibraries = @(
        'kernel32.lib', 'ntdll.lib', 'userenv.lib', 'ws2_32.lib',
        'dbghelp.lib', 'advapi32.lib', 'user32.lib', 'ole32.lib',
        'oleaut32.lib', 'shell32.lib', 'bcrypt.lib', 'msvcrt.lib',
        'rpc_winshim.lib'
    )
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $requiredLibraries) {
        $path = Join-Path $libraryRoot $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-Item -LiteralPath $path).Length -le 0) {
            $missing.Add($name)
        }
    }

    $provenancePath = Join-Path $sysrootRoot 'PROVENANCE.json'
    if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf) -or
        (Get-Item -LiteralPath $provenancePath).Length -le 0) {
        $missing.Add('PROVENANCE.json')
    }
    else {
        try {
            $provenance = Get-Content -LiteralPath $provenancePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($provenance.triple -ne 'x86_64-pc-windows-msvc' -or
                $provenance.zigVersion -ne '0.13.0' -or
                @($provenance.files).Count -ne $requiredLibraries.Count) {
                $missing.Add('PROVENANCE.json (target, Zig version, or file list)')
            }
        }
        catch {
            $missing.Add('PROVENANCE.json (invalid JSON)')
        }
    }

    return [pscustomobject]@{
        Root = $sysrootRoot
        Missing = $missing.ToArray()
        IsComplete = ($missing.Count -eq 0)
    }
}

function Ensure-SetupWindowsLinkInputs {
    param(
        [Parameter(Mandatory = $true)][string]$ToolkitRoot,
        [Parameter(Mandatory = $true)][string]$ScriptRoot
    )

    $status = Get-SetupWindowsLinkInputStatus -ToolkitRoot $ToolkitRoot
    if ($status.IsComplete) {
        Write-Step "Using existing Windows link inputs at $($status.Root)"
        return
    }

    $generator = Join-Path $ScriptRoot 'build_win_link_inputs.ps1'
    Assert-SetupFile -Path $generator -Description 'Windows link-input generator'
    Write-Step "Repairing Windows link inputs under $($status.Root): $($status.Missing -join ', ')"
    $global:LASTEXITCODE = 0
    & $generator -ToolkitRoot $ToolkitRoot -Force
    if ($LASTEXITCODE -ne 0) {
        throw "Windows link-input generator failed with exit code $LASTEXITCODE`: $generator"
    }

    $status = Get-SetupWindowsLinkInputStatus -ToolkitRoot $ToolkitRoot
    if (-not $status.IsComplete) {
        throw "Windows link inputs remain incomplete under $($status.Root): $($status.Missing -join ', ')"
    }
}

function Invoke-RustToolkitSetup {
    param(
        [switch]$Force
    )

    $resolvedPaths = Get-RustToolkitPaths
    $scriptRoot = $resolvedPaths.ScriptRoot
    $toolkitRoot = $resolvedPaths.ToolkitRoot
    $toolsRoot = Join-Path $toolkitRoot "tools"
    $downloadsRoot = Join-Path $toolsRoot "downloads"
    $rustupBinRoot = Join-Path $toolsRoot "rustup"
    $cargoHome = Join-Path $toolsRoot "cargo-home"
    $rustupHome = Join-Path $toolsRoot "rustup-home"
    $zigRoot = Join-Path $toolsRoot "zig"
    $zigLocalCache = Join-Path $toolsRoot "zig-local-cache"
    $zigGlobalCache = Join-Path $toolsRoot "zig-global-cache"
    $wrappersRoot = Join-Path $toolsRoot "wrappers"
    $cargoBin = Join-Path $cargoHome "bin"
    $rustupExe = Join-Path $downloadsRoot "rustup-init.exe"
    $cargoExe = Join-Path $cargoBin "cargo.exe"
    $rustcExe = Join-Path $cargoBin "rustc.exe"
    $rustupCmd = Join-Path $cargoBin "rustup.exe"
    $zigVersion = "0.13.0"
    $zigExe = Join-Path $zigRoot "zig.exe"
    $zigArchive = Join-Path $downloadsRoot "zig-windows-x86_64-$zigVersion.zip"
    $zigExtractRootBase = Join-Path $downloadsRoot "zig-extract-$zigVersion"
    $rustupRelativePath = "rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe"
    $rustupOfficialUrl = "https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe"
    $zigRelativePath = "download/$zigVersion/zig-windows-x86_64-$zigVersion.zip"
    $zigOfficialUrl = "https://ziglang.org/download/$zigVersion/zig-windows-x86_64-$zigVersion.zip"
    $defaultRustupMirrorUris = @(
        "https://rsproxy.cn/$rustupRelativePath",
        "https://mirror.sjtu.edu.cn/rust-static/$rustupRelativePath"
    )
    $defaultZigMirrorUris = @(
    )

    Write-Host "=== Rust Toolkit Auto Setup Start ==="

    if ($Force) {
        Write-Step "Force mode enabled; refreshing repository-local toolchain state in place"

        $cargoHomeSubdirectories = @("registry", "git", ".global-cache", ".package-cache")
        foreach ($subdirectory in $cargoHomeSubdirectories) {
            $subdirectoryPath = Join-Path $cargoHome $subdirectory
            try {
                Remove-ManagedPath -Path $subdirectoryPath
            }
            catch {
                Write-Warning "Unable to clear $subdirectoryPath. $($_.Exception.Message)"
            }
        }
    }

    foreach ($directory in @($toolsRoot, $downloadsRoot, $rustupBinRoot, $cargoHome, $rustupHome, $zigLocalCache, $zigGlobalCache, $wrappersRoot)) {
        Ensure-Directory -Path $directory
    }

    $legacyHostAbi = "g" + "nu"
    $legacyHostWrapperBase = "x86_64-" + "w64-" + ("min" + "gw32") + "-gcc"
    $legacyHostTriple = "x86_64-pc-windows-$legacyHostAbi"
    foreach ($legacyWrapperFile in @(
        "$legacyHostWrapperBase.cmd",
        "$legacyHostWrapperBase.ps1",
        ("zig-" + "dll" + "tool.cmd"),
        ("zig-" + "dll" + "tool.ps1")
    )) {
        Remove-ManagedPath -Path (Join-Path $wrappersRoot $legacyWrapperFile)
    }
    # Remove toolchains from the previous floating-channel layout before installing the
    # pinned toolchain. This prevents a stale 1.95 payload from being picked up or shipped.
    foreach ($obsoleteToolchain in @(
        "stable-x86_64-pc-windows-msvc",
        "stable-$legacyHostTriple"
    )) {
        Remove-ManagedPath -Path (Join-Path $rustupHome "toolchains\$obsoleteToolchain")
        Remove-ManagedPath -Path (Join-Path $rustupHome "update-hashes\$obsoleteToolchain")
    }

    $env:RUST_PORTABLE_CROSS_ROOT = $toolkitRoot
    $env:CARGO_HOME = $cargoHome
    $env:RUSTUP_HOME = $rustupHome
    $env:ZIG_LOCAL_CACHE_DIR = $zigLocalCache
    $env:ZIG_GLOBAL_CACHE_DIR = $zigGlobalCache
    $env:RUSTUP_DIST_SERVER = if ($env:RUSTUP_DIST_SERVER) { $env:RUSTUP_DIST_SERVER } else { "https://rsproxy.cn" }
    $env:RUSTUP_UPDATE_ROOT = if ($env:RUSTUP_UPDATE_ROOT) { $env:RUSTUP_UPDATE_ROOT } else { "https://rsproxy.cn/rustup" }
    Add-PathEntry -Entry $rustupBinRoot
    Add-PathEntry -Entry $cargoBin
    Add-PathEntry -Entry $zigRoot
    Add-PathEntry -Entry $wrappersRoot

    $downloadProxyPrefix = $env:RUST_PORTABLE_CROSS_DOWNLOAD_PROXY_PREFIX

    $rustupMirrorUris = @(Get-ConfiguredMirrorUris `
        -DefaultMirrorUris $defaultRustupMirrorUris `
        -MirrorUrls $env:RUST_PORTABLE_CROSS_RUSTUP_MIRRORS `
        -MirrorBase $env:RUST_PORTABLE_CROSS_RUSTUP_MIRROR_BASE `
        -RelativePath $rustupRelativePath)

    $zigMirrorUris = @(Get-ConfiguredMirrorUris `
        -DefaultMirrorUris $defaultZigMirrorUris `
        -MirrorUrls $env:RUST_PORTABLE_CROSS_ZIG_MIRRORS `
        -MirrorBase $env:RUST_PORTABLE_CROSS_ZIG_MIRROR_BASE `
        -RelativePath $zigRelativePath)

    $rustupDownloadUris = @(Get-DownloadUriList `
        -PrimaryUri $env:RUST_PORTABLE_CROSS_RUSTUP_INIT_URL `
        -MirrorUris $rustupMirrorUris `
        -ProxyPrefix $downloadProxyPrefix `
        -FallbackUri $rustupOfficialUrl)

    $zigDownloadUris = @(Get-DownloadUriList `
        -PrimaryUri $env:RUST_PORTABLE_CROSS_ZIG_URL `
        -MirrorUris $zigMirrorUris `
        -ProxyPrefix $downloadProxyPrefix `
        -FallbackUri $zigOfficialUrl)

    Write-Step "Rust downloads will try $(($rustupDownloadUris -join ' -> '))"
    Write-Step "RUSTUP_DIST_SERVER=$env:RUSTUP_DIST_SERVER"
    Write-Step "RUSTUP_UPDATE_ROOT=$env:RUSTUP_UPDATE_ROOT"
    Write-Step "Zig downloads will try $(($zigDownloadUris -join ' -> '))"

    Ensure-Download `
        -Uris $rustupDownloadUris `
        -Destination $rustupExe `
        -Label "rustup-init.exe"

    if (-not (Test-Path -LiteralPath $rustupCmd)) {
        Write-Step "Installing rustup into repository-local homes"
        Invoke-Native -FilePath $rustupExe -Arguments @(
            "-y",
            "--profile", "minimal",
            "--no-modify-path",
            "--default-toolchain", "none"
        )
    }
    else {
        Write-Step "Using existing repository-local rustup bootstrap in $cargoBin"
    }

    if (-not (Test-Path -LiteralPath $rustupCmd)) {
        throw "rustup.exe was not installed into $cargoBin"
    }

    Write-Step "Ensuring 1.98.0-x86_64-pc-windows-msvc is installed"
    Install-PinnedRustToolchain `
        -RustupPath $rustupCmd `
        -Toolchain "1.98.0-x86_64-pc-windows-msvc"

    # Pin the active toolchain for all subsequent rustup-proxy calls in this script.
    $env:RUSTUP_TOOLCHAIN = "1.98.0-x86_64-pc-windows-msvc"
    Invoke-Native -FilePath $rustupCmd -Arguments @(
        "default",
        "1.98.0-x86_64-pc-windows-msvc"
    )

    Copy-Item -LiteralPath $rustupCmd -Destination (Join-Path $rustupBinRoot "rustup.exe") -Force

    Write-Step "Installing Linux musl and bare-metal embedded targets"
    Invoke-Native -FilePath $rustupCmd -Arguments @(
        "target",
        "add",
        "armv7-unknown-linux-musleabihf",
        "aarch64-unknown-linux-musl",
        "thumbv7em-none-eabihf"
    )

    Write-Step "Verifying Rust standard-library target payloads"
    $rustcVerbose = @(Get-NativeOutput -FilePath $rustcExe -Arguments @("-vV"))
    Write-Host "Managed rustc details:"
    foreach ($rustcDetail in $rustcVerbose) {
        Write-Host "  $rustcDetail"
    }
    foreach ($payloadDefinition in (Get-RustTargetPayloadDefinitions).Values) {
        $payloadStatus = Get-RustTargetPayloadStatus -RustcPath $rustcExe -TargetTriple $payloadDefinition.Triple
        if (-not $payloadStatus.IsComplete) {
            Write-Step "Repairing incomplete $($payloadDefinition.Triple) payload"
            if ($payloadDefinition.Triple -eq "x86_64-pc-windows-msvc") {
                # Remove first so a stale rustup record cannot short-circuit the repair.
                try {
                    $global:LASTEXITCODE = 0
                    & $rustupCmd component remove --toolchain 1.98.0-x86_64-pc-windows-msvc $payloadDefinition.RustComponent 2>&1 | Out-Host
                }
                catch {
                    Write-Verbose "Unable to remove stale $($payloadDefinition.RustComponent) metadata before repair: $($_.Exception.Message)"
                }
                Invoke-Native -FilePath $rustupCmd -Arguments @(
                    "component",
                    "add",
                    "--toolchain",
                    "1.98.0-x86_64-pc-windows-msvc",
                    $payloadDefinition.RustComponent
                )
            }
            else {
                try {
                    $global:LASTEXITCODE = 0
                    & $rustupCmd target remove --toolchain 1.98.0-x86_64-pc-windows-msvc $payloadDefinition.Triple 2>&1 | Out-Host
                }
                catch {
                    Write-Verbose "Unable to remove stale $($payloadDefinition.Triple) metadata before repair: $($_.Exception.Message)"
                }
                Invoke-Native -FilePath $rustupCmd -Arguments @(
                    "target",
                    "add",
                    "--toolchain",
                    "1.98.0-x86_64-pc-windows-msvc",
                    $payloadDefinition.Triple
                )
            }

            $payloadStatus = Get-RustTargetPayloadStatus -RustcPath $rustcExe -TargetTriple $payloadDefinition.Triple
            if (-not $payloadStatus.IsComplete) {
                throw (Format-RustTargetPayloadFailure -Status $payloadStatus)
            }
        }

        Write-Host ("  - {0}: {1}" -f $payloadDefinition.Triple, $payloadStatus.Libdir)
    }

    $installZig = $true
    if (Test-Path -LiteralPath $zigExe) {
        try {
            $existingZigVersion = (@(Get-NativeOutput -FilePath $zigExe -Arguments @("version")))[0].ToString().Trim()
            if ($existingZigVersion -eq $zigVersion) {
                $installZig = $false
            }
        }
        catch {
            $installZig = $true
        }
    }

    if ($installZig) {
        Write-Step "Installing Zig $zigVersion"
        Ensure-Directory -Path $zigRoot
        $zigExtractRoot = "{0}-{1}" -f $zigExtractRootBase, ([guid]::NewGuid().ToString("N"))
        if (Test-Path -LiteralPath $zigExtractRoot) {
            try {
                Remove-ManagedPath -Path $zigExtractRoot
            }
            catch {
                Write-Warning "Unable to clear temporary Zig extraction path $zigExtractRoot. $($_.Exception.Message)"
            }
        }
        Ensure-Directory -Path $zigExtractRoot

        Ensure-Download `
            -Uris $zigDownloadUris `
            -Destination $zigArchive `
            -Label "Zig $zigVersion" `
            -ValidateFile { param($Path) Test-ZipArchive -Path $Path } `
            -InvalidCacheMessage "Cached Zig archive is corrupt"

        Expand-Archive -LiteralPath $zigArchive -DestinationPath $zigExtractRoot -Force

        $expandedZigRoot = Get-ChildItem -LiteralPath $zigExtractRoot -Directory | Select-Object -First 1
        if (-not $expandedZigRoot) {
            throw "Unable to find extracted Zig directory under $zigExtractRoot"
        }

        Get-ChildItem -LiteralPath $zigRoot -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $existingPath = $_
            try {
                Remove-Item -LiteralPath $existingPath.FullName -Recurse -Force
            }
            catch {
                Write-Warning "Unable to remove existing Zig path $($existingPath.FullName). Reinstall will overwrite remaining files where possible. $($_.Exception.Message)"
            }
        }

        Get-ChildItem -LiteralPath $expandedZigRoot.FullName -Force | ForEach-Object {
            Move-Item -LiteralPath $_.FullName -Destination $zigRoot -Force
        }

        try {
            Remove-ManagedPath -Path $zigExtractRoot
        }
        catch {
            Write-Warning "Unable to remove temporary Zig extraction path $zigExtractRoot. $($_.Exception.Message)"
        }
    }
    else {
        Write-Step "Using existing Zig $zigVersion in $zigRoot"
    }

    Write-Step "Generating Zig cross-compiler wrappers"

    # Every `.cmd` shim runs its `.ps1` under PowerShell 7 (`pwsh`) when one is
    # available and falls back to Windows PowerShell otherwise, so all wrappers
    # behave identically regardless of which shell invoked the build.
    function New-WrapperCmdBody {
        param([Parameter(Mandatory = $true)][string]$BaseName)

        return @(
            "@echo off",
            "setlocal",
            "set `"_PS=`"",
            "for %%I in (pwsh.exe) do set `"_PS=%%~`$PATH:I`"",
            "if not defined _PS if exist `"%ProgramFiles%\PowerShell\7\pwsh.exe`" set `"_PS=%ProgramFiles%\PowerShell\7\pwsh.exe`"",
            "if not defined _PS set `"_PS=powershell`"",
            "`"%_PS%`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$BaseName.ps1`" %*"
        ) -join "`r`n"
    }


    # Linux cross-compilation wrappers: a `.cmd` shim delegates to a `.ps1`
    # helper that strips any caller-supplied `--target=`/`-target` flags
    # (cc-rs injects the 4-component Rust triple, e.g.
    # `--target=aarch64-unknown-linux-musl`, which zig's strict target
    # parser rejects with UnknownOperatingSystem/UnknownArchitecture) and
    # forces the canonical Zig 3-tuple.
    $crossWrapperDefinitions = @(
        @{ BaseName = "arm-linux-musleabihf-gcc"; Target = "arm-linux-musleabihf" },
        @{ BaseName = "aarch64-linux-musl-gcc";   Target = "aarch64-linux-musl"   }
    )

    foreach ($wrapper in $crossWrapperDefinitions) {
        $ps1Path = Join-Path $wrappersRoot ($wrapper.BaseName + ".ps1")
        $ps1Body = @(
            "# Wrapper: forwards args to ``zig cc -target $($wrapper.Target)``.",
            "# cc-rs (and some build.rs scripts) inject ``--target=<rust-triple>`` which zig's",
            "# strict target parser rejects. Drop any caller-supplied -target/--target= flags",
            "# and force the canonical Zig 3-tuple ourselves.",
            "#",
            "# rustc also injects linker flags from the target spec that zig refuses to forward:",
            "# zig 0.13 validates ``-Wl,`` arguments against an allowlist and aborts with",
            "# ``error: unsupported linker arg`` instead of handing them to LLD. The AArch64",
            "# Linux specs prepend ``-Wl,--fix-cortex-a53-843419`` - a link-time workaround for",
            "# an erratum in Cortex-A53 r0p0-r0p4 - which fails every aarch64 link. Strip that",
            "# family of flags; binaries linked here carry the same erratum exposure as any",
            "# other binary zig links for aarch64.",
            "#",
            "# A real link never arrives as plain argv: rustc spills the whole command line",
            "# into an ``@response-file``, so the same filtering has to run over the file's",
            "# contents. rustc writes one argument per line, so dropping or rewriting whole",
            "# lines preserves its escaping; the rewritten copy is left beside the original",
            "# inside rustc's own temp directory and is cleaned up with it.",
            "`$zigTarget = '$($wrapper.Target)'",
            "`$droppedLinkArgPrefixes = @('--fix-cortex-a53-')",
            "",
            "function Test-DroppedLinkArg {",
            "    param([string]`$Value)",
            "    foreach (`$prefix in `$droppedLinkArgPrefixes) {",
            "        if (`$Value.StartsWith(`$prefix)) { return `$true }",
            "    }",
            "    return `$false",
            "}",
            "",
            "# Returns the argument to forward, or `$null when it must be dropped entirely.",
            "function Convert-LinkArg {",
            "    param([string]`$Value)",
            "    if (Test-DroppedLinkArg `$Value) { return `$null }",
            "    if (`$Value.StartsWith('-Wl,')) {",
            "        `$linkArgs = `$Value.Substring(4).Split(',')",
            "        `$keptLinkArgs = @(`$linkArgs | Where-Object { -not (Test-DroppedLinkArg `$_) })",
            "        if (`$keptLinkArgs.Count -ne `$linkArgs.Count) {",
            "            if (`$keptLinkArgs.Count -eq 0) { return `$null }",
            "            return '-Wl,' + (`$keptLinkArgs -join ',')",
            "        }",
            "    }",
            "    return `$Value",
            "}",
            "",
            "function Convert-ResponseFile {",
            "    param([string]`$Path)",
            "    `$responseLines = [System.IO.File]::ReadAllLines(`$Path)",
            "    `$keptLines = New-Object 'System.Collections.Generic.List[string]'",
            "    `$changed = `$false",
            "    foreach (`$line in `$responseLines) {",
            "        `$converted = Convert-LinkArg `$line",
            "        if (`$null -eq `$converted) { `$changed = `$true; continue }",
            "        if (`$converted -ne `$line) { `$changed = `$true }",
            "        `$keptLines.Add(`$converted)",
            "    }",
            "    if (-not `$changed) { return `$null }",
            "    `$rewrittenPath = `$Path + '.zig-cc'",
            "    [System.IO.File]::WriteAllText(`$rewrittenPath, [string]::Join([string][char]10, `$keptLines), (New-Object System.Text.UTF8Encoding(`$false)))",
            "    return `$rewrittenPath",
            "}",
            "",
            "`$filtered = New-Object 'System.Collections.Generic.List[string]'",
            "`$skipNext = `$false",
            "foreach (`$a in `$args) {",
            "    if (`$skipNext) { `$skipNext = `$false; continue }",
            "    `$arg = [string]`$a",
            "    `$normalizedArg = `$arg.Trim('`"')",
            "    if (`$normalizedArg.StartsWith('--target=')) { continue }",
            "    if (`$normalizedArg -eq '-target' -or `$normalizedArg -eq '--target') { `$skipNext = `$true; continue }",
            "    if (`$normalizedArg.StartsWith('@') -and (Test-Path -LiteralPath `$normalizedArg.Substring(1) -PathType Leaf)) {",
            "        `$rewrittenResponse = Convert-ResponseFile -Path `$normalizedArg.Substring(1)",
            "        if (`$null -ne `$rewrittenResponse) { `$filtered.Add('@' + `$rewrittenResponse); continue }",
            "        `$filtered.Add(`$arg)",
            "        continue",
            "    }",
            "    `$converted = Convert-LinkArg `$normalizedArg",
            "    if (`$null -eq `$converted) { continue }",
            "    if (`$converted -ne `$normalizedArg) { `$filtered.Add(`$converted) } else { `$filtered.Add(`$arg) }",
            "}",
            "",
            "& `"`$PSScriptRoot\..\zig\zig.exe`" cc -target `$zigTarget @filtered",
            "exit `$LASTEXITCODE"
        ) -join "`r`n"
        Set-Content -LiteralPath $ps1Path -Value $ps1Body -Encoding ASCII

        $cmdPath = Join-Path $wrappersRoot ($wrapper.BaseName + ".cmd")
        $cmdBody = New-WrapperCmdBody -BaseName $wrapper.BaseName
        Set-Content -LiteralPath $cmdPath -Value $cmdBody -Encoding ASCII
    }

    # Generic archive wrappers used by cc-rs for crates that require C/ASM build steps.
    $zigArPs1Path = Join-Path $wrappersRoot "zig-ar.ps1"
    $zigArPs1Body = @(
        "# Wrapper: forwards args to ``zig ar`` to provide a repository-local archive tool.",
        "& `"`$PSScriptRoot\..\zig\zig.exe`" ar @args",
        "exit `$LASTEXITCODE"
    ) -join "`r`n"
    Set-Content -LiteralPath $zigArPs1Path -Value $zigArPs1Body -Encoding ASCII

    $zigArCmdPath = Join-Path $wrappersRoot "zig-ar.cmd"
    $zigArCmdBody = New-WrapperCmdBody -BaseName "zig-ar"
    Set-Content -LiteralPath $zigArCmdPath -Value $zigArCmdBody -Encoding ASCII

    $zigRanlibPs1Path = Join-Path $wrappersRoot "zig-ranlib.ps1"
    $zigRanlibPs1Body = @(
        "# Wrapper: forwards args to ``zig ranlib`` for static archive index updates.",
        "& `"`$PSScriptRoot\..\zig\zig.exe`" ranlib @args",
        "exit `$LASTEXITCODE"
    ) -join "`r`n"
    Set-Content -LiteralPath $zigRanlibPs1Path -Value $zigRanlibPs1Body -Encoding ASCII

    $zigRanlibCmdPath = Join-Path $wrappersRoot "zig-ranlib.cmd"
    $zigRanlibCmdBody = New-WrapperCmdBody -BaseName "zig-ranlib"
    Set-Content -LiteralPath $zigRanlibCmdPath -Value $zigRanlibCmdBody -Encoding ASCII

    $zigLibPs1Path = Join-Path $wrappersRoot "zig-lib.ps1"
    $zigLibPs1Body = @(
        "# Wrapper: forwards args to ``zig lib`` (lld-lib) for MSVC-compatible static archive creation.",
        "#",
        "# cc-rs (for x86_64-pc-windows-msvc) calls the archiver as:",
        "#   zig-lib.cmd -out:DESTPATH [-nologo] [DESTPATH] OBJ1 OBJ2 ...",
        "#",
        "# PowerShell's -File invocation mode treats '-param:value' as named-parameter binding",
        "# and splits '-out:D:\path\file.a' into two separate `$args entries:",
        "#   `$args[0] = '-out'          (parameter name, colon stripped)",
        "#   `$args[1] = 'D:\path\file.a' (parameter value as next element)",
        "#",
        "# We detect this split and reassemble before forwarding to zig lib.",
        "# zig lib (lld-lib) accepts both '-out:X' and '/out:X' prefixes.",
        "",
        "`$zigExe = `"`$PSScriptRoot\..\zig\zig.exe`"",
        "`$translated = [System.Collections.Generic.List[string]]::new()",
        "",
        "`$i = 0",
        "while (`$i -lt `$args.Count) {",
        "    `$a = [string]`$args[`$i]",
        "",
        "    # Detect the PowerShell-split form: '-out' followed by a path as the next arg.",
        "    # A path value will not start with '-' or '/'.",
        "    if (`$a -ceq '-out' -and (`$i + 1) -lt `$args.Count -and ([string]`$args[`$i + 1]) -notmatch '^[-/]') {",
        "        `$translated.Add('/out:' + [string]`$args[`$i + 1])",
        "        `$i += 2",
        "        continue",
        "    }",
        "",
        "    # Translate remaining '-X...' flags to '/X...' (MSVC lld-lib style).",
        "    # Also handles the non-split form '-out:X' passed directly (e.g. unit tests).",
        "    if (`$a -match '^-([A-Za-z])') {",
        "        `$translated.Add('/' + `$a.Substring(1))",
        "    } else {",
        "        `$translated.Add(`$a)",
        "    }",
        "    `$i++",
        "}",
        "",
        "& `$zigExe lib @translated",
        "exit `$LASTEXITCODE"
    ) -join "`r`n"
    Set-Content -LiteralPath $zigLibPs1Path -Value $zigLibPs1Body -Encoding ASCII

    $zigLibCmdPath = Join-Path $wrappersRoot "zig-lib.cmd"
    $zigLibCmdBody = New-WrapperCmdBody -BaseName "zig-lib"
    Set-Content -LiteralPath $zigLibCmdPath -Value $zigLibCmdBody -Encoding ASCII

    $rustMsvcBin = Join-Path $rustupHome 'toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\x86_64-pc-windows-msvc\bin'
    foreach ($file in @(
        $cargoExe, $rustcExe, $rustupCmd, (Join-Path $rustupBinRoot 'rustup.exe'),
        $zigExe, (Join-Path $rustMsvcBin 'rust-lld.exe'),
        (Join-Path $rustMsvcBin 'rust-objcopy.exe')
    )) {
        Assert-SetupFile -Path $file -Description 'managed tool'
    }
    foreach ($baseName in @(
        'arm-linux-musleabihf-gcc', 'aarch64-linux-musl-gcc',
        'zig-ar', 'zig-ranlib', 'zig-lib'
    )) {
        foreach ($extension in @('.cmd', '.ps1')) {
            Assert-SetupFile -Path (Join-Path $wrappersRoot ($baseName + $extension)) -Description 'wrapper'
        }
    }
    foreach ($payloadDefinition in (Get-RustTargetPayloadDefinitions).Values) {
        $payloadStatus = Get-RustTargetPayloadStatus -RustcPath $rustcExe -TargetTriple $payloadDefinition.Triple
        if (-not $payloadStatus.IsComplete) {
            throw (Format-RustTargetPayloadFailure -Status $payloadStatus)
        }
    }

    Ensure-SetupWindowsLinkInputs -ToolkitRoot $toolkitRoot -ScriptRoot $scriptRoot

    Write-Step "Running self-checks"
    $cargoVersion = (@(Get-NativeOutput -FilePath $cargoExe -Arguments @("-V")))[0].ToString().Trim()
    $rustcVersion = (@(Get-NativeOutput -FilePath $rustcExe -Arguments @("-V")))[0].ToString().Trim()

    if ($rustcVersion -notmatch "^rustc 1\.98\.0(?:\s|$)") {
        throw "Expected pinned Rust 1.98.0, but managed rustc reported: $rustcVersion"
    }

    # `rustup target list --installed` only shows additional (cross) targets; the host triple is
    # always available but never appears in that list.  Check cross targets separately.
    $installedTargets = @(Get-NativeOutput -FilePath $rustupCmd -Arguments @("target", "list", "--installed"))

    foreach ($requiredTarget in @(
        "armv7-unknown-linux-musleabihf",
        "aarch64-unknown-linux-musl",
        "thumbv7em-none-eabihf"
    )) {
        if ($installedTargets -notcontains $requiredTarget) {
            throw "Missing required installed target: $requiredTarget"
        }
    }

    # Verify the active toolchain is the MSVC host toolchain.
    $rustcHostLine = & $rustcExe -vV 2>&1 | Where-Object { $_ -match "^host:" }
    if ($rustcHostLine -notmatch "x86_64-pc-windows-msvc") {
        throw "Expected host toolchain x86_64-pc-windows-msvc but rustc reports: $rustcHostLine"
    }

    Write-Host ""
    Write-Host "Portable Rust toolkit setup complete."
    Write-Host "Toolkit root : $toolkitRoot"
    Write-Host "RUST_PORTABLE_CROSS_ROOT : $env:RUST_PORTABLE_CROSS_ROOT"
    Write-Host "rustup bin   : $rustupBinRoot"
    Write-Host "CARGO_HOME   : $cargoHome"
    Write-Host "RUSTUP_HOME  : $rustupHome"
    Write-Host "Zig root     : $zigRoot"
    Write-Host "Zig local    : $zigLocalCache"
    Write-Host "Zig global   : $zigGlobalCache"
    Write-Host "Wrappers     : $wrappersRoot"
    Write-Host "cargo        : $cargoVersion"
    Write-Host "rustc        : $rustcVersion"
    Write-Host "rustc details:"
    foreach ($rustcDetail in $rustcVerbose) {
        Write-Host "  $rustcDetail"
    }
    Write-Host "installed targets:"
    foreach ($installedTarget in $installedTargets) {
        Write-Host "  - $installedTarget"
    }
}

if ($env:RUST_PORTABLE_CROSS_SKIP_MAIN -ne "1") {
    Invoke-RustToolkitSetup -Force:$Force
}
