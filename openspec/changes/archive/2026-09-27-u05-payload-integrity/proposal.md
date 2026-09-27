## Why

The setup path accepts a cached or mirrored bootstrap without a fixed checksum, and a readable Zig ZIP can contain the wrong payload. Release staging currently accepts nonempty Rust target files and Windows libraries without checking their content against a recorded compiler or source.

## What Changes

- Pin the Rust bootstrap and Zig archive to independently published SHA-256 values and validate cached and downloaded copies before use.
- Bind staged managed files to the installed compiler commit in a private integrity index and verify that index before release or installation.
- Audit every published Windows import library against its provenance hashes, while retaining the existing quick target check during normal activation.
- Keep all existing command parameters, target layout, and published JSON fields unchanged.

## Capabilities

### New Capabilities

- `toolkit-payload-integrity`: Pinned downloads and verifiable staged toolchain files.

### Modified Capabilities

None.

## Impact

Touches setup download validation, staging/finalization, Windows link-input verification, internal metadata, and regression tests. It adds only private internal files; callers keep the current interface.
