Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:RUST_PORTABLE_CROSS_SKIP_BUILD_MAIN = '1'
. (Join-Path $PSScriptRoot '..\build.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workRoot = Join-Path $repoRoot ('dist\build-cache-tests-' + [guid]::NewGuid().ToString('N'))
$environmentNames = @('CARGO_HOME', 'RUSTUP_HOME', 'RUSTUP_TOOLCHAIN', 'CARGO_NET_OFFLINE', 'CARGO_BUILD_TARGET')
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$cargoExe = Join-Path $workRoot 'tools\cargo-home\bin\cargo.exe'
$script:CargoCalls = New-Object 'System.Collections.Generic.List[object]'
$script:CacheComplete = $false
$script:FetchFails = $false

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $cargoExe) -Force | Out-Null
    Set-Content -LiteralPath $cargoExe -Value 'fake executable' -Encoding ASCII
    # Resolve the bundled executable name to a fake Cargo command. It models the
    # missing-cache error without using the network or a developer's Cargo home.
    Set-Item -LiteralPath ('Function:' + $cargoExe) -Value {
        $script:CargoCalls.Add([pscustomobject]@{
            Arguments = @($args)
            CargoHome = $env:CARGO_HOME
            RustupHome = $env:RUSTUP_HOME
            Toolchain = $env:RUSTUP_TOOLCHAIN
            Offline = $env:CARGO_NET_OFFLINE
            BuildTarget = $env:CARGO_BUILD_TARGET
        })
        if ($args -contains '--offline') {
            if ($script:CacheComplete) { $global:LASTEXITCODE = 0; return }
            $global:LASTEXITCODE = 101
            Write-Error 'failed to download android_system_properties v0.1.5: offline mode'
            return
        }
        if ($script:FetchFails) {
            $global:LASTEXITCODE = 101
            Write-Error 'registry connection failed'
            return
        }
        $script:CacheComplete = $true
        $global:LASTEXITCODE = 0
    }
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, ('caller-' + $name), 'Process')
    }
    $env:CARGO_NET_OFFLINE = 'true'

    Initialize-ReleaseSampleCache -ToolkitRoot $workRoot
    Assert-True ($script:CargoCalls.Count -eq 2) 'Incomplete cache must be fetched after the offline probe.'
    Assert-True $script:CacheComplete 'Missing locked dependencies were not fetched.'
    foreach ($call in $script:CargoCalls) {
        Assert-True ($call.Arguments[0] -eq 'fetch' -and $call.Arguments -contains '--locked') 'Fetch must preserve Cargo.lock.'
        Assert-True ($call.Arguments -notcontains '--target' -and $call.Arguments -contains 'build.target=[]') 'Fetch must include dependencies for all platforms.'
        Assert-True ([string]::IsNullOrEmpty($call.BuildTarget)) 'Fetch must clear an inherited build target to include all platforms.'
        Assert-True ($call.Arguments -contains (Join-Path $workRoot 'sample\Cargo.toml')) 'Fetch used the wrong manifest.'
        Assert-True ($call.CargoHome -eq (Join-Path $workRoot 'tools\cargo-home')) 'Fetch must use the bundled Cargo cache.'
        Assert-True ($call.RustupHome -eq (Join-Path $workRoot 'tools\rustup-home')) 'Fetch must use the bundled Rustup home.'
        Assert-True ($call.Toolchain -eq '1.98.0-x86_64-pc-windows-msvc') 'Fetch must use the pinned toolchain.'
    }
    Assert-True ($script:CargoCalls[0].Offline -eq 'true') 'Cache probe must be offline.'
    Assert-True ($script:CargoCalls[1].Offline -eq 'false' -and $script:CargoCalls[1].Arguments -contains 'net.offline=false') 'Online fetch must override inherited offline settings.'
    foreach ($name in $environmentNames) {
        $expected = if ($name -eq 'CARGO_NET_OFFLINE') { 'true' } else { 'caller-' + $name }
        Assert-True ([Environment]::GetEnvironmentVariable($name, 'Process') -eq $expected) "Fetch leaked environment variable $name."
    }

    $script:CargoCalls.Clear()
    Initialize-ReleaseSampleCache -ToolkitRoot $workRoot
    Assert-True ($script:CargoCalls.Count -eq 1 -and $script:CargoCalls[0].Arguments -contains '--offline') 'Complete cache must not require network access.'

    $script:CargoCalls.Clear()
    $script:CacheComplete = $false
    $script:FetchFails = $true
    foreach ($name in $environmentNames) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
    $message = ''
    try { Initialize-ReleaseSampleCache -ToolkitRoot $workRoot }
    catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'Failed to fetch locked sample dependencies' -and $message -match 'registry connection failed') 'Fetch failure must include Cargo diagnostics.'
    Assert-True ($script:CargoCalls.Count -eq 2) 'Fetch failure must stop preparation.'
    foreach ($name in $environmentNames) {
        Assert-True ($null -eq [Environment]::GetEnvironmentVariable($name, 'Process')) "Failed fetch left environment variable $name set."
    }

    'build_sample_cache tests passed.'
}
finally {
    Remove-Item -LiteralPath ('Function:' + $cargoExe) -ErrorAction SilentlyContinue
    foreach ($name in $environmentNames) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
    }
    if (Test-Path -LiteralPath $workRoot) {
        $dist = Join-Path $repoRoot 'dist'
        if (-not (Test-ManagedPathInsideRoot -Root $dist -Path $workRoot)) {
            throw "Refusing to remove test path outside dist: $workRoot"
        }
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}
