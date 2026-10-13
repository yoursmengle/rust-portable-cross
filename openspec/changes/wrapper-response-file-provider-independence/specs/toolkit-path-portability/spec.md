# Spec Delta

## ADDED Requirements

### Requirement: Response file detection is independent of PowerShell drive state
The Linux cross-compiler wrappers SHALL recognize an `@<path>` argument as a response file whenever the operating system can open `<path>` as a file, regardless of which PowerShell drives are mounted in the wrapper's process.

#### Scenario: Volume has no PowerShell drive
- **WHEN** a wrapper receives `@<path>` for an existing file on a volume that has no PowerShell drive in the wrapper's process, and the file contains `-Wl,--fix-cortex-a53-843419`
- **THEN** the wrapper filters the file and the bundled compiler does not report an unsupported linker argument

#### Scenario: Argument is not a file
- **WHEN** a wrapper receives an `@<path>` argument where `<path>` is a directory or does not exist
- **THEN** the wrapper forwards the argument unchanged

#### Scenario: Short command line
- **WHEN** a link command is short enough to arrive as plain arguments without a response file
- **THEN** the wrapper filters and forwards the arguments exactly as it did before this requirement

### Requirement: Response files are filtered by whole lines
The Linux cross-compiler wrappers SHALL treat each line of a response file as one opaque argument. A wrapper SHALL only drop a whole line or rewrite the comma-separated list of a `-Wl,` line, and SHALL forward every other line byte for byte without decoding escapes or adding or removing quotes.

#### Scenario: rustc-escaped line
- **WHEN** a response file contains a line in rustc's format, with a backslash before each backslash and each space, such as `C:\\dir\\sp\ ace\\a.o`
- **THEN** the forwarded response file contains that line unchanged

#### Scenario: Pre-processed quoted line
- **WHEN** a response file contains a line already rewritten by a consumer, with literal backslashes and the whole argument in double quotes, such as `"C:\dir\sp ace\a.o"`
- **THEN** the forwarded response file contains that line unchanged

#### Scenario: Rejected linker flag on its own line
- **WHEN** a response file contains the line `-Wl,--fix-cortex-a53-843419`
- **THEN** the forwarded response file omits that line and keeps every other line in its original order

#### Scenario: Rejected linker flag inside a list
- **WHEN** a response file contains a `-Wl,` line that lists a rejected flag together with other linker arguments
- **THEN** the forwarded line keeps the other linker arguments in order and omits only the rejected flag

### Requirement: Rewritten response files have a fixed location and encoding
When filtering changes a response file, the wrappers SHALL leave the original untouched and write the result to `<original path>.zig-cc` in the same directory, encoded as UTF-8 without a byte order mark and with LF line endings, and SHALL pass that file to the bundled compiler. When filtering changes nothing, the wrappers SHALL pass the original response file and SHALL NOT create a copy.

#### Scenario: Filtering removes a line
- **WHEN** a wrapper drops or rewrites at least one line of the response file at `<path>`
- **THEN** `<path>.zig-cc` exists beside it as UTF-8 without a byte order mark and with LF line endings, the file at `<path>` is unmodified, and the bundled compiler is given `@<path>.zig-cc`

#### Scenario: Nothing to filter
- **WHEN** no line of the response file at `<path>` needs to be dropped or rewritten
- **THEN** the bundled compiler is given `@<path>` and no `<path>.zig-cc` file is created
