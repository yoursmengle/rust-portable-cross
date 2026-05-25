@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0aarch64-linux-musl-gcc.ps1" %*
