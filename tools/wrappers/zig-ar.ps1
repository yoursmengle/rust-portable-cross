# Wrapper: forwards args to `zig ar` to provide a repository-local archive tool.
& "$PSScriptRoot\..\zig\zig.exe" ar @args
exit $LASTEXITCODE
