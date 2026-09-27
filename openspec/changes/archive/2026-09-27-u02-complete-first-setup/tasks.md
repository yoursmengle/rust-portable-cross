## 1. Complete setup outputs

- [x] 1.1 Add private setup checks for all managed executables, wrappers, and the full Windows link-input payload.
- [x] 1.2 Generate the existing Windows sysroot when missing or incomplete and verify it before setup reports success.
- [x] 1.3 Preserve repeat-run and `-Force` behavior while rechecking target component payloads.

## 2. Verify behavior

- [x] 2.1 Add isolated tests for complete reuse, missing-file repair, and generator failure without modifying the developer's sysroot.
- [x] 2.2 Verify the shipped toolchain can satisfy the new structural checks and run the existing four-target build lane.

## 3. Document and finish

- [x] 3.1 Update setup guidance to mention Windows link-input preparation and run the default CI and strict OpenSpec checks.
