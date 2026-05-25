@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0x86_64-w64-mingw32-gcc.ps1" %*
