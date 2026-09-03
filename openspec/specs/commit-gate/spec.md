# commit-gate Specification

## Purpose
Gives the repository one command that decides whether its current state is fit to commit, and attaches that decision to `git commit` so verification stops depending on who remembered to run it.
## Requirements
### Requirement: Single verification entry point

The repository SHALL provide one command that runs its verification checks and reports a single pass/fail verdict. The command SHALL exit with status 0 when every check it ran passed and non-zero when any check failed. It SHALL report each check individually, naming the check and its outcome, so a failure identifies what to fix without re-running anything.

A check that fails SHALL NOT stop the remaining checks from running. A developer SHALL see every failure in the run, not only the first one.

#### Scenario: Every check passes

- **WHEN** the verification command runs against a repository state where every check passes
- **THEN** it reports each check as passed and exits with status 0

#### Scenario: A check fails

- **WHEN** one of the checks fails
- **THEN** the command exits with a non-zero status, names the check that failed, and reproduces enough of its output to diagnose the failure

#### Scenario: Several checks fail

- **WHEN** more than one check fails in the same run
- **THEN** every failing check is reported, not just the first one

### Requirement: Fast lane runs without an installed toolchain

The verification command SHALL have a default lane that requires no installed cross-compilation toolchain, so it succeeds in a freshly cloned repository where `tools/` has not been populated. The default lane SHALL cover, at minimum:

- that every PowerShell script tracked in the repository parses,
- that every test suite under `test/` passes,
- that OpenSpec artifacts for active changes validate.

Checks in the default lane that genuinely require an absent toolchain SHALL report themselves as skipped, naming what was missing. A skip SHALL NOT be reported as a pass and SHALL NOT fail the run.

#### Scenario: Fresh clone with no toolchain installed

- **WHEN** the default lane runs in a clone where `tools/` contains no downloaded toolchain
- **THEN** it completes with status 0, and any check that needed the toolchain is reported as skipped with the reason

#### Scenario: A script does not parse

- **WHEN** a tracked PowerShell script contains a syntax error
- **THEN** the default lane fails and names the file and the parse error

### Requirement: Full lane covers the cross-build checks

The verification command SHALL offer an opt-in lane that additionally runs the toolchain's per-target build checks. That lane SHALL NOT be the default and SHALL NOT run from the commit hook, because it requires an installed toolchain and takes minutes rather than seconds.

When the opt-in lane is requested but the toolchain it needs is absent, the command SHALL fail with a message naming what is missing, rather than silently degrading to the default lane.

#### Scenario: Full lane requested with the toolchain installed

- **WHEN** the verification command is asked for the full lane on a machine with the toolchain installed
- **THEN** it runs the per-target build checks in addition to the default lane, and its verdict reflects all of them

#### Scenario: Full lane requested without the toolchain

- **WHEN** the full lane is requested but the required toolchain is not installed
- **THEN** the command fails and names what is missing, and does not report a pass

### Requirement: Commit hook runs the gate

The repository SHALL provide a version-controlled `git` pre-commit hook that runs the verification command's default lane and blocks the commit when it fails. The hook SHALL be usable on a Windows developer machine where `git` executes hooks through a POSIX shell, and SHALL locate PowerShell itself rather than assuming a particular one is on `PATH`.

Installing the hook SHALL be an explicit, single command, because a checkout cannot configure git on its own. The installer SHALL be idempotent, and SHALL refuse to overwrite an existing hook configuration that it did not install, reporting what it found instead.

#### Scenario: Commit blocked by a failing gate

- **WHEN** a developer with the hook installed runs `git commit` while a check fails
- **THEN** the commit is refused, and the output names the failing check

#### Scenario: Commit allowed by a passing gate

- **WHEN** a developer with the hook installed runs `git commit` while every check passes
- **THEN** the commit proceeds

#### Scenario: Installing over a foreign hook configuration

- **WHEN** the installer runs in a clone that already has a hook configuration this repository did not install
- **THEN** it makes no change and reports what it found

#### Scenario: Re-installing

- **WHEN** the installer runs again in a clone where it has already installed the hook
- **THEN** it succeeds and leaves the clone in the same working state

### Requirement: Deliberate bypass is possible and visible

The gate SHALL be bypassable, because a gate that cannot be bypassed gets uninstalled. `git commit --no-verify` SHALL bypass it, and an environment variable SHALL bypass it for scripted or automated commits.

The gate SHALL skip itself while a merge or rebase is in progress, so it cannot block conflict resolution.

Whenever the gate skips or is bypassed through the environment variable, it SHALL say so on its output. A bypassed run SHALL NOT print anything that could be mistaken for a passing verification.

#### Scenario: Bypass via the environment variable

- **WHEN** a commit is made with the bypass environment variable set
- **THEN** the commit proceeds, and the output states that verification was skipped rather than reporting a pass

#### Scenario: Committing during a merge

- **WHEN** `git commit` runs while a merge or rebase is in progress
- **THEN** the gate skips itself, says so, and the commit proceeds

### Requirement: The gate reports what it actually verified

The gate runs against the working tree, which is not necessarily what is being committed. When the working tree differs from what the commit will contain, the gate SHALL warn that it verified the working tree rather than the staged content, so a passing gate is never read as a stronger guarantee than it is.

#### Scenario: Committing with unstaged changes present

- **WHEN** the gate runs for a commit while tracked files have unstaged modifications
- **THEN** it warns that the working tree, not the staged content, is what was verified

#### Scenario: Working tree matches the commit

- **WHEN** the gate runs with no unstaged modifications to tracked files
- **THEN** it emits no such warning

### Requirement: The gate stays out of the customer payload

The verification command and its hook are development-time files. They SHALL NOT appear in the offline release payload assembled for customers.

#### Scenario: Building the offline release

- **WHEN** the offline release payload is assembled
- **THEN** it contains neither the verification command nor the hook directory

