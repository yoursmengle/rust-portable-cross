## 1. `ci.ps1` skeleton and reporting

- [x] 1.1 Create `ci.ps1` at the repository root with `[CmdletBinding()]`, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = "Stop"`, and parameters `-Full`, `-InstallHook`, matching the style of `scripts/rust_setup.ps1`.
- [x] 1.2 Implement a check registry: each check has a name, a scriptblock, and produces one of `Passed` / `Failed` / `Skipped` with a reason and captured output.
- [x] 1.3 Implement the runner so a failing check does not stop the remaining checks (design Decision 5), collecting all results before reporting.
- [x] 1.4 Print failing checks' captured output, then a final summary listing every check with its outcome; exit 0 only when no check failed. Render `Skipped` with wording that cannot be read as a pass (design Decision 6).
- [x] 1.5 Wrap native-command invocations so `[Console]::OutputEncoding` is UTF-8 for the duration and restored in a `finally` (design Decision 7); confirm a check that prints non-ASCII does not fail or corrupt the summary.

## 2. Fast-lane checks

- [x] 2.1 Add the PowerShell parse check: run `git ls-files '*.ps1'` and parse each with `[System.Management.Automation.Language.Parser]::ParseFile`, failing with the file path and first parse error. Confirm it reports 0 failures on the current tree (27 files).
- [x] 2.2 Add one check per `test/*.tests.ps1` discovered on disk, invoking each in a child `pwsh` and using its exit code as the verdict. Discover the suites rather than hardcoding the list, so a new suite is gated automatically.
- [x] 2.3 Add the OpenSpec check running `openspec validate --all --strict --no-interactive`; report `Skipped` with the reason when the `openspec` executable is not on `PATH` (design Decision 8).
- [x] 2.4 Confirm the whole default lane runs without an installed toolchain: temporarily point the toolkit root at an empty directory (or verify on a clone with no `tools/`) and check it still exits 0, with `rust_setup.tests.ps1`'s zig-dependent assertion self-skipping.
- [x] 2.5 Measure the default lane's wall clock and confirm it is inside the budget stated in design (under 15 s).

## 3. Full lane

- [x] 3.1 Add the four `check_tool_*.ps1` as checks that run only under `-Full`, discovered from disk rather than hardcoded.
- [x] 3.2 Make `-Full` fail with a message naming what is missing when the toolchain required by those checks is absent, instead of silently degrading to the default lane.
- [x] 3.3 Run `ci.ps1 -Full` on the development machine and confirm it passes end to end.

## 4. Hook and installer

- [x] 4.1 Create `.githooks/pre-commit` as a POSIX `sh` script that resolves PowerShell in the order `pwsh` on `PATH` -> `%ProgramFiles%\PowerShell\7\pwsh.exe` -> `powershell`, and fails the commit with a message naming the bypass when none is found (design Decision 3).
- [x] 4.2 Have the hook invoke `ci.ps1` (default lane) from the repository root regardless of the directory `git` invoked it from, and propagate its exit status.
- [x] 4.3 Implement `ci.ps1 -InstallHook`: set `core.hooksPath` to `.githooks`, succeed as a no-op when it is already set to that value, and refuse with a report of what it found when it is set to anything else (design Decision 2).
- [x] 4.4 Verify the hook end to end against a throwaway clone (not this one, so no test commits land in the repository's history): a commit is refused while a check fails, proceeds once they pass, and both bypasses plus the merge skip behave as specified.
- [x] 4.5 Pin `.githooks/**` to LF in `.gitattributes`: `core.autocrlf` is true here, so a fresh clone would otherwise check the hook out with CRLF endings and rely on `sh` tolerating them.

## 5. Bypass, skip, and working-tree honesty

- [x] 5.1 Implement the `RUST_PORTABLE_CROSS_SKIP_CI` bypass in the hook, printing a line that states verification was skipped rather than passed.
- [x] 5.2 Implement the merge/rebase auto-skip using `git rev-parse --git-path MERGE_HEAD` and the rebase state directories, so a conflict resolution commit is never blocked.
- [x] 5.3 Implement the working-tree warning: when `git diff --quiet` reports unstaged modifications to tracked files, warn that the working tree - not the staged content - is what was verified; emit nothing when they match (design Decision 4).
- [x] 5.4 Confirm `git commit --no-verify` bypasses the hook.

## 6. Tests

- [x] 6.1 Create `test/ci.tests.ps1` following the existing suites' shape (`Assert-Equal` / `Assert-True` helpers, temp roots created and removed in `finally`).
- [x] 6.2 Test the aggregate verdict: a run where every check passes exits 0; a run with one failing check exits non-zero and names it; a run with two failing checks reports both.
- [x] 6.3 Test that a skipped check is reported as skipped, is not counted as a pass, and does not fail the run.
- [x] 6.4 Test the installer's three cases: fresh install, re-install as a no-op, and refusal when `core.hooksPath` already points somewhere else - each against a throwaway repository created with `git init` under a temp root, never against this clone's config.
- [x] 6.5 Test the working-tree warning in both directions (present with unstaged changes, absent without) in a throwaway repository.
- [x] 6.6 Confirm each new test fails when the behaviour it covers is removed, so none of them is vacuous.

## 7. Packaging and documentation

- [x] 7.1 Add an assertion to `test/prepare_offline_release.tests.ps1` that the staged payload contains neither `ci.ps1` nor `.githooks/` (design Decision 9).
- [x] 7.2 Document the gate in `README.md`: what `ci.ps1` runs, the `-Full` lane, `-InstallHook`, and every bypass (`--no-verify`, `RUST_PORTABLE_CROSS_SKIP_CI`, `git config --unset core.hooksPath`).

## 8. Final verification

- [x] 8.1 Run `ci.ps1` and confirm it is green on the final tree, including the new `test/ci.tests.ps1`.
- [x] 8.2 Re-run the whole default lane under codepage 936 as well as 65001, since encoding has already produced one false failure in this repository.
- [x] 8.3 Run `ci.ps1 -Full` once and confirm all four cross-build checks still pass.
