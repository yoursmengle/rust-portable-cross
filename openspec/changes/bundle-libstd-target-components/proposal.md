## Why

`docs/libstd.md` is substantively correct: a rustup target entry is not proof that the target's
standard-library payload was released, and the three hosted targets need a real, version-matched
`rust-std` payload to compile. The current toolkit checks installed-target metadata and, during
offline staging, only checks target directories/manifests; a partial or corrupted `libstd` payload
can therefore pass preparation and fail later with `can't find crate for std`.

## What Changes

- Define one canonical required-payload table for the host target, the ARMv7 Linux target, the
  AArch64 Linux target, and the `no_std` thumb target.
- Validate target libdirs by payload, not only rustup metadata: hosted targets must contain
  non-empty `libstd-*.rlib` and `libstd-*.rmeta` plus the component's supporting libraries;
  `thumbv7em-none-eabihf` must contain its `libcore`, `liballoc`, and `libcompiler_builtins`
  payloads and must not be treated as broken for lacking `libstd`.
- Make setup, offline release staging, and post-install validation use the same payload check;
  missing or incomplete hosted payloads must trigger the existing rustup target-add repair path,
  then fail with the target and expected files if repair did not produce a complete payload.
- Keep the toolchain/version boundary explicit by checking the payloads through the active
  toolchain's target-libdir and recording the rustc version/commit evidence used by verification.
- Add focused PowerShell regression coverage for valid payloads, missing `libstd`, missing support
  libraries, the `no_std` thumb target, and offline-install/package validation.

## Capabilities

### New Capabilities

- `rust-std-target-components`: every shipped target has the standard-library payload appropriate
  to its execution model, and package/install checks reject metadata-only or partial components.

### Modified Capabilities

- `toolchain-self-containment-check`: release and installed-toolchain verification additionally
  require the hosted target `rust-std` payloads before a toolchain is considered usable.

## Impact

- `scripts/rust_setup.ps1` — shared target payload definitions and setup-time verification.
- `scripts/prepare_offline_release.ps1` — payload-aware repair and staging gates.
- `scripts/finalize_offline_install.ps1` — installed package validation diagnostics.
- `test/rust_setup.tests.ps1`, `test/prepare_offline_release.tests.ps1`, and
  `test/finalize_offline_install.tests.ps1` — regression coverage.
- `openspec/specs/` — one new capability and one delta to the existing self-containment contract.
- No new dependencies, no target-triple changes, and no change to the existing `rustup target add`
  download source or customer component names.
