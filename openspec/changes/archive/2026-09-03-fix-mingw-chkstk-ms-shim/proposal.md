## Why

Third-party crates with C build scripts fail to link for `x86_64-pc-windows-msvc` with
`undefined symbol: ___chkstk_ms`. The toolkit compiles C through a `zig cc -target
x86_64-windows-gnu` wrapper (deliberately — Zig cannot ship MSVC headers), so GNU-ABI codegen
emits libgcc's stack probe `___chkstk_ms` for any function whose frame exceeds one page. The
final link is done by `rust-lld` in MSVC mode, where libgcc and compiler-rt are absent, and the
bundled `rpc_winshim.lib` — which exists precisely to supply "the symbols no Windows DLL exports"
— defines only the MSVC spelling `__chkstk`, not the MinGW one.

The gap is latent rather than new: it surfaces the moment a crate with a large C stack frame
(observed with `zstd-sys`) is compiled rather than restored from a cache built when
`CC_x86_64-pc-windows-msvc` still pointed at a real `cl.exe`. Every consumer of the toolkit hits it
on a clean build.

Fixing that symbol exposed a second gap of the same family, found by building a real `zstd` project
against the corrected shim: `undefined symbol: fprintf`, referenced 54 times from
`zstd/lib/dictBuilder/zdict.c`. `ucrtbase.dll` exports the `__stdio_common_v*` primitives and
`__acrt_iob_func`, but not one member of the printf or scanf families - in Microsoft's own headers
those are inline functions that forward to the primitives, so they never become DLL exports. mingw's
headers instead declare them as ordinary functions and leave the bodies to `libmingwex.a`, which an
MSVC-mode link never sees. Both gaps are the same statement: a symbol the bundled C compiler emits
that nothing on the link line defines.

## What Changes

- Add `___chkstk_ms` to the generated shim source in `scripts/build_win_link_inputs.ps1` as an
  alias label on the existing `__chkstk` body. The two are already the same routine: both take the
  frame size in `RAX`, probe the stack without touching `RSP`, preserve `RAX`, and leave the
  caller to perform `sub %rax, %rsp`. Verified against the codegen: `zig cc -target
  x86_64-windows-gnu -O2` emits `movl $N, %eax; callq ___chkstk_ms; subq %rax, %rsp`.
- Add the narrow-character printf and scanf families to the same shim as thin forwarders to the
  `__stdio_common_v*` primitives, carrying the exact option flags Microsoft's headers pass:
  `printf`, `fprintf`, `sprintf`, `snprintf`, `_snprintf`, `_scprintf`, `scanf`, `fscanf`, `sscanf`
  and each one's `v`-prefixed variant.
- Regenerate `tools/sysroot/x86_64-pc-windows-msvc/lib/rpc_winshim.lib` and its `PROVENANCE.json`
  entry so the shipped sysroot carries the new symbols.
- Extend the `win_selfcontained` fixture so its C side allocates a frame larger than one page,
  making `___chkstk_ms` a symbol the self-containment check actually demands. Without this the
  check keeps passing while the gap is open — its current `probe.c` has only small frames.
- Add an explicit shim-symbol assertion to `check_tool_x64_win.ps1` and a required-exports guard in
  the generator, mirroring the existing `RequiredCrtExports` check, so a future regeneration cannot
  silently drop either spelling.

Non-goals: changing `$zigCcTarget` away from `x86_64-windows-gnu` (the MinGW headers are the whole
reason the wrapper works on a bare machine), and pre-emptively adding other libgcc helpers.
Empirical probing of the bundled Zig shows the only other GNU-runtime symbol reachable from C
codegen is `__udivti3`, which Rust's `compiler_builtins` already supplies; the stack protector is
off by default, so `__stack_chk_fail` is not emitted.

The wide-character families (`wprintf`, `swprintf`, `_snwprintf` and friends) are also absent from
`ucrtbase.dll`'s exports and are deliberately left out. Their MSVC semantics differ from C's in ways
that are easy to get subtly wrong, and no C dependency reached through this toolchain calls them.
They are a known, stated limitation rather than an oversight; the symbol list makes adding them a
one-line change if one ever does.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `x64-windows-link-inputs`: the shim requirement becomes explicit about supplying both classes of
  symbol the bundled C compiler emits but nothing on an MSVC link line defines - compiler-runtime
  symbols such as the stack probe, in the MSVC and MinGW spellings, and C-runtime functions that
  exist only as header inlines in Microsoft's headers. The generator gains a required-symbols guard
  analogous to the existing CRT-export guard.
- `toolchain-self-containment-check`: the check must exercise a C translation unit whose stack
  frame exceeds one page, so that stack-probe symbols are actually demanded by the link it verifies.

## Impact

- `scripts/build_win_link_inputs.ps1` — shim source and a new required-symbols assertion.
- `tools/sysroot/x86_64-pc-windows-msvc/lib/rpc_winshim.lib`, `.../PROVENANCE.json` — regenerated
  (untracked build output; must be rebuilt before packaging).
- `test/fixtures/win_selfcontained/csrc/probe.c`, `src/main.rs` — large-frame probe.
- `check_tool_x64_win.ps1` — shim-symbol assertion.
- `README.md` — the `build_win_link_inputs.ps1` section, which enumerates what the shim supplies.
- Offline release packages built before this change ship a shim without `___chkstk_ms`; they need
  regeneration via `scripts/prepare_offline_release.ps1`.
