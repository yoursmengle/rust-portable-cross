@echo off
setlocal
set "_PS="
for %%I in (pwsh.exe) do set "_PS=%%~$PATH:I"
if not defined _PS if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "_PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined _PS set "_PS=powershell"
"%_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0x86_64-w64-mingw32-gcc.ps1" %*
