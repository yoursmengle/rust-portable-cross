# Tasks

## 1. Provider-independent response file detection

- [x] 1.1 In `test/rust_setup.tests.ps1`, add assertions that the generator template contains the `[System.IO.File]::Exists` response-file test, that neither `tools/wrappers/aarch64-linux-musl-gcc.ps1` nor `tools/wrappers/arm-linux-musleabihf-gcc.ps1` contains `Test-Path`, and that both tracked wrappers contain the response-file test line the generator emits; verify the test file fails on these assertions before the fix
- [x] 1.2 Replace the `Test-Path -LiteralPath ... -PathType Leaf` response-file test with `[System.IO.File]::Exists(...)` in the wrapper template in `scripts/rust_setup.ps1`; verify the generator assertion from 1.1 passes
- [x] 1.3 Apply the same one-line change to `tools/wrappers/aarch64-linux-musl-gcc.ps1` and `tools/wrappers/arm-linux-musleabihf-gcc.ps1`, keeping CRLF line endings and ASCII encoding; verify `git diff --stat` shows one changed line per wrapper and the remaining assertions from 1.1 pass
- [x] 1.4 Verify the existing aarch64 end-to-end wrapper test still passes with `--version` in a response file, and that an `@` argument naming a directory or a missing path is forwarded unchanged

## 2. Response file format contract tests

- [x] 2.1 In `test/rust_setup.tests.ps1`, add a helper that runs a wrapper against a hand-written response file and returns the bytes of `<path>.zig-cc` without asserting on the compiler's exit code; verify it reproduces the existing `--version` expectation
- [x] 2.2 Add cases for both wrappers: a rustc-escaped line (`C:\\dir\\sp\ ace\\a.o`) and a consumer-quoted line (`"C:\dir\sp ace\a.o"`) are byte-identical in the output next to a dropped `-Wl,--fix-cortex-a53-843419` line, and line order is preserved; verify the cases pass
- [x] 2.3 Add cases for both wrappers: a mixed `-Wl,` list loses only the rejected flag; the output has no byte order mark and no CR; the original response file is unmodified; a response file with nothing to filter produces no `.zig-cc` file; verify the cases pass

## 3. Integration checks

- [x] 3.1 Run `test/rust_setup.tests.ps1` under PowerShell 7 and Windows PowerShell 5.1; verify both print `rust_setup tests passed.`
- [x] 3.2 Run `ci.ps1`; verify it passes
- [x] 3.3 Run `openspec validate wrapper-response-file-provider-independence --strict`; verify it reports the change as valid

## Workflow follow-up

- Rebuild and republish the installer so installed toolkits receive the corrected wrappers.
- Ask the consumer (HEC) to confirm the fix in its isolated environment by invoking the wrapper directly with a response file containing `-Wl,--fix-cortex-a53-843419` and checking that `<path>.zig-cc` is produced, or by running its aarch64 build with its own `--fix-cortex-a53-*` drop disabled. Its normal build passes with or without this fix.
- Ask the consumer whether it runs any toolkit script other than the wrappers inside its isolated process.
- Archive the change after review.
