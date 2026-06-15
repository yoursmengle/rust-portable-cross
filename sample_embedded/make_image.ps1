Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Build the HEM6801E firmware and emit downloadable .bin / .hex images.
#
# Prerequisites: activate the toolkit environment first, from the toolkit root:
#     . .\scripts\rust_env.ps1
# That puts cargo and rust-objcopy on PATH.
#
# Output (written next to this script):
#     sample_embedded.bin   raw image, flash it at 0x08008000
#     sample_embedded.hex   Intel HEX, already carries the 0x08008000 address

$here = Split-Path -Parent $PSCommandPath
Push-Location $here
try {
    if (-not (Get-Command rust-objcopy -ErrorAction SilentlyContinue)) {
        throw "rust-objcopy not found on PATH. Activate the toolkit first: . .\scripts\rust_env.ps1"
    }

    # 1) Build the firmware ELF with the bundled bare-metal toolchain.
    & (Join-Path $here "..\scripts\rust_build_thumbv7em.ps1")

    $elf = Join-Path $here "target\thumbv7em-none-eabihf\release\sample_embedded"
    if (-not (Test-Path -LiteralPath $elf)) {
        throw "Firmware ELF not found: $elf. Did the build succeed?"
    }

    $bin = Join-Path $here "sample_embedded.bin"
    $hex = Join-Path $here "sample_embedded.hex"

    # 2) Convert ELF -> raw binary and Intel HEX with the bundled LLVM objcopy.
    rust-objcopy -O binary $elf $bin
    if ($LASTEXITCODE -ne 0) { throw "rust-objcopy (binary) failed with exit code $LASTEXITCODE." }
    rust-objcopy -O ihex $elf $hex
    if ($LASTEXITCODE -ne 0) { throw "rust-objcopy (ihex) failed with exit code $LASTEXITCODE." }

    Write-Host ""
    Write-Host "Generated flashable images for the HEM6801E active-app slot (0x08008000):"
    Write-Host ("  {0}  ({1} bytes)" -f $bin, (Get-Item $bin).Length)
    Write-Host ("  {0}  ({1} bytes)" -f $hex, (Get-Item $hex).Length)
}
finally {
    Pop-Location
}
