@echo off
"%~dp0..\zig\zig.exe" lib %*
exit /b %ERRORLEVEL%
