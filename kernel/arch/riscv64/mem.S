/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * Rutinas de memoria que los compiladores pueden invocar implícitamente.
 * Están en ensamblador para que el optimizador no convierta el bucle en una
 * llamada a sí misma. Trabajan por palabras cuando la alineación lo permite.
 * Las direcciones del kernel son mayores que 64, así que `fin - 64` no da la vuelta.
 */

    .section .text.mem, "ax", @progbits
    .global memset
    .type memset, @function
memset:
    mv      t0, a0
    add     t1, a0, a2
    andi    a1, a1, 0xff

1:  /* Bytes sueltos hasta alinear. */
    andi    t2, t0, 7
    beqz    t2, 2f
    bgeu    t0, t1, 5f
    sb      a1, 0(t0)
    addi    t0, t0, 1
    j       1b

2:  /* El byte repetido en las ocho posiciones. */
    li      t2, 0x0101010101010101
    mul     t3, a1, t2

    /* Bloques de 64 bytes: 11 instrucciones en lugar de 32. Borrar una página
       es la mayor parte de crear un proceso. */
    addi    t2, t1, -64
6:
    bgtu    t0, t2, 7f
    sd      t3, 0(t0)
    sd      t3, 8(t0)
    sd      t3, 16(t0)
    sd      t3, 24(t0)
    sd      t3, 32(t0)
    sd      t3, 40(t0)
    sd      t3, 48(t0)
    sd      t3, 56(t0)
    addi    t0, t0, 64
    j       6b

7:  /* Palabras sueltas tras el último bloque completo. */
    addi    t2, t1, -8
3:
    bgtu    t0, t2, 4f
    sd      t3, 0(t0)
    addi    t0, t0, 8
    j       3b

4:  /* Lo que queda tras la última palabra completa. */
    bgeu    t0, t1, 5f
    sb      a1, 0(t0)
    addi    t0, t0, 1
    j       4b
5:
    ret
    .size memset, . - memset

    .global memcpy
    .type memcpy, @function
memcpy:
    mv      t0, a0
    add     t1, a0, a2

    /* Solo se puede ir por palabras si origen y destino se alinean a la vez. */
    xor     t2, t0, a1
    andi    t2, t2, 7
    bnez    t2, 4f

1:
    andi    t2, t0, 7
    beqz    t2, 2f
    bgeu    t0, t1, 5f
    lb      t2, 0(a1)
    sb      t2, 0(t0)
    addi    t0, t0, 1
    addi    a1, a1, 1
    j       1b

2:
    addi    t3, t1, -8
3:
    bgtu    t0, t3, 4f
    ld      t2, 0(a1)
    sd      t2, 0(t0)
    addi    t0, t0, 8
    addi    a1, a1, 8
    j       3b

4:
    bgeu    t0, t1, 5f
    lb      t2, 0(a1)
    sb      t2, 0(t0)
    addi    t0, t0, 1
    addi    a1, a1, 1
    j       4b
5:
    ret
    .size memcpy, . - memcpy

/*
 * Hacia delante es seguro si el destino está antes que el origen: memcpy solo
 * va por palabras cuando la distancia es múltiplo de 8. Si el destino pisa el
 * final del origen, se copia desde el último byte.
 */
    .global memmove
    .type memmove, @function
memmove:
    bgeu    a1, a0, memcpy
    add     t0, a1, a2
    bgeu    a0, t0, memcpy

    add     t1, a0, a2
1:
    beq     t1, a0, 2f
    addi    t0, t0, -1
    addi    t1, t1, -1
    lb      t2, 0(t0)
    sb      t2, 0(t1)
    j       1b
2:
    ret
    .size memmove, . - memmove

/*
 * memcmp: diferencia del primer byte distinto, sin signo, como pide C. El
 * código SPARK la usa para comparar arrays (los nombres de los archivos). Va
 * byte a byte: los nombres miden 24 bytes y casi siempre difieren al
 * principio.
 */
    .global memcmp
    .type memcmp, @function
memcmp:
    add     t0, a0, a2
1:
    beq     a0, t0, 2f
    lbu     t1, 0(a0)
    lbu     t2, 0(a1)
    addi    a0, a0, 1
    addi    a1, a1, 1
    beq     t1, t2, 1b
    sub     a0, t1, t2
    ret
2:
    li      a0, 0
    ret
    .size memcmp, . - memcmp
