## 1. Shared coordination

- [x] 1.1 Add a normalized-root process mutex with owner/start-time diagnostics and abandoned-lock recovery.
- [x] 1.2 Coordinate setup, sysroot generation, staging, repair, and the four build entries with the toolkit lock.

## 2. Recoverable toolkit state

- [x] 2.1 Build and verify Windows sysroot in a same-volume private sibling, then promote with previous-state recovery.
- [x] 2.2 Build and verify staging in a same-volume private sibling, then promote with previous-state recovery.
- [x] 2.3 Repair missing Rust target components in a copied rustup-home and promote only after validation.
- [x] 2.4 Make native wrapper and self-containment probe temporary roots unique; keep the negative test away from the live sysroot.

## 3. Publication

- [x] 3.1 Split and validate privately, then publish immutable versioned parts with same-version conflict detection.
- [x] 3.2 Replace the public manifest only after all referenced parts are complete and verified; report publication success only then.

## 4. Verification and delivery

- [x] 4.1 Test interrupted promotion, occupied destinations, abandoned locks, concurrent roots, split failures, and same-version retries/conflicts in isolated directories.
- [x] 4.2 Run PS5.1/PS7 targeted tests, real staged preparation, Full CI, strict OpenSpec validation; sync, archive, and commit.
