Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'rust_payload_integrity.ps1')
. (Join-Path $PSScriptRoot 'rust_target_payload.ps1')
. (Join-Path $PSScriptRoot 'rust_transaction.ps1')

function Get-ReleaseLayout {
    param([string]$StagingRoot, [string]$Version)
    $staging = Assert-ManagedRootIsOrdinary -Path $StagingRoot
    $layoutPath = Join-Path $staging 'core\install-layout.json'
    if (-not (Test-Path -LiteralPath $layoutPath -PathType Leaf)) { throw "Missing staged install layout: $layoutPath" }
    $layout = Get-Content -LiteralPath $layoutPath -Raw | ConvertFrom-Json
    if ($layout.productVersion -ne $Version -or $layout.hostToolchain -ne '1.98.0-x86_64-pc-windows-msvc' -or
        $layout.hostTriple -ne 'x86_64-pc-windows-msvc') {
        throw "Staging version or host toolchain mismatch: expected $Version, found $($layout.productVersion)"
    }
    foreach ($name in @('core', 'armv7', 'aarch64', 'thumbv7em')) {
        if ($null -eq $layout.componentFiles.$name) { throw "Staging lacks component $name" }
    }
    $expectedTriples = @{
        armv7 = 'armv7-unknown-linux-musleabihf'
        aarch64 = 'aarch64-unknown-linux-musl'
        thumbv7em = 'thumbv7em-none-eabihf'
    }
    foreach ($name in $expectedTriples.Keys) {
        if ($layout.targets.$name.triple -ne $expectedTriples[$name]) { throw "Staging target mismatch: $name" }
    }
    return $layout
}

function Assert-StagedRelease {
    param([Parameter(Mandatory = $true)][string]$StagingRoot, [Parameter(Mandatory = $true)][string]$Version)

    $staging = Assert-ManagedRootIsOrdinary -Path $StagingRoot
    $layout = Get-ReleaseLayout -StagingRoot $staging -Version $Version
    $null = Test-PayloadIntegrityIndex -StagingRoot $staging -Layout $layout -RequireIndex
    $core = Join-Path $staging 'core'
    Assert-WindowsLinkInputProvenance -ToolkitRoot $core
    $lock = Get-PayloadDependencyLock -ToolkitRoot $core
    foreach ($item in @(
        @{ Path = 'tools\cargo-home\bin\rustup.exe'; Hash = $lock.rustupBootstrap.sha256 },
        @{ Path = 'tools\zig\zig.exe'; Hash = $lock.zigArchive.executableSha256 }
    )) {
        $path = Join-Path $core $item.Path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            -not [string]::Equals((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash, [string]$item.Hash,
                [StringComparison]::OrdinalIgnoreCase)) { throw "Pinned staged tool mismatch: $path" }
    }
    foreach ($relative in @(
        'tools\rustup-home\toolchains\1.98.0-x86_64-pc-windows-msvc\lib\rustlib\x86_64-pc-windows-msvc\bin\rust-objcopy.exe',
        'test\fixtures\release_smoke\macro\src\lib.rs',
        'test\fixtures\win_selfcontained\build.rs'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $core $relative) -PathType Leaf)) { throw "Missing staged release input: $relative" }
    }

    # Inno's recursive [Files] entries include every file, not only entries in
    # install-layout.json. Reject extras before they can bypass the U05 index.
    foreach ($component in $layout.componentFiles.PSObject.Properties) {
        $root = Get-PayloadComponentRoot -StagingRoot $staging -Component $component.Name
        $declared = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($relative in @($component.Value)) { [void]$declared.Add(([string]$relative).Replace('\', '/')) }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force)) {
            $relative = $file.FullName.Substring($root.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
            if ($component.Name -eq 'core' -and $relative -eq 'payload-integrity.json') { continue }
            if (-not $declared.Contains($relative)) { throw "Unindexed staged file: $($component.Name)/$relative" }
        }
    }
    return $layout
}

function Copy-ReleaseComponent {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Missing release component: $Source" }
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    foreach ($file in @(Get-ChildItem -LiteralPath $Source -File -Recurse -Force)) {
        $relative = $file.FullName.Substring($Source.TrimEnd('\', '/').Length).TrimStart('\', '/')
        $destinationPath = Join-Path $Destination $relative
        $parent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
    }
}

function New-StagedInstallView {
    param([string]$StagingRoot, [string]$InstallRoot)
    $staging = Assert-ManagedRootIsOrdinary -Path $StagingRoot
    $install = Assert-ManagedRootIsOrdinary -Path $InstallRoot
    if ([string]::Equals($staging, $install, [StringComparison]::OrdinalIgnoreCase) -or
        (Test-ManagedPathInsideRoot -Root $staging -Path $install)) { throw 'Install view must be outside staging.' }
    if (Test-Path -LiteralPath $install) { throw "Install view already exists: $install" }
    New-Item -ItemType Directory -Path $install -Force | Out-Null
    foreach ($component in @('core', 'armv7', 'aarch64', 'thumbv7em')) {
        $source = Get-PayloadComponentRoot -StagingRoot $staging -Component $component
        Copy-ReleaseComponent -Source $source -Destination $install
    }
    return $install
}

function Get-ReleasePowerShell {
    $shellCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($shellCommand) { return $shellCommand.Source }
    return Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function Invoke-ReleaseSmokeProcess {
    param([string]$InstallRoot, [string]$Version)
    $shell = Get-ReleasePowerShell
    $smoke = Join-Path $PSScriptRoot 'release_smoke.ps1'
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 turns a child process's stderr into a
        # terminating error under Stop, obscuring its actual exit code.
        $ErrorActionPreference = 'Continue'
        & $shell -NoProfile -ExecutionPolicy Bypass -File $smoke -InstallRoot $InstallRoot -Version $Version
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($LASTEXITCODE -ne 0) { throw "Installed release smoke failed ($LASTEXITCODE): $InstallRoot" }
}

function Invoke-StagedInstallValidation {
    param([string]$StagingRoot, [string]$Version, [string]$WorkRoot)
    $null = Assert-StagedRelease -StagingRoot $StagingRoot -Version $Version
    $work = Assert-ManagedRootIsOrdinary -Path $WorkRoot
    if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
    $install = Join-Path $work ('install-view-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = New-StagedInstallView -StagingRoot $StagingRoot -InstallRoot $install
        $finalizer = Join-Path $install 'scripts\finalize_offline_install.ps1'
        $shell = Get-ReleasePowerShell
        & $shell -NoProfile -ExecutionPolicy Bypass -File $finalizer -InstallRoot $install -SelectedComponents 'armv7,aarch64,thumbv7em' -InstallScope perUser
        if ($LASTEXITCODE -ne 0) { throw "Staged install finalizer failed ($LASTEXITCODE)" }
        Invoke-ReleaseSmokeProcess -InstallRoot $install -Version $Version
    }
    finally {
        if (Test-Path -LiteralPath $install) {
            $full = Assert-TransactionChildPath -ManagedRoot $work -Path $install
            Remove-Item -LiteralPath $full -Recurse -Force
        }
    }
}

function Invoke-DisposableInstallerValidation {
    param([string]$InstallerPath, [string]$Version, [string]$WorkRoot)

    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { throw "Installer output not found: $InstallerPath" }
    $work = Assert-ManagedRootIsOrdinary -Path $WorkRoot
    if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
    # Inno's file replacement path still hits traditional MAX_PATH limits on
    # some machines. Keep the temporary install itself near the volume root.
    $shortRoot = Assert-ManagedRootIsOrdinary -Path ([IO.Path]::GetTempPath())
    if ($shortRoot.Length -gt 45) { throw "TEMP is too deep for installer validation: $shortRoot" }
    $validationRoot = Join-Path $shortRoot ('rpc-u04-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $install = Join-Path $validationRoot 'toolkit'
    # Keep the recovery file outside the disposable tree until restoration has
    # been verified; a failed registry import must not destroy its own backup.
    $registryBackup = Join-Path $work ('uninstall-registration-' + [guid]::NewGuid().ToString('N') + '.reg')
    $logPath = Join-Path $validationRoot 'installer.log'
    $registryKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{8A3B77B4-BF0E-4B30-B6AC-8FA8302B3E10}_is1'
    $psRegistryKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{8A3B77B4-BF0E-4B30-B6AC-8FA8302B3E10}_is1'
    $regExe = Join-Path $env:WINDIR 'System32\reg.exe'
    $environmentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if (-not $environmentKey) { throw 'Unable to open current-user environment registry key.' }
    $hadPath = $environmentKey.GetValueNames() -contains 'Path'
    $oldPath = if ($hadPath) { $environmentKey.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
    $oldPathKind = if ($hadPath) { $environmentKey.GetValueKind('Path') } else { $null }
    $hadRegistration = Test-Path -LiteralPath $psRegistryKey
    $oldRegistration = if ($hadRegistration) { Get-ItemProperty -LiteralPath $psRegistryKey } else { $null }
    New-Item -ItemType Directory -Path $validationRoot -Force | Out-Null
    if ($hadRegistration) {
        & $regExe export $registryKey $registryBackup /y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to back up existing installer registration.' }
    }

    try {
        Write-Host "==> Installing EXE for release validation under $install"
        $setupProcess = Start-Process -FilePath $InstallerPath -ArgumentList @(
            '/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER',
            "/RPCValidationDir=`"$install`"", "/DIR=`"$install`"", "/LOG=`"$logPath`""
        ) -WindowStyle Hidden -PassThru -Wait
        if ($setupProcess.ExitCode -ne 0) { throw "Disposable installer failed ($($setupProcess.ExitCode)). Log: $logPath" }
        if (-not (Test-Path -LiteralPath (Join-Path $install 'install-layout.json') -PathType Leaf)) {
            throw "Installer did not populate the disposable directory: $install"
        }
        $registration = Get-ItemProperty -LiteralPath $psRegistryKey -ErrorAction Stop
        if (-not [string]::Equals(([IO.Path]::GetFullPath([string]$registration.InstallLocation)).TrimEnd('\', '/'),
            ([IO.Path]::GetFullPath($install)).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Installer registered an unexpected location: $($registration.InstallLocation)"
        }
        Invoke-ReleaseSmokeProcess -InstallRoot $install -Version $Version
    }
    catch {
        $reason = $_.Exception.Message
        $logTail = if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            $savedLog = Join-Path $work ('failed-install-' + [guid]::NewGuid().ToString('N') + '.log')
            Copy-Item -LiteralPath $logPath -Destination $savedLog -Force
            $markers = @(Select-String -LiteralPath $logPath -Pattern 'Defaulting to Abort|MoveFile failed|User canceled|Error code|Unable to' | Select-Object -Last 12)
            "Saved log: $savedLog" + [Environment]::NewLine + (($markers | ForEach-Object { $_.Line }) -join [Environment]::NewLine)
        }
        else { 'No installer log was created.' }
        throw "$reason`nInstaller log tail:`n$logTail"
    }
    finally {
        try {
            $uninstaller = Join-Path $install 'unins000.exe'
            if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
                $uninstallProcess = Start-Process -FilePath $uninstaller -ArgumentList @(
                    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
                ) -WindowStyle Hidden -PassThru -Wait
                if ($uninstallProcess.ExitCode -ne 0) { Write-Warning "Disposable uninstaller failed ($($uninstallProcess.ExitCode)): $uninstaller" }
            }
        }
        finally {
            try {
                if ($hadRegistration) {
                    if (Test-Path -LiteralPath $psRegistryKey) {
                        Remove-Item -LiteralPath $psRegistryKey -Recurse -Force
                    }
                    & $regExe import $registryBackup | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Unable to restore existing installer registration. Backup: $registryBackup" }
                }
                elseif (Test-Path -LiteralPath $psRegistryKey) {
                    Remove-Item -LiteralPath $psRegistryKey -Recurse -Force
                }
                if ($hadPath) { $environmentKey.SetValue('Path', $oldPath, $oldPathKind) }
                else { $environmentKey.DeleteValue('Path', $false) }
            }
            finally {
                $environmentKey.Dispose()
                if (Test-Path -LiteralPath $validationRoot) {
                    $full = Assert-TransactionChildPath -ManagedRoot $shortRoot -Path $validationRoot
                    Remove-Item -LiteralPath $full -Recurse -Force
                }
            }
        }
    }
    $restoredEnvironment = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try {
        $restoredPath = $restoredEnvironment.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($hadPath -and -not [string]::Equals([string]$restoredPath, [string]$oldPath, [StringComparison]::Ordinal)) {
            throw 'Disposable install did not restore the original user PATH.'
        }
        if (-not $hadPath -and $restoredEnvironment.GetValueNames() -contains 'Path') {
            throw 'Disposable install left an unexpected user PATH value.'
        }
    }
    finally { $restoredEnvironment.Dispose() }
    if ($hadRegistration) {
        $restoredRegistration = Get-ItemProperty -LiteralPath $psRegistryKey -ErrorAction Stop
        if ($restoredRegistration.DisplayVersion -ne $oldRegistration.DisplayVersion -or
            $restoredRegistration.InstallLocation -ne $oldRegistration.InstallLocation) {
            throw 'Disposable install did not restore the original installer registration.'
        }
    }
    elseif (Test-Path -LiteralPath $psRegistryKey) {
        throw 'Disposable install left an unexpected uninstall registration.'
    }
    if (Test-Path -LiteralPath $validationRoot) { throw "Disposable install directory was not removed: $validationRoot" }
    if ($hadRegistration -and (Test-Path -LiteralPath $registryBackup -PathType Leaf)) {
        Remove-Item -LiteralPath $registryBackup -Force
    }
    $recordPath = Join-Path $work "verified-installer-$Version.json"
    [ordered]@{
        formatVersion = 1
        productVersion = $Version
        installer = [IO.Path]::GetFullPath($InstallerPath)
        installerSha256 = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        validatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        validation = @('payload-index', 'rust-targets', 'windows-c', 'armv7-proc-macro', 'aarch64-proc-macro', 'full-sample-windows', 'full-sample-armv7', 'full-sample-aarch64', 'x64-pe-imports', 'linux-elf-abi', 'thumbv7em-vector-bin-hex')
        networkConstraint = 'rustup-auto-install-disabled; cargo-offline; proxy-blackhole'
        temporaryInstallRemoved = -not (Test-Path -LiteralPath $validationRoot)
        priorRegistrationRestored = $true
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recordPath -Encoding UTF8
    Write-Host "Verified installed EXE: $recordPath"
}
