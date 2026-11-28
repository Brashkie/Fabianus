// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Mide en Linux, con varios harts, lo mismo que benchmark.runSmp en Fabianus.
 * Es el /init de un initramfs: mide, imprime y apaga la máquina.
 *
 * Con -icount, QEMU ejecuta los harts por turnos sobre un solo contador de
 * instrucciones, así que el reloj virtual avanza con las instrucciones de
 * todos: con shift=0, un nanosegundo por instrucción. Se lee con rdtime desde
 * usuario, la misma instrucción que en Fabianus. La calibración lo comprueba.
 *
 * No forma parte de Fabianus: solo sirve para comparar. Se compila estático con
 * `zig cc -target riscv64-linux-musl`.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/futex.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#define ROUNDS 4096
#define INVERSION_ROUNDS 256
#define REPEATS 5
/* El reloj de QEMU virt va a 10 MHz: 100 ns por unidad. */
#define NS_PER_UNIT 100

static inline uint64_t rdtime(void) {
    uint64_t value;
    __asm__ volatile("rdtime %0" : "=r"(value));
    return value;
}

static long futex(uint32_t *address, int operation, uint32_t value) {
    return syscall(SYS_futex, address, operation, value, NULL, NULL, 0);
}

static void pin(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof set, &set) != 0) {
        printf("no se pudo fijar la CPU %d\n", cpu);
        fflush(stdout);
    }
}

/* Con la llamada al sistema directa: el sched_setscheduler de musl devuelve
   siempre ENOSYS, porque el de Linux no sigue POSIX. */
static void fifo(int priority) {
    struct sched_param param = {.sched_priority = priority};
    long status = syscall(SYS_sched_setscheduler, 0, SCHED_FIFO, &param);
    if (status != 0 || syscall(SYS_sched_getscheduler, 0) != SCHED_FIFO) {
        printf("no se pudo poner SCHED_FIFO %d\n", priority);
        fflush(stdout);
    }
}

static void *shared(size_t size) {
    void *memory = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (memory == MAP_FAILED) {
        printf("sin memoria compartida\n");
        fflush(stdout);
        reboot(RB_POWER_OFF);
    }
    memset(memory, 0, size);
    return memory;
}

static void sort(uint64_t *values) {
    for (int i = 1; i < REPEATS; i++)
        for (int j = i; j > 0 && values[j - 1] > values[j]; j--) {
            uint64_t swap = values[j];
            values[j] = values[j - 1];
            values[j - 1] = swap;
        }
}

/* Mínima, mediana y máxima de las repeticiones, por operación. */
static void print_spread(uint64_t *values, uint64_t operations) {
    sort(values);
    printf("%llu ns (minima; mediana %llu ns, maxima %llu ns)",
           (unsigned long long)(values[0] * NS_PER_UNIT / operations),
           (unsigned long long)(values[REPEATS / 2] * NS_PER_UNIT / operations),
           (unsigned long long)(values[REPEATS - 1] * NS_PER_UNIT / operations));
}

static uint64_t max_of(uint64_t *values) {
    uint64_t out = 0;
    for (int i = 0; i < REPEATS; i++)
        if (values[i] > out) out = values[i];
    return out;
}

/* Lo que comparten cliente y servidor en una medida. */
struct exchange {
    uint32_t turn;
    uint32_t pad;
    uint64_t stamp;
    uint64_t wake_sum;
    uint64_t wake_max;
};

static void note_wake(struct exchange *x, uint64_t stamp) {
    uint64_t late = rdtime() - stamp;
    x->wake_sum += late;
    if (late > x->wake_max) x->wake_max = late;
}

/* Calibración: un bucle de exactamente 2 instrucciones por vuelta. */
static void calibrate(const char *name) {
    uint64_t begin = rdtime();
    __asm__ volatile("li t0, 1000000\n1: addi t0, t0, -1\nbnez t0, 1b" ::: "t0");
    printf("calibracion, %s: bucle de 2000001 instrucciones; reloj virtual %llu ns\n", name,
           (unsigned long long)((rdtime() - begin) * NS_PER_UNIT));
    fflush(stdout);
}

static void calibrate_busy(void) {
    pid_t spinner = fork();
    if (spinner == 0) {
        pin(1);
        for (;;) __asm__ volatile("" ::: "memory");
    }
    pin(0);
    usleep(10000);
    calibrate("con otra CPU girando");
    kill(spinner, SIGKILL);
    waitpid(spinner, NULL, 0);
}

/*
 * Ida y vuelta con futex entre dos procesos fijados a sus CPU. Cada ida lleva
 * el instante en que se hizo: el servidor mide cuánto tardó en despertar.
 */
static void futex_once(int client_cpu, int server_cpu, uint64_t *total, uint64_t *wake_sum, uint64_t *wake_max) {
    struct exchange *x = shared(4096);
    pid_t server = fork();
    if (server == 0) {
        pin(server_cpu);
        for (int i = 0; i < ROUNDS; i++) {
            while (__atomic_load_n(&x->turn, __ATOMIC_ACQUIRE) != 1) futex(&x->turn, FUTEX_WAIT, 0);
            note_wake(x, x->stamp);
            __atomic_store_n(&x->turn, 0, __ATOMIC_RELEASE);
            futex(&x->turn, FUTEX_WAKE, 1);
        }
        _exit(0);
    }
    pin(client_cpu);
    usleep(10000);
    uint64_t begin = rdtime();
    for (int i = 0; i < ROUNDS; i++) {
        x->stamp = rdtime();
        __atomic_store_n(&x->turn, 1, __ATOMIC_RELEASE);
        futex(&x->turn, FUTEX_WAKE, 1);
        while (__atomic_load_n(&x->turn, __ATOMIC_ACQUIRE) != 0) futex(&x->turn, FUTEX_WAIT, 1);
    }
    *total = rdtime() - begin;
    waitpid(server, NULL, 0);
    *wake_sum = x->wake_sum;
    *wake_max = x->wake_max;
    munmap(x, 4096);
}

/* Lo mismo con un mensaje de 8 bytes por tuberías: el instante va en él. */
static void pipe_once(int client_cpu, int server_cpu, uint64_t *total, uint64_t *wake_sum, uint64_t *wake_max) {
    struct exchange *x = shared(4096);
    int request[2], answer[2];
    if (pipe(request) || pipe(answer)) return;
    pid_t server = fork();
    if (server == 0) {
        pin(server_cpu);
        uint64_t stamp;
        for (int i = 0; i < ROUNDS; i++) {
            if (read(request[0], &stamp, sizeof stamp) != sizeof stamp) _exit(1);
            note_wake(x, stamp);
            if (write(answer[1], &stamp, sizeof stamp) != sizeof stamp) _exit(1);
        }
        _exit(0);
    }
    pin(client_cpu);
    usleep(10000);
    uint64_t begin = rdtime();
    for (int i = 0; i < ROUNDS; i++) {
        uint64_t stamp = rdtime();
        if (write(request[1], &stamp, sizeof stamp) != sizeof stamp) break;
        if (read(answer[0], &stamp, sizeof stamp) != sizeof stamp) break;
    }
    *total = rdtime() - begin;
    waitpid(server, NULL, 0);
    *wake_sum = x->wake_sum;
    *wake_max = x->wake_max;
    close(request[0]);
    close(request[1]);
    close(answer[0]);
    close(answer[1]);
    munmap(x, 4096);
}

typedef void (*exchange_fn)(int, int, uint64_t *, uint64_t *, uint64_t *);

static void measure_ping_pong(const char *name, exchange_fn once, int client_cpu, int server_cpu) {
    uint64_t total[REPEATS], wake_sum[REPEATS], wake_max[REPEATS];
    for (int i = 0; i < REPEATS; i++) once(client_cpu, server_cpu, &total[i], &wake_sum[i], &wake_max[i]);
    pin(0);
    printf("%s, ida y vuelta: ", name);
    print_spread(total, ROUNDS);
    printf("; despertar al otro lado: ");
    print_spread(wake_sum, ROUNDS);
    printf("; el peor %llu ns (%d x %d ops)\n", (unsigned long long)(max_of(wake_max) * NS_PER_UNIT), REPEATS,
           ROUNDS);
    fflush(stdout);
}

/*
 * Inversión de prioridad entre CPU con futex PI, el mecanismo de Linux para
 * ella. L (SCHED_FIFO 10, CPU 1) tiene el cerrojo; M (SCHED_FIFO 50, CPU 1)
 * gira; H (SCHED_FIFO 90, CPU 0) pide el cerrojo. Con PI, L hereda la
 * prioridad de H, expropia a M y suelta el cerrojo en cuanto ve que H espera:
 * es el servidor que contesta en cuanto le llega la llamada. Se mide cuánto
 * tarda L en correr desde que H lo pide, y lo que tarda H en tener el cerrojo.
 */
struct inversion {
    uint32_t lock;
    uint32_t spin;
    uint32_t ready;
    uint32_t pad;
    uint64_t spun;
    uint64_t stamp;
    uint64_t wake_sum;
    uint64_t wake_max;
};

static void inversion_once(uint64_t *total, uint64_t *wake_sum, uint64_t *wake_max) {
    struct inversion *v = shared(4096);
    pid_t medium = fork();
    if (medium == 0) {
        pin(1);
        fifo(50);
        for (;;) {
            while (__atomic_load_n(&v->spin, __ATOMIC_ACQUIRE)) __atomic_fetch_add(&v->spun, 1, __ATOMIC_RELAXED);
            futex(&v->spin, FUTEX_WAIT, 0);
        }
    }
    pid_t low = fork();
    if (low == 0) {
        pin(1);
        fifo(10);
        uint32_t tid = (uint32_t)syscall(SYS_gettid);
        for (uint32_t round = 1; round <= INVERSION_ROUNDS; round++) {
            uint32_t expected = 0;
            if (!__atomic_compare_exchange_n(&v->lock, &expected, tid, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
                _exit(1);
            __atomic_store_n(&v->ready, round, __ATOMIC_RELEASE);
            futex(&v->ready, FUTEX_WAKE, 1);
            while ((__atomic_load_n(&v->lock, __ATOMIC_ACQUIRE) & FUTEX_WAITERS) == 0) {
            }
            uint64_t late = rdtime() - v->stamp;
            v->wake_sum += late;
            if (late > v->wake_max) v->wake_max = late;
            expected = tid;
            if (!__atomic_compare_exchange_n(&v->lock, &expected, 0, 0, __ATOMIC_RELEASE, __ATOMIC_RELAXED))
                futex(&v->lock, FUTEX_UNLOCK_PI, 0);
        }
        _exit(0);
    }
    pid_t high = fork();
    if (high == 0) {
        pin(0);
        fifo(90);
        uint32_t tid = (uint32_t)syscall(SYS_gettid);
        uint64_t sum = 0;
        for (uint32_t round = 1; round <= INVERSION_ROUNDS; round++) {
            /* M se aparta para que L vuelva a tomar el cerrojo. */
            __atomic_store_n(&v->spin, 0, __ATOMIC_RELEASE);
            uint32_t seen;
            while ((seen = __atomic_load_n(&v->ready, __ATOMIC_ACQUIRE)) != round) futex(&v->ready, FUTEX_WAIT, seen);
            /* M vuelve a girar y expropia a L. */
            uint64_t spun = __atomic_load_n(&v->spun, __ATOMIC_ACQUIRE);
            __atomic_store_n(&v->spin, 1, __ATOMIC_RELEASE);
            futex(&v->spin, FUTEX_WAKE, 1);
            while (__atomic_load_n(&v->spun, __ATOMIC_ACQUIRE) == spun) {
            }
            uint64_t begin = rdtime();
            v->stamp = begin;
            uint32_t expected = 0;
            if (!__atomic_compare_exchange_n(&v->lock, &expected, tid, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
                if (futex(&v->lock, FUTEX_LOCK_PI, 0) != 0) _exit(1);
            sum += rdtime() - begin;
            expected = tid;
            if (!__atomic_compare_exchange_n(&v->lock, &expected, 0, 0, __ATOMIC_RELEASE, __ATOMIC_RELAXED))
                futex(&v->lock, FUTEX_UNLOCK_PI, 0);
        }
        __atomic_store_n(&v->spin, 0, __ATOMIC_RELEASE);
        v->stamp = sum;
        _exit(0);
    }
    int status_high = 0, status_low = 0;
    waitpid(high, &status_high, 0);
    waitpid(low, &status_low, 0);
    kill(medium, SIGKILL);
    waitpid(medium, NULL, 0);
    if (status_high != 0 || status_low != 0) {
        printf("la medida de inversion fallo (%d, %d)\n", status_high, status_low);
        fflush(stdout);
    }
    *total = v->stamp;
    *wake_sum = v->wake_sum;
    *wake_max = v->wake_max;
    munmap(v, 4096);
}

static void measure_inversion(void) {
    uint64_t total[REPEATS], wake_sum[REPEATS], wake_max[REPEATS];
    for (int i = 0; i < REPEATS; i++) inversion_once(&total[i], &wake_sum[i], &wake_max[i]);
    printf("inversion entre CPU con futex PI (H FIFO 90, L FIFO 10, M FIFO 50 girando): L corre a los ");
    print_spread(wake_sum, INVERSION_ROUNDS);
    printf("; el peor %llu ns; H tiene el cerrojo a los ", (unsigned long long)(max_of(wake_max) * NS_PER_UNIT));
    print_spread(total, INVERSION_ROUNDS);
    printf(" (%d x %d ops)\n", REPEATS, INVERSION_ROUNDS);
    fflush(stdout);
}

/*
 * Pasar 4 KiB de un proceso a otro de otra CPU y una suma de vuelta, como
 * benchmark.measureSharedPass en Fabianus. Por memoria compartida y futex
 * (sin copias), y por tubería (el kernel copia los 4 KiB).
 */
#define PASS_WORDS 512

struct pass {
    uint32_t turn;
    uint32_t pad;
    uint64_t sum;
    volatile uint64_t data[PASS_WORDS];
};

static uint64_t expected_sum(uint64_t round) { return 512 * round + 130816; }

static void shm_pass_once(uint64_t *total) {
    struct pass *x = shared(8192);
    pid_t server = fork();
    if (server == 0) {
        pin(1);
        for (int i = 0; i < ROUNDS; i++) {
            while (__atomic_load_n(&x->turn, __ATOMIC_ACQUIRE) != 1) futex(&x->turn, FUTEX_WAIT, 0);
            uint64_t sum = 0;
            for (int j = 0; j < PASS_WORDS; j++) sum += x->data[j];
            x->sum = sum;
            __atomic_store_n(&x->turn, 0, __ATOMIC_RELEASE);
            futex(&x->turn, FUTEX_WAKE, 1);
        }
        _exit(0);
    }
    pin(0);
    usleep(10000);
    int bad = 0;
    uint64_t begin = rdtime();
    for (uint64_t round = 1; round <= ROUNDS; round++) {
        for (int j = 0; j < PASS_WORDS; j++) x->data[j] = round + j;
        __atomic_store_n(&x->turn, 1, __ATOMIC_RELEASE);
        futex(&x->turn, FUTEX_WAKE, 1);
        while (__atomic_load_n(&x->turn, __ATOMIC_ACQUIRE) != 0) futex(&x->turn, FUTEX_WAIT, 1);
        if (x->sum != expected_sum(round)) bad = 1;
    }
    *total = rdtime() - begin;
    waitpid(server, NULL, 0);
    if (bad) {
        printf("la suma por memoria compartida no cuadro\n");
        fflush(stdout);
    }
    munmap(x, 8192);
}

static int full_read(int fd, void *buffer, size_t size) {
    size_t done = 0;
    while (done < size) {
        ssize_t n = read(fd, (char *)buffer + done, size - done);
        if (n <= 0) return 0;
        done += (size_t)n;
    }
    return 1;
}

static void pipe_pass_once(uint64_t *total) {
    int request[2], answer[2];
    if (pipe(request) || pipe(answer)) return;
    pid_t server = fork();
    if (server == 0) {
        pin(1);
        uint64_t data[PASS_WORDS];
        for (int i = 0; i < ROUNDS; i++) {
            if (!full_read(request[0], data, sizeof data)) _exit(1);
            uint64_t sum = 0;
            for (int j = 0; j < PASS_WORDS; j++) sum += data[j];
            if (write(answer[1], &sum, sizeof sum) != sizeof sum) _exit(1);
        }
        _exit(0);
    }
    pin(0);
    usleep(10000);
    uint64_t data[PASS_WORDS];
    int bad = 0;
    uint64_t begin = rdtime();
    for (uint64_t round = 1; round <= ROUNDS; round++) {
        for (int j = 0; j < PASS_WORDS; j++) data[j] = round + j;
        if (write(request[1], data, sizeof data) != sizeof data) break;
        uint64_t sum;
        if (!full_read(answer[0], &sum, sizeof sum)) break;
        if (sum != expected_sum(round)) bad = 1;
    }
    *total = rdtime() - begin;
    waitpid(server, NULL, 0);
    if (bad) {
        printf("la suma por tuberia no cuadro\n");
        fflush(stdout);
    }
    close(request[0]);
    close(request[1]);
    close(answer[0]);
    close(answer[1]);
}

static void measure_pass(void) {
    uint64_t total[REPEATS];
    for (int i = 0; i < REPEATS; i++) shm_pass_once(&total[i]);
    pin(0);
    printf("4 KiB entre CPU por memoria compartida y futex (escribir, despertar, leer y sumar): ");
    print_spread(total, ROUNDS);
    printf(" por cada 4 KiB (%d x %d)\n", REPEATS, ROUNDS);
    fflush(stdout);
    for (int i = 0; i < REPEATS; i++) pipe_pass_once(&total[i]);
    pin(0);
    printf("4 KiB entre CPU por tuberia (el kernel copia): ");
    print_spread(total, ROUNDS);
    printf(" por cada 4 KiB (%d x %d)\n", REPEATS, ROUNDS);
    fflush(stdout);
}

/* Mapear 64 KiB compartidos y escribir en sus 16 páginas, como
   benchmark.measureRegionMap. */
static void measure_map(void) {
    uint64_t total[REPEATS];
    for (int i = 0; i < REPEATS; i++) {
        uint64_t begin = rdtime();
        volatile char *memory = mmap(NULL, 16 * 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
        if (memory == MAP_FAILED) return;
        for (int page = 0; page < 16; page++) memory[page * 4096] = (char)page;
        total[i] = rdtime() - begin;
        munmap((void *)memory, 16 * 4096);
    }
    printf("mapear 64 KiB compartidos y escribir en sus 16 paginas: ");
    print_spread(total, 1);
    printf(" (%d veces)\n", REPEATS);
    fflush(stdout);
}

/*
 * Buscar un nombre sin tocar el disco (Hito 35), como la búsqueda del
 * servidor de archivos de Fabianus: stat de un archivo del initramfs, que
 * Linux resuelve en la caché de nombres (dcache). Con un directorio de 2 y de
 * 64 entradas, como la tabla de Fabianus con 1 y con 64 archivos.
 */
#define LOOKUP_ROUNDS 1024

static void measure_lookup_in(const char *directory, int entries, const char *label) {
    char path[64];
    mkdir(directory, 0755);
    for (int i = 0; i < entries; i++) {
        snprintf(path, sizeof path, "%s/f%02d", directory, i);
        int fd = open(path, O_CREAT | O_WRONLY, 0644);
        if (fd < 0) {
            printf("no se pudo crear %s\n", path);
            return;
        }
        close(fd);
    }
    snprintf(path, sizeof path, "%s/f%02d", directory, entries - 1);
    uint64_t total[REPEATS];
    struct stat info;
    for (int i = 0; i < REPEATS; i++) {
        uint64_t begin = rdtime();
        for (int round = 0; round < LOOKUP_ROUNDS; round++) {
            if (stat(path, &info) != 0) {
                printf("stat fallo\n");
                return;
            }
        }
        total[i] = rdtime() - begin;
    }
    printf("buscar un nombre con stat (%s): ", label);
    print_spread(total, LOOKUP_ROUNDS);
    printf(" (%d x %d)\n", REPEATS, LOOKUP_ROUNDS);
    fflush(stdout);
}

static void measure_lookup(void) {
    measure_lookup_in("/fs2", 2, "directorio de 2 entradas");
    measure_lookup_in("/fs64", 64, "directorio de 64 entradas");
}

/*
 * Directorios (Hito 37), como las medidas 6 y 7 del sistema de archivos de
 * Fabianus: stat de una ruta de 4 nombres (d1/d2/d3/bench), con el reloj, y
 * renombrar entre directorios (d1/d2/d3/bench <-> d1/bench), contando las
 * instrucciones de toda la máquina. En Linux todo queda en memoria (initramfs):
 * renombrar no escribe en el disco, y en Fabianus sí (la tabla).
 */
static void measure_directories(void) {
    mkdir("/d1", 0755);
    mkdir("/d1/d2", 0755);
    mkdir("/d1/d2/d3", 0755);
    int fd = open("/d1/d2/d3/bench", O_CREAT | O_WRONLY, 0644);
    if (fd < 0) {
        printf("no se pudo crear /d1/d2/d3/bench\n");
        return;
    }
    close(fd);
    uint64_t total[REPEATS];
    struct stat info;
    for (int i = 0; i < REPEATS; i++) {
        uint64_t begin = rdtime();
        for (int round = 0; round < LOOKUP_ROUNDS; round++) {
            if (stat("/d1/d2/d3/bench", &info) != 0) {
                printf("stat fallo\n");
                return;
            }
        }
        total[i] = rdtime() - begin;
    }
    printf("buscar una ruta de 4 nombres con stat: ");
    print_spread(total, LOOKUP_ROUNDS);
    printf(" (%d x %d)\n", REPEATS, LOOKUP_ROUNDS);
    for (int i = 0; i < REPEATS; i++) {
        uint64_t begin = rdtime();
        for (int round = 0; round < 128; round++) {
            const char *from = round % 2 == 0 ? "/d1/d2/d3/bench" : "/d1/bench";
            const char *to = round % 2 == 0 ? "/d1/bench" : "/d1/d2/d3/bench";
            if (rename(from, to) != 0) {
                printf("rename fallo\n");
                return;
            }
        }
        total[i] = rdtime() - begin;
    }
    printf("renombrar entre directorios, en memoria: ");
    print_spread(total, 128);
    printf(" (%d x 128)\n", REPEATS);
    fflush(stdout);
}

/*
 * Manejadores (Hito 38). Conseguir uno: open + close de una ruta de 1 y de 4
 * nombres (en Fabianus, LOOKUP, que da el manejador). Usarlo sin tocar el
 * disco: fstat sobre el descriptor (en Fabianus, una lectura con un
 * manejador caducado: ida y vuelta al servidor y la comprobación de la
 * generación).
 */
static void measure_handles(void) {
    const char *paths[2] = {"/fs2/f00", "/d1/d2/d3/bench"};
    const char *labels[2] = {"1 nombre", "4 nombres"};
    uint64_t total[REPEATS];
    for (int which = 0; which < 2; which++) {
        for (int i = 0; i < REPEATS; i++) {
            uint64_t begin = rdtime();
            for (int round = 0; round < LOOKUP_ROUNDS; round++) {
                int fd = open(paths[which], O_RDONLY);
                if (fd < 0) {
                    printf("open de %s fallo\n", paths[which]);
                    return;
                }
                close(fd);
            }
            total[i] = rdtime() - begin;
        }
        printf("open + close de una ruta de %s: ", labels[which]);
        print_spread(total, LOOKUP_ROUNDS);
        printf(" (%d x %d)\n", REPEATS, LOOKUP_ROUNDS);
    }
    int fd = open(paths[0], O_RDONLY);
    if (fd < 0) {
        printf("open de %s fallo\n", paths[0]);
        return;
    }
    struct stat info;
    for (int i = 0; i < REPEATS; i++) {
        uint64_t begin = rdtime();
        for (int round = 0; round < LOOKUP_ROUNDS; round++) {
            if (fstat(fd, &info) != 0) {
                printf("fstat fallo\n");
                return;
            }
        }
        total[i] = rdtime() - begin;
    }
    close(fd);
    printf("usar un descriptor sin disco (fstat): ");
    print_spread(total, LOOKUP_ROUNDS);
    printf(" (%d x %d)\n", REPEATS, LOOKUP_ROUNDS);
    fflush(stdout);
}

/*
 * Disco virtio-blk (Hito 34), como benchmark.measureDisk en Fabianus: leer y
 * escribir 4 KiB con O_DIRECT en los sectores 8i mod 2040, contando las
 * instrucciones de toda la máquina (instret, global con -icount). No con el
 * reloj: mientras todos esperan al disco, QEMU lo hace saltar.
 */
#define DISK_ROUNDS 256

static inline uint64_t rdinstret(void) {
    uint64_t value;
    __asm__ volatile("rdinstret %0" : "=r"(value));
    return value;
}

static int load_module(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    long status = syscall(SYS_finit_module, fd, "", 0);
    close(fd);
    return (int)status;
}

/* Carga los módulos y monta /dev. Devuelve si hay /dev/vda. */
static int prepare_disk(void) {
    if (load_module("/virtio_mmio.ko") != 0 || load_module("/virtio_blk.ko") != 0) {
        printf("disco: no se pudieron cargar los modulos\n");
        fflush(stdout);
        return 0;
    }
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    /* Linux solo deja leer instret desde usuario con perf_user_access = 2. */
    int fd = open("/proc/sys/kernel/perf_user_access", O_WRONLY);
    if (fd >= 0) {
        if (write(fd, "2", 1) != 1) printf("disco: no se pudo abrir instret\n");
        close(fd);
    }
    return 1;
}

static void disk_once(int write_mode, uint64_t *instructions) {
    int fd = open("/dev/vda", (write_mode ? O_RDWR : O_RDONLY) | O_DIRECT);
    void *buffer = NULL;
    if (fd < 0 || posix_memalign(&buffer, 4096, 4096) != 0) {
        printf("disco: no se pudo abrir /dev/vda\n");
        fflush(stdout);
        *instructions = 0;
        return;
    }
    memset(buffer, 0x5a, 4096);
    int bad = 0;
    uint64_t sector = 0;
    uint64_t begin = rdinstret();
    for (int i = 0; i < DISK_ROUNDS; i++) {
        ssize_t n = write_mode ? pwrite(fd, buffer, 4096, (off_t)(sector * 512))
                               : pread(fd, buffer, 4096, (off_t)(sector * 512));
        if (n != 4096) bad = 1;
        sector += 8;
        if (sector >= 2040) sector = 0;
    }
    *instructions = rdinstret() - begin;
    if (bad) {
        printf("disco: una transferencia fallo\n");
        fflush(stdout);
    }
    if (!write_mode && ((uint64_t *)buffer)[1] == 0) {
        printf("disco: los datos leidos no cuadran\n");
        fflush(stdout);
    }
    free(buffer);
    close(fd);
}

static void measure_disk(void) {
    /* instret desde usuario puede no estar permitido (falla) o no avanzar
       (Linux 6.12 en este QEMU devuelve siempre lo mismo): se prueba en un
       hijo con un bucle conocido. */
    pid_t probe = fork();
    if (probe == 0) {
        uint64_t before = rdinstret();
        __asm__ volatile("li t0, 1000\n1: addi t0, t0, -1\nbnez t0, 1b" ::: "t0");
        _exit(rdinstret() - before >= 2000 ? 0 : 1);
    }
    int status = 0;
    waitpid(probe, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        printf("disco: /dev/vda funciona, pero instret no avanza leido desde usuario: sin medida\n");
        fflush(stdout);
        return;
    }
    const char *names[2] = {"leer 4 KiB del disco (O_DIRECT)", "escribir 4 KiB en el disco (O_DIRECT)"};
    for (int mode = 0; mode < 2; mode++) {
        uint64_t runs[REPEATS];
        pin(0);
        for (int i = 0; i < REPEATS; i++) disk_once(mode, &runs[i]);
        sort(runs);
        printf("%s: %llu instrucciones de toda la maquina (minima; mediana %llu, maxima %llu) (%d x %d)\n",
               names[mode], (unsigned long long)(runs[0] / DISK_ROUNDS),
               (unsigned long long)(runs[REPEATS / 2] / DISK_ROUNDS),
               (unsigned long long)(runs[REPEATS - 1] / DISK_ROUNDS), REPEATS, DISK_ROUNDS);
        fflush(stdout);
    }
}

int main(void) {
    mkdir("/proc", 0555);
    mount("proc", "/proc", "proc", 0, NULL);
    char release[128] = "?";
    int fd = open("/proc/sys/kernel/osrelease", O_RDONLY);
    if (fd >= 0) {
        ssize_t n = read(fd, release, sizeof release - 1);
        release[n > 0 ? n - 1 : 0] = 0;
        close(fd);
    }
    printf("linux %s: benchmark con %ld CPU\n", release, sysconf(_SC_NPROCESSORS_ONLN));
    fflush(stdout);
    int disk = prepare_disk();

    /* Deja que terminen las tareas de arranque del kernel antes de medir. */
    sleep(3);
    pin(0);
    calibrate("las demas CPU en reposo");
    calibrate_busy();

    measure_ping_pong("futex, misma CPU", futex_once, 0, 0);
    measure_ping_pong("futex, entre CPU", futex_once, 0, 1);
    measure_ping_pong("pipe, misma CPU", pipe_once, 0, 0);
    measure_ping_pong("pipe, entre CPU", pipe_once, 0, 1);
    measure_inversion();
    measure_pass();
    measure_map();
    measure_lookup();
    measure_directories();
    measure_handles();
    if (disk) measure_disk();

    printf("fin del benchmark de linux\n");
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    return 0;
}
