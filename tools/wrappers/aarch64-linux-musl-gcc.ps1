# Wrapper: forwards args to `zig cc -target aarch64-linux-musl`.
# cc-rs (and some build.rs scripts) inject `--target=<rust-triple>` which zig's
# strict target parser rejects. Drop any caller-supplied -target/--target= flags
# and force the canonical Zig 3-tuple ourselves.
#
# rustc also injects linker flags from the target spec that zig refuses to forward:
# zig 0.13 validates `-Wl,` arguments against an allowlist and aborts with
# `error: unsupported linker arg` instead of handing them to LLD. The AArch64
# Linux specs prepend `-Wl,--fix-cortex-a53-843419` - a link-time workaround for
# an erratum in Cortex-A53 r0p0-r0p4 - which fails every aarch64 link. Strip that
# family of flags; binaries linked here carry the same erratum exposure as any
# other binary zig links for aarch64.
#
# A real link never arrives as plain argv: rustc spills the whole command line
# into an `@response-file`, so the same filtering has to run over the file's
# contents. rustc writes one argument per line, so dropping or rewriting whole
# lines preserves its escaping; the rewritten copy is left beside the original
# inside rustc's own temp directory and is cleaned up with it.
$zigTarget = 'aarch64-linux-musl'
$droppedLinkArgPrefixes = @('--fix-cortex-a53-')

function Test-DroppedLinkArg {
    param([string]$Value)
    foreach ($prefix in $droppedLinkArgPrefixes) {
        if ($Value.StartsWith($prefix)) { return $true }
    }
    return $false
}

# Returns the argument to forward, or $null when it must be dropped entirely.
function Convert-LinkArg {
    param([string]$Value)
    if (Test-DroppedLinkArg $Value) { return $null }
    if ($Value.StartsWith('-Wl,')) {
        $linkArgs = $Value.Substring(4).Split(',')
        $keptLinkArgs = @($linkArgs | Where-Object { -not (Test-DroppedLinkArg $_) })
        if ($keptLinkArgs.Count -ne $linkArgs.Count) {
            if ($keptLinkArgs.Count -eq 0) { return $null }
            return '-Wl,' + ($keptLinkArgs -join ',')
        }
    }
    return $Value
}

function Convert-ResponseFile {
    param([string]$Path)
    $responseLines = [System.IO.File]::ReadAllLines($Path)
    $keptLines = New-Object 'System.Collections.Generic.List[string]'
    $changed = $false
    foreach ($line in $responseLines) {
        $converted = Convert-LinkArg $line
        if ($null -eq $converted) { $changed = $true; continue }
        if ($converted -ne $line) { $changed = $true }
        $keptLines.Add($converted)
    }
    if (-not $changed) { return $null }
    $rewrittenPath = $Path + '.zig-cc'
    [System.IO.File]::WriteAllText($rewrittenPath, [string]::Join([string][char]10, $keptLines), (New-Object System.Text.UTF8Encoding($false)))
    return $rewrittenPath
}

$filtered = New-Object 'System.Collections.Generic.List[string]'
$skipNext = $false
foreach ($a in $args) {
    if ($skipNext) { $skipNext = $false; continue }
    $arg = [string]$a
    $normalizedArg = $arg.Trim('"')
    if ($normalizedArg.StartsWith('--target=')) { continue }
    if ($normalizedArg -eq '-target' -or $normalizedArg -eq '--target') { $skipNext = $true; continue }
    if ($normalizedArg.StartsWith('@') -and [System.IO.File]::Exists($normalizedArg.Substring(1))) {
        $rewrittenResponse = Convert-ResponseFile -Path $normalizedArg.Substring(1)
        if ($null -ne $rewrittenResponse) { $filtered.Add('@' + $rewrittenResponse); continue }
        $filtered.Add($arg)
        continue
    }
    $converted = Convert-LinkArg $normalizedArg
    if ($null -eq $converted) { continue }
    if ($converted -ne $normalizedArg) { $filtered.Add($converted) } else { $filtered.Add($arg) }
}

& "$PSScriptRoot\..\zig\zig.exe" cc -target $zigTarget @filtered
exit $LASTEXITCODE
