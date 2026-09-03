## Context

See proposal.md - Why. The design-relevant facts about this repository:

- Verification is split into two very different populations. The four `test/*.tests.ps1` suites are self-contained (they build their own fixture toolkit roots under `$env:TEMP`) and complete in **6.6 s** together, measured on the development machine: 3.1 s, 1.9 s, 0.6 s, 1.0 s. The four `check_tool_*.ps1` scripts are real cross-compilations of `sample/` and take minutes, and they only work when `tools/` has been populated by `rust_setup.ps1` - a multi-gigabyte tree that `tools/.gitignore` deliberately keeps out of the repository.
- A fresh clone therefore has no toolchain. Anything the gate does by default must work without one.
- Hooks on the developers' machines run under Git for Windows' bundled `sh`, not `cmd` or PowerShell.
- The repository already has a debugged pattern for locating PowerShell from a shim (`tools/wrappers/*.cmd`) and a debugged pattern for reading native-command output on a legacy code page (`check_tool_x64_win.ps1`, which forces `[Console]::OutputEncoding` to UTF-8 around the probe after codepage 936 mangled rustc's output into a false failure).
- Both candidate gates are green today: all 27 tracked `.ps1` files parse, and `openspec validate --all --strict` exits 0.

## Goals / Non-Goals

**Goals:**

- A commit gate fast enough that nobody has a standing reason to disable it - target well under 15 s wall clock for the default lane.
- One command that a developer runs by hand and the hook runs automatically, so there is no second, divergent definition of "verified".
- Correct behaviour in a fresh clone with no toolchain, on a legacy code page, and under Git for Windows' `sh`.

**Non-Goals:**

- Hosted/server-side CI. This is a local gate; nothing here assumes a build server.
- Turning the `check_tool_*.ps1` cross builds into something a commit waits for.
- Static analysis or linting beyond "does this file parse". PSScriptAnalyzer is not installed on the development machine and pulling it in is a separate decision.
- Verifying the staged content in isolation. See Decision 4.

## Decisions

### Decision 1: Two lanes, fast by default

The default lane is script parsing + `test/*.tests.ps1` + OpenSpec validation. The `-Full` lane adds the four `check_tool_*.ps1`.

A commit gate competes directly with the developer's patience: at 6.6 s the tests are cheaper than the commit message; at several minutes they would be bypassed permanently within a week, and a bypassed gate is worse than no gate because it still looks like coverage. Splitting the lanes keeps the expensive, toolchain-dependent checks available under one command without letting them near `git commit`.

*Alternative rejected - one lane running everything*: honest, but guarantees `--no-verify` becomes muscle memory.

*Alternative deferred - full lane on `pre-push`*: plausible and cheap to add later; see Open Questions.

### Decision 2: `core.hooksPath` pointing at a versioned `.githooks/`, not a file written into `.git/hooks`

The hook lives at `.githooks/pre-commit`, tracked in git, and installation is one `git config core.hooksPath .githooks`.

This makes the hook reviewable in diffs and means a fix to the hook reaches every clone through a normal `git pull`. A hook copied into `.git/hooks` is invisible to review and goes stale the moment it is edited, with no way to tell which clones have which version.

The cost is that `core.hooksPath` replaces `.git/hooks` **wholesale**: any other hook a developer has in `.git/hooks` stops firing, silently. This repository ships only unmodified `.sample` files today, so nothing is lost here - but the installer cannot assume that of every clone. It therefore refuses to act when `core.hooksPath` is already set to anything other than `.githooks`, prints what it found, and changes nothing. Setting it to the same value again is a no-op, which is what makes the installer idempotent.

*Alternative rejected - writing `.git/hooks/pre-commit` directly*: no versioning, no review, no update path.

### Decision 3: The hook is POSIX `sh` and locates PowerShell itself

Git for Windows executes hooks through its bundled `sh`, where `pwsh` is frequently not on `PATH`. The hook resolves the interpreter in the same order the repository's existing `.cmd` wrappers use - `pwsh` on `PATH`, then `%ProgramFiles%\PowerShell\7\pwsh.exe`, then `powershell` - because that chain is already proven on these machines.

If no interpreter is found the hook **fails the commit** rather than passing. A PowerShell repository whose developer has no PowerShell is a broken environment, and the failure message names the documented bypass, so this cannot trap anyone.

### Decision 4: Verify the working tree and warn about the gap - do not stash

The gate runs `ci.ps1` against the working tree as it stands, and warns when `git diff --quiet` reports unstaged modifications to tracked files.

The textbook alternative, `git stash --keep-index` around the run, is wrong here specifically. The checks write into `sample/target/` and the toolkit's zig caches; an interrupted or failing run leaves a stash the developer did not create, holding work they will look for in the wrong place. The other alternative - running from a throwaway worktree built from the index - cannot work at all, because the checks need `tools/` and `sample/target/`, neither of which exists in a worktree built from tracked files.

So the gate does the cheap, honest thing: it verifies what is on disk and says so. The warning exists precisely so a green gate is not over-read. This is a real limitation, not a temporary one, and the spec makes the warning a requirement rather than a nicety.

### Decision 5: Run every check, then report

Checks do not short-circuit. Each one's outcome is collected and printed as a summary at the end, with failing checks' output reproduced above it. A developer interrupted by a failed commit should learn everything wrong in one attempt, not discover a second failure after fixing the first.

### Decision 6: Skips are loud and never look like passes

Three ways to not run: `git commit --no-verify` (git's own, nothing to implement), the `RUST_PORTABLE_CROSS_SKIP_CI` environment variable for scripted commits, and an automatic skip while `MERGE_HEAD` or a rebase directory exists so the gate cannot block conflict resolution.

The variable name follows the repository's existing `RUST_PORTABLE_CROSS_*` convention (`RUST_PORTABLE_CROSS_ROOT`, `RUST_PORTABLE_CROSS_SKIP_MAIN`). Every skip prints a line that states verification did not run - never a checkmark, never a "passed". The same rule applies to an individual check that skips for a missing prerequisite: skipped and passed are different words on the summary.

### Decision 7: Force UTF-8 when reading child-process output

`ci.ps1` captures output from `pwsh`, `git`, and `openspec`. On a console running codepage 936 - which is the state of the development machine - .NET decodes those bytes with the legacy code page and mangles any non-ASCII, which has already produced one false failure in this repository. The gate sets `[Console]::OutputEncoding` to UTF-8 around native invocations and restores it in a `finally`, matching what `check_tool_x64_win.ps1` already does.

The gate must also not fail merely because a check printed non-ASCII text.

### Decision 8: OpenSpec validation is a gate, and degrades to a skip

`openspec validate --all --strict --no-interactive` covers both the active changes and the archived-into main specs, and exits 0 today. It belongs in the fast lane because spec artifacts have no other automatic check.

The `openspec` CLI is not part of the repository, so a clone without it must still pass the fast lane: when the executable is not found, the check reports itself skipped with that reason.

### Decision 9: Keep the gate out of the customer payload

`scripts/prepare_offline_release.ps1` copies an explicit allow-list of files, so a new root-level `ci.ps1` and a new `.githooks/` directory are excluded by construction. That is a property worth asserting rather than assuming, so `test/prepare_offline_release.tests.ps1` gains an assertion that neither appears in the staged payload - which also catches a future refactor that switches the packager to a deny-list.

### Decision 10: Run the independent checks concurrently

The suites and the OpenSpec validation are separate processes that share nothing (each builds its own temp root), so `ci.ps1` starts them all and then collects results, putting the lane's cost at the slowest check rather than the sum of all of them. Their output is redirected to files rather than pipes, so no child can block on a full buffer while the runner waits on a different one. The cross builds are the exception and stay sequential: they contend for `sample/target/` and cargo's locks.

This decision was forced by measurement, and it is the reason the budget in Goals is still met. Sequentially, the default lane came to **27 s** once the gate's own suite existed - `test/ci.tests.ps1` alone costs 11-14 s, because testing a gate that spawns processes means spawning processes. Concurrently, and after merging redundant scenarios in that suite, the same lane measures **12 s**. The structural point matters more than the number: the sequential cost grows with every suite added, and the concurrent cost does not.

*Alternative rejected - `ForEach-Object -Parallel`*: PowerShell 7 only, and the hook deliberately falls back to Windows PowerShell 5.1 when `pwsh` is absent. Starting processes and waiting on them works on both.

*Alternative rejected - raising the budget to match the measurement*: the budget is the whole argument for the gate existing in a form people keep. Moving it to fit the first implementation that missed it would have given up the thing being designed for.

### Decision 11: Pin the hook to LF endings

`core.autocrlf` is `true` on the development machine, so a checked-out `.githooks/pre-commit` would arrive with CRLF endings. Git for Windows' `sh` tolerated that in testing, but a shell script whose lines end in a carriage return is relying on leniency, not on a guarantee - and this repository has already lost a day to an encoding assumption that held on one machine and not another. A `.gitattributes` entry marks `/.githooks/**` as `text eol=lf` so every clone gets a hook `sh` can read.

## Risks / Trade-offs

- **The gate slows down enough that developers disable it** -> Keep the default lane's budget explicit (under 15 s; 6.6 s of tests today) and keep the cross builds out of it. If a future check pushes past the budget, it belongs in `-Full`, not in the default lane.
- **`core.hooksPath` silently disables a developer's other hooks** -> The installer refuses to overwrite a hooks path it did not set, and reports what it found. Uninstalling is one documented command: `git config --unset core.hooksPath`.
- **A green gate is mistaken for "this commit is verified"** -> Decision 4; the warning is a spec requirement, not an implementation detail.
- **A test suite leaves state behind and the next run inherits it** -> The suites create and remove their own temp roots. The gate adds nothing shared: it must not write into the repository outside what the checks already write.
- **`rust_setup.tests.ps1` now invokes `zig` for its wrapper behaviour test** -> That test already self-skips when `tools/zig/zig.exe` is absent, which is what keeps the fast lane toolchain-independent. The gate relies on that behaviour, so it is worth re-confirming on a clone without `tools/`.
- **The hook cannot find PowerShell** -> Fails closed with a message naming the bypass (Decision 3). Failing open would mean commits that silently skip verification on exactly the machines where something is already misconfigured.

## Migration Plan

1. Add `ci.ps1`, `.githooks/pre-commit`, and `test/ci.tests.ps1`; run `ci.ps1` by hand and confirm it is green on the current tree.
2. Install locally with `ci.ps1 -InstallHook`, then confirm both directions: a commit is refused while a check fails, and proceeds when they pass.
3. Document the workflow and the bypasses in `README.md`.
4. Each developer opts their own clone in - `core.hooksPath` is per-clone config and cannot be set by a checkout.

**Rollback:** `git config --unset core.hooksPath` disables the gate immediately and completely, with no repository change. Removing the files removes it for everyone.

## Open Questions

- Should the `-Full` lane later be attached to `pre-push`, where a multi-minute run is more tolerable? Deferrable: it changes neither the specs, the structure of `ci.ps1`, nor the task breakdown - a `pre-push` hook would simply invoke the same command with `-Full`.
