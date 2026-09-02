## Context

See `proposal.md` — Why for the motivation and the measurements. The design-relevant facts:

- The link is already performed by the bundled `rust-lld` in `lld-link` flavor. Nothing about the
  linker changes here.
- `rustc` names five import libraries plus `/defaultlib:msvcrt`, and supplies the search path by
  injecting `LIB` into the linker child process from its own registry probe for Visual Studio and the
  Windows SDK. There is no `/LIBPATH:` on the command line to override.
- With `/NODEFAULTLIB:msvcrt` the residual symbol set is closed and small:
  `mainCRTStartup`, `__CxxFrameHandler3`, `_CxxThrowException`, ``const type_info::`vftable` ``,
  `__chkstk`, `_tls_index`, `_fltused`, `atexit`, `memcpy`, `memmove`, `memset`, `memcmp`, `strlen`.
- The bundled Zig 0.13.0 already carries every source needed to produce those:
  `lib/libc/mingw/lib-common/*.def{,.in}` and `lib64/*.def` (module definitions for the Windows DLLs),
  `lib/libc/mingw/lib-common/ucrtbase.def.in`, `lib/libc/mingw/crt/crtexe.c` and `crt/ucrtexewin.c`
  (CRT startup), `lib/libc/mingw/crt/tlssup.c` (`_tls_index` / `_tls_used`),
  `lib/compiler_rt/stack_probe.zig` (`__chkstk`), and the `zig dlltool`, `zig cc`, `zig lib`
  subcommands to turn them into `.lib` files.

Constraint that shapes everything: we may redistribute mingw-w64-derived and Zig-derived artifacts, but
not Microsoft's CRT or SDK libraries. Every shipped byte must be derivable from what is already in
`tools/zig/`.

## Goals / Non-Goals

**Goals:**

- `x86_64-pc-windows-msvc` remains the produced triple. Downstream output paths
  (`target/x86_64-pc-windows-msvc/<profile>/`) and ABI expectations do not move.
- Link inputs are generated, not curated: one script reproduces the whole sysroot from bundled sources.
- Bundled inputs take precedence over host ones even when a host Visual Studio exists, so a developer
  machine and a bare machine link identically.
- `panic = "unwind"` keeps working. No forced `panic = "abort"`.

**Non-Goals:**

- Adding `x86_64-pc-windows-gnu` or `x86_64-pc-windows-gnullvm` as a shipped target.
- Making `zig cc -target x86_64-windows-msvc` work without host MSVC headers. C dependencies are
  handled by retargeting the C compiler (see Decision 5), not by shipping MSVC headers.
- Supporting Windows 8.1 or earlier, or Windows Server before 2016.
- Changing anything in the `armv7`, `aarch64`, or `thumbv7em` paths.

## Decisions

### Decision 1: Keep `x86_64-pc-windows-msvc`; do not switch to a mingw triple

The obvious alternative was to make the portable Windows target `x86_64-pc-windows-gnullvm`, which is a
Tier-2 Rust target whose entire runtime Zig already provides. This was tried: `rustup target add
x86_64-pc-windows-gnullvm` succeeds, and a single offline `zig cc -target x86_64-windows-gnu`
materialises `kernel32.lib`, `ntdll.lib`, `userenv.lib`, `ws2_32.lib`, `dbghelp.lib`, `advapi32.lib`,
`ole32.lib`, `oleaut32.lib`, `shell32.lib`, `user32.lib`, the full `api-ms-win-crt-*` set,
`mingw32.lib`, `c.lib`, `compiler_rt.lib` and `libunwind.a`. Linking got as far as a single duplicate
`___chkstk_ms` between Zig's `compiler_rt` and Rust's `compiler_builtins`.

Rejected anyway, because the triple is part of this toolkit's contract with its consumers: output
directory names, the ABI of any MSVC-built binary they link against, and the desktop app's expectations
all key off `x86_64-pc-windows-msvc`. Changing the triple to fix a missing-files problem trades a
small, closed packaging gap for an open-ended compatibility one.

### Decision 2: Satisfy `/defaultlib:msvcrt` with an import library for `ucrtbase.dll`

This is the decision the whole change turns on. MSVC's `msvcrt.lib` is not redistributable, so the
question was whether anything redistributable can supply the CRT and — critically — the MSVC C++
exception-handling personality that Rust's precompiled MSVC `std` references from its unwind tables.

`tools/zig/lib/libc/mingw/lib-common/ucrtbase.def.in` exports `__CxxFrameHandler`,
`__CxxFrameHandler2`, `__CxxFrameHandler3` and `_CxxThrowException`, alongside `memcpy`, `memmove`,
`memset`, `memcmp`, `strlen`, `exit` and `_crt_atexit`. `ucrtbase.dll` is an operating-system component
on Windows 10 and later — not a Visual C++ redistributable — so depending on it introduces no install
step for end users.

So the toolkit ships a generated `msvcrt.lib` that is an import library for `ucrtbase.dll`, produced by
`zig dlltool` from that definition file. `/defaultlib:msvcrt` resolves against it, and every dynamic
CRT symbol in the residual set is covered. This was verified end to end: a `std` binary links with all
inputs resolving inside the toolkit, runs, and a `catch_unwind` around a panic eight frames deep is
caught correctly — so `ucrtbase`'s personality routine really does drive Rust's unwinder.

Alternatives considered and rejected:

- *Import library for `vcruntime140.dll`* (Zig ships `vcruntime140_app.def.in`): `vcruntime140.dll` is
  a Visual C++ redistributable, not an OS component. It would reintroduce exactly the external
  dependency this change exists to remove.
- *`panic = "abort"` plus stub personality routines*: measured, and it does not work.
  `-C panic=abort` drops `_CxxThrowException`, but `__CxxFrameHandler3` and
  ``const type_info::`vftable` `` are still referenced from the `.xdata` of the *precompiled*
  `libstd`, so the symbols remain undefined. Escaping that needs `-Z build-std`, which is nightly-only,
  and it would still cost users `catch_unwind`.
- *Reimplementing `__CxxFrameHandler3`*: MSVC's C++ EH runtime is intricate and mingw-w64 deliberately
  does not implement it. Not a maintainable thing to own.

### Decision 3: Generate the SDK import libraries with `zig dlltool`, do not hand-collect them

The Windows API import libraries are produced from the bundled mingw-w64 `.def` and `.def.in` files.
`.def.in` inputs are preprocessed first (they `#include "func.def.in"` and use `DATA`/architecture
macros), which the bundled `zig cc -E` handles, then fed to `zig dlltool`.

The generated set covers the five libraries `rustc` always names plus the ones commonly pulled in by
`windows-sys`-style dependencies: `kernel32`, `ntdll`, `userenv`, `ws2_32`, `dbghelp`, `advapi32`,
`user32`, `ole32`, `oleaut32`, `shell32`, `bcrypt`. The generator is driven by an explicit list so the
set is auditable and the package does not balloon to all 481 definitions; extending it is a one-line
change.

Hand-collecting `.lib` files was rejected: it is unauditable and it invites someone to copy a
Microsoft library in by accident. The generated tree is added to `tools/.gitignore` alongside the
other derived payloads, so there is no committed blob to drift from its sources.

### Decision 4: A small static shim archive for the symbols no DLL exports

Six symbols are static-only and cannot come from an import library:

| Symbol | Source |
| --- | --- |
| `mainCRTStartup` | a ~4-line entry point calling `_configure_narrow_argv`, `main`, `exit` — all imported from `ucrtbase` |
| `atexit` | one-line forward to `ucrtbase`'s `_crt_atexit`, which is exported where `atexit` is not |
| `_fltused` | the conventional `0x9875` data symbol the compiler references whenever floating point is used |
| `_tls_index`, `_tls_used` | the TLS directory, adapted from the ~15 essential lines of Zig's `lib/libc/mingw/crt/tlssup.c` |
| `__chkstk` | hand-written naked assembly (the canonical MSVC x64 stack probe, ~14 instructions) |
| ``const type_info::`vftable` `` | a one-object data definition; unreachable at runtime because the throw path lives in `ucrtbase` |

These are compiled by the bundled `zig cc` and archived with `zig lib` into a single
`rpc_winshim.lib`, which the build script appends to the link. Keeping them in one clearly named
archive makes the "what did we invent ourselves" surface exactly six entries wide.

Two of these were not visible from the undefined-symbol list alone and surfaced during
implementation. `atexit` appears in the residual set but `ucrtbase.def.in` exports only `_crt_atexit`,
so the forward is required. Compiling mingw's `crt/tlssup.c` and `crt/crtexe.c` wholesale was tried
and abandoned: both drag in `__mingw_TLScallback`, `_CRT_MT`, `malloc` and the pseudo-relocation
machinery, which would pull mingw's libc into an MSVC-ABI link. Transcribing the handful of lines that
matter keeps the object free of mingw runtime entanglement, which is also why the shim is compiled
`-ffreestanding -nostdinc`.

### Decision 5: Retarget the bundled C compiler to `x86_64-windows-gnu`

`rust_build_x64_win_native.ps1` currently points `CC` at a wrapper running
`zig cc -target x86_64-windows-msvc`. That target requires MSVC's headers, which we cannot ship — so
any dependency with a C build script would still fail on a bare machine even after the link inputs are
fixed. The wrapper is retargeted to `x86_64-windows-gnu`, whose headers and libc Zig bundles in full.

The resulting objects are C-ABI compatible with the MSVC-ABI Rust objects, and the CRT lines up because
Zig's mingw in UCRT mode and our generated `msvcrt.lib` both resolve to `ucrtbase.dll`. This is the
weakest joint in the design and is called out under Risks.

### Decision 6: Force precedence with `/LIBPATH:`, then verify

`rustc` injects host `LIB` into the linker process and offers no switch to stop it. `lld-link`
searches `/LIBPATH:` entries before `LIB`, so passing the sysroot as an explicit `/LIBPATH:` link
argument makes the bundled `kernel32.lib` and `msvcrt.lib` win on any machine, with or without Visual
Studio. `rust_build_x64_win_native.ps1` additionally scrubs `LIB`, `INCLUDE`, `VCINSTALLDIR` and
`WindowsSdkDir` through the existing `rust_build_isolation.ps1` mechanism.

Precedence is asserted rather than assumed: the self-containment check links with `/verbose` and fails
if any resolved input lies outside the toolkit root. That check is what makes the guarantee real, so it
runs in the release pipeline and blocks packaging on failure.

### Decision 7: Generate at release time; ship in the `core` component

The sysroot is a derived artifact, added to `tools/.gitignore` alongside the toolchain payloads it
is generated from, so it is never committed. `prepare_offline_release.ps1`
invokes the generator before staging and records the produced files in the `core` component of
`install-layout.json` — `core` rather than a new `x64_win` component, because `core` is always
installed and the existing x64 scripts (`scripts/rust_build_x64_win_native.ps1`,
`check_tool_x64_win.ps1`) already live there. The sysroot is import libraries and one small archive, so
the package grows by a low single-digit number of megabytes.

## Risks / Trade-offs

- **Mixing mingw-compiled C objects into an MSVC-ABI link (Decision 5)** → The C ABI matches, and both
  sides resolve the CRT to `ucrtbase.dll`, but mingw-specific constructs (pseudo-relocations,
  `__mingw_*` helpers, structured-exception glue) can leak in. Mitigation: pin Zig's mingw to UCRT mode,
  add a C-dependency crate to the verification matrix rather than testing only the pure-Rust sample, and
  document that a crate needing genuine MSVC headers still needs host MSVC.
- **Depending on `ucrtbase.dll` (Decision 2)** → Windows 8.1 and Server 2012 R2 do not ship it as an OS
  component. Mitigation: state Windows 10 / Server 2016 as the floor in the docs. This matches Rust's
  own supported-platform floor, so it costs nothing in practice.
- **Rust could change which libraries it names** → A future toolchain bump may add an import library the
  generated set does not cover, surfacing as an undefined symbol. Mitigation: the generator's library
  list is explicit and one line to extend, and the self-containment check runs on every release, so the
  failure appears in the pipeline rather than at a customer.
- **The `type_info::vftable` data symbol is ours, not Microsoft's** → If a future `std` genuinely
  dereferences it rather than only referencing it, behaviour would be wrong instead of merely unused.
  Mitigation: the verification matrix includes a `catch_unwind` round-trip and a panic-across-frames
  test, so a real dependency on it would fail loudly.
- **`/LIBPATH:` precedence is an `lld-link` behaviour, not a contract** → If it ever changed, host
  libraries could silently win on developer machines. Mitigation: the self-containment check asserts
  the actual resolved paths rather than trusting the ordering.
- **The check parses linker output, so its own correctness is environment-sensitive** → This bit once:
  on a console using code page 936, a UTF-8 lead byte swallowed the carriage return separating
  `/verbose` records, the records merged, and the check reported a false host dependency. Mitigation:
  the probe forces UTF-8 decoding, the pattern is tempered so a match cannot span records, and a
  captured path that is not an existing file is reported as a defect in the check rather than as a
  leak. Verified under code page 936 as well as 65001.
- **Package grows and the desktop installer's hashes must be regenerated** → A stale
  `rust-toolkit-install.ts` manifest would fail verification for existing users. Mitigation: manifest
  regeneration is an explicit task, and the change is a coordinated release, not a hot-swap of the
  toolkit archive.

## Migration Plan

1. Land the generator and the sysroot; `rust_build_x64_win_native.ps1` uses it when present and falls
   back to today's host-MSVC behaviour when it is not, so nothing breaks mid-rollout.
2. Turn `check_tool_x64_win.ps1` into the self-containment check and wire it into
   `prepare_offline_release.ps1`.
3. Once a release package passes the check on a clean, MSVC-free machine, remove the fallback so a
   missing sysroot becomes a hard error with an accurate message.
4. Regenerate the desktop installer's volume manifest and SHA-256 values, then publish.

All four steps are complete. The fallback from step 1 has been removed, so a missing or incomplete
sysroot now fails the build with a message naming the regeneration command, rather than silently
linking against whatever Visual Studio the machine happens to have.

Rollback: reverting the build-script commit restores host-MSVC linking with the sysroot present but
unused.

## Open Questions

- Whether to extend the same generated-sysroot approach to `aarch64-pc-windows-msvc` later. It does not
  affect this design — the generator is parameterised by architecture from the start, and the mingw
  definition files for ARM64 are bundled — so it can be answered after this ships.
