## MODIFIED Requirements

### Requirement: Fast lane runs without an installed toolchain

The verification command SHALL have a default lane that requires no installed cross-compilation toolchain, so it succeeds in a freshly cloned repository where `tools/` has not been populated. The default lane SHALL cover, at minimum:

- that every PowerShell script tracked in the repository parses,
- that every toolkit path quoted in tracked documentation resolves, and that tracked documentation carries no disallowed control characters,
- that every test suite under `test/` passes,
- that OpenSpec artifacts for active changes validate.

Checks in the default lane that genuinely require an absent toolchain SHALL report themselves as skipped, naming what was missing. A skip SHALL NOT be reported as a pass and SHALL NOT fail the run.

#### Scenario: Fresh clone with no toolchain installed

- **WHEN** the default lane runs in a clone where `tools/` contains no downloaded toolchain
- **THEN** it completes with status 0, and any check that needed the toolchain is reported as skipped with the reason

#### Scenario: A script does not parse

- **WHEN** a tracked PowerShell script contains a syntax error
- **THEN** the default lane fails and names the file and the parse error

#### Scenario: Documentation names a path that does not exist

- **WHEN** tracked documentation quotes a toolkit path that the repository does not contain
- **THEN** the default lane fails and names the document, the line, and the unresolved path

#### Scenario: Documentation integrity is checked without a toolchain

- **WHEN** the default lane runs in a clone whose toolchain directories are empty
- **THEN** the documentation check produces a pass or fail verdict rather than a skip
