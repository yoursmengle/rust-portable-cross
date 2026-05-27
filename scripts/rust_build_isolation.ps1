Set-StrictMode -Version Latest

$script:RustBuildIsolatedEnvironmentNames = @(
    'CARGO_BUILD_TARGET',
    'CARGO_ENCODED_RUSTFLAGS',
    'CARGO_TARGET_DIR',
    'RUSTFLAGS',
    'CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER',
    'CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS',
    'CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER',
    'CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_RUSTFLAGS',
    'CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER',
    'CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS',
    'CC',
    'HOST_CC',
    'AR',
    'RANLIB',
    'DLLTOOL',
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
    'CC_x86_64_pc_windows_gnu',
    'AR_x86_64_pc_windows_gnu',
    'RANLIB_x86_64_pc_windows_gnu',
    'DLLTOOL_x86_64_pc_windows_gnu',
    'CC_x86_64-pc-windows-gnu',
    'AR_x86_64-pc-windows-gnu',
    'RANLIB_x86_64-pc-windows-gnu',
    'DLLTOOL_x86_64-pc-windows-gnu'
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
