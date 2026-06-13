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

$script:HostToolchain = "stable-x86_64-pc-windows-msvc"
$script:HostTriple = "x86_64-pc-windows-msvc"

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

function Stop-ProcessTree {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    # The rustup/cargo proxies spawn real toolchain child processes; kill the
    # whole tree so a stuck validation can never keep the installer alive.
    try {
        $taskkill = Join-Path $env:WINDIR "System32\taskkill.exe"
        if (Test-Path -LiteralPath $taskkill) {
            Start-Process -FilePath $taskkill -ArgumentList @("/F", "/T", "/PID", $Process.Id) `
                -NoNewWindow -Wait -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch {
    }

    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
        }
    }
    catch {
    }
}

function Start-FinalizeWatchdog {
    param(
        [int]$TimeoutSeconds = 150
    )

    # Absolute backstop against a frozen wizard. Inno Setup launches this script
    # with waituntilterminated, so if validation (or anything else) ever wedges,
    # the installer hangs forever. A separate, detached PowerShell process force
    # terminates this finalize process tree once the deadline passes. All toolkit
    # files are deployed and configured *before* validation runs, so a hard kill
    # still leaves a fully working installation behind.
    try {
        $selfPid = $PID
        $taskkill = Join-Path $env:WINDIR "System32\taskkill.exe"
        $psExe = Join-Path $PSHOME "powershell.exe"
        if (-not (Test-Path -LiteralPath $psExe)) {
            $psExe = "powershell.exe"
        }

        $command = "Start-Sleep -Seconds $TimeoutSeconds; & '$taskkill' /F /T /PID $selfPid"
        return Start-Process -FilePath $psExe `
            -ArgumentList @("-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", $command) `
            -WindowStyle Hidden -PassThru
    }
    catch {
        return $null
    }
}

function Stop-FinalizeWatchdog {
    param(
        $Watchdog
    )

    if ($null -eq $Watchdog) {
        return
    }

    try {
        if (-not $Watchdog.HasExited) {
            Stop-Process -Id $Watchdog.Id -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }
}

function Invoke-NativeWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [int]$TimeoutSeconds = 30
    )

    # Validation must never block the installer UI. Run the tool out-of-band,
    # capture its output, and enforce a hard timeout (works on Windows
    # PowerShell 5.1, which the installer uses, and on PowerShell 7+).
    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-ProcessTree -Process $process
            throw "Command timed out after ${TimeoutSeconds}s: $FilePath $($Arguments -join ' ')"
        }

        # The direct process has exited and its output was redirected to files
        # by the OS, so the files are already complete. Use a *bounded* flush
        # wait only, never the parameterless WaitForExit(): a lingering toolchain
        # grandchild that inherited the file handles must not be able to block us.
        [void]$process.WaitForExit(5000)

        $stdout = @()
        $stderr = @()
        if (Test-Path -LiteralPath $stdoutFile) { $stdout = @(Get-Content -LiteralPath $stdoutFile) }
        if (Test-Path -LiteralPath $stderrFile) { $stderr = @(Get-Content -LiteralPath $stderrFile) }

        if ($process.ExitCode -ne 0) {
            $detail = (@($stdout) + @($stderr)) -join [Environment]::NewLine
            throw "Command failed ($($process.ExitCode)): $FilePath $($Arguments -join ' ')`n$detail"
        }

        return @($stdout)
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
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

    return Get-Content -LiteralPath $layoutPath -Raw | ConvertFrom-Json
}

function Set-RustupSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    $settingsPath = Join-Path $InstallRoot "tools\rustup-home\settings.toml"
    $content = @(
        'version = "12"',
        'default_toolchain = "stable-x86_64-pc-windows-msvc"',
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

function Repair-InstalledCargoHostConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    $isolationScript = Join-Path $PSScriptRoot "rust_build_isolation.ps1"
    if (-not (Test-Path -LiteralPath $isolationScript -PathType Leaf)) {
        throw "Missing build isolation helper: $isolationScript"
    }

    . $isolationScript
    # Only repair the freshly deployed toolkit. Never read the user's ambient
    # CARGO_HOME config: it may be a large or locked file that would hang the
    # installer (the toolkit's own cargo-home config is covered by ToolkitRoot).
    Repair-CargoHostTargetConfig -ToolkitRoot $InstallRoot -ProjectRoot "" -SkipAmbientCargoHome
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
    # Never let a rustup/cargo proxy reach out to the network during validation:
    # an offline auto-install attempt is exactly what used to hang the installer.
    $env:RUSTUP_AUTO_INSTALL = "0"
    $env:CARGO_NET_OFFLINE = "true"

    $cargoVersion = [string]::Join([Environment]::NewLine, (Invoke-NativeWithTimeout -FilePath $cargoExe -Arguments @("-V") -TimeoutSeconds 60)).Trim()
    $rustcVersion = [string]::Join([Environment]::NewLine, (Invoke-NativeWithTimeout -FilePath $rustcExe -Arguments @("-V") -TimeoutSeconds 60)).Trim()
    $rustcVerbose = Invoke-NativeWithTimeout -FilePath $rustcExe -Arguments @("-vV") -TimeoutSeconds 60
    $installedTargets = @(Invoke-NativeWithTimeout -FilePath $rustupExe -Arguments @("target", "list", "--installed") -TimeoutSeconds 60)

    if ($cargoVersion -notmatch "^cargo ") {
        throw "cargo -V returned unexpected output: $cargoVersion"
    }

    if ($rustcVersion -notmatch "^rustc ") {
        throw "rustc -V returned unexpected output: $rustcVersion"
    }

    if (($rustcVerbose | Where-Object { $_ -match "^host: " }) -notcontains "host: $script:HostTriple") {
        throw "rustc host triple does not match the expected MSVC host."
    }

    foreach ($targetName in @("armv7", "aarch64", "thumbv7em")) {
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
    Repair-InstalledCargoHostConfig -InstallRoot $resolvedInstallRoot
    Remove-UnselectedComponentFiles -InstallRoot $resolvedInstallRoot -Layout $layout -SelectedComponents $selectedComponentList
    Set-RustupSettings -InstallRoot $resolvedInstallRoot
    Set-ToolchainComponentsFile -InstallRoot $resolvedInstallRoot -Layout $layout -SelectedComponents $selectedComponentList
    New-InstallManifest -InstallRoot $resolvedInstallRoot -Layout $layout -SelectedComponents $selectedComponentList -InstallScope $InstallScope

    if ($Validate) {
        # The toolkit files are already deployed and configured at this point.
        # Validation is a best-effort health check: it is bounded by per-command
        # timeouts and, even if it fails, must never abort or hang the installer.
        try {
            Test-OfflineInstall -InstallRoot $resolvedInstallRoot -Layout $layout -SelectedComponents $selectedComponentList
        }
        catch {
            $warningPath = Join-Path $resolvedInstallRoot "install-validation-warning.txt"
            $warningText = @(
                "Offline install validation did not complete cleanly.",
                "Generated at: $((Get-Date).ToString('o'))",
                "Detail: $($_.Exception.Message)"
            ) -join [Environment]::NewLine
            try {
                Set-Content -LiteralPath $warningPath -Value $warningText -Encoding UTF8
            }
            catch {
            }
            Write-Warning $warningText
        }
    }
}

if ($env:RUST_PORTABLE_CROSS_SKIP_FINALIZE_INSTALL_MAIN -ne "1") {
    # Only the validating installer run can block on toolchain processes; the
    # config-only path is pure file IO and needs no watchdog.
    $watchdog = $null
    if ($Validate) {
        $watchdog = Start-FinalizeWatchdog -TimeoutSeconds 150
    }

    $exitCode = 0
    try {
        Invoke-FinalizeOfflineInstall -InstallRoot $InstallRoot -SelectedComponents $SelectedComponents -InstallScope $InstallScope -Validate:$Validate
    }
    catch {
        # Surface the error for logging, but always terminate so the installer's
        # synchronous wait can return instead of freezing the wizard window.
        Write-Error $_.Exception.Message
        $exitCode = 1
    }
    finally {
        # Cancel the backstop on normal completion so it does not linger and
        # later kill an unrelated, PID-recycled process.
        Stop-FinalizeWatchdog -Watchdog $watchdog
    }

    exit $exitCode
}
