## Why

The installer and target-payload checker currently trust manifest paths after a prefix test or direct join. A damaged or crafted layout can escape the toolkit root or delete another managed asset, and a string prefix check can treat a sibling directory as part of the toolkit.

## What Changes

- Validate managed relative paths, normalized root boundaries, and reparse points before using layout or rustup manifest entries.
- Validate every install-layout component and selected component before the first install write or deletion; restrict component removal to its own published files.
- Apply the same boundary rule to staging copies, sysroot provenance and output cleanup, and self-containment checks.
- Add isolated sentinel tests for traversal, drive/UNC, ADS, sibling-prefix, and junction cases.

## Capabilities

### New Capabilities

- `managed-path-boundaries`: Untrusted metadata and user-selected roots cannot move verification or mutation outside the intended managed tree.

### Modified Capabilities

None.

## Impact

Adds an internal path helper to scripts and the offline core payload; updates target payload verification, finalization, release staging, Windows sysroot generation, and self-checks. Public commands, selected component names, layout fields, and paths remain unchanged.
