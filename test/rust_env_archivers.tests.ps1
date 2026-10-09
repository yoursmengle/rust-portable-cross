[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Activation must hand the bundled GNU-style archivers only to the cross targets.
# cc-rs falls back to the unsuffixed AR / RANLIB for every target, including the
# host x86_64-pc-windows-msvc, where it calls the archiver lib.exe-style
# (-out:<path> -nologo) and zig-ar rejects that.

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$rustEnv = Join-Path $repoRoot "scripts\rust_env.ps1"

# rust_env executes the managed rustc, so this suite needs a provisioned toolkit.
$provisioningPaths = @(
    "tools\cargo-home\bin\cargo.exe",
    "tools\cargo-home\bin\rustc.exe",
    "tools\cargo-home\bin\rustup.exe",
    "tools\zig\zig.exe",
    "tools\wrappers\zig-ar.cmd",
    "tools\wrappers\zig-ranlib.cmd"
)
$missing = @($provisioningPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot $_)) })
if ($missing.Count -gt 0) {
    Write-Host "SKIP: toolkit is not provisioned (missing $($missing -join ', '))"
    exit 3
}

$scopedArchivers = [ordered]@{
    "AR_armv7_unknown_linux_musleabihf"      = "zig-ar.cmd"
    "AR_armv7-unknown-linux-musleabihf"      = "zig-ar.cmd"
    "AR_aarch64_unknown_linux_musl"          = "zig-ar.cmd"
    "AR_aarch64-unknown-linux-musl"          = "zig-ar.cmd"
    "RANLIB_armv7_unknown_linux_musleabihf"  = "zig-ranlib.cmd"
    "RANLIB_armv7-unknown-linux-musleabihf"  = "zig-ranlib.cmd"
    "RANLIB_aarch64_unknown_linux_musl"      = "zig-ranlib.cmd"
    "RANLIB_aarch64-unknown-linux-musl"      = "zig-ranlib.cmd"
}
$hostArchivers = @(
    "AR_x86_64_pc_windows_msvc",
    "AR_x86_64-pc-windows-msvc",
    "RANLIB_x86_64_pc_windows_msvc",
    "RANLIB_x86_64-pc-windows-msvc"
)
$observed = @("AR", "RANLIB") + @($scopedArchivers.Keys) + $hostArchivers

# Activates in a fresh child process so nothing from this shell (which may itself be
# activated) leaks in. Returns the archiver variables after each activation and the
# archiver warnings each activation emitted.
function Invoke-Activation {
    param(
        [hashtable]$Seed = @{},

        [int]$Times = 1
    )

    $seedJson = ($Seed | ConvertTo-Json -Compress)
    $namesJson = (ConvertTo-Json -InputObject $observed -Compress)
    $child = @'
param([string]$RustEnv, [string]$SeedJson, [string]$NamesJson, [int]$Times)
$ErrorActionPreference = "Stop"
$names = @($NamesJson | ConvertFrom-Json)
foreach ($name in $names) {
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
}
$seed = $SeedJson | ConvertFrom-Json
foreach ($property in $seed.PSObject.Properties) {
    Set-Item -LiteralPath "Env:$($property.Name)" -Value $property.Value
}
$runs = foreach ($i in 1..$Times) {
    $records = . $RustEnv 3>&1 6>$null
    $warnings = @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
        ForEach-Object { $_.Message } |
        Where-Object { $_ -match '^(AR|RANLIB) is set' })
    $values = [ordered]@{}
    foreach ($name in $names) {
        $values[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    [pscustomobject]@{ Values = $values; Warnings = $warnings }
}
ConvertTo-Json -InputObject @($runs) -Depth 4 -Compress
'@
    $childPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rpc-env-archivers-" + [Guid]::NewGuid().ToString("N") + ".ps1")
    [System.IO.File]::WriteAllText($childPath, $child, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $output = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $childPath `
            -RustEnv $rustEnv -SeedJson $seedJson -NamesJson $namesJson -Times $Times 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "activation child failed with exit code $LASTEXITCODE`n$output"
        }
    }
    finally {
        Remove-Item -LiteralPath $childPath -Force -ErrorAction SilentlyContinue
    }

    $jsonLine = @($output -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith("[") })[-1]
    return @($jsonLine | ConvertFrom-Json)
}

function Assert-ScopedArchivers {
    param($Run, [string]$Case)

    foreach ($name in $scopedArchivers.Keys) {
        Assert-True -Condition ($Run.Values.$name -eq $scopedArchivers[$name]) `
            -Message "${Case}: $name should be '$($scopedArchivers[$name])', got '$($Run.Values.$name)'."
    }
    foreach ($name in $hostArchivers) {
        Assert-True -Condition ([string]::IsNullOrEmpty($Run.Values.$name)) `
            -Message "${Case}: activation must not set the host archiver $name, got '$($Run.Values.$name)'."
    }
}

# --- Fresh activation ---------------------------------------------------------

$runs = Invoke-Activation
Assert-True -Condition ([string]::IsNullOrEmpty($runs[0].Values.AR)) -Message "fresh activation must not set AR, got '$($runs[0].Values.AR)'."
Assert-True -Condition ([string]::IsNullOrEmpty($runs[0].Values.RANLIB)) -Message "fresh activation must not set RANLIB, got '$($runs[0].Values.RANLIB)'."
Assert-True -Condition (@($runs[0].Warnings).Count -eq 0) -Message "fresh activation must not warn about AR / RANLIB: $($runs[0].Warnings -join '; ')"
Assert-ScopedArchivers -Run $runs[0] -Case "fresh activation"

# --- Leftover from an earlier activation is removed ---------------------------

$runs = Invoke-Activation -Seed @{ AR = "zig-ar.cmd"; RANLIB = "ZIG-RANLIB.CMD" }
Assert-True -Condition ([string]::IsNullOrEmpty($runs[0].Values.AR)) -Message "a leftover AR=zig-ar.cmd must be removed, got '$($runs[0].Values.AR)'."
Assert-True -Condition ([string]::IsNullOrEmpty($runs[0].Values.RANLIB)) -Message "a leftover RANLIB=zig-ranlib.cmd must be removed (case-insensitively), got '$($runs[0].Values.RANLIB)'."
Assert-True -Condition (@($runs[0].Warnings).Count -eq 0) -Message "removing a toolkit leftover must not warn: $($runs[0].Warnings -join '; ')"
Assert-ScopedArchivers -Run $runs[0] -Case "leftover cleanup"

# --- User-set archivers are kept, with a warning -------------------------------

$runs = Invoke-Activation -Seed @{ AR = "custom.exe"; RANLIB = "custom-ranlib.exe" }
Assert-True -Condition ($runs[0].Values.AR -eq "custom.exe") -Message "a user-set AR must be preserved, got '$($runs[0].Values.AR)'."
Assert-True -Condition ($runs[0].Values.RANLIB -eq "custom-ranlib.exe") -Message "a user-set RANLIB must be preserved, got '$($runs[0].Values.RANLIB)'."
Assert-True -Condition (@($runs[0].Warnings | Where-Object { $_ -match '^AR is set' }).Count -eq 1) -Message "a user-set AR must produce one warning naming AR: $($runs[0].Warnings -join '; ')"
Assert-True -Condition (@($runs[0].Warnings | Where-Object { $_ -match '^RANLIB is set' }).Count -eq 1) -Message "a user-set RANLIB must produce one warning naming RANLIB: $($runs[0].Warnings -join '; ')"
Assert-ScopedArchivers -Run $runs[0] -Case "user-set archivers"

# --- Repeated activation is stable --------------------------------------------

$runs = Invoke-Activation -Times 2
Assert-True -Condition ($runs.Count -eq 2) -Message "expected two activation results, got $($runs.Count)."
foreach ($name in $observed) {
    Assert-True -Condition ($runs[0].Values.$name -eq $runs[1].Values.$name) `
        -Message "a second activation changed ${name}: '$($runs[0].Values.$name)' -> '$($runs[1].Values.$name)'."
}
Assert-True -Condition (@($runs[1].Warnings).Count -eq 0) -Message "a second activation must not warn about AR / RANLIB: $($runs[1].Warnings -join '; ')"

Write-Host "rust_env archiver tests passed."
