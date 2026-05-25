@echo off
"%~dp0..\zig\zig.exe" cc -target aarch64-linux-musl %*
