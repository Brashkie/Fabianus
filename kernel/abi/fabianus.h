/* SPDX-License-Identifier: GPL-3.0-or-later */
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
/* Disco virtio-blk (virtio-mmio moderno, versión 2) en la primera ranura de
   QEMU virt: -device virtio-blk-device,bus=virtio-mmio-bus.0. */
#define FB_VIRTIO0_BASE 0x10001000
#define FB_VIRTIO0_IRQ 1

/* Protocolo del driver de disco (drivers/disk). Un cliente comparte con él
   una región de datos y le llama: a1 = operación, a2 = primer sector, a3 =
   página de la región. Cada lectura o escritura mueve una página (8 sectores
   de 512 bytes). Contesta en a1 un FB_DISK_* y, para CAPACITY, en a2 el número
   de sectores. Con STOP contesta y termina.
   Para las pruebas de cortes de luz (inyección de fallos, como dm-flakey en
   Linux): CUT con a2 = sectores y a3 = FB_DISK_TEAR_* deja escribir esos
   sectores más y entonces «se va la luz». La escritura que cruza el límite
   solo escribe una parte (los primeros sectores o los últimos), y desde ahí
   toda lectura o escritura contesta FB_DISK_ERR_IO sin tocar el disco.
   POWER vuelve a dar la luz. */
#define FB_DISK_OP_STOP 0
#define FB_DISK_OP_READ 1
#define FB_DISK_OP_WRITE 2
#define FB_DISK_OP_CAPACITY 3
#define FB_DISK_OP_CUT 4
#define FB_DISK_OP_POWER 5
#define FB_DISK_TEAR_FIRST 0
#define FB_DISK_TEAR_LAST 1
#define FB_DISK_OK 0
#define FB_DISK_ERR_REQUEST 1
#define FB_DISK_ERR_IO 2
#define FB_DISK_SECTOR_BYTES 512
#define FB_DISK_SECTORS_PER_PAGE 8
/* Donde el driver mapea su cola (una página) y la región de datos. Puede
   recibir una segunda región de datos, que mapea en FB_DISK_EXTRA_BASE: sus
   páginas siguen, en la numeración, a las de la primera. */
#define FB_DISK_QUEUE_BASE 0x104000000
#define FB_DISK_DATA_BASE 0x104010000
#define FB_DISK_EXTRA_BASE 0x104020000
#define FB_DISK_MAX_DATA_PAGES 32

/* Sistema de archivos (servers/fs, con su núcleo demostrado en
   spark/src/fs_core.ads). Es un servidor de usuario entre los clientes y el
   driver del disco, y ocupa FB_FS_BLOCKS bloques de 4 KiB desde el sector
   FB_FS_FIRST_SECTOR. Comparte con el driver una región de FB_FS_META_PAGES
   páginas (superbloque y tabla) y con el cliente y el driver la región de
   datos del cliente: el disco lee y escribe en ella sin copias.
   Cada entrada es un archivo o un directorio (FB_FS_KIND_*). Las rutas van
   al principio de una página de la región del cliente, con a lo sumo
   FB_FS_PATH_BYTES bytes: nombres separados por '/', desde la raíz. Cada
   nombre tiene de 1 a FB_FS_NAME_BYTES bytes, sin ceros, y no es "." ni "..".
   Cada archivo o directorio tiene un número: su entrada en los
   FB_FS_HANDLE_SHIFT bits bajos y la generación de la entrada encima.
   Borrar sube la generación, así que el número de algo borrado no vuelve a
   nombrar nada, aunque otro archivo ocupe su entrada; renombrar no la
   cambia. La raíz es FB_FS_ROOT.
   Manejadores (Hito 39). El servidor sabe qué cliente le llama por la marca
   de su capability (a6 al recibir), y guarda para cada uno los manejadores
   que tiene abiertos: números de 0 a FB_FS_MAX_OPEN - 1, como descriptores
   de archivo. LOOKUP y CREATE abren uno; CLOSE lo suelta. Un manejador que
   el cliente no tiene abierto contesta FB_FS_ERR_BAD_HANDLE, aunque otro
   cliente sí lo tenga; uno abierto sobre algo borrado (o tras FORMAT),
   FB_FS_ERR_STALE hasta que lo cierre. FB_FS_ROOT es un manejador de la
   raíz que vale para todos y no se abre ni se cierra. Sin marca, todo
   contesta FB_FS_ERR_DENIED. Caben FB_FS_CLIENTS clientes a la vez.
   Un cliente le llama con a1 = operación:
     FORMAT: deja el sistema de archivos vacío. Ningún manejador de antes
       vale después (contestan FB_FS_ERR_STALE).
     LOOKUP: a2 = página de la ruta, a3 = su longitud. Abre un manejador
       (FB_FS_ROOT para "/", sin abrir nada) y contesta a2 = manejador, a3 =
       longitud y a4 = tipo. Sin manejadores libres, FB_FS_ERR_HANDLES.
     CREATE: a2 = página, a3 = longitud de la ruta, a4 = tipo. Crea un
       archivo o un directorio vacío en un directorio que ya existe y
       contesta a2 = un manejador abierto sobre él. Sin manejadores libres
       no crea nada (FB_FS_ERR_HANDLES).
     READ: a2 = manejador, a3 = bloque del archivo, a4 = página de la región.
       Contesta a2 = bytes del archivo en esa página.
     WRITE: a2 = manejador, a3 = bloque | bytes << 32, a4 = página.
     DELETE: a2 = manejador. Un directorio, solo si está vacío. El manejador
       sigue abierto (y contesta FB_FS_ERR_STALE) hasta que se cierre.
     RENAME: a2 = manejador, a3 = página, a4 = longitud de la ruta nueva.
       Puede cambiar de directorio. No sustituye a otra entrada
       (FB_FS_ERR_EXISTS), y un directorio no puede ir dentro de sí mismo
       (FB_FS_ERR_REQUEST).
     LIST: a2 = manejador del directorio, a3 = desde (una entrada), a4 =
       página. Contesta a2 = el número de la siguiente entrada del
       directorio desde "desde" (FB_FS_FILES si no hay), a3 = su longitud y
       a4 = su tipo; su nombre queda en los primeros FB_FS_NAME_BYTES bytes
       de la página. No abre nada.
     STAT: a2 = manejador. Contesta a2 = el número de lo que nombra, a3 =
       longitud y a4 = tipo.
     CLOSE: a2 = manejador.
     DETACH: cierra todos los manejadores del cliente.
     FREE: contesta a2 = bloques libres.
     STOP: contesta y termina.
   En a1 contesta un FB_FS_*. Si el disco no tiene formato, toda operación
   salvo FORMAT contesta FB_FS_ERR_UNFORMATTED; si el superbloque es bueno
   pero la tabla no (también con un ciclo de directorios), FB_FS_ERR_CORRUPT.
   Un nombre del medio de la ruta que es un archivo da FB_FS_ERR_NOT_DIR; leer
   o escribir un directorio, FB_FS_ERR_IS_DIR. Si una escritura de la tabla falla,
   el servidor deja de atender (FB_FS_ERR_IO) hasta que otro monte el disco:
   la tabla de memoria ya no es la del disco.
   Reescribir un bloque escribe en uno libre (copia al escribir), así que
   necesita un bloque libre: con el disco lleno contesta FB_FS_ERR_FULL. */
#define FB_FS_OP_STOP 0
#define FB_FS_OP_FORMAT 1
#define FB_FS_OP_CREATE 2
#define FB_FS_OP_LOOKUP 3
#define FB_FS_OP_READ 4
#define FB_FS_OP_WRITE 5
#define FB_FS_OP_DELETE 6
#define FB_FS_OP_LIST 7
#define FB_FS_OP_FREE 8
#define FB_FS_OP_RENAME 9
#define FB_FS_OP_CLOSE 10
#define FB_FS_OP_STAT 11
#define FB_FS_OP_DETACH 12
#define FB_FS_OK 0
#define FB_FS_ERR_REQUEST 1
#define FB_FS_ERR_IO 2
#define FB_FS_ERR_NOT_FOUND 3
#define FB_FS_ERR_EXISTS 4
#define FB_FS_ERR_FULL 5
#define FB_FS_ERR_UNFORMATTED 6
#define FB_FS_ERR_CORRUPT 7
#define FB_FS_ERR_NOT_DIR 8
#define FB_FS_ERR_NOT_EMPTY 9
#define FB_FS_ERR_IS_DIR 10
#define FB_FS_ERR_STALE 11
#define FB_FS_ERR_BAD_HANDLE 12
#define FB_FS_ERR_DENIED 13
#define FB_FS_ERR_HANDLES 14
#define FB_FS_MAX_OPEN 16
#define FB_FS_CLIENTS 4
#define FB_FS_HANDLE_SHIFT 8
#define FB_FS_KIND_FILE 0
#define FB_FS_KIND_DIR 1
#define FB_FS_ROOT 255
#define FB_FS_PATH_BYTES 256
#define FB_FS_BLOCKS 256
#define FB_FS_FIRST_DATA 2
#define FB_FS_FILES 64
#define FB_FS_FILE_BLOCKS 16
#define FB_FS_NAME_BYTES 20
#define FB_FS_FIRST_SECTOR 2048
#define FB_FS_META_PAGES 2
/* Donde el servidor mapea sus metadatos y la región del cliente. */
#define FB_FS_META_BASE 0x104000000
#define FB_FS_CLIENT_BASE 0x104010000
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
/* Donde los programas de prueba mapean una región compartida. */
#define FB_USER_SHARED_BASE 0x104000000
#define FB_USPACE_MAX 4
#define FB_USPACE_MAX_REGIONS 4
#define FB_USPACE_MAX_REGION_PAGES 16
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
/* a0 = capability de región, a1 = dirección. Mapea todas sus páginas desde
   a1: para escribir si la capability tiene Send, si no solo para leer. */
#define FB_SYS_REGION_MAP 20
/* a0 = capability de región, a1 = página, a2 = capability del disco (Send).
   Devuelve la dirección física de esa página, para programar DMA, solo si
   quien llama está unido a la región y tiene los registros del disco. */
#define FB_SYS_DMA_ADDRESS 21
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
/* Región compartida: el objeto es el número de región - 1. Recv deja mapearla
   para leer y Send, además, para escribir. */
#define FB_CAP_REGION 5
#define FB_DEVICE_UART 0
#define FB_DEVICE_DISK 1
#define FB_DEVICE_COUNT 2
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

/* Qué recibió recv en a5. Lo escribe el kernel: un emisor no puede imitarlo.
   En a6 recibe la marca de la capability con que le enviaron (0 sin marca o
   en una señal). Las marcas solo las pone el kernel al conceder una
   capability; derivarla o cederla la conserva (Cap_Core). */
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
/* Mapea los registros de un dispositivo (FB_DEVICE_*) en un solo espacio a
   la vez. Devuelve FB_USPACE_*. */
uint64_t fb_uspace_map_device(uint64_t space, uint64_t device, uint64_t va);
/* Regiones compartidas. Crear devuelve la región (1 .. 4) o 0; frame, la
   dirección física de una página o 0; in_use, 1 si algún espacio está unido.
   Las demás devuelven FB_USPACE_*. */
uint64_t fb_uspace_region_create(uint64_t pages);
uint64_t fb_uspace_region_frame(uint64_t region, uint64_t page);
uint64_t fb_uspace_region_attach(uint64_t space, uint64_t region);
uint64_t fb_uspace_region_map(uint64_t space, uint64_t region, uint64_t page, uint64_t va,
                              uint64_t writable);
uint64_t fb_uspace_region_in_use(uint64_t region);
/* Como region_frame, pero solo si el espacio está unido a la región. */
uint64_t fb_uspace_region_frame_for(uint64_t space, uint64_t region, uint64_t page);
uint64_t fb_uspace_region_free(uint64_t region);

/* Capabilities, demostradas en SPARK. fb_cap_grant es solo para el kernel. */
uint64_t fb_cap_grant(uint64_t proc, uint64_t slot, uint64_t kind, uint64_t object, uint64_t rights);
uint64_t fb_cap_grant_badged(uint64_t proc, uint64_t slot, uint64_t kind, uint64_t object, uint64_t rights,
                             uint64_t badge);
uint64_t fb_cap_badge(uint64_t proc, uint64_t slot); /* Marca de la capability, o 0. */
uint64_t fb_cap_check(uint64_t proc, uint64_t slot, uint64_t kind, uint64_t right);
uint64_t fb_cap_held(uint64_t proc, uint64_t slot);
uint64_t fb_cap_derive(uint64_t proc, uint64_t src, uint64_t dst, uint64_t rights);
uint64_t fb_cap_transfer(uint64_t from_proc, uint64_t from_slot, uint64_t to_proc, uint64_t to_slot);
uint64_t fb_cap_delete(uint64_t proc, uint64_t slot);
uint64_t fb_cap_clear(uint64_t proc);
uint64_t fb_cap_holds_receive(uint64_t proc, uint64_t object);
uint64_t fb_cap_other_receiver(uint64_t proc, uint64_t object);
/* 1 si alguna capability de ese tipo nombra ese objeto. */
uint64_t fb_cap_refers(uint64_t kind, uint64_t object);

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
/* Boost y despertar en una sola operación; solo si despertar no le quita un
   contexto a nadie (si no, FB_SCHED_WRONG_STATE). */
uint64_t fb_sched_wake_boost(uint64_t thread, uint64_t level);

/* Herencia de prioridad (Inherit_Gate). Con el cerrojo global y los de
   todos los harts, salvo las dos últimas: con los de `held` (un bit por
   hart), que comprueban ellas mismas que bastan (si no, FB_INHERIT_UNHELD). */
#define FB_INHERIT_CYCLE 6UL
#define FB_INHERIT_UNHELD 7UL
uint64_t fb_inherit_refresh(uint64_t server);
uint64_t fb_inherit_refresh_chain(uint64_t server, uint64_t *notify);
uint64_t fb_inherit_holds(void);
/* Llamar y heredar: recalcula el suelo del servidor y lo despierta. */
uint64_t fb_inherit_call_wake(uint64_t server, uint64_t held);
/* Responder y heredar: despierta al cliente y recalcula el suelo del servidor. */
uint64_t fb_inherit_reply_wake(uint64_t server, uint64_t client, uint64_t held, uint64_t *notify);

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

/* Núcleo del sistema de archivos, demostrado en SPARK (fs_core.ads). Lo
   enlaza el servidor de archivos; el kernel solo lo usa en sus pruebas. La
   tabla, los mapas (dueño de cada bloque y profundidad de cada entrada) y
   el superbloque son del que llama. */
struct fb_fs_entry {
    uint8_t used;
    uint8_t kind;
    uint8_t parent;
    uint8_t pad;
    uint32_t length;
    uint32_t gen;
    uint8_t name[20];
    uint16_t blocks[16];
};
struct fb_fs_super {
    uint64_t magic;
    uint32_t version;
    uint32_t blocks;
    uint32_t files;
    uint32_t unused;
};
struct fb_fs_owner {
    uint8_t used;
    uint8_t file;
    uint8_t slot;
    uint8_t pad;
};
void fb_fs_mount(const struct fb_fs_super *super, const struct fb_fs_entry *table, struct fb_fs_owner *owner, uint8_t *depth, uint64_t *status);
void fb_fs_format(struct fb_fs_super *super, struct fb_fs_entry *table, struct fb_fs_owner *owner, uint8_t *depth, uint64_t keep);
void fb_fs_lookup(const struct fb_fs_entry *table, const struct fb_fs_owner *owner, const uint8_t *depth, uint64_t dir, const uint8_t *name, uint64_t *file, uint64_t *status);
void fb_fs_create(struct fb_fs_entry *table, const struct fb_fs_owner *owner, uint8_t *depth, uint64_t dir, const uint8_t *name, uint64_t kind, uint64_t *file, uint64_t *status);
void fb_fs_block_of(const struct fb_fs_entry *table, const struct fb_fs_owner *owner, const uint8_t *depth, uint64_t file, uint64_t gen, uint64_t slot, uint64_t *block, uint64_t *bytes, uint64_t *status);
void fb_fs_plan_write(const struct fb_fs_entry *table, const struct fb_fs_owner *owner, const uint8_t *depth, uint64_t file, uint64_t gen, uint64_t slot, uint64_t bytes, uint64_t *block, uint64_t *status);
void fb_fs_commit_write(struct fb_fs_entry *table, struct fb_fs_owner *owner, const uint8_t *depth, uint64_t file, uint64_t gen, uint64_t slot, uint64_t bytes, uint64_t block, uint64_t *status);
void fb_fs_delete(struct fb_fs_entry *table, struct fb_fs_owner *owner, uint8_t *depth, uint64_t file, uint64_t gen, uint64_t *status);
void fb_fs_rename(struct fb_fs_entry *table, const struct fb_fs_owner *owner, uint8_t *depth, uint64_t file, uint64_t gen, uint64_t dir, const uint8_t *name, uint64_t *status);
void fb_fs_next_in(const struct fb_fs_entry *table, const struct fb_fs_owner *owner, const uint8_t *depth, uint64_t dir, uint64_t gen, uint64_t from, uint64_t *file, uint64_t *status);
void fb_fs_stat(const struct fb_fs_entry *table, const struct fb_fs_owner *owner, const uint8_t *depth, uint64_t file, uint64_t gen, uint64_t *kind, uint64_t *length, uint64_t *status);
uint64_t fb_fs_free_blocks(const struct fb_fs_owner *owner);

/* Manejadores abiertos de cada cliente (fs_handles.ads, Hito 39). */
struct fb_fs_open {
    uint32_t used;
    uint32_t file;
    uint32_t gen;
    uint32_t pad;
};
struct fb_fs_client {
    uint64_t badge;
    struct fb_fs_open opens[16];
};
void fb_fs_handles_clear(struct fb_fs_client *table);
uint64_t fb_fs_room(const struct fb_fs_client *table, uint64_t badge);
void fb_fs_open(struct fb_fs_client *table, uint64_t badge, uint64_t file, uint64_t gen, uint64_t *handle, uint64_t *status);
void fb_fs_resolve(const struct fb_fs_client *table, uint64_t badge, uint64_t handle, uint64_t *file, uint64_t *gen, uint64_t *status);
void fb_fs_close(struct fb_fs_client *table, uint64_t badge, uint64_t handle, uint64_t *status);
void fb_fs_detach(struct fb_fs_client *table, uint64_t badge);

/* Autopruebas en ensamblador. Devuelven 0 si todo fue bien. */
uint64_t fb_selftest_callee_saved(void (*call)(void), uint64_t seed);
uint64_t fb_selftest_preempt_spin(uint64_t *counter, const uint64_t *stop);

/* Devuelve 0 si un trap conserva todos los registros. */
uint64_t fb_selftest_registers(void);

#endif /* __ASSEMBLER__ */

#endif /* FABIANUS_ABI_H */
