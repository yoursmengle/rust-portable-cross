# Wrapper: forwards args to `zig lib` (lld-lib) for MSVC-compatible static archive creation.
#
# cc-rs (for x86_64-pc-windows-msvc) calls the archiver as:
#   zig-lib.cmd -out:DESTPATH [-nologo] [DESTPATH] OBJ1 OBJ2 ...
#
# PowerShell's -File invocation mode treats '-param:value' as named-parameter binding
# and splits '-out:D:\path\file.a' into two separate $args entries:
#   $args[0] = '-out'          (parameter name, colon stripped)
#   $args[1] = 'D:\path\file.a' (parameter value as next element)
#
# We detect this split and reassemble before forwarding to zig lib.
# zig lib (lld-lib) accepts both '-out:X' and '/out:X' prefixes.

$zigExe = "$PSScriptRoot\..\zig\zig.exe"
$translated = [System.Collections.Generic.List[string]]::new()

$i = 0
while ($i -lt $args.Count) {
    $a = [string]$args[$i]

    # Detect the PowerShell-split form: '-out' followed by a path as the next arg.
    # A path value will not start with '-' or '/'.
    if ($a -ceq '-out' -and ($i + 1) -lt $args.Count -and ([string]$args[$i + 1]) -notmatch '^[-/]') {
        $translated.Add('/out:' + [string]$args[$i + 1])
        $i += 2
        continue
    }

    # Translate remaining '-X...' flags to '/X...' (MSVC lld-lib style).
    # Also handles the non-split form '-out:X' passed directly (e.g. unit tests).
    if ($a -match '^-([A-Za-z])') {
        $translated.Add('/' + $a.Substring(1))
    } else {
        $translated.Add($a)
    }
    $i++
}

& $zigExe lib @translated
exit $LASTEXITCODE
