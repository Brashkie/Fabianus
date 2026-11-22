/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * Imagen plana del driver. El kernel la copia al inicio de la ventana de usuario
 * con permisos de lectura y ejecución, y le da una pila aparte.
 */
ENTRY(_start)

SECTIONS
{
    . = 0x100000000;

    .text : {
        *(.text.entry)
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    }

    /* Esta imagen no se puede escribir: cualquier dato mutable es un error. */
    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
    }

    /DISCARD/ : {
        *(.eh_frame .eh_frame_hdr .comment .note .note.*)
    }

    ASSERT(SIZEOF(.data) == 0, "el driver no puede tener datos globales modificables")
}
