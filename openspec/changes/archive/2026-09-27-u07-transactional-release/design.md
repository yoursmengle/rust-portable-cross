## Context

See proposal.md. The current staging and sysroot locations are fixed public paths; Windows directory replacement requires more than one rename. `build.ps1` writes versioned part names and a fixed public JSON name. Normal builds and release preparation can run from the same root.

## Goals / Non-Goals

**Goals:** Preserve recoverable prior directories, serialize conflicting toolkit work, isolate temporary files, and publish only verified immutable parts.

**Non-Goals:** Change target ABI, package names, CLI switches, or promise a single atomic rename across multiple directories and rustup homes.

## Decisions

- Use a named Windows mutex keyed by SHA-256 of normalized root plus scope. The kernel releases abandoned ownership after process death; a sidecar records PID, process start time, operation, and acquisition time for diagnosis only. PID alone is never used to reclaim a lock. Nested calls in the same PowerShell thread may reenter the mutex.
- Build and verify staging/sysroot in a UUID-named sibling on the same volume. On startup, recover `*.previous` if active is absent. Promotion sets aside active, moves verified next into place, and restores active on a caught failure. Keep one previous generation after success. An interruption in the rename gap is repaired on the next invocation.
- Repair rustup targets in a copied `rustup-home` under the toolkit root. Point rustup commands at the copy, verify all target manifests and compiler commit there, then swap the entire home under the toolkit lock. `cargo-home` remains shared because target repair does not update its executables. Fresh setup uses the lock; later target repair follows the copy path.
- Build scripts take the toolkit mutex while using managed assets. This serializes same-root builds with writers; separate roots hash to different mutex names. The native C wrapper and link probe use UUID-named temporary roots with `finally` cleanup.
- The missing-sysroot negative check calls the exact guard used by the build against an isolated empty toolkit root. It does not rename the working sysroot.
- Split into a private same-volume directory. Verify each part and reconstruct SHA-256; acquire the publication mutex, check any public same-version manifest and existing part filenames, move missing immutable parts, then atomically replace the JSON via `File.Replace` (or rename when absent). Leave prior-version parts; orphaned parts from an interrupted attempt can be reused only after hash validation.

## Risks / Trade-offs

- [A two-step directory swap has a brief missing-path interval] → Hold the toolkit lock, restore on caught failure, and recover `previous` on next start; builds use the same lock.
- [Power loss during a rename can leave private or previous directories] → Recovery prioritizes the prior active state and cleanup only touches validated managed paths.
- [Lock wait can delay builds] → Show the recorded owner/operation and use a finite wait; unrelated roots remain independent.
- [Rustup repair copy is large] → Copy only when payload status is incomplete; keep the usual complete-path fast check.

## Migration Plan

The first run recognizes existing active staging/sysroot directly. No public metadata changes. Existing published manifests remain valid and old versioned parts are retained. Rollback can restore the saved previous directory if needed.
