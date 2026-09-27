## Context

See proposal.md. The bootstrap URL can change over time. rustup verifies downloaded component packages, while this project controls its bootstrap and release staging. The existing target check is intentionally cheap during activation.

## Goals / Non-Goals

**Goals:** Pin initial downloads; bind the exact staged bytes to a Rust commit; verify staged and installed payloads; detect changed Windows libraries.

**Non-Goals:** Redesign rustup's component installer, re-hash the whole toolchain on every activation, or change public metadata schemas.

## Decisions

- Keep `scripts/dependency-lock.json` in version control. The Zig digest comes from Zig's official 0.13.0 download index; the rustup 1.29.0 digest comes from the official versioned SHA-256 sidecar. A mutable download endpoint is acceptable only when its bytes match this lock. A future upstream update requires an explicit lock revision.
- Generate `payload-integrity.json` in staging core from the complete component file lists after copies finish. It records product version, managed rustc commit, component name, relative path, byte length, and SHA-256. The finalizer verifies it before writing files. Its absence in an old package preserves the old path.
- Use the actual installed rustc `-vV` commit and assert it equals the pinned Rust commit. Do not infer the commit from hashed rlib filenames.
- Verify `PROVENANCE.json` against all 13 expected `.lib` files, both names and hashes, in the full Windows check; retain its current quick build prerequisites.

## Risks / Trade-offs

- [Hashing the entire payload costs time] → Do it only for release and installation, not ordinary activation.
- [PowerShell 5.1 preflight plus hashing exceeds the old 150-second outer watchdog] → Start that watchdog immediately before optional subprocess health checks; file preflight still runs before any install mutation.
- [An index built from already malicious source bytes cannot prove upstream authenticity] → rustup package verification remains responsible for component download integrity; the index proves copied payload continuity. The compiler commit lock adds an independent version constraint.
- [Interrupted installation can leave partial files] → U07 handles transactional preparation separately; this change guarantees preflight integrity only.

## Migration Plan

New releases include the private index; old packages remain installable through existing checks. Rollback restores the prior setup and finalizer while keeping public formats unchanged.
