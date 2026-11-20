/*
 * Primer código de Fabianus. Con `-bios none`, QEMU entra aquí en modo máquina
 * y deja en a0 el identificador del hart. Este archivo prepara el procesador
 * y baja a modo supervisor, donde se ejecuta el kernel.
 */
#include "fabianus.h"

#define MSTATUS_MPP_MASK   (3 << 11)
#define MSTATUS_MPP_S      (1 << 11)
/* Supervisor puede leer los contadores time e instret. */
#define MCOUNTEREN_TM_IR   6
#define PMP_NAPOT(base, size) (((base) | ((size) / 2 - 1)) >> 2)
#define PMP_DEVICE_SIZE    0x1000
/* Entrada 0: RAM con RWX. Entradas 1 a 4: dispositivos con RW. Todas NAPOT.
   La 4 son solo las palabras msip del CLINT: el supervisor puede avisar a
   otros harts, pero no tocar mtimecmp. */
#define PMP_CONFIG         0x1b1b1b1b1f
/* Excepciones 0-8, 12, 13 y 15. La llamada desde supervisor sigue en modo M. */
#define MEDELEG_KERNEL     0xb1ff
/* Interrupciones de software, timer y externas de supervisor. */
#define MIDELEG_SUPERVISOR 0x222
/* La interrupción de software de máquina es el aviso de otro hart. */
#define MIE_MSIE           (1 << 3)
#define MIP_SSIP           (1 << 1)
#define MCAUSE_MSI         0x8000000000000003

    .section .text._start, "ax", @progbits
    .global _start
    .type _start, @function
_start:
    /* Sin interrupciones, y cualquier trap temprano termina detenido. */
    csrw    mie, zero
    csrci   mstatus, 0x8
    la      t0, park
    csrw    mtvec, t0

    /* Los harts que el kernel no usa se quedan aparcados. */
    csrr    a0, mhartid
    li      t0, FB_MAX_HARTS
    bgeu    a0, t0, park

    /* Cada hart prepara sus propios registros de modo máquina. */
    call    machine_setup

    li      t0, FB_BOOT_HART
    bne     a0, t0, secondary

    /* El código compilado asume que .bss empieza en cero. */
    la      t0, __bss_start
    la      t1, __bss_end
1:
    bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:
    la      sp, __stack_top
    mv      tp, a0

    /* mret continúa en fb_kmain, ya en modo supervisor. */
    li      t0, MSTATUS_MPP_MASK
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S
    csrs    mstatus, t0
    la      t0, fb_kmain
    csrw    mepc, t0
    mret

    /*
     * Un hart secundario espera a que el kernel lo suelte. La señal está en
     * .data: el hart de arranque borra .bss mientras tanto. Luego toma su pila
     * y baja a fb_secondary_main (a0 = hart) en modo supervisor.
     */
secondary:
    la      t0, fb_harts_release
1:  ld      t1, 0(t0)
    beqz    t1, 1b
    fence   r, rw

    la      t0, __hart_area_start
    addi    t1, a0, -1
    li      t2, 0x8000
    mul     t1, t1, t2
    add     t0, t0, t1
    li      t2, 0x1000 + FB_HART_STACK_SIZE
    add     sp, t0, t2
    mv      tp, a0

    li      t0, MSTATUS_MPP_MASK
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S
    csrs    mstatus, t0
    la      t0, fb_secondary_main
    csrw    mepc, t0
    mret

    /* Registros de modo máquina de este hart. Deja en a1 si hay Sstc. */
machine_setup:
    /* El modo supervisor solo puede tocar la RAM y los tres dispositivos. */
    li      t0, PMP_NAPOT(FB_RAM_BASE, FB_RAM_SIZE)
    csrw    pmpaddr0, t0
    li      t0, PMP_NAPOT(FB_UART0_BASE, PMP_DEVICE_SIZE)
    csrw    pmpaddr1, t0
    li      t0, PMP_NAPOT(FB_TEST_FINISHER_BASE, PMP_DEVICE_SIZE)
    csrw    pmpaddr2, t0
    li      t0, PMP_NAPOT(FB_PLIC_BASE, FB_PLIC_SIZE)
    csrw    pmpaddr3, t0
    li      t0, PMP_NAPOT(FB_CLINT_BASE, FB_CLINT_MSIP_SIZE)
    csrw    pmpaddr4, t0
    li      t0, PMP_CONFIG
    csrw    pmpcfg0, t0

    li      t0, MEDELEG_KERNEL
    csrw    medeleg, t0
    li      t0, MIDELEG_SUPERVISOR
    csrw    mideleg, t0

    /* Pide el timer de supervisor (Sstc). a1 indica si el hardware lo tiene. */
    li      t0, 1
    slli    t0, t0, 63
    csrs    menvcfg, t0
    csrr    t1, menvcfg
    srli    a1, t1, 63
    li      t0, MCOUNTEREN_TM_IR
    csrw    mcounteren, t0

    /* Los avisos entre harts llegan a modo máquina y se pasan al supervisor. */
    la      t0, fb_machine_scratch
    slli    t1, a0, 4
    add     t0, t0, t1
    csrw    mscratch, t0
    la      t0, machine_trap
    csrw    mtvec, t0
    li      t0, MIE_MSIE
    csrw    mie, t0
    ret

    /*
     * Único trap que modo máquina atiende una vez arrancado el kernel: el aviso
     * de otro hart (msip). Lo borra y levanta la interrupción de software de
     * supervisor de este hart, que es la que atiende el kernel. Cualquier otra
     * causa detiene el hart.
     */
    .balign 4
machine_trap:
    csrrw   sp, mscratch, sp
    sd      t0, 0(sp)
    sd      t1, 8(sp)
    csrr    t0, mcause
    li      t1, MCAUSE_MSI
    bne     t0, t1, park
    csrr    t0, mhartid
    slli    t0, t0, 2
    li      t1, FB_CLINT_BASE
    add     t0, t0, t1
    sw      zero, 0(t0)
    li      t0, MIP_SSIP
    csrs    mip, t0
    ld      t0, 0(sp)
    ld      t1, 8(sp)
    csrrw   sp, mscratch, sp
    mret

    .balign 4
park:
    wfi
    j       park
    .size _start, . - _start

    /* Dos registros guardados por hart mientras atiende un aviso. */
    .section .data
    .balign 16
fb_machine_scratch:
    .space  16 * FB_MAX_HARTS
