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
| D16 (FAULT) LED | `PF14`, **active-low** (drive low = on) | `led_pins[FAULT_LED]` |
| D17 (STATUS) LED | `PG15`, **active-low** (drive low = on) | `led_pins[STATUS_LED]` |
| Blink timing | SysTick @ IRC16M (16 MHz), 500 ms half-period | — |

> The first 32 KiB of flash are reserved for the bootloader (`0x08000000`, 16 KiB)
> and a user-data sector (`0x08004000`, 16 KiB). The application therefore starts
> at `0x08008000`; `Reset` sets `SCB->VTOR = 0x08008000` to match.

## Front-panel LED pin reference (from `hem6801c_app`)

| LED | GPIO | Polarity |
| --- | --- | --- |
| xSPEED | `PE0` | active-low |
| STATUS | `PG15` | active-low |
| FAULT  | `PF14` | active-low |

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
  slot). Do **not** write it at `0x08000000`, which holds the bootloader.

After flashing and resetting (or letting the bootloader jump to the app), the
D16 (FAULT) and D17 (STATUS) LEDs blink alternately at 1 Hz.

## How it works

The crate is deliberately dependency-free so it builds fully offline against
`core` alone:

- `src/main.rs` — vector table, `Reset` (`.bss`/`.data` init + `VTOR`), the
  clock setup, the SysTick-timed 1 Hz alternating-blink loop using direct
  GD32F427 register access, and a panic handler.
- `src/lib.rs` — the original `core`-only smoke-test routines (`checksum`,
  `saturating_total`), still compiled as a standalone `rlib` to exercise the
  installed `core` for the target.
- `link.x` — memory map + Cortex-M section layout (placed on the linker search
  path by `build.rs`).
- `.cargo/config.toml` — selects the `thumbv7em-none-eabihf` target and passes
  `-Tlink.x` to the bundled `rust-lld`.
