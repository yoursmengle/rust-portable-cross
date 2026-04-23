# Offline Inno Installer Implementation Plan

Date: 2026-04-23
Depends on: `docs/superpowers/specs/2026-04-23-offline-inno-installer-design.md`

## Objective

Implement a single offline Inno Setup installer for `rust-portable-cross` that installs only the selected target payloads, defaults to `armv7`, supports modify/repair/remove, and never downloads content on the customer machine.

## Scope

This plan covers:

- offline staging generation
- target payload partitioning
- Inno installer authoring
- post-install validation
- customer-facing documentation
- automated tests for staging and offline install behavior

This plan does not cover:

- arbitrary offline crate dependency mirroring for customer projects
- unrelated refactors outside the packaging path

## Deliverables

- `scripts/prepare_offline_release.ps1`
- tests for staging and manifest generation
- `packaging/inno/rust_portable_cross.iss`
- `docs/customer/README-offline.md`
- optional customer entry script refinements if needed for install-root UX
- documentation updates in `README.md`

## Phase 1: Baseline Audit And Partition Rules

Goal: turn the existing repository-local toolkit into an explicit packaging model with deterministic ownership.

Tasks:

1. Enumerate the current `tools/` tree and map files into:
   - core
   - armv7
   - aarch64
   - x64_win
2. Identify which `rustup-home` paths are shared host content versus target-specific content.
3. Identify which wrapper files are always required versus target-gated.
4. Record the partition rules in code-friendly form so the staging script does not rely on ad hoc path checks.
5. Resolve the current Windows target wording mismatch and standardize on `x86_64-pc-windows-gnu`.

Acceptance criteria:

- every staged file class has one owner: shared or exactly one component
- the `x64_win` versus host-content boundary is explicitly documented in code comments or constants
- no packaging logic depends on running `rust_setup.ps1` on the customer machine

## Phase 2: Build The Offline Staging Script

Goal: generate a clean installer input tree from a prepared repository.

Primary file:

- `scripts/prepare_offline_release.ps1`

Tasks:

1. Validate preconditions:
   - required files under `tools/` exist
   - required scripts and config files exist
2. Create a clean `dist/staging/` tree.
3. Copy shared payload into `dist/staging/core/`.
4. Copy target-specific payloads into `dist/staging/targets/<component>/`.
5. Generate per-component file lists.
6. Generate `install-manifest.json` input metadata.
7. Place customer-facing docs and entry scripts into the staged core payload.
8. Emit a summary report with payload counts and sizes per component.

Acceptance criteria:

- rerunning the script produces the same directory shape
- staged output contains no accidental source workspace junk such as sample build outputs unless explicitly intended
- each target component can be reasoned about independently from the generated manifests

## Phase 3: Add Script-Level Tests

Goal: make the packaging split stable and regression-resistant.

Primary file:

- `test/prepare_offline_release.tests.ps1`

Tasks:

1. Add unit tests for partition rule helpers.
2. Add tests for manifest generation structure.
3. Add tests that target-owned files do not leak into other components.
4. Add tests that core-only files are never emitted into target payloads.
5. Add tests for deterministic output given a fixed sample input tree.

Acceptance criteria:

- tests fail if a file changes owner unexpectedly
- tests fail if generated manifest shape changes unintentionally
- tests run without requiring network access

## Phase 4: Author The Inno Installer

Goal: produce one offline `setup.exe` from the staged payload.

Primary file:

- `packaging/inno/rust_portable_cross.iss`

Tasks:

1. Define application metadata and version wiring.
2. Define install scope behavior for per-user and per-machine installs.
3. Define components:
   - core
   - armv7
   - aarch64
   - x64_win
4. Mark `armv7` selected by default.
5. Wire file copying from `dist/staging/`.
6. Implement Start Menu shortcuts.
7. Implement maintenance mode behavior compatible with rerunning the same installer.
8. Write or update `install-manifest.json` in the install root.
9. Run post-install local validation only.

Acceptance criteria:

- installer can build from a complete `dist/staging/`
- installer does not invoke online bootstrap logic
- installer supports modify/repair/remove flows without full uninstall

## Phase 5: Local Validation Hooks

Goal: verify that the installed toolkit is present and coherent without using the network.

Tasks:

1. Validate required executables exist:
   - `cargo.exe`
   - `rustc.exe`
   - `rustup.exe`
   - `zig.exe`
2. Validate selected wrapper scripts exist.
3. Run read-only commands:
   - `cargo -V`
   - `rustc -V`
   - `rustup target list --installed`
4. Compare installed targets against the selected components.
5. Report actionable local errors on failure.

Acceptance criteria:

- validation only reads local files and local command output
- failures point to missing payload, corrupt payload, or manifest mismatch

## Phase 6: Customer-Facing Documentation

Goal: give customers a concise offline usage path separate from internal setup instructions.

Tasks:

1. Add `docs/customer/README-offline.md`.
2. Explain:
   - install scope options
   - selected target behavior
   - how to activate the environment
   - which build script maps to which target
   - that install is fully offline
3. Update top-level `README.md` to separate:
   - internal toolkit preparation flow
   - customer offline installer flow
4. Correct all Windows target naming to `x86_64-pc-windows-gnu`.

Acceptance criteria:

- customer docs never direct users to run `rust_setup.ps1`
- internal docs and customer docs no longer conflict

## Phase 7: End-To-End Verification

Goal: prove that the installer works in the intended offline delivery model.

Test matrix:

1. Install `core + armv7`
2. Install `core + armv7 + aarch64`
3. Install `core + armv7 + aarch64 + x64_win`
4. Modify an existing install to add `aarch64`
5. Modify an existing install to remove `aarch64` or `x64_win`

Checks:

1. Installed directory contains only expected component files.
2. Start Menu entries are created correctly.
3. Activation script works.
4. `cargo -V`, `rustc -V`, and `rustup target list --installed` succeed.
5. The sample project builds successfully for selected targets.
6. No install or validation step attempts network access.

Acceptance criteria:

- all matrix cases pass on a disconnected machine
- modify flows preserve shared files and only add or remove component-owned files

## Recommended Implementation Order

1. Phase 1: baseline audit and partition rules
2. Phase 2: staging script
3. Phase 3: script-level tests
4. Phase 4: Inno installer
5. Phase 5: local validation hooks
6. Phase 6: customer and top-level docs
7. Phase 7: end-to-end verification and cleanup

## Risks And Mitigations

Risk: `x64_win` ownership is modeled incorrectly because host GNU files are shared.
Mitigation: complete Phase 1 before authoring installer component rules.

Risk: staging may accidentally include mutable caches or unrelated workspace outputs.
Mitigation: use an explicit allowlist-based copy strategy rather than broad recursive copies.

Risk: modify or uninstall may remove shared files.
Mitigation: use generated ownership manifests and test modify/remove flows explicitly.

Risk: documentation may keep pointing customers at the internal bootstrap script.
Mitigation: update customer docs and top-level docs in the same implementation slice.

## Definition Of Done

The work is done when:

- a single offline `setup.exe` can be built from the repository
- the installer defaults to `armv7` and supports optional `aarch64` and `x64_win`
- only selected component files are installed
- rerunning the installer supports modify/repair/remove
- customer installation never requires network access
- documentation reflects the shipped flow
- script-level and end-to-end offline verification pass
