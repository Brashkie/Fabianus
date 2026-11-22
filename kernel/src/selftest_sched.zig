// SPDX-License-Identifier: GPL-3.0-or-later
//! Autopruebas de las prioridades y de los presupuestos de CPU.

const abi = @import("abi.zig").c;
const ipc = @import("ipc.zig");
const process = @import("process.zig");
const riscv = @import("riscv.zig");
const selftest_driver = @import("selftest_driver.zig");
const selftest_ipc = @import("selftest_ipc.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");
const uart = @import("uart.zig");

const passed = selftest_ipc.passed;
const endpoint = selftest_ipc.endpoint;
const start = selftest_ipc.start;
const waitBlocked = selftest_ipc.waitBlocked;
const expectEqual = selftest_ipc.expectEqual;
const expectExit = selftest_driver.expectExit;

const low: u64 = abi.FB_PRIO_LOW;
const normal: u64 = abi.FB_PRIO_NORMAL;
const top: u64 = abi.FB_PRIO_TOP;
const default_budget: u64 = abi.FB_SCHED_DEFAULT_BUDGET;

/// Si un hilo no consigue la CPU en este tiempo, hay inanición.
const limit: u64 = abi.FB_TIMEBASE_HZ * 10;

inline fn me() u64 {
    return @import("hart.zig").id();
}

fn spawn(entry: thread.Entry, argument: u64, interrupts: thread.Interrupts) u64 {
    return thread.spawn(entry, argument, interrupts) orelse @panic("no se pudo crear el hilo");
}

fn waitDead(id: u64) void {
    const begin = timer.now();
    while (thread.isAlive(id)) {
        if (timer.now() - begin > limit) @panic("inanicion: el hilo no llego a terminar");
        thread.yield();
    }
}

fn restoreMain() void {
    thread.setParams(0, normal, default_budget);
}

var log: [8]u8 = undefined;
var log_length: usize = 0;

fn logWorker(tag: u64) callconv(.c) void {
    for (0..3) |_| {
        log[log_length] = @truncate(tag);
        log_length += 1;
        thread.yield();
    }
}

fn firstWorker(tag: u64) callconv(.c) void {
    log[log_length] = @truncate(tag);
    log_length += 1;
}

/// Dos hilos del nivel del principal; el promovido corre antes que el otro,
/// sea cual sea el orden natural del turno.
fn testPromoteGoesFirst() void {
    {
        const model = thread.lockModel();
        defer thread.unlockModel(model);
        expectEqual(abi.fb_sched_promote(me(), 99), abi.FB_SCHED_INVALID);
    }
    for ([_]usize{ 0, 1 }) |which| {
        log_length = 0;
        var ids: [2]u64 = undefined;
        {
            const saved = riscv.disableInterruptsSaving();
            defer riscv.restoreInterrupts(saved);
            ids[0] = spawn(firstWorker, 'a', .off);
            ids[1] = spawn(firstWorker, 'b', .off);
            const model = thread.lockModel();
            defer thread.unlockModel(model);
            expectEqual(abi.fb_sched_promote(me(), ids[which]), abi.FB_SCHED_OK);
        }
        waitDead(ids[0]);
        waitDead(ids[1]);
        {
            const model = thread.lockModel();
            defer thread.unlockModel(model);
            expectEqual(abi.fb_sched_promote(me(), ids[0]), abi.FB_SCHED_WRONG_STATE);
        }
        expectLog(if (which == 0) "ab" else "ba");
    }
    passed("el hilo adelantado es el siguiente de su nivel");
}

/// El atajo de la regla de la rodaja da exactamente lo mismo que la función
/// demostrada en SPARK, y el cuanto y la media se comportan como se demostró.
fn testSliceRule() void {
    const model = thread.lockModel();
    defer thread.unlockModel(model);
    const remainings = [_]u64{ 0, 1, 999, 10000, 10001, 99999, 1000000 };
    const quanta = [_]u64{ thread.base_quantum, 14000, 100000 };
    for (remainings) |remaining| {
        for (quanta) |quantum_value| {
            const fast = thread.sliceRule(remaining, 0, quantum_value, 0);
            const proven = abi.fb_quantum_slice(remaining, abi.fb_sched_budget(me(), 0), quantum_value, 0);
            if (fast != proven) @panic("el atajo de la rodaja no coincide con la regla demostrada");
        }
    }
    for (quanta) |quantum_value| {
        for ([_]u64{ 0, 7, 15 }) |cost| {
            if (thread.sliceRule(abi.fb_sched_remaining(me(), 0), 0, quantum_value, cost) != abi.fb_sched_slice(me(), 0, quantum_value, cost)) {
                @panic("el atajo de la rodaja no coincide con la regla demostrada");
            }
        }
    }
    expectEqual(abi.fb_quantum_for(0), thread.base_quantum);
    expectEqual(abi.fb_quantum_for(5000), 40000);
    expectEqual(abi.fb_quantum_for(1 << 40), 100000);
    expectEqual(abi.fb_quantum_update(0, 7), 0);
    expectEqual(abi.fb_quantum_update(8000, 8000), 8000);
    expectEqual(abi.fb_quantum_slice(500, 1000, thread.base_quantum, 1000), 2000);
    expectEqual(abi.fb_quantum_slice(5, 10, thread.base_quantum, 15), 5);
    expectEqual(abi.fb_quantum_slice(500, 100000, thread.base_quantum, 1000), 500);
    passed("la regla de la rodaja y el cuanto adaptable dan lo demostrado");
}

/// Justo después de un tick y con el presupuesto entero, la rodaja que se
/// concede no pasa del cuanto: el turno de su nivel rota a tiempo.
fn testQuantum() void {
    riscv.enableInterrupts();
    thread.setParams(0, normal, default_budget);
    const tick = timer.ticks();
    while (timer.ticks() == tick) {}
    riscv.disableInterrupts();
    thread.yield();
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    if (timer.armedAt() > timer.now() + thread.quantum()) @panic("la rodaja pasa del cuanto");
    passed("la rodaja no pasa del cuanto");
}

fn expectLog(expected: []const u8) void {
    if (log_length != expected.len) @panic("orden de prioridades incorrecto");
    for (expected, log[0..log_length]) |wanted, actual| {
        if (wanted != actual) @panic("orden de prioridades incorrecto");
    }
}

fn testGate() void {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    const model = thread.lockModel();
    defer thread.unlockModel(model);

    const invalid = abi.FB_SCHED_INVALID;
    const wrong = abi.FB_SCHED_WRONG_STATE;
    const h = me();

    expectEqual(abi.fb_sched_set_params(h, 99, 0, 1), invalid);
    expectEqual(abi.fb_sched_set_params(h, 0, 4, 1), invalid);
    expectEqual(abi.fb_sched_set_params(h, 0, 0, 0), invalid);
    expectEqual(abi.fb_sched_set_params(h, 0, 0, abi.FB_SCHED_MAX_BUDGET + 1), invalid);
    expectEqual(abi.fb_sched_set_params(h, 1, 0, 1), wrong);
    expectEqual(abi.fb_sched_hand_off(h, 0, 0, 1), invalid);
    expectEqual(abi.fb_sched_hand_off(h, 99, 0, 1), invalid);
    expectEqual(abi.fb_sched_hand_off(h, 1, 0, 1), wrong);
    expectEqual(abi.fb_sched_adopt(h, 0, 1), invalid);
    expectEqual(abi.fb_sched_adopt(h, 1, 0), invalid);
    expectEqual(abi.fb_sched_adopt(h, 99, 1), invalid);
    expectEqual(abi.fb_sched_adopt(h, 1, 99), invalid);
    expectEqual(abi.fb_sched_adopt(h, 1, 2), wrong);
    expectEqual(abi.fb_sched_adopt(h, 1, 1), wrong);
    expectEqual(abi.fb_sched_remaining(h, 99), abi.FB_SCHED_NONE);
    expectEqual(abi.fb_sched_context(h, 99), abi.FB_SCHED_NONE);
    expectEqual(abi.fb_sched_context(h, 0), 0);
    expectEqual(abi.fb_sched_running(h), thread.currentId());
    // Un hart que no existe: nada cambia en ningún modelo.
    const bad = abi.FB_MAX_HARTS;
    expectEqual(abi.fb_sched_create(bad), abi.FB_SCHED_NONE);
    expectEqual(abi.fb_sched_pick(bad, 0), abi.FB_SCHED_NONE);
    expectEqual(abi.fb_sched_charge(bad, 0), invalid);
    expectEqual(abi.fb_sched_block(bad, 1), invalid);
    expectEqual(abi.fb_sched_unblock(bad, 1), invalid);
    expectEqual(abi.fb_sched_promote(bad, 0), invalid);
    expectEqual(abi.fb_sched_exit(bad, 1), invalid);
    expectEqual(abi.fb_sched_set_params(bad, 0, 0, 1), invalid);
    expectEqual(abi.fb_sched_hand_off(bad, 1, 0, 0), invalid);
    expectEqual(abi.fb_sched_adopt(bad, 1, 2), invalid);
    expectEqual(abi.fb_sched_state(bad, 0), abi.FB_SCHED_NONE);
    expectEqual(abi.fb_sched_running(bad), abi.FB_SCHED_NONE);
    expectEqual(abi.fb_sched_should_yield(bad), 0);
    expectEqual(abi.fb_sched_alone(bad), 0);
    expectEqual(abi.fb_sched_slice(bad, 0, thread.base_quantum, 0), 0);
    expectEqual(abi.fb_sched_running(h), thread.currentId());
    passed("el planificador rechaza prioridades y presupuestos invalidos");
}

/// La prioridad alta va primero, y aun así la baja acaba ejecutándose: quien está
/// en medio, el hilo principal, solo puede retrasarla hasta gastar su presupuesto.
fn testStrictPriority() void {
    log_length = 0;
    const big: u64 = abi.FB_SCHED_MAX_BUDGET;
    const slow = spawn(logWorker, 'L', .off);
    thread.setParams(slow, low, big);
    const fast = spawn(logWorker, 'H', .off);
    thread.setParams(fast, top, big);
    thread.setParams(0, normal, 200000);

    thread.yield();
    expectLog("HHH");
    if (thread.isAlive(fast)) @panic("la prioridad alta no termino primero");

    waitDead(slow);
    expectLog("HHHLLL");
    restoreMain();
    passed("prioridad estricta, y la baja no se queda sin CPU");
}

var evader_stop: u64 = 0;

/// Nunca recibe un tick (interrupciones apagadas) y cede sin parar: un cobro por
/// ticks jamás le descontaría nada. El cobro por tiempo sí.
fn evader(_: u64) callconv(.c) void {
    const begin = timer.now();
    while (@atomicLoad(u64, &evader_stop, .seq_cst) == 0) {
        if (timer.now() - begin > limit) @panic("inanicion: un hilo esquivo su presupuesto");
        thread.yield();
    }
}

fn testBudgetCannotBeEvaded() void {
    const budget: u64 = 20000;
    @atomicStore(u64, &evader_stop, 0, .seq_cst);
    const id = spawn(evader, 0, .off);
    thread.setParams(id, top, budget);

    thread.yield();

    // Solo se llega aquí si el presupuesto del hilo prioritario se ha agotado.
    if (thread.cpuTime(id) < budget) @panic("el hilo cedio la CPU sin gastar su presupuesto");
    @atomicStore(u64, &evader_stop, 1, .seq_cst);
    waitDead(id);
    passed("ceder sin parar no esquiva el presupuesto");
}

var share_stop: u64 = 0;

fn shareWorker(_: u64) callconv(.c) void {
    const begin = timer.now();
    while (@atomicLoad(u64, &share_stop, .seq_cst) == 0) {
        if (timer.now() - begin > limit) @panic("inanicion: el hilo de minima prioridad no corrio");
    }
}

/// Dos hilos de máxima prioridad, 3 a 1. El principal, con la mínima, sigue vivo.
/// Sin -icount el reloj de QEMU lo marca el anfitrión, cuyo temporizador puede
/// retrasar cada corte un par de milisegundos: los presupuestos son largos para
/// que ese error no decida la prueba.
fn testBudgetShare() void {
    const needed: u64 = 2000000;
    @atomicStore(u64, &share_stop, 0, .seq_cst);
    const first = spawn(shareWorker, 0, .on);
    thread.setParams(first, top, 300000);
    const second = spawn(shareWorker, 0, .on);
    thread.setParams(second, top, 100000);
    thread.setParams(0, low, 10000);

    const early_before = timer.earlyFires();
    const begin = timer.now();
    riscv.enableInterrupts();
    while (thread.cpuTime(first) + thread.cpuTime(second) < needed) {
        if (timer.now() - begin > limit) @panic("los hilos no gastaron su presupuesto");
    }
    riscv.disableInterrupts();

    const a = thread.cpuTime(first);
    const b = thread.cpuTime(second);
    const early = timer.earlyFires() - early_before;
    @atomicStore(u64, &share_stop, 1, .seq_cst);
    restoreMain();
    waitDead(first);
    waitDead(second);

    uart.print("[ok] reparto de CPU, 3 a 1 pedido: ");
    uart.printDecimal(a);
    uart.print(" y ");
    uart.printDecimal(b);
    uart.print(" unidades\n");
    if (a < 2 * b or a > 4 * b) @panic("el reparto no respeta los presupuestos");
    if (early == 0) @panic("el timer no corto ningun presupuesto");
}

/// Un proceso de usuario no puede monopolizar la CPU aunque nunca entre al kernel.
fn testUserProcessCannotStarve() void {
    const id = process.spawn(.spin, 0) orelse @panic("no se pudo crear el proceso");
    thread.setParams(id, top, 20000);

    thread.yield();
    if (thread.cpuTime(id) == 0) @panic("el proceso no llego a ejecutarse");

    process.requestKill(id);
    waitDead(id);
    if (process.resultOf(id).kind != .killed) @panic("el proceso debia morir por orden");
    passed("un proceso de maxima prioridad no acapara la CPU");
}

var slice_ok = false;
var slice_peer: u64 = 0;
var slice_granted: u64 = 0;

/// Recibe la CPU por cesión directa y comprueba que el timer ya está armado
/// para cortarle al agotar su presupuesto, no en el próximo periodo.
fn sliceChecker(_: u64) callconv(.c) void {
    thread.block();
    const saved = riscv.disableInterruptsSaving();
    slice_ok = timer.armedAt() <= timer.now() + thread.sliceFor(thread.currentId());
    slice_granted = thread.grantedNow();
    riscv.restoreInterrupts(saved);
}

fn sliceGiver(_: u64) callconv(.c) void {
    thread.blockAndSwitchTo(slice_peer, false);
}

fn testHandOffLimitsSlice() void {
    slice_ok = false;
    const checker = spawn(sliceChecker, 0, .off);
    thread.setParams(checker, top, default_budget);
    while (thread.state(checker) != abi.FB_THREAD_BLOCKED) thread.yield();
    // El presupuesto pequeño, ya bloqueado: así no se gasta antes de la cesión.
    thread.setParams(checker, top, 1000);
    slice_peer = checker;
    slice_granted = 0;
    const left = thread.remainingOf(checker);

    const direct_before = thread.directSwitches();
    const giver = spawn(sliceGiver, 0, .off);
    waitDead(checker);
    if (thread.directSwitches() == direct_before) @panic("no hubo cesion directa");
    if (!slice_ok) @panic("la cesion directa no limito la rodaja al presupuesto");
    // Sin interrupciones el checker no pudo recibir otra rodaja: la que ve es
    // la de la cesión, y debe ser justo lo que le quedaba a su contexto.
    if (slice_granted != left) @panic("la cesion directa no concedio lo que le quedaba al contexto");
    thread.unblock(giver);
    waitDead(giver);
    passed("la cesion directa corta la rodaja al agotar el presupuesto");
}

fn testBillingConsistent() void {
    if (!thread.billingConsistent()) @panic("hay tiempo cobrado dos veces o sin cobrar");
    passed("cada unidad de tiempo se cobra exactamente una vez");
}

const server_grants = [_]process.Grant{endpoint(0, 0, abi.FB_RIGHT_RECV)};
const client_grants = [_]process.Grant{endpoint(0, 0, abi.FB_RIGHT_SEND)};

var inversion_client: u64 = 0;
var inversion_seen = false;

/// Prioridad intermedia: si llega a correr mientras el cliente espera, el
/// servidor de prioridad baja lo ha retrasado. Eso es inversión de prioridad.
fn inversionWitness(_: u64) callconv(.c) void {
    inversion_seen = thread.isAlive(inversion_client);
}

/// Cliente de prioridad máxima, servidor de prioridad mínima y un hilo intermedio
/// listo. Con la donación el servidor trabaja con el contexto del cliente: el
/// intermedio no se cuela y el servidor no gasta nada de su propio presupuesto.
fn testCallDonatesContext() void {
    const server_budget: u64 = 50000;
    const server = start(.call_server, 2, &server_grants);
    waitBlocked(server);
    thread.setParams(server, low, server_budget);

    const declined_before = thread.declinedSwitches();
    const donations_before = thread.donations();
    inversion_seen = false;
    const client = start(.call_client, 1, &client_grants);
    // Con margen: si QEMU va lento frente al reloj real, un presupuesto justo
    // se agotaría a mitad de la llamada y el testigo correría con razón.
    thread.setParams(client, top, 10 * default_budget);
    inversion_client = client;
    const witness = spawn(inversionWitness, 0, .off);
    thread.setParams(witness, abi.FB_PRIO_HIGH, default_budget);

    expectExit(client, .call_client, 0);
    waitDead(witness);
    waitBlocked(server);

    if (inversion_seen) @panic("inversion de prioridad: el servidor no recibio el contexto del cliente");
    if (thread.declinedSwitches() != declined_before) @panic("una llamada con donacion no se cedio directamente");
    if (thread.donations() == donations_before) @panic("no hubo ninguna donacion");
    if (thread.contextOf(server) != server) @panic("el servidor no devolvio el contexto");
    if (thread.remainingOf(server) != server_budget) @panic("el servidor gasto su propio presupuesto en llamadas ajenas");

    process.requestKill(server);
    waitDead(server);
    passed("una llamada presta el contexto: sin inversion de prioridad");
}

const forwarder_grants = [_]process.Grant{ endpoint(0, 0, abi.FB_RIGHT_RECV), endpoint(1, 1, abi.FB_RIGHT_SEND) };
const end_server_grants = [_]process.Grant{endpoint(0, 1, abi.FB_RIGHT_RECV)};

/// Cadena: cliente de prioridad máxima, reenviador y servidor final de
/// prioridad mínima, y un hilo intermedio listo. El préstamo llega al final de
/// la cadena: el intermedio no se cuela y ninguno gasta su propio presupuesto.
fn testChainedCallDonates() void {
    const own_budget: u64 = 50000;
    const server = start(.call_server, 1, &end_server_grants);
    waitBlocked(server);
    thread.setParams(server, low, own_budget);
    const forwarder = start(.call_forwarder, 0, &forwarder_grants);
    waitBlocked(forwarder);
    thread.setParams(forwarder, low, own_budget);

    const donations_before = thread.donations();
    inversion_seen = false;
    var client: u64 = undefined;
    var witness: u64 = undefined;
    {
        const saved = riscv.disableInterruptsSaving();
        defer riscv.restoreInterrupts(saved);
        client = start(.call_client, 1, &client_grants);
        thread.setParams(client, top, 10 * default_budget);
        inversion_client = client;
        witness = spawn(inversionWitness, 0, .off);
        thread.setParams(witness, abi.FB_PRIO_HIGH, default_budget);
    }
    expectExit(client, .call_client, 0);
    waitDead(witness);
    expectExit(forwarder, .call_forwarder, 0);
    expectExit(server, .call_server, 0);

    if (inversion_seen) @panic("inversion de prioridad: el prestamo no llego al final de la cadena");
    // Cada vuelta presta dos veces: al reenviador y, desde él, al servidor final.
    if (thread.donations() - donations_before < 2 * 65) @panic("la cadena no presto el contexto en cada eslabon");
    passed("una cadena de llamadas lleva el prestamo hasta el final");
}

const chain_defer_grants = [_]process.Grant{ endpoint(0, 1, abi.FB_RIGHT_RECV), endpoint(1, 2, abi.FB_RIGHT_RECV) };

/// El servidor final aplaza la respuesta y conserva el contexto del cliente a
/// dos eslabones. Si muere el reenviador, de en medio, nadie se queda con un
/// contexto ajeno.
fn testChainMiddleDies() void {
    const server = start(.defer_wait, 0, &chain_defer_grants);
    waitBlocked(server);
    const forwarder = start(.call_forwarder, 0, &forwarder_grants);
    waitBlocked(forwarder);
    const client = start(.call_client, 1, &client_grants);
    waitBlocked(client);
    waitBlocked(forwarder);
    waitBlocked(server);
    if (thread.contextOf(server) != client) @panic("el servidor final no recibio el contexto del cliente");
    if (thread.contextOf(forwarder) != client) @panic("el reenviador perdio el contexto del cliente");

    process.requestKill(forwarder);
    waitDead(forwarder);
    if (thread.contextOf(server) != server) @panic("el servidor final siguio con un contexto ajeno");
    expectExit(client, .call_client, 1);
    {
        const saved = riscv.disableInterruptsSaving();
        defer riscv.restoreInterrupts(saved);
        _ = ipc.signal(2);
    }
    expectExit(server, .defer_wait, 1);
    passed("si muere un eslabon de en medio, la cadena devuelve los contextos");
}

/// La llamada llega antes que el servidor: al recibirla, el servidor también
/// pasa a usar el contexto del cliente. Al final contesta con reply y vuelve a
/// su prioridad baja: el cliente despertado debe expropiarle en ese momento.
fn testQueuedCallDonates() void {
    const client = start(.call_client, 1, &client_grants);
    // Con margen: con el anfitrión saturado, un presupuesto justo se agota y
    // el cliente despertado ya no tendría con qué expropiar.
    thread.setParams(client, top, 10 * default_budget);
    waitBlocked(client);

    const donations_before = thread.donations();
    const accepted_before = thread.acceptedCalls();
    const wakes_before = thread.wakePreemptions();
    const server = start(.call_server, 1, &server_grants);
    thread.setParams(server, low, default_budget);
    expectExit(client, .call_client, 0);
    expectExit(server, .call_server, 0);

    if (thread.donations() == donations_before) @panic("no hubo ninguna donacion");
    if (thread.acceptedCalls() == accepted_before) @panic("la llamada en cola no presto el contexto");
    if (thread.wakePreemptions() == wakes_before) @panic("el cliente despertado no expropio al servidor");
    passed("una llamada en cola tambien presta el contexto, y responder lo devuelve");
}

/// Hilo de prioridad intermedia que gira hasta que el cliente termina o pasa el
/// tiempo límite. Lo que gire con el cliente vivo es inversión de prioridad.
var spin_client: u64 = 0;
var inversion_units: u64 = 0;
const spin_limit: u64 = 20000;

/// Cómo estaba el cliente cuando el intermedio empezó a girar: si falla la
/// prueba, dice si fue por presupuesto agotado o por otra cosa.
var spin_seen_state: u64 = 0;
var spin_seen_remaining: u64 = 0;
var spin_seen_context: u64 = 0;

fn inversionSpinner(_: u64) callconv(.c) void {
    spin_seen_state = thread.state(spin_client);
    spin_seen_remaining = thread.remainingOf(spin_client);
    spin_seen_context = thread.contextOf(spin_client);
    const begin = timer.now();
    var now = begin;
    while (thread.isAlive(spin_client) and now - begin < spin_limit) now = timer.now();
    inversion_units = now - begin;
}

const defer_grants = [_]process.Grant{ endpoint(0, 0, abi.FB_RIGHT_RECV), endpoint(1, 1, abi.FB_RIGHT_RECV) };
const go_grants = [_]process.Grant{endpoint(0, 1, abi.FB_RIGHT_SEND)};

/// Servidor de prioridad mínima que aplaza la llamada de un cliente de
/// prioridad máxima. Cuando le dan permiso, un hilo intermedio se pone listo a
/// la vez. Devuelve cuánto tiempo giró ese hilo con el cliente esperando.
pub fn deferredInversion() u64 {
    const server = start(.defer_wait, 0, &defer_grants);
    waitBlocked(server);
    thread.setParams(server, low, default_budget);

    const client = start(.call_once, 1, &client_grants);
    // Con margen: con el anfitrión saturado, un presupuesto justo se agotaría
    // mientras el servidor trabaja y el intermedio correría con razón.
    thread.setParams(client, top, 10 * default_budget);
    waitBlocked(client);
    waitBlocked(server);
    if (thread.contextOf(server) != client) @panic("aplazar no conservo el contexto del cliente");

    spin_client = client;
    inversion_units = 0;
    var spinner: u64 = undefined;
    {
        const saved = riscv.disableInterruptsSaving();
        defer riscv.restoreInterrupts(saved);
        const go = start(.go_sender, 0, &go_grants);
        thread.setParams(go, top, default_budget);
        spinner = spawn(inversionSpinner, 0, .off);
        thread.setParams(spinner, abi.FB_PRIO_HIGH, default_budget);
    }
    expectExit(client, .call_once, 0);
    expectExit(server, .defer_wait, 0);
    waitDead(spinner);
    return inversion_units;
}

/// El intermedio no puede colarse: el trabajo aplazado sigue con la prioridad
/// del cliente.
fn testDeferredKeepsPriority() void {
    const units = deferredInversion();
    if (units > spin_limit / 10) {
        uart.print("giro: ");
        uart.printDecimal(units);
        uart.print(", cliente al empezar: estado ");
        uart.printDecimal(spin_seen_state);
        uart.print(", le quedaba ");
        uart.printDecimal(spin_seen_remaining);
        uart.print(", contexto ");
        uart.printDecimal(spin_seen_context);
        uart.print(", exceso maximo ");
        uart.printDecimal(thread.maxOverrun());
        uart.print("\n");
        @panic("inversion de prioridad: lo aplazado perdio la prioridad del cliente");
    }
    passed("una respuesta aplazada conserva la prioridad del cliente");
}

var lower_client: u64 = 0;
var lower_seen = false;

/// Prioridad normal: si corre con el cliente aún esperando, el servidor cedió
/// la CPU al bajar a la prioridad del cliente.
fn lowerWitness(_: u64) callconv(.c) void {
    lower_seen = thread.state(lower_client) == abi.FB_THREAD_BLOCKED;
}

/// Un servidor de prioridad máxima acepta la llamada en cola de un cliente de
/// prioridad mínima: pasa a esa prioridad y debe ceder la CPU a quien esté
/// listo por encima, antes de contestar.
fn testAcceptLowerYields() void {
    const client = start(.call_client, 1, &client_grants);
    thread.setParams(client, low, default_budget);
    waitBlocked(client);

    lower_client = client;
    lower_seen = false;
    var server: u64 = undefined;
    var witness: u64 = undefined;
    {
        const saved = riscv.disableInterruptsSaving();
        defer riscv.restoreInterrupts(saved);
        server = start(.call_server, 1, &server_grants);
        thread.setParams(server, top, default_budget);
        witness = spawn(lowerWitness, 0, .off);
    }
    expectExit(client, .call_client, 0);
    expectExit(server, .call_server, 0);
    waitDead(witness);
    if (!lower_seen) @panic("al aceptar una llamada menos urgente el servidor no cedio la CPU");
    passed("aceptar una llamada menos urgente cede la CPU");
}

var low_ran = false;

fn lowWaiter(_: u64) callconv(.c) void {
    thread.block();
    low_ran = true;
}

fn plainGiver(_: u64) callconv(.c) void {
    thread.blockAndSwitchTo(slice_peer, false);
}

/// Sin donación, ceder a un hilo de prioridad baja con otro de más prioridad
/// listo se rechaza: decide el planificador.
fn testHandOffDeclined() void {
    // El principal debe seguir elegible durante toda la prueba: con el
    // presupuesto agotado, el de prioridad baja sería con razón el primero.
    thread.setParams(0, normal, 10 * default_budget);
    defer restoreMain();
    low_ran = false;
    const waiter = spawn(lowWaiter, 0, .off);
    while (thread.state(waiter) != abi.FB_THREAD_BLOCKED) thread.yield();
    thread.setParams(waiter, low, default_budget);
    slice_peer = waiter;

    const declined_before = thread.declinedSwitches();
    const giver = spawn(plainGiver, 0, .off);
    while (thread.state(giver) != abi.FB_THREAD_BLOCKED) thread.yield();
    if (thread.declinedSwitches() == declined_before) @panic("la cesion directa se salto una prioridad");
    if (low_ran) @panic("el hilo de prioridad baja adelanto al principal");

    waitDead(waiter);
    thread.unblock(giver);
    waitDead(giver);
    passed("ceder sin donar no se salta prioridades");
}

var borrow_peer: u64 = 0;
var borrow_seen: u64 = 0;

/// Recibe primero un préstamo y se bloquea con él; luego lo despierta otro que
/// no puede prestarle nada más urgente.
fn borrowKeeper(_: u64) callconv(.c) void {
    thread.block();
    thread.block();
    borrow_seen = thread.contextOf(thread.currentId());
}

fn borrowGiver(_: u64) callconv(.c) void {
    thread.blockAndSwitchTo(borrow_peer, true);
}

/// Pedir el préstamo no basta: si el que despierta ya corre con un contexto
/// tan urgente como el del que cede, no lo cambia, y no se cuenta préstamo.
fn testRefusedDonationNotCounted() void {
    thread.setParams(0, normal, 10 * default_budget);
    defer restoreMain();
    const keeper = spawn(borrowKeeper, 0, .off);
    while (thread.state(keeper) != abi.FB_THREAD_BLOCKED) thread.yield();
    borrow_peer = keeper;
    borrow_seen = 0;

    const first_before = thread.donations();
    const first = spawn(borrowGiver, 0, .off);
    while (thread.state(first) != abi.FB_THREAD_BLOCKED or thread.state(keeper) != abi.FB_THREAD_BLOCKED) thread.yield();
    if (thread.donations() - first_before != 1) @panic("el primer prestamo no se conto una vez");
    if (thread.contextOf(keeper) != first) @panic("el primer prestamo no llego");

    const second_before = thread.donations();
    const second = spawn(borrowGiver, 0, .off);
    waitDead(keeper);
    if (borrow_seen != first) @panic("un prestamo igual de urgente sustituyo al que habia");
    if (thread.donations() != second_before) @panic("se conto un prestamo que no hubo");

    thread.unblock(first);
    thread.unblock(second);
    waitDead(first);
    waitDead(second);
    passed("un prestamo que no se aplica no se cuenta");
}

const AccountMode = enum(u64) { reply, die, slice };

var account_client: u64 = 0;
var account_slice_ok = false;
const account_work: u64 = 3000;

fn accountClient(_: u64) callconv(.c) void {
    thread.block();
}

/// Toma el contexto del cliente como si recibiera su llamada y trabaja con las
/// interrupciones apagadas: sin ticks, todo el tiempo se cobra en los cambios.
fn accountServer(raw_mode: u64) callconv(.c) void {
    const mode: AccountMode = @enumFromInt(raw_mode);
    thread.acceptCall(account_client);
    if (mode == .slice) {
        const saved = riscv.disableInterruptsSaving();
        account_slice_ok = timer.armedAt() <= timer.now() + thread.sliceFor(thread.currentId());
        riscv.restoreInterrupts(saved);
        thread.unblock(account_client);
        return;
    }
    const begin = timer.now();
    while (timer.now() - begin < account_work) {}
    if (mode == .reply) thread.unblock(account_client);
}

/// El trabajo hecho con un contexto prestado se cobra a ese contexto, también
/// cuando el servidor contesta o muere, y la rodaja se ajusta al prestado.
fn testBorrowedTimeIsBilled() void {
    // El principal no debe agotar su presupuesto mientras espera: sin nadie
    // elegible se rellenarían todos, también el del cliente que se comprueba.
    thread.setParams(0, normal, 100 * default_budget);
    defer restoreMain();
    for ([_]AccountMode{ .reply, .die, .slice }) |mode| {
        const budget: u64 = if (mode == .slice) 1000 else 1000000;
        account_slice_ok = false;
        const client = spawn(accountClient, 0, .off);
        while (thread.state(client) != abi.FB_THREAD_BLOCKED) thread.yield();
        thread.setParams(client, normal, budget);
        account_client = client;

        const accepted_before = thread.acceptedCalls();
        const server = spawn(accountServer, @intFromEnum(mode), .off);
        waitDead(server);
        if (thread.acceptedCalls() == accepted_before) @panic("el servidor no tomo el contexto");

        switch (mode) {
            .reply, .die => if (thread.remainingOf(client) > budget - account_work)
                @panic("el trabajo con un contexto prestado no se cobro a su dueno"),
            .slice => if (!account_slice_ok) @panic("tomar un contexto no ajusto la rodaja"),
        }
        if (thread.contextOf(client) != client) @panic("el contexto no volvio a su dueno");
        if (mode == .die) thread.unblock(client);
        waitDead(client);
    }
    passed("el tiempo con un contexto prestado se cobra a su dueno");
}

/// Quien se baja la prioridad cede la CPU en ese momento, no en el próximo tick.
fn testLoweringYields() void {
    // El principal debe seguir elegible: con el presupuesto agotado no habría
    // nadie por encima a quien ceder.
    thread.setParams(0, normal, 10 * default_budget);
    defer restoreMain();
    const wakes_before = thread.wakePreemptions();
    const id = start(.sched_lower, low, &.{schedGrant(2, abi.FB_RIGHT_SEND)});
    // Sin la cesión, el proceso ya bajado giraría hasta el tick sin pedir nada.
    const begin = timer.now();
    while (thread.wakePreemptions() == wakes_before) {
        if (timer.now() - begin > limit) @panic("bajarse la prioridad no cedio la CPU");
        thread.yield();
    }
    process.requestKill(id);
    waitDead(id);
    passed("bajarse la prioridad cede la CPU al momento");
}

fn schedGrant(max_level: u64, rights: u64) process.Grant {
    return .{ .slot = 0, .kind = abi.FB_CAP_SCHED, .object = max_level, .rights = rights };
}

/// Cambiar la propia prioridad exige autoridad, y nunca por encima de la que da.
fn testSchedCapability() void {
    expectExit(start(.sched_set, 1, &.{}), .sched_set, abi.FB_ERR_CAP);
    expectExit(start(.sched_set, 1, &.{schedGrant(2, abi.FB_RIGHT_RECV)}), .sched_set, abi.FB_ERR_CAP);
    expectExit(start(.sched_set, 3, &.{schedGrant(1, abi.FB_RIGHT_SEND)}), .sched_set, abi.FB_ERR_INVALID);
    expectExit(start(.sched_set, 1, &.{selftest_ipc.console(0)}), .sched_set, abi.FB_ERR_CAP);
    const device: process.Grant = .{ .slot = 0, .kind = abi.FB_CAP_DEVICE, .object = 0, .rights = abi.FB_RIGHT_SEND };
    expectExit(start(.sched_set, 0, &.{device}), .sched_set, abi.FB_ERR_CAP);

    const id = start(.sched_set, 2, &.{schedGrant(2, abi.FB_RIGHT_SEND)});
    const begin = timer.now();
    while (thread.remainingOf(id) > 20000) {
        if (!thread.isAlive(id)) @panic("el proceso no pudo fijar su prioridad");
        if (timer.now() - begin > limit) @panic("el proceso no fijo su presupuesto");
        thread.yield();
    }
    process.requestKill(id);
    waitDead(id);
    passed("fijar prioridad y presupuesto exige una capability y respeta su tope");
}

pub fn run() void {
    testGate();
    testStrictPriority();
    testBudgetCannotBeEvaded();
    testBudgetShare();
    testUserProcessCannotStarve();
    testCallDonatesContext();
    testQueuedCallDonates();
    testChainedCallDonates();
    testChainMiddleDies();
    testDeferredKeepsPriority();
    testPromoteGoesFirst();
    testQuantum();
    testSliceRule();
    testAcceptLowerYields();
    testHandOffDeclined();
    testSchedCapability();
    testBorrowedTimeIsBilled();
    testLoweringYields();
    testHandOffLimitsSlice();
    testRefusedDonationNotCounted();
    testBillingConsistent();
}
