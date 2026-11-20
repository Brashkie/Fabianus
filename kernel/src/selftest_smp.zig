//! Autopruebas de los harts secundarios, del cerrojo y de la planificación por
//! hart.

const abi = @import("abi.zig").c;
const build_options = @import("build_options");
const hart = @import("hart.zig");
const ipi = @import("ipi.zig");
const ipc = @import("ipc.zig");
const kernel_lock = @import("kernel_lock.zig");
const sleep = @import("sleep.zig");
const riscv = @import("riscv.zig");
const trap = @import("trap.zig");
const process = @import("process.zig");
const selftest_ipc = @import("selftest_ipc.zig");
const spinlock = @import("spinlock.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");
const uart = @import("uart.zig");

const passed = selftest_ipc.passed;

/// Vueltas de cada hilo en la prueba de exclusión.
const rounds: u64 = 20000;

var test_lock = spinlock.SpinLock{};
var shared: u64 = 0;
var inside: u64 = 0;
var overlap = false;
var wrong_hart = false;

/// Dentro del cerrojo, leer y escribir por separado: sin exclusión mutua, dos
/// harts leerían el mismo valor y se perdería un incremento. Además se
/// comprueba que nunca hay dos dentro a la vez y que corre en su hart.
fn contend(expected_hart: u64) callconv(.c) void {
    if (hart.id() != expected_hart) wrong_hart = true;
    var round: u64 = 0;
    while (round < rounds) : (round += 1) {
        test_lock.acquire();
        if (@atomicRmw(u64, &inside, .Add, 1, .monotonic) != 0) overlap = true;
        const value = @as(*volatile u64, &shared).*;
        var pause: u64 = 0;
        while (pause < 8) : (pause += 1) asm volatile ("" ::: "memory");
        @as(*volatile u64, &shared).* = value + 1;
        _ = @atomicRmw(u64, &inside, .Sub, 1, .monotonic);
        test_lock.release();
    }
}

fn spawnOrPanic(target: u64, entry: thread.Entry, argument: u64) u64 {
    return thread.spawnKernelOn(target, entry, argument, .off) orelse @panic("no se pudo crear el hilo");
}

fn waitAll(ids: []const u64) void {
    const limit = timer.now() + 20 * abi.FB_TIMEBASE_HZ;
    for (ids) |id| {
        while (thread.isAlive(id)) {
            if (timer.now() > limit) @panic("un hilo de otro hart no termino");
            thread.yield();
        }
    }
}

fn testHartsOnline(harts: u64) void {
    if (harts != build_options.harts) {
        uart.print("harts en linea: ");
        uart.printDecimal(harts);
        uart.print("\n");
        @panic("no arrancaron todos los harts");
    }
    uart.print("[ok] arrancan los ");
    uart.printDecimal(harts);
    uart.print(" harts\n");
}

/// Un hilo en cada hart compite por el cerrojo.
fn testMutualExclusion(harts: u64) void {
    shared = 0;
    overlap = false;
    wrong_hart = false;
    var ids: [hart.max]u64 = undefined;
    for (0..harts) |h| ids[h] = spawnOrPanic(h, contend, h);
    waitAll(ids[0..harts]);
    if (wrong_hart) @panic("un hilo corrio en un hart que no era el suyo");
    if (overlap) @panic("dos harts dentro del cerrojo a la vez");
    if (shared != harts * rounds) {
        uart.print("incrementos: ");
        uart.printDecimal(shared);
        uart.print(" de ");
        uart.printDecimal(harts * rounds);
        uart.print("\n");
        @panic("el cerrojo perdio incrementos");
    }
    passed("el cerrojo da exclusion mutua entre harts, un hilo por hart");
}

var flags = [_]u64{0} ** hart.max;

/// Cada hilo marca su bandera y espera a que todos lo hayan hecho. Sin
/// interrupciones, solo terminan si corren a la vez en harts distintos.
fn meetAll(index: u64) callconv(.c) void {
    @atomicStore(u64, &flags[index], 1, .release);
    const limit = timer.now() + 10 * abi.FB_TIMEBASE_HZ;
    for (1..meet_count + 1) |other| {
        while (@atomicLoad(u64, &flags[other], .acquire) == 0) {
            if (timer.now() > limit) return;
        }
    }
    @atomicStore(u64, &met[index], 1, .release);
}

var met = [_]u64{0} ** hart.max;
var meet_count: u64 = 0;

fn testParallel(harts: u64) void {
    if (harts < 2) {
        passed("con un solo hart no hay paralelismo que probar");
        return;
    }
    meet_count = harts - 1;
    flags = [_]u64{0} ** hart.max;
    met = [_]u64{0} ** hart.max;
    var ids: [hart.max]u64 = undefined;
    for (1..harts) |h| ids[h] = spawnOrPanic(h, meetAll, h);
    waitAll(ids[1..harts]);
    for (1..harts) |h| {
        if (met[h] == 0) @panic("los hilos de distintos harts no corrieron a la vez");
    }
    passed("hilos de harts distintos corren a la vez");
}

fn waitExit(id: u64, code: u64) void {
    waitAll(&.{id});
    const result = process.resultOf(id);
    if (result.kind != .exited or result.value != code) @panic("un proceso de otro hart termino mal");
}

/// Un proceso corre en el último hart y termina bien.
fn testProcessOnOtherHart(harts: u64) void {
    const id = process.spawnWithOn(harts - 1, .hello, 0, &process.console_grant) orelse @panic("no se pudo crear el proceso");
    if (thread.homeOf(id) != harts - 1) @panic("el proceso no quedo en su hart");
    waitExit(id, 7);
    passed("un proceso corre en otro hart");
}

/// El programa `registers` pone tp = 0x5a04 antes de una llamada al sistema.
/// En el último hart, la entrada del trap tiene que recuperar su número de
/// hart y no usar el tp del usuario (0x5a04 apuntaría al hart 0).
fn testUserTp(harts: u64) void {
    const id = process.spawnWithOn(harts - 1, .registers, 0, &.{}) orelse @panic("no se pudo crear el proceso");
    waitExit(id, 0);
    passed("el kernel no se fia del tp del usuario");
}

const send: u64 = abi.FB_RIGHT_SEND;
const recv: u64 = abi.FB_RIGHT_RECV;

/// 65 llamadas (64 y la de parada) entre un cliente y un servidor en los
/// harts indicados. Devuelve cuánto tardaron, en unidades del reloj.
fn callRound(server_hart: u64, client_hart: u64) u64 {
    const begin = timer.now();
    const server = process.spawnWithOn(server_hart, .call_server, 1, &.{selftest_ipc.endpoint(0, 0, recv)}) orelse @panic("no se pudo crear el proceso");
    const client = process.spawnWithOn(client_hart, .call_client, 1, &.{selftest_ipc.endpoint(0, 0, send)}) orelse @panic("no se pudo crear el proceso");
    waitExit(client, 0);
    waitExit(server, 0);
    return timer.now() - begin;
}

/// Cliente y servidor en harts distintos: las llamadas funcionan, sin cesión
/// directa ni préstamo. Se compara con el mismo par en un solo hart.
fn testCrossHartCall(harts: u64) void {
    const same = callRound(0, 0);
    const received_before = ipi.received(harts - 1);
    const switches_before = thread.notifiedSwitches();
    const cross = callRound(0, harts - 1);
    // Con varios harts, despertar al cliente del otro hart pasa por un aviso,
    // y el aviso pone a correr al despertado sin esperar al tick.
    if (harts > 1 and ipi.received(harts - 1) == received_before) @panic("las llamadas entre harts no usaron avisos");
    if (harts > 1 and thread.notifiedSwitches() == switches_before) @panic("ningun aviso puso a correr al despertado");
    uart.print("[ok] llamadas y respuestas entre procesos de harts distintos (65 llamadas: ");
    uart.printDecimal(cross / 10);
    uart.print(" us entre harts, ");
    uart.printDecimal(same / 10);
    uart.print(" us en el mismo)\n");
}

/// Entradas de cada hart secundario en la prueba de equidad.
const fair_rounds: u64 = 16;
var fair_done: u64 = 0;

fn enterKernelOften(_: u64) callconv(.c) void {
    for (0..fair_rounds) |_| {
        const saved = riscv.disableInterruptsSaving();
        riscv.restoreInterrupts(saved);
    }
    _ = @atomicRmw(u64, &fair_done, .Add, 1, .acq_rel);
}

/// El hart 0 tiene el cerrojo del kernel casi todo el tiempo y lo suelta solo
/// un instante entre vuelta y vuelta. Los demás también tienen que poder
/// entrar. Con un cerrojo sin turno, el hart 0 lo vuelve a ganar siempre: con
/// QEMU en -icount, que reparte el tiempo entre harts por turnos, un hart se
/// quedaba fuera. Con tiques, cada uno entra a su turno.
fn testLockFairness(harts: u64) void {
    if (harts < 2) {
        passed("con un solo hart no hay con quien compartir el cerrojo");
        return;
    }
    @atomicStore(u64, &fair_done, 0, .release);
    var ids: [hart.max]u64 = undefined;
    for (1..harts) |h| ids[h] = spawnOrPanic(h, enterKernelOften, 0);
    const limit = timer.now() + 10 * abi.FB_TIMEBASE_HZ;
    while (@atomicLoad(u64, &fair_done, .acquire) < harts - 1) {
        if (timer.now() > limit) @panic("un hart no consiguio el cerrojo del kernel: inanicion");
        const saved = riscv.disableInterruptsSaving();
        var work: u64 = 0;
        while (work < 1000) : (work += 1) asm volatile ("" ::: "memory");
        riscv.restoreInterrupts(saved);
    }
    waitAll(ids[1..harts]);
    passed("con un hart entrando sin parar, los demas tambien entran al kernel");
}

/// El PMP solo deja al supervisor las palabras msip del CLINT. La palabra
/// siguiente está en la misma página mapeada, así que el fallo es del PMP.
fn testClintLimited() void {
    const beyond: *volatile u32 = @ptrFromInt(abi.FB_CLINT_BASE + abi.FB_CLINT_MSIP_SIZE);
    trap.expectException(trap.cause_store_access_fault);
    beyond.* = 0;
    if (!trap.expectedExceptionSeen()) @panic("el supervisor pudo escribir en el CLINT fuera de msip");
    passed("el supervisor solo puede tocar las palabras msip del CLINT");
}

/// Matar a un proceso que gira en otro hart: el aviso lo saca de modo usuario
/// sin esperar al tick de su hart.
fn testRemoteKill(harts: u64) void {
    if (harts < 2) {
        passed("con un solo hart no hay a quien avisar para matar");
        return;
    }
    const target = harts - 1;
    const id = process.spawnWithOn(target, .spin, 0, &.{}) orelse @panic("no se pudo crear el proceso");
    // Que llegue a girar en modo usuario.
    const settle = timer.now() + 2 * abi.FB_TIMEBASE_HZ / 1000;
    while (timer.now() < settle) thread.yield();

    const received_before = ipi.received(target);
    const sent_before = ipi.sent();
    const begin = timer.now();
    process.requestKill(id);
    if (ipi.sent() == sent_before) @panic("matar en otro hart no envio aviso");
    waitAll(&.{id});
    const took = timer.now() - begin;
    if (process.resultOf(id).kind != .killed) @panic("el proceso de otro hart no murio matado");
    // Con el anfitrión cargado, el tick del otro hart puede matarlo antes de
    // que llegue el aviso; el aviso tiene que llegar igualmente.
    const limit = timer.now() + abi.FB_TIMEBASE_HZ;
    while (ipi.received(target) == received_before) {
        if (timer.now() > limit) @panic("el aviso para matar no llego a su hart");
        thread.yield();
    }
    uart.print("[ok] matar en otro hart avisa a ese hart (");
    uart.printDecimal(took / 10);
    uart.print(" us)\n");
}

/// Con el cerrojo del kernel tomado, un aviso solo se anota: el destino no
/// debe despertar para girar en el cerrojo. Sale en cuanto se suelta.
fn testIpiAfterUnlock(harts: u64) void {
    if (harts < 2) {
        passed("con un solo hart no hay avisos que aplazar");
        return;
    }
    const target = harts - 1;
    const received_before = ipi.received(target);
    const saved = riscv.disableInterruptsSaving();
    const sent_before = ipi.sent();
    ipi.send(target);
    const sent_inside = ipi.sent();
    const pending = ipi.pendingHere();
    riscv.restoreInterrupts(saved);
    const sent_after = ipi.sent();
    if (sent_inside != sent_before or !pending) @panic("el aviso salio con el cerrojo tomado");
    if (sent_after == sent_before or ipi.pendingHere()) @panic("el aviso anotado no salio al soltar el cerrojo");
    const limit = timer.now() + abi.FB_TIMEBASE_HZ;
    while (ipi.received(target) == received_before) {
        if (timer.now() > limit) @panic("el aviso aplazado no llego a su hart");
        thread.yield();
    }

    // Dos avisos anotados a harts distintos salen los dos.
    if (harts >= 3) {
        const other = harts - 2;
        const before = [2]u64{ ipi.received(target), ipi.received(other) };
        const held = riscv.disableInterruptsSaving();
        ipi.send(target);
        ipi.send(other);
        riscv.restoreInterrupts(held);
        const deadline = timer.now() + abi.FB_TIMEBASE_HZ;
        while (ipi.received(target) == before[0] or ipi.received(other) == before[1]) {
            if (timer.now() > deadline) @panic("de dos avisos anotados no salieron los dos");
            thread.yield();
        }
    }

    // Sin el cerrojo, sale en el acto.
    const enabled = riscv.readCsr("sstatus") & (1 << 1);
    riscv.disableInterrupts();
    const sent_free = ipi.sent();
    ipi.send(target);
    const sent_now = ipi.sent();
    const left = ipi.pendingHere();
    riscv.setCsr("sstatus", enabled);
    if (sent_now == sent_free or left) @panic("un aviso sin el cerrojo se quedo anotado");
    passed("un aviso con el cerrojo tomado sale al soltarlo, y sin el, en el acto");
}

/// Un hart sin trabajo duerme sin tick: en 100 ms no entra al kernel por su
/// timer más que un par de veces (con tick serían unas 10, y con rodajas de
/// 1 ms del hilo en reposo, unas 100).
fn testIdleSleeps(harts: u64) void {
    if (harts < 2) {
        passed("con un solo hart no hay harts en reposo");
        return;
    }
    const idle = harts - 1;
    const before = timer.interruptsOf(idle);
    const end = timer.now() + abi.FB_TIMEBASE_HZ / 10;
    while (timer.now() < end) thread.yield();
    const taken = timer.interruptsOf(idle) - before;
    if (taken > 2) {
        uart.print("interrupciones de timer en reposo: ");
        uart.printDecimal(taken);
        uart.print("\n");
        @panic("un hart sin trabajo no duerme sin tick");
    }
    passed("un hart sin trabajo duerme sin tick hasta que le avisan");
}

var turn_counts = [_]u64{0} ** 2;
var turn_go: u64 = 0;
/// Cada hilo vio al otro llegar a la meta mientras él seguía vivo.
var turn_met = [_]u64{0} ** 2;
const turn_goal: u64 = 200000;

/// Espera la salida y gira hasta que los dos hilos hayan avanzado. La salida
/// se da sin avisar al hart, así que después solo su timer puede turnarlos.
fn turnWorker(index: u64) callconv(.c) void {
    const other = 1 - index;
    const limit = timer.now() + 10 * abi.FB_TIMEBASE_HZ;
    while (@atomicLoad(u64, &turn_go, .acquire) == 0) {
        if (timer.now() > limit) return;
    }
    while (timer.now() < limit) {
        _ = @atomicRmw(u64, &turn_counts[index], .Add, 1, .monotonic);
        if (@atomicLoad(u64, &turn_counts[index], .monotonic) >= turn_goal and
            @atomicLoad(u64, &turn_counts[other], .monotonic) >= turn_goal)
        {
            @atomicStore(u64, &turn_met[index], 1, .release);
            return;
        }
    }
}

/// Dos hilos ocupados en el último hart se turnan: el hart sigue teniendo
/// tick mientras hay más de un hilo listo.
fn testSecondaryTurns(harts: u64) void {
    turn_counts = .{ 0, 0 };
    turn_met = .{ 0, 0 };
    @atomicStore(u64, &turn_go, 0, .release);
    const target = harts - 1;
    const first = spawnOrPanic2(target, turnWorker, 0);
    const second = spawnOrPanic2(target, turnWorker, 1);
    // Que los avisos de crear ya se hayan atendido antes de dar la salida.
    const settle = timer.now() + 5 * abi.FB_TIMEBASE_HZ / 1000;
    while (timer.now() < settle) thread.yield();
    @atomicStore(u64, &turn_go, 1, .release);
    waitAll(&.{ first, second });
    if (turn_met[0] == 0 or turn_met[1] == 0) @panic("dos hilos del mismo hart no se turnaron");
    passed("dos hilos ocupados en otro hart se turnan");
}

fn spawnOrPanic2(target: u64, entry: thread.Entry, argument: u64) u64 {
    return thread.spawnKernelOn(target, entry, argument, .on) orelse @panic("no se pudo crear el hilo");
}

/// Un hilo de prioridad mínima comparte nivel con el hilo en reposo de su
/// hart: cuando el turno pasa al reposo, el hart no puede dormirse sin tick.
fn lowSpinner(_: u64) callconv(.c) void {
    const end = timer.now() + 3 * abi.FB_TIMEBASE_HZ / 100;
    while (timer.now() < end) {}
}

fn testLowOnIdleHart(harts: u64) void {
    const target = harts - 1;
    const id = spawnOrPanic2(target, lowSpinner, 0);
    thread.setParams(id, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
    waitAll(&.{id});
    passed("un hilo de prioridad minima en otro hart termina aunque comparta turno con el reposo");
}

var boost_done: u64 = 0;
const boost_limit: u64 = abi.FB_TIMEBASE_HZ / 10;

/// Prioridad alta y presupuesto de sobra: gira hasta que acabe la prueba o
/// pasen 100 ms. Sin herencia, el servidor de prioridad mínima de su hart no
/// correría hasta entonces.
fn boostSpinner(_: u64) callconv(.c) void {
    const begin = timer.now();
    while (@atomicLoad(u64, &boost_done, .acquire) == 0 and timer.now() - begin < boost_limit) {}
}

fn waitBlockedSmp(id: u64) void {
    const limit = timer.now() + 10 * abi.FB_TIMEBASE_HZ;
    while (thread.state(id) != abi.FB_THREAD_BLOCKED) {
        if (timer.now() > limit) @panic("un proceso de otro hart no llego a esperar");
        thread.yield();
    }
}

/// Un cliente de prioridad máxima llama a un servidor de prioridad mínima de
/// otro hart, donde gira un hilo de prioridad alta. El servidor hereda la
/// prioridad del cliente, el aviso le hace expropiar al que gira y contesta
/// sin esperar a que este acabe. Después vuelve a su prioridad.
fn testCrossHartInheritance(harts: u64) void {
    if (harts < 2) {
        passed("con un solo hart no hay herencia entre harts");
        return;
    }
    const server_hart = harts - 1;
    const server = process.spawnWithOn(server_hart, .call_server, 1, &.{selftest_ipc.endpoint(0, 0, recv)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(server, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
    waitBlockedSmp(server);

    @atomicStore(u64, &boost_done, 0, .release);
    const spinner = spawnOrPanic2(server_hart, boostSpinner, 0);
    thread.setParams(spinner, abi.FB_PRIO_HIGH, 20 * abi.FB_SCHED_DEFAULT_BUDGET);
    // Que el hilo que gira ocupe ya su hart.
    const settle = timer.now() + 2 * abi.FB_TIMEBASE_HZ / 1000;
    while (timer.now() < settle) thread.yield();

    const boosts_before = ipc.boosts();
    const begin = timer.now();
    const client = process.spawnWithOn(0, .call_once, 1, &.{selftest_ipc.endpoint(0, 0, send)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(client, abi.FB_PRIO_TOP, abi.FB_SCHED_DEFAULT_BUDGET);
    waitExit(client, 0);
    const took = timer.now() - begin;
    @atomicStore(u64, &boost_done, 1, .release);
    waitAll(&.{spinner});

    if (ipc.boosts() == boosts_before) @panic("el servidor de otro hart no heredo la prioridad");
    if (thread.priorityOf(server) != abi.FB_PRIO_LOW) @panic("el servidor no volvio a su prioridad");
    process.requestKill(server);
    waitAll(&.{server});
    if (took >= boost_limit / 2) {
        uart.print("la llamada tardo ");
        uart.printDecimal(took / 10);
        uart.print(" us\n");
        @panic("inversion de prioridad entre harts: el servidor espero al hilo que giraba");
    }
    uart.print("[ok] un servidor de otro hart hereda la prioridad del cliente (");
    uart.printDecimal(took / 10);
    uart.print(" us, con un hilo de prioridad alta girando en su hart)\n");
}

/// La llamada llega antes que el servidor y espera en cola: al recibirla, el
/// servidor de otro hart hereda la prioridad del cliente. Si el cliente muere
/// esperando la respuesta, el servidor vuelve a la suya.
fn testInheritanceFromQueueAndDeath(harts: u64) void {
    if (harts < 2) {
        passed("con un solo hart no hay herencia que deshacer");
        return;
    }
    const client = process.spawnWithOn(0, .call_expect_peer, 0, &.{selftest_ipc.endpoint(0, 0, send)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(client, abi.FB_PRIO_TOP, abi.FB_SCHED_DEFAULT_BUDGET);
    waitBlockedSmp(client);

    const server = process.spawnWithOn(harts - 1, .call_server_lost, 0, &.{selftest_ipc.endpoint(0, 0, recv)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(server, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
    // El servidor recibe de la cola, comprueba que no puede recibir otra y se
    // duerme sin contestar.
    const limit = timer.now() + 10 * abi.FB_TIMEBASE_HZ;
    while (@import("sleep.zig").earliest() == abi.FB_SLEEP_NONE) {
        if (!thread.isAlive(server) or timer.now() > limit) @panic("el servidor de otro hart no llego a dormirse");
        thread.yield();
    }
    if (thread.priorityOf(server) != abi.FB_PRIO_TOP) @panic("recibir de la cola no hizo heredar la prioridad");

    process.requestKill(client);
    waitAll(&.{client});
    if (thread.priorityOf(server) != abi.FB_PRIO_LOW) @panic("muerto el cliente, el servidor no volvio a su prioridad");
    if (!@import("sleep.zig").cancel(server)) @panic("el servidor no estaba dormido");
    waitExit(server, 0);
    passed("lo heredado de la cola se deshace si el cliente muere");
}

var tick_stop: u64 = 0;

fn tickSpinner(_: u64) callconv(.c) void {
    while (@atomicLoad(u64, &tick_stop, .acquire) == 0) {}
}

/// Con el cerrojo global tomado por este hart, otro hart sigue atendiendo su
/// tick y cambiando de hilo: solo esperan a su propio cerrojo.
fn testTickWithoutGlobal(harts: u64) void {
    if (harts < 2) {
        passed("con un solo hart no hay tick ajeno que medir");
        return;
    }
    const target = harts - 1;
    @atomicStore(u64, &tick_stop, 0, .release);
    const ids = [2]u64{
        thread.spawnKernelOn(target, tickSpinner, 0, .on) orelse @panic("no se pudo crear el hilo"),
        thread.spawnKernelOn(target, tickSpinner, 0, .on) orelse @panic("no se pudo crear el hilo"),
    };
    // Que los dos estén ya turnándose.
    const warm = thread.switchesOf(target) + 4;
    const warm_limit = timer.now() + 5 * abi.FB_TIMEBASE_HZ;
    while (thread.switchesOf(target) < warm) {
        if (timer.now() > warm_limit) @panic("los hilos de otro hart no se turnan");
        thread.yield();
    }

    const saved = riscv.disableInterruptsSaving();
    // Ningún dormido vence mientras tanto: el tick no necesitará el global.
    if (sleep.earliest() != abi.FB_SLEEP_NONE) @panic("hay dormidos durante la prueba del tick");
    const ticks_before = timer.interruptsOf(target);
    const switches_before = thread.switchesOf(target);
    const limit = timer.now() + abi.FB_TIMEBASE_HZ / 2;
    while (timer.interruptsOf(target) < ticks_before + 3 or thread.switchesOf(target) < switches_before + 3) {
        if (timer.now() > limit) break;
    }
    const ticks = timer.interruptsOf(target) - ticks_before;
    const switches = thread.switchesOf(target) - switches_before;
    riscv.restoreInterrupts(saved);

    @atomicStore(u64, &tick_stop, 1, .release);
    waitAll(&ids);
    if (ticks < 3 or switches < 3) @panic("el tick de otro hart espero al cerrojo global");
    passed("el tick y el cambio de hilo de otro hart no esperan al cerrojo global");
}

var follow_depth: u64 = 0;
var follow_busy = false;
var follow_hart_depth: u64 = 99;

fn blockHoldingGlobal(_: u64) callconv(.c) void {
    const saved = riscv.disableInterruptsSaving();
    kernel_lock.enter();
    thread.block();
    follow_depth = kernel_lock.globalDepth();
    follow_busy = kernel_lock.globalBusy();
    follow_hart_depth = kernel_lock.hartDepth();
    kernel_lock.leave();
    riscv.restoreInterrupts(saved);
}

/// El global pasa con el hilo: el que se bloquea teniéndolo dos veces lo suelta
/// al cambiar a uno que no lo tiene, y al volver lo tiene de verdad otra vez,
/// con su profundidad.
fn testGlobalFollowsThread() void {
    follow_depth = 0;
    follow_busy = false;
    follow_hart_depth = 99;
    const id = thread.spawn(blockHoldingGlobal, 0, .on) orelse @panic("no se pudo crear el hilo");
    const limit = timer.now() + 5 * abi.FB_TIMEBASE_HZ;
    while (thread.state(id) != abi.FB_THREAD_BLOCKED) {
        if (timer.now() > limit) @panic("el hilo no llego a bloquearse");
        thread.yield();
    }
    if (kernel_lock.globalDepth() != 0) @panic("el global siguio en el hilo que entro");
    // Otro hart puede tenerlo un momento; este no, así que se libera.
    while (kernel_lock.globalBusy()) {
        if (timer.now() > limit) @panic("el global no se solto al cambiar de hilo");
    }
    thread.unblock(id);
    while (thread.isAlive(id)) {
        if (timer.now() > limit) @panic("el hilo no termino");
        thread.yield();
    }
    if (follow_depth != 2 or !follow_busy or follow_hart_depth != 0) @panic("el global no volvio con el hilo");
    passed("el cerrojo global pasa con el hilo al cambiar de hilo");
}

/// Herencia transitiva: A (máxima, hart 0) llama a B, que reenvía hasta C,
/// en otro hart. Con 3 harts o más la cadena pasa además por D, en el hart de
/// B, que trabaja con el contexto prestado de B: A -> B -> D -> C. C hereda la
/// prioridad de A a lo largo de toda la cadena; al matar a A, todos vuelven a
/// su prioridad sin esperar a que C conteste.
fn testTransitiveInheritance(harts: u64) void {
    if (harts < 2) {
        passed("con un solo hart no hay cadenas entre harts");
        return;
    }
    const long = harts >= 3;
    const hart_b: u64 = 1;
    const hart_c: u64 = if (long) harts - 1 else 0;
    const last_endpoint: u64 = if (long) 2 else 1;
    const client = process.spawnWithOn(0, .call_expect_peer, 0, &.{selftest_ipc.endpoint(0, 0, send)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(client, abi.FB_PRIO_TOP, abi.FB_SCHED_DEFAULT_BUDGET);
    waitBlockedSmp(client);

    const last = process.spawnWithOn(hart_c, .call_server_lost, 0, &.{selftest_ipc.endpoint(0, last_endpoint, recv)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(last, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
    waitBlockedSmp(last);

    // D, en el hart de B: recibe en 1 y llama a 2.
    var inner: u64 = 0;
    if (long) {
        inner = process.spawnWithOn(hart_b, .call_forwarder, 0, &.{
            selftest_ipc.endpoint(0, 1, recv),
            selftest_ipc.endpoint(1, 2, send),
        }) orelse @panic("no se pudo crear el proceso");
        thread.setParams(inner, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
        waitBlockedSmp(inner);
    }

    const middle = process.spawnWithOn(hart_b, .call_forwarder, 0, &.{
        selftest_ipc.endpoint(0, 0, recv),
        selftest_ipc.endpoint(1, 1, send),
    }) orelse @panic("no se pudo crear el proceso");
    thread.setParams(middle, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);

    // C recibe la llamada, comprueba que no puede recibir otra y se duerme sin
    // contestar: la cadena queda montada.
    const limit = timer.now() + 10 * abi.FB_TIMEBASE_HZ;
    while (sleep.earliest() == abi.FB_SLEEP_NONE) {
        if (!thread.isAlive(last) or timer.now() > limit) @panic("el final de la cadena no llego a dormirse");
        thread.yield();
    }
    const before_last = if (long) inner else middle;
    if (abi.fb_ipc_waits_for(before_last) != last) @panic("la cadena no quedo montada");
    if (long and abi.fb_ipc_waits_for(middle) != inner) @panic("la cadena no quedo montada");
    if (thread.priorityOf(middle) != abi.FB_PRIO_TOP) @panic("el del medio no heredo la prioridad");
    if (long and thread.priorityOf(inner) != abi.FB_PRIO_TOP) @panic("el del mismo hart no corre con la prioridad heredada");
    if (thread.priorityOf(last) != abi.FB_PRIO_TOP) @panic("el final de la cadena no heredo la prioridad");
    if (!ipc.ruleHolds()) @panic("con la cadena montada no se cumple la regla de la herencia");

    const recomputed = ipc.recomputations();
    process.requestKill(client);
    waitAll(&.{client});
    if (thread.priorityOf(middle) != abi.FB_PRIO_LOW) @panic("muerto el cliente, el del medio no volvio a su prioridad");
    if (long and thread.priorityOf(inner) != abi.FB_PRIO_LOW) @panic("muerto el cliente, el del mismo hart siguio con su prioridad");
    if (thread.priorityOf(last) != abi.FB_PRIO_LOW) @panic("muerto el cliente, el final de la cadena siguio con su prioridad");
    if (ipc.recomputations() == recomputed) @panic("el cambio no se rehizo por la cadena");
    if (!ipc.ruleHolds()) @panic("muerto el cliente, no se cumple la regla de la herencia");

    process.requestKill(middle);
    if (long) process.requestKill(inner);
    process.requestKill(last);
    waitAll(&.{ middle, last });
    if (long) waitAll(&.{inner});
    passed(if (long)
        "la herencia sigue la cadena entre harts, tambien por un tramo del mismo hart, y se deshace entera"
    else
        "la herencia sigue la cadena entre harts y se deshace entera");
}

/// Espera a que se cumpla `ready`, con un límite.
fn waitFor(ready: *const fn ([]const u64) bool, ids: []const u64, message: []const u8) void {
    const limit = timer.now() + 10 * abi.FB_TIMEBASE_HZ;
    while (!ready(ids)) {
        if (timer.now() > limit) @panic(message);
        thread.yield();
    }
}

/// ids[0] (el servidor) esperando, con la respuesta de ids[1] pendiente.
fn holdsCall(ids: []const u64) bool {
    return abi.fb_ipc_waits_for(ids[1]) == ids[0] and thread.state(ids[0]) == abi.FB_THREAD_BLOCKED;
}

/// Un servidor aplaza la llamada de un cliente de su hart y sigue con su
/// contexto. Llega después la de un cliente urgente de otro hart, que no
/// puede prestarle el suyo: el servidor hereda su urgencia sin soltar el
/// contexto prestado. Antes se subía la prioridad del contexto propio del
/// servidor, que no usaba, y la herencia no llegaba.
fn testBorrowedContextInherits(harts: u64) void {
    if (harts < 2) {
        passed("con un solo hart no hay herencia sobre un contexto prestado");
        return;
    }
    const hart_s: u64 = 1;
    const server = process.spawnWithOn(hart_s, .defer_three, 0, &.{
        selftest_ipc.endpoint(0, 0, recv),
        selftest_ipc.endpoint(1, 1, recv),
    }) orelse @panic("no se pudo crear el proceso");
    thread.setParams(server, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
    waitBlockedSmp(server);

    const local = process.spawnWithOn(hart_s, .call_expect_peer, 0, &.{selftest_ipc.endpoint(0, 0, send)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(local, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);
    waitFor(holdsCall, &.{ server, local }, "el servidor no aplazo la llamada de su hart");
    if (thread.contextOf(server) != local) @panic("aplazar no conservo el contexto prestado");

    const remote = process.spawnWithOn(0, .call_expect_peer, 0, &.{selftest_ipc.endpoint(0, 0, send)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(remote, abi.FB_PRIO_TOP, abi.FB_SCHED_DEFAULT_BUDGET);
    waitFor(holdsCall, &.{ server, remote }, "el servidor no aplazo la llamada de otro hart");

    if (thread.contextOf(server) != local) @panic("el servidor solto el contexto prestado");
    if (thread.priorityOf(server) != abi.FB_PRIO_TOP) @panic("con un contexto prestado, el servidor no heredo la urgencia de otro hart");
    if (thread.priorityOf(local) != abi.FB_PRIO_NORMAL) @panic("la herencia cambio la prioridad del cliente que presto su contexto");
    if (!ipc.ruleHolds()) @panic("con un contexto prestado no se cumple la regla de la herencia");

    process.requestKill(remote);
    waitAll(&.{remote});
    if (thread.priorityOf(server) != abi.FB_PRIO_NORMAL) @panic("muerto el cliente de otro hart, el servidor siguio con su urgencia");

    process.requestKill(server);
    waitAll(&.{ server, local });
    passed("con un contexto prestado, el servidor hereda la urgencia de otro hart sin soltarlo");
}

/// ids[1] terminó e ids[0] (el servidor) espera otra vez.
fn answeredAndWaiting(ids: []const u64) bool {
    return !thread.isAlive(ids[1]) and thread.state(ids[0]) == abi.FB_THREAD_BLOCKED;
}

/// Contestar con reply a un cliente de otro hart quita lo heredado de él: el
/// servidor vuelve a la urgencia del aplazado que le queda, sin soltar su
/// contexto.
fn testReplyDropsInheritance(harts: u64) void {
    if (harts < 2) {
        passed("con un solo hart no hay herencia que soltar al contestar");
        return;
    }
    const hart_s: u64 = 1;
    const server = process.spawnWithOn(hart_s, .defer_then_serve, 0, &.{
        selftest_ipc.endpoint(0, 0, recv),
        selftest_ipc.endpoint(1, 1, recv),
    }) orelse @panic("no se pudo crear el proceso");
    thread.setParams(server, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
    waitBlockedSmp(server);

    const local = process.spawnWithOn(hart_s, .call_expect_peer, 0, &.{selftest_ipc.endpoint(0, 0, send)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(local, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);
    waitFor(holdsCall, &.{ server, local }, "el servidor no aplazo la llamada de su hart");

    const remote = process.spawnWithOn(0, .call_once, 7, &.{selftest_ipc.endpoint(0, 0, send)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(remote, abi.FB_PRIO_TOP, abi.FB_SCHED_DEFAULT_BUDGET);
    waitFor(answeredAndWaiting, &.{ server, remote }, "el servidor no contesto al cliente de otro hart");
    if (process.resultOf(remote).value != 0) @panic("la respuesta al cliente de otro hart fue erronea");

    if (thread.contextOf(server) != local) @panic("contestar solto el contexto del aplazado");
    if (thread.priorityOf(server) != abi.FB_PRIO_NORMAL) @panic("contestar con reply no quito lo heredado del cliente de otro hart");

    process.requestKill(server);
    waitAll(&.{ server, local });
    passed("contestar con reply quita lo heredado de otro hart y conserva el contexto del aplazado");
}

pub fn run(harts: u64) void {
    testHartsOnline(harts);
    testMutualExclusion(harts);
    testParallel(harts);
    testLockFairness(harts);
    testProcessOnOtherHart(harts);
    testUserTp(harts);
    testCrossHartCall(harts);
    testClintLimited();
    testIpiAfterUnlock(harts);
    testTickWithoutGlobal(harts);
    testGlobalFollowsThread();
    testRemoteKill(harts);
    testIdleSleeps(harts);
    testSecondaryTurns(harts);
    testLowOnIdleHart(harts);
    testCrossHartInheritance(harts);
    testInheritanceFromQueueAndDeath(harts);
    testTransitiveInheritance(harts);
    testBorrowedContextInherits(harts);
    testReplyDropsInheritance(harts);
}
