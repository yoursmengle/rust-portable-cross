## Context

See proposal.md. `rust_target_payload.ps1` is already loaded by setup, staging, and finalization; staging ships it in the core payload. Finalization currently performs cache/config writes before iterating unselected component paths. `check_tool_x64_win.ps1` and the sysroot generator have separate prefix checks. Rustup may legitimately install relative file symlinks such as `cargo.exe` pointing to `rustup.exe`, so a blanket ban on all final file links would break existing installations.

## Goals / Non-Goals

**Goals:** One reusable path policy for metadata reads and managed mutations; full preflight before installer writes; a narrowly scoped component deletion list; isolated sentinel tests.

**Non-Goals:** A filesystem-wide race-proof sandbox or lock protocol; U07 adds writer locking and transaction boundaries. Do not change JSON field names or component selection syntax.

## Decisions

1. Add `rust_path_boundary.ps1` with a lexical `Path.GetFullPath` root-or-root-plus-separator test using ordinal case-insensitive comparison. Reject absolute/drive/UNC/empty/`.`/`..`/ADS and Windows invalid-name forms before joining. Inspect every existing descendant for reparse points. Permit a final file symlink only when explicitly requested for read-only core assets and its target remains a regular file inside the same root; reject junctions and links on mutation paths.
2. Make `rust_target_payload.ps1` load this helper so setup, staging, and finalization share it without additional public commands. Ship the helper alongside the target-payload script in the core payload. The checker applies a manifest entry only when it is beneath the exact target lib directory; malformed entries remain reported in `Invalid` rather than throwing away the whole status result.
3. Preflight the entire install layout immediately after loading it: validate selected names, known component names, every relative file path, and component-specific published prefixes. Produce a validated removal list before calling any function that writes. The finalizer's existing `-Validate` health-check behavior remains warning-based, but an invalid layout is a hard setup error because proceeding could delete files.
4. Apply the helper to release copy sources/destinations and output cleanup. Reject output roots that overlap the toolkit source, including an output ancestor of the source. A normal nested `dist` under source remains allowed; staging deletes only its own known subtree. The sysroot generator's work and lib cleanup remain within its selected ToolkitRoot and reject reparse traversal; U07 later changes their transaction order.
5. Test with temporary roots outside the developer's `tools`, including a sibling-prefix sentinel and junction when Windows permits creating one. Compare sentinel content hashes before and after failed operations. Avoid deleting a target until its resolved absolute path and expected test prefix are checked.

## Risks / Trade-offs

- Rustup symlink shims are valid but can point outside a copied package → allow only read-only final file links whose target is still inside the managed root.
- A path can be swapped after validation → U07's lock/transaction work narrows that race; this change stops malformed paths and existing junctions before mutation.
- Some old malformed layouts may now be rejected → this is intentional for paths that could escape or delete a different component; published normal layouts continue to pass.

## Migration Plan

No interface migration. Add helper to staging core, verify existing finalization and release tests, exercise malicious layouts in temporary roots, then sync, archive, and commit U06 alone.
