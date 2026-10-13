# Design

## Context

See proposal.md for motivation.

The two Linux cross-compiler wrappers are emitted by `scripts/rust_setup.ps1` from one string template and are also tracked in git under `tools/wrappers/`. Release packaging copies the tracked files. Both copies of the response-file test read:

```
if ($normalizedArg.StartsWith('@') -and (Test-Path -LiteralPath $normalizedArg.Substring(1) -PathType Leaf)) {
```

Everything after that test already uses .NET file APIs (`ReadAllLines`, `WriteAllText`), which resolve paths against the process working directory, as `zig` does. The existence test is the only step that goes through the PowerShell provider.

The "only a `Temp:` drive" condition could not be reproduced locally: removing the `C:` and `D:` drives in a child PowerShell 7.6.1 session triggers automount and `Test-Path` succeeds again. The consumer's isolation evidently prevents automount as well. The fix therefore rests on the consumer's measurements, and on the replacement being safe whether or not that diagnosis is complete.

## Goals / Non-Goals

**Goals:**

- Response-file detection that gives the same answer as the file APIs used to read the file.
- Generator and tracked wrappers changed together and kept from drifting apart.
- A test that fails if the provider dependency returns, without needing the isolated environment.
- Tests for the format contract that pin today's behavior.

**Non-Goals:**

- Reproducing the consumer's isolated environment in this repository's tests.
- Any change to how lines are parsed, escaped, or written.

## Decisions

### Use `[System.IO.File]::Exists` for detection

`File.Exists` returns `False` for directories, so it covers `-PathType Leaf`. It does not throw on malformed paths or access errors, so a non-file `@` argument still falls through to plain forwarding. It exists in Windows PowerShell 5.1 and PowerShell 7. Relative paths now resolve against the process working directory instead of the PowerShell location; under `-File` start-up the two are identical, and the process directory is what `ReadAllLines` and `zig` use anyway.

Alternative considered: keep `Test-Path` and fall back to `File.Exists` when it returns `False`. Rejected: two code paths with no case where `Test-Path` gives a better answer.

Alternative considered: drop the existence test and attempt to read every `@` argument inside `try`/`catch`. Rejected: larger behavior change than the problem calls for.

### Edit the generator and the tracked wrappers in the same change

The generator is the source; the tracked files are what packaging ships. Changing only one leaves either the next setup run or the next release with the old line. The tracked files are edited by hand to match the generator output rather than regenerated, because running setup has side effects far beyond these two files.

### Guard with static assertions

`test/rust_setup.tests.ps1` already asserts on the generator's text and on the shipped aarch64 wrapper. Add:

- the generator template contains the `File.Exists` response-file test;
- neither tracked wrapper contains `Test-Path`;
- both tracked wrappers contain the same response-file test line as the generator emits.

A behavioral test would need a process whose drive for the file's volume cannot be mounted, which is not reproducible here (see Context).

### Test the format contract on the rewritten file, not on the compiler's exit code

The existing end-to-end test passes `--version` so that `zig cc` exits 0. Lines that look like object paths would make the compiler fail on missing inputs. The wrapper writes `<path>.zig-cc` before it starts the compiler, so the contract tests assert on that file's bytes and ignore the exit code. Cases: a rustc-escaped line and a consumer-quoted line survive byte for byte next to a dropped `-Wl,--fix-cortex-a53-843419` line; a mixed `-Wl,` list loses only the rejected flag; the output has no BOM and no CR; a file with nothing to filter produces no `.zig-cc`. The same cases run against the armv7 wrapper, which today has no behavior test.

## Risks / Trade-offs

- [The consumer's builds pass with or without this fix, because the consumer drops `--fix-cortex-a53-*` itself] → Acceptance is the direct wrapper invocation in the isolated environment, performed by the consumer, or the consumer's build with its own drop disabled. Stated in tasks.md as a follow-up outside this repository.
- [Static assertions prove the cmdlet is absent, not that the wrapper works without a drive] → Accepted; the remaining statements in the wrapper are .NET calls and a native invocation that the consumer has observed working in isolation.
- [Other scripts under `scripts/` use provider cmdlets heavily and may fail the same way if a consumer runs them in isolation] → Out of scope; raised with the consumer as a question.
- [The wrapper header comment stays inaccurate about argv delivery and escaping] → Deferred with the space-decoding work it belongs to.

## Migration Plan

Ship in the next installer build. Installed toolkits keep the old wrappers until reinstalled. Rollback is reverting the commit; no data or state is involved.

## Open Questions

- Does the consumer run any toolkit script other than the wrappers inside its isolated process? This decides whether a follow-up audit of `scripts/` is needed; it does not affect this change.
