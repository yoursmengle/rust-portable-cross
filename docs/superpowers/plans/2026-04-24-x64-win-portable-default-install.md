# x64 Windows Portable Default Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Windows x64 support portable and selected by default while preserving user ability to deselect any target component.

**Architecture:** Keep the GNU host Rust toolchain in fixed `core`; make `x64_win` a thin target overlay containing the build entry script and wrapper exposure. Use the shared Cargo target config to force `x86_64-pc-windows-gnu` builds through the portable `x86_64-w64-mingw32-gcc.cmd` wrapper.

**Tech Stack:** PowerShell 5.1-compatible scripts, Inno Setup component metadata, Cargo target configuration, existing PowerShell test scripts.

---

## File Structure

- Modify `config/.cargo/config.toml`: add `x86_64-pc-windows-gnu` linker section.
- Modify `scripts/rust_build_x64_win.ps1`: copy toolkit Cargo config, check x64 wrapper, run `cargo build --release --target x86_64-pc-windows-gnu`.
- Modify `scripts/prepare_offline_release.ps1`: set all target components as defaults.
- Modify `packaging/inno/rust_portable_cross.iss`: make `aarch64` and `x64_win` part of the `default` setup type.
- Modify `docs/customer/README-offline.md`: document all targets selected by default.
- Modify `README.md`: document the x64 Windows build example and default installer behavior.
- Modify `test/prepare_offline_release.tests.ps1`: test default metadata and `x64_win` wrapper ownership.
- Modify `test/finalize_offline_install.tests.ps1`: strengthen selected/deselected component assertions.

---

### Task 1: Add Failing Tests For Default Components And x64 Payload Ownership

**Files:**
- Modify: `test/prepare_offline_release.tests.ps1`
- Modify: `test/finalize_offline_install.tests.ps1`

- [ ] **Step 1: Update prepare test expectations**

Replace the current default component assertions in `test/prepare_offline_release.tests.ps1`:

```powershell
Assert-Equal -Actual $layout.defaultComponents.Count -Expected 1 -Message "layout should keep a single default component"
Assert-Equal -Actual $layout.defaultComponents[0] -Expected "armv7" -Message "layout should default to armv7"
```

with:

```powershell
Assert-Equal -Actual $layout.defaultComponents.Count -Expected 3 -Message "layout should default to all target components"
Assert-True -Condition ($layout.defaultComponents -contains "armv7") -Message "layout should default to armv7"
Assert-True -Condition ($layout.defaultComponents -contains "aarch64") -Message "layout should default to aarch64"
Assert-True -Condition ($layout.defaultComponents -contains "x64_win") -Message "layout should default to x64_win"
```

Add these assertions after the existing `x64_win` staged build-script assertion:

```powershell
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "x64_win\tools\wrappers\x86_64-w64-mingw32-gcc.cmd")) -Message "x64_win payload should contain its cmd wrapper"
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetsRoot "x64_win\tools\wrappers\x86_64-w64-mingw32-gcc.ps1")) -Message "x64_win payload should contain its PowerShell wrapper"
```

- [ ] **Step 2: Strengthen finalize test expectations**

In `test/finalize_offline_install.tests.ps1`, after the assertion that `scripts\rust_build_aarch64.ps1` is removed, add:

```powershell
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $tempRoot "scripts\rust_build_x64_win.ps1")) -Message "selected x64_win component files should remain installed"
```

- [ ] **Step 3: Run prepare test and verify RED**

Run:

```powershell
.\test\prepare_offline_release.tests.ps1
```

Expected: FAIL with `layout should default to all target components` because `DefaultComponents` currently contains only `armv7`.

- [ ] **Step 4: Run finalize test**

Run:

```powershell
.\test\finalize_offline_install.tests.ps1
```

Expected: PASS, because this test already selects `x64_win`; the new assertion documents current behavior before implementation.

---

### Task 2: Make x64 Windows Build Use Portable Target Config

**Files:**
- Modify: `config/.cargo/config.toml`
- Modify: `scripts/rust_build_x64_win.ps1`

- [ ] **Step 1: Add x64 Windows Cargo target config**

Append this section to `config/.cargo/config.toml`:

```toml
[target.x86_64-pc-windows-gnu]
linker = "x86_64-w64-mingw32-gcc.cmd"
```

- [ ] **Step 2: Replace the x64 build script implementation**

Replace the body of `scripts/rust_build_x64_win.ps1` with:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $env:RUST_PORTABLE_CROSS_ROOT -or -not $env:CARGO_HOME -or -not $env:RUSTUP_HOME) {
    throw "Toolkit environment is not active. Run .\scripts\rust_env.ps1 from the toolkit repository first."
}

if (-not (Test-Path -LiteralPath ".\Cargo.toml")) {
    throw "Cargo.toml not found in $(Get-Location). Change into a Rust project directory first."
}

$toolkitRoot = $env:RUST_PORTABLE_CROSS_ROOT
$configSource = Join-Path $toolkitRoot "config\.cargo\config.toml"
$cargoDir = Join-Path (Get-Location) ".cargo"
$configTarget = Join-Path $cargoDir "config.toml"

if (-not (Test-Path -LiteralPath $configSource)) {
    throw "Missing toolkit Cargo config at $configSource"
}

$wrapperPath = Join-Path $toolkitRoot "tools\wrappers\x86_64-w64-mingw32-gcc.cmd"
if (-not (Test-Path -LiteralPath $wrapperPath)) {
    throw "Windows x64 support is not installed. Missing wrapper: $wrapperPath"
}

New-Item -ItemType Directory -Path $cargoDir -Force | Out-Null
Copy-Item -LiteralPath $configSource -Destination $configTarget -Force

cargo build --release --target x86_64-pc-windows-gnu
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed for x86_64-pc-windows-gnu with exit code $LASTEXITCODE."
}

Write-Host "Build output: $(Join-Path (Get-Location) 'target\x86_64-pc-windows-gnu\release')"
```

- [ ] **Step 3: Run setup tests**

Run:

```powershell
.\test\rust_setup.tests.ps1
```

Expected: PASS. This change should not affect download/config helper tests.

---

### Task 3: Make All Target Components Default In Staging And Installer

**Files:**
- Modify: `scripts/prepare_offline_release.ps1`
- Modify: `packaging/inno/rust_portable_cross.iss`

- [ ] **Step 1: Change default component metadata**

In `scripts/prepare_offline_release.ps1`, replace:

```powershell
$script:DefaultComponents = @("armv7")
```

with:

```powershell
$script:DefaultComponents = @("armv7", "aarch64", "x64_win")
```

- [ ] **Step 2: Change Inno component defaults**

In `packaging/inno/rust_portable_cross.iss`, replace:

```ini
Name: "armv7"; Description: "ARMv7 Linux support"; Types: default custom
Name: "aarch64"; Description: "AArch64 Linux support"; Types: custom
Name: "x64_win"; Description: "Windows x64 support"; Types: custom
```

with:

```ini
Name: "armv7"; Description: "ARMv7 Linux support"; Types: default custom
Name: "aarch64"; Description: "AArch64 Linux support"; Types: default custom
Name: "x64_win"; Description: "Windows x64 support"; Types: default custom
```

- [ ] **Step 3: Run prepare test and verify GREEN**

Run:

```powershell
.\test\prepare_offline_release.tests.ps1
```

Expected: PASS.

- [ ] **Step 4: Run finalize test**

Run:

```powershell
.\test\finalize_offline_install.tests.ps1
```

Expected: PASS.

---

### Task 4: Update Customer And Repository Documentation

**Files:**
- Modify: `docs/customer/README-offline.md`
- Modify: `README.md`

- [ ] **Step 1: Update customer installer default text**

In `docs/customer/README-offline.md`, replace:

```markdown
- `armv7` is selected by default.
- Only the selected target payloads are installed.
```

with:

```markdown
- All target components are selected by default.
- You can use custom installation to deselect one or more target payloads.
- Only the selected target payloads are installed.
```

- [ ] **Step 2: Add x64 Windows quick-start example**

In `README.md`, after the ARMv7 build example block, add:

~~~markdown
```powershell
# Build for Windows x64 GNU
cd my_project
. D:\rust-portable-cross\scripts\rust_env.ps1
rust_build_x64_win.ps1
```
~~~

- [ ] **Step 3: Add offline installer default note**

In `README.md`, under "Customer offline installer flow", add:

```markdown
By default the installer selects all target components. Customers can choose custom installation to deselect `armv7`, `aarch64`, or `x64_win`.
```

- [ ] **Step 4: Search for stale default wording**

Run:

```powershell
rg -n "armv7.*selected by default|single default|default to armv7|Types: custom" README.md docs scripts test packaging
```

Expected: no stale documentation or test wording that says only `armv7` defaults. The Inno `custom` setup type definition may still match if the search is broad; verify target component lines all include `default custom`.

---

### Task 5: Run Full Verification And Review Diff

**Files:**
- No planned edits unless verification finds a defect.

- [ ] **Step 1: Run all PowerShell tests**

Run:

```powershell
.\test\rust_setup.tests.ps1
.\test\prepare_offline_release.tests.ps1
.\test\finalize_offline_install.tests.ps1
```

Expected: all PASS.

- [ ] **Step 2: Refresh offline staging**

Run:

```powershell
.\scripts\prepare_offline_release.ps1
```

Expected: staging completes and summary includes `armv7`, `aarch64`, and `x64_win` payload counts. This may require the repository-local `tools/` payload to be present.

- [ ] **Step 3: Inspect generated layout defaults**

Run:

```powershell
Get-Content -Raw 'dist\staging\core\install-layout.json' | ConvertFrom-Json | Select-Object -ExpandProperty defaultComponents
```

Expected output contains:

```text
armv7
aarch64
x64_win
```

- [ ] **Step 4: Review git diff**

Run:

```powershell
git diff --check
git diff -- README.md docs/customer/README-offline.md config/.cargo/config.toml scripts/rust_build_x64_win.ps1 scripts/prepare_offline_release.ps1 packaging/inno/rust_portable_cross.iss test/prepare_offline_release.tests.ps1 test/finalize_offline_install.tests.ps1
```

Expected: `git diff --check` reports no whitespace errors; diff matches the approved spec.

- [ ] **Step 5: Commit implementation**

Run:

```powershell
git add README.md docs/customer/README-offline.md config/.cargo/config.toml scripts/rust_build_x64_win.ps1 scripts/prepare_offline_release.ps1 packaging/inno/rust_portable_cross.iss test/prepare_offline_release.tests.ps1 test/finalize_offline_install.tests.ps1
git commit -m "feat: make x64 windows support portable by default"
```

Expected: commit succeeds after all tests pass.

---

## Self-Review

- Spec coverage: The plan covers portable x64 build flow, default-all installer behavior, component ownership, tests, docs, and verification.
- Placeholder scan: No `TBD`, `TODO`, or unspecified implementation steps remain.
- Type consistency: Component names are consistently `armv7`, `aarch64`, and `x64_win`; Windows target triple is consistently `x86_64-pc-windows-gnu`; wrapper name is consistently `x86_64-w64-mingw32-gcc.cmd`.
