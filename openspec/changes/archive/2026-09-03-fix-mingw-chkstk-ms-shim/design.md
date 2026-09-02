## Context

See `proposal.md — Why` for motivation. The constraints that shape the fix:

- `scripts/rust_build_x64_win_native.ps1:181` pins `$zigCcTarget = "x86_64-windows-gnu"` and points
  `CC_x86_64-pc-windows-msvc` at the generated wrapper. This is deliberate and documented in the
  script: `zig cc -target x86_64-windows-msvc` needs MSVC headers the toolkit cannot ship, so the
  GNU target is the only one that works on a bare machine. C objects stay C-ABI compatible with the
  MSVC-ABI Rust objects, and both sides resolve the CRT to `ucrtbase.dll`.
- The final link is `rust-lld` in `lld-link` flavor (`rust_build_x64_win_native.ps1:225-229`), which
  sees no `libgcc.a` and no compiler-rt.
- `rpc_winshim.lib` is already the designated home for "symbols that no DLL exports, so they cannot
  come from an import library" (`scripts/build_win_link_inputs.ps1:222`), and already contains a
  hand-written `__chkstk`.

Confirmed against the bundled compiler rather than assumed:

```
$ zig cc -target x86_64-windows-gnu -S -O2 probe.c    # 16 KiB local array, address escapes
big:
        movl    $16552, %eax
        callq   ___chkstk_ms
        subq    %rax, %rsp
```

The call site's contract — size in `RAX`, `RAX` preserved, caller does the `sub` — is exactly what
the shim's `__chkstk` body already implements, and matches libgcc's `___chkstk_ms` in
`config/i386/cygwin.S` instruction for instruction. A symbol scan of the shipped
`rpc_winshim.lib` shows `__chkstk`, `_fltused` and `mainCRTStartup`, and no `___chkstk_ms`.

Probing the same compiler for other GNU-runtime references found only `__udivti3` (128-bit division),
which Rust's `compiler_builtins` already supplies to the link, and no `__stack_chk_fail` — the
bundled Zig does not enable the stack protector for C by default.

## Goals / Non-Goals

**Goals:**

- Resolve `___chkstk_ms` from bundled inputs, with no second copy of the probe logic.
- Make the gap non-recurring: the required symbols become a declared list checked at generation time
  and again by the self-containment check, and the check's build actually demands them.
- Keep the shim's licence and provenance story intact.

**Non-Goals:**

- Switching `$zigCcTarget` to `x86_64-windows-msvc`, or splitting C compilation across two targets.
- Vendoring libgcc or compiler-rt.
- Pre-emptively adding GNU-runtime helpers that the bundled compiler does not emit.

## Decisions

### Alias, not a second function

Emit `___chkstk_ms` as an additional label on the existing `__chkstk` body, inside the same inline
`__asm__` block:

```
".globl ___chkstk_ms\n"
".def ___chkstk_ms; .scl 2; .type 32; .endef\n"
"___chkstk_ms:\n"
".globl __chkstk\n"
".def __chkstk; .scl 2; .type 32; .endef\n"
"__chkstk:\n"
"    push %rcx\n"
...
```

*Why:* the two routines have identical calling conventions and identical bodies, so a shared body
cannot drift. *Alternatives:* a separate `___chkstk_ms` that jumps to `__chkstk` costs a branch and a
second SEH-less frame for no benefit; a COFF weak alias (`.weak`/`-alias:`) would work but is less
legible than a label and would be the only weak symbol in the file.

The label goes *before* `__chkstk:` with no instructions between, so both names denote the same
address. Both need the `.def ... .scl 2 .type 32 .endef` COFF storage-class directives so `lld-link`
sees them as external functions.

### Forwarders for the CRT's header-inline functions

`ucrtbase.dll` exports 2654 symbols. Among them are `__stdio_common_vfprintf`, `__stdio_common_vsprintf`,
`__stdio_common_vfscanf`, `__stdio_common_vsscanf` and `__acrt_iob_func` - and not one member of the
printf or scanf families, narrow or wide. In Microsoft's headers those families are `inline` bodies
that forward to the primitives, so they are never exported; mingw's headers declare them as ordinary
functions and let `libmingwex.a` supply the bodies, which an MSVC-mode link never sees.

The shim therefore carries those bodies. Each is the Microsoft header inline transcribed, which means
the option flags matter and are not interchangeable:

| Function | Primitive | Options | Count |
| --- | --- | --- | --- |
| `printf`, `fprintf`, `vprintf`, `vfprintf` | `__stdio_common_vfprintf` | `0` | - |
| `sprintf`, `vsprintf` | `__stdio_common_vsprintf` | `LEGACY_VSPRINTF_NULL_TERMINATION` | `(size_t)-1` |
| `snprintf`, `vsnprintf` | `__stdio_common_vsprintf` | `STANDARD_SNPRINTF_BEHAVIOR` | caller's |
| `_snprintf`, `_vsnprintf` | `__stdio_common_vsprintf` | `LEGACY_VSPRINTF_NULL_TERMINATION` | caller's |
| `_scprintf`, `_vscprintf` | `__stdio_common_vsprintf` | `STANDARD_SNPRINTF_BEHAVIOR` | `0`, null buffer |
| `scanf`, `fscanf`, `vscanf`, `vfscanf` | `__stdio_common_vfscanf` | `0` | - |
| `sscanf`, `vsscanf` | `__stdio_common_vsscanf` | `0` | `(size_t)-1` |

The C99 `snprintf` and the MSVC `_snprintf` differ precisely in that flag - the C99 one always null
terminates and returns the length it wanted, the legacy one does neither - so both spellings exist
with different options rather than one aliasing the other. `printf` and `scanf` reach the standard
streams through `__acrt_iob_func`, exactly as the headers do.

*Why in the shim rather than a second archive:* it is already the file for "symbols no Windows DLL
exports", it is already on every link line for this target, and `/OPT:REF` drops whatever a given
binary does not call. *Alternative considered:* generating an import library from a mingw `.def` for
`libmingwex` - there is no such DLL, so there is nothing to import from.

The shim compiles with `-nostdinc`, so it declares the primitives itself and uses `__builtin_va_list`
and `__builtin_va_start` rather than `stdarg.h`. `-fno-builtin` is added to the compile: without it
clang is entitled to recognize these names as builtins and rewrite a body into a call to itself.

### Declared required-symbol set in the generator

Add `$script:RequiredShimSymbols = @("__chkstk", "___chkstk_ms", "_fltused", "mainCRTStartup",
"atexit", "_tls_used", "_tls_index")` next to the existing `$script:RequiredCrtExports`, and have
`New-ShimArchive` verify the produced object defines each one before archiving.

*Why:* the CRT import library already has exactly this guard, so the pattern is established and the
failure mode is familiar. *How:* the check reads the symbol names out of the produced object; the
generator has no `nm`, but the COFF symbol/string tables are readable directly, and the simpler route
is to let `zig cc` do it — link a probe that references each required symbol against the archive and
fail on the linker's own error. Implementation picks whichever is cheaper; the spec only requires
that a missing symbol fails the run and is named.

### Fixture carries the large frame

`test/fixtures/win_selfcontained/csrc/probe.c` gains a function with a multi-page local array whose
address escapes to an external callee (otherwise LLVM sinks the array and no probe is emitted — the
first attempt at reproducing this with a `volatile` buffer produced no `___chkstk_ms` at all). The
Rust side calls it and asserts the result, so a broken probe shows up as a wrong value or a crash,
not just a successful link.

*Why here:* the fixture is already the place where "the C side and the Rust side agree" is proven,
and it is built by `check_tool_x64_win.ps1` under a scrubbed environment — precisely the conditions
under which the bug reproduces.

### Shipped artifacts are build output

`tools/sysroot/` is git-ignored (`tools/.gitignore:8`), so the fix is not complete when the script is
edited: `rpc_winshim.lib` and `PROVENANCE.json` must be regenerated locally, and any already-built
offline package under `dist/` is stale.

## Risks / Trade-offs

- **The alias changes `rpc_winshim.lib`'s hash, so `PROVENANCE.json` and any published package
  checksum move.** → Regeneration already rewrites `PROVENANCE.json`; the reproducibility scenario in
  the spec only requires two runs of the *same* generator to agree, which still holds.
- **`___chkstk_ms` is now defined for objects that also see a real libgcc.** → Cannot happen here:
  the shim is only on the link line for `x86_64-pc-windows-msvc` (`-C link-arg=rpc_winshim.lib`,
  `rust_build_x64_win_native.ps1:229`), and that link has no libgcc. A GNU-target link never consumes
  this archive.
- **Other libgcc-only symbols may surface later from C code this toolkit has not yet compiled.** →
  The required-symbol list plus the generator guard make adding one a one-line declared change, which
  is the same shape as adding an import library today. The proposal records what was probed so a
  future report can be compared against it rather than re-derived.
- **The shim now defines names a future C dependency might also define.** → All of them are standard
  C library functions that no sane translation unit redefines, and the shim is a single object that
  is pulled in for `mainCRTStartup` regardless. A crate that ships its own `printf` would already
  conflict with any real libc.
- **A forwarder with the wrong option flag is worse than a missing symbol: it links and then
  misbehaves.** → The fixture asserts observable behaviour rather than just linking - `snprintf`
  truncation and return value, `_snprintf`'s legacy non-termination, `sprintf` output and `sscanf`
  parsing - so a wrong flag fails the check instead of shipping.
- **Stale caches hide the fix the same way they hid the bug.** → The migration step below forces a
  rebuild of the affected crate rather than trusting an incremental run.

## Migration Plan

1. Edit the generator, then run `.\scripts\build_win_link_inputs.ps1 -Force` to rewrite the sysroot.
2. Run `.\check_tool_x64_win.ps1` — with the enlarged fixture this now fails before the fix and
   passes after, which is the regression test.
3. For a consumer already hitting the error: after regenerating, delete the cached artifacts of the
   offending crate (`cargo clean -p zstd-sys`, or the whole `target/`) so it is recompiled through
   the wrapper against the new shim.
4. Rebuild offline packages with `.\scripts\prepare_offline_release.ps1`; packages produced before
   this change carry the old shim.

Rollback is reverting the generator edit and re-running step 1.
