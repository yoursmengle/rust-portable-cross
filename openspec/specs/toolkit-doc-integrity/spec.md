# toolkit-doc-integrity Specification

## Purpose

Keeps the documentation this toolkit ships to customers honest about its own contents: every
toolkit path the documentation quotes resolves to something that exists, and no document reaches a
customer carrying characters that a text-escape accident silently substituted for a path separator.

## Requirements

### Requirement: Documented toolkit paths resolve

Every path into the toolkit that **instructional** documentation presents to a reader as a literal
path SHALL name a file or directory that the repository actually contains, or that a documented
command creates. A path that resolves only on the author's machine, or that does not resolve at all,
SHALL be treated as a defect in the documentation.

#### Scenario: Documentation names a path that does not exist

- **WHEN** instructional documentation quotes a toolkit-relative path for which the repository has no
  corresponding file or directory
- **THEN** the check SHALL fail
- **AND** the failure SHALL name the document, the line, and the path that did not resolve

#### Scenario: Documentation names only paths that exist

- **WHEN** every toolkit-relative path quoted in instructional documentation resolves
- **THEN** the check SHALL pass and SHALL report how many paths it resolved

#### Scenario: Path into a real toolkit directory

- **WHEN** documentation quotes a path whose leading directory does exist in this repository, but
  whose remaining segments do not resolve
- **THEN** the check SHALL fail and name it

### Requirement: Path resolution covers instructional documentation only

Instructional documentation is the documentation that tells a reader what to run or where to look:
the repository's front page and the documentation shipped to customers. Planning records,
specifications, and correspondence received from or addressed to another team SHALL NOT be in scope
for path resolution.

#### Scenario: Planning record naming a path that no longer exists

- **WHEN** an archived planning record or a received handoff document quotes a path that the
  repository does not contain
- **THEN** the check SHALL NOT report it
- **AND** the document SHALL still be checked for control characters

### Requirement: Records keep the paths they were written with

The check SHALL NOT require planning records, specifications, or correspondence to be
corrected. Those documents legitimately name paths that do not exist here — a path
as it stood before a rename, a path a rejected proposal would have created, a source file in another
project — and failing on them would force the rewriting of records whose value is that they were not
rewritten.

#### Scenario: Record names a path from before a rename

- **WHEN** an archived planning record quotes a path as it stood before a rename
- **THEN** the check SHALL NOT fail
- **AND** the record SHALL NOT need to be edited for the check to pass

### Requirement: Paths are identified by their documented form

The check SHALL identify a path by the form the documentation itself gives it — a code span holding
a toolkit-relative path — rather than by a hand-maintained list, so a newly documented path is
covered the moment it is written.

#### Scenario: Newly documented path

- **WHEN** instructional documentation gains a code span holding a toolkit-relative path
- **THEN** the check SHALL resolve that path without any list of paths being updated

### Requirement: Paths the repository cannot contain are not reported

Paths the repository cannot be expected to contain SHALL NOT be reported. These classes fall under
this: paths under directories that only exist after the toolchain is downloaded or a release is
staged; paths written as placeholders for the reader to substitute; paths into a different
repository, which this repository has no way to resolve; paths carrying a trailing line or line-range
reference; and paths under the version-control system's own directory.

#### Scenario: Path under a directory that installation populates

- **WHEN** documentation quotes a path beneath a directory that only exists after the toolchain is
  installed or a release is staged
- **THEN** the check SHALL NOT report it as missing

#### Scenario: Placeholder path

- **WHEN** documentation quotes a path containing a reader-substituted placeholder
- **THEN** the check SHALL NOT report it as missing

#### Scenario: Path with a line reference

- **WHEN** documentation quotes a path followed by a line number or line range
- **THEN** the check SHALL resolve the path itself and disregard the line reference

#### Scenario: Path into another repository

- **WHEN** documentation addressed to an integrating team quotes a path whose leading directory does
  not exist in this repository at all, because the path belongs to a different repository
- **THEN** the check SHALL NOT report it as missing

### Requirement: Wildcard paths are matched as patterns

A path written as a wildcard pattern SHALL be treated as a pattern: the check SHALL require that it
match at least one file, rather than requiring a file of that literal name.

#### Scenario: Wildcard pattern that matches

- **WHEN** instructional documentation quotes a wildcard pattern for which at least one file exists
- **THEN** the check SHALL NOT report it as missing

#### Scenario: Wildcard pattern that matches nothing

- **WHEN** instructional documentation quotes a wildcard pattern that matches no file
- **THEN** the check SHALL fail and name it

### Requirement: Shipped documentation is free of control characters

**Every** tracked document SHALL contain no control characters other than the line terminators and
the horizontal tab — this requirement, unlike the one above, is not narrowed to instructional
documentation, because an escape accident is a defect wherever it lands and costs nothing to detect.
A line terminator SHALL itself be well formed: a carriage return that is not followed by a line feed
is a defect.

#### Scenario: A document carries a stray carriage return

- **WHEN** a tracked document contains a carriage return that is not followed by a line feed
- **THEN** the check SHALL fail and name the document and the line

#### Scenario: Clean documentation

- **WHEN** no tracked document contains a disallowed control character
- **THEN** the check SHALL pass

### Requirement: Both control-character ranges are rejected

Both the C0 range and the C1 range SHALL be rejected: the two defects this
requirement exists to prevent are a backslash escape decoded into a backspace and a backslash escape
decoded into a C1 character, and each one turns a correct path into one the reader cannot follow while
remaining invisible in most viewers.

This is the check that catches an escape-mangled path even when the mangled path lies under a
directory that the repository does not track, where no existence check can reach it.

#### Scenario: A document carries a C0 control character

- **WHEN** a tracked document contains a control character in the C0 range outside the permitted set
- **THEN** the check SHALL fail
- **AND** the failure SHALL name the document, the line, and the offending character by code point

#### Scenario: A document carries a C1 control character

- **WHEN** a tracked document contains a character in the C1 range
- **THEN** the check SHALL fail
- **AND** the failure SHALL name the document, the line, and the offending character by code point

### Requirement: The check runs without a toolchain or network

The documentation-integrity check SHALL run to a verdict in a freshly cloned repository where no
toolchain has been downloaded and no network is available, because a check that only runs on a fully
provisioned machine will not run on the commit that introduces the defect.

#### Scenario: Fresh clone

- **WHEN** the check runs in a clone whose toolchain directories are empty
- **THEN** it SHALL complete with a pass or a fail verdict, and SHALL NOT report itself as skipped
