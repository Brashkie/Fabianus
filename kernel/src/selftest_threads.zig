//! Autopruebas de hilos, cambio de contexto y expropiación.

const abi = @import("abi.zig").c;
const riscv = @import("riscv.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");
const uart = @import("uart.zig");

fn passed(name: []const u8) void {
    uart.print("[ok] ");
    uart.print(name);
    uart.print("\n");
}

fn spawnOrPanic(entry: thread.Entry, argument: u64, interrupts: thread.Interrupts) u64 {
    return thread.spawn(entry, argument, interrupts) orelse @panic("no se pudo crear el hilo");
}

fn waitUntilDead(id: u64) void {
    while (thread.isAlive(id)) thread.yield();
}

fn expectStatus(actual: u64, expected: u64) void {
    if (actual != expected) @panic("estado inesperado del planificador");
}

var log: [16]u8 = undefined;
var log_length: usize = 0;

fn appendLog(byte: u8) void {
    if (log_length == log.len) @panic("registro de la prueba lleno");
    log[log_length] = byte;
    log_length += 1;
}

fn logEquals(expected: []const u8) bool {
    if (log_length != expected.len) return false;
    for (expected, log[0..log_length]) |wanted, actual| {
        if (wanted != actual) return false;
    }
    return true;
}

fn alternatingWorker(tag: u64) callconv(.c) void {
    for (0..3) |_| {
        appendLog(@truncate(tag));
        thread.yield();
    }
}

fn testCooperativeOrder() void {
    log_length = 0;
    const first = spawnOrPanic(alternatingWorker, 'A', .off);
    const second = spawnOrPanic(alternatingWorker, 'B', .off);
    // El orden no debe depender de lo que tarde la máquina anfitriona.
    thread.setParams(first, abi.FB_PRIO_NORMAL, abi.FB_SCHED_MAX_BUDGET);
    thread.setParams(second, abi.FB_PRIO_NORMAL, abi.FB_SCHED_MAX_BUDGET);
    waitUntilDead(first);
    waitUntilDead(second);
    if (!logEquals("ABABAB")) @panic("orden de planificacion incorrecto");
    passed("turnos en orden round-robin");
}

fn yieldFromAssembly() callconv(.c) void {
    thread.yield();
}

var callee_saved_failed: bool = false;

fn calleeSavedWorker(seed: u64) callconv(.c) void {
    for (0..16) |round| {
        if (abi.fb_selftest_callee_saved(yieldFromAssembly, seed + round * 256) != 0) {
            callee_saved_failed = true;
        }
    }
}

fn testCalleeSavedRegisters() void {
    callee_saved_failed = false;
    const first = spawnOrPanic(calleeSavedWorker, 0x1000, .off);
    const second = spawnOrPanic(calleeSavedWorker, 0x7000, .off);
    waitUntilDead(first);
    waitUntilDead(second);
    if (callee_saved_failed) @panic("un cambio de contexto altero s0-s11");
    passed("cambio de contexto conserva s0-s11");
}

var spin_counters: [2]u64 = undefined;
var spin_stop: u64 = 0;
var spin_failed: bool = false;

fn spinWorker(index: u64) callconv(.c) void {
    if (abi.fb_selftest_preempt_spin(&spin_counters[index], &spin_stop) != 0) {
        @atomicStore(bool, &spin_failed, true, .seq_cst);
    }
}

fn counter(index: usize) u64 {
    return @atomicLoad(u64, &spin_counters[index], .seq_cst);
}

/// Ningún hilo cede aquí: solo el timer puede repartir la CPU.
fn testPreemption() void {
    const minimum_preemptions: u64 = 12;
    const limit = abi.FB_TIMEBASE_HZ * 20;

    spin_counters = .{ 0, 0 };
    spin_stop = 0;
    @atomicStore(bool, &spin_failed, false, .seq_cst);

    const first = spawnOrPanic(spinWorker, 0, .on);
    const second = spawnOrPanic(spinWorker, 1, .on);
    const preemptions_before = thread.preemptions();
    const start = timer.now();

    riscv.enableInterrupts();
    while (thread.preemptions() - preemptions_before < minimum_preemptions or
        counter(0) == 0 or counter(1) == 0)
    {
        if (timer.now() - start > limit) @panic("la expropiacion no reparte la CPU");
    }
    @atomicStore(u64, &spin_stop, 1, .seq_cst);
    while (thread.isAlive(first) or thread.isAlive(second)) {
        if (timer.now() - start > limit) @panic("los hilos no terminaron");
    }
    riscv.disableInterrupts();

    if (@atomicLoad(bool, &spin_failed, .seq_cst)) @panic("la expropiacion altero registros");
    uart.print("[ok] expropiacion por timer, cambios: ");
    uart.printDecimal(thread.preemptions() - preemptions_before);
    uart.print("\n");
}

fn blockingWorker(_: u64) callconv(.c) void {
    appendLog('w');
    thread.block();
    appendLog('r');
}

fn testBlockAndWake() void {
    log_length = 0;
    const worker = spawnOrPanic(blockingWorker, 0, .off);

    thread.yield();
    if (thread.state(worker) != abi.FB_THREAD_BLOCKED) @panic("el hilo no se bloqueo");

    // Un hilo bloqueado nunca debe recibir CPU.
    thread.yield();
    thread.yield();
    if (!logEquals("w")) @panic("un hilo bloqueado se ejecuto");

    thread.unblock(worker);
    waitUntilDead(worker);
    if (!logEquals("wr")) @panic("el hilo no desperto");
    passed("bloqueo y despertar");
}

fn emptyWorker(_: u64) callconv(.c) void {}

fn testSlotExhaustionAndReuse() void {
    var ids: [thread.max_threads - 1]u64 = undefined;
    for (&ids) |*id| id.* = spawnOrPanic(emptyWorker, 0, .off);
    if (thread.spawn(emptyWorker, 0, .off) != null) @panic("se crearon hilos de mas");
    for (ids) |id| waitUntilDead(id);

    for (0..64) |_| waitUntilDead(spawnOrPanic(emptyWorker, 0, .off));
    passed("agotamiento y reutilizacion de hilos");
}

/// Con interrupciones apagadas: el planificador no es reentrante.
fn testGateRejectsInvalidRequests() void {
    const model = thread.lockModel();
    defer thread.unlockModel(model);
    const h = @import("hart.zig").id();
    expectStatus(abi.fb_sched_init(), abi.FB_SCHED_ALREADY);
    expectStatus(abi.fb_sched_block(h, 0), abi.FB_SCHED_INVALID);
    expectStatus(abi.fb_sched_exit(h, 0), abi.FB_SCHED_INVALID);
    expectStatus(abi.fb_sched_unblock(h, 0), abi.FB_SCHED_INVALID);
    expectStatus(abi.fb_sched_block(h, 99), abi.FB_SCHED_INVALID);
    expectStatus(abi.fb_sched_unblock(h, 1), abi.FB_SCHED_WRONG_STATE);
    expectStatus(abi.fb_sched_block(h, 1), abi.FB_SCHED_WRONG_STATE);
    expectStatus(abi.fb_sched_exit(h, 1), abi.FB_SCHED_WRONG_STATE);
    expectStatus(abi.fb_sched_state(h, 99), abi.FB_SCHED_NONE);
    passed("el planificador rechaza peticiones invalidas");
}

fn overflowingWorker(_: u64) callconv(.c) void {
    asm volatile (
        \\1:
        \\addi sp, sp, -2048
        \\addi sp, sp, -2048
        \\sd zero, 0(sp)
        \\j 1b
        ::: "memory");
}

/// Agota la pila de un hilo; debe detectarse en su página de guarda.
pub fn crashThreadStack() void {
    const id = spawnOrPanic(overflowingWorker, 0, .off);
    uart.print("guarda del hilo: ");
    uart.printHex(thread.kernelStackGuard(id));
    uart.print("\n");
    thread.yield();
}

pub fn run() void {
    testGateRejectsInvalidRequests();
    testCooperativeOrder();
    testCalleeSavedRegisters();
    testBlockAndWake();
    testSlotExhaustionAndReuse();
    testPreemption();
}
