# Proposal

## Why

The Linux cross-compiler wrappers decide whether an `@file` argument is a response file with `Test-Path`, which goes through the PowerShell FileSystem provider. In a consumer's isolated build (HEC), the PowerShell process has only a `Temp:` drive and no drive for the volume holding the file, so `Test-Path` reports `False` for a file that exists. The wrapper then skips its linker-argument filtering and hands the untouched file to `zig cc`, and every aarch64 link that spills into a response file fails with `unsupported linker arg: --fix-cortex-a53-843419`.

The same consumer now rewrites response files before the wrapper sees them, which makes the wrapper's "whole lines only, no re-escaping" handling a cross-repository contract. Nothing in this repository records it.

## What Changes

- The generated `arm-linux-musleabihf-gcc.ps1` and `aarch64-linux-musl-gcc.ps1` wrappers detect a response file with `[System.IO.File]::Exists` instead of `Test-Path`, so detection no longer depends on which PowerShell drives are mounted.
- The change is made in the generator (`scripts/rust_setup.ps1`) and in the two checked-in generated wrappers under `tools/wrappers/`, so the next setup run does not revert it.
- A regression test asserts that the generator and the shipped wrappers do not use PowerShell provider cmdlets to locate a response file.
- The response-file handling contract is written into the spec: line-wise filtering without decoding or re-quoting, both accepted input formats, and the location, encoding, and line endings of the rewritten copy. The current implementation already behaves this way; no behavior change is intended for this part.

Non-goals:

- Decoding rustc's backslash-escaped spaces so that `zig cc` accepts space-containing paths when the toolkit is used without a pre-processing consumer.
- Correcting the wrapper header comment that says a link never arrives as plain argv and that whole-line rewriting preserves escaping.
- Auditing the scripts under `scripts/` for the same provider dependency.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `toolkit-path-portability`: adds a requirement that cross-compiler wrappers detect response files independently of PowerShell drive state, and a requirement that fixes the response-file filtering format contract.

## Impact

- `scripts/rust_setup.ps1`: the wrapper generator line that tests for a response file.
- `tools/wrappers/aarch64-linux-musl-gcc.ps1`, `tools/wrappers/arm-linux-musleabihf-gcc.ps1`: the same line in the checked-in generated output.
- `test/rust_setup.tests.ps1`: new assertions.
- Installed toolkits pick the fix up only from a rebuilt and republished installer; `dist/staging` copies are build output.
- HEC currently drops `--fix-cortex-a53-*` itself, so a build routed through HEC succeeds with or without this fix and cannot serve as evidence for it. Verification has to call the wrapper directly with a response file.
