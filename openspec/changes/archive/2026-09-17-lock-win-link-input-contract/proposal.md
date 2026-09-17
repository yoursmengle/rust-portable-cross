## Why

`docs/toolkit-handoff.md` arrived from the HEC side as an untracked problem report: it claims this
toolkit ships a linker but no link inputs, and asks the toolchain side to choose between fetching
Microsoft's CRT and SDK libraries (A) or adding an `x86_64-pc-windows-gnu` target (B). That gap was
already closed, by neither of those routes — commits `53c03d2` through `cd6ab2f` generate MSVC-ABI
import libraries from the mingw-w64 module-definition files bundled inside `tools/zig`, and ship all
14 files in the always-installed `core` component. The report is therefore stale on its main point,
but nobody has told HEC so, and the decision remains undocumented and open to being re-litigated.

What is genuinely unresolved is smaller and more damaging: HEC's readiness probe looks for
`tools/msvc-sysroot` with `sdk/x64` and `lib/x64` — the layout that option A would have produced —
while the toolkit ships `tools/sysroot/x86_64-pc-windows-msvc/lib`. Left alone, HEC reports "missing
link inputs" on a machine whose link inputs are complete and correct. Two customer-facing paths in
`docs/customer/README-offline.md` are also corrupted by backslash escapes, so a customer following
them looks for files that appear not to exist.

## What Changes

- Record the decision: option C (link inputs generated from bundled mingw-w64 definitions) stands;
  options A and B are declined, with the reasoning captured so the question does not reopen.
- Promote the link-input sysroot location from an implementation detail to a **published contract**:
  `tools/sysroot/<target-triple>/lib`, with `PROVENANCE.json` as its machine-readable manifest.
  Downstream integrators may depend on it, and it may not move without notice. No compatibility
  alias at `tools/msvc-sysroot` is added — on Windows that means duplicated files or symlinks
  requiring elevation, and it would freeze xwin's layout into a contract this toolkit does not use.
- Answer the handoff in writing: a reply document stating the current state, the A/B/C verdict, the
  exact path HEC's `TOOLKIT_LINK_INPUT_DIR` should point at, and the one limitation that remains
  (a C build script needing Microsoft's own headers, which is a compile error, not a link error).
- Commit `docs/toolkit-handoff.md` as received, so the reply has something to cite.
- Repair the two corrupted paths in `docs/customer/README-offline.md` (line 69's `\x86` decoded to
  `U+0086`; line 77's `\b` decoded to a backspace).
- Add a documentation-integrity check to the commit gate's default lane: toolkit-relative paths
  quoted in tracked documentation must resolve to real files, and tracked documentation must contain
  no C0 control characters. This is what catches the next escape-mangling before a customer does.

## Capabilities

### New Capabilities
- `toolkit-doc-integrity`: documentation shipped to customers names paths that exist and carries no
  control characters; verified mechanically rather than by review.

### Modified Capabilities
- `x64-windows-link-inputs`: the sysroot location becomes a stated external contract with a
  machine-readable manifest, rather than an unstated implementation detail; the documentation
  requirement additionally demands that every path the documentation quotes resolves.
- `commit-gate`: the default lane's minimum coverage gains the documentation-integrity check.

## Impact

- `docs/customer/README-offline.md` — two corrupted paths repaired.
- `docs/toolkit-handoff.md` — brought under version control unchanged.
- `docs/` — new reply document to the HEC side.
- `ci.ps1` — new in-process check in the default lane, alongside `Test-PowerShellSyntax`.
- `test/ci.tests.ps1` — coverage for the new check.
- No change to `scripts/build_win_link_inputs.ps1`, to the generated sysroot, to the shipped ABI, or
  to `install-layout.json`. Nothing customers already installed becomes invalid.
- Downstream: HEC changes `TOOLKIT_LINK_INPUT_DIR` in `crates/hec-core/src/health.rs` to the
  contracted path. That edit is theirs to make; this change supplies the path and the guarantee.
