## Why

The release gate currently proves that the source checkout can build, while the installer consumes a separately copied staging tree. A stale or incomplete staging tree can therefore be compiled into a successful EXE and published without proving that the customer payload works.

## What Changes

- Verify the exact staged file set, pinned toolchain identity, target components, and Windows link-input provenance before compiling an installer, including when `-SkipStaging` is used.
- Assemble an isolated installation from staged core and target components, run the existing finalize and activation flow, and build dependency-free host, Linux, and embedded smoke fixtures with offline Rust/Cargo settings.
- Install the compiled EXE in a disposable location and repeat payload and build checks before exporting or publishing it.
- Treat missing ISCC output and any release verification failure as a failed publication; leave the previous public manifest intact.

## Capabilities

### New Capabilities

- `delivered-release-verification`: A release is publishable only after its staged and actually installed payloads pass isolated offline validation.

### Modified Capabilities

None.

## Impact

`build.ps1`, `scripts/prepare_offline_release.ps1`, a new internal release validation helper, staged smoke fixtures, and release tests. Existing command parameters, layout schema, installer filename, split-part naming, and customer build entry points remain unchanged.
