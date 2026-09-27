## Why

`rust_setup.ps1` installs Rust, Zig, and wrappers but does not generate the Windows link-input sysroot required by every build, including cross builds with host build scripts. A fresh source checkout can report setup success and still fail on its first build.

## What Changes

- Make the existing setup entrypoint generate or repair the bundled Windows sysroot once its compiler inputs are ready.
- Verify the managed executables, linker, objcopy, target payloads, wrappers, and Windows link inputs before reporting setup complete.
- Keep repeated setup idempotent while retaining `-Force`'s current Cargo cache reset semantics.
- Add a no-network test path using fake managed tools and a real bundled Zig integration check where available.

## Capabilities

### New Capabilities

- `toolkit-setup-completeness`: Successful first-time setup yields the complete managed toolchain needed by all existing build entrypoints and repairs missing assets on a repeated run.

### Modified Capabilities

None.

## Impact

Changes `scripts/rust_setup.ps1`, setup tests, and setup documentation. Existing parameters, target triples, toolchain version, sysroot path, wrapper names, and external messages remain compatible.
