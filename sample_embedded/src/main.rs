#![no_std]
#![no_main]

//! Ready-to-flash firmware for the **HEM6801E** mainboard (MCU `U9`, a
//! GigaDevice **GD32F427ZE** Cortex-M4F).
//!
//! It blinks the two front-panel LEDs **`D16` (FAULT)** and **`D17` (STATUS)**
//! alternately at **1 Hz** (each LED is on for 500 ms per 1 s cycle, the two
//! never on together).
//!
//! Hardware configuration matches the production C application (`hem6801c_app`):
//!
//! * **Start address `0x08008000`.** The first 32 KiB of flash hold a
//!   bootloader (16 KiB) and a user-data sector (16 KiB); the active
//!   application lives at `0x08008000..0x0803FFFF` (224 KiB). `Reset` also
//!   points the vector table there via `SCB->VTOR`, exactly as the C app's
//!   `Main_HwInit` does.
//! * **LED pins, active-low.** `D16` (FAULT) is `PF14` and `D17` (STATUS) is
//!   `PG15` (see `led_pins[]` in hem6801c_app). The C driver
//!   `DRV_PANEL_LED_Onoff` lights a panel LED by driving its pin *low*
//!   (`gpio_bit_reset`), so this example does the same.
//!
//! Timing is derived from SysTick after forcing the system clock to the
//! known 16 MHz internal oscillator (IRC16M), so the 1 Hz rate is accurate
//! regardless of the clock state the bootloader left behind.
//!
//! The example is intentionally dependency-free: it provides its own
//! Cortex-M vector table, reset routine and linker script (`link.x`), so it
//! links with the bundled `rust-lld` against `core` alone and builds fully
//! offline. `cargo build --release` produces an ELF that `rust-objcopy`
//! converts into the `.bin` / `.hex` images you download to the board (see
//! `make_image.ps1` and `README.md`).

use core::panic::PanicInfo;
use core::ptr::{addr_of, addr_of_mut, read_volatile, write_volatile};

// ---------------------------------------------------------------------------
// Memory-mapped registers.
//
// The GD32F427 reuses the STM32F4 peripheral memory map verbatim, so these
// addresses match both vendors' reference manuals.
// ---------------------------------------------------------------------------

/// System Control Block vector table offset register (`SCB->VTOR`).
const SCB_VTOR: *mut u32 = 0xE000_ED08 as *mut u32;
/// Base address of the active application / its vector table.
const APP_BASE: u32 = 0x0800_8000;

// SysTick (24-bit down-counter clocked from the processor clock).
const SYST_CSR: *mut u32 = 0xE000_E010 as *mut u32; // control & status
const SYST_RVR: *mut u32 = 0xE000_E014 as *mut u32; // reload value
const SYST_CVR: *mut u32 = 0xE000_E018 as *mut u32; // current value

// RCU (RCC-compatible) clock control.
const RCU_CTL: *mut u32 = 0x4002_3800 as *mut u32; // RCU_CTL  (osc enable/ready)
const RCU_CFG0: *mut u32 = 0x4002_3808 as *mut u32; // RCU_CFG0 (system clock switch)
const RCU_AHB1EN: *mut u32 = 0x4002_3830 as *mut u32; // AHB1 peripheral clock enable

// GPIO ports F and G (base + control/bit-operate registers).
const GPIOF_CTL: *mut u32 = 0x4002_1400 as *mut u32;
const GPIOF_BOP: *mut u32 = 0x4002_1418 as *mut u32;
const GPIOG_CTL: *mut u32 = 0x4002_1800 as *mut u32;
const GPIOG_BOP: *mut u32 = 0x4002_1818 as *mut u32;

/// AHB1 enable bit for GPIOF (port F is the 6th GPIO, bit 5).
const GPIOF_CLOCK_EN: u32 = 1 << 5;
/// AHB1 enable bit for GPIOG (port G is the 7th GPIO, bit 6).
const GPIOG_CLOCK_EN: u32 = 1 << 6;

/// D16 (FAULT) LED is on `PF14`.
const D16_PIN: u32 = 14;
/// D17 (STATUS) LED is on `PG15`.
const D17_PIN: u32 = 15;

/// IRC16M internal oscillator frequency, used as the deterministic core clock.
const CORE_CLOCK_HZ: u32 = 16_000_000;

/// Reset handler: the second word of the vector table and the program entry.
///
/// Initialises the `.bss`/`.data` sections that the linker script lays out,
/// then hands control to [`main`]. Marked `unsafe` because it touches raw
/// linker symbols before the Rust runtime invariants are established.
#[no_mangle]
pub unsafe extern "C" fn Reset() -> ! {
    extern "C" {
        static mut __sbss: u32;
        static mut __ebss: u32;
        static mut __sdata: u32;
        static mut __edata: u32;
        static __sidata: u32;
    }

    // Relocate the vector table to the application base, matching the C app
    // (`SCB->VTOR = FLASH_BASE | 0x00008000`). Required for interrupts to be
    // fetched from this image rather than the bootloader's table.
    write_volatile(SCB_VTOR, APP_BASE);

    // Zero the .bss section.
    let mut dst = addr_of_mut!(__sbss);
    let bss_end = addr_of_mut!(__ebss);
    while dst < bss_end {
        write_volatile(dst, 0);
        dst = dst.add(1);
    }

    // Copy the .data section from its flash load address into RAM.
    let mut dst = addr_of_mut!(__sdata);
    let data_end = addr_of_mut!(__edata);
    let mut src = addr_of!(__sidata);
    while dst < data_end {
        write_volatile(dst, read_volatile(src));
        dst = dst.add(1);
        src = src.add(1);
    }

    main()
}

/// Alternate the D16 (FAULT) and D17 (STATUS) LEDs at 1 Hz, forever.
fn main() -> ! {
    unsafe {
        // Force a known core clock so the SysTick-based delay is accurate.
        select_irc16m_clock();

        // Enable the GPIOF and GPIOG peripheral clocks.
        write_volatile(
            RCU_AHB1EN,
            read_volatile(RCU_AHB1EN) | GPIOF_CLOCK_EN | GPIOG_CLOCK_EN,
        );

        // Configure PF14 (D16) and PG15 (D17) as push-pull outputs (MODER = 01).
        configure_output(GPIOF_CTL, D16_PIN);
        configure_output(GPIOG_CTL, D17_PIN);

        loop {
            // Phase A: D16 on, D17 off. (active-low: low = on, high = off)
            led_on(GPIOF_BOP, D16_PIN);
            led_off(GPIOG_BOP, D17_PIN);
            delay_ms(500);

            // Phase B: D16 off, D17 on.
            led_off(GPIOF_BOP, D16_PIN);
            led_on(GPIOG_BOP, D17_PIN);
            delay_ms(500);
        }
    }
}

/// Select the 16 MHz internal RC oscillator (IRC16M) as the system clock.
///
/// Switching *down* to IRC16M is always safe (no extra flash wait states are
/// needed) and gives a deterministic core frequency no matter what the
/// bootloader configured.
unsafe fn select_irc16m_clock() {
    // Ensure IRC16M is enabled and stable.
    write_volatile(RCU_CTL, read_volatile(RCU_CTL) | 1); // IRC16MEN
    while read_volatile(RCU_CTL) & (1 << 1) == 0 {} // wait IRC16MSTB

    // System clock switch (SCS, bits [1:0]) = 00 -> IRC16M.
    write_volatile(RCU_CFG0, read_volatile(RCU_CFG0) & !0b11);
    // Wait until the switch status (SCSS, bits [3:2]) reports IRC16M.
    while read_volatile(RCU_CFG0) & 0b1100 != 0 {}
}

/// Configure a GPIO pin as a push-pull general-purpose output.
unsafe fn configure_output(ctl: *mut u32, pin: u32) {
    let mut moder = read_volatile(ctl);
    moder &= !(0b11 << (pin * 2));
    moder |= 0b01 << (pin * 2);
    write_volatile(ctl, moder);
}

/// Turn an active-low LED on by driving its pin low (BOP high half = reset).
unsafe fn led_on(bop: *mut u32, pin: u32) {
    write_volatile(bop, 1 << (pin + 16));
}

/// Turn an active-low LED off by driving its pin high (BOP low half = set).
unsafe fn led_off(bop: *mut u32, pin: u32) {
    write_volatile(bop, 1 << pin);
}

/// Busy-wait `ms` milliseconds using SysTick at the 16 MHz core clock.
///
/// At 16 MHz a 500 ms delay is 8,000,000 cycles, which fits in SysTick's 24-bit
/// reload (max 16,777,215), so each half-period is a single reload.
unsafe fn delay_ms(ms: u32) {
    let cycles = ms * (CORE_CLOCK_HZ / 1000);
    write_volatile(SYST_CSR, 0); // disable
    write_volatile(SYST_RVR, cycles - 1); // reload value
    write_volatile(SYST_CVR, 0); // clear current value and COUNTFLAG
    write_volatile(SYST_CSR, 0b101); // CLKSOURCE = processor clock, ENABLE
    while read_volatile(SYST_CSR) & (1 << 16) == 0 {} // wait COUNTFLAG
    write_volatile(SYST_CSR, 0); // disable
}

// ---------------------------------------------------------------------------
// Cortex-M vector table.
//
// Word 0 (initial stack pointer) is emitted by the linker script. The reset
// vector and the core system exceptions are placed here and KEEP'd by
// `link.x`.
// ---------------------------------------------------------------------------

/// Reset vector (table word 1).
#[link_section = ".vector_table.reset_vector"]
#[no_mangle]
pub static RESET_VECTOR: unsafe extern "C" fn() -> ! = Reset;

/// Catch-all handler for the system exceptions we do not service.
#[allow(non_snake_case)]
#[no_mangle]
pub extern "C" fn DefaultExceptionHandler() -> ! {
    loop {
        core::hint::spin_loop();
    }
}

/// One entry in the exception part of the vector table: either a handler
/// address or a reserved (zero) word.
#[repr(C)]
pub union Vector {
    handler: unsafe extern "C" fn() -> !,
    reserved: usize,
}

/// Core system exceptions, vector-table words 2..=15.
#[link_section = ".vector_table.exceptions"]
#[no_mangle]
pub static EXCEPTIONS: [Vector; 14] = [
    Vector { handler: DefaultExceptionHandler }, // 2  NMI
    Vector { handler: DefaultExceptionHandler }, // 3  HardFault
    Vector { handler: DefaultExceptionHandler }, // 4  MemManage
    Vector { handler: DefaultExceptionHandler }, // 5  BusFault
    Vector { handler: DefaultExceptionHandler }, // 6  UsageFault
    Vector { reserved: 0 },                      // 7  Reserved
    Vector { reserved: 0 },                      // 8  Reserved
    Vector { reserved: 0 },                      // 9  Reserved
    Vector { reserved: 0 },                      // 10 Reserved
    Vector { handler: DefaultExceptionHandler }, // 11 SVCall
    Vector { reserved: 0 },                      // 12 DebugMonitor
    Vector { reserved: 0 },                      // 13 Reserved
    Vector { handler: DefaultExceptionHandler }, // 14 PendSV
    Vector { handler: DefaultExceptionHandler }, // 15 SysTick
];

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {
        core::hint::spin_loop();
    }
}
