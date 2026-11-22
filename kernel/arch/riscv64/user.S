/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * Programas de usuario de las autopruebas. Son datos para el kernel: se copian
 * a marcos propios del proceso y solo se ejecutan allí, en modo usuario.
 * Todos son independientes de la posición.
 */
#include "fabianus.h"

    .option norelax
    .section .rodata.user, "a", @progbits

.macro SYS number
    li      a7, \number
    ecall
.endm

.macro BEGIN name
    .balign 8
\name\()_start:
.endm

.macro END name
    .balign 4
\name\()_end:
.endm

/* Si la instrucción prohibida no falla, el programa termina con este código. */
.macro SURVIVED
    li      a0, 99
    SYS     FB_SYS_EXIT
.endm

BEGIN hello
    li      a2, 2f - 1f
    lla     a1, 1f
    li      a0, 0
    SYS     FB_SYS_WRITE
    li      a0, 7
    SYS     FB_SYS_EXIT
1:  .ascii  "hola desde modo usuario\n"
2:
END hello

/* Registros que una llamada debe conservar: todos salvo a0, que es el resultado. */
#define KEPT_REGISTERS 1,2,3,4,5,6,7,8,9,11,12,13,14,15,16,18,19,20,21,22,23,24,25,26,27,28,29,30,31

BEGIN registers
    /* Nada del kernel debe llegar al usuario: solo sp tiene valor al entrar. */
    .irp n, 1,3,4,5,6,7,8,9,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    bnez    x\n, 1f
    .endr

    .irp n, KEPT_REGISTERS
    li      x\n, (0x5a00 + \n)
    .endr
    li      a7, FB_SYS_THREAD_ID
    ecall
    .irp n, KEPT_REGISTERS
    li      a0, (0x5a00 + \n)
    bne     x\n, a0, 1f
    .endr
    li      a0, FB_SYS_THREAD_ID
    bne     a7, a0, 1f
    li      a0, 0
    SYS     FB_SYS_EXIT
1:  li      a0, 1
    SYS     FB_SYS_EXIT
END registers

/* Bucle infinito: solo el timer puede quitarle la CPU. Comprueba sus registros. */
BEGIN spin
    .irp n, 8,9,18,19,20,21,22,23,24,25,26,27
    li      x\n, (0x7700 + \n)
    .endr
1:
    .irp n, 8,9,18,19,20,21,22,23,24,25,26,27
    li      t0, (0x7700 + \n)
    bne     x\n, t0, 2f
    .endr
    j       1b
2:  li      a0, 1
    SYS     FB_SYS_EXIT
END spin

/* Guarda un valor propio en la pila y comprueba que nadie lo cambia. */
BEGIN isolated
    mv      s0, a0
    addi    s1, sp, -2048
    addi    s1, s1, -2048
    sd      s0, 0(s1)
    li      s2, 64
1:  SYS     FB_SYS_YIELD
    ld      t0, 0(s1)
    bne     t0, s0, 2f
    addi    s0, s0, 1
    sd      s0, 0(s1)
    addi    s2, s2, -1
    bnez    s2, 1b
    li      a0, 0
    SYS     FB_SYS_EXIT
2:  li      a0, 1
    SYS     FB_SYS_EXIT
END isolated

/* La memoria recién entregada no debe conservar nada de un dueño anterior. */
BEGIN zerocheck
    li      t0, (FB_USER_STACK_TOP - FB_USER_STACK_PAGES * 4096)
    li      t1, FB_USER_STACK_TOP
1:  ld      t2, 0(t0)
    bnez    t2, 3f
    addi    t0, t0, 8
    bltu    t0, t1, 1b

    lla     t0, zerocheck_end
    li      t1, (FB_USER_BASE + 4096)
2:  lbu     t2, 0(t0)
    bnez    t2, 3f
    addi    t0, t0, 1
    bltu    t0, t1, 2b

    li      a0, 0
    SYS     FB_SYS_EXIT
3:  li      a0, 1
    SYS     FB_SYS_EXIT
END zerocheck

/*
 * Intenta que el kernel use direcciones que no le pertenecen al proceso.
 * Termina con 0, o con el número de la comprobación que falló.
 */
.macro EXPECT_RESULT check, expected
    li      t0, \expected
    li      s0, \check
    bne     a0, t0, deputy_failed
.endm

BEGIN deputy
    li      a2, 16
    li     a1, 0x80000000
    li      a0, 0
    SYS     FB_SYS_WRITE
    EXPECT_RESULT 1, FB_ERR_FAULT

    li      a2, 8
    li     a1, FB_UART0_BASE
    li      a0, 0
    SYS     FB_SYS_WRITE
    EXPECT_RESULT 2, FB_ERR_FAULT

    li      a2, (FB_SYS_WRITE_MAX + 1)
    lla     a1, deputy_text
    li      a0, 0
    SYS     FB_SYS_WRITE
    EXPECT_RESULT 3, FB_ERR_INVALID

    li      a2, 16
    li     a1, -8
    li      a0, 0
    SYS     FB_SYS_WRITE
    EXPECT_RESULT 4, FB_ERR_FAULT

    li      a2, 16
    li     a1, (FB_USER_STACK_TOP - 8)
    li      a0, 0
    SYS     FB_SYS_WRITE
    EXPECT_RESULT 5, FB_ERR_FAULT

    li      a2, 8
    li     a1, (FB_USER_BASE + 0x200000)
    li      a0, 0
    SYS     FB_SYS_WRITE
    EXPECT_RESULT 6, FB_ERR_FAULT

    li      a2, 0
    lla     a1, deputy_text
    li      a0, 0
    SYS     FB_SYS_WRITE
    EXPECT_RESULT 7, 0

    li      a0, 0
    SYS     999
    EXPECT_RESULT 8, FB_ERR_NOSYS

    /* Cruzar entre dos páginas válidas sí está permitido. */
    li      t1, 0x2e2e2e2e2e2e2e2e
    li      t2, 0x0a2e2e2e2e2e2e2e
    li      t0, (FB_USER_STACK_TOP - 4096 - 8)
    sd      t1, 0(t0)
    sd      t2, 8(t0)
    li      a2, 16
    li     a1, (FB_USER_STACK_TOP - 4096 - 8)
    li      a0, 0
    SYS     FB_SYS_WRITE
    EXPECT_RESULT 9, 16

    li      a0, 0
    SYS     FB_SYS_EXIT
deputy_failed:
    mv      a0, s0
    SYS     FB_SYS_EXIT
deputy_text:
    .ascii  "x"
END deputy

BEGIN fault_csr
    csrr    t0, sstatus
    SURVIVED
END fault_csr

BEGIN fault_sret
    sret
    SURVIVED
END fault_sret

BEGIN fault_load_kernel
    li      t0, 0x80000000
    ld      t1, 0(t0)
    SURVIVED
END fault_load_kernel

BEGIN fault_store_kernel
    li      t0, 0x80000000
    sd      t1, 0(t0)
    SURVIVED
END fault_store_kernel

BEGIN fault_jump_kernel
    li      t0, 0x80000000
    jr      t0
    SURVIVED
END fault_jump_kernel

BEGIN fault_store_text
    lla     t0, fault_store_text_start
    sd      t1, 0(t0)
    SURVIVED
END fault_store_text

BEGIN fault_exec_stack
    addi    t0, sp, -16
    jr      t0
    SURVIVED
END fault_exec_stack

BEGIN fault_stack_guard
    li      t0, (FB_USER_STACK_TOP - FB_USER_STACK_PAGES * 4096 - 8)
    sd      t1, 0(t0)
    SURVIVED
END fault_stack_guard

BEGIN fault_device
    li      t0, FB_UART0_BASE
    sb      t1, 0(t0)
    SURVIVED
END fault_device

/* Solo se lanzan en la compilación de medida, donde instret es legible. */
.macro BENCH_LOOP number
    csrr    s0, instret
    li      s1, 4096
1:  SYS     \number
    addi    s1, s1, -1
    bnez    s1, 1b
    csrr    t0, instret
    sub     a0, t0, s0
    SYS     FB_SYS_EXIT
.endm

BEGIN bench_syscall
    BENCH_LOOP FB_SYS_THREAD_ID
END bench_syscall

BEGIN bench_yield
    BENCH_LOOP FB_SYS_YIELD
END bench_yield

/* Comprueba un resultado y, si falla, salta a `label` con el número de prueba. */
.macro EXPECT_AT label, check, expected
    li      t0, \expected
    li      s0, \check
    bne     a0, t0, \label
.endm

.macro NO_TRANSFER
    li      a5, FB_CAP_SLOT_NONE
.endm

/* Sin capabilities: ninguna operación con autoridad puede funcionar. */
BEGIN no_caps
    li      a0, 0
    lla     a1, no_caps_text
    li      a2, 1
    SYS     FB_SYS_WRITE
    EXPECT_AT no_caps_failed, 1, FB_ERR_CAP

    li      a0, 99
    SYS     FB_SYS_WRITE
    EXPECT_AT no_caps_failed, 2, FB_ERR_CAP

    li      a0, -1
    SYS     FB_SYS_WRITE
    EXPECT_AT no_caps_failed, 3, FB_ERR_CAP

    li      a0, 0
    NO_TRANSFER
    SYS     FB_SYS_SEND
    EXPECT_AT no_caps_failed, 4, FB_ERR_CAP

    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    EXPECT_AT no_caps_failed, 5, FB_ERR_CAP

    li      a0, 0
    li      a1, 1
    li      a2, FB_RIGHT_SEND
    SYS     FB_SYS_CAP_DERIVE
    EXPECT_AT no_caps_failed, 6, FB_ERR_CAP

    li      a0, 0
    SYS     FB_SYS_CAP_DELETE
    EXPECT_AT no_caps_failed, 7, FB_ERR_CAP

    li      a0, 0
    SYS     FB_SYS_EXIT
no_caps_failed:
    mv      a0, s0
    SYS     FB_SYS_EXIT
no_caps_text:
    .ascii  "x"
END no_caps

/* Hueco 0: endpoint solo con Send. Hueco 1: consola. */
BEGIN cap_rights
    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    EXPECT_AT cap_rights_failed, 1, FB_ERR_CAP

    li      a0, 0
    li      a1, 2
    li      a2, (FB_RIGHT_SEND | FB_RIGHT_RECV)
    SYS     FB_SYS_CAP_DERIVE
    EXPECT_AT cap_rights_failed, 2, FB_ERR_CAP

    li      a0, 0
    li      a1, 1
    li      a2, FB_RIGHT_SEND
    SYS     FB_SYS_CAP_DERIVE
    EXPECT_AT cap_rights_failed, 3, FB_ERR_CAP

    li      a0, 0
    lla     a1, cap_rights_text
    li      a2, 1
    SYS     FB_SYS_WRITE
    EXPECT_AT cap_rights_failed, 4, FB_ERR_CAP

    li      a0, 0
    li      a1, 2
    li      a2, FB_RIGHT_SEND
    SYS     FB_SYS_CAP_DERIVE
    EXPECT_AT cap_rights_failed, 5, 0

    li      a0, 2
    SYS     FB_SYS_CAP_DELETE
    EXPECT_AT cap_rights_failed, 6, 0

    li      a0, 2
    lla     a1, cap_rights_text
    li      a2, 1
    SYS     FB_SYS_WRITE
    EXPECT_AT cap_rights_failed, 7, FB_ERR_CAP

    li      a0, 2
    SYS     FB_SYS_CAP_DELETE
    EXPECT_AT cap_rights_failed, 8, FB_ERR_CAP

    li      a0, 99
    li      a1, 2
    li      a2, FB_RIGHT_SEND
    SYS     FB_SYS_CAP_DERIVE
    EXPECT_AT cap_rights_failed, 9, FB_ERR_CAP

    li      a0, 0
    li      a1, 99
    li      a2, FB_RIGHT_SEND
    SYS     FB_SYS_CAP_DERIVE
    EXPECT_AT cap_rights_failed, 10, FB_ERR_CAP

    li      a0, 0
    li      a1, 2
    li      a2, 8
    SYS     FB_SYS_CAP_DERIVE
    EXPECT_AT cap_rights_failed, 11, FB_ERR_CAP

    /* Ceder una capability exige Grant sobre el endpoint. */
    li      a0, 0
    li      a5, 1
    SYS     FB_SYS_SEND
    EXPECT_AT cap_rights_failed, 12, FB_ERR_CAP

    li      a0, 0
    SYS     FB_SYS_EXIT
cap_rights_failed:
    mv      a0, s0
    SYS     FB_SYS_EXIT
cap_rights_text:
    .ascii  "x"
END cap_rights

/* Servicio: hueco 0 endpoint con Recv, hueco 1 consola. a1 lleva la longitud. */
BEGIN console_server
    addi    sp, sp, -32
1:  li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 3f
    beqz    a1, 2f
    sd      a2, 0(sp)
    sd      a3, 8(sp)
    sd      a4, 16(sp)
    mv      a2, a1
    mv      a1, sp
    li      a0, 1
    SYS     FB_SYS_WRITE
    j       1b
2:  li      a0, 0
    SYS     FB_SYS_EXIT
3:  li      a0, 1
    SYS     FB_SYS_EXIT
END console_server

/* Cliente sin consola: hueco 0 endpoint con Send. */
BEGIN console_client
    lla     t0, 1f
    ld      a2, 0(t0)
    ld      a3, 8(t0)
    ld      a4, 16(t0)
    li      a1, 16
    li      a0, 0
    NO_TRANSFER
    SYS     FB_SYS_SEND
    bnez    a0, 2f

    li      a0, 0
    li      a1, 0
    NO_TRANSFER
    SYS     FB_SYS_SEND
    bnez    a0, 2f

    li      a0, 0
    SYS     FB_SYS_EXIT
2:  li      a0, 1
    SYS     FB_SYS_EXIT
    .balign 8
1:  .ascii  "cliente via IPC\n\0\0\0\0\0\0\0\0"
END console_client

/* Hueco 0: enviar. Hueco 1: recibir. */
BEGIN ping
    li      s1, 64
    li      s2, 1
1:  mv      a1, s2
    slli    a2, s2, 1
    addi    a3, s2, 7
    not     a4, s2
    li      a0, 0
    NO_TRANSFER
    SYS     FB_SYS_SEND
    bnez    a0, 2f

    li      a0, 1
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 2f
    addi    t0, s2, 1
    bne     a1, t0, 2f
    slli    t0, s2, 1
    bne     a2, t0, 2f
    addi    t0, s2, 7
    bne     a3, t0, 2f

    addi    s2, s2, 1
    addi    s1, s1, -1
    bnez    s1, 1b
    li      a0, 0
    SYS     FB_SYS_EXIT
2:  li      a0, 1
    SYS     FB_SYS_EXIT
END ping

/* Hueco 0: recibir. Hueco 1: enviar. Responde sumando uno al primer valor. */
BEGIN pong
    li      s1, 64
1:  li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 2f
    slli    t0, a1, 1
    bne     a2, t0, 2f
    addi    t0, a1, 7
    bne     a3, t0, 2f
    not     t0, a1
    bne     a4, t0, 2f

    addi    a1, a1, 1
    li      a0, 1
    NO_TRANSFER
    SYS     FB_SYS_SEND
    bnez    a0, 2f

    addi    s1, s1, -1
    bnez    s1, 1b
    li      a0, 0
    SYS     FB_SYS_EXIT
2:  li      a0, 1
    SYS     FB_SYS_EXIT
END pong

/* Hueco 0: endpoint con Send y Grant. Cede la consola del hueco 1. */
BEGIN granter
    li      a0, 0
    li      a1, 0x77
    li      a5, 1
    SYS     FB_SYS_SEND
    SYS     FB_SYS_EXIT
END granter

/* Hueco 0: endpoint con Recv. Solo puede escribir tras recibir la consola. */
BEGIN grantee
    li      a0, 1
    lla     a1, 2f
    li      a2, 3f - 2f
    SYS     FB_SYS_WRITE
    EXPECT_AT grantee_failed, 1, FB_ERR_CAP

    li      a0, 0
    li      a1, 1
    SYS     FB_SYS_RECV
    EXPECT_AT grantee_failed, 2, 0
    mv      a0, a1
    EXPECT_AT grantee_failed, 3, 0x77
    mv      a0, a5
    EXPECT_AT grantee_failed, 4, 1

    li      a0, 1
    lla     a1, 2f
    li      a2, 3f - 2f
    SYS     FB_SYS_WRITE
    EXPECT_AT grantee_failed, 5, (3f - 2f)

    li      a0, 0
    SYS     FB_SYS_EXIT
grantee_failed:
    mv      a0, s0
    SYS     FB_SYS_EXIT
2:  .ascii  "capability concedida\n"
3:
END grantee

/* Envía su argumento por el endpoint del hueco 0. */
BEGIN ipc_sender
    mv      a1, a0
    li      a0, 0
    NO_TRANSFER
    SYS     FB_SYS_SEND
    SYS     FB_SYS_EXIT
END ipc_sender

/* Recibe tres valores y devuelve sus dígitos en orden de llegada. */
BEGIN ipc_fifo_receiver
    li      s1, 3
    li      s2, 0
    li      s3, 10
1:  li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    mul     s2, s2, s3
    add     s2, s2, a1
    addi    s1, s1, -1
    bnez    s1, 1b
    mv      a0, s2
    SYS     FB_SYS_EXIT
END ipc_fifo_receiver

/* Espera un mensaje que nunca llega. */
BEGIN ipc_blocked
    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    li      a0, 99
    SYS     FB_SYS_EXIT
END ipc_blocked

BEGIN bench_ping
    csrr    s0, instret
    li      s1, 4096
1:  li      a0, 0
    NO_TRANSFER
    SYS     FB_SYS_SEND
    li      a0, 1
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    addi    s1, s1, -1
    bnez    s1, 1b
    csrr    t0, instret
    sub     a0, t0, s0
    SYS     FB_SYS_EXIT
END bench_ping

BEGIN bench_pong
    li      s1, 4096
1:  li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    li      a0, 1
    NO_TRANSFER
    SYS     FB_SYS_SEND
    addi    s1, s1, -1
    bnez    s1, 1b
    li      a0, 0
    SYS     FB_SYS_EXIT
END bench_pong

/* Imagen del driver en Rust, enlazada para FB_USER_BASE. */
BEGIN uart_driver
    .incbin "uart_driver.bin"
END uart_driver

BEGIN disk_driver
    .incbin "disk_driver.bin"
END disk_driver

/* Sin capabilities: el dispositivo y sus interrupciones están fuera de alcance. */
BEGIN device_denied
    li      a0, 0
    SYS     FB_SYS_DEVICE_MAP
    EXPECT_AT device_denied_failed, 1, FB_ERR_CAP

    li      a0, 0
    li      a1, 1
    SYS     FB_SYS_IRQ_BIND
    EXPECT_AT device_denied_failed, 2, FB_ERR_CAP

    li      a0, 0
    SYS     FB_SYS_IRQ_ACK
    EXPECT_AT device_denied_failed, 3, FB_ERR_CAP

    li      a0, 0
    NO_TRANSFER
    SYS     FB_SYS_TRY_SEND
    EXPECT_AT device_denied_failed, 4, FB_ERR_CAP

    li      a0, 0
    SYS     FB_SYS_EXIT
device_denied_failed:
    mv      a0, s0
    SYS     FB_SYS_EXIT
END device_denied

/* Hueco 0: dispositivo solo con Recv. Hueco 1: solo con Send. Hueco 2: endpoint con Send. */
BEGIN device_rights
    li      a0, 0
    SYS     FB_SYS_DEVICE_MAP
    EXPECT_AT device_rights_failed, 1, FB_ERR_CAP

    li      a0, 1
    li      a1, 2
    SYS     FB_SYS_IRQ_BIND
    EXPECT_AT device_rights_failed, 2, FB_ERR_CAP

    li      a0, 1
    SYS     FB_SYS_IRQ_ACK
    EXPECT_AT device_rights_failed, 3, FB_ERR_CAP

    /* Tener el dispositivo no basta: enlazarlo exige ser su dueño. */
    li      a0, 0
    li      a1, 2
    SYS     FB_SYS_IRQ_BIND
    EXPECT_AT device_rights_failed, 4, FB_ERR_BUSY

    li      a0, 0
    SYS     FB_SYS_IRQ_ACK
    EXPECT_AT device_rights_failed, 5, FB_ERR_INVALID

    /* Una capability de endpoint no es la de un dispositivo. */
    li      a0, 2
    SYS     FB_SYS_DEVICE_MAP
    EXPECT_AT device_rights_failed, 6, FB_ERR_CAP

    /* El envío que no espera no puede ceder capabilities. */
    li      a0, 2
    li      a5, 0
    SYS     FB_SYS_TRY_SEND
    EXPECT_AT device_rights_failed, 7, FB_ERR_INVALID

    li      a0, 0
    SYS     FB_SYS_EXIT
device_rights_failed:
    mv      a0, s0
    SYS     FB_SYS_EXIT
END device_rights

BEGIN device_touch
    li      t0, FB_USER_DEVICE_BASE
    lb      t1, 0(t0)
    SURVIVED
END device_touch

/* Toma la UART, prueba su registro de uso libre y se queda esperando. */
BEGIN device_holder
    li      a0, 0
    SYS     FB_SYS_DEVICE_MAP
    li      t0, FB_USER_DEVICE_BASE
    bne     a0, t0, 1f
    li      t1, 0x5a
    sb      t1, 7(a0)
    lbu     t2, 7(a0)
    bne     t1, t2, 1f

    /* Las interrupciones solo pueden ir a un endpoint del que pueda recibir. */
    li      a0, 0
    li      a1, 5
    SYS     FB_SYS_IRQ_BIND
    li      t0, FB_ERR_CAP
    bne     a0, t0, 1f
    li      a0, 0
    li      a1, 0
    SYS     FB_SYS_IRQ_BIND
    li      t0, FB_ERR_CAP
    bne     a0, t0, 1f

    li      a0, 1
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    li      a0, 98
    SYS     FB_SYS_EXIT
1:  li      a0, 97
    SYS     FB_SYS_EXIT
END device_holder

/* Hueco 0: dispositivo. Hueco 1: consola. La UART ya tiene dueño. */
BEGIN device_thief
    li      a0, 0
    SYS     FB_SYS_DEVICE_MAP
    EXPECT_AT device_thief_failed, 1, FB_ERR_BUSY

    li      a0, 1
    lla     a1, 2f
    li      a2, 1
    SYS     FB_SYS_WRITE
    EXPECT_AT device_thief_failed, 2, FB_ERR_BUSY

    li      a0, 0
    SYS     FB_SYS_EXIT
device_thief_failed:
    mv      a0, s0
    SYS     FB_SYS_EXIT
2:  .ascii  "x"
END device_thief

/* Los registros no se pueden ejecutar. */
BEGIN device_exec
    li      a0, 0
    SYS     FB_SYS_DEVICE_MAP
    li      t0, FB_USER_DEVICE_BASE
    bne     a0, t0, 1f
    jr      a0
1:  SURVIVED
END device_exec

.macro UART_SEND op, length
    li      a1, (\op | (\length << 8))
    li      a0, 0
    NO_TRANSFER
    SYS     FB_SYS_SEND
.endm

/* Hueco 0: peticiones. Ni consola ni dispositivo: todo pasa por el driver. */
BEGIN uart_client
    lla     t0, 2f
    ld      a2, 0(t0)
    ld      a3, 8(t0)
    ld      a4, 16(t0)
    UART_SEND FB_UART_OP_WRITE, 24
    bnez    a0, 1f

    lla     t0, 2f
    ld      a2, 24(t0)
    UART_SEND FB_UART_OP_WRITE, 5
    bnez    a0, 1f

    li      a0, 0
    SYS     FB_SYS_EXIT
1:  li      a0, 1
    SYS     FB_SYS_EXIT
    .balign 8
2:  .ascii  "hola desde el driver en Rust\n\0\0\0"
END uart_client

/* Dos peticiones que el driver debe rechazar sin caerse, y la parada. */
BEGIN uart_stopper
    UART_SEND FB_UART_OP_WRITE, 25
    bnez    a0, 1f
    UART_SEND 99, 0
    bnez    a0, 1f
    UART_SEND FB_UART_OP_STOP, 0
    SYS     FB_SYS_EXIT
1:  li      a0, 1
    SYS     FB_SYS_EXIT
END uart_stopper

/* Hueco 0: entrada. Reúne tres bytes, que pueden llegar en varios mensajes. */
BEGIN uart_reader
    li      s1, 0
    li      s2, 0
1:  li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 3f
    beqz    a1, 3f
    slli    t0, s1, 3
    sll     t1, a2, t0
    or      s2, s2, t1
    add     s1, s1, a1
    li      t0, 3
    bltu    s1, t0, 1b
    bne     s1, t0, 3f
    li      t0, 0x636261
    bne     s2, t0, 3f
    li      a0, 0
    SYS     FB_SYS_EXIT
3:  li      a0, 1
    SYS     FB_SYS_EXIT
END uart_reader

/* Hueco 0: peticiones. La UART se recibe a sí misma. */
BEGIN uart_loop_client
    li      a2, 1
    UART_SEND FB_UART_OP_LOOPBACK, 0
    bnez    a0, 1f

    li      a2, 0x6261
    UART_SEND FB_UART_OP_WRITE, 2
    bnez    a0, 1f

    li      s1, 16
2:  SYS     FB_SYS_YIELD
    addi    s1, s1, -1
    bnez    s1, 2b

    li      a0, 0
    SYS     FB_SYS_EXIT
1:  li      a0, 1
    SYS     FB_SYS_EXIT
END uart_loop_client

/* Se lanza cuando el lector ya tiene todo: parar no puede ser lo que entrega la entrada. */
BEGIN uart_loop_finish
    li      a2, 0
    UART_SEND FB_UART_OP_LOOPBACK, 0
    bnez    a0, 1f
    UART_SEND FB_UART_OP_STOP, 0
    SYS     FB_SYS_EXIT
1:  li      a0, 1
    SYS     FB_SYS_EXIT
END uart_loop_finish

/*
 * Hueco 0: dispositivo. Hueco 1: endpoint. Provoca una interrupción y no la
 * confirma: con argumento 0 la recibe y se queda esperando, con 1 ni la recibe.
 */
BEGIN device_irq_taker
    mv      s1, a0
    li      a0, 0
    SYS     FB_SYS_DEVICE_MAP
    li      t0, FB_USER_DEVICE_BASE
    bne     a0, t0, 3f
    mv      s2, a0

    li      a0, 0
    li      a1, 1
    SYS     FB_SYS_IRQ_BIND
    bnez    a0, 3f

    li      t1, 1
    sb      t1, 1(s2)
    li      t1, 0x10
    sb      t1, 4(s2)
    li      t1, 'z'
    sb      t1, 0(s2)

    bnez    s1, 2f
    li      a0, 1
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    li      t0, FB_MSG_SIGNAL
    bne     a5, t0, 3f

    li      a0, 1
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    li      a0, 98
    SYS     FB_SYS_EXIT

2:  SYS     FB_SYS_YIELD
    j       2b
3:  li      a0, 97
    SYS     FB_SYS_EXIT
END device_irq_taker

/* Deja la UART en modo bucle: quien limpie tras el driver debe arreglarlo. */
BEGIN uart_loop_on
    li      a2, 1
    UART_SEND FB_UART_OP_LOOPBACK, 0
    SYS     FB_SYS_EXIT
END uart_loop_on

BEGIN bench_write
    csrr    s0, instret
    li      s1, 256
1:  li      a0, 0
    lla     a1, 2f
    li      a2, 1
    SYS     FB_SYS_WRITE
    addi    s1, s1, -1
    bnez    s1, 1b
    csrr    t0, instret
    sub     a0, t0, s0
    SYS     FB_SYS_EXIT
2:  .ascii  "."
END bench_write

BEGIN bench_driver_client
    csrr    s0, instret
    li      s1, 256
1:  li      a2, '.'
    UART_SEND FB_UART_OP_WRITE, 1
    addi    s1, s1, -1
    bnez    s1, 1b
    csrr    s2, instret
    sub     s2, s2, s0
    UART_SEND FB_UART_OP_STOP, 0
    mv      a0, s2
    SYS     FB_SYS_EXIT
END bench_driver_client

/* Hueco 0: peticiones. Hueco 1: confirmación del lector. */
BEGIN bench_loop_writer
    li      a2, 1
    UART_SEND FB_UART_OP_LOOPBACK, 0

    csrr    s0, instret
    li      s1, 256
1:  li      a2, 'x'
    UART_SEND FB_UART_OP_WRITE, 1
    li      a0, 1
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    addi    s1, s1, -1
    bnez    s1, 1b
    csrr    s2, instret
    sub     s2, s2, s0

    li      a2, 0
    UART_SEND FB_UART_OP_LOOPBACK, 0
    UART_SEND FB_UART_OP_STOP, 0
    mv      a0, s2
    SYS     FB_SYS_EXIT
END bench_loop_writer

/* Hueco 0: entrada. Hueco 1: confirmación. */
BEGIN bench_loop_reader
    li      s1, 256
1:  li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    sub     s1, s1, a1
    li      a0, 1
    NO_TRANSFER
    SYS     FB_SYS_SEND
    bnez    s1, 1b
    li      a0, 0
    SYS     FB_SYS_EXIT
END bench_loop_reader

.macro CALL_MESSAGE
    li      a0, 0
    NO_TRANSFER
    SYS     FB_SYS_CALL
.endm

/* Hueco 0: endpoint con Send. El argumento es el primer valor; 0 pide parar. */
BEGIN call_client
    mv      s2, a0
    li      s1, 64
1:  mv      a1, s2
    slli    a2, s2, 1
    addi    a3, s2, 7
    not     a4, s2
    CALL_MESSAGE
    bnez    a0, 3f
    bnez    a5, 3f
    addi    t0, s2, 1
    bne     a1, t0, 3f
    slli    t0, s2, 2
    bne     a2, t0, 3f
    addi    t0, s2, 8
    bne     a3, t0, 3f
    not     t0, s2
    bne     a4, t0, 3f

    addi    s2, s2, 1
    addi    s1, s1, -1
    bnez    s1, 1b

    li      a1, 0
    CALL_MESSAGE
    bnez    a0, 3f
    li      a0, 0
    SYS     FB_SYS_EXIT
3:  li      a0, 1
    SYS     FB_SYS_EXIT
END call_client

/* Hueco 0: endpoint con Recv. Termina tras tantas peticiones de parar como su argumento. */
BEGIN call_server
    mv      s1, a0
    /* Un hueco libre: aquí nadie debe poder depositar una capability. */
    li      a1, 5
    li      a0, 0
    SYS     FB_SYS_REPLY_RECV
1:  bnez    a0, 3f
    beqz    a1, 2f
    addi    a1, a1, 1
    slli    a2, a2, 1
    addi    a3, a3, 1
    li      a0, 0
    SYS     FB_SYS_REPLY_RECV
    j       1b
2:  addi    s1, s1, -1
    beqz    s1, 4f
    li      a0, 0
    SYS     FB_SYS_REPLY_RECV
    j       1b
4:  SYS     FB_SYS_REPLY
    bnez    a0, 3f
    li      a0, 0
    SYS     FB_SYS_EXIT
3:  li      a0, 1
    SYS     FB_SYS_EXIT
END call_server

/* Recibe una llamada y termina sin contestarla. */
BEGIN call_server_dies
    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    SYS     FB_SYS_EXIT
END call_server_dies

BEGIN call_expect_peer
    li      a1, 5
    CALL_MESSAGE
    li      t0, FB_ERR_PEER
    bne     a0, t0, 1f
    li      a0, 0
    SYS     FB_SYS_EXIT
1:  li      a0, 1
    SYS     FB_SYS_EXIT
END call_expect_peer

BEGIN send_expect_peer
    li      a0, 0
    li      a1, 5
    NO_TRANSFER
    SYS     FB_SYS_SEND
    li      t0, FB_ERR_PEER
    bne     a0, t0, 1f
    li      a0, 0
    SYS     FB_SYS_EXIT
1:  li      a0, 1
    SYS     FB_SYS_EXIT
END send_expect_peer

/* Hueco 0: endpoint solo con Send. */
BEGIN call_checks
    SYS     FB_SYS_REPLY
    EXPECT_AT call_checks_failed, 1, FB_ERR_INVALID

    li      a0, 5
    NO_TRANSFER
    SYS     FB_SYS_CALL
    EXPECT_AT call_checks_failed, 2, FB_ERR_CAP

    li      a0, 0
    li      a5, 0
    SYS     FB_SYS_CALL
    EXPECT_AT call_checks_failed, 3, FB_ERR_INVALID

    li      a0, 0
    SYS     FB_SYS_REPLY_RECV
    EXPECT_AT call_checks_failed, 4, FB_ERR_CAP

    li      a0, 0
    SYS     FB_SYS_EXIT
call_checks_failed:
    mv      a0, s0
    SYS     FB_SYS_EXIT
END call_checks

/* Recibe una llamada, comprueba que no puede recibir otra y espera a que su cliente muera. */
BEGIN call_server_lost
    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    EXPECT_AT call_server_lost_failed, 1, 0

    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    EXPECT_AT call_server_lost_failed, 2, FB_ERR_INVALID

    /* Duerme hasta que el kernel lo despierte: así sabe que ya pasó por
       aquí antes de matar al cliente. */
    li      a0, -2
    SYS     FB_SYS_SLEEP_UNTIL

    SYS     FB_SYS_REPLY
    EXPECT_AT call_server_lost_failed, 3, FB_ERR_INVALID

    li      a0, 0
    SYS     FB_SYS_EXIT
call_server_lost_failed:
    mv      a0, s0
    SYS     FB_SYS_EXIT
END call_server_lost

BEGIN call_long
    li      s1, 65536
1:  li      a1, 1
    CALL_MESSAGE
    bnez    a0, 2f
    addi    s1, s1, -1
    bnez    s1, 1b
    li      a1, 0
    CALL_MESSAGE
    SYS     FB_SYS_EXIT
2:  li      a0, 1
    SYS     FB_SYS_EXIT
END call_long

/* Contesta dos llamadas: la segunda ya está en cola cuando responde a la primera. */
BEGIN call_server_pair
    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 3f

    mv      s2, a1
    li      s1, 4096
1:  SYS     FB_SYS_YIELD
    addi    s1, s1, -1
    bnez    s1, 1b

    addi    a1, s2, 1
    li      a0, 0
    SYS     FB_SYS_REPLY_RECV
    bnez    a0, 3f
    addi    a1, a1, 1
    SYS     FB_SYS_REPLY
    bnez    a0, 3f
    li      a0, 0
    SYS     FB_SYS_EXIT
3:  li      a0, 1
    SYS     FB_SYS_EXIT
END call_server_pair

/* Una llamada con su argumento; espera el argumento más uno. */
BEGIN call_once
    mv      s2, a0
    mv      a1, a0
    CALL_MESSAGE
    bnez    a0, 1f
    addi    t0, s2, 1
    bne     a1, t0, 1f
    li      a0, 0
    SYS     FB_SYS_EXIT
1:  li      a0, 1
    SYS     FB_SYS_EXIT
END call_once

/* Pide para sí la prioridad del argumento con la capability del hueco 0.
   Si lo consigue, cede la CPU para siempre; si no, sale con el error. */
BEGIN sched_set
    mv      a1, a0
    li      a0, 0
    li      a2, 20000
    SYS     FB_SYS_SCHED_SET
    bnez    a0, 2f
1:  SYS     FB_SYS_YIELD
    j       1b
2:  SYS     FB_SYS_EXIT
END sched_set

/* Se baja a la prioridad del argumento y gira sin volver a entrar al kernel. */
BEGIN sched_lower
    mv      a1, a0
    li      a0, 0
    li      a2, 20000
    SYS     FB_SYS_SCHED_SET
    bnez    a0, 2f
1:  j       1b
2:  SYS     FB_SYS_EXIT
END sched_lower

/*
 * Hueco 0: peticiones. Hueco 1: permiso para contestar. Aplaza la primera
 * llamada, contesta la segunda y, cuando le dan permiso, contesta la primera.
 * Sale con el resultado de esa última respuesta.
 */
BEGIN defer_server
    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 9f
    li      t0, FB_MSG_CALL
    bne     a5, t0, 9f
    mv      s2, a1
    SYS     FB_SYS_DEFER
    bnez    a0, 9f
    mv      s1, a1

    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 9f
    addi    a1, a1, 1
    SYS     FB_SYS_REPLY
    bnez    a0, 9f

    li      a0, 1
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 9f
    mv      a0, s1
    addi    a1, s2, 1
    SYS     FB_SYS_REPLY_TO
    SYS     FB_SYS_EXIT
9:  li      a0, 1
    SYS     FB_SYS_EXIT
END defer_server

/* Hueco 0: endpoint con Send. Da permiso y sale. */
BEGIN go_sender
    li      a0, 0
    NO_TRANSFER
    SYS     FB_SYS_SEND
    SYS     FB_SYS_EXIT
END go_sender

/* Intenta contestar al hilo del argumento sin haberle aplazado nada. */
BEGIN reply_to_other
    li      a1, 0
    SYS     FB_SYS_REPLY_TO
    SYS     FB_SYS_EXIT
END reply_to_other

/* Recibe en el hueco 0 una llamada y la aplaza. */
.macro DEFER_NEXT token, value
    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 9f
    mv      \value, a1
    SYS     FB_SYS_DEFER
    bnez    a0, 9f
    mv      \token, a1
.endm

/* Espera permiso en el hueco 1 y contesta la llamada aplazada con su valor + 1. */
.macro ANSWER_NEXT token, value
    li      a0, 1
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 9f
    mv      a0, \token
    addi    a1, \value, 1
    SYS     FB_SYS_REPLY_TO
    bnez    a0, 9f
.endm

/* Aplaza tres llamadas y, con cada permiso, contesta una: la tercera, la
   segunda y la primera. Sale con 0 si todo fue bien. */
BEGIN defer_three
    DEFER_NEXT s1, s4
    DEFER_NEXT s2, s5
    DEFER_NEXT s3, s6
    ANSWER_NEXT s3, s6
    ANSWER_NEXT s2, s5
    ANSWER_NEXT s1, s4
    li      a0, 0
    SYS     FB_SYS_EXIT
9:  li      a0, 1
    SYS     FB_SYS_EXIT
END defer_three

/* Recibe en el hueco indicado. */
.macro RECV_AT slot
    li      a0, \slot
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 9f
.endm

/* Aplaza una llamada (A) y atiende otras con el valor + 1: B con reply. Tras
   un permiso, recibe C de la cola y la contesta con reply_recv, que recibe D,
   también en cola; aplaza D y la contesta con el siguiente permiso. Luego E con
   reply_recv sin nadie en cola, que recibe F, y F con reply. Con un último
   permiso contesta A. Sale con 0 si todo fue bien. */
BEGIN defer_then_serve
    DEFER_NEXT s1, s4

    RECV_AT 0
    addi    a1, a1, 1
    SYS     FB_SYS_REPLY
    bnez    a0, 9f

    RECV_AT 1
    RECV_AT 0
    addi    a1, a1, 1
    li      a0, 0
    SYS     FB_SYS_REPLY_RECV
    bnez    a0, 9f
    mv      s6, a1
    SYS     FB_SYS_DEFER
    bnez    a0, 9f
    mv      s3, a1
    ANSWER_NEXT s3, s6

    RECV_AT 0
    addi    a1, a1, 1
    li      a0, 0
    SYS     FB_SYS_REPLY_RECV
    bnez    a0, 9f
    addi    a1, a1, 1
    SYS     FB_SYS_REPLY
    bnez    a0, 9f

    ANSWER_NEXT s1, s4
    li      a0, 0
    SYS     FB_SYS_EXIT
9:  li      a0, 1
    SYS     FB_SYS_EXIT
END defer_then_serve

/* Aplaza una llamada y la contesta cuando le dan permiso. */
BEGIN defer_wait
    DEFER_NEXT s1, s4
    ANSWER_NEXT s1, s4
    li      a0, 0
    SYS     FB_SYS_EXIT
9:  li      a0, 1
    SYS     FB_SYS_EXIT
END defer_wait

/* Recibe una llamada, la aplaza y muere sin contestar. */
BEGIN defer_then_die
    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 1f
    SYS     FB_SYS_DEFER
    bnez    a0, 1f
    li      a0, 0
    SYS     FB_SYS_EXIT
1:  li      a0, 1
    SYS     FB_SYS_EXIT
END defer_then_die

/* Pide al driver un tramo de la entrada. Sale con el primer byte o con el error. */
BEGIN uart_call_reader
    li      a1, FB_UART_OP_READ
    CALL_MESSAGE
    bnez    a0, 1f
    li      t0, 24
    bgtu    a1, t0, 2f
    beqz    a1, 1f
    andi    a0, a2, 0xff
    SYS     FB_SYS_EXIT
2:  mv      a0, a1
    SYS     FB_SYS_EXIT
1:  li      a0, 1
    SYS     FB_SYS_EXIT
END uart_call_reader

/* Escribe un byte en bucle y lo lee con una llamada que el driver aplaza. */
/* Lee 256 bytes con call. Cada lectura llega antes que su byte, que escribe
   otro proceso de menos prioridad: el driver la aplaza. */
BEGIN bench_defer_reader
    li      a2, 1
    UART_SEND FB_UART_OP_LOOPBACK, 0

    csrr    s0, instret
    li      s1, 256
1:  li      a1, FB_UART_OP_READ
    CALL_MESSAGE
    sub     s1, s1, a1
    bgtz    s1, 1b
    csrr    s2, instret
    sub     s2, s2, s0

    li      a2, 0
    UART_SEND FB_UART_OP_LOOPBACK, 0
    UART_SEND FB_UART_OP_STOP, 0
    mv      a0, s2
    SYS     FB_SYS_EXIT
END bench_defer_reader

/*
 * Mide la latencia de despertar, como cyclictest: duerme hasta un instante y
 * mide cuánto tarda en volver a correr. a0 = vueltas << 32 | periodo, en
 * unidades del reloj. Sale con la latencia media << 32 | la máxima, o con el
 * bit 63 si alguna vez despertó antes de tiempo.
 */
BEGIN latency_probe
    srli    s1, a0, 32
    slli    s2, a0, 32
    srli    s2, s2, 32
    mv      s4, s1
    li      s5, 0
    li      s6, 0
    rdtime  s3
1:  add     s3, s3, s2
    mv      a0, s3
    SYS     FB_SYS_SLEEP_UNTIL
    rdtime  t0
    bltu    t0, s3, 3f
    sub     t1, t0, s3
    add     s5, s5, t1
    bgeu    s6, t1, 2f
    mv      s6, t1
2:  mv      s3, t0
    addi    s1, s1, -1
    bnez    s1, 1b
    divu    s5, s5, s4
    slli    a0, s5, 32
    or      a0, a0, s6
    SYS     FB_SYS_EXIT
3:  li      a0, 1
    slli    a0, a0, 63
    SYS     FB_SYS_EXIT
END latency_probe

/*
 * Hueco 0: recibe llamadas. Hueco 1: llama al siguiente servidor. Reenvía cada
 * llamada tal cual y contesta con la respuesta que le den. Una llamada con
 * a1 = 0 también se reenvía, y después termina.
 */
BEGIN call_forwarder
    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
1:  bnez    a0, 9f
    mv      s2, a1
    li      a0, 1
    NO_TRANSFER
    SYS     FB_SYS_CALL
    bnez    a0, 9f
    beqz    s2, 2f
    li      a0, 0
    SYS     FB_SYS_REPLY_RECV
    j       1b
2:  SYS     FB_SYS_REPLY
    li      a0, 0
    SYS     FB_SYS_EXIT
9:  li      a0, 1
    SYS     FB_SYS_EXIT
END call_forwarder

/* Duerme hasta un instante muy lejano: solo sale si lo matan. */
BEGIN sleep_forever
    li      a0, -2
    SYS     FB_SYS_SLEEP_UNTIL
    SYS     FB_SYS_EXIT
END sleep_forever

/* Escribe 256 bytes con call, uno por llamada. */
BEGIN bench_defer_writer
    li      s1, 256
1:  li      a1, (FB_UART_OP_WRITE | (1 << 8))
    li      a2, 'x'
    CALL_MESSAGE
    addi    s1, s1, -1
    bnez    s1, 1b
    li      a0, 0
    SYS     FB_SYS_EXIT
END bench_defer_writer

BEGIN bench_call_read
    li      a2, 1
    UART_SEND FB_UART_OP_LOOPBACK, 0

    csrr    s0, instret
    li      s1, 256
1:  li      a1, (FB_UART_OP_WRITE | (1 << 8))
    li      a2, 'x'
    CALL_MESSAGE
    li      a1, FB_UART_OP_READ
    CALL_MESSAGE
    sub     s1, s1, a1
    bgtz    s1, 1b
    csrr    s2, instret
    sub     s2, s2, s0

    li      a2, 0
    UART_SEND FB_UART_OP_LOOPBACK, 0
    UART_SEND FB_UART_OP_STOP, 0
    mv      a0, s2
    SYS     FB_SYS_EXIT
END bench_call_read

/* Espera con reply_recv: la señal pendiente debe llegar como tal. */
BEGIN signal_taker
    li      s1, 256
1:  SYS     FB_SYS_YIELD
    addi    s1, s1, -1
    bnez    s1, 1b
    li      a0, 0
    SYS     FB_SYS_REPLY_RECV
    bnez    a0, 2f
    li      t0, FB_MSG_SIGNAL
    bne     a5, t0, 2f
    li      a0, 0
    SYS     FB_SYS_EXIT
2:  li      a0, 1
    SYS     FB_SYS_EXIT
END signal_taker

BEGIN bench_call
    csrr    s0, instret
    li      s1, 4096
1:  li      a1, 1
    CALL_MESSAGE
    addi    s1, s1, -1
    bnez    s1, 1b
    csrr    s2, instret
    sub     s2, s2, s0
    li      a1, 0
    CALL_MESSAGE
    mv      a0, s2
    SYS     FB_SYS_EXIT
END bench_call

/* Recibe una llamada, gira a0 vueltas y contesta: un servidor ocupado. */
BEGIN call_server_spin
    mv      s1, a0
    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
1:  addi    s1, s1, -1
    bnez    s1, 1b
    SYS     FB_SYS_REPLY
    li      a0, 0
    SYS     FB_SYS_EXIT
END call_server_spin

BEGIN bench_serve
    li      a0, 0
1:  SYS     FB_SYS_REPLY_RECV
    beqz    a1, 2f
    li      a0, 0
    j       1b
2:  SYS     FB_SYS_REPLY
    li      a0, 0
    SYS     FB_SYS_EXIT
END bench_serve

/*
 * Cliente de las medidas con varios harts. a0 = vueltas | qué devolver << 32:
 * 0, las instrucciones de su hart; 1, el tiempo total; 2, la vuelta más larga
 * (tiempos en unidades del reloj). Cada llamada lleva el instante en que se
 * hizo, para que el servidor mida cuánto tardó en despertar. Al final pide
 * parar con 0.
 */
BEGIN bench_xcall
    srli    s5, a0, 32
    slli    s1, a0, 32
    srli    s1, s1, 32
    li      s4, 0
    csrr    s0, instret
    rdtime  s3
1:  rdtime  s6
    mv      a1, s6
    CALL_MESSAGE
    bnez    a0, 9f
    rdtime  t0
    sub     t0, t0, s6
    bgeu    s4, t0, 2f
    mv      s4, t0
2:  addi    s1, s1, -1
    bnez    s1, 1b
    csrr    s7, instret
    rdtime  s8
    sub     s7, s7, s0
    sub     s8, s8, s3
    li      a1, 0
    CALL_MESSAGE
    mv      a0, s7
    beqz    s5, 3f
    mv      a0, s8
    li      t0, 1
    beq     s5, t0, 3f
    mv      a0, s4
3:  SYS     FB_SYS_EXIT
9:  li      a0, -1
    SYS     FB_SYS_EXIT
END bench_xcall

/*
 * Servidor de bench_xcall. Mide cuánto tarda cada llamada en llegarle desde el
 * instante que trae y, al recibir 0, contesta y sale con la suma << 32 | la
 * mayor (en unidades del reloj).
 */
BEGIN bench_xserve
    li      s2, 0
    li      s3, 0
    li      a0, 0
    SYS     FB_SYS_REPLY_RECV
1:  rdtime  t0
    bnez    a0, 9f
    beqz    a1, 2f
    sub     t0, t0, a1
    add     s2, s2, t0
    bgeu    s3, t0, 3f
    mv      s3, t0
3:  li      a0, 0
    SYS     FB_SYS_REPLY_RECV
    j       1b
2:  SYS     FB_SYS_REPLY
    slli    s3, s3, 32
    srli    s3, s3, 32
    slli    a0, s2, 32
    or      a0, a0, s3
    SYS     FB_SYS_EXIT
9:  li      a0, -1
    SYS     FB_SYS_EXIT
END bench_xserve

/*
 * Memoria compartida. Patrón de prueba: la palabra i vale 3i + 7.
 * Los bucles usan las etiquetas 5 y 6; quien los usa no debe usarlas.
 */
.macro MAP_SHARED slot
    li      a0, \slot
    li      a1, FB_USER_SHARED_BASE
    SYS     FB_SYS_REGION_MAP
.endm

/* Escribe el patrón en las primeras \count palabras de la región. */
.macro WRITE_PATTERN count
    li      t0, FB_USER_SHARED_BASE
    li      t1, 0
5:  bgeu    t1, \count, 6f
    slli    t2, t1, 1
    add     t2, t2, t1
    addi    t2, t2, 7
    slli    t3, t1, 3
    add     t3, t3, t0
    sd      t2, 0(t3)
    addi    t1, t1, 1
    j       5b
6:
.endm

/* Comprueba el patrón; si una palabra no cuadra salta a \fail. */
.macro CHECK_PATTERN count, fail
    li      t0, FB_USER_SHARED_BASE
    li      t1, 0
5:  bgeu    t1, \count, 6f
    slli    t2, t1, 1
    add     t2, t2, t1
    addi    t2, t2, 7
    slli    t3, t1, 3
    add     t3, t3, t0
    ld      t4, 0(t3)
    bne     t4, t2, \fail
    addi    t1, t1, 1
    j       5b
6:
.endm

/* Hueco 0: región; hueco 1: endpoint con Send. Escribe a0 palabras, llama
   con su número y espera que se lo devuelvan. Sale con 0 si todo fue bien,
   2 si no pudo mapear. */
BEGIN shm_writer
    mv      s1, a0
    MAP_SHARED 0
    bnez    a0, 8f
    WRITE_PATTERN s1
    li      a0, 1
    mv      a1, s1
    NO_TRANSFER
    SYS     FB_SYS_CALL
    bnez    a0, 9f
    bne     a1, s1, 9f
    li      a0, 0
    SYS     FB_SYS_EXIT
8:  li      a0, 2
    SYS     FB_SYS_EXIT
9:  li      a0, 1
    SYS     FB_SYS_EXIT
END shm_writer

/* Hueco 0: región; hueco 1: endpoint con Recv. Recibe cuántas palabras hay,
   las comprueba y contesta con el mismo número (0 si no cuadran). Sale con
   0 si todo fue bien, 3 si el patrón no cuadra, 2 si no pudo mapear. */
BEGIN shm_reader
    MAP_SHARED 0
    bnez    a0, 8f
    li      a0, 1
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    bnez    a0, 9f
    mv      s1, a1
    CHECK_PATTERN s1, 7f
    mv      a1, s1
    SYS     FB_SYS_REPLY
    li      a0, 0
    SYS     FB_SYS_EXIT
7:  li      a1, 0
    SYS     FB_SYS_REPLY
    li      a0, 3
    SYS     FB_SYS_EXIT
8:  li      a0, 2
    SYS     FB_SYS_EXIT
9:  li      a0, 1
    SYS     FB_SYS_EXIT
END shm_reader

/* Mapea la región del hueco 0 e intenta escribir en ella. */
BEGIN shm_store
    MAP_SHARED 0
    bnez    a0, 8f
    li      t0, FB_USER_SHARED_BASE
    li      t1, 1
    sd      t1, 0(t0)
    SURVIVED
8:  li      a0, 2
    SYS     FB_SYS_EXIT
END shm_store

/* Mapea la región del hueco a0 y sale con lo que devolvió la llamada. */
BEGIN shm_map_status
    li      a1, FB_USER_SHARED_BASE
    SYS     FB_SYS_REGION_MAP
    SYS     FB_SYS_EXIT
END shm_map_status

/* Mapea la región del hueco 0 dos veces en el mismo sitio; sale con lo que
   devolvió la segunda (2 si falló la primera). */
BEGIN shm_map_twice
    MAP_SHARED 0
    bnez    a0, 8f
    MAP_SHARED 0
    SYS     FB_SYS_EXIT
8:  li      a0, 2
    SYS     FB_SYS_EXIT
END shm_map_twice

/* Hueco 0: región con Grant; hueco 1: endpoint con Send y Grant. Escribe a0
   palabras y envía la capability de la región con su número. */
BEGIN shm_giver
    mv      s1, a0
    MAP_SHARED 0
    bnez    a0, 8f
    WRITE_PATTERN s1
    li      a0, 1
    mv      a1, s1
    li      a2, 0
    li      a3, 0
    li      a4, 0
    li      a5, 0
    SYS     FB_SYS_SEND
    bnez    a0, 9f
    li      a0, 0
    SYS     FB_SYS_EXIT
8:  li      a0, 2
    SYS     FB_SYS_EXIT
9:  li      a0, 1
    SYS     FB_SYS_EXIT
END shm_giver

/* Hueco 1: endpoint con Recv. Recibe en el hueco 0 la capability de una
   región, la mapea y comprueba el patrón. Sale con 0 si todo fue bien. */
BEGIN shm_taker
    li      a0, 1
    li      a1, 0
    SYS     FB_SYS_RECV
    bnez    a0, 9f
    li      t0, FB_MSG_CAP
    bne     a5, t0, 9f
    mv      s1, a1
    MAP_SHARED 0
    bnez    a0, 8f
    CHECK_PATTERN s1, 7f
    li      a0, 0
    SYS     FB_SYS_EXIT
7:  li      a0, 3
    SYS     FB_SYS_EXIT
8:  li      a0, 2
    SYS     FB_SYS_EXIT
9:  li      a0, 1
    SYS     FB_SYS_EXIT
END shm_taker

/*
 * Medidas de la memoria compartida. Hueco 0: región (lectura y escritura);
 * hueco 1: endpoint con Send. a0 = vueltas. En cada vuelta escribe 4 KiB (512
 * palabras, la i vale vuelta + i), llama con el número de vuelta y comprueba
 * la suma que le devuelven. Al final pide parar con 0 y sale con el tiempo
 * total en unidades del reloj (-1 si algo falla).
 */
BEGIN bench_shm_produce
    mv      s1, a0
    MAP_SHARED 0
    bnez    a0, 9f
    rdtime  s3
    li      s2, 1
1:  li      t0, FB_USER_SHARED_BASE
    li      t1, 0
    li      t5, 512
2:  add     t2, s2, t1
    slli    t3, t1, 3
    add     t3, t3, t0
    sd      t2, 0(t3)
    addi    t1, t1, 1
    bne     t1, t5, 2b
    li      a0, 1
    mv      a1, s2
    NO_TRANSFER
    SYS     FB_SYS_CALL
    bnez    a0, 9f
    /* 512 vuelta + (0 + 1 + ... + 511) */
    slli    t2, s2, 9
    li      t3, 130816
    add     t2, t2, t3
    bne     a1, t2, 9f
    addi    s2, s2, 1
    addi    s1, s1, -1
    bnez    s1, 1b
    rdtime  s4
    sub     s4, s4, s3
    li      a0, 1
    li      a1, 0
    NO_TRANSFER
    SYS     FB_SYS_CALL
    mv      a0, s4
    SYS     FB_SYS_EXIT
9:  li      a0, -1
    SYS     FB_SYS_EXIT
END bench_shm_produce

/* Hueco 0: región (lectura); hueco 1: endpoint con Recv. Suma las 512
   palabras de cada vuelta y contesta con la suma; con 0, contesta y sale. */
BEGIN bench_shm_consume
    MAP_SHARED 0
    bnez    a0, 9f
    li      a0, 1
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
1:  bnez    a0, 9f
    beqz    a1, 3f
    li      t0, FB_USER_SHARED_BASE
    li      t1, 0
    li      t5, 512
    li      t4, 0
2:  slli    t3, t1, 3
    add     t3, t3, t0
    ld      t2, 0(t3)
    add     t4, t4, t2
    addi    t1, t1, 1
    bne     t1, t5, 2b
    mv      a1, t4
    li      a0, 1
    SYS     FB_SYS_REPLY_RECV
    j       1b
3:  SYS     FB_SYS_REPLY
    li      a0, 0
    SYS     FB_SYS_EXIT
9:  li      a0, -1
    SYS     FB_SYS_EXIT
END bench_shm_consume

/* Lo mismo sin memoria compartida: cada vuelta copia 4 KiB en 128 llamadas
   de 32 bytes (a1 .. a4). Hueco 0: endpoint con Send. a0 = vueltas. */
BEGIN bench_copy_produce
    mv      s1, a0
    rdtime  s3
1:  li      s2, 128
2:  li      a0, 0
    mv      a1, s2
    mv      a2, s1
    mv      a3, s2
    mv      a4, s1
    NO_TRANSFER
    SYS     FB_SYS_CALL
    bnez    a0, 9f
    addi    s2, s2, -1
    bnez    s2, 2b
    addi    s1, s1, -1
    bnez    s1, 1b
    rdtime  s4
    sub     s4, s4, s3
    li      a0, 0
    li      a1, 0
    NO_TRANSFER
    SYS     FB_SYS_CALL
    mv      a0, s4
    SYS     FB_SYS_EXIT
9:  li      a0, -1
    SYS     FB_SYS_EXIT
END bench_copy_produce

/* Guarda cada mensaje en un búfer de 4 KiB de su pila y contesta. Hueco 0:
   endpoint con Recv. Con a1 = 0, contesta y sale. */
BEGIN bench_copy_consume
    li      a0, 0
    li      a1, FB_CAP_SLOT_NONE
    SYS     FB_SYS_RECV
    li      s2, 0
1:  bnez    a0, 9f
    beqz    a1, 3f
    li      t0, -4096
    add     t0, t0, sp
    add     t0, t0, s2
    sd      a1, 0(t0)
    sd      a2, 8(t0)
    sd      a3, 16(t0)
    sd      a4, 24(t0)
    addi    s2, s2, 32
    li      t1, 4095
    and     s2, s2, t1
    li      a0, 0
    SYS     FB_SYS_REPLY_RECV
    j       1b
3:  SYS     FB_SYS_REPLY
    li      a0, 0
    SYS     FB_SYS_EXIT
9:  li      a0, -1
    SYS     FB_SYS_EXIT
END bench_copy_consume

/* Mapea la región del hueco 0 (16 páginas) y escribe una palabra en cada
   página. Sale con lo que tardó, en unidades del reloj (-1 si falla). */
BEGIN bench_shm_map
    rdtime  s3
    MAP_SHARED 0
    bnez    a0, 9f
    li      t0, FB_USER_SHARED_BASE
    li      t1, 16
    li      t2, 4096
1:  sd      t1, 0(t0)
    add     t0, t0, t2
    addi    t1, t1, -1
    bnez    t1, 1b
    rdtime  s4
    sub     a0, s4, s3
    SYS     FB_SYS_EXIT
9:  li      a0, -1
    SYS     FB_SYS_EXIT
END bench_shm_map

/*
 * Disco. Llama al driver (hueco 0) con a1 = operación, a2 = sector, a3 =
 * página; deja en a1 el estado y en a2 el segundo valor de la respuesta.
 */
.macro DISK op, sector, page
    li      a0, 0
    li      a1, \op
    mv      a2, \sector
    mv      a3, \page
    li      a4, 0
    NO_TRANSFER
    SYS     FB_SYS_CALL
.endm

/* Hueco 0: endpoint del driver con Send; hueco 1: la región de datos que
   comparte con él (al menos 3 páginas). Comprueba la capacidad, lee los
   sectores 16 a 23 y comprueba el patrón de la imagen (la palabra i del sector
   s vale s * 2^32 + i), escribe una página en los sectores 64 a 71, la vuelve
   a leer en otra página y las compara, y prueba peticiones fuera de rango.
   Con a0 = 1, al final pide al driver que pare. Sale con 0 si todo fue bien
   o con el número del paso que falló. */
BEGIN disk_check
    mv      s9, a0
    MAP_SHARED 1
    li      s1, 1
    bnez    a0, 9f

    /* Capacidad: 2048 sectores. */
    li      s1, 2
    li      s2, 0
    DISK    FB_DISK_OP_CAPACITY, s2, s2
    bnez    a0, 9f
    bnez    a1, 9f
    li      t0, 2048
    bne     a2, t0, 9f

    /* Leer los sectores 16 a 23 en la página 0. */
    li      s1, 3
    li      s2, 16
    li      s3, 0
    DISK    FB_DISK_OP_READ, s2, s3
    bnez    a0, 9f
    bnez    a1, 9f
    li      s1, 4
    li      t0, FB_USER_SHARED_BASE
    li      t1, 0
    li      t5, 512
1:  srli    t2, t1, 6
    addi    t2, t2, 16
    slli    t2, t2, 32
    andi    t3, t1, 63
    or      t2, t2, t3
    slli    t3, t1, 3
    add     t3, t3, t0
    ld      t4, 0(t3)
    bne     t4, t2, 9f
    addi    t1, t1, 1
    bne     t1, t5, 1b

    /* Escribir en los sectores 64 a 71 la página 1. */
    li      s1, 5
    li      t0, FB_USER_SHARED_BASE + 4096
    li      t1, 0
    li      t2, 0xa5a50000
2:  add     t3, t2, t1
    slli    t4, t1, 3
    add     t4, t4, t0
    sd      t3, 0(t4)
    addi    t1, t1, 1
    bne     t1, t5, 2b
    li      s2, 64
    li      s3, 1
    DISK    FB_DISK_OP_WRITE, s2, s3
    bnez    a0, 9f
    bnez    a1, 9f

    /* Y leerlos en la página 2: debe quedar igual que la 1. */
    li      s1, 6
    li      s2, 64
    li      s3, 2
    DISK    FB_DISK_OP_READ, s2, s3
    bnez    a0, 9f
    bnez    a1, 9f
    li      s1, 7
    li      t0, FB_USER_SHARED_BASE + 4096
    li      t1, FB_USER_SHARED_BASE + 8192
    li      t2, 0
3:  ld      t3, 0(t0)
    ld      t4, 0(t1)
    bne     t3, t4, 9f
    addi    t0, t0, 8
    addi    t1, t1, 8
    addi    t2, t2, 1
    bne     t2, t5, 3b

    /* Una página que no cabe al final del disco y una página que la región
       no tiene: el driver las rechaza. */
    li      s1, 8
    li      s2, 2044
    li      s3, 0
    DISK    FB_DISK_OP_READ, s2, s3
    bnez    a0, 9f
    li      t0, FB_DISK_ERR_REQUEST
    bne     a1, t0, 9f
    li      s1, 9
    li      s2, 0
    li      s3, 16
    DISK    FB_DISK_OP_READ, s2, s3
    bnez    a0, 9f
    li      t0, FB_DISK_ERR_REQUEST
    bne     a1, t0, 9f

    beqz    s9, 4f
    li      s1, 10
    li      s2, 0
    DISK    FB_DISK_OP_STOP, s2, s2
    bnez    a0, 9f
4:  li      a0, 0
    SYS     FB_SYS_EXIT
    /* Al fallar: el paso en el byte alto, y los bytes bajos de a1 y a0. */
9:  slli    s1, s1, 56
    andi    a1, a1, 0xff
    slli    a1, a1, 8
    andi    a0, a0, 0xff
    or      a0, a0, a1
    or      a0, a0, s1
    SYS     FB_SYS_EXIT
END disk_check

/* Hueco 0: una región; hueco 1: un dispositivo. a0: bit 0, mapear antes el
   dispositivo; bit 1, mapear antes la región. Sale con lo que devuelve
   FB_SYS_DMA_ADDRESS para la página 0. */
BEGIN dma_status
    mv      s1, a0
    andi    t0, s1, 1
    beqz    t0, 1f
    li      a0, 1
    SYS     FB_SYS_DEVICE_MAP
1:  andi    t0, s1, 2
    beqz    t0, 2f
    MAP_SHARED 0
2:  li      a0, 0
    li      a1, 0
    li      a2, 1
    SYS     FB_SYS_DMA_ADDRESS
    SYS     FB_SYS_EXIT
END dma_status

/* Medida del disco. Hueco 0: endpoint del driver con Send; hueco 1: la región
   de datos. a0 = vueltas | operación << 32 (FB_DISK_OP_READ o WRITE). Cada
   vuelta mueve 4 KiB (página 0) en los sectores 8i mod 2040. Al final pide al
   driver que pare y sale con las instrucciones que ejecutó toda la máquina
   (instret, global con -icount; -1 si algo falla). No con el reloj: mientras
   todos esperan al disco, QEMU lo hace saltar hasta el siguiente plazo. */
BEGIN bench_disk
    slli    s1, a0, 32
    srli    s1, s1, 32
    srli    s5, a0, 32
    MAP_SHARED 1
    bnez    a0, 9f
    li      s2, 0
    li      s3, 0
    csrr    s6, instret
1:  li      a0, 0
    mv      a1, s5
    mv      a2, s2
    li      a3, 0
    li      a4, 0
    NO_TRANSFER
    SYS     FB_SYS_CALL
    bnez    a0, 9f
    bnez    a1, 9f
    addi    s2, s2, 8
    li      t0, 2040
    bltu    s2, t0, 2f
    li      s2, 0
2:  addi    s1, s1, -1
    bnez    s1, 1b
    csrr    s7, instret
    sub     s7, s7, s6
    li      s2, 0
    DISK    FB_DISK_OP_STOP, s2, s2
    mv      a0, s7
    SYS     FB_SYS_EXIT
9:  li      a0, -1
    SYS     FB_SYS_EXIT
END bench_disk

/* Debe seguir el orden de process.Program. */
    .balign 8
    .global fb_user_program_table
fb_user_program_table:
    .irp name, hello,registers,spin,isolated,zerocheck,deputy,fault_csr,fault_sret,fault_load_kernel,fault_store_kernel,fault_jump_kernel,fault_store_text,fault_exec_stack,fault_stack_guard,fault_device,bench_syscall,bench_yield,no_caps,cap_rights,console_server,console_client,ping,pong,granter,grantee,ipc_sender,ipc_fifo_receiver,ipc_blocked,bench_ping,bench_pong,uart_driver,device_denied,device_rights,device_touch,device_holder,device_thief,device_exec,uart_client,uart_stopper,uart_reader,uart_loop_client,uart_loop_finish,device_irq_taker,uart_loop_on,bench_write,bench_driver_client,bench_loop_writer,bench_loop_reader,call_client,call_server,call_server_dies,call_expect_peer,send_expect_peer,call_checks,call_server_lost,call_long,call_server_pair,call_once,sched_set,sched_lower,defer_server,go_sender,reply_to_other,defer_then_die,defer_three,defer_then_serve,defer_wait,uart_call_reader,bench_call_read,bench_defer_reader,bench_defer_writer,latency_probe,call_forwarder,sleep_forever,signal_taker,bench_call,bench_serve,bench_xcall,bench_xserve,call_server_spin,shm_writer,shm_reader,shm_store,shm_map_status,shm_map_twice,shm_giver,shm_taker,bench_shm_produce,bench_shm_consume,bench_copy_produce,bench_copy_consume,bench_shm_map,disk_driver,disk_check,dma_status,bench_disk
    .quad   \name\()_start, \name\()_end
    .endr
