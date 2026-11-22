// SPDX-License-Identifier: GPL-3.0-or-later
//! Autopruebas del disco virtio-blk y de su driver en Rust (Hito 34).

const abi = @import("abi.zig").c;
const device = @import("device.zig");
const process = @import("process.zig");
const riscv = @import("riscv.zig");
const region = @import("region.zig");
const selftest_ipc = @import("selftest_ipc.zig");
const selftest_user = @import("selftest_user.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");
const uart = @import("uart.zig");

const send: u64 = abi.FB_RIGHT_SEND;
const recv: u64 = abi.FB_RIGHT_RECV;

/// Bits del registro Status de virtio: el driver terminó de arrancarlo.
const status_driver_ok: u32 = 4;

fn passed(name: []const u8) void {
    uart.print("[ok] ");
    uart.print(name);
    uart.print("\n");
}

fn regionCap(slot: u64, number: u64, rights: u64) process.Grant {
    return .{ .slot = slot, .kind = abi.FB_CAP_REGION, .object = region.object(number), .rights = rights };
}

fn diskCap(slot: u64, rights: u64) process.Grant {
    return .{ .slot = slot, .kind = abi.FB_CAP_DEVICE, .object = abi.FB_DEVICE_DISK, .rights = rights };
}

fn createOrPanic(pages: u64) u64 {
    return region.create(pages) orelse @panic("no se pudo crear una region para el disco");
}

fn spawnOrPanic(target: u64, program: process.Program, argument: u64, grants: []const process.Grant) u64 {
    return process.spawnWithOn(target, program, argument, grants) orelse @panic("no se pudo crear el proceso");
}

/// Espera con las interrupciones encendidas, como las pruebas de la UART:
/// las del disco llegan al hart 0, y si este hilo las tuviera apagadas
/// mientras los demás esperan, nadie las tomaría.
fn waitDone(id: u64) process.Result {
    const limit = timer.now() + 20 * abi.FB_TIMEBASE_HZ;
    riscv.enableInterrupts();
    defer riscv.disableInterrupts();
    while (thread.isAlive(id)) {
        if (timer.now() > limit) @panic("un proceso del disco no termino");
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
        @panic("un proceso del disco termino mal");
    }
}

/// Lanza el driver con su cola y la región de datos. Devuelve el hilo.
fn startDriver(target: u64, queue: u64, data: u64) u64 {
    return spawnOrPanic(target, .disk_driver, 0, &.{
        selftest_ipc.endpoint(0, 0, recv),
        diskCap(1, send | recv),
        selftest_ipc.endpoint(2, 1, recv),
        regionCap(3, queue, send | recv),
        regionCap(4, data, send | recv),
    });
}

/// Espera a que el driver haya arrancado el disco y esté esperando peticiones.
fn waitDriverReady(id: u64) void {
    const limit = timer.now() + 20 * abi.FB_TIMEBASE_HZ;
    riscv.enableInterrupts();
    defer riscv.disableInterrupts();
    while (device.diskStatus() & status_driver_ok == 0 or thread.state(id) != abi.FB_THREAD_BLOCKED) {
        if (!thread.isAlive(id)) {
            const result = process.resultOf(id);
            uart.print("el driver salio con ");
            uart.printHex(result.value);
            uart.print("\n");
            @panic("el driver del disco no arranco");
        }
        if (timer.now() > limit) @panic("el driver del disco no llego a esperar peticiones");
        thread.yield();
    }
}

/// Un cliente lee y escribe el disco a través del driver en Rust, con los
/// datos en una región que comparten: el disco los mueve por DMA, sin copias.
/// Al parar, el disco queda reiniciado, las regiones se liberan y los marcos
/// vuelven.
fn testDiskThroughDriver(harts: u64) void {
    const frames_before = selftest_user.poisonFreeFrames();
    const queue = createOrPanic(1);
    const data = createOrPanic(4);
    const driver = startDriver(harts - 1, queue, data);
    const client = spawnOrPanic(0, .disk_check, 1, &.{ selftest_ipc.endpoint(0, 0, send), regionCap(1, data, send | recv) });
    region.release(queue);
    region.release(data);

    const client_result = waitDone(client);
    if (client_result.kind != .exited or client_result.value != 0) {
        uart.print("cliente del disco: paso ");
        uart.printDecimal(client_result.value >> 56);
        uart.print(", a1 ");
        uart.printHex((client_result.value >> 8) & 0xff);
        uart.print(", a0 ");
        uart.printHex(client_result.value & 0xff);
        uart.print("; driver vivo: ");
        uart.print(if (thread.isAlive(driver)) "si" else "no");
        uart.print(", salida ");
        uart.printHex(process.resultOf(driver).value);
        uart.print(", estado del disco ");
        uart.printHex(device.diskStatus());
        uart.print("\n");
        @panic("el cliente del disco fallo");
    }
    expectExit(driver, 0, "driver del disco");
    if (device.ownerOf(abi.FB_DEVICE_DISK) != 0) @panic("el disco siguio teniendo dueno");
    if (device.diskStatus() != 0) @panic("el disco no quedo reiniciado");
    if (region.alive(queue) or region.alive(data)) @panic("las regiones del disco siguieron vivas");
    if (selftest_user.poisonFreeFrames() != frames_before) @panic("el disco perdio marcos");
    passed(if (harts > 1)
        "el driver de disco en Rust (en otro hart) lee y escribe por DMA en la region del cliente"
    else
        "el driver de disco en Rust lee y escribe por DMA en la region del cliente");
}

/// Si el driver muere con el disco arrancado, el kernel lo reinicia antes de
/// liberar su memoria: ningún DMA puede caer en marcos que ya son de otro.
fn testDriverDeathResetsDisk() void {
    const queue = createOrPanic(1);
    const data = createOrPanic(1);
    const driver = startDriver(0, queue, data);
    region.release(queue);
    region.release(data);
    waitDriverReady(driver);

    process.requestKill(driver);
    const result = waitDone(driver);
    if (result.kind != .killed) @panic("el driver del disco no murio como muerto");
    if (device.diskStatus() != 0) @panic("muerto el driver, el disco no quedo reiniciado");
    if (device.ownerOf(abi.FB_DEVICE_DISK) != 0) @panic("muerto el driver, el disco siguio teniendo dueno");
    if (region.alive(queue) or region.alive(data)) @panic("muerto el driver, sus regiones siguieron vivas");
    passed("si el driver del disco muere, el kernel reinicia el disco antes de liberar su memoria");
}

/// La dirección física de una página solo se da a quien tiene los registros
/// del disco (su capability con Send) y está unido a la región.
fn testDmaAddressGuarded() void {
    const number = createOrPanic(1);
    const expected = abi.fb_uspace_region_frame(number, 0);
    const both = regionCap(0, number, send | recv);

    // Sin capability del disco.
    expectExit(spawnOrPanic(0, .dma_status, 3, &.{both}), abi.FB_ERR_CAP, "sin disco");
    // Con la de la UART.
    expectExit(spawnOrPanic(0, .dma_status, 3, &.{ both, .{ .slot = 1, .kind = abi.FB_CAP_DEVICE, .object = abi.FB_DEVICE_UART, .rights = send } }), abi.FB_ERR_CAP, "con la UART");
    // Con la del disco sin Send.
    expectExit(spawnOrPanic(0, .dma_status, 3, &.{ both, diskCap(1, recv) }), abi.FB_ERR_CAP, "disco sin send");
    // Con la del disco, pero sin haber mapeado sus registros.
    expectExit(spawnOrPanic(0, .dma_status, 2, &.{ both, diskCap(1, send) }), abi.FB_ERR_INVALID, "sin registros");
    // Con los registros, pero sin estar unido a la región.
    expectExit(spawnOrPanic(0, .dma_status, 1, &.{ both, diskCap(1, send) }), abi.FB_ERR_INVALID, "sin unirse");
    // Con todo: la dirección física de la página.
    expectExit(spawnOrPanic(0, .dma_status, 3, &.{ both, diskCap(1, send) }), expected, "con todo");

    region.release(number);
    if (region.alive(number)) @panic("la region de las pruebas de DMA siguio viva");
    passed("la direccion fisica de una pagina solo la conoce quien tiene el disco y esta unido a la region");
}

pub fn run(harts: u64) void {
    // Sin disco, las pruebas no se saltan: se para (QEMU necesita -drive y
    // -device virtio-blk-device,bus=virtio-mmio-bus.0; lo pone zig build run).
    if (!device.diskPresent()) @panic("no hay disco virtio en la primera ranura");
    testDmaAddressGuarded();
    testDiskThroughDriver(harts);
    testDriverDeathResetsDisk();
}
