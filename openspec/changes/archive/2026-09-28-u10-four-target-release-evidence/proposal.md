## Why

The release smoke builds all four targets, but only checks that output files exist. A wrong-architecture binary or firmware mapped outside its flash slot could therefore pass. The Full CI lane also cannot invoke any target checks because its script-check closure loses access to the PowerShell runner function.

## What Changes

- Make Full CI actually execute its four existing target checks, with a regression test for the child runner.
- Add release-gate inspection of the actual Windows PE, ARMv7/AArch64 Linux ELF, and Thumbv7EM firmware ELF/BIN/HEX outputs, including current ABI and load-address baselines.
- Record these artifact checks in the installed-EXE verification report and add negative cases for wrong architecture and malformed image metadata.

## Capabilities

### New Capabilities

- `four-target-artifact-evidence`: The release gate checks the identity and key runtime/load properties of each produced target artifact.

### Modified Capabilities

- `delivered-release-verification`: Publication requires four-target artifact checks after the staged and actual-EXE builds.

## Impact

Internal CI runner, release smoke and validation scripts, tests, and OpenSpec. Public build commands, parameters, target triples, package layout, installer naming, and user project configuration remain unchanged. Broader cc-rs/host-C provenance and Linux or board runtime testing remain in the later U10 work described by the upgrade plan.
