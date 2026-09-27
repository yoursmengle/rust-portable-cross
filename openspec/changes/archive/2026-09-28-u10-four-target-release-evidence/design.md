## Context

U04 and U09 build all four targets from staged and installed payloads. The smoke currently checks Linux binaries and BIN/HEX only for existence and size. Full CI's `New-ScriptCheck` closure captures a module scope that cannot resolve the script-level PowerShell runner function, causing all four target checks to fail before execution.

## Goals / Non-Goals

**Goals:** Validate the actual outputs of the existing four-target release build; restore Full CI target execution; keep the default lane fast.

**Non-Goals:** Add new customer-facing build commands, change target triples, prove Linux runtime behavior on QEMU/boards, or complete the broader cc-rs and link-input provenance work deferred to S3/S4 in the upgrade plan.

## Decisions

- Keep the release binary inspector as a small internal PowerShell helper invoked after smoke builds, with no new runtime dependency. Read bounded file headers and PE/ELF tables; use the current pinned target format as an explicit baseline. The observed Linux samples are static ELF executables with no program interpreter or dynamic segment; ARMv7 and Thumbv7EM carry the hard-float flag.
- Inspect Windows PE machine/PE32+ headers and import table. Allow only the observed Windows operating-system DLL set, require UCRT, and retain the existing execute-and-check runtime fixture. This catches an added private DLL dependency while preserving known system imports.
- Inspect the firmware ELF entry point and cross-check the binary vector table and HEX data against `0x08008000..0x0803FFFF` and `0x20000000..0x2002FFFF`; verify Intel HEX record checksums and data bytes against BIN. This is image-structure evidence, not board execution evidence.
- Resolve the PowerShell executable before constructing the Full CI closure and capture its path. Add a real child-process regression case so the failure mode cannot recur unnoticed.

## Risks / Trade-offs

- A future pinned toolchain may alter ELF type or imports → release fails with a concrete difference, prompting an explicit baseline review.
- Format parsing must reject truncation and malformed offsets → bounded reads and fault-injection tests cover those paths.
- Static ELF and firmware structure do not prove execution on customer Linux images or the board → report those untested environments separately in release evidence.

## Migration Plan

Run default and Full CI, then validate the already built 0.1.2 EXE with the stronger smoke helper. Because only internal verification scripts change, the installer payload remains byte-identical; future installer builds automatically use the stronger gate.
