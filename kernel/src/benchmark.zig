//! Mide el asignador de marcos en instrucciones ejecutadas.
//! Solo es válido con QEMU en `-icount`; las instrucciones no equivalen a tiempo.

const abi = @import("abi.zig").c;
const std = @import("std");
const hart = @import("hart.zig");
const ipi = @import("ipi.zig");
const kernel_lock = @import("kernel_lock.zig");
const ipc = @import("ipc.zig");
const memory = @import("memory.zig");
const process = @import("process.zig");
const riscv = @import("riscv.zig");
const selftest_sched = @import("selftest_sched.zig");
const spinlock = @import("spinlock.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");
const uart = @import("uart.zig");

var addresses: [abi.FB_MAX_FRAMES]u64 = undefined;

const repetitions: u64 = 16;

fn instructions() u64 {
    return riscv.readCsr("instret");
}

fn report(name: []const u8, total: u64, operations: u64) void {
    uart.print(name);
    uart.print(": ");
    uart.printDecimal(total / operations);
    uart.print(" instrucciones/op (");
    uart.printDecimal(operations);
    uart.print(" ops)\n");
}

fn allocateAll() u64 {
    var count: u64 = 0;
    while (true) : (count += 1) {
        const address = abi.fb_frames_alloc();
        if (address == 0) return count;
        addresses[count] = address;
    }
}

fn freeAll() void {
    for (addresses[0..memory.frame_count]) |address| {
        if (abi.fb_frames_free(address) != abi.FB_FRAMES_OK) @panic("fallo al liberar");
    }
}

fn measureSequential() void {
    const start = instructions();
    const count = allocateAll();
    report("asignacion secuencial", instructions() - start, count);

    const free_start = instructions();
    freeAll();
    report("liberacion", instructions() - free_start, count);
}

/// Con la memoria llena, libera uno de cada dos marcos y los vuelve a pedir.
fn measureFragmented() void {
    const count = allocateAll();
    var index: u64 = 1;
    while (index < count) : (index += 2) {
        if (abi.fb_frames_free(addresses[index]) != abi.FB_FRAMES_OK) @panic("fallo al liberar");
    }

    const start = instructions();
    index = 1;
    var operations: u64 = 0;
    while (index < count) : (index += 2) {
        addresses[index] = abi.fb_frames_alloc();
        operations += 1;
    }
    report("memoria fragmentada", instructions() - start, operations);
    freeAll();
}

/// El único marco libre está siempre una palabra por detrás de la sugerencia,
/// de modo que la búsqueda tiene que dar la vuelta a casi todo el mapa.
fn measureWorstCase() void {
    const count = allocateAll();
    const frames_per_word: u64 = 64;

    var total: u64 = 0;
    var victim = count - 1;
    for (0..repetitions) |_| {
        victim = (victim + count - frames_per_word) % count;
        const expected = addresses[victim];
        if (abi.fb_frames_free(expected) != abi.FB_FRAMES_OK) @panic("fallo al liberar");
        const start = instructions();
        const address = abi.fb_frames_alloc();
        total += instructions() - start;
        if (address != expected) @panic("resultado inesperado en el peor caso");
    }
    report("peor caso con exito", total, repetitions);

    total = 0;
    for (0..repetitions) |_| {
        const start = instructions();
        const address = abi.fb_frames_alloc();
        total += instructions() - start;
        if (address != 0) @panic("habia marcos libres inesperados");
    }
    report("memoria agotada", total, repetitions);
    freeAll();
}

var switch_worker_running: bool = true;

fn switchWorker(_: u64) callconv(.c) void {
    while (switch_worker_running) thread.yield();
}

/// Dos hilos cediéndose la CPU; cada vuelta son dos cambios de contexto.
fn measureContextSwitch() void {
    const rounds: u64 = 4096;
    const worker = thread.spawn(switchWorker, 0, .off) orelse @panic("no se pudo crear el hilo");

    // Lleva al hilo hasta su bucle antes de medir.
    thread.yield();

    const start = instructions();
    for (0..rounds) |_| thread.yield();
    report("cambio de contexto", instructions() - start, rounds * 2);

    switch_worker_running = false;
    while (thread.isAlive(worker)) thread.yield();
}

fn waitForResult(id: u64) process.Result {
    while (thread.isAlive(id)) thread.yield();
    const result = process.resultOf(id);
    if (result.kind != .exited) @panic("el programa de medida no termino bien");
    return result;
}

/// El programa cuenta sus propias instrucciones alrededor de cada llamada.
/// Tomar y soltar el cerrojo de giro cuando nadie lo tiene.
fn measureLock() void {
    var lock = spinlock.SpinLock{};
    const rounds: u64 = 4096;
    const start = instructions();
    for (0..rounds) |_| {
        lock.acquire();
        lock.release();
    }
    report("cerrojo libre, tomar y soltar", instructions() - start, rounds);

    var ticket = spinlock.TicketLock{};
    const ticket_start = instructions();
    for (0..rounds) |_| {
        ticket.acquire();
        ticket.release();
    }
    report("cerrojo de tiques libre, tomar y soltar", instructions() - ticket_start, rounds);
}

/// Un aviso a este mismo hart: escribir msip, el paso por modo máquina, la
/// interrupción de supervisor y volver a planificar, hasta que se atiende.
fn measureIpi() void {
    const rounds: u64 = 1024;
    const me = hart.id();
    var total: u64 = 0;
    riscv.enableInterrupts();
    defer riscv.disableInterrupts();
    for (0..rounds) |_| {
        const before = ipi.received(me);
        const start = instructions();
        ipi.send(me);
        while (ipi.received(me) == before) {}
        total += instructions() - start;
    }
    report("aviso entre harts (a si mismo), ida y vuelta", total, rounds);
}

fn measureSyscall() void {
    const id = process.spawn(.bench_syscall, 0) orelse @panic("no se pudo crear el proceso");
    report("llamada al sistema, ida y vuelta", waitForResult(id).value, 4096);
}

/// Tres participantes en turno; cada cambio incluye cambiar de tablas.
fn measureSpaceSwitch() void {
    const first = process.spawn(.bench_yield, 0) orelse @panic("no se pudo crear el proceso");
    const second = process.spawn(.bench_yield, 0) orelse @panic("no se pudo crear el proceso");
    const value = waitForResult(first).value;
    _ = waitForResult(second);
    report("yield con cambio de espacio", value, 4096 * 3);
}

/// Un cliente y un servidor; incluye al hilo principal en el turno.
fn measureIpc() void {
    const send: u64 = abi.FB_RIGHT_SEND;
    const recv: u64 = abi.FB_RIGHT_RECV;
    const kind: u64 = abi.FB_CAP_ENDPOINT;
    const pong = process.spawnWith(.bench_pong, 0, &.{
        .{ .slot = 0, .kind = kind, .object = 0, .rights = recv },
        .{ .slot = 1, .kind = kind, .object = 1, .rights = send },
    }) orelse @panic("no se pudo crear el proceso");
    const ping = process.spawnWith(.bench_ping, 0, &.{
        .{ .slot = 0, .kind = kind, .object = 0, .rights = send },
        .{ .slot = 1, .kind = kind, .object = 1, .rights = recv },
    }) orelse @panic("no se pudo crear el proceso");
    report("IPC ida y vuelta entre procesos", waitForResult(ping).value, 4096);
    _ = waitForResult(pong);
}

/// La misma IPC sin el hilo principal en el turno. Con prioridad mínima solo
/// corre cuando ping y pong están bloqueados a la vez, es decir, al acabar.
/// En measureIpc el turno circular lo mete en cada vuelta, y el contador de
/// instrucciones del hart cuenta también su sondeo y el traspaso de cerrojos
/// entre él (cerrojo del hart) y los procesos (cerrojo global).
fn measureIpcAlone() void {
    const send: u64 = abi.FB_RIGHT_SEND;
    const recv: u64 = abi.FB_RIGHT_RECV;
    const kind: u64 = abi.FB_CAP_ENDPOINT;
    thread.setParams(0, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
    const pong = process.spawnWith(.bench_pong, 0, &.{
        .{ .slot = 0, .kind = kind, .object = 0, .rights = recv },
        .{ .slot = 1, .kind = kind, .object = 1, .rights = send },
    }) orelse @panic("no se pudo crear el proceso");
    const ping = process.spawnWith(.bench_ping, 0, &.{
        .{ .slot = 0, .kind = kind, .object = 0, .rights = send },
        .{ .slot = 1, .kind = kind, .object = 1, .rights = recv },
    }) orelse @panic("no se pudo crear el proceso");
    const value = waitForResult(ping).value;
    _ = waitForResult(pong);
    thread.setParams(0, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);
    report("IPC ida y vuelta entre procesos, sin el hilo que mide", value, 4096);
}

/// Mismo intercambio que measureIpc, con llamada y respuesta y cambio directo.
/// Una llamada con un salto intermedio: cliente, reenviador y servidor. El
/// préstamo recorre la cadena y vuelve.
fn measureChainedCall() void {
    const send: u64 = abi.FB_RIGHT_SEND;
    const recv: u64 = abi.FB_RIGHT_RECV;
    const kind: u64 = abi.FB_CAP_ENDPOINT;
    const server = process.spawnWith(.bench_serve, 0, &.{
        .{ .slot = 0, .kind = kind, .object = 1, .rights = recv },
    }) orelse @panic("no se pudo crear el proceso");
    while (thread.state(server) != abi.FB_THREAD_BLOCKED) thread.yield();
    const forwarder = process.spawnWith(.call_forwarder, 0, &.{
        .{ .slot = 0, .kind = kind, .object = 0, .rights = recv },
        .{ .slot = 1, .kind = kind, .object = 1, .rights = send },
    }) orelse @panic("no se pudo crear el proceso");
    while (thread.state(forwarder) != abi.FB_THREAD_BLOCKED) thread.yield();
    const client = process.spawnWith(.bench_call, 0, &.{
        .{ .slot = 0, .kind = kind, .object = 0, .rights = send },
    }) orelse @panic("no se pudo crear el proceso");
    report("llamada con un salto intermedio", waitForResult(client).value, 4096);
    _ = waitForResult(forwarder);
    _ = waitForResult(server);
}

fn measureCall() void {
    const send: u64 = abi.FB_RIGHT_SEND;
    const recv: u64 = abi.FB_RIGHT_RECV;
    const kind: u64 = abi.FB_CAP_ENDPOINT;
    const server = process.spawnWith(.bench_serve, 0, &.{
        .{ .slot = 0, .kind = kind, .object = 0, .rights = recv },
    }) orelse @panic("no se pudo crear el proceso");
    while (thread.state(server) != abi.FB_THREAD_BLOCKED) thread.yield();
    const client = process.spawnWith(.bench_call, 0, &.{
        .{ .slot = 0, .kind = kind, .object = 0, .rights = send },
    }) orelse @panic("no se pudo crear el proceso");
    report("llamada y respuesta entre procesos", waitForResult(client).value, 4096);
    _ = waitForResult(server);
}

const send_right: u64 = abi.FB_RIGHT_SEND;
const recv_right: u64 = abi.FB_RIGHT_RECV;

fn endpointGrant(slot: u64, object: u64, rights: u64) process.Grant {
    return .{ .slot = slot, .kind = abi.FB_CAP_ENDPOINT, .object = object, .rights = rights };
}

fn startDriver() u64 {
    const id = process.spawnWith(.uart_driver, abi.FB_UART_MODE_TEST, &.{
        endpointGrant(0, 0, recv_right),
        .{ .slot = 1, .kind = abi.FB_CAP_DEVICE, .object = abi.FB_DEVICE_UART, .rights = send_right | recv_right },
        endpointGrant(2, 1, send_right),
    }) orelse @panic("no se pudo crear el driver");
    while (thread.state(id) != abi.FB_THREAD_BLOCKED) thread.yield();
    return id;
}

const uart_rounds: u64 = 256;

/// El kernel escribe un byte por llamada, sondeando la UART.
fn measureDirectWrite() void {
    const id = process.spawnWith(.bench_write, 0, &process.console_grant) orelse @panic("no se pudo crear el proceso");
    const value = waitForResult(id).value;
    uart.print("\n");
    report("byte por el kernel", value, uart_rounds);
}

/// El mismo byte pasando por IPC hasta el driver de usuario.
fn measureDriverWrite() void {
    const driver = startDriver();
    const client = process.spawnWith(.bench_driver_client, 0, &.{endpointGrant(0, 0, send_right)}) orelse @panic("no se pudo crear el proceso");
    const value = waitForResult(client).value;
    _ = waitForResult(driver);
    uart.print("\n");
    report("byte por el driver de usuario", value, uart_rounds);
}

/// IPC al driver, UART en bucle, interrupción, señal, driver, lector y vuelta.
fn measureInterruptPath() void {
    const driver = startDriver();
    const reader = process.spawnWith(.bench_loop_reader, 0, &.{
        endpointGrant(0, 1, recv_right),
        endpointGrant(1, 2, send_right),
    }) orelse @panic("no se pudo crear el proceso");
    while (thread.state(reader) != abi.FB_THREAD_BLOCKED) thread.yield();
    const writer = process.spawnWith(.bench_loop_writer, 0, &.{
        endpointGrant(0, 0, send_right),
        endpointGrant(1, 2, recv_right),
    }) orelse @panic("no se pudo crear el proceso");
    const value = waitForResult(writer).value;
    _ = waitForResult(reader);
    _ = waitForResult(driver);
    report("byte por interrupcion, ida y vuelta", value, uart_rounds);
}

/// El mismo byte, escrito y leído con llamadas: la lectura la aplaza el driver
/// hasta que llega la interrupción.
fn measureCallRead() void {
    const driver = startDriver();
    const deferred_before = ipc.deferrals();
    const client = process.spawnWith(.bench_call_read, 0, &.{endpointGrant(0, 0, send_right)}) orelse @panic("no se pudo crear el proceso");
    const value = waitForResult(client).value;
    _ = waitForResult(driver);
    report("byte por interrupcion, lectura con call", value, uart_rounds);
    uart.print("lecturas que se aplazaron: ");
    uart.printDecimal(ipc.deferrals() - deferred_before);
    uart.print(" de ");
    uart.printDecimal(uart_rounds);
    uart.print("\n");
}

/// Un lector de prioridad máxima pide cada byte antes de que exista y otro
/// proceso lo escribe después: el driver aplaza la lectura y la contesta desde
/// la interrupción. El hilo principal baja a prioridad mínima para no contar.
fn measureDeferredRead() void {
    const driver = startDriver();
    const deferred_before = ipc.deferrals();
    thread.setParams(0, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
    var reader: u64 = undefined;
    var writer: u64 = undefined;
    {
        const saved = riscv.disableInterruptsSaving();
        defer riscv.restoreInterrupts(saved);
        reader = process.spawnWith(.bench_defer_reader, 0, &.{endpointGrant(0, 0, send_right)}) orelse @panic("no se pudo crear el proceso");
        thread.setParams(reader, abi.FB_PRIO_TOP, abi.FB_SCHED_DEFAULT_BUDGET);
        writer = process.spawnWith(.bench_defer_writer, 0, &.{endpointGrant(0, 0, send_right)}) orelse @panic("no se pudo crear el proceso");
    }
    const value = waitForResult(reader).value;
    _ = waitForResult(writer);
    _ = waitForResult(driver);
    thread.setParams(0, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);
    report("byte escrito por otro proceso con lectura aplazada", value, uart_rounds);
    uart.print("lecturas que se aplazaron: ");
    uart.printDecimal(ipc.deferrals() - deferred_before);
    uart.print(" de ");
    uart.printDecimal(uart_rounds);
    uart.print("\n");
}

/// Tiempo que un hilo de prioridad intermedia corre mientras un cliente de
/// prioridad máxima espera una respuesta aplazada por un servidor de prioridad
/// mínima. Es la inversión de prioridad que sufre ese cliente.
fn measureDeferredInversion() void {
    uart.print("inversion de prioridad con respuesta aplazada: ");
    uart.printDecimal(selftest_sched.deferredInversion());
    uart.print(" unidades\n");
}

/// El peor caso para destruir: los marcos del proceso muy separados. Se ocupa
/// toda la memoria y solo quedan libres ocho marcos repartidos por ella.
fn measureSpreadProcess() void {
    var count: usize = 0;
    while (count < addresses.len) {
        const address = abi.fb_frames_alloc();
        if (address == 0) break;
        addresses[count] = address;
        count += 1;
    }
    const holes: usize = 8;
    for (0..holes) |index| _ = abi.fb_frames_free(addresses[index * (count - 1) / (holes - 1)]);

    const rounds: u64 = 4;
    const start = instructions();
    for (0..rounds) |_| _ = waitForResult(process.spawnWith(.hello, 0, &process.console_grant) orelse @panic("no se pudo crear el proceso"));
    report("crear, ejecutar y destruir proceso con marcos dispersos", instructions() - start, rounds);

    // Los huecos ya están libres: liberarlos otra vez solo devuelve un error.
    for (addresses[0..count]) |address| _ = abi.fb_frames_free(address);
}

fn measureProcessLifetime() void {
    const rounds: u64 = 16;
    const start = instructions();
    for (0..rounds) |_| _ = waitForResult(process.spawnWith(.hello, 0, &process.console_grant) orelse @panic("no se pudo crear el proceso"));
    report("crear, ejecutar y destruir proceso", instructions() - start, rounds);
}

var gap_stop: u64 = 0;
var max_gaps = [_]u64{0} ** 3;
/// Vueltas de los hilos ocupados: trabajo útil, lo que no se fue en cambiar de hilo.
var work_done: u64 = 0;

/// Gira anotando el mayor hueco entre dos instantes consecutivos en que corrió.
fn gapWorker(index: u64) callconv(.c) void {
    var last = timer.now();
    while (@atomicLoad(u64, &gap_stop, .seq_cst) == 0) {
        const time = timer.now();
        if (time - last > max_gaps[index]) max_gaps[index] = time - last;
        last = time;
        _ = @atomicRmw(u64, &work_done, .Add, 1, .monotonic);
    }
}

/// La cota demostrada cuenta tiempo cobrado a presupuesto. Lo que cada turno
/// ajeno se pase de su presupuesto (el exceso, que se cobra como deuda) va
/// aparte: como mucho `turns` turnos por el exceso máximo medido.
fn reportGap(name: []const u8, measured: u64, bound: u64, turns: u64) void {
    const extended = bound + turns * thread.maxOverrun();
    uart.print(name);
    uart.print(": espera maxima ");
    uart.printDecimal(measured);
    uart.print(" de una cota de ");
    uart.printDecimal(bound);
    uart.print(" unidades de presupuesto, ");
    uart.printDecimal(extended);
    uart.print(" con los excesos\n");
    if (measured > extended) @panic("se supero la cota demostrada");
}

/// Compara la espera real con la cota demostrada, 2 * (suma de los demás).
/// El hilo principal compite también, con la prioridad mínima.
/// Turnos ajenos que caben en la cota: dos rondas, y en cada una cada
/// contexto en trozos de como mínimo un cuanto.
fn turnsBesides(index: usize, budgets: [3]u64, main_budget: u64) u64 {
    var turns = (main_budget + thread.base_quantum - 1) / thread.base_quantum;
    for (budgets, 0..) |budget, other| {
        if (other != index) turns += (budget + thread.base_quantum - 1) / thread.base_quantum;
    }
    return 2 * turns;
}

fn measureBoundedWait() void {
    const budgets = [_]u64{ 10000, 20000, 30000 };
    const levels = [_]u64{ abi.FB_PRIO_TOP, abi.FB_PRIO_HIGH, abi.FB_PRIO_LOW };
    const main_budget: u64 = 10000;
    var ids: [3]u64 = undefined;

    timer.init();
    for (&ids, budgets, levels, 0..) |*id, budget, level, index| {
        id.* = thread.spawn(gapWorker, index, .on) orelse @panic("no se pudo crear el hilo");
        thread.setParams(id.*, level, budget);
    }
    thread.setParams(0, abi.FB_PRIO_LOW, main_budget);

    thread.resetMaxOverrun();
    riscv.enableInterrupts();
    const start = timer.now();
    while (timer.now() - start < abi.FB_TIMEBASE_HZ / 5) {}
    @atomicStore(u64, &gap_stop, 1, .seq_cst);
    while (thread.isAlive(ids[0]) or thread.isAlive(ids[1]) or thread.isAlive(ids[2])) {}
    riscv.disableInterrupts();

    const total = budgets[0] + budgets[1] + budgets[2] + main_budget;
    reportGap("prioridad maxima", max_gaps[0], 2 * (total - budgets[0]), turnsBesides(0, budgets, main_budget));
    reportGap("prioridad alta", max_gaps[1], 2 * (total - budgets[1]), turnsBesides(1, budgets, main_budget));
    reportGap("prioridad minima", max_gaps[2], 2 * (total - budgets[2]), turnsBesides(2, budgets, main_budget));
    uart.print("exceso maximo sobre el presupuesto: ");
    uart.printDecimal(thread.maxOverrun());
    uart.print(" unidades\n");
}

/// Tres hilos ocupados del mismo nivel: la mayor espera de cada uno entre dos
/// turnos. Con el cuanto, el turno rota cada milisegundo, no cada tick.
fn measureTurnGap() void {
    var ids: [3]u64 = undefined;
    @atomicStore(u64, &gap_stop, 0, .seq_cst);
    max_gaps = [_]u64{0} ** 3;
    work_done = 0;
    for (&ids, 0..) |*id, index| {
        id.* = thread.spawn(gapWorker, index, .on) orelse @panic("no se pudo crear el hilo");
        thread.setParams(id.*, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);
    }
    thread.setParams(0, abi.FB_PRIO_LOW, 1000);

    riscv.enableInterrupts();
    const start = timer.now();
    while (timer.now() - start < abi.FB_TIMEBASE_HZ / 5) {}
    @atomicStore(u64, &gap_stop, 1, .seq_cst);
    while (thread.isAlive(ids[0]) or thread.isAlive(ids[1]) or thread.isAlive(ids[2])) {}
    riscv.disableInterrupts();
    thread.setParams(0, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);

    uart.print("mismo nivel, 3 hilos ocupados: espera maxima entre turnos ");
    uart.printDecimal(@max(max_gaps[0], @max(max_gaps[1], max_gaps[2])));
    uart.print(" unidades (cuanto ");
    uart.printDecimal(thread.quantum());
    uart.print(", cambio de hilo ");
    uart.printDecimal(thread.switchCost());
    uart.print(")\n");
    uart.print("trabajo util en 200 ms: ");
    uart.printDecimal(work_done);
    uart.print(" vueltas\n");
}

/// Latencia de despertar bajo carga, como cyclictest: un proceso duerme hasta un
/// instante y mide cuánto tarda en volver a correr, mientras otros procesos
/// giran sin parar. Mismo programa, periodo y vueltas que en Linux.
const latency_period: u64 = abi.FB_TIMEBASE_HZ / 1000;
const latency_rounds: u64 = 200;
const ns_per_unit: u64 = 1_000_000_000 / abi.FB_TIMEBASE_HZ;

fn measureLatency(name: []const u8, probe_level: u64, hogs: usize) void {
    thread.setParams(0, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
    var hog_ids: [3]u64 = undefined;
    var probe: u64 = undefined;
    {
        const saved = riscv.disableInterruptsSaving();
        defer riscv.restoreInterrupts(saved);
        for (hog_ids[0..hogs]) |*id| {
            id.* = process.spawn(.spin, 0) orelse @panic("no se pudo crear el proceso");
            thread.setParams(id.*, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);
        }
        probe = process.spawn(.latency_probe, latency_rounds << 32 | latency_period) orelse @panic("no se pudo crear el proceso");
        thread.setParams(probe, probe_level, abi.FB_SCHED_DEFAULT_BUDGET);
    }
    riscv.enableInterrupts();
    const value = waitForResult(probe).value;
    for (hog_ids[0..hogs]) |id| {
        process.requestKill(id);
        while (thread.isAlive(id)) thread.yield();
    }
    riscv.disableInterrupts();
    thread.setParams(0, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);
    if (value >> 63 != 0) @panic("un proceso desperto antes de su vencimiento");

    uart.print("latencia, ");
    uart.print(name);
    uart.print(": maxima ");
    uart.printDecimal((value & 0xffff_ffff) * ns_per_unit);
    uart.print(" ns, media ");
    uart.printDecimal((value >> 32) * ns_per_unit);
    uart.print(" ns (");
    uart.printDecimal(latency_rounds);
    uart.print(" vueltas de 1 ms)\n");
}

/// Con la misma prioridad, la espera está acotada por el teorema de no
/// inanición: a lo sumo lo que les queda a los demás contextos, aquí tres
/// procesos ocupados y el hilo principal con el presupuesto por defecto.
fn measureLatencies() void {
    measureLatency("sin carga", abi.FB_PRIO_TOP, 0);
    measureLatency("prioridad maxima y 3 procesos ocupados", abi.FB_PRIO_TOP, 3);
    measureLatency("misma prioridad que 3 procesos ocupados", abi.FB_PRIO_NORMAL, 3);
    uart.print("cota demostrada con misma prioridad, por presupuestos: ");
    uart.printDecimal(4 * abi.FB_SCHED_DEFAULT_BUDGET * ns_per_unit);
    uart.print(" ns; por turno, sin despertar: menos de ");
    uart.printDecimal(abi.FB_MAX_THREADS);
    uart.print(" cuantos de ");
    uart.printDecimal(thread.quantum() * ns_per_unit);
    uart.print(" ns\n");
}

pub fn run() void {
    uart.print("benchmark: marcos=");
    uart.printDecimal(memory.frame_count);
    uart.print("\n");
    measureSequential();
    measureFragmented();
    measureWorstCase();
    measureContextSwitch();
    measureLock();
    measureIpi();

    // Solo en esta compilación el usuario puede leer el contador instret.
    riscv.writeCsr("scounteren", (1 << 1) | (1 << 2));
    measureSyscall();
    measureSpaceSwitch();
    measureIpc();
    measureCall();
    measureChainedCall();
    measureDirectWrite();
    measureDriverWrite();
    measureInterruptPath();
    measureCallRead();
    measureDeferredRead();
    measureDeferredInversion();
    measureProcessLifetime();
    measureSpreadProcess();
    measureBoundedWait();
    measureTurnGap();
    measureLatencies();
    // Al final: deja al hilo 0 con el presupuesto entero, y eso cambiaría
    // las medidas de detrás.
    measureIpcAlone();
}

// Medidas con varios harts, para compararlas con Linux en la misma máquina.
//
// Con -icount, QEMU ejecuta los harts por turnos sobre un solo contador de
// instrucciones: el reloj virtual, e instret en cualquier hart, avanzan con las
// instrucciones de todos (con shift=0, un nanosegundo por instrucción; el reloj
// cuenta de 100 en 100). Así se mide el trabajo de toda la máquina, leído con
// rdtime desde usuario, igual que en Linux. La calibración lo comprueba.

const x_rounds: u64 = 4096;
const inversion_rounds: u64 = 256;
const x_repeats = 5;

/// Espera dormido con wfi: el hilo principal no suma instrucciones a su hart.
/// Mira si el proceso sigue vivo solo una vez por tick: mirarlo toma el
/// cerrojo del kernel, y hacerlo cada vez que el cliente se bloquea lo haría
/// competir con el servidor de otro hart en cada vuelta (como `init` en Linux,
/// que espera en waitpid sin tocar nada).
fn sleepUntilExit(id: u64) process.Result {
    thread.yield();
    var seen = timer.ticks();
    while (true) {
        riscv.disableInterrupts();
        const tick = timer.ticks();
        if (tick != seen) {
            seen = tick;
            if (!thread.isAlive(id)) break;
        }
        riscv.waitForInterrupt();
        riscv.enableInterrupts();
    }
    const result = process.resultOf(id);
    if (result.kind != .exited or result.value == ~@as(u64, 0)) @panic("el programa de medida no termino bien");
    return result;
}

/// Lo que devuelven bench_xcall (en modo 1, el tiempo total) y bench_xserve.
const XRun = struct {
    total: u64,
    wake_sum: u64,
    wake_max: u64,
};

/// Un servidor y un cliente de llamadas, cada uno en su hart. Si `spin`, un
/// proceso de prioridad alta gira en el hart del servidor mientras se mide.
fn runXCall(client_hart: u64, server_hart: u64, rounds: u64, levels: [2]u64, spin: bool) XRun {
    const server = process.spawnWithOn(server_hart, .bench_xserve, 0, &.{endpointGrant(0, 0, recv_right)}) orelse @panic("no se pudo crear el proceso");
    // Presupuesto máximo: se mide el camino de la llamada, no la espera a que
    // se reponga un presupuesto (los procesos normales de Linux no tienen).
    thread.setParams(server, levels[1], abi.FB_SCHED_MAX_BUDGET);
    while (thread.state(server) != abi.FB_THREAD_BLOCKED) thread.yield();

    var spinner: u64 = 0;
    if (spin) {
        spinner = process.spawnWithOn(server_hart, .spin, 0, &.{}) orelse @panic("no se pudo crear el proceso");
        thread.setParams(spinner, abi.FB_PRIO_HIGH, 20 * abi.FB_SCHED_DEFAULT_BUDGET);
        // Que el proceso que gira ocupe ya su hart.
        const settle = timer.now() + 2 * abi.FB_TIMEBASE_HZ / 1000;
        while (timer.now() < settle) thread.yield();
    }

    const client = process.spawnWithOn(client_hart, .bench_xcall, rounds | 1 << 32, &.{endpointGrant(0, 0, send_right)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(client, levels[0], abi.FB_SCHED_MAX_BUDGET);
    const total = sleepUntilExit(client).value;
    if (spin) {
        process.requestKill(spinner);
        while (thread.isAlive(spinner)) thread.yield();
    }
    const served = waitForResult(server).value;
    return .{ .total = total, .wake_sum = served >> 32, .wake_max = served & 0xffff_ffff };
}

fn printNs(units: u64, operations: u64) void {
    uart.printDecimal(units * ns_per_unit / operations);
    uart.print(" ns");
}

fn sorted(values: [x_repeats]u64) [x_repeats]u64 {
    var out = values;
    std.mem.sort(u64, &out, {}, std.sort.asc(u64));
    return out;
}

/// Mínima, mediana y máxima de las repeticiones, por operación.
fn printSpread(values: [x_repeats]u64, operations: u64) void {
    const s = sorted(values);
    printNs(s[0], operations);
    uart.print(" (minima; mediana ");
    printNs(s[x_repeats / 2], operations);
    uart.print(", maxima ");
    printNs(s[x_repeats - 1], operations);
    uart.print(")");
}

fn measureRepeated(client_hart: u64, server_hart: u64, rounds: u64, levels: [2]u64, spin: bool) [3][x_repeats]u64 {
    var out: [3][x_repeats]u64 = undefined;
    for (0..x_repeats) |i| {
        const waits = kernel_lock.longWaits();
        const hart_waits = kernel_lock.longHartWaits();
        const run_ = runXCall(client_hart, server_hart, rounds, levels, spin);
        uart.print("  repeticion: ");
        printNs(run_.total, rounds);
        uart.print("/op, esperas largas al cerrojo global: ");
        uart.printDecimal(kernel_lock.longWaits() - waits);
        uart.print(", a los de hart: ");
        uart.printDecimal(kernel_lock.longHartWaits() - hart_waits);
        uart.print("\n");
        out[0][i] = run_.total;
        out[1][i] = run_.wake_sum;
        out[2][i] = run_.wake_max;
    }
    return out;
}

/// Ida y vuelta de una llamada, con cliente y servidor en los harts dados.
fn measurePingPong(name: []const u8, client_hart: u64, server_hart: u64) void {
    const levels = [2]u64{ abi.FB_PRIO_NORMAL, abi.FB_PRIO_NORMAL };
    const r = measureRepeated(client_hart, server_hart, x_rounds, levels, false);
    uart.print(name);
    uart.print(", ida y vuelta: ");
    printSpread(r[0], x_rounds);
    uart.print("; despertar al otro lado: ");
    printSpread(r[1], x_rounds);
    uart.print("; el peor ");
    printNs(sorted(r[2])[x_repeats - 1], 1);
    uart.print(" (");
    uart.printDecimal(x_repeats);
    uart.print(" x ");
    uart.printDecimal(x_rounds);
    uart.print(" ops)\n");
}

/// Inversión de prioridad entre harts: un cliente de prioridad máxima llama a
/// un servidor de prioridad mínima en otro hart, donde gira un proceso de
/// prioridad alta. Con la herencia del Hito 25 el servidor lo expropia. Lo
/// que se compara es cuánto tarda el servidor en empezar a correr: la vuelta
/// al cliente la alarga QEMU, que deja al hart que gira terminar su turno.
fn measureCrossInversion(server_hart: u64) void {
    const levels = [2]u64{ abi.FB_PRIO_TOP, abi.FB_PRIO_LOW };
    const r = measureRepeated(0, server_hart, inversion_rounds, levels, true);
    uart.print("inversion entre harts (cliente maxima, servidor minima, alta girando): el servidor corre a los ");
    printSpread(r[1], inversion_rounds);
    uart.print("; el peor ");
    printNs(sorted(r[2])[x_repeats - 1], 1);
    uart.print("; llamada completa ");
    printSpread(r[0], inversion_rounds);
    uart.print(" (");
    uart.printDecimal(x_repeats);
    uart.print(" x ");
    uart.printDecimal(inversion_rounds);
    uart.print(" ops)\n");
}

/// Un bucle de exactamente 2 instrucciones por vuelta: qué cuentan instret y
/// el reloj virtual mientras corre, con los demás harts en reposo o con uno
/// girando.
fn calibrate(name: []const u8) void {
    const start = instructions();
    const begin = timer.now();
    asm volatile (
        \\li t0, 1000000
        \\1: addi t0, t0, -1
        \\bnez t0, 1b
        ::: "t0");
    const counted = instructions() - start;
    const elapsed = timer.now() - begin;
    uart.print("calibracion, ");
    uart.print(name);
    uart.print(": bucle de 2000001 instrucciones; instret ");
    uart.printDecimal(counted);
    uart.print(", reloj virtual ");
    uart.printDecimal(elapsed * ns_per_unit);
    uart.print(" ns\n");
}

fn calibrateBusy(server_hart: u64) void {
    const spinner = process.spawnWithOn(server_hart, .spin, 0, &.{}) orelse @panic("no se pudo crear el proceso");
    const settle = timer.now() + abi.FB_TIMEBASE_HZ / 1000;
    while (timer.now() < settle) thread.yield();
    calibrate("con otro hart girando");
    process.requestKill(spinner);
    while (thread.isAlive(spinner)) thread.yield();
}

/// Se llama con los secundarios ya en línea.
var stale_go: u64 = 0;
var stale_seen: u64 = 0;

fn staleWatcher(_: u64) callconv(.c) void {
    while (@atomicLoad(u64, &stale_go, .acquire) == 0) {}
    @atomicStore(u64, &stale_seen, timer.now(), .release);
}

fn waitUntil(comptime what: []const u8, done: *const fn (u64) bool, id: u64) void {
    const limit = timer.now() + 20 * abi.FB_TIMEBASE_HZ;
    while (!done(id)) {
        if (timer.now() > limit) @panic("benchmark: no se llego a " ++ what);
        thread.yield();
    }
}

fn isBlocked(id: u64) bool {
    return thread.state(id) == abi.FB_THREAD_BLOCKED;
}

fn isTop(id: u64) bool {
    return thread.priorityOf(id) == abi.FB_PRIO_TOP;
}

fn isRunningOn2(id: u64) bool {
    return thread.runningOn(2) == id;
}

fn isDead(id: u64) bool {
    return !thread.isAlive(id);
}

fn isSeen(_: u64) bool {
    return @atomicLoad(u64, &stale_seen, .acquire) != 0;
}

/// Una vez: A (máxima, hart 0) -> B (hart 1) -> C (hart 2, ocupado `spin`
/// vueltas). En el hart de C espera un hilo normal. Se mata a A y se mide
/// cuánto tarda en correr ese hilo: lo que C sigue con la urgencia de A.
fn staleOnce(spin: u64) u64 {
    const a = process.spawnWithOn(0, .call_expect_peer, 0, &.{endpointGrant(0, 0, send_right)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(a, abi.FB_PRIO_TOP, abi.FB_SCHED_DEFAULT_BUDGET);
    waitUntil("bloquear al cliente", isBlocked, a);
    const c = process.spawnWithOn(2, .call_server_spin, spin, &.{endpointGrant(0, 1, recv_right)}) orelse @panic("no se pudo crear el proceso");
    thread.setParams(c, abi.FB_PRIO_LOW, abi.FB_SCHED_MAX_BUDGET);
    waitUntil("bloquear al servidor", isBlocked, c);
    @atomicStore(u64, &stale_go, 0, .release);
    @atomicStore(u64, &stale_seen, 0, .release);
    const x = thread.spawnKernelOn(2, staleWatcher, 0, .on) orelse @panic("no se pudo crear el hilo");
    thread.setParams(x, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);
    const b = process.spawnWithOn(1, .call_forwarder, 0, &.{ endpointGrant(0, 0, recv_right), endpointGrant(1, 1, send_right) }) orelse @panic("no se pudo crear el proceso");
    thread.setParams(b, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
    // C ya atiende a B con la urgencia de A, y el hilo normal no corre.
    waitUntil("heredar en la cadena", isTop, c);
    waitUntil("correr C en su hart", isRunningOn2, c);

    const start = timer.now();
    @atomicStore(u64, &stale_go, start, .release);
    process.requestKill(a);
    // Espera con wfi: con -icount QEMU reparte los harts por turnos, y girando
    // aquí el aviso al hart de C esperaría al final del turno de este. El hilo
    // apunta él mismo cuándo corre, así que el tick que nos despierta no cuenta.
    const limit = timer.now() + 20 * abi.FB_TIMEBASE_HZ;
    while (!isSeen(0)) {
        if (timer.now() > limit) @panic("benchmark: no se llego a correr el hilo normal");
        riscv.disableInterrupts();
        if (!isSeen(0)) riscv.waitForInterrupt();
        riscv.enableInterrupts();
    }
    const waited = @atomicLoad(u64, &stale_seen, .acquire) - start;

    process.requestKill(b);
    process.requestKill(c);
    waitUntil("terminar la cadena", isDead, a);
    waitUntil("terminar la cadena", isDead, b);
    waitUntil("terminar la cadena", isDead, c);
    waitUntil("terminar el hilo normal", isDead, x);
    return waited;
}

/// Lo heredado que sobra: cuánto espera un hilo normal del hart de C desde que
/// muere A hasta que corre.
fn measureStaleInheritance(harts: u64) void {
    if (harts < 3) return;
    const spin: u64 = 1 << 21;
    var waits: [x_repeats]u64 = undefined;
    for (&waits) |*w| w.* = staleOnce(spin);
    uart.print("herencia que sobra (A -> B -> C en tres harts, C ocupado ");
    uart.printDecimal(spin);
    uart.print(" vueltas, muere A): el hilo normal del hart de C corre a los ");
    printSpread(waits, 1);
    uart.print(" (5 veces)\n");
}

pub fn runSmp(harts: u64) void {
    uart.print("benchmark con ");
    uart.printDecimal(harts);
    uart.print(" harts\n");
    if (harts < 2) return;
    riscv.writeCsr("scounteren", (1 << 1) | (1 << 2));
    // Sin timer, un presupuesto agotado no se repone nunca y, con todos los
    // harts en wfi, la máquina se queda parada.
    if (!timer.running()) timer.init();
    calibrate("los demas harts en reposo");
    calibrateBusy(1);
    thread.setParams(0, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
    measurePingPong("llamada y respuesta, mismo hart", 0, 0);
    measurePingPong("llamada y respuesta entre harts", 0, 1);
    measureCrossInversion(1);
    measureStaleInheritance(harts);
    thread.setParams(0, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);
}
