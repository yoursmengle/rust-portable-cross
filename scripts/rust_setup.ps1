[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:RustToolkitScriptPath = $PSCommandPath
$script:RustToolkitScriptRoot = $PSScriptRoot
$script:RustToolkitRoot = if ($script:RustToolkitScriptRoot) { Split-Path -Parent $script:RustToolkitScriptRoot } else { $null }

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
        Write-Step "Installing stable-x86_64-pc-windows-gnu into repository-local homes"
        Invoke-Native -FilePath $rustupExe -Arguments @(
            "-y",
            "--profile", "minimal",
            "--no-modify-path",
            "--default-toolchain", "stable-x86_64-pc-windows-gnu"
        )
    }
    else {
        Write-Step "Using existing repository-local rustup bootstrap in $cargoBin"
    }

    if (-not (Test-Path -LiteralPath $rustupCmd)) {
        throw "rustup.exe was not installed into $cargoBin"
    }

    Write-Step "Ensuring stable-x86_64-pc-windows-gnu is installed"
    Invoke-Native -FilePath $rustupCmd -Arguments @(
        "toolchain",
        "install",
        "stable-x86_64-pc-windows-gnu"
    )

    # Pin the active toolchain for all subsequent rustup-proxy calls in this script.
    $env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-gnu"

    Copy-Item -LiteralPath $rustupCmd -Destination (Join-Path $rustupBinRoot "rustup.exe") -Force

    Write-Step "Installing Linux musl targets"
    Invoke-Native -FilePath $rustupCmd -Arguments @(
        "target",
        "add",
        "armv7-unknown-linux-musleabihf",
        "aarch64-unknown-linux-musl"
    )

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

    # Linux cross-compilation wrappers: simple pass-through to zig cc.
    $crossWrapperDefinitions = @(
        @{ Name = "arm-linux-musleabihf-gcc.cmd"; Target = "arm-linux-musleabihf" },
        @{ Name = "aarch64-linux-musl-gcc.cmd";   Target = "aarch64-linux-musl"   }
    )

    foreach ($wrapper in $crossWrapperDefinitions) {
        $wrapperPath = Join-Path $wrappersRoot $wrapper.Name
        $wrapperBody = @(
            "@echo off",
            "`"%~dp0..\zig\zig.exe`" cc -target $($wrapper.Target) %*"
        ) -join "`r`n"
        Set-Content -LiteralPath $wrapperPath -Value $wrapperBody -Encoding ASCII
    }

    # Windows GNU host wrapper: delegates to a PowerShell helper that filters
    # linker flags unsupported by zig's LLD (e.g. --disable-auto-image-base).
    $winPs1Path = Join-Path $wrappersRoot "x86_64-w64-mingw32-gcc.ps1"
    $winPs1Body = @(
        "# Wrapper: forwards args to zig cc (x86_64-windows-gnu), filtering flags",
        "# that rustc injects for x86_64-pc-windows-gnu but zig's LLD does not support.",
        "`$unsupported = @(",
        "    '-Wl,--disable-auto-image-base'",
        ")",
        "",
        "`$filteredArgs = `$args | Where-Object { `$_ -notin `$unsupported }",
        "",
        "& `"`$PSScriptRoot\..\zig\zig.exe`" cc -target x86_64-windows-gnu @filteredArgs",
        "exit `$LASTEXITCODE"
    ) -join "`r`n"
    Set-Content -LiteralPath $winPs1Path -Value $winPs1Body -Encoding ASCII

    $winCmdPath = Join-Path $wrappersRoot "x86_64-w64-mingw32-gcc.cmd"
    $winCmdBody = @(
        "@echo off",
        "powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0x86_64-w64-mingw32-gcc.ps1`" %*"
    ) -join "`r`n"
    Set-Content -LiteralPath $winCmdPath -Value $winCmdBody -Encoding ASCII

    Write-Step "Running self-checks"
    $cargoVersion = (@(Get-NativeOutput -FilePath $cargoExe -Arguments @("-V")))[0].ToString().Trim()
    $rustcVersion = (@(Get-NativeOutput -FilePath $rustcExe -Arguments @("-V")))[0].ToString().Trim()

    # `rustup target list --installed` only shows additional (cross) targets; the host triple is
    # always available but never appears in that list.  Check cross targets separately.
    $installedTargets = @(Get-NativeOutput -FilePath $rustupCmd -Arguments @("target", "list", "--installed"))

    foreach ($requiredTarget in @(
        "armv7-unknown-linux-musleabihf",
        "aarch64-unknown-linux-musl"
    )) {
        if ($installedTargets -notcontains $requiredTarget) {
            throw "Missing required installed target: $requiredTarget"
        }
    }

    # Verify the active toolchain is the GNU host toolchain (no MSVC link.exe dependency).
    $rustcHostLine = & $rustcExe -vV 2>&1 | Where-Object { $_ -match "^host:" }
    if ($rustcHostLine -notmatch "x86_64-pc-windows-gnu") {
        throw "Expected host toolchain x86_64-pc-windows-gnu but rustc reports: $rustcHostLine"
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
    Write-Host "installed targets:"
    foreach ($installedTarget in $installedTargets) {
        Write-Host "  - $installedTarget"
    }
}

if ($env:RUST_PORTABLE_CROSS_SKIP_MAIN -ne "1") {
    Invoke-RustToolkitSetup -Force:$Force
}
