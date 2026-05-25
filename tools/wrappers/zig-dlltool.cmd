@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zig-dlltool.ps1" %*
