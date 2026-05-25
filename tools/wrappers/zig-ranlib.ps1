# Wrapper: forwards args to `zig ranlib` for static archive index updates.
& "$PSScriptRoot\..\zig\zig.exe" ranlib @args
exit $LASTEXITCODE
