## Context

See proposal.md. The existing CI discovers `test/*.tests.ps1`, so the contract check can join the default lane without changing `ci.ps1`. No installed toolchain is needed for static signatures and generated metadata shapes.

## Goals / Non-Goals

**Goals:** Capture a useful machine-readable baseline, fail with precise drift diagnostics, and document the installer behavior actually encoded in the current Inno script.

**Non-Goals:** Freeze internal helper functions, transient timestamps, absolute build roots, binary hashes, or arbitrary log wording. Do not change installation behavior or release schema.

## Decisions

1. Store expected contract data in a dedicated JSON fixture and test it from a discovered PowerShell suite. Compare script parameters through PowerShell's parser AST, not text regexes, so whitespace and comments do not trigger false drift.
2. Test metadata field shapes from the source constructors and a small synthetic install layout rather than from a previously generated `dist/` tree. The check must work in a fresh clone and avoid invoking release tooling.
3. Check public paths, wrappers, triples, and the installer component constant from current source. Keep the fixture limited to external surfaces; internal source refactors may update the extraction code while preserving the expected JSON.
4. Preserve `defaultComponents = ["armv7"]` in layout metadata and the `SelectedComponents` finalize parameter. They remain valid for direct finalize usage even though the shipping installer currently selects all targets.

## Risks / Trade-offs

- Source inspection can miss a behavioral regression even when names and schemas match → retain runtime build and package checks; this suite only supplies the contract baseline.
- Source inspection can become brittle if implementation moves → parse syntax for signatures and compare semantic values wherever practical; maintain tests when internal constructors move while retaining fixture values.
- An internal helper might be incorrectly treated as public → enumerate only documented or installer-invoked entrypoints.

## Migration Plan

Add the fixture and suite, correct the customer guide, run the default gate, then compare the baseline before each later P0 change. Revert the suite and guide correction as one commit if a false positive blocks the gate.
