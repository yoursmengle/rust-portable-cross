## Purpose

Keep manifest-driven toolkit verification, installation, staging, and cleanup confined to the intended managed directories, including when metadata is damaged or paths contain traversal and Windows-specific alternate forms.

## ADDED Requirements

### Requirement: Managed relative paths remain inside their root
The toolkit SHALL reject empty, rooted, drive-qualified, UNC, traversal, alternate-data-stream, and unsafe reparse-point paths before using them as managed file entries.

#### Scenario: Traversal or alternate root
- **WHEN** a manifest entry contains `..`, a drive prefix, a UNC prefix, or an alternate data stream
- **THEN** validation rejects it before reading or modifying an asset outside the intended root

#### Scenario: Sibling prefix and junction
- **WHEN** a path names a sibling whose text shares the toolkit-root prefix or traverses a junction to another directory
- **THEN** it is not treated as a file inside the toolkit

#### Scenario: Ordinary managed file
- **WHEN** a normal relative file entry resolves below its expected root without an unsafe reparse point
- **THEN** validation and existing build or install behavior proceed unchanged

### Requirement: Installer validates complete layout before mutation
The offline finalizer SHALL validate every layout component path, component name, and selected component against its published managed area before creating, rewriting, or deleting install files.

#### Scenario: Invalid unselected component entry
- **WHEN** an unselected component lists an escape path or a core file as its payload
- **THEN** finalization fails before the first install modification, and existing files remain unchanged

#### Scenario: Unknown selected component
- **WHEN** `SelectedComponents` names a component absent from the supported layout
- **THEN** finalization fails before modifying the install

#### Scenario: Empty and known selections
- **WHEN** selection is empty or names a published subset
- **THEN** the prior default and subset semantics remain available

### Requirement: Preparation and diagnostics respect managed boundaries
Staging, Windows sysroot provenance, and self-containment checks SHALL use normalized directory-boundary comparisons and SHALL reject unsafe source or cleanup paths.

#### Scenario: Output root and toolkit root overlap unsafely
- **WHEN** release preparation would delete or copy through an unexpected overlapping or reparse-point root
- **THEN** it fails before deleting existing output or reading external assets

#### Scenario: Diagnostic path has sibling prefix
- **WHEN** a host library resolves from a sibling of the toolkit with a similar name
- **THEN** the self-containment check reports it as external
