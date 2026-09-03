## Why

Everything this toolkit guarantees is enforced by PowerShell scripts, and PowerShell has no compiler: a syntax error, a broken generator, or a regressed wrapper reaches `master` looking exactly like working code. The repository already owns the checks that would catch it - four test scripts that run in about 7 seconds total and four `check_tool_*.ps1` cross-build checks - but nothing runs them automatically, so whether a commit is verified depends on who typed it and how much of a hurry they were in.

That gap has already cost real defects. The wrapper generator in `scripts/rust_setup.ps1` silently drifted from the wrappers committed under `tools/wrappers/` across two separate commits (the `zig-lib.ps1` `-out:` handling and the `pwsh` `.cmd` shims); running `rust_setup.ps1` would have reverted both hand-applied fixes with no error. A gate on `git commit` turns "someone remembered to run the tests" into a property of the repository.

## What Changes

- Add `ci.ps1` at the repository root: a single entry point that runs the repository's existing checks as ordered, individually reported gates and exits non-zero if any fail.
  - **Fast lane (default)**: parse every tracked `.ps1` with the PowerShell parser, run the four `test/*.tests.ps1` suites, and run `openspec validate --strict` over active changes. No installed toolchain required, so it works in a fresh clone.
  - **Full lane (`-Full`)**: additionally run the four `check_tool_*.ps1` real cross builds. Requires an installed toolchain under `tools/` and takes minutes, so it is opt-in and never runs from the hook.
- Add a version-controlled `.githooks/pre-commit` that invokes the fast lane, plus `ci.ps1 -InstallHook` to point the clone's `core.hooksPath` at it. Hook installation is an explicit per-clone opt-in, because git config is not something a checkout can set on its own.
- Provide deliberate escape hatches: `git commit --no-verify`, an `RUST_PORTABLE_CROSS_SKIP_CI` environment variable for scripted commits, and an automatic skip while a merge or rebase is in progress so the gate cannot block conflict resolution.
- Report honestly what was verified: the gate runs against the working tree, not the staged index, so it warns when the two differ instead of implying it checked the commit.
- Add `test/ci.tests.ps1` covering the gate's own behaviour, and document the workflow in `README.md`.

## Capabilities

### New Capabilities
- `commit-gate`: a single repository-wide verification entry point and its `git commit` hook - which checks run, in what order, what the exit status means, how the hook is installed and bypassed, and what the gate must tell the developer about the difference between the working tree and the commit.

### Modified Capabilities

None. This change adds a way to run existing checks automatically; it does not alter what any of those checks assert.

## Impact

- **New files**: `ci.ps1`, `.githooks/pre-commit`, `test/ci.tests.ps1`.
- **Modified files**: `README.md` (developer workflow section); `.gitignore` only if the gate needs a scratch location.
- **Existing checks**: `test/*.tests.ps1` and `check_tool_*.ps1` are invoked, not modified. The gate depends on their exit codes, which makes "this script exits non-zero on failure" a contract rather than an incidental behaviour.
- **Per-clone git config**: `core.hooksPath` is set only by an explicit `ci.ps1 -InstallHook`. Because `core.hooksPath` overrides `.git/hooks` wholesale, the installer must refuse to clobber an existing hooks path it did not set.
- **Release packaging**: `ci.ps1` and `.githooks/` are development-time files and must stay out of the customer payload assembled by `scripts/prepare_offline_release.ps1`.
- **No runtime impact**: nothing here ships to users or changes any produced binary.
