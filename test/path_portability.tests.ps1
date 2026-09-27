[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param([string]$Actual, [string]$Expected, [string]$Message)
    if ($Actual -cne $Expected) {
        throw "$Message`: expected <$Expected>, got <$Actual>"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\rust_build_isolation.ps1')
$previousSkip = [Environment]::GetEnvironmentVariable('RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN', 'Process')
try {
    $env:RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN = '1'
    . (Join-Path $repoRoot 'scripts\prepare_offline_release.ps1')
}
finally {
    [Environment]::SetEnvironmentVariable('RUST_PORTABLE_CROSS_SKIP_OFFLINE_RELEASE_MAIN', $previousSkip, 'Process')
}

$toolkitRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'rpc path 中文 & (test)'
$expectedLibraryRoot = Join-Path $toolkitRoot 'tools\sysroot\x86_64-pc-windows-msvc\lib'
$configPath = New-WindowsHostCargoConfigFile -ToolkitRoot $toolkitRoot
try {
    $line = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8).Trim()
    $prefix = 'target.x86_64-pc-windows-msvc.rustflags='
    if (-not $line.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
        throw 'Host Cargo config omitted the target-specific rustflags key.'
    }
    $flags = @(($line.Substring($prefix.Length) | ConvertFrom-Json))
    Assert-Equal -Actual ($flags -join '|') -Expected ( @(
        '-C', 'linker-flavor=lld-link', '-C',
        "link-arg=/LIBPATH:$expectedLibraryRoot", '-C', 'link-arg=rpc_winshim.lib'
    ) -join '|') -Message 'Cargo flag boundaries changed'
}
finally {
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Remove-Item -LiteralPath $configPath -Force
    }
}

$base = 'D:\Temp\中文 & (kit)\stage\'
Assert-Equal -Actual (Get-RelativePath -BasePath $base -ChildPath 'd:\Temp\中文 & (kit)\stage\core\file.txt') -Expected 'core/file.txt' -Message 'Nested path'
Assert-Equal -Actual (Get-RelativePath -BasePath $base -ChildPath 'D:\Temp\中文 & (kit)\other\file.txt') -Expected '../other/file.txt' -Message 'Sibling path'
Assert-Equal -Actual (Get-RelativePath -BasePath $base -ChildPath 'D:\Temp\中文 & (kit)\stage') -Expected '.' -Message 'Same path'
Assert-Equal -Actual (Get-RelativePath -BasePath $base -ChildPath 'C:\other\file.txt') -Expected 'C:/other/file.txt' -Message 'Cross-volume path'

$previousPath = $env:PATH
try {
    $oldRoot = 'D:\Temp\rpc old kit'
    $newRoot = 'D:\Temp\rpc new 中文 & (kit)'
    $unrelated = 'D:\Temp\rpc old kit-other\bin'
    $env:PATH = [string]::Join(';', @(
        (Join-Path $oldRoot 'scripts'),
        (Join-Path $newRoot 'tools\zig'),
        (Join-Path $newRoot 'tools\zig'),
        $unrelated,
        $previousPath
    ))
    Set-ToolkitPathPrefix -ToolkitRoot $newRoot -PreviousToolkitRoot $oldRoot
    Set-ToolkitPathPrefix -ToolkitRoot $newRoot -PreviousToolkitRoot $newRoot
    $entries = @($env:PATH -split ';')
    foreach ($managed in @(Get-ToolkitPathEntries -ToolkitRoot $newRoot)) {
        $count = @($entries | Where-Object { (Get-ToolkitPathKey -Entry $_) -ceq (Get-ToolkitPathKey -Entry $managed) }).Count
        if ($count -ne 1) { throw "Managed PATH entry occurs $count times: $managed" }
    }
    if (@($entries | Where-Object { $_ -ieq (Join-Path $oldRoot 'scripts') }).Count -ne 0) {
        throw 'Old toolkit PATH entry survived activation at the new root.'
    }
    if (@($entries | Where-Object { $_ -ieq $unrelated }).Count -ne 1) {
        throw 'Activation removed an unrelated sibling PATH entry.'
    }
}
finally {
    $env:PATH = $previousPath
}

Write-Host 'path_portability tests passed.'
