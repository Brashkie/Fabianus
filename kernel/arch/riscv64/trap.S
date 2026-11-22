/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * Entrada común de traps en modo supervisor: cambia a la pila de traps, guarda
 * el estado completo en un fb_trap_frame y llama al manejador en Zig.
 *
 * sscratch contiene la cima de la pila de traps. Usarla permite atender incluso
 * un desbordamiento de la pila del kernel, que golpea su página de guarda.
 */
#include "fabianus.h"

    .section .text.trap, "ax", @progbits
    .global fb_trap_entry
    .type fb_trap_entry, @function
    .balign 4
fb_trap_entry:
    csrrw   sp, sscratch, sp
    addi    sp, sp, -FB_TF_SIZE

    /* Todos los registros salvo x0 (siempre cero) y sp (se guarda aparte). */
    .irp reg, 1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    sd      x\reg, (FB_TF_REGS + \reg * 8)(sp)
    .endr

    csrr    t0, sscratch
    sd      t0, (FB_TF_REGS + 2 * 8)(sp)

    /* El hart de este hilo está justo encima de su pila de traps: el usuario
       puede haber cambiado tp, y el kernel lo necesita. */
    ld      tp, (FB_TF_SIZE + 8)(sp)

    csrr    t0, sepc
    sd      t0, FB_TF_SEPC(sp)
    csrr    t0, sstatus
    sd      t0, FB_TF_SSTATUS(sp)
    csrr    t0, scause
    sd      t0, FB_TF_SCAUSE(sp)
    csrr    t0, stval
    sd      t0, FB_TF_STVAL(sp)

    mv      a0, sp
    call    fb_trap_handler

    ld      t0, FB_TF_SEPC(sp)
    csrw    sepc, t0
    ld      t0, FB_TF_SSTATUS(sp)
    csrw    sstatus, t0

    .irp reg, 1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    ld      x\reg, (FB_TF_REGS + \reg * 8)(sp)
    .endr

    /* Vuelve a la pila interrumpida y deja en sscratch la cima de la de traps. */
    addi    sp, sp, FB_TF_SIZE
    csrrw   sp, sscratch, sp
    sret
    .size fb_trap_entry, . - fb_trap_entry
