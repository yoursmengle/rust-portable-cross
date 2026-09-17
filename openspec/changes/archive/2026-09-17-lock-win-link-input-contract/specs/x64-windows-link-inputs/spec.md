## ADDED Requirements

### Requirement: The link-input sysroot location is a published contract

The location and shape of the Windows link-input sysroot SHALL be a stated external contract, not an
implementation detail. Integrating tools SHALL be able to determine whether an installation can link
for `x86_64-pc-windows-msvc` by inspecting that location alone, without invoking a build.

The contract SHALL be: the sysroot for a target lives at `tools/sysroot/<target-triple>/` beneath the
toolkit root, its import libraries and runtime shim live directly in that directory's `lib/`
subdirectory as a flat set of `.lib` files, and a machine-readable manifest sits alongside `lib/`
naming every file the sysroot ships together with the source and licence it derives from.

The toolkit SHALL NOT relocate this path, nest the libraries more deeply, or split them across
subdirectories without treating the move as a breaking change to the contract. The toolkit SHALL NOT
publish the sysroot under a second path as a compatibility alias.

#### Scenario: A downstream tool probes an installation for readiness

- **WHEN** an integrating tool inspects an installation at the contracted sysroot path
- **THEN** it SHALL find the import libraries and the runtime shim as flat `.lib` files in `lib/`
- **AND** it SHALL find the manifest alongside `lib/`
- **AND** the presence of those files SHALL be sufficient to conclude that the installation can link
  for the target without a Visual Studio or Windows SDK installation

#### Scenario: Documentation and packaging agree with the contract

- **WHEN** the documented sysroot path, the path the build scripts add to the linker search, and the
  paths listed in the install layout manifest are compared
- **THEN** all three SHALL name the same location
- **AND** that location SHALL be the contracted path

#### Scenario: No compatibility alias is shipped

- **WHEN** an installation is inspected for the sysroot
- **THEN** the link inputs SHALL be present at exactly one location
- **AND** no duplicate or aliased copy of them SHALL exist elsewhere in the installation

### Requirement: The route to self-containment is recorded with its alternatives

The toolkit SHALL carry a written record of how it satisfies the Windows link inputs and why the
alternatives were declined, so the decision is auditable and does not have to be re-derived.

The record SHALL state that the link inputs are generated from assets bundled with the toolkit; that
obtaining Microsoft's own CRT and SDK libraries on the user's machine was declined because it
requires network access and licence acceptance on machines the product exists to serve offline; and
that switching the delivered target to the GNU ABI was declined because it changes the ABI of the
delivered artefact and reverses a prior deliberate migration.

The record SHALL also state the limitation the chosen route retains: a crate whose C code requires
Microsoft's own headers still needs a host MSVC installation, and this surfaces as a compile error
naming a missing header, not as a link error.

#### Scenario: An integrator asks why a given route was not taken

- **WHEN** a reader consults the record for the reasoning behind the current approach
- **THEN** the record SHALL name each declined alternative and the reason it was declined
- **AND** it SHALL state the retained limitation and how that limitation presents itself

## MODIFIED Requirements

### Requirement: Documentation states the actual host requirements

Product documentation SHALL describe the host prerequisites for `x86_64-pc-windows-msvc` builds
accurately, and SHALL NOT claim host independence that the shipped package does not deliver.
Documentation for the cross targets SHALL also state that host build scripts and proc-macros are
linked with the bundled Windows link inputs and need no Visual Studio or Windows SDK installation.

Every toolkit path the documentation quotes SHALL resolve, so that a reader who follows a documented
path finds what the documentation says is there.

#### Scenario: Offline README describes x64 host requirements

- **WHEN** a reader consults the offline documentation for the `x86_64-pc-windows-msvc` target
- **THEN** the documentation SHALL state that no Visual Studio, MSVC linker, or Windows SDK
  installation is required
- **AND** it SHALL name the supported Windows versions on which the produced executables run

#### Scenario: Offline README describes cross-target host linking

- **WHEN** a reader consults the offline documentation for `thumbv7em-none-eabihf` or another
  shipped cross target
- **THEN** the documentation SHALL state that cargo still links host build scripts as
  `x86_64-pc-windows-msvc` binaries
- **AND** it SHALL state that those host links use the bundled Windows link inputs and need no
  Visual Studio or Windows SDK installation

#### Scenario: Reader follows a documented path

- **WHEN** a reader follows any toolkit path the offline documentation quotes — the sysroot
  directory, a build script, or the link-input regeneration command
- **THEN** the path SHALL name a file or directory the installation actually contains
