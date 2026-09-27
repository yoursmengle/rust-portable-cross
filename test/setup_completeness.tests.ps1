[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$previousSkip = [Environment]::GetEnvironmentVariable('RUST_PORTABLE_CROSS_SKIP_MAIN', 'Process')
try {
    $env:RUST_PORTABLE_CROSS_SKIP_MAIN = '1'
    . (Join-Path $PSScriptRoot '..\scripts\rust_setup.ps1')
}
finally {
    [Environment]::SetEnvironmentVariable('RUST_PORTABLE_CROSS_SKIP_MAIN', $previousSkip, 'Process')
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rpc-setup-' + [guid]::NewGuid().ToString('N'))
$scriptRoot = Join-Path $testRoot 'scripts'
$libraryRoot = Join-Path $testRoot 'tools\sysroot\x86_64-pc-windows-msvc\lib'
$generatorPath = Join-Path $scriptRoot 'build_win_link_inputs.ps1'
$counterPath = Join-Path $testRoot 'generation-count.txt'

try {
    New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null
    $generator = @'
param([string]$ToolkitRoot, [switch]$Force)
if ($env:RPC_SETUP_TEST_GENERATOR_FAIL -eq '1') { throw 'simulated generator failure' }
$sysroot = Join-Path $ToolkitRoot 'tools\sysroot\x86_64-pc-windows-msvc'
$lib = Join-Path $sysroot 'lib'
New-Item -ItemType Directory -Path $lib -Force | Out-Null
$names = @(
    'kernel32.lib', 'ntdll.lib', 'userenv.lib', 'ws2_32.lib',
    'dbghelp.lib', 'advapi32.lib', 'user32.lib', 'ole32.lib',
    'oleaut32.lib', 'shell32.lib', 'bcrypt.lib', 'msvcrt.lib', 'rpc_winshim.lib'
)
foreach ($name in $names) { Set-Content -LiteralPath (Join-Path $lib $name) -Value 'fake' -Encoding ASCII }
[ordered]@{ triple = 'x86_64-pc-windows-msvc'; zigVersion = '0.13.0'; files = @($names) } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $sysroot 'PROVENANCE.json') -Encoding UTF8
$counter = Join-Path $ToolkitRoot 'generation-count.txt'
$old = if (Test-Path -LiteralPath $counter) { [int](Get-Content -LiteralPath $counter -Raw) } else { 0 }
Set-Content -LiteralPath $counter -Value ($old + 1) -Encoding ASCII
'@
    Set-Content -LiteralPath $generatorPath -Value $generator -Encoding UTF8

    $status = Get-SetupWindowsLinkInputStatus -ToolkitRoot $testRoot
    Assert-True (-not $status.IsComplete -and $status.Missing.Count -eq 14) 'A clean root should report all 13 libraries and provenance missing.'

    Ensure-SetupWindowsLinkInputs -ToolkitRoot $testRoot -ScriptRoot $scriptRoot
    Assert-True ((Get-SetupWindowsLinkInputStatus -ToolkitRoot $testRoot).IsComplete) 'Initial setup did not create the complete sysroot.'
    Assert-True ((Get-Content -LiteralPath $counterPath -Raw).Trim() -eq '1') 'Initial setup did not invoke the generator once.'

    Ensure-SetupWindowsLinkInputs -ToolkitRoot $testRoot -ScriptRoot $scriptRoot
    Assert-True ((Get-Content -LiteralPath $counterPath -Raw).Trim() -eq '1') 'Complete sysroot was regenerated on repeat setup.'

    Remove-Item -LiteralPath (Join-Path $libraryRoot 'bcrypt.lib') -Force
    Ensure-SetupWindowsLinkInputs -ToolkitRoot $testRoot -ScriptRoot $scriptRoot
    Assert-True ((Get-Content -LiteralPath $counterPath -Raw).Trim() -eq '2') 'Missing library did not trigger repair.'

    Set-Content -LiteralPath (Join-Path $libraryRoot 'msvcrt.lib') -Value '' -NoNewline
    Ensure-SetupWindowsLinkInputs -ToolkitRoot $testRoot -ScriptRoot $scriptRoot
    Assert-True ((Get-Content -LiteralPath $counterPath -Raw).Trim() -eq '3') 'Empty library did not trigger repair.'

    Set-Content -LiteralPath (Join-Path $testRoot 'tools\sysroot\x86_64-pc-windows-msvc\PROVENANCE.json') -Value '{broken' -Encoding ASCII
    Ensure-SetupWindowsLinkInputs -ToolkitRoot $testRoot -ScriptRoot $scriptRoot
    Assert-True ((Get-Content -LiteralPath $counterPath -Raw).Trim() -eq '4') 'Invalid provenance did not trigger repair.'

    Remove-Item -LiteralPath (Join-Path $libraryRoot 'kernel32.lib') -Force
    $env:RPC_SETUP_TEST_GENERATOR_FAIL = '1'
    $failed = $false
    try { Ensure-SetupWindowsLinkInputs -ToolkitRoot $testRoot -ScriptRoot $scriptRoot }
    catch { $failed = $_.Exception.Message.Contains('simulated generator failure') }
    Assert-True $failed 'Generator failure was not surfaced to setup.'

    Set-Content -LiteralPath (Join-Path $testRoot 'empty.exe') -Value '' -NoNewline
    $failed = $false
    try { Assert-SetupFile -Path (Join-Path $testRoot 'empty.exe') -Description 'managed tool' }
    catch { $failed = $_.Exception.Message.Contains('empty managed tool') }
    Assert-True $failed 'An empty managed executable was accepted.'
}
finally {
    Remove-Item -LiteralPath Env:RPC_SETUP_TEST_GENERATOR_FAIL -ErrorAction SilentlyContinue
    $resolved = [System.IO.Path]::GetFullPath($testRoot)
    $temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($temporaryBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'rpc-setup-*' -and
        (Test-Path -LiteralPath $resolved -PathType Container)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

Write-Host 'setup_completeness tests passed.'
