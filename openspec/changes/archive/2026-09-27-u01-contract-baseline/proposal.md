## Why

The toolkit has multiple published scripts, environment variables, layouts, and JSON consumers, but its default gate does not detect accidental interface drift. Seven P0 improvements require a checked compatibility baseline before internal changes can be reviewed safely.

## What Changes

- Add a repository-local contract inventory covering the existing public entrypoints, parameters, layout paths, output formats, and documented behavior.
- Add executable regression checks to the default CI lane for the stable portions of this contract.
- Reconcile documentation that describes optional installer targets with the installer's current all-target behavior, without changing installation behavior or JSON fields.
- Keep the existing user-edited `codex_no_ask.ps1` outside this change.

## Capabilities

### New Capabilities

- `toolkit-interface-regression`: The repository's default gate detects changes to the supported public scripts, parameter signatures, layout, and external JSON field shapes while requiring no downloaded toolchain.

### Modified Capabilities

None.

## Impact

Adds an internal contract snapshot and a test under `test/`, updates README/customer documentation, and adds a CI check through the existing suite discovery. No public command, parameter, environment variable, directory, target triple, ABI, or JSON field is changed.
