@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0arm-linux-musleabihf-gcc.ps1" %*
