<#
.SYNOPSIS
    Build, flash and (optionally) verify the HEM6801E blink firmware over SWD
    with a SEGGER J-Link.

.DESCRIPTION
    The active application slot starts at 0x08008000 (the first 32 KiB of flash
    hold the bootloader and the user-data sector), so the raw .bin is programmed
    at that address. After programming, the script resets the MCU and lets it
    run; the D16 (FAULT) and D17 (STATUS) LEDs then blink alternately at 1 Hz.

    -Verify additionally halts the core after ~0.5 s, reads the GPIOF/GPIOG
    output-data registers (OCTL) twice half a second apart, and prints them so
    you can confirm PF14 / PG15 are actually toggling without watching the board.

    Prerequisites:
      * Activate the toolkit once from the repo root:  . .\scripts\rust_env.ps1
      * SEGGER J-Link Software installed (JLink.exe on PATH, or pass -JLinkExe).

.EXAMPLE
    . .\scripts\rust_env.ps1
    .\sample_embedded\flash_jlink.ps1

.EXAMPLE
    .\sample_embedded\flash_jlink.ps1 -Verify
#>
param(
    # J-Link target device name for the GD32F427ZE (Cortex-M4F).
    [string]$Device = "GD32F427ZE",
    # SWD interface clock in kHz.
    [int]$SpeedKHz = 4000,
    # Path to JLink.exe; resolved from PATH by default.
    [string]$JLinkExe = "JLink.exe",
    # Also read back the LED port registers to confirm the pins toggle.
    [switch]$Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $PSCommandPath

# Active-app slot base; must match link.x ORIGIN(FLASH) and Reset's SCB->VTOR.
$AppBase = "0x08008000"
# LED port output-data registers (OCTL): GPIOF base+0x14, GPIOG base+0x14.
$GpiofOctl = "0x40021414"  # PF14 = D16 (FAULT)
$GpiogOctl = "0x40021814"  # PG15 = D17 (STATUS)

Push-Location $here
try {
    $jlink = Get-Command $JLinkExe -ErrorAction SilentlyContinue
    if (-not $jlink) {
        throw "JLink.exe not found. Install SEGGER J-Link Software or pass -JLinkExe <path>."
    }

    # 1) Build + emit the flashable images (sample_embedded.bin / .hex).
    & (Join-Path $here "make_image.ps1")

    $bin = Join-Path $here "sample_embedded.bin"
    if (-not (Test-Path -LiteralPath $bin)) { throw "Image not found: $bin" }

    # 2) Generate a J-Link command file: program the raw .bin at the app base,
    #    reset and run.
    $cmd = @"
si SWD
speed $SpeedKHz
halt
loadbin "$bin" $AppBase
verifybin "$bin" $AppBase
r
go
"@
    if ($Verify) {
        # Sample the LED ports half a second apart; the two reads should differ
        # (PF14/PG15 swap each 500 ms half-period).
        $cmd += @"

sleep 500
halt
mem32 $GpiofOctl 1
mem32 $GpiogOctl 1
sleep 500
mem32 $GpiofOctl 1
mem32 $GpiogOctl 1
go
"@
    }
    $cmd += "`nqc`n"

    $script = Join-Path $here "flash_jlink.gen.jlink"
    Set-Content -LiteralPath $script -Value $cmd -Encoding ascii

    # 3) Run J-Link.
    Write-Host ""
    Write-Host "Flashing $bin -> $AppBase on $Device (SWD @ ${SpeedKHz} kHz)..."
    & $jlink.Source -device $Device -if SWD -speed $SpeedKHz -autoconnect 1 -CommanderScript $script
    if ($LASTEXITCODE -ne 0) { throw "JLink.exe failed with exit code $LASTEXITCODE." }

    Write-Host ""
    Write-Host "Done. The D16 (FAULT) and D17 (STATUS) LEDs should now blink alternately at 1 Hz."
    if ($Verify) {
        Write-Host "Check the two OCTL reads above: bit 14 of GPIOF and bit 15 of GPIOG"
        Write-Host "should be set in opposite samples (0x00004000 <-> 0x00008000)."
    }
}
finally {
    Pop-Location
}
