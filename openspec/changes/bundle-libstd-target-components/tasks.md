## 1. Add the shared target-payload contract

- [x] 1.1 Add `scripts/rust_target_payload.ps1` with the host, ARMv7, AArch64, and thumb target
      definitions, including the hosted-vs-`no_std` requirement distinction.
- [x] 1.2 Implement manifest inventory validation that rejects missing/empty files and checks the
      required `libstd` or core/alloc/compiler-builtins anchor artifacts.
- [x] 1.3 Return target-specific diagnostics and managed `rustc --print target-libdir` paths without
      consulting ambient/system Rust installations.

## 2. Enforce the contract in setup and activation

- [x] 2.1 Integrate the helper into `scripts/rust_setup.ps1` after toolchain/target installation;
      repair incomplete host/cross components through the existing managed rustup commands, then
      fail if the payload remains incomplete.
- [x] 2.2 Integrate the helper into `scripts/rust_env.ps1` as a local, non-networking warning so a
      damaged installed target is diagnosed before cargo reports a missing `std` crate.
- [x] 2.3 Print the managed `rustc -vV` version/commit evidence alongside the payload verdicts.

## 3. Gate offline packaging and installation

- [x] 3.1 Replace `prepare_offline_release.ps1`'s directory/manifest-only test with the shared
      payload check and preserve its auto-heal path for incomplete targets.
- [x] 3.2 Include the shared helper in the always-installed release payload and required-input list,
      so customer validation does not depend on repository-only files.
- [x] 3.3 Run the same no-network payload validation from `finalize_offline_install.ps1`, preserving
      bounded warning/reporting behaviour and naming the affected target/file.

## 4. Add regression coverage

- [x] 4.1 Extend `test/rust_setup.tests.ps1` with fixture-based checks for complete hosted payloads,
      missing `libstd`, missing supporting files, the thumb `no_std` exception, and managed-toolchain
      path selection.
- [x] 4.2 Update `test/prepare_offline_release.tests.ps1` fixtures and assertions to use real
      `libstd-*.rlib/.rmeta` names and verify incomplete payloads are repaired or rejected before
      staging.
- [x] 4.3 Extend `test/finalize_offline_install.tests.ps1` to verify installed validation accepts a
      complete payload, reports a metadata-only hosted target, and accepts thumb without `libstd`.

## 5. Verify the change

- [x] 5.1 Run the targeted PowerShell test suites and `./ci.ps1` (default lane).
- [x] 5.2 With a provisioned toolchain, run the three hosted `cargo check --target` commands and the
      thumb embedded smoke check from the existing scripts.
- [x] 5.3 Run `openspec validate --all --strict` and confirm no existing link-input or installer
      component contract was changed unintentionally.
