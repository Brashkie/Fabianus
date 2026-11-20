OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

PAGE_SIZE = 4K;
STACK_SIZE = 16K;
TRAP_STACK_SIZE = 8K;

SECTIONS
{
    .text : ALIGN(PAGE_SIZE) {
        __text_start = .;
        KEEP(*(.text._start))
        *(.text .text.*)
        . = ALIGN(PAGE_SIZE);
        __text_end = .;
    } > RAM

    .rodata : ALIGN(PAGE_SIZE) {
        __rodata_start = .;
        *(.srodata .srodata.*)
        *(.rodata .rodata.*)
        . = ALIGN(PAGE_SIZE);
        __rodata_end = .;
    } > RAM

    .data : ALIGN(PAGE_SIZE) {
        __data_start = .;
        *(.sdata .sdata.*)
        *(.data .data.*)
    } > RAM

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
        . = ALIGN(PAGE_SIZE);
        __data_end = .;
    } > RAM

    /* Cada pila queda debajo de una página sin mapear, su página de guarda. */
    .stacks (NOLOAD) : ALIGN(PAGE_SIZE) {
        __stack_guard = .;
        . += PAGE_SIZE;
        __stack_bottom = .;
        . += STACK_SIZE;
        __stack_top = .;

        __trap_stack_guard = .;
        . += PAGE_SIZE;
        __trap_stack_bottom = .;
        . += TRAP_STACK_SIZE;
        __trap_stack_top = .;

        /* Siete hilos con: guarda, pila, guarda y pila de traps (32 KiB cada uno). */
        . = ALIGN(PAGE_SIZE);
        __thread_area_start = .;
        . += 7 * 32K;
        __thread_area_end = .;

        /* Tres harts secundarios con: guarda, pila, guarda y pila de traps
           (32 KiB cada uno). */
        . = ALIGN(PAGE_SIZE);
        __hart_area_start = .;
        . += 3 * 32K;
        __hart_area_end = .;

        __image_end = .;
    } > RAM

    /DISCARD/ : {
        *(.eh_frame .eh_frame_hdr)
        *(.comment)
        *(.note .note.*)
    }
}
