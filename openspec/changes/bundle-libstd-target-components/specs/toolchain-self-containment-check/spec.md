## MODIFIED Requirements

### Requirement: Self-containment is enforced at release time

Producing an offline release package SHALL run the self-containment check and the required target
payload check, and SHALL abort if either check fails, so a package that depends on host tooling or
omits a required Rust standard-library component is never published.

#### Scenario: Release blocked by a failing check

- **WHEN** the offline release pipeline runs and the self-containment check or target payload check
  fails
- **THEN** the pipeline SHALL abort before writing the release package
- **AND** the failing check's output SHALL be surfaced to the operator

#### Scenario: Release blocked by metadata-only target state

- **WHEN** rustup metadata lists a required target but the target libdir lacks a complete payload
- **THEN** the offline release pipeline SHALL abort or repair before packaging
- **AND** it SHALL identify the target and missing `libstd`/supporting files

#### Scenario: Verification of a produced package

- **WHEN** an operator verifies a produced offline package on a machine with no Visual Studio, no
  Windows SDK, and no network access
- **THEN** installing the package and running the self-containment and target payload checks SHALL
  succeed without network access
