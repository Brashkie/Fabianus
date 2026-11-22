// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Mide en Linux las mismas operaciones que el benchmark de Fabianus, en
 * instrucciones retiradas con QEMU en -icount. Es el /init de un initramfs:
 * mide, imprime y apaga la máquina.
 *
 * Linux para los contadores de hardware fuera de perf, así que se cuentan con
 * perf_event_open en modo sistema sobre la CPU 0: todas las instrucciones del
 * hart, de usuario y de kernel y de cualquier proceso, igual que instret en
 * Fabianus.
 *
 * No forma parte de Fabianus: solo sirve para comparar. Se compila estático con
 * `zig cc -target riscv64-linux-musl`.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/futex.h>
#include <linux/perf_event.h>
#include <sched.h>
#include <signal.h>
#include <sys/prctl.h>
#include <time.h>
#include <spawn.h>
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

extern char **environ;

#define ROUNDS 4096
#define PROCESS_ROUNDS 16

static int counter = -1;

static uint64_t instret(void) {
    uint64_t value = 0;
    if (read(counter, &value, sizeof value) != sizeof value) return 0;
    return value;
}

static int open_counter(void) {
    struct perf_event_attr attr;
    memset(&attr, 0, sizeof attr);
    attr.type = PERF_TYPE_HARDWARE;
    attr.size = sizeof attr;
    attr.config = PERF_COUNT_HW_INSTRUCTIONS;
    counter = (int)syscall(SYS_perf_event_open, &attr, -1, 0, -1, 0);
    return counter;
}

/* Llamada al sistema sin pasar por libc, como BENCH_LOOP en Fabianus. */
static inline long raw_syscall0(long number) {
    register long a7 __asm__("a7") = number;
    register long a0 __asm__("a0");
    __asm__ volatile("ecall" : "=r"(a0) : "r"(a7) : "memory");
    return a0;
}

#define REPEATS 5

/* Cada medida se repite REPEATS veces; se dan la mínima, la mediana y la máxima. */
static uint64_t samples[REPEATS];
static int sample_count;

static void report(const char *name, uint64_t total, uint64_t operations) {
    samples[sample_count++] = total / operations;
    if (sample_count < REPEATS) return;
    for (int i = 1; i < REPEATS; i++)
        for (int j = i; j > 0 && samples[j - 1] > samples[j]; j--) {
            uint64_t swap = samples[j];
            samples[j] = samples[j - 1];
            samples[j - 1] = swap;
        }
    printf("%s: %llu instrucciones/op (minima; mediana %llu, maxima %llu; %d x %llu ops)\n", name,
           (unsigned long long)samples[0], (unsigned long long)samples[REPEATS / 2],
           (unsigned long long)samples[REPEATS - 1], REPEATS, (unsigned long long)operations);
    fflush(stdout);
    sample_count = 0;
}

static void repeat(void (*measure)(void)) {
    for (int i = 0; i < REPEATS; i++) measure();
}

/* Ida y vuelta de una llamada al sistema trivial: getppid. */
static void measure_syscall(void) {
    uint64_t start = instret();
    for (int i = 0; i < ROUNDS; i++) raw_syscall0(SYS_getppid);
    report("llamada al sistema, ida y vuelta (getppid)", instret() - start, ROUNDS);
}

/* Dos procesos ceden la CPU por turnos: cada sched_yield cambia de proceso. */
static void measure_yield(void) {
    int go[2];
    if (pipe(go)) return;
    pid_t child = fork();
    if (child == 0) {
        char byte;
        read(go[0], &byte, 1);
        for (int i = 0; i < ROUNDS; i++) raw_syscall0(SYS_sched_yield);
        _exit(0);
    }
    write(go[1], "g", 1);
    uint64_t start = instret();
    for (int i = 0; i < ROUNDS; i++) raw_syscall0(SYS_sched_yield);
    uint64_t total = instret() - start;
    waitpid(child, NULL, 0);
    report("yield con cambio de proceso (sched_yield)", total, 2 * ROUNDS);
    close(go[0]);
    close(go[1]);
}

/* Ida y vuelta de un mensaje de 8 bytes entre dos procesos con tuberías. */
static void measure_pipe(void) {
    int request[2], answer[2];
    if (pipe(request) || pipe(answer)) return;
    pid_t child = fork();
    uint64_t word = 1;
    if (child == 0) {
        for (int i = 0; i < ROUNDS; i++) {
            read(request[0], &word, sizeof word);
            word++;
            write(answer[1], &word, sizeof word);
        }
        _exit(0);
    }
    uint64_t start = instret();
    for (int i = 0; i < ROUNDS; i++) {
        write(request[1], &word, sizeof word);
        read(answer[0], &word, sizeof word);
    }
    uint64_t total = instret() - start;
    waitpid(child, NULL, 0);
    report("ida y vuelta entre procesos (pipe)", total, ROUNDS);
    close(request[0]);
    close(request[1]);
    close(answer[0]);
    close(answer[1]);
}

static long futex(uint32_t *address, int operation, uint32_t value) {
    return syscall(SYS_futex, address, operation, value, NULL, NULL, 0);
}

/* Ida y vuelta entre procesos con memoria compartida y futex: el mecanismo
   mínimo que ofrece Linux para despertar a otro proceso. */
static void measure_futex(void) {
    uint32_t *turn = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (turn == MAP_FAILED) return;
    *turn = 0;
    pid_t child = fork();
    if (child == 0) {
        for (int i = 0; i < ROUNDS; i++) {
            while (__atomic_load_n(turn, __ATOMIC_ACQUIRE) != 1) futex(turn, FUTEX_WAIT, 0);
            __atomic_store_n(turn, 0, __ATOMIC_RELEASE);
            futex(turn, FUTEX_WAKE, 1);
        }
        _exit(0);
    }
    uint64_t start = instret();
    for (int i = 0; i < ROUNDS; i++) {
        __atomic_store_n(turn, 1, __ATOMIC_RELEASE);
        futex(turn, FUTEX_WAKE, 1);
        while (__atomic_load_n(turn, __ATOMIC_ACQUIRE) != 0) futex(turn, FUTEX_WAIT, 1);
    }
    uint64_t total = instret() - start;
    waitpid(child, NULL, 0);
    report("ida y vuelta entre procesos (futex)", total, ROUNDS);
    munmap(turn, 4096);
}

/* Crear un proceso que imprime una línea y termina, y esperarlo. */
static void measure_fork_exec(void) {
    char *argv[] = {"/hello", NULL};
    uint64_t start = instret();
    for (int i = 0; i < PROCESS_ROUNDS; i++) {
        pid_t child = fork();
        if (child == 0) {
            execve("/hello", argv, environ);
            _exit(127);
        }
        waitpid(child, NULL, 0);
    }
    report("crear, ejecutar y destruir proceso (fork+execve)", instret() - start, PROCESS_ROUNDS);
}

static void measure_spawn(void) {
    char *argv[] = {"/hello", NULL};
    uint64_t start = instret();
    for (int i = 0; i < PROCESS_ROUNDS; i++) {
        pid_t child;
        if (posix_spawn(&child, "/hello", NULL, NULL, argv, environ) == 0) waitpid(child, NULL, 0);
    }
    report("crear, ejecutar y destruir proceso (posix_spawn)", instret() - start, PROCESS_ROUNDS);
}

/*
 * Latencia de despertar bajo carga, como cyclictest y como latency_probe en
 * Fabianus: dormir hasta un instante absoluto y medir cuánto se tarda en volver
 * a correr, mientras otros procesos giran sin parar. El siguiente instante es
 * el de despertar más el periodo, igual que en Fabianus.
 */
#define LATENCY_PERIOD_NS 1000000L
#define LATENCY_ROUNDS 200

struct latency_result {
    uint64_t max;
    uint64_t sum;
    uint64_t early;
    uint64_t max_round;
    uint64_t second;
};

static int64_t nanoseconds(const struct timespec *t) {
    return (int64_t)t->tv_sec * 1000000000L + t->tv_nsec;
}

static void latency_probe(int fifo, struct latency_result *out) {
    if (fifo) {
        struct sched_param param = {.sched_priority = 99};
        /* Con la llamada al sistema directa: el sched_setscheduler de musl
           devuelve siempre ENOSYS, porque el de Linux no sigue POSIX. Hasta el
           Hito 26 se llamaba al de musl, y la sonda corría con SCHED_OTHER. */
        if (syscall(SYS_sched_setscheduler, 0, SCHED_FIFO, &param) != 0 ||
            syscall(SYS_sched_getscheduler, 0) != SCHED_FIFO) {
            printf("no se pudo poner SCHED_FIFO\n");
            fflush(stdout);
        }
    }
    /* Sin holgura: Linux puede retrasar a propósito hasta 50 us los despertares
       de procesos normales para agruparlos. */
    prctl(PR_SET_TIMERSLACK, 1UL, 0, 0, 0);
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    int64_t next = nanoseconds(&now);
    for (int i = 0; i < LATENCY_ROUNDS; i++) {
        next += LATENCY_PERIOD_NS;
        struct timespec deadline = {.tv_sec = next / 1000000000L, .tv_nsec = next % 1000000000L};
        while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &deadline, NULL) != 0) {
        }
        clock_gettime(CLOCK_MONOTONIC, &now);
        int64_t woke = nanoseconds(&now);
        if (woke < next) {
            out->early++;
        } else {
            uint64_t late = (uint64_t)(woke - next);
            out->sum += late;
            if (late > out->max) {
                out->second = out->max;
                out->max = late;
                out->max_round = (uint64_t)i;
            } else if (late > out->second) {
                out->second = late;
            }
        }
        next = woke;
    }
}

static void measure_latency(const char *name, int fifo, int hogs) {
    struct latency_result *result = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (result == MAP_FAILED) return;
    memset(result, 0, sizeof *result);
    pid_t hog[3];
    for (int i = 0; i < hogs; i++) {
        hog[i] = fork();
        if (hog[i] == 0)
            for (;;) __asm__ volatile("" ::: "memory");
    }
    pid_t probe = fork();
    if (probe == 0) {
        latency_probe(fifo, result);
        _exit(0);
    }
    waitpid(probe, NULL, 0);
    for (int i = 0; i < hogs; i++) {
        kill(hog[i], SIGKILL);
        waitpid(hog[i], NULL, 0);
    }
    printf("latencia, %s: maxima %llu ns, media %llu ns (%d vueltas de 1 ms; antes de tiempo: %llu)\n", name,
           (unsigned long long)result->max, (unsigned long long)(result->sum / LATENCY_ROUNDS), LATENCY_ROUNDS,
           (unsigned long long)result->early);
    printf("  la maxima fue en la vuelta %llu; la segunda mayor, %llu ns\n",
           (unsigned long long)result->max_round, (unsigned long long)result->second);
    fflush(stdout);
    munmap(result, 4096);
}

/* Tres procesos ocupados del mismo nivel durante 200 ms: la mayor espera de
   cada uno entre dos turnos, como measureTurnGap en Fabianus. */
static void measure_turn_gap(void) {
    int64_t *gaps = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (gaps == MAP_FAILED) return;
    memset(gaps, 0, 3 * sizeof *gaps);
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    int64_t stop = nanoseconds(&now) + 200000000L;
    pid_t children[3];
    for (int i = 0; i < 3; i++) {
        children[i] = fork();
        if (children[i] == 0) {
            clock_gettime(CLOCK_MONOTONIC, &now);
            int64_t last = nanoseconds(&now);
            while (last < stop) {
                clock_gettime(CLOCK_MONOTONIC, &now);
                int64_t time = nanoseconds(&now);
                if (time - last > gaps[i]) gaps[i] = time - last;
                last = time;
            }
            _exit(0);
        }
    }
    for (int i = 0; i < 3; i++) waitpid(children[i], NULL, 0);
    int64_t worst = gaps[0];
    if (gaps[1] > worst) worst = gaps[1];
    if (gaps[2] > worst) worst = gaps[2];
    printf("mismo nivel, 3 procesos ocupados: espera maxima entre turnos %lld ns\n", (long long)worst);
    fflush(stdout);
    munmap(gaps, 4096);
}

static void mount_proc(void) {
    mkdir("/proc", 0555);
    mount("proc", "/proc", "proc", 0, NULL);
}

int main(void) {
    mount_proc();
    char release[128] = "?";
    int fd = open("/proc/sys/kernel/osrelease", O_RDONLY);
    if (fd >= 0) {
        ssize_t n = read(fd, release, sizeof release - 1);
        release[n > 0 ? n - 1 : 0] = 0;
        close(fd);
    }
    printf("linux %s: benchmark\n", release);
    if (open_counter() < 0) {
        printf("no se pudo abrir el contador de instrucciones\n");
        fflush(stdout);
        reboot(RB_POWER_OFF);
    }
    /* Lo que cuesta leer el contador, para restarlo si hiciera falta. */
    uint64_t probe = instret();
    printf("leer el contador: %llu instrucciones\n", (unsigned long long)(instret() - probe));
    fflush(stdout);

    /* Deja que terminen las tareas de arranque del kernel antes de medir. */
    sleep(3);

    /* Calibración: un bucle de exactamente 2 instrucciones por vuelta. */
    uint64_t start = instret();
    __asm__ volatile("li t0, 1000000\n1: addi t0, t0, -1\nbnez t0, 1b" ::: "t0");
    printf("calibracion: %llu instrucciones para un bucle de 2000001\n",
           (unsigned long long)(instret() - start));
    fflush(stdout);

    repeat(measure_syscall);
    repeat(measure_yield);
    repeat(measure_pipe);
    repeat(measure_futex);
    repeat(measure_fork_exec);
    repeat(measure_spawn);

    measure_turn_gap();
    measure_latency("sin carga (SCHED_FIFO 99)", 1, 0);
    measure_latency("SCHED_FIFO 99 y 3 procesos ocupados", 1, 3);
    measure_latency("misma prioridad que 3 procesos ocupados (EEVDF)", 0, 3);

    printf("fin del benchmark de linux\n");
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    return 0;
}
