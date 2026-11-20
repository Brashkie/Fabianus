//! Autopruebas de los hilos dormidos.

const abi = @import("abi.zig").c;
const process = @import("process.zig");
const riscv = @import("riscv.zig");
const selftest_driver = @import("selftest_driver.zig");
const selftest_ipc = @import("selftest_ipc.zig");
const sleep = @import("sleep.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");

const passed = selftest_ipc.passed;
const start = selftest_ipc.start;
const waitBlocked = selftest_ipc.waitBlocked;
const expectEqual = selftest_ipc.expectEqual;
const expectExit = selftest_driver.expectExit;

fn testGate() void {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    const none = abi.FB_SLEEP_NONE;
    expectEqual(abi.fb_sleep_arm(0, 10), abi.FB_SLEEP_INVALID);
    expectEqual(abi.fb_sleep_arm(8, 10), abi.FB_SLEEP_INVALID);
    expectEqual(abi.fb_sleep_arm(1, none), abi.FB_SLEEP_INVALID);
    expectEqual(abi.fb_sleep_disarm(0), abi.FB_SLEEP_INVALID);
    expectEqual(abi.fb_sleep_disarm(1), abi.FB_SLEEP_NOT_ARMED);
    expectEqual(abi.fb_sleep_earliest(), none);
    expectEqual(abi.fb_sleep_take_expired(none - 1), none);
    passed("dormir rechaza peticiones invalidas");
}

var sleeper_deadline: u64 = 0;
var sleeper_woke_at: u64 = 0;

fn sleeper(_: u64) callconv(.c) void {
    _ = sleep.sleepUntil(sleeper_deadline);
    sleeper_woke_at = timer.now();
}

/// Un intento de testWakesOnTime. Devuelve si llegó a ver al hilo dormido: con
/// el anfitrión saturado puede despertar y terminar antes.
fn wakesOnTimeOnce() bool {
    // Justo después de un tick y con el presupuesto entero, el vencimiento cae
    // antes del siguiente tick y del final de la rodaja (medio cuanto): solo
    // llega a tiempo si el temporizador se programa para él.
    thread.setParams(0, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);
    const tick = timer.ticks();
    while (timer.ticks() == tick) {}
    const wakes_before = sleep.wakes();
    sleeper_woke_at = 0;
    sleeper_deadline = timer.now() + thread.quantum() / 2;
    const id = thread.spawn(sleeper, 0, .on) orelse @panic("no se pudo crear el hilo");
    while (thread.isAlive(id) and thread.state(id) != abi.FB_THREAD_BLOCKED) thread.yield();
    var seen = false;
    {
        const saved = riscv.disableInterruptsSaving();
        defer riscv.restoreInterrupts(saved);
        if (thread.state(id) == abi.FB_THREAD_BLOCKED) {
            seen = true;
            if (timer.armedAt() > sleeper_deadline) {
                @panic("un hilo dormido no tiene prevista la interrupcion que lo despierta");
            }
        }
    }
    while (thread.isAlive(id)) thread.yield();
    if (sleeper_woke_at < sleeper_deadline) @panic("un hilo desperto antes de su vencimiento");
    // Si el anfitrión iba lento, el vencimiento pudo pasar antes de dormir: el
    // hilo no llegó a dormir y el intento no cuenta.
    if (!seen) return false;
    if (sleep.wakes() == wakes_before) @panic("el hilo no lo desperto su vencimiento");
    return true;
}

/// Mientras el hilo duerme, el temporizador está programado para no más tarde
/// de su vencimiento; y al despertar, el vencimiento ya ha llegado.
fn testWakesOnTime() void {
    for (0..5) |_| {
        if (wakesOnTimeOnce()) {
            passed("un hilo dormido despierta a su hora, ni antes ni sin interrupcion prevista");
            return;
        }
    }
    @panic("no se pudo ver dormido al hilo en cinco intentos");
}

/// Un proceso mide su latencia de despertar varias veces: nunca antes de tiempo.
fn testUserSleeps() void {
    const period: u64 = abi.FB_TIMEBASE_HZ / 1000;
    const rounds: u64 = 20;
    const id = start(.latency_probe, rounds << 32 | period, &.{});
    while (thread.isAlive(id)) thread.yield();
    const result = process.resultOf(id);
    if (result.kind != .exited) @panic("el proceso que duerme no termino bien");
    if (result.value >> 63 != 0) @panic("un proceso desperto antes de su vencimiento");
    passed("un proceso duerme hasta un instante y mide su latencia");
}

/// Dormir hasta un instante ya pasado vuelve en seguida.
fn testPastDeadline() void {
    if (sleep.sleepUntil(1) != 0) @panic("dormir hasta un instante pasado fallo");
    passed("dormir hasta un instante pasado vuelve en seguida");
}

/// Se puede matar a un proceso que duerme: despierta y muere.
fn testKillSleeper() void {
    const id = start(.sleep_forever, 0, &.{});
    waitBlocked(id);
    process.requestKill(id);
    while (thread.isAlive(id)) thread.yield();
    if (process.resultOf(id).kind != .killed) @panic("el proceso dormido no murio");
    if (abi.fb_sleep_earliest() != abi.FB_SLEEP_NONE) @panic("el proceso muerto sigue dormido");
    if (@import("sleep.zig").earliest() != abi.FB_SLEEP_NONE) @panic("la copia del vencimiento sigue con el proceso muerto");
    passed("se puede matar a un proceso dormido");
}

var order: [2]u8 = undefined;
var order_length: usize = 0;

fn note(tag: u8) void {
    order[order_length] = tag;
    order_length += 1;
}

fn sleepThenNote(_: u64) callconv(.c) void {
    _ = sleep.sleepUntil(timer.now() + abi.FB_TIMEBASE_HZ);
    note('s');
}

fn justNote(_: u64) callconv(.c) void {
    thread.block();
    note('w');
}

/// Un hilo que se bloquea nada más empezar; corre cuando lo desbloquean.
fn spawnPaused() u64 {
    const id = spawnRoomy(justNote, .off);
    waitBlocked(id);
    return id;
}

/// Con presupuesto de sobra: si QEMU va lento frente al reloj real, un
/// presupuesto justo se agotaría y el hilo dejaría de ser elegible.
fn spawnRoomy(entry: thread.Entry, interrupts: thread.Interrupts) u64 {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    const id = thread.spawn(entry, 0, interrupts) orelse @panic("no se pudo crear el hilo");
    thread.setParams(id, abi.FB_PRIO_NORMAL, 10 * abi.FB_SCHED_DEFAULT_BUDGET);
    return id;
}

/// Quien despierta de dormir corre antes que otro listo de su nivel. Dos
/// rondas, con el otro antes y después en el orden natural del turno.
/// Una ronda de testWakeGoesFirst. Devuelve si el despertado fue el primero.
fn wakeGoesFirstOnce(other_first: bool) bool {
    order_length = 0;
    var other: u64 = 0;
    // El otro se crea en pausa (bloqueado) para que no corra antes de tiempo.
    if (other_first) other = spawnPaused();
    const sleeper_id = spawnRoomy(sleepThenNote, .on);
    waitBlocked(sleeper_id);
    if (!other_first) other = spawnPaused();
    {
        const saved = riscv.disableInterruptsSaving();
        defer riscv.restoreInterrupts(saved);
        thread.unblock(other);
        // Su vencimiento pasa a estar vencido, y se despierta como en la
        // interrupción del temporizador.
        expectEqual(abi.fb_sleep_disarm(sleeper_id), abi.FB_SLEEP_OK);
        expectEqual(abi.fb_sleep_arm(sleeper_id, 1), abi.FB_SLEEP_OK);
        sleep.wakeExpired();
    }
    while (thread.isAlive(sleeper_id) or thread.isAlive(other)) thread.yield();
    return order_length == 2 and order[0] == 's';
}

/// Con el anfitrión saturado una pausa larga puede agotar un presupuesto; una
/// mutación en cambio falla siempre, así que se admiten tres intentos.
fn testWakeGoesFirst() void {
    thread.setParams(0, abi.FB_PRIO_NORMAL, 10 * abi.FB_SCHED_DEFAULT_BUDGET);
    defer thread.setParams(0, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);
    for ([_]bool{ false, true }) |other_first| {
        var ok = false;
        for (0..3) |_| {
            if (wakeGoesFirstOnce(other_first)) {
                ok = true;
                break;
            }
        }
        if (!ok) @panic("quien desperto no fue el primero de su nivel");
    }
    passed("quien despierta de dormir va el primero de su nivel");
}

pub fn run() void {
    // El hilo principal espera en el kernel: sin interrupciones encendidas no
    // llegaría la del temporizador que despierta a los dormidos.
    riscv.enableInterrupts();
    defer riscv.disableInterrupts();
    testGate();
    testPastDeadline();
    testWakesOnTime();
    testUserSleeps();
    testKillSleeper();
    testWakeGoesFirst();
}
