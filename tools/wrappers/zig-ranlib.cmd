@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zig-ranlib.ps1" %*
