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

    printf("fin del benchmark de linux\n");
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    return 0;
}
