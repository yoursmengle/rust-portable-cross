## 1. Shared path policy

- [x] 1.1 Add a PS5.1-compatible managed-path helper for safe relative paths, root boundaries, and reparse points.
- [x] 1.2 Load the helper in the target payload checker and reject malicious rustup manifest entries without leaving the target root.

## 2. Apply before mutations

- [x] 2.1 Preflight every install-layout component and selected name before finalization writes, then delete only validated component-owned files.
- [x] 2.2 Validate release staging copy and cleanup roots and include the helper in the offline core payload.
- [x] 2.3 Apply the same boundary rule to sysroot provenance/cleanup and x64 self-containment checks.

## 3. Verify and finish

- [x] 3.1 Add isolated sentinel cases for traversal, sibling prefix, UNC/drive/ADS, junction, unknown component, and valid subset behavior.
- [x] 3.2 Run focused PS5.1/PS7 tests, full CI, and strict OpenSpec validation, then sync, archive, and commit U06.
