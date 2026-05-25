# Wrapper: forwards args to `zig cc -target arm-linux-musleabihf`.
# cc-rs (and some build.rs scripts) inject `--target=<rust-triple>` which zig's
# strict target parser rejects. Drop any caller-supplied -target/--target= flags
# and force the canonical Zig 3-tuple ourselves.
$zigTarget = 'arm-linux-musleabihf'

$filtered = New-Object 'System.Collections.Generic.List[string]'
$skipNext = $false
foreach ($a in $args) {
    if ($skipNext) { $skipNext = $false; continue }
    $arg = [string]$a
    $normalizedArg = $arg.Trim('"')
    if ($normalizedArg.StartsWith('--target=')) { continue }
    if ($normalizedArg -eq '-target' -or $normalizedArg -eq '--target') { $skipNext = $true; continue }
    $filtered.Add($arg)
}

& "$PSScriptRoot\..\zig\zig.exe" cc -target $zigTarget @filtered
exit $LASTEXITCODE
