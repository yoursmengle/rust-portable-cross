## Context

See proposal.md. The public build scripts clear conflicting Cargo flags, then set target-specific environment variables before invoking Cargo. Cargo 1.98 treats a target rustflags environment string as whitespace-delimited even when a path fragment is quoted: a local build with a Unicode, space, and `&` path failed with `unknown codegen option`. The same build passed when an inline `--config target.x86_64-pc-windows-msvc.rustflags=[...]` TOML array supplied each flag as a distinct element. [Cargo's configuration reference](https://doc.rust-lang.org/cargo/reference/config.html#buildrustflags) documents the mutually exclusive rustflags sources and `--config` precedence.

## Goals / Non-Goals

**Goals:** Preserve the original script interface, target flags, and managed assets while protecting their process argument boundaries; support both shipped PowerShell runtimes; test relocation and complex paths.

**Non-Goals:** Change target triples, vendor a new command-line parser, or make an already-running build migrate after its directory is moved. U07 owns concurrent temporary-directory isolation.

## Decisions

1. Build the host rustflags as a TOML array in the shared build helper and pass a unique temporary TOML file to Cargo with its existing `--config` option at each build call. A JSON string array is valid TOML here and supplies escaping for Windows backslashes and Unicode. Cargo 1.98 accepted an inline array under PowerShell 7, but PowerShell 5.1 stripped its quotes while constructing the native command line; a file avoids that boundary. Keep the existing target-specific environment variables for non-path flags; avoid the global encoded rustflags source because it would override cross-target settings.
2. Keep `rust-lld` as the host linker. A new linker wrapper would add another CMD/PowerShell boundary to every Rust link; the target-only Cargo array supplies the single path argument without that boundary.
3. Generated cross wrappers already locate Zig relative to their script path. Make the x64 native wrapper use its active toolkit root rather than embedding Zig's absolute path in ASCII source. Write any generated PowerShell source containing non-ASCII literals as UTF-8 with BOM for Windows PowerShell 5.1; the current root-relative wrappers remain ASCII-compatible.
4. Replace the .NET Core-only relative-path call with a .NET Framework-compatible implementation based on normalized full paths and path segments. Check volume roots first and compare Windows segments without case sensitivity. Cover separator, Unicode, and cross-drive behavior explicitly.
5. Rebuild the managed PATH prefix during activation by removing exact entries for both the current toolkit and the previously activated toolkit root before prepending the current root. Do not remove unrelated entries or infer roots from similarly named directories.
6. Keep the published `.cmd` wrapper names. A real Rust `std::process::Command` caller preserved empty values, embedded quotes, Unicode, and response-file arguments through CMD to the PowerShell process; PowerShell's script binder splits `-out:` into two values, and the existing `zig-lib` wrapper reassembles it. An interactive PowerShell caller can lose an empty value before CMD receives it, so validation uses the real Rust caller as well as actual Zig invocations.

## Risks / Trade-offs

- Cargo `--config` has higher precedence than ambient target rustflags → the build scripts already clear ambient flags; keep every managed host flag in the array and check host plus cross builds. Generate a unique file per build and remove it on success or failure.
- CMD `%*` and PowerShell `-File` have special option behavior → exercise real wrapper invocations with spaced, Unicode, and option-style paths; repair only verified translation defects.
- Relative-path normalization can mis-handle a different volume → test cross-volume result in both PowerShell runtimes and reject path arithmetic that returns a path rooted at the wrong volume.

## Migration Plan

No user action or data migration. Run focused PS5.1/PS7 tests and builds from a relocated isolated toolkit, then sync, archive, and commit the change. Revert this commit if existing no-space build calls regress.
