# sample_embedded — HEM6801E firmware example

A ready-to-flash bare-metal (`no_std`) Rust firmware for the **HEM6801E**
mainboard. It blinks the two front-panel LEDs **`D16` (FAULT)** and
**`D17` (STATUS)** alternately at **1 Hz** — each LED is on for 500 ms per 1 s
cycle, and the two are never lit at the same time.

The hardware configuration is kept consistent with the production C application
(`hem6801c_app`) so the generated image runs in the same slot on the same board.

| Item | Value | Source |
| --- | --- | --- |
| MCU (`U9`) | GigaDevice **GD32F427ZE** (Cortex-M4F, LQFP144) | board BOM |
| Flash start (this app) | **`0x08008000`** | `hem6801c_app` flash map / `SCB->VTOR` |
| Flash size (app slot) | 224 KiB (`0x08008000..0x0803FFFF`) | `hem6801c_app` flash map |
| SRAM | 192 KiB @ `0x20000000` | GD32F427 (SRAM0+1+2) |
| D16 (FAULT) LED | `PF14`, **active-high** (drive high = on) | `led_status()` (`gpio_bit_set`) |
| D17 (STATUS) LED | `PG15`, **active-high** (drive high = on) | `led_can()` (`gpio_bit_set`) |
| Blink timing | SysTick @ IRC16M (16 MHz), 500 ms half-period | — |

> The first 32 KiB of flash are reserved for the bootloader (`0x08000000`, 16 KiB)
> and a user-data sector (`0x08004000`, 16 KiB). The application therefore starts
> at `0x08008000`; `Reset` sets `SCB->VTOR = 0x08008000` to match.

## Front-panel LED pin reference (from `hem6801c_app`)

| LED | GPIO | Polarity |
| --- | --- | --- |
| xSPEED | `PE0` | active-high |
| STATUS | `PG15` | active-high |
| FAULT  | `PF14` | active-high |

## Build

Activate the toolkit environment once (from the toolkit root), then build:

```powershell
# from the toolkit root
. .\scripts\rust_env.ps1

# build + generate the flashable images
.\sample_embedded\make_image.ps1
```

`make_image.ps1` builds the firmware and runs `rust-objcopy` to produce, next to
itself:

- `sample_embedded.bin` — raw image; **flash it at `0x08008000`**
- `sample_embedded.hex` — Intel HEX; already carries the `0x08008000` address

To build only the ELF (no image conversion):

```powershell
cd sample_embedded
..\scripts\rust_build_thumbv7em.ps1
# ELF: target\thumbv7em-none-eabihf\release\sample_embedded
```

## Flash to the board

Use any tool that targets the GD32F427 (GD-Link, J-Link/J-Flash, or the
bootloader's update path):

- **`.hex`** — load as-is; the address (`0x08008000`) is embedded.
- **`.bin`** — set the download base address to **`0x08008000`** (the active-app
  slot). Do **not** write it at `0x08000000`, which holds the bootloader. This is
  also the address the CAN updater (`hem_upgrade.py`) writes to.

### With a SEGGER J-Link (SWD)

`flash_jlink.ps1` builds the image and programs it over SWD in one step
(`JLink.exe` must be installed):

```powershell
# from the toolkit root
. .\scripts\rust_env.ps1
.\sample_embedded\flash_jlink.ps1            # build + flash + run
.\sample_embedded\flash_jlink.ps1 -Verify    # also read back PF14/PG15 to confirm toggling
```

It programs `sample_embedded.bin` at `0x08008000`, verifies, then resets and
runs. With `-Verify` it halts twice 500 ms apart and prints the GPIOF/GPIOG
output-data registers (OCTL): bit 14 of GPIOF (`0x40021414`) and bit 15 of
GPIOG (`0x40021814`) read set in *opposite* samples (`0x00004000` ↔
`0x00008000`), proving the LEDs alternate even without eyeballing the board.
Override the target with `-Device`, `-SpeedKHz`, or `-JLinkExe` as needed.

After flashing and resetting (or letting the bootloader jump to the app), the
D16 (FAULT) and D17 (STATUS) LEDs blink alternately at 1 Hz.

> **Re-flashing note.** This demo keeps interrupts masked and does **not** run
> the CAN protocol, so it cannot respond to the updater's "jump to bootloader"
> command. To load another image, recover through the bootloader's own power-on
> update window (start `hem_upgrade.py`, then power-cycle the board so the
> bootloader catches the start frame) or use an SWD debugger (GD-Link/J-Link).

## Passing the bootloader's app-validity check

The HEM6801E bootloader will only hand control to the active app once its
`is_app_valid(ACTIVE_APP_IDX)` check passes. That check requires **all** of:

1. `app_valid_flag1 = 0x10353533` and `app_valid_flag2 = 0x20230216` in the
   app-info record at `0x08005000` (the `DOWNLOAD_DATA_ADDR_BASE` user-data
   page), with `app_addr_base = 0x08008000`;
2. the active app's first word (initial SP) satisfying `SP & 0x2FFC0000 ==
   0x20000000` — ours is `0x20030000`, so this holds;
3. a **32-byte signature** at `FL_CONST_DATA_ADDR = 0x0800A000` byte-matching the
   bootloader's `flashConstData[]` table (`"PROCSHEM6801-01-"` + date + zero
   padding).

The app-info record (1) is written by the bootloader itself during a CAN
download (`hem_upgrade.py`), so a board provisioned that way already has it. The
signature (3), however, sits at app base + `0x2000`; in the production C app it
happens to fall inside the image, but a small example must place it there
explicitly. `src/main.rs` defines `APP_SIGNATURE` and `link.x` pins it at
`0x0800A000`, so the generated `.bin`/`.hex` carry it. **Without this signature
the image is otherwise perfect yet the bootloader silently refuses to start it,
and the LEDs never light** — this was the original "flashed but dead" symptom.

> If you flash a *virgin* board over SWD (one that was never CAN-downloaded), the
> app-info record (1) is still missing, so program it once at `0x08005000`
> alongside the image, or do the initial load through `hem_upgrade.py` so the
> bootloader writes it for you.

## Booting behind the bootloader

The board's bootloader hands control to the app with a **soft jump**, not a
hardware reset, so SysTick / the NVIC / peripheral interrupts can still be live
from the boot phase. If the application's vector table is incomplete, a
left-over interrupt vectors into code and the board appears dead. To be robust,
`Reset` therefore, before anything else:

1. masks interrupts (`cpsid i`) and keeps them masked (the blink loop polls,
   it needs no interrupts),
2. stops SysTick and disables/clears every NVIC line,
3. sets `SCB->VTOR = 0x08008000` (with `dsb`/`isb`).

The firmware also ships a **full-length vector table** (the 16 system vectors
plus all 82 GD32F427 peripheral-interrupt slots, all routed to a safe default
handler), mirroring the production C application.

## How it works

The crate is deliberately dependency-free so it builds fully offline against
`core` alone:

- `src/main.rs` — full vector table, `Reset` (interrupt sanitise + `VTOR` +
  `.bss`/`.data` init), the clock setup, the SysTick-timed 1 Hz
  alternating-blink loop using direct GD32F427 register access, and a panic
  handler.
- `src/lib.rs` — the original `core`-only smoke-test routines (`checksum`,
  `saturating_total`), still compiled as a standalone `rlib` to exercise the
  installed `core` for the target.
- `link.x` — memory map + Cortex-M section layout (placed on the linker search
  path by `build.rs`).
- `.cargo/config.toml` — selects the `thumbv7em-none-eabihf` target and passes
  `-Tlink.x` to the bundled `rust-lld`.
