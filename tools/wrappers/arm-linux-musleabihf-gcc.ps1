# Wrapper: forwards args to `zig cc -target arm-linux-musleabihf`.
# cc-rs (and some build.rs scripts) inject `--target=<rust-triple>` such as
# `--target=armv7-unknown-linux-musleabihf`. zig's strict target parser
# rejects the 4-component Rust triple (UnknownArchitecture), so we drop any
# caller-supplied `-target` / `--target=` flags and force the canonical
# Zig 3-tuple ourselves.
$zigTarget = 'arm-linux-musleabihf'

$filtered = New-Object 'System.Collections.Generic.List[string]'
$skipNext = $false
foreach ($a in $args) {
    if ($skipNext) { $skipNext = $false; continue }

    $arg = [string]$a
    $normalizedArg = $arg.Trim('"')

    if (($normalizedArg -match '--target') -and ($normalizedArg -match 'armv7-unknown-linux-musleabihf')) { continue }
    if ($normalizedArg -eq 'armv7-unknown-linux-musleabihf') { continue }
    if ($normalizedArg -eq '-target' -or $normalizedArg -eq '--target') { $skipNext = $true; continue }

    $filtered.Add($arg)
}

& "$PSScriptRoot\..\zig\zig.exe" cc -target $zigTarget @filtered
exit $LASTEXITCODE
