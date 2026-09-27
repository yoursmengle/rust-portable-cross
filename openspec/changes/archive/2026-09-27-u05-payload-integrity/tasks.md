## 1. Trusted input lock

- [x] 1.1 Record verified Rust/rustup/Zig versions, sources, and archive digests in a version-controlled private lock.
- [x] 1.2 Enforce the lock on cached and freshly downloaded bootstrap and Zig archives, including wrong-version ZIPs.

## 2. End-to-end payload integrity

- [x] 2.1 Generate a private component file index bound to the managed compiler commit after release staging copies finish.
- [x] 2.2 Verify all indexed files and compiler identity before finalization modifies an install, preserving legacy package behavior.
- [x] 2.3 Audit all 13 Windows libraries against provenance hashes in the release check.

## 3. Verification and delivery

- [x] 3.1 Add corruption and cache replacement regression cases, including a nonempty target library and same-name Windows library.
- [x] 3.2 Run PS5.1/PS7 targeted checks, real staging/integrity verification, full CI, and strict OpenSpec validation; sync, archive, and commit.
