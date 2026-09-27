## 1. Bounded dependency payload

- [x] 1.1 Implement lockfile-selected Cargo registry copying, checksum verification, and dependency/license manifest generation.
- [x] 1.2 Add the selected files and generated manifest to staged layout and payload integrity verification without copying personal Cargo state.

## 2. Installed release gate

- [x] 2.1 Build the complete sample on supported host/Linux targets from staged and installed roots with isolated offline Cargo settings.
- [x] 2.2 Add meaningful missing/corrupt dependency and clean-cache regression checks; update customer dependency documentation.

## 3. Verification and publication

- [x] 3.1 Run relevant CI and an actual installer validation, then sync specifications, archive the change, and commit only its files.
