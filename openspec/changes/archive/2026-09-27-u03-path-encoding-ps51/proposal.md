## Why

The supported toolkit can fail when its installation, project, or temporary directory contains spaces or non-ASCII text. Host linker flags currently use a whitespace-delimited string, a generated native wrapper embeds a path using ASCII, and release staging calls a .NET API absent from Windows PowerShell 5.1.

## What Changes

- Preserve individual Cargo and linker arguments for Windows host builds with complex paths, while retaining target-specific flag precedence.
- Make generated wrappers work after moving the toolkit and under both PowerShell 5.1 and 7.
- Calculate staging-relative paths with an implementation available on .NET Framework.
- Avoid repeated PATH entries when the same toolkit is activated again and verify the moved installation uses its new root.
- Add path and argument regression tests, including actual host and cross builds.

## Capabilities

### New Capabilities

- `toolkit-path-portability`: Existing commands work with spaces, Unicode, shell metacharacters, and relocation on supported Windows PowerShell versions.

### Modified Capabilities

None.

## Impact

Touches the private build helper, four build scripts, activation, setup-generated wrappers, staging path calculations, and tests. Public command signatures, output names, target triples, and JSON schemas remain unchanged.
