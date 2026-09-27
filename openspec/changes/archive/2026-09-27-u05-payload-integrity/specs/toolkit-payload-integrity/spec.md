## Purpose

Ensure the managed compiler, target components, and generated Windows link inputs shipped to customers can be tied to approved downloads and checked for corruption before use.

## ADDED Requirements

### Requirement: Setup accepts only pinned bootstrap archives

Setup SHALL check the SHA-256 digest of cached and downloaded rustup-init and Zig archives against version-controlled trusted values before executing or extracting them, regardless of the selected download source.

#### Scenario: Mirror supplies wrong bytes
- **WHEN** a mirror supplies an HTML page, another version, or a modified archive
- **THEN** setup rejects that candidate and does not execute or extract it

#### Scenario: Cached archive is replaced
- **WHEN** a cached bootstrap or Zig archive has a different digest from the lock
- **THEN** setup discards the cache entry and accepts only a matching replacement

### Requirement: Published payload has a private integrity index

New release staging SHALL record the SHA-256 digest of every published managed file and the expected Rust compiler commit in a private index without changing the existing install-layout schema. Publication and installation SHALL verify the index before consuming or mutating the payload. Legacy packages without the private index SHALL retain their existing compatibility checks.

#### Scenario: Nonempty target library is modified
- **WHEN** a staged or installed target library has the right name and nonzero size but different bytes from the integrity index
- **THEN** full verification fails and identifies that file

#### Scenario: Compiler does not match payload
- **WHEN** the managed compiler reports a commit different from the one bound to the index
- **THEN** full verification fails before release or installation modification

#### Scenario: Legacy package
- **WHEN** a previously published package has no private integrity index
- **THEN** its existing manifest, anchor, and nonempty-file checks continue to apply

### Requirement: Windows link inputs are fully audited

Release verification SHALL check each published Windows `.lib` against its recorded provenance digest and retain the existing symbol checks and sysroot location.

#### Scenario: Import library is replaced
- **WHEN** a required import library is replaced by a nonempty file with the same name
- **THEN** the full audit fails even if the quick readiness check would accept its presence
