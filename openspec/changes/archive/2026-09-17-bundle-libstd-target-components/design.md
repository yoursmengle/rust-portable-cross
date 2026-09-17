## Context

See `proposal.md` and the new `rust-std-target-components` spec. The repository already installs
the host toolchain with `rustup`, adds the three cross targets in `scripts/rust_setup.ps1`, and
reuses the same managed homes while staging an offline release. The weak point is the success
criterion: setup checks `rustup target list --installed`, while release staging checks only a target
directory and `manifest-rust-std-*`. Neither proves that the files listed by the manifest are present
and usable. The checked-in toolchain confirms the intended shape: hosted targets contain both
`libstd-*.rlib` and `libstd-*.rmeta`; `thumbv7em-none-eabihf` contains core/alloc/compiler-builtins
but no `libstd`.

## Goals / Non-Goals

**Goals:**

- Make one payload definition and one completeness check the source of truth for setup, activation,
  offline staging, and installed-package validation.
- Preserve the existing rustup repair path and offline package component names.
- Produce target-specific diagnostics that distinguish metadata-only state, missing files, and the
  intentional `no_std` thumb target.
- Keep verification local and deterministic once the managed toolchain files are present.

**Non-Goals:**

- Do not invent or copy a `libstd` file, rebuild Rust standard libraries, or add a new dependency.
- Do not change target triples, rustup distribution mirrors, linker/sysroot behavior, or installer
  component selection.
- Do not make the thumb target require `libstd` merely because its package is named `rust-std`.

## Decisions

### Use a small shared payload helper

Add a minimal `scripts/rust_target_payload.ps1` helper containing the target matrix and pure path
inspection functions. The helper returns a result with the target triple, resolved libdir,
manifest path, missing/empty manifest files, and missing required library families. `rust_setup.ps1`,
`rust_env.ps1`, `prepare_offline_release.ps1`, and `finalize_offline_install.ps1` dot-source it.
This avoids four slightly different definitions while keeping the helper free of network or global
environment side effects.

*Alternative considered:* duplicate a few `Test-Path` checks in each script. Rejected — the host
triple and the `no_std` exception would drift, recreating the bug this change is meant to remove.

### Treat the rustup manifest as the inventory, with explicit anchor artifacts

For each target, read `manifest-rust-std-<triple>` and require every `file:` entry to exist and be
non-zero. Additionally require both `libstd-*.rlib` and `libstd-*.rmeta` for hosted targets, and
`libcore-*`, `liballoc-*`, and `libcompiler_builtins-*` for all four targets. The manifest catches a
partial component; the anchor patterns make the user-facing failure unambiguous and stop a malformed
or empty manifest from passing.

*Alternative considered:* only look for one `libstd` file. Rejected — it misses dependent-file loss
  and accepts a metadata-only or otherwise partial target payload.

### Repair only through the existing managed rustup homes

Setup keeps using `rustup target add` for cross targets and uses the managed host component repair
for `rust-std-x86_64-pc-windows-msvc` when the host payload is damaged. A damaged component is first
removed through the same managed rustup home, then added again; this prevents an ``up to date``
metadata record from short-circuiting the repair. Offline staging runs the same check before copying
files, repairs incomplete targets, then re-checks. No system `rustc`, system `RUSTUP_HOME`, or ambient
target directory is accepted as evidence.

### Keep activation diagnostics lightweight

`rust_env.ps1` runs the helper after selecting the managed toolchain. It warns with the target and
missing artifact when a payload is incomplete, preserving its current role as an environment setup
script while making the failure visible before `cargo` emits `can't find crate for std`. The release
and installer validation paths remain the hard gates; the activation warning does not add network
activity.

### Test the helper with filesystem fixtures, then retain one real smoke check

Extend the existing PowerShell test scripts with temporary toolchain trees containing small,
non-empty fixture files and manifests. Cover a complete hosted target, missing `libstd`, a missing
manifest-listed dependency, the thumb `no_std` exception, and the managed-path/version boundary.
Keep the existing cross-build checks as the end-to-end proof that a provisioned real toolchain can
compile; the new unit fixtures do not require downloads.

## Risks / Trade-offs

- **A future Rust release adds a manifest entry or changes a library filename.** → The manifest is
  the inventory, while the explicit anchors are stable names required by the documented contract;
  update only the helper's anchor rules if Rust changes the contract.
- **Validation finds a damaged installation after files were already unpacked.** → The installer
  keeps its existing bounded, warning-based validation behaviour and records the target-specific
  diagnostic in `install-validation-warning.txt`; release staging remains a hard gate.
- **A manifest could be present but use malformed lines.** → Ignore no `file:` entries silently:
  malformed or empty inventory lines produce a failure naming the manifest.
- **Checking every manifest file adds filesystem work.** → It is linear in the component file list,
  runs only at setup/staging/validation boundaries, and avoids a slower compile as the first signal.

## Migration Plan

No on-disk migration is required. Existing complete installations continue to pass. On the next
setup or release staging run, an incomplete managed target is repaired through rustup or fails with a
diagnostic before packaging. Rollback is reverting the helper and its callers; no customer payload
format changes.
