## Context

The release copies `sample/Cargo.lock` and source but no registry files. The source machine's managed Cargo home already has a standard crates.io sparse index and registry cache. The lockfile has 232 registry packages; all archives can be fetched with the pinned Cargo release before staging. The existing integrity index verifies staged and installed files.

## Goals / Non-Goals

**Goals:** Reproduce the locked sample build in a clean installed Cargo home; keep the dependency payload limited to lockfile packages; preserve existing commands and project configuration.

**Non-Goals:** Supply dependencies for arbitrary customer projects or change Cargo's default network policy. System-level network isolation needs an external test host and is not simulated by source changes.

## Decisions

- Package selected `.crate` archives and the matching sparse index records inside `tools/cargo-home/registry`, using `sample/Cargo.lock` as the allowlist and digest source. A clean test Cargo home containing only those files completed `cargo metadata --locked --offline` for all 233 packages. This avoids a sample-specific source replacement setting and leaves Cargo's normal project behavior unchanged.
- Before copying, use pinned Cargo metadata to identify dependency names, versions, and license expressions, and parse lockfile checksums. Require a one-to-one match and validate each archive SHA-256. Do not copy registry source trees, unrelated caches, credentials, or Cargo config files.
- Write a generated `docs/sample-dependencies.json` with relative archive names, checksums, and license expressions. Include it and every selected cache/index file in the existing layout and integrity index; index generated manifest bytes from staging, since there is no source file counterpart.
- Extend the installed release smoke to use the bundled sample itself with isolated environment variables, empty host cache, offline Cargo, and blackhole proxies. The existing dependency-free fixture remains the fast independent toolchain probe.

## Risks / Trade-offs

- Sparse index cache records can contain versions outside the lockfile → only the needed crate-name records ship; no extra archives ship, and all staged files are digested.
- Cargo internal cache layout could change → the pinned Cargo version and an actual installed offline sample build are release gates.
- A local machine with blackhole proxies is not a physically disconnected machine → retain a separate clean disconnected acceptance run in release evidence.

## Migration Plan

Run pinned Cargo `fetch --locked` on the preparation machine once, then prepare and validate the release. Existing installers remain valid and can be rolled back; the new cache only adds managed files.
