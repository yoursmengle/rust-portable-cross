# Wrapper: forwards args to `zig dlltool`.
& "$PSScriptRoot\..\zig\zig.exe" dlltool @args
exit $LASTEXITCODE
