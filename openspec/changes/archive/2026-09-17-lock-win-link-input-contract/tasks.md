## 1. Record the received handoff

- [x] 1.1 Commit `docs/toolkit-handoff.md` unmodified, so the reply has a citable artefact. Do not
      edit its claims, even the ones that are now false.

## 2. Repair the customer documentation

- [x] 2.1 Fix `docs/customer/README-offline.md` line 69: replace `tools\sysroot` + `U+0086` +
      `_64-pc-windows-msvc\lib` with `tools\sysroot\x86_64-pc-windows-msvc\lib`.
- [x] 2.2 Fix `docs/customer/README-offline.md` line 77: replace `scripts` + `U+0008` +
      `uild_win_link_inputs.ps1` with `scripts\build_win_link_inputs.ps1`.
- [x] 2.3 Confirm no control character outside tab/CR/LF remains anywhere in the file, and that the
      surrounding claims (no Visual Studio, no `link.exe`, no Windows SDK; Windows 10 / Server 2016
      and later; `ucrtbase.dll`; no VC++ redistributable) still match the shipped behaviour.

## 3. Write the reply to the integrating side

- [x] 3.1 Add `docs/toolkit-handoff-reply.md` stating, claim by claim, which parts of the handoff no
      longer hold, with the commit range that closed them and the evidence in the current tree
      (14 files under `core` in `install-layout.json`; the eleven scrubbed host-MSVC variables).
- [x] 3.2 In the same document, record the verdict: route C stands; A declined for requiring network
      access and Microsoft licence acceptance on machines the product exists to serve offline; B
      declined for changing the delivered ABI and reversing the prior deliberate `gnu` → `msvc`
      migration. Give the reason for each, not just the outcome.
- [x] 3.3 State the path contract explicitly — `tools/sysroot/<target-triple>/lib`, flat `.lib`
      files, `PROVENANCE.json` alongside `lib/` — and name the concrete value the downstream
      `TOOLKIT_LINK_INPUT_DIR` constant should take:
      `tools/sysroot/x86_64-pc-windows-msvc/lib`. Say that no `tools/msvc-sysroot` alias will be
      shipped, and why.
- [x] 3.4 State the retained limitation: a crate whose C code needs Microsoft's own headers still
      needs a host MSVC installation, and it presents as a compile error naming a missing header,
      not as a link error. Note that this is not something a readiness probe can detect.
- [x] 3.5 Correct the handoff's pointer to the offline README: the file is
      `docs/customer/README-offline.md`, and the claim it flagged is now accurate.

## 4. Implement the documentation-integrity check

- [x] 4.1 Add `Test-DocumentationIntegrity` to `ci.ps1` alongside `Test-PowerShellSyntax`, sourcing
      its file list from `git ls-files "*.md"` and returning `Skipped` with a reason when git is
      unavailable, matching the existing precedent.
- [x] 4.2 Implement the control-character scan: reject any C0 character other than tab, CR and LF,
      and reject the whole C1 range. Report document, line number, and the offending code point.
- [x] 4.3 Implement the path-resolution scan: for each backtick code span, treat it as a toolkit path
      only when it contains a separator; take the first whitespace-delimited token; strip a leading
      `.\` and any trailing separator; skip angle-bracketed placeholders; skip the generated roots
      `tools/sysroot`, `tools/zig`, `tools/rustup-home`, `tools/cargo-home`, `dist`, `target`.
      Report document, line number, and the unresolved path.
- [x] 4.4 Keep the exemption list in one named variable with a comment saying why each root is
      exempt, so adding a root is one declared edit.
- [x] 4.5 Register the check in the default lane via `Invoke-Check -Name "documentation-integrity"`,
      immediately after `powershell-syntax`.
- [x] 4.6 Have the passing outcome report how many documents and how many paths it resolved, so a
      pass is distinguishable from a check that found nothing to examine.

## 5. Test the check

- [x] 5.1 In `test/ci.tests.ps1`, cover: a document with a backspace fails and names the code point;
      a document with a C1 character fails and names the code point; a clean document passes.
- [x] 5.2 Cover the path scan: an unresolvable separator-bearing path fails and is named; a resolving
      path passes; a bare filename such as `link.exe` is not reported; an angle-bracketed placeholder
      is not reported; a path under `tools/sysroot` is not reported.
- [x] 5.3 Cover the fresh-clone case: with the generated roots absent, the check reaches a pass or
      fail verdict rather than reporting itself skipped.

## 6. Verify

- [x] 6.1 Run `.\ci.ps1` and confirm the default lane passes, with `documentation-integrity`
      reported as a pass rather than a skip.
- [x] 6.2 Temporarily reintroduce each of the two original defects and confirm the check fails on
      each, naming the right document and line. Revert both.
- [x] 6.3 Run `openspec validate --all --strict` and confirm the change's artifacts validate.
- [x] 6.4 Confirm nothing under `tools/sysroot/`, `scripts/build_win_link_inputs.ps1`, or
      `dist/staging/core/install-layout.json` was modified by this change.
