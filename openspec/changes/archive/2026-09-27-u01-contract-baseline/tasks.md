## 1. Snapshot the existing public surface

- [x] 1.1 Record supported entrypoints, parameter signatures, target triples, wrapper names, install paths, and JSON field shapes in a machine-readable fixture.
- [x] 1.2 Record the current installer all-target behavior and preserve the distinct layout default/finalize subset semantics.

## 2. Enforce the baseline

- [x] 2.1 Add a default-lane suite that compares script signatures using PowerShell AST and reports precise differences.
- [x] 2.2 Check published paths, target definitions, installer behavior, and generated metadata keys without requiring a downloaded toolchain.
- [x] 2.3 Test that the suite rejects representative changes to a parameter, a JSON field, and a published path.

## 3. Document and verify

- [x] 3.1 Correct customer and repository guidance to match the installed target behavior without changing the installer.
- [x] 3.2 Run the contract suite, default CI, and strict OpenSpec validation; inspect the resulting diff for unintended public changes.
