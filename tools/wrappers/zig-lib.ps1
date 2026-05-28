# Wrapper: forwards args to `zig lib` to provide a repository-local MSVC-compatible archive tool.
# cc-rs passes args with '-' prefix (e.g. -out:X) but zig lib requires '/' prefix (e.g. /out:X).
$translated = $args | ForEach-Object {
    $a = [string]$_
    if ($a -match '^-([A-Za-z])') { '/' + $a.Substring(1) } else { $a }
}
& "$PSScriptRoot\..\zig\zig.exe" lib @translated
exit $LASTEXITCODE
