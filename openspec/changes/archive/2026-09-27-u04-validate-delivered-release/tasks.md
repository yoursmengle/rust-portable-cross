## 1. Staged payload gate

- [x] 1.1 Verify reused and newly prepared staging version, index, pinned tools, target payloads, and Windows provenance without modifying staging.
- [x] 1.2 Add dependency-free host build-script/proc-macro smoke fixture to the staged core.

## 2. Installed-view validation

- [x] 2.1 Assemble all staged components in an isolated install root and run the shipped finalizer strictly.
- [x] 2.2 Run host Windows C, ARMv7, AArch64, and embedded BIN/HEX smoke builds from an environment with only installed toolkit tools, offline Cargo, and rustup auto-install disabled.

## 3. Actual EXE gate

- [x] 3.1 Require the expected ISCC EXE and install it into a disposable location before export or publication.
- [x] 3.2 Verify that installed EXE payload with the same strict checks, preserving and restoring any existing per-user AppId registration and PATH.

## 4. Verification and delivery

- [x] 4.1 Test stale/tampered staging, missing EXE, and failed smoke with previous manifest preservation in isolated fixtures.
- [x] 4.2 Run actual staging, assembled-view, and EXE install checks plus Full CI and strict OpenSpec validation; sync, archive, and commit.
