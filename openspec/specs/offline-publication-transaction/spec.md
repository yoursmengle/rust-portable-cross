# offline-publication-transaction Specification

## Purpose

Make the public split installer manifest a reliable commit point so downloads never see a newly advertised set of incomplete, mixed, or conflicting parts.

## Requirements

### Requirement: Parts are complete before publication

The publisher SHALL write parts privately, validate their sizes and digests and the reconstructed installer digest, and expose the public manifest only after all named parts are complete.

#### Scenario: Split fails midway
- **WHEN** splitting or validation fails before publication
- **THEN** the prior public manifest and every part it references remain unchanged

#### Scenario: New version succeeds
- **WHEN** all parts match the installer
- **THEN** the existing manifest filename is atomically replaced to refer to the complete new set

### Requirement: A published version can be rebuilt and replaced

The publisher SHALL accept a same-version installer whose bytes differ from the published one, replace that version's parts and manifest, and say that it did so. A rebuild does not reproduce the same bytes, so refusing it would make a version buildable only once. Repeating an identical publication SHALL change nothing.

#### Scenario: Same version rebuilt
- **WHEN** a second installer has the same version and different bytes
- **THEN** its parts and manifest replace the published ones, and the publisher reports the replacement

#### Scenario: Rebuild has fewer parts
- **WHEN** the rebuilt installer splits into fewer parts than the published one
- **THEN** the parts the rebuild no longer has are removed from the published set

#### Scenario: Identical retry
- **WHEN** the same installer is published again
- **THEN** the publisher accepts it without changing the manifest or any part

### Requirement: A failed replacement restores the previous publication

Replacing published parts SHALL be reversible until the manifest is replaced, which SHALL happen last. If any step fails, the publisher SHALL restore every part it set aside, so the previous manifest and the parts it names are usable again. The publisher SHALL NOT modify parts that belong to another version.

#### Scenario: Replacement fails midway
- **WHEN** verification fails after some parts have been replaced
- **THEN** the previous manifest is unchanged and every part it names has its previous bytes

#### Scenario: Other versions are untouched
- **WHEN** a version is published or replaced
- **THEN** the parts of every other version remain as they were
