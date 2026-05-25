# Wrapper: forwards args to zig cc (x86_64-windows-gnu), filtering or
# normalizing flags that rustc injects for x86_64-pc-windows-gnu but Zig does
# not accept verbatim.
$unsupported = @(
    '-Wl,--disable-auto-image-base',
    '-Wl,-Bdynamic'
)

$selfContainedLibDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\rustup-home\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\x86_64-pc-windows-gnu\lib\self-contained"))
$zigExe = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\zig\zig.exe"))

function ConvertTo-ResponseArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Argument
    )

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    return '"' + ($Argument -replace '"', '\"') + '"'
}

function Convert-LinkerArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Argument
    )

    $arg = [string]$Argument
    $normalizedArg = $arg.Trim('"')

    if ($script:SkipNextLinkerArgument) {
        $script:SkipNextLinkerArgument = $false
        return @()
    }

    if ($normalizedArg -in $unsupported) {
        return @()
    }

    # cc-rs may pass the Rust 4-tuple target, which zig rejects.
    if ($normalizedArg.StartsWith('--target=')) {
        return @()
    }
    if ($normalizedArg -eq '--target' -or $normalizedArg -eq '-target') {
        $script:SkipNextLinkerArgument = $true
        return @()
    }

    if ($normalizedArg -match '^-l:?libpthread\.a$' -or $normalizedArg -eq '-llibpthread.a') {
        return @((Join-Path $selfContainedLibDir 'libpthread.a'))
    }

    # rustc uses `-Wl,<path>\list.def` when linking proc-macro DLLs. Zig
    # rejects that as an unsupported linker arg, but accepts the .def file as
    # a normal input.
    if ($normalizedArg -match '^-Wl,(.+\.def)$') {
        return @($Matches[1])
    }

    if ($normalizedArg.StartsWith('@')) {
        $responsePath = $normalizedArg.Substring(1)
        if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
            $convertedResponsePath = "$responsePath.zig"
            $convertedResponseArgs = New-Object 'System.Collections.Generic.List[string]'
            foreach ($line in [System.IO.File]::ReadAllLines($responsePath)) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }

                foreach ($converted in @(Convert-LinkerArgument -Argument $line)) {
                    $convertedResponseArgs.Add((ConvertTo-ResponseArgument -Argument $converted))
                }
            }

            [System.IO.File]::WriteAllLines($convertedResponsePath, [string[]]$convertedResponseArgs)
            return @("@$convertedResponsePath")
        }
    }

    return @($arg)
}

$filteredArgs = New-Object 'System.Collections.Generic.List[string]'
$script:SkipNextLinkerArgument = $false

foreach ($a in $args) {
    foreach ($converted in @(Convert-LinkerArgument -Argument ([string]$a))) {
        $filteredArgs.Add($converted)
    }
}

& $zigExe cc -target x86_64-windows-gnu "-L$selfContainedLibDir" @filteredArgs
exit $LASTEXITCODE
