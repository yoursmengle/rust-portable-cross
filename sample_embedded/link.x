/* Linker script for the HEM6801E mainboard's MCU U9: a GigaDevice GD32F427ZE
 * (ARM Cortex-M4F, LQFP144).
 *
 * Flash layout matches the production C application (hem6801c_app); the first
 * 32 KiB of flash are reserved for the bootloader and user-data sector, so the
 * application image is linked at 0x08008000:
 *
 *   bootloader  : 0x08000000 .. 0x08003FFF   16 KiB
 *   user data   : 0x08004000 .. 0x08007FFF   16 KiB
 *   active app  : 0x08008000 .. 0x0803FFFF  224 KiB  <-- this firmware
 *   factory app : 0x08040000 .. 0x0807FFFF  256 KiB
 *
 *   SRAM        : 192 KiB @ 0x20000000  (SRAM0 112K + SRAM1 16K + SRAM2 64K,
 *                                        contiguous; TCM/ADD SRAM left unused)
 *
 * This script is self-contained: it defines the memory map, the Cortex-M
 * vector-table layout and the standard sections, so the crate links with the
 * bundled rust-lld alone -- no cortex-m-rt and no external linker script.
 */

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08008000, LENGTH = 224K
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 192K
}

/* Initial stack pointer: top of RAM (full-descending stack). */
_stack_start = ORIGIN(RAM) + LENGTH(RAM);

/* Program entry point (see `Reset` in src/main.rs). */
ENTRY(Reset);

SECTIONS
{
    /* The vector table must sit at the start of flash so the Cortex-M core
     * fetches the initial SP and reset vector from 0x08000000 on power-up. */
    .vector_table ORIGIN(FLASH) :
    {
        /* Word 0: initial stack pointer. */
        LONG(_stack_start);
        /* Word 1: reset vector. */
        KEEP(*(.vector_table.reset_vector));
        /* Words 2..=15: core system exceptions. */
        KEEP(*(.vector_table.exceptions));
        /* Words 16.. : external (peripheral) interrupts. */
        KEEP(*(.vector_table.interrupts));
    } > FLASH

    .text :
    {
        *(.text .text.*);
        . = ALIGN(4);
    } > FLASH

    .rodata :
    {
        *(.rodata .rodata.*);
        . = ALIGN(4);
    } > FLASH

    /* Bootloader application-validity signature. The HEM6801E bootloader's
     * is_app_valid() compares 32 bytes at FL_CONST_DATA_ADDR (0x0800A000)
     * against its flashConstData[] table; without a match it refuses to jump
     * to this app. Pin the bytes (see APP_SIGNATURE in src/main.rs) at that
     * absolute address, i.e. app base (0x08008000) + 0x2000. */
    .app_signature 0x0800A000 :
    {
        KEEP(*(.app_signature));
    } > FLASH

    /* Initialised data: lives in RAM at run time, but its initial image is
     * stored in flash (LMA) and copied across by `Reset`. */
    .data :
    {
        . = ALIGN(4);
        __sdata = .;
        *(.data .data.*);
        . = ALIGN(4);
        __edata = .;
    } > RAM AT > FLASH
    __sidata = LOADADDR(.data);

    /* Zero-initialised data, cleared by `Reset`. */
    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __sbss = .;
        *(.bss .bss.*);
        *(COMMON);
        . = ALIGN(4);
        __ebss = .;
    } > RAM

    /* No unwinding on a panic=abort bare-metal target. */
    /DISCARD/ :
    {
        *(.ARM.exidx .ARM.exidx.*);
        *(.ARM.extab .ARM.extab.*);
    }
}
