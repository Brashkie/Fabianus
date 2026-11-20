/*
 * ABI común de Fabianus: única fuente de verdad entre lenguajes.
 * Este archivo se incluye tanto desde ensamblador como desde Zig.
 */
#ifndef FABIANUS_ABI_H
#define FABIANUS_ABI_H

/* Hart que ejecuta el arranque; los demás quedan detenidos. */
#define FB_BOOT_HART 0
/* Harts que el kernel arranca; los de más se quedan aparcados. */
#define FB_MAX_HARTS 4
/* Pila de cada hart secundario, debajo de una página de guarda. */
#define FB_HART_STACK_SIZE 0x4000

/* Dispositivos de la máquina `virt` de QEMU. */
#define FB_UART0_BASE 0x10000000
#define FB_UART0_IRQ 10
#define FB_PLIC_BASE 0x0c000000
#define FB_PLIC_SIZE 0x400000UL
/* CLINT: el supervisor solo puede escribir las palabras msip de los harts
   (los avisos entre harts), nunca mtimecmp. */
#define FB_CLINT_BASE 0x02000000
#define FB_CLINT_MSIP_SIZE 16
#define FB_TEST_FINISHER_BASE 0x00100000
#define FB_TEST_FINISHER_PASS 0x5555U
#define FB_TEST_FINISHER_FAIL 0x3333U
#define FB_TIMEBASE_HZ 10000000UL

/* Memoria física de la máquina `virt` con -m 128M. */
#define FB_RAM_BASE 0x80000000
#define FB_RAM_SIZE 0x08000000
#define FB_PAGE_SIZE 4096UL
#define FB_MEGAPAGE_SIZE 0x200000UL

/* Paginación. Deben coincidir con spark/src/paging_gate.ads. */
#define FB_PAGING_MAX_REGIONS 32
#define FB_PERM_READ 1UL
#define FB_PERM_READ_WRITE 2UL
#define FB_PERM_READ_EXECUTE 3UL
#define FB_PAGE_4K 0UL
#define FB_PAGE_2M 1UL
#define FB_PAGING_OK 0UL
#define FB_PAGING_INVALID 1UL
#define FB_PAGING_NO_SPACE 2UL
#define FB_PAGING_CONFLICT 3UL
#define FB_PAGING_ALREADY_BUILT 4UL

/* Asignador de marcos. Deben coincidir con spark/src/frame_gate.ads. */
#define FB_MAX_FRAMES 32768UL
#define FB_FRAMES_OK 0UL
#define FB_FRAMES_MISALIGNED 1UL
#define FB_FRAMES_OUT_OF_RANGE 2UL
#define FB_FRAMES_NOT_ASSIGNED 3UL
#define FB_FRAMES_ALREADY_INIT 4UL

/* Planificador. Deben coincidir con spark/src/sched_gate.ads. */
#define FB_MAX_THREADS 8
#define FB_SCHED_NONE 0xffffffffffffffffUL
#define FB_SCHED_OK 0UL
#define FB_SCHED_INVALID 1UL
#define FB_SCHED_WRONG_STATE 2UL
#define FB_SCHED_ALREADY 3UL
#define FB_SCHED_DECLINED 4UL
#define FB_SCHED_YIELD 5UL
/* fb_sched_wake_remote: avisar al hart (resultado - FB_SCHED_NOTIFY_BASE). */
#define FB_SCHED_NOTIFY_BASE 0x100UL
#define FB_SCHED_NO_BOOST 0xffffffffffffffffUL
#define FB_PRIO_LOW 0UL
#define FB_PRIO_NORMAL 1UL
#define FB_PRIO_HIGH 2UL
#define FB_PRIO_TOP 3UL
#define FB_SCHED_MAX_BUDGET 1000000000UL
#define FB_SCHED_DEFAULT_BUDGET 100000UL
#define FB_THREAD_FREE 0UL
#define FB_THREAD_READY 1UL
#define FB_THREAD_BLOCKED 2UL

/* Espacios de usuario. Deben coincidir con spark/src/user_space.ads. */
#define FB_USER_BASE 0x100000000
#define FB_USER_LIMIT 0x4000000000
#define FB_USER_STACK_TOP 0x101000000
#define FB_USER_STACK_PAGES 4
#define FB_USER_DEVICE_BASE 0x102000000
#define FB_USPACE_MAX 4
#define FB_USPACE_MAX_LEAF_TABLES 5
#define FB_USPACE_OK 0UL
#define FB_USPACE_INVALID 1UL
#define FB_USPACE_NO_SPACE 2UL
#define FB_USPACE_CONFLICT 3UL
#define FB_USPACE_NO_FRAMES 4UL
#define FB_USPACE_INTERNAL 5UL
#define FB_ACCESS_READ 1UL
#define FB_ACCESS_WRITE 2UL

/* Llamadas al sistema: número en a7, argumentos desde a0, resultado en a0. */
#define FB_SYS_EXIT 1
#define FB_SYS_WRITE 2
#define FB_SYS_YIELD 3
#define FB_SYS_THREAD_ID 4
#define FB_SYS_SEND 5
#define FB_SYS_RECV 6
#define FB_SYS_CAP_DERIVE 7
#define FB_SYS_CAP_DELETE 8
#define FB_SYS_DEVICE_MAP 9
#define FB_SYS_IRQ_BIND 10
#define FB_SYS_IRQ_ACK 11
#define FB_SYS_TRY_SEND 12
#define FB_SYS_CALL 13
#define FB_SYS_REPLY 14
#define FB_SYS_REPLY_RECV 15
#define FB_SYS_SCHED_SET 16
#define FB_SYS_DEFER 17
#define FB_SYS_REPLY_TO 18
/* a0 = instante absoluto, en unidades de FB_TIMEBASE_HZ. */
#define FB_SYS_SLEEP_UNTIL 19
#define FB_SYS_WRITE_MAX 256
#define FB_ERR_NOSYS 0xffffffffffffffff
#define FB_ERR_FAULT 0xfffffffffffffffe
#define FB_ERR_INVALID 0xfffffffffffffffd
#define FB_ERR_CAP 0xfffffffffffffffc
#define FB_ERR_BUSY 0xfffffffffffffffb
#define FB_ERR_NOT_READY 0xfffffffffffffffa
#define FB_ERR_PEER 0xfffffffffffffff9

/* Capabilities. Deben coincidir con spark/src/cap_core.ads. */
#define FB_CAP_ENDPOINT 1
#define FB_CAP_CONSOLE 2
#define FB_CAP_DEVICE 3
#define FB_CAP_SCHED 4
#define FB_DEVICE_UART 0
#define FB_RIGHT_SEND 1
#define FB_RIGHT_RECV 2
#define FB_RIGHT_GRANT 4
#define FB_CAP_SLOT_NONE 0xffffffffffffffff
#define FB_CAP_NO_OBJECT 0xffffffffffffffff
#define FB_CAP_OK 0UL
#define FB_CAP_INVALID 1UL
#define FB_CAP_DENIED 2UL
#define FB_CAP_OCCUPIED 3UL

/* IPC. Deben coincidir con spark/src/ipc_core.ads. */
#define FB_IPC_ENDPOINTS 4
#define FB_IPC_QUEUED 100UL
#define FB_IPC_INVALID 101UL
#define FB_IPC_SIGNAL 102UL
#define FB_IPC_NOT_READY 103UL
#define FB_IPC_OK 0UL
#define FB_IPC_NOT_WAITING 1UL
#define FB_IPC_CANCEL_INVALID 2UL

/* Qué recibió recv en a5. Lo escribe el kernel: un emisor no puede imitarlo. */
#define FB_MSG_CAP 1
#define FB_MSG_SIGNAL 2
#define FB_MSG_CALL 3

/* Protocolo del driver de UART. El mensaje lleva en a1 la operación y, desde el bit 8, la longitud. */
#define FB_UART_MODE_TEST 1
#define FB_UART_OP_WRITE 1
#define FB_UART_OP_LOOPBACK 2
#define FB_UART_OP_STOP 3
#define FB_UART_OP_READ 4

/* Desplazamientos de fb_context, para ensamblador. */
#define FB_CTX_RA 0
#define FB_CTX_SP 8
#define FB_CTX_S0 16
#define FB_CTX_SSCRATCH 112
#define FB_CTX_SIZE 120

/* Banderas que boot.S entrega a fb_kmain. */
#define FB_BOOT_FLAG_SSTC 1UL

/* Desplazamientos de fb_trap_frame, para ensamblador. */
#define FB_TF_REGS 0
#define FB_TF_SEPC 256
#define FB_TF_SSTATUS 264
#define FB_TF_SCAUSE 272
#define FB_TF_STVAL 280
#define FB_TF_SIZE 288

#ifndef __ASSEMBLER__

#include <stdint.h>

/* Estado guardado en cada trap. regs[n] contiene el registro xn. */
typedef struct fb_trap_frame {
    uint64_t regs[32];
    uint64_t sepc;
    uint64_t sstatus;
    uint64_t scause;
    uint64_t stval;
} fb_trap_frame;

/* Punto de entrada del kernel en modo supervisor. Nunca retorna. */
_Noreturn void fb_kmain(uint64_t hart_id, uint64_t boot_flags);

/* Vector de traps, escrito en ensamblador. */
void fb_trap_entry(void);

/* Manejador de traps, llamado desde fb_trap_entry. */
void fb_trap_handler(fb_trap_frame *frame);

/* Asignador de marcos físicos, implementado y demostrado en SPARK. */
uint64_t fb_frames_init(uint64_t base, uint64_t count);
uint64_t fb_frames_alloc(void); /* Dirección física, o 0 si no quedan. */
uint64_t fb_frames_free(uint64_t address);

/* Región de memoria que debe aparecer en las tablas de páginas del kernel. */
typedef struct fb_region {
    uint64_t va;
    uint64_t pa;
    uint64_t length;
    uint64_t perm;
    uint64_t size;
} fb_region;

/* Construye las tablas del kernel en SPARK. Solo puede completarse una vez. */
uint64_t fb_paging_build(const fb_region *regions, uint64_t count, uint64_t pool_base);

/* Primer byte del conjunto de tablas; la raíz es su primera página. */
extern uint8_t fb_page_pool;

/* Registros que conserva un cambio de contexto. */
typedef struct fb_context {
    uint64_t ra;
    uint64_t sp;
    uint64_t s[12];
    uint64_t sscratch;
} fb_context;

/* Guarda el hilo actual en `from` y continúa en `to`. */
void fb_context_switch(fb_context *from, const fb_context *to);

/* Primer código de un hilo nuevo, escrito en ensamblador. */
void fb_thread_start(void);

/* Termina el hilo actual. Nunca retorna. */
_Noreturn void fb_thread_exit(void);

/* Baja a modo usuario en `pc` con la pila `sp` y `arg` en a0. Nunca retorna. */
_Noreturn void fb_enter_user(uint64_t pc, uint64_t sp, uint64_t arg);

/* Espacios de usuario, demostrados en SPARK. Requieren interrupciones apagadas. */
uint64_t fb_uspace_init(uint64_t pool, uint64_t first_frame, uint64_t count,
                        const uint64_t *kernel_root);
uint64_t fb_uspace_create(void); /* Identificador, o 0 si no quedan. */
uint64_t fb_uspace_root(uint64_t space); /* Página física de la raíz, o 0. */
/* Dirección física del marco nuevo, o un FB_USPACE_* si es menor que una página. */
uint64_t fb_uspace_map(uint64_t space, uint64_t va, uint64_t perm);
/* Dirección física de la página, o 0 si no es accesible en ese modo. */
uint64_t fb_uspace_translate(uint64_t space, uint64_t va, uint64_t mode);
uint64_t fb_uspace_destroy(uint64_t space);
/* Mapea la UART en un solo espacio a la vez. Devuelve FB_USPACE_*. */
uint64_t fb_uspace_map_device(uint64_t space, uint64_t va);

/* Capabilities, demostradas en SPARK. fb_cap_grant es solo para el kernel. */
uint64_t fb_cap_grant(uint64_t proc, uint64_t slot, uint64_t kind, uint64_t object, uint64_t rights);
uint64_t fb_cap_check(uint64_t proc, uint64_t slot, uint64_t kind, uint64_t right);
uint64_t fb_cap_held(uint64_t proc, uint64_t slot);
uint64_t fb_cap_derive(uint64_t proc, uint64_t src, uint64_t dst, uint64_t rights);
uint64_t fb_cap_transfer(uint64_t from_proc, uint64_t from_slot, uint64_t to_proc, uint64_t to_slot);
uint64_t fb_cap_delete(uint64_t proc, uint64_t slot);
uint64_t fb_cap_clear(uint64_t proc);
uint64_t fb_cap_holds_receive(uint64_t proc, uint64_t object);
uint64_t fb_cap_other_receiver(uint64_t proc, uint64_t object);

/* Colas de IPC, demostradas en SPARK. Devuelven el hilo emparejado o FB_IPC_*. */
uint64_t fb_ipc_send(uint64_t endpoint, uint64_t thread);
uint64_t fb_ipc_recv(uint64_t endpoint, uint64_t thread);
uint64_t fb_ipc_cancel(uint64_t thread);
uint64_t fb_ipc_try_send(uint64_t endpoint);
uint64_t fb_ipc_signal(uint64_t endpoint);
uint64_t fb_ipc_clear_signal(uint64_t endpoint);
uint64_t fb_ipc_call(uint64_t endpoint, uint64_t thread);
uint64_t fb_ipc_reply(uint64_t thread);
uint64_t fb_ipc_defer(uint64_t thread);
uint64_t fb_ipc_reply_held(uint64_t thread, uint64_t caller);
uint64_t fb_ipc_abort_held(uint64_t thread);
uint64_t fb_ipc_waits_for(uint64_t thread); /* Servidor del que espera respuesta, o 0. */
uint64_t fb_ipc_abort_sender(uint64_t endpoint);

/* Primer byte del conjunto de tablas de usuario. */
extern uint8_t fb_user_pool;

/* Planificador, implementado y demostrado en SPARK. Requieren interrupciones apagadas.
 * Hay un modelo por hart: hart es aquel cuyo modelo se usa. Su hart lo usa con el
 * cerrojo global o con el del hart; otro hart, con los dos. create, exit,
 * set_params y boost requieren siempre el global. */
uint64_t fb_sched_init(void);
uint64_t fb_sched_create(uint64_t hart);
/* elapsed: unidades de tiempo gastadas por el hilo en ejecución. */
uint64_t fb_sched_pick(uint64_t hart, uint64_t elapsed);
uint64_t fb_sched_hand_off(uint64_t hart, uint64_t peer, uint64_t elapsed, uint64_t donate);
/* Como fb_sched_hand_off, y además lo que le queda al contexto con que correrá
   peer (*granted) y si es el que pagaba el hilo que cedió (*donated = 1). */
uint64_t fb_sched_hand_off_grant(uint64_t hart, uint64_t peer, uint64_t elapsed, uint64_t donate,
                                 uint64_t *granted, uint64_t *donated);
uint64_t fb_sched_charge(uint64_t hart, uint64_t elapsed);
uint64_t fb_sched_adopt(uint64_t hart, uint64_t server, uint64_t client);
uint64_t fb_sched_context(uint64_t hart, uint64_t thread);
uint64_t fb_sched_should_yield(uint64_t hart);
uint64_t fb_sched_set_params(uint64_t hart, uint64_t thread, uint64_t level, uint64_t budget);
uint64_t fb_sched_remaining(uint64_t hart, uint64_t thread);
uint64_t fb_sched_budget(uint64_t hart, uint64_t thread);
uint64_t fb_sched_slice(uint64_t hart, uint64_t thread, uint64_t quantum, uint64_t estimate);
uint64_t fb_sched_running(uint64_t hart);
uint64_t fb_sched_block(uint64_t hart, uint64_t thread);
uint64_t fb_sched_unblock(uint64_t hart, uint64_t thread);
/* El hilo pasa a ser el siguiente en turno de su nivel. */
uint64_t fb_sched_promote(uint64_t hart, uint64_t thread);
uint64_t fb_sched_exit(uint64_t hart, uint64_t thread);
uint64_t fb_sched_state(uint64_t hart, uint64_t thread);
/* El hart de un hilo. Las tres siguientes usan el modelo del hart del hilo. */
uint64_t fb_sched_home(uint64_t thread);
uint64_t fb_sched_wake_remote(uint64_t thread);
uint64_t fb_sched_alone(uint64_t hart);
/* Herencia de prioridad entre harts. level = FB_SCHED_NO_BOOST la quita. */
uint64_t fb_sched_boost(uint64_t thread, uint64_t level);
uint64_t fb_sched_priority_of(uint64_t thread);
uint64_t fb_sched_floor_of(uint64_t thread); /* Suelo heredado, o FB_SCHED_NONE. */
uint64_t fb_sched_has_floor(uint64_t thread); /* 1 si hereda un suelo distinto de 0. */

/* Herencia de prioridad (Inherit_Gate). Con el cerrojo global y los de
   todos los harts. */
#define FB_INHERIT_CYCLE 6UL
uint64_t fb_inherit_refresh(uint64_t server);
uint64_t fb_inherit_refresh_chain(uint64_t server, uint64_t *notify);
uint64_t fb_inherit_holds(void);

/* Cuanto de turno adaptado al coste de cambiar de contexto, demostrado en SPARK. */
uint64_t fb_quantum_update(uint64_t estimate, uint64_t sample);
uint64_t fb_quantum_for(uint64_t estimate);
uint64_t fb_quantum_slice(uint64_t remaining, uint64_t budget, uint64_t quantum, uint64_t estimate);

/* Hilos dormidos hasta un instante, demostrado en SPARK. */
#define FB_SLEEP_OK 0UL
#define FB_SLEEP_INVALID 1UL
#define FB_SLEEP_NOT_ARMED 2UL
#define FB_SLEEP_NONE 0xffffffffffffffffUL
uint64_t fb_sleep_arm(uint64_t thread, uint64_t deadline);
uint64_t fb_sleep_disarm(uint64_t thread);
uint64_t fb_sleep_earliest(void);
uint64_t fb_sleep_take_expired(uint64_t now);

/* Autopruebas en ensamblador. Devuelven 0 si todo fue bien. */
uint64_t fb_selftest_callee_saved(void (*call)(void), uint64_t seed);
uint64_t fb_selftest_preempt_spin(uint64_t *counter, const uint64_t *stop);

/* Devuelve 0 si un trap conserva todos los registros. */
uint64_t fb_selftest_registers(void);

#endif /* __ASSEMBLER__ */

#endif /* FABIANUS_ABI_H */
