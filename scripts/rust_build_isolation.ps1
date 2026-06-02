Set-StrictMode -Version Latest

$script:RustBuildIsolatedEnvironmentNames = @(
    'CARGO_BUILD_TARGET',
    'CARGO_ENCODED_RUSTFLAGS',
    'CARGO_TARGET_DIR',
    'RUSTFLAGS',
    'CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER',
    'CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS',
    'CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER',
    'CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_RUSTFLAGS',
    'CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER',
    'CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS',
    'CC',
    'HOST_CC',
    'AR',
    'RANLIB',
    'CC_armv7_unknown_linux_musleabihf',
    'AR_armv7_unknown_linux_musleabihf',
    'RANLIB_armv7_unknown_linux_musleabihf',
    'CC_armv7-unknown-linux-musleabihf',
    'AR_armv7-unknown-linux-musleabihf',
    'RANLIB_armv7-unknown-linux-musleabihf',
    'CC_aarch64_unknown_linux_musl',
    'AR_aarch64_unknown_linux_musl',
    'RANLIB_aarch64_unknown_linux_musl',
    'CC_aarch64-unknown-linux-musl',
    'AR_aarch64-unknown-linux-musl',
    'RANLIB_aarch64-unknown-linux-musl',
    'CC_x86_64_pc_windows_msvc',
    'AR_x86_64_pc_windows_msvc',
    'RANLIB_x86_64_pc_windows_msvc',
    'CC_x86_64-pc-windows-msvc',
    'AR_x86_64-pc-windows-msvc',
    'RANLIB_x86_64-pc-windows-msvc'
)

function Save-RustBuildEnvironment {
    $snapshot = @{}
    foreach ($name in @($script:RustBuildIsolatedEnvironmentNames)) {
        $snapshot[$name] = [System.Environment]::GetEnvironmentVariable([string]$name, 'Process')
    }
    return $snapshot
}

function Add-RustBuildFlagIfMissing {
    param(
        [AllowEmptyString()]
        [string]$Existing,

        [Parameter(Mandatory = $true)]
        [string]$Flag
    )

    if ([string]::IsNullOrWhiteSpace($Existing)) {
        return $Flag
    }
    if ($Existing -match [regex]::Escape($Flag)) {
        return $Existing
    }
    return "$Existing $Flag"
}

function New-ZigToolWrapperIfMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WrappersRoot,

        [Parameter(Mandatory = $true)]
        [string]$ToolName,

        [Parameter(Mandatory = $true)]
        [string]$ZigSubcommand,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $WrappersRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $WrappersRoot -Force | Out-Null
    }

    $ps1Path = Join-Path $WrappersRoot "$ToolName.ps1"
    if (-not (Test-Path -LiteralPath $ps1Path -PathType Leaf)) {
        $ps1Body = @(
            "# Wrapper: forwards args to ``zig $ZigSubcommand`` $Description.",
            "& `"`$PSScriptRoot\..\zig\zig.exe`" $ZigSubcommand @args",
            "exit `$LASTEXITCODE"
        ) -join "`r`n"
        Set-Content -LiteralPath $ps1Path -Value $ps1Body -Encoding ASCII
    }

    $cmdPath = Join-Path $WrappersRoot "$ToolName.cmd"
    if (-not (Test-Path -LiteralPath $cmdPath -PathType Leaf)) {
        $cmdBody = @(
            "@echo off",
            "setlocal",
            'set "_PS="',
            'for %%I in (pwsh.exe) do set "_PS=%%~$PATH:I"',
            'if not defined _PS if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "_PS=%ProgramFiles%\PowerShell\7\pwsh.exe"',
            'if not defined _PS set "_PS=powershell"',
            "`"%_PS%`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$ToolName.ps1`" %*"
        ) -join "`r`n"
        Set-Content -LiteralPath $cmdPath -Value $cmdBody -Encoding ASCII
    }
}

function Ensure-ZigDlltoolWrapper {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WrappersRoot
    )

    New-ZigToolWrapperIfMissing `
        -WrappersRoot $WrappersRoot `
        -ToolName "zig-dlltool" `
        -ZigSubcommand "dlltool" `
        -Description "for Windows GNU import library generation"
}

function Get-NormalizedCargoSectionName {
    param([AllowEmptyString()][string]$SectionName)

    return (([string]$SectionName).Trim().Replace('"', '').Replace("'", '').ToLowerInvariant())
}

function Test-CargoWindowsHostTargetSectionName {
    param([AllowEmptyString()][string]$SectionName)

    $name = Get-NormalizedCargoSectionName -SectionName $SectionName
    return ($name -eq "target.x86_64-pc-windows-gnu" -or $name -eq "target.x86_64-pc-windows-msvc")
}

function Repair-CargoHostTargetConfigFile {
    param([AllowEmptyString()][string]$ConfigPath)

    if ([string]::IsNullOrWhiteSpace($ConfigPath) -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return $false
    }

    $lines = @(Get-Content -LiteralPath $ConfigPath -Encoding UTF8)
    $kept = New-Object System.Collections.Generic.List[string]
    $insideRemovedSection = $false
    $changed = $false
    $currentSection = ""

    foreach ($line in $lines) {
        $trimmed = ([string]$line).Trim()
        if ($trimmed -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $sectionName = [string]$Matches[1]
            $currentSection = Get-NormalizedCargoSectionName -SectionName $sectionName
            $insideRemovedSection = Test-CargoWindowsHostTargetSectionName -SectionName $sectionName
            if ($insideRemovedSection) {
                $changed = $true
                continue
            }
        }

        if ($insideRemovedSection) {
            $changed = $true
            continue
        }

        if ($currentSection -eq "build" -and $trimmed -match '^(?i)target\s*=\s*(["'']?)x86_64-pc-windows-(gnu|msvc)\1\s*(?:#.*)?$') {
            $changed = $true
            continue
        }

        $kept.Add([string]$line) | Out-Null
    }

    if (-not $changed) {
        return $false
    }

    Set-Content -LiteralPath $ConfigPath -Value $kept.ToArray() -Encoding UTF8
    Write-Host "Repaired Windows host Cargo config: $ConfigPath"
    return $true
}

function Repair-CargoHostTargetConfig {
    param(
        [AllowEmptyString()][string]$ToolkitRoot,
        [AllowEmptyString()][string]$ProjectRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        Repair-CargoHostTargetConfigFile -ConfigPath (Join-Path $ToolkitRoot "config\.cargo\config.toml") | Out-Null
        Repair-CargoHostTargetConfigFile -ConfigPath (Join-Path $ToolkitRoot "tools\cargo-home\config.toml") | Out-Null
        Repair-CargoHostTargetConfigFile -ConfigPath (Join-Path $ToolkitRoot "tools\cargo-home\config") | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$env:CARGO_HOME)) {
        Repair-CargoHostTargetConfigFile -ConfigPath (Join-Path ([string]$env:CARGO_HOME) "config.toml") | Out-Null
        Repair-CargoHostTargetConfigFile -ConfigPath (Join-Path ([string]$env:CARGO_HOME) "config") | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $projectCargoDir = Join-Path $ProjectRoot ".cargo"
        Repair-CargoHostTargetConfigFile -ConfigPath (Join-Path $projectCargoDir "config.toml") | Out-Null
        Repair-CargoHostTargetConfigFile -ConfigPath (Join-Path $projectCargoDir "config") | Out-Null
    }
}

function Clear-RustBuildEnvironment {
    foreach ($name in @($script:RustBuildIsolatedEnvironmentNames)) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

function Restore-RustBuildEnvironment {
    param([hashtable]$Snapshot)

    if (-not $Snapshot) {
        return
    }

    foreach ($name in @($script:RustBuildIsolatedEnvironmentNames)) {
        if ($Snapshot.ContainsKey($name) -and $null -ne $Snapshot[$name]) {
            [System.Environment]::SetEnvironmentVariable([string]$name, [string]$Snapshot[$name], 'Process')
        }
        else {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
    }
}
