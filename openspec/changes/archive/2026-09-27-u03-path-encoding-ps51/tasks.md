## 1. Preserve build arguments

- [x] 1.1 Add a shared target-specific Cargo TOML array builder for Windows host link flags and use it from all four build entrypoints.
- [x] 1.2 Update native and cross wrappers so current-root paths and quoted/output/response arguments survive CMD, PowerShell, and Zig handoff.

## 2. Restore portable paths

- [x] 2.1 Replace release preparation's .NET Core-only relative path call with a PS5.1-compatible implementation.
- [x] 2.2 Deduplicate toolkit PATH entries during repeated activation and drop entries for a previously activated root after relocation.

## 3. Verify and finish

- [x] 3.1 Add focused PS5.1 and PS7 tests for the Cargo config, relative paths, wrappers, and activation.
- [x] 3.2 Run four builds from an isolated moved toolkit with complex toolkit/project/TEMP paths and verify BIN/HEX outputs.
- [x] 3.3 Run default/full CI and strict OpenSpec validation, then sync the main spec and archive.
