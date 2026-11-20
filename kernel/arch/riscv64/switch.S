/*
 * Cambio de contexto entre hilos del kernel. Solo guarda lo que la convención
 * de llamada obliga a conservar: el resto ya lo salvó quien llamó.
 *
 * sscratch forma parte del contexto: dentro de un trap guarda la pila
 * interrumpida, y fuera de él la cima de la pila de traps del hilo.
 */
#include "fabianus.h"

    .section .text.switch, "ax", @progbits
    .global fb_context_switch
    .type fb_context_switch, @function
fb_context_switch:
    sd      ra, FB_CTX_RA(a0)
    sd      sp, FB_CTX_SP(a0)
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11
    sd      s\n, (FB_CTX_S0 + \n * 8)(a0)
    .endr
    csrr    t0, sscratch
    sd      t0, FB_CTX_SSCRATCH(a0)

    ld      t0, FB_CTX_SSCRATCH(a1)
    csrw    sscratch, t0
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11
    ld      s\n, (FB_CTX_S0 + \n * 8)(a1)
    .endr
    ld      sp, FB_CTX_SP(a1)
    ld      ra, FB_CTX_RA(a1)
    ret
    .size fb_context_switch, . - fb_context_switch

/* Primer código de un hilo nuevo. s0: función, s1: argumento, s2: interrupciones. */
    .global fb_thread_start
    .type fb_thread_start, @function
fb_thread_start:
    /* Suelta el cerrojo del kernel que tenía quien le cedió la CPU. */
    call    fb_thread_begin
    beqz    s2, 1f
    csrsi   sstatus, 2
1:
    mv      a0, s1
    jalr    s0
    call    fb_thread_exit
    .size fb_thread_start, . - fb_thread_start

#define SSTATUS_SIE  (1 << 1)
#define SSTATUS_SPIE (1 << 5)
#define SSTATUS_SPP  (1 << 8)
#define SSTATUS_SUM  (1 << 18)
#define SSTATUS_MXR  (1 << 19)

/*
 * Baja a modo usuario. a0: pc, a1: pila, a2: argumento. sscratch ya contiene la
 * cima de la pila de traps del hilo, que es donde entrará el próximo trap.
 * Ningún registro del kernel llega al usuario.
 */
    .global fb_enter_user
    .type fb_enter_user, @function
fb_enter_user:
    csrci   sstatus, SSTATUS_SIE
    li      t0, (SSTATUS_SPP | SSTATUS_SUM | SSTATUS_MXR)
    csrc    sstatus, t0
    li      t0, SSTATUS_SPIE
    csrs    sstatus, t0
    csrw    sepc, a0
    mv      sp, a1
    mv      a0, a2
    .irp reg, 1,3,4,5,6,7,8,9,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\reg, 0
    .endr
    sret
    .size fb_enter_user, . - fb_enter_user
