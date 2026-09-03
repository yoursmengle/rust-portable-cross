## Context

See `proposal.md` — Why. Three facts from the current tree shape everything below.

**The link inputs already exist and already ship.** `tools/sysroot/x86_64-pc-windows-msvc/lib/`
holds eleven import libraries plus `msvcrt.lib` and `rpc_winshim.lib`, all fourteen files are listed
in the `core` component of `dist/staging/core/install-layout.json`, `rust_build_isolation.ps1`
scrubs eleven host-MSVC environment variables, and `openspec/specs/x64-windows-link-inputs/spec.md`
already governs the behaviour. Nothing in this change touches that machinery.

**`tools/sysroot/` is generated, not tracked.** `tools/.gitignore` excludes it, alongside
`cargo-home/`, `rustup-home/`, `zig/` and the caches. A fresh clone therefore has no sysroot until
`rust_setup.ps1` and `build_win_link_inputs.ps1` have run. Any check that runs in the default commit
lane must survive that.

**The two documentation defects are escape-decoding damage, not typos.** `docs/customer/README-offline.md`
line 69 holds `tools\sysroot` + `U+0086` + `_64-pc-windows-msvc\lib` — a `\x86` decoded as a hex
escape. Line 77 holds `scripts` + `U+0008` + `uild_win_link_inputs.ps1` — a `\b` decoded as a
backspace. In both cases the separator was consumed along with the character that followed it.

## Goals / Non-Goals

**Goals:**

- Make the sysroot location a contract a downstream probe can rely on, and say so in a place the
  integrating side can cite.
- Repair the two damaged paths and add a mechanical check that would have caught them.
- Close the A/B question in writing, in the repository, where the next person to ask will look.

**Non-Goals:**

- Any change to the generated sysroot, to `build_win_link_inputs.ps1`, to the shipped ABI, or to the
  install layout. The link-input mechanism is settled and out of scope.
- Solving the retained limitation (a C build script that needs Microsoft's own headers). It is
  documented, not fixed.
- Making the downstream edit. `TOOLKIT_LINK_INPUT_DIR` lives in another repository this change has no
  write access to; this change supplies the path and the guarantee it is stable.

## Decisions

### Keep the current sysroot path; do not add a `tools/msvc-sysroot` alias

The integrating side's probe expects `tools/msvc-sysroot` with `sdk/x64` and `lib/x64`. That is
xwin's layout, chosen when option A was the presumed outcome. Matching it would mean either copying
every `.lib` twice into the installer payload, or creating a directory symlink — which on Windows
needs either elevation or Developer Mode, so it would fail on exactly the locked-down customer
machines this product targets. Beyond the mechanics, an alias makes two paths canonical forever, and
it embeds the shape of a route that was declined.

*Alternative considered:* ship the alias and let the downstream side change nothing. Rejected — it
moves a one-line edit in one repository into a permanent duplication in every installation.

*Alternative considered:* move the toolkit to `tools/msvc-sysroot/lib/x64`. Rejected — the current
path is triple-qualified, so it extends to a second target without restructuring, and it is already
referenced by `rust_env.ps1`, `rust_build_isolation.ps1`, `prepare_offline_release.ps1`, the install
layout, and the customer README.

### The reply is a document in this repository, not a message

The handoff arrived as a file. The answer leaves as a file, next to it, under version control, so it
can be diffed against a later toolkit release and so the A/B verdict has an address.
`docs/toolkit-handoff.md` is committed unmodified first, as the received artefact, so the reply can
cite line and claim.

### The documentation check is two independent checks, and only one of them catches these defects

Being precise about this matters, because the weaker of the two is easy to overclaim.

*Control characters* — reject anything outside tab, carriage return and line feed in the C0 range,
plus the whole C1 range, and reject a carriage return not followed by a line feed. This is the scan
that catches every defect of this class: it needs no filesystem, no toolchain, and it fires on the
mangled `scriptsuild_win_link_inputs.ps1`, which no longer contains a separator for a path scan to
recognise it by. It is also what found a third instance during implementation — `README.md` line 287,
where a copy-pasteable command had been mangled from `.\test\rust_setup.tests.ps1` into a tab, a
stray carriage return, and the wreckage of two path separators.

*Path resolution* — for each backtick code span in tracked Markdown, treat it as a toolkit path only
when it contains a backslash or forward-slash separator. That restriction is deliberate: bare names
such as `link.exe`, `ucrtbase.dll` and `link.x` appear in the README and are not repository paths.
Then take the first whitespace-delimited token (so the x64 build script span reduces to the script
itself, dropping its `-ProjectPath` argument), strip a leading `.\` and a trailing separator, skip
anything containing an angle-bracketed reader placeholder, and skip anything whose first segments
name a generated root — `tools/sysroot`, `tools/zig`, `tools/rustup-home`, `tools/cargo-home`,
`tools/downloads`, `dist`, `target`. Fenced code blocks are skipped whole: a fence holds transcripts
and templates, not claims about this repository's layout.

One further restriction, which implementing the check forced into the open: a path is only in scope
when its **leading segment names something that exists at the repository root**. The reply document
this change adds cites `crates/hec-core/src/health.rs`, which is correct and belongs to another
repository; `crates/` does not exist here, so the path is foreign and out of scope. The rule that
falls out is defensible on its own terms — this check verifies that documentation about *this*
toolkit is accurate about *this* toolkit — and it is what the spec now states.

The cost is that a typo in the leading segment (`script\build_win_link_inputs.ps1`) escapes, while a
typo anywhere after it is caught. That asymmetry is accepted: the alternative is a failure on every
legitimate cross-repository reference, and a check that fails on correct documentation gets deleted.

This catches a different class: a renamed script, a moved sample, a path that was correct three
refactors ago. Verified against the two original defects, it also catches the first of them as a
side effect — `tools/sysroot` + `U+0086` + `_64-…` is no longer *under* the exempted `tools/sysroot`
root, so it is scanned and does not resolve — but it cannot see the second, whose separator is gone.
The control-character scan is the one to rely on for this class; the path scan is a bonus on it and
the primary defence against a different one. Neither is a substitute for the other.

*Alternative considered:* a hand-maintained list of documented paths. Rejected — it decays the moment
someone documents a path without updating the list, which is the same failure mode one layer up.

*Alternative considered:* resolve paths under generated roots too, by requiring `-Full`. Rejected —
the defect is introduced in an editing session and must be caught by the lane that runs on commit,
not by a lane that needs a provisioned toolchain.

### The check is in-process in `ci.ps1`, not a separate suite

`Test-PowerShellSyntax` is the precedent: it enumerates tracked files through `git ls-files`, needs
no toolchain, and runs in-process rather than as one of the auto-discovered `test/*.tests.ps1`
external suites. The documentation check has the same shape and the same cost profile, so it follows
the same pattern, and its unit coverage goes into the existing `test/ci.tests.ps1`.

## Risks / Trade-offs

- **The downstream side does not make the constant change, and the mismatch persists.** → The reply
  document names the exact path and the exact constant. The contract is now specified, so the
  toolkit side's obligation is discharged and verifiable; the remaining step is visibly one edit in
  one file.
- **The path check produces false failures on a legitimately documented future path.** → The
  generated-root exemption list is explicit and extending it is a one-line edit, the same shape as
  extending the import-library list in `build_win_link_inputs.ps1`.
- **The path check's separator heuristic misses a bare-filename path that is genuinely wrong.** →
  Accepted. Widening it to bare filenames would flag `link.exe` and `ucrtbase.dll`, which are
  operating-system files and correctly documented. A check that cries wolf gets deleted.
- **Committing `docs/toolkit-handoff.md` records a document whose claims are now false.** → It is
  committed as a dated received artefact and the reply states which of its claims no longer hold,
  which is the point of keeping it.
- **The contract requirement freezes a path that a future second Windows target might want to
  reshape.** → The contract is `tools/sysroot/<target-triple>/lib`, already parameterised by triple,
  so a second target extends it rather than breaking it.

## Migration Plan

No runtime migration. The sysroot does not move, so every existing installation already satisfies the
contract this change writes down. Rollback is reverting the commit; nothing outside the repository
changes state.

The one cross-repository step — the integrating side pointing `TOOLKIT_LINK_INPUT_DIR` at
`tools/sysroot/x86_64-pc-windows-msvc/lib` — is sequenced after this change lands, because the reply
document is what authorises it.
