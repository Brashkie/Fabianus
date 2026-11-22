/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * Comprueba que un trap conserva todos los registros: carga en cada uno un
 * valor distinto, provoca un breakpoint y verifica los valores al volver.
 */
#define PATTERN 0x5a5a0000

    .section .text.selftest, "ax", @progbits
    .global fb_selftest_registers
    .type fb_selftest_registers, @function
fb_selftest_registers:
    addi    sp, sp, -128
    sd      ra, 0(sp)
    sd      gp, 8(sp)
    sd      tp, 16(sp)
    sd      s0, 24(sp)
    sd      s1, 32(sp)
    sd      s2, 40(sp)
    sd      s3, 48(sp)
    sd      s4, 56(sp)
    sd      s5, 64(sp)
    sd      s6, 72(sp)
    sd      s7, 80(sp)
    sd      s8, 88(sp)
    sd      s9, 96(sp)
    sd      s10, 104(sp)
    sd      s11, 112(sp)
    sd      sp, 120(sp)

    .irp reg, 1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\reg, PATTERN + \reg
    .endr

    ebreak

    /* Tras restar su índice, todos deben valer exactamente PATTERN. */
    .irp reg, 1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    addi    x\reg, x\reg, -\reg
    .endr
    .irp reg, 1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30
    bne     x\reg, x31, .Lmismatch
    .endr
    li      t0, PATTERN
    bne     x31, t0, .Lmismatch
    ld      t0, 120(sp)
    bne     t0, sp, .Lmismatch

    li      a0, 0
    j       .Lrestore
.Lmismatch:
    li      a0, 1
.Lrestore:
    ld      ra, 0(sp)
    ld      gp, 8(sp)
    ld      tp, 16(sp)
    ld      s0, 24(sp)
    ld      s1, 32(sp)
    ld      s2, 40(sp)
    ld      s3, 48(sp)
    ld      s4, 56(sp)
    ld      s5, 64(sp)
    ld      s6, 72(sp)
    ld      s7, 80(sp)
    ld      s8, 88(sp)
    ld      s9, 96(sp)
    ld      s10, 104(sp)
    ld      s11, 112(sp)
    addi    sp, sp, 128
    ret
    .size fb_selftest_registers, . - fb_selftest_registers

/*
 * uint64_t fb_selftest_callee_saved(void (*call)(void), uint64_t seed)
 * Comprueba que llamar a `call`, que cambia de hilo, conserva s0-s11.
 */
    .global fb_selftest_callee_saved
    .type fb_selftest_callee_saved, @function
fb_selftest_callee_saved:
    addi    sp, sp, -112
    sd      ra, 0(sp)
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11
    sd      s\n, (8 + \n * 8)(sp)
    .endr
    sd      a1, 104(sp)

    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11
    addi    s\n, a1, \n
    .endr
    jalr    a0

    ld      t1, 104(sp)
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11
    addi    t2, t1, \n
    bne     s\n, t2, .Lcallee_mismatch
    .endr
    li      a0, 0
    j       .Lcallee_restore
.Lcallee_mismatch:
    li      a0, 1
.Lcallee_restore:
    ld      ra, 0(sp)
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11
    ld      s\n, (8 + \n * 8)(sp)
    .endr
    addi    sp, sp, 112
    ret
    .size fb_selftest_callee_saved, . - fb_selftest_callee_saved

/*
 * uint64_t fb_selftest_preempt_spin(uint64_t *counter, const uint64_t *stop)
 * Mantiene patrones en casi todos los registros y los verifica sin parar hasta
 * que *stop deja de ser 0. Si la expropiación corrompe alguno, devuelve 1.
 */
    .global fb_selftest_preempt_spin
    .type fb_selftest_preempt_spin, @function
fb_selftest_preempt_spin:
    addi    sp, sp, -128
    sd      ra, 0(sp)
    sd      gp, 8(sp)
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11
    sd      s\n, (16 + \n * 8)(sp)
    .endr

    .irp reg, 1,5,6,7,8,9,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\reg, PATTERN + \reg
    .endr

.Lspin_check:
    .irp reg, 1,5,6,7,8,9,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      gp, PATTERN + \reg
    bne     x\reg, gp, .Lspin_mismatch
    .endr
    ld      gp, 0(a1)
    bnez    gp, .Lspin_done
    ld      gp, 0(a0)
    addi    gp, gp, 1
    sd      gp, 0(a0)
    j       .Lspin_check

.Lspin_done:
    li      a0, 0
    j       .Lspin_restore
.Lspin_mismatch:
    li      a0, 1
.Lspin_restore:
    ld      ra, 0(sp)
    ld      gp, 8(sp)
    .irp n, 0,1,2,3,4,5,6,7,8,9,10,11
    ld      s\n, (16 + \n * 8)(sp)
    .endr
    addi    sp, sp, 128
    ret
    .size fb_selftest_preempt_spin, . - fb_selftest_preempt_spin
