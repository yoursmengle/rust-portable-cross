[CmdletBinding()]
param(
    [string]$InstallRoot,

    [string]$SelectedComponents = "",

    [ValidateSet("perUser", "perMachine")]
    [string]$InstallScope = "perUser",

    [switch]$Validate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:HostToolchain = "stable-x86_64-pc-windows-gnu"
$script:HostTriple = "x86_64-pc-windows-gnu"

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Assert-PathExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Message`nMissing path: $Path"
    }
}

function Invoke-NativeCapture {
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

function Get-SelectedComponentList {
    param(
        [string]$SelectedComponents
    )

    $selected = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in ($SelectedComponents -split "[,;]")) {
        $trimmed = $name.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            [void]$selected.Add($trimmed)
        }
    }

    return @($selected | Sort-Object)
}

function Get-InstallLayout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    $layoutPath = Join-Path $InstallRoot "install-layout.json"
    Assert-PathExists -Path $layoutPath -Message "Offline install layout metadata is missing."

    return Get-Content -LiteralPath $layoutPath -Raw | ConvertFrom-Json -Depth 6
}

function Set-RustupSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    $settingsPath = Join-Path $InstallRoot "tools\rustup-home\settings.toml"
    $content = @(
        'version = "12"',
        'default_toolchain = "stable-x86_64-pc-windows-gnu"',
        'profile = "minimal"',
        '',
        '[overrides]'
    ) -join "`r`n"

    Ensure-Directory -Path (Split-Path -Parent $settingsPath)
    Set-Content -LiteralPath $settingsPath -Value $content -Encoding ASCII
}

function Set-ToolchainComponentsFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [object]$Layout,

        [string[]]$SelectedComponents
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $Layout.hostRustComponents) {
        $lines.Add([string]$line)
    }

    foreach ($componentName in $SelectedComponents) {
        $targetMetadata = $Layout.targets.$componentName
        if ($null -ne $targetMetadata -and -not [string]::IsNullOrWhiteSpace([string]$targetMetadata.rustComponent)) {
            $lines.Add([string]$targetMetadata.rustComponent)
        }
    }

    $componentsPath = Join-Path $InstallRoot "tools\rustup-home\toolchains\$script:HostToolchain\lib\rustlib\components"
    Ensure-Directory -Path (Split-Path -Parent $componentsPath)
    Set-Content -LiteralPath $componentsPath -Value ($lines -join "`r`n") -Encoding ASCII
}

function Remove-EmptyParentDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StopDirectory
    )

    $current = $StartDirectory
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if ($current.TrimEnd('\') -eq $StopDirectory.TrimEnd('\')) {
            break
        }

        if (-not (Test-Path -LiteralPath $current)) {
            $current = Split-Path -Parent $current
            continue
        }

        if ((Get-ChildItem -LiteralPath $current -Force | Measure-Object).Count -gt 0) {
            break
        }

        Remove-Item -LiteralPath $current -Force
        $current = Split-Path -Parent $current
    }
}

function Remove-UnselectedComponentFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [object]$Layout,

        [string[]]$SelectedComponents
    )

    foreach ($componentProperty in $Layout.componentFiles.PSObject.Properties) {
        $componentName = [string]$componentProperty.Name
        if ($componentName -eq "core") {
            continue
        }

        if ($SelectedComponents -contains $componentName) {
            continue
        }

        foreach ($relativePath in $componentProperty.Value) {
            $targetPath = Join-Path $InstallRoot ($relativePath -replace "/", "\")
            if (Test-Path -LiteralPath $targetPath) {
                Remove-Item -LiteralPath $targetPath -Force
                Remove-EmptyParentDirectories -StartDirectory (Split-Path -Parent $targetPath) -StopDirectory $InstallRoot
            }
        }
    }
}

function New-InstallManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [object]$Layout,

        [string[]]$SelectedComponents,

        [Parameter(Mandatory = $true)]
        [string]$InstallScope
    )

    $manifest = [ordered]@{
        productName = $Layout.productName
        productVersion = $Layout.productVersion
        generatedAt = (Get-Date).ToString("o")
        installScope = $InstallScope
        hostToolchain = $Layout.hostToolchain
        hostTriple = $Layout.hostTriple
        installedComponents = @("core") + @($SelectedComponents)
        componentFiles = $Layout.componentFiles
    }

    $manifestPath = Join-Path $InstallRoot "install-manifest.json"
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding ASCII
}

function Ensure-LocalCacheDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    foreach ($relativePath in @(
        "tools\cargo-home\registry",
        "tools\cargo-home\git",
        "tools\zig-local-cache",
        "tools\zig-global-cache"
    )) {
        Ensure-Directory -Path (Join-Path $InstallRoot $relativePath)
    }
}

function Test-OfflineInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [object]$Layout,

        [string[]]$SelectedComponents
    )

    $cargoExe = Join-Path $InstallRoot "tools\cargo-home\bin\cargo.exe"
    $rustcExe = Join-Path $InstallRoot "tools\cargo-home\bin\rustc.exe"
    $rustupExe = Join-Path $InstallRoot "tools\cargo-home\bin\rustup.exe"
    $zigExe = Join-Path $InstallRoot "tools\zig\zig.exe"

    Assert-PathExists -Path $cargoExe -Message "cargo.exe is required for the offline toolkit."
    Assert-PathExists -Path $rustcExe -Message "rustc.exe is required for the offline toolkit."
    Assert-PathExists -Path $rustupExe -Message "rustup.exe is required for the offline toolkit."
    Assert-PathExists -Path $zigExe -Message "zig.exe is required for the offline toolkit."

    foreach ($componentName in $SelectedComponents) {
        foreach ($relativePath in $Layout.componentFiles.$componentName) {
            $targetPath = Join-Path $InstallRoot ($relativePath -replace "/", "\")
            Assert-PathExists -Path $targetPath -Message "A selected component payload is missing."
        }
    }

    $env:RUSTUP_HOME = Join-Path $InstallRoot "tools\rustup-home"
    $env:CARGO_HOME = Join-Path $InstallRoot "tools\cargo-home"
    $env:RUSTUP_TOOLCHAIN = $script:HostToolchain

    $cargoVersion = [string]::Join([Environment]::NewLine, (Invoke-NativeCapture -FilePath $cargoExe -Arguments @("-V"))).Trim()
    $rustcVersion = [string]::Join([Environment]::NewLine, (Invoke-NativeCapture -FilePath $rustcExe -Arguments @("-V"))).Trim()
    $rustcVerbose = Invoke-NativeCapture -FilePath $rustcExe -Arguments @("-vV")
    $installedTargets = @(Invoke-NativeCapture -FilePath $rustupExe -Arguments @("target", "list", "--installed"))

    if ($cargoVersion -notmatch "^cargo ") {
        throw "cargo -V returned unexpected output: $cargoVersion"
    }

    if ($rustcVersion -notmatch "^rustc ") {
        throw "rustc -V returned unexpected output: $rustcVersion"
    }

    if (($rustcVerbose | Where-Object { $_ -match "^host: " }) -notcontains "host: $script:HostTriple") {
        throw "rustc host triple does not match the expected GNU host."
    }

    foreach ($targetName in @("armv7", "aarch64")) {
        $triple = [string]$Layout.targets.$targetName.triple
        $shouldExist = $SelectedComponents -contains $targetName
        $isInstalled = $installedTargets -contains $triple
        if ($shouldExist -and -not $isInstalled) {
            throw "Expected installed target not reported by rustup: $triple"
        }
    }
}

function Invoke-FinalizeOfflineInstall {
    param(
        [string]$InstallRoot,
        [string]$SelectedComponents,
        [string]$InstallScope,
        [switch]$Validate
    )

    $resolvedInstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
    $layout = Get-InstallLayout -InstallRoot $resolvedInstallRoot
    $selectedComponentList = Get-SelectedComponentList -SelectedComponents $SelectedComponents

    Ensure-LocalCacheDirectories -InstallRoot $resolvedInstallRoot
    Remove-UnselectedComponentFiles -InstallRoot $resolvedInstallRoot -Layout $layout -SelectedComponents $selectedComponentList
    Set-RustupSettings -InstallRoot $resolvedInstallRoot
    Set-ToolchainComponentsFile -InstallRoot $resolvedInstallRoot -Layout $layout -SelectedComponents $selectedComponentList
    New-InstallManifest -InstallRoot $resolvedInstallRoot -Layout $layout -SelectedComponents $selectedComponentList -InstallScope $InstallScope

    if ($Validate) {
        Test-OfflineInstall -InstallRoot $resolvedInstallRoot -Layout $layout -SelectedComponents $selectedComponentList
    }
}

if ($env:RUST_PORTABLE_CROSS_SKIP_FINALIZE_INSTALL_MAIN -ne "1") {
    Invoke-FinalizeOfflineInstall -InstallRoot $InstallRoot -SelectedComponents $SelectedComponents -InstallScope $InstallScope -Validate:$Validate
}
