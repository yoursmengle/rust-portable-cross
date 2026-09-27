## Purpose

Make the public split installer manifest a reliable commit point so downloads never see a newly advertised set of incomplete, mixed, or conflicting parts.

## ADDED Requirements

### Requirement: Parts are complete before publication

The publisher SHALL write parts privately, validate their sizes and digests and the reconstructed installer digest, and expose the public manifest only after all named parts are complete.

#### Scenario: Split fails midway
- **WHEN** splitting or validation fails before publication
- **THEN** the prior public manifest and every part it references remain unchanged

#### Scenario: New version succeeds
- **WHEN** all parts match the installer and no version conflict exists
- **THEN** the existing manifest filename is atomically replaced to refer to the complete new set

### Requirement: Published part names are immutable

The publisher SHALL reject a same-version installer whose bytes differ from the already published installer and SHALL not overwrite any part still referenced by a published manifest. Repeating an identical publication SHALL be safe.

#### Scenario: Same-version conflict
- **WHEN** a second installer has the same version and different bytes
- **THEN** publication fails and the prior manifest and parts remain usable

#### Scenario: Identical retry
- **WHEN** the same installer is published again
- **THEN** the publisher accepts it without changing referenced part bytes
