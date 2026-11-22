// SPDX-License-Identifier: GPL-3.0-or-later
//! Autopruebas de la memoria compartida entre procesos (Hito 33).

const abi = @import("abi.zig").c;
const process = @import("process.zig");
const region = @import("region.zig");
const selftest_ipc = @import("selftest_ipc.zig");
const selftest_user = @import("selftest_user.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");
const trap = @import("trap.zig");
const uart = @import("uart.zig");

const page_size: u64 = abi.FB_PAGE_SIZE;
const shared_base: u64 = abi.FB_USER_SHARED_BASE;
const send: u64 = abi.FB_RIGHT_SEND;
const recv: u64 = abi.FB_RIGHT_RECV;
const grant: u64 = abi.FB_RIGHT_GRANT;

fn passed(name: []const u8) void {
    uart.print("[ok] ");
    uart.print(name);
    uart.print("\n");
}

fn regionCap(slot: u64, number: u64, rights: u64) process.Grant {
    return .{ .slot = slot, .kind = abi.FB_CAP_REGION, .object = region.object(number), .rights = rights };
}

fn createOrPanic(pages: u64) u64 {
    return region.create(pages) orelse @panic("no se pudo crear una region");
}

fn spawnOrPanic(target: u64, program: process.Program, argument: u64, grants: []const process.Grant) u64 {
    return process.spawnWithOn(target, program, argument, grants) orelse @panic("no se pudo crear el proceso");
}

fn waitDone(id: u64) process.Result {
    const limit = timer.now() + 20 * abi.FB_TIMEBASE_HZ;
    while (thread.isAlive(id)) {
        if (timer.now() > limit) @panic("un proceso de la memoria compartida no termino");
        thread.yield();
    }
    return process.resultOf(id);
}

fn expectExit(id: u64, code: u64, what: []const u8) void {
    const result = waitDone(id);
    if (result.kind != .exited or result.value != code) {
        uart.print(what);
        uart.print(": tipo ");
        uart.print(@tagName(result.kind));
        uart.print(", valor ");
        uart.printHex(result.value);
        uart.print("\n");
        @panic("un proceso de la memoria compartida termino mal");
    }
}

/// Un escritor y un lector de harts distintos comparten una región de dos
/// páginas: el lector ve exactamente lo que escribió el otro, sin copias. Al
/// morir los dos, la región se libera y sus marcos vuelven.
fn testSharedBetweenProcesses(harts: u64) void {
    const frames_before = selftest_user.poisonFreeFrames();
    const freed_before = region.freed();
    const number = createOrPanic(2);
    const words: u64 = 2 * page_size / 8;
    const other: u64 = harts - 1;

    const reader = spawnOrPanic(other, .shm_reader, 0, &.{ regionCap(0, number, recv), selftest_ipc.endpoint(1, 0, recv) });
    const writer = spawnOrPanic(0, .shm_writer, words, &.{ regionCap(0, number, send | recv), selftest_ipc.endpoint(1, 0, send) });
    region.release(number);
    expectExit(writer, 0, "escritor");
    expectExit(reader, 0, "lector");

    if (region.alive(number)) @panic("la region siguio viva sin nadie que la alcance");
    if (region.freed() != freed_before + 1) @panic("la region no se libero una vez");
    if (selftest_user.poisonFreeFrames() != frames_before) @panic("la memoria compartida perdio marcos");
    passed(if (harts > 1)
        "dos procesos de harts distintos comparten una region y sus marcos vuelven al terminar"
    else
        "dos procesos comparten una region y sus marcos vuelven al terminar");
}

/// Con una capability sin Send la región se mapea solo para leer: escribir
/// mata al proceso con un fallo de página en la región.
fn testReadOnlyCannotWrite() void {
    const number = createOrPanic(1);
    const id = spawnOrPanic(0, .shm_store, 0, &.{regionCap(0, number, recv)});
    region.release(number);
    const result = waitDone(id);
    if (result.kind != .faulted or result.value != trap.cause_store_page_fault or result.address != shared_base) {
        uart.print("tipo ");
        uart.print(@tagName(result.kind));
        uart.print(", scause ");
        uart.printHex(result.value);
        uart.print(", stval ");
        uart.printHex(result.address);
        uart.print("\n");
        @panic("escribir en una region de solo lectura no fallo como se esperaba");
    }
    if (region.alive(number)) @panic("la region de solo lectura siguio viva");

    // Y con Send sí puede: el mismo programa llega al final.
    const writable = createOrPanic(1);
    const ok = spawnOrPanic(0, .shm_store, 0, &.{regionCap(0, writable, send | recv)});
    region.release(writable);
    expectExit(ok, 99, "escritura permitida");
    passed("una region sin Send se mapea solo para leer: escribir es un fallo de pagina");
}

/// Mapear exige una capability de región con Recv, y no se puede mapear
/// encima de lo que ya está mapeado.
fn testMapNeedsCapability() void {
    // Sin nada en el hueco.
    expectExit(spawnOrPanic(0, .shm_map_status, 0, &.{}), abi.FB_ERR_CAP, "sin capability");
    // Una capability de otro tipo con el mismo objeto.
    expectExit(spawnOrPanic(0, .shm_map_status, 0, &.{selftest_ipc.endpoint(0, 0, send | recv)}), abi.FB_ERR_CAP, "endpoint");

    const number = createOrPanic(1);
    // Solo Send no basta: mapear exige Recv.
    expectExit(spawnOrPanic(0, .shm_map_status, 0, &.{regionCap(0, number, send)}), abi.FB_ERR_CAP, "solo send");
    // Dos veces en el mismo sitio.
    expectExit(spawnOrPanic(0, .shm_map_twice, 0, &.{regionCap(0, number, recv)}), abi.FB_ERR_BUSY, "dos veces");
    region.release(number);
    if (region.alive(number)) @panic("la region de las pruebas de derechos siguio viva");
    passed("mapear una region exige su capability con Recv y no pisa lo ya mapeado");
}

/// La capability de una región viaja por IPC como cualquier otra: quien la
/// recibe mapea la misma memoria y ve lo que escribió quien la envió.
fn testRegionTravelsByIpc(harts: u64) void {
    const number = createOrPanic(1);
    const words: u64 = page_size / 8;
    const taker = spawnOrPanic(harts - 1, .shm_taker, 0, &.{selftest_ipc.endpoint(1, 0, recv)});
    const giver = spawnOrPanic(0, .shm_giver, words, &.{ regionCap(0, number, send | recv | grant), selftest_ipc.endpoint(1, 0, send | grant) });
    region.release(number);
    expectExit(giver, 0, "quien envia");
    expectExit(taker, 0, "quien recibe");
    if (region.alive(number)) @panic("la region enviada por IPC siguio viva");
    passed("la capability de una region viaja por IPC y quien la recibe ve la misma memoria");
}

/// Mientras una capability la nombre, la región vive aunque nadie la tenga
/// mapeada; cuando muere el último que la tiene, se libera.
fn testCapabilityKeepsRegion() void {
    const number = createOrPanic(1);
    // Recién creada, aún sin capability ni nadie unido: la retiene el kernel.
    // Que muera otro proceso (y se busquen regiones que liberar) no la toca.
    expectExit(spawnOrPanic(0, .shm_map_status, 0, &.{}), abi.FB_ERR_CAP, "proceso ajeno");
    if (!region.alive(number)) @panic("se libero una region que el kernel aun retenia");
    const holder = spawnOrPanic(0, .sleep_forever, 0, &.{regionCap(0, number, recv)});
    region.release(number);
    if (!region.alive(number)) @panic("la region murio con una capability que la nombra");
    process.requestKill(holder);
    _ = waitDone(holder);
    if (region.alive(number)) @panic("la region siguio viva tras morir quien la tenia");
    passed("una region vive mientras alguna capability la nombre");
}

/// Una región nueva empieza a cero aunque sus marcos guarden datos de antes.
fn testNewRegionIsZero() void {
    const first = createOrPanic(abi.FB_USPACE_MAX_REGION_PAGES);
    var page: u64 = 0;
    while (page < abi.FB_USPACE_MAX_REGION_PAGES) : (page += 1) {
        const bytes: [*]u8 = @ptrFromInt(abi.fb_uspace_region_frame(first, page));
        @memset(bytes[0..page_size], 0x5a);
    }
    region.release(first);
    if (region.alive(first)) @panic("la region sin nadie no se libero");

    const second = createOrPanic(abi.FB_USPACE_MAX_REGION_PAGES);
    page = 0;
    while (page < abi.FB_USPACE_MAX_REGION_PAGES) : (page += 1) {
        const words: [*]const u64 = @ptrFromInt(abi.fb_uspace_region_frame(second, page));
        for (words[0 .. page_size / 8]) |word| {
            if (word != 0) @panic("una region nueva trajo datos de otra");
        }
    }
    region.release(second);
    passed("una region nueva empieza a cero");
}

/// Matar a un proceso que aún no ha corrido: su primera llamada es dormir
/// para siempre, y debe morir igual. Antes del Hito 33 la orden solo se
/// atendía en una interrupción o al despertar, y este proceso no moría nunca.
fn testKillBeforeBlocking() void {
    const id = spawnOrPanic(0, .sleep_forever, 0, &.{});
    process.requestKill(id);
    const result = waitDone(id);
    if (result.kind != .killed) @panic("un proceso al que se pidio morir antes de dormirse no murio como muerto");
    passed("un proceso al que se pide morir antes de bloquearse muere igual");
}

pub fn run(harts: u64) void {
    testKillBeforeBlocking();
    testSharedBetweenProcesses(harts);
    testReadOnlyCannotWrite();
    testMapNeedsCapability();
    testRegionTravelsByIpc(harts);
    testCapabilityKeepsRegion();
    testNewRegionIsZero();
}
