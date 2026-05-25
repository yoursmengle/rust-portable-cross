@echo off
"%~dp0..\zig\zig.exe" cc -target arm-linux-musleabihf %*
