@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zig-lib.ps1" %*
