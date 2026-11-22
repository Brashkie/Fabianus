// SPDX-License-Identifier: GPL-3.0-or-later
//! Autopruebas del modo usuario, los espacios de direcciones y las llamadas al sistema.

const abi = @import("abi.zig").c;
const paging = @import("paging.zig");
const process = @import("process.zig");
const riscv = @import("riscv.zig");
const syscall = @import("syscall.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");
const trap = @import("trap.zig");
const uart = @import("uart.zig");

const page_size: u64 = abi.FB_PAGE_SIZE;
const megapage_size: u64 = abi.FB_MEGAPAGE_SIZE;
const user_base: u64 = abi.FB_USER_BASE;
const user_limit: u64 = abi.FB_USER_LIMIT;
const user_stack_top: u64 = abi.FB_USER_STACK_TOP;
const user_stack_pages: u64 = abi.FB_USER_STACK_PAGES;
const max_spaces: u64 = abi.FB_USPACE_MAX;
const max_leaf_tables: u64 = abi.FB_USPACE_MAX_LEAF_TABLES;
const uart_address: u64 = abi.FB_UART0_BASE;
const kernel_address: u64 = 0x80000000;

fn passed(name: []const u8) void {
    uart.print("[ok] ");
    uart.print(name);
    uart.print("\n");
}

fn spawnOrPanic(program: process.Program, argument: u64) u64 {
    return process.spawn(program, argument) orelse @panic("no se pudo crear el proceso");
}

fn waitFor(id: u64) process.Result {
    while (thread.isAlive(id)) thread.yield();
    return process.resultOf(id);
}

fn expectExit(program: process.Program, code: u64) void {
    expectExitWith(program, code, &.{});
}

fn expectExitWith(program: process.Program, code: u64, grants: []const process.Grant) void {
    const id = process.spawnWith(program, 0, grants) orelse @panic("no se pudo crear el proceso");
    const result = waitFor(id);
    if (result.kind != .exited or result.value != code) {
        uart.print("programa: ");
        uart.print(@tagName(program));
        uart.print(", valor: ");
        uart.printHex(result.value);
        uart.print("\n");
        @panic("un programa de usuario termino de forma inesperada");
    }
}

fn expectEqual(actual: u64, expected: u64) void {
    if (actual != expected) @panic("resultado inesperado de los espacios de usuario");
}

fn expectMapped(value: u64) void {
    if (value < page_size) @panic("no se pudo mapear la pagina");
}

/// Con interrupciones apagadas: los espacios de usuario no son reentrantes.
fn testGateRejectsInvalidRequests() void {
    const space = abi.fb_uspace_create();
    if (space == 0) @panic("no se pudo crear el espacio");
    const rw = abi.FB_PERM_READ_WRITE;

    expectEqual(abi.fb_uspace_map(0, user_base, rw), abi.FB_USPACE_INVALID);
    expectEqual(abi.fb_uspace_map(max_spaces + 1, user_base, rw), abi.FB_USPACE_INVALID);
    expectEqual(abi.fb_uspace_map(space, user_base + 1, rw), abi.FB_USPACE_INVALID);
    expectEqual(abi.fb_uspace_map(space, kernel_address, rw), abi.FB_USPACE_INVALID);
    expectEqual(abi.fb_uspace_map(space, user_base - page_size, rw), abi.FB_USPACE_INVALID);
    expectEqual(abi.fb_uspace_map(space, user_limit, rw), abi.FB_USPACE_INVALID);
    expectEqual(abi.fb_uspace_map(space, user_base, 0), abi.FB_USPACE_INVALID);
    expectEqual(abi.fb_uspace_map(space, user_base, 4), abi.FB_USPACE_INVALID);

    expectMapped(abi.fb_uspace_map(space, user_base, abi.FB_PERM_READ));
    expectEqual(abi.fb_uspace_map(space, user_base, rw), abi.FB_USPACE_CONFLICT);

    if (abi.fb_uspace_translate(space, user_base, abi.FB_ACCESS_READ) == 0) @panic("traduccion ausente");
    expectEqual(abi.fb_uspace_translate(space, user_base, abi.FB_ACCESS_WRITE), 0);
    expectEqual(abi.fb_uspace_translate(space, user_base, 0), 0);
    expectEqual(abi.fb_uspace_translate(space, user_base + page_size, abi.FB_ACCESS_READ), 0);
    expectEqual(abi.fb_uspace_translate(space, kernel_address, abi.FB_ACCESS_READ), 0);
    expectEqual(abi.fb_uspace_translate(space + 1, user_base, abi.FB_ACCESS_READ), 0);

    // Una tabla hoja cubre 2 MiB: la primera ya está en uso.
    var region: u64 = 1;
    while (region < max_leaf_tables) : (region += 1) {
        expectMapped(abi.fb_uspace_map(space, user_base + region * megapage_size, rw));
    }
    expectEqual(abi.fb_uspace_map(space, user_base + region * megapage_size, rw), abi.FB_USPACE_NO_SPACE);

    expectEqual(abi.fb_uspace_destroy(space), abi.FB_USPACE_OK);
    expectEqual(abi.fb_uspace_destroy(space), abi.FB_USPACE_INVALID);
    expectEqual(abi.fb_uspace_destroy(0), abi.FB_USPACE_INVALID);
    expectEqual(abi.fb_uspace_translate(space, user_base, abi.FB_ACCESS_READ), 0);
    passed("los espacios de usuario rechazan peticiones invalidas");
}

/// Sstatus.SUM está a cero: ni el kernel puede leer una página de usuario por su
/// dirección virtual. La única vía es la traducción demostrada.
fn testKernelCannotDereferenceUserPages() void {
    const space = abi.fb_uspace_create();
    if (space == 0) @panic("no se pudo crear el espacio");
    expectMapped(abi.fb_uspace_map(space, user_base, abi.FB_PERM_READ_WRITE));

    paging.activate(paging.satpFor(abi.fb_uspace_root(space)));
    const target: *volatile u64 = @ptrFromInt(user_base);
    trap.expectException(trap.cause_load_page_fault);
    _ = target.*;
    const faulted = trap.expectedExceptionSeen();
    paging.activate(paging.kernelSatp());

    if (!faulted) @panic("el kernel pudo leer una pagina de usuario");
    expectEqual(abi.fb_uspace_destroy(space), abi.FB_USPACE_OK);
    passed("el kernel no accede a paginas de usuario por su direccion");
}

/// Pide todos los marcos libres, los llena de basura y los devuelve.
/// Cada marco guarda en su primera palabra el anterior de la lista.
pub fn poisonFreeFrames() u64 {
    var head: u64 = 0;
    var count: u64 = 0;
    while (true) : (count += 1) {
        const address = abi.fb_frames_alloc();
        if (address == 0) break;
        const words: [*]u64 = @ptrFromInt(address);
        @memset(words[0 .. page_size / 8], 0xaaaaaaaaaaaaaaaa);
        words[0] = head;
        head = address;
    }
    while (head != 0) {
        const words: [*]const u64 = @ptrFromInt(head);
        const next = words[0];
        if (abi.fb_frames_free(head) != abi.FB_FRAMES_OK) @panic("fallo al liberar un marco");
        head = next;
    }
    return count;
}

fn expectLastWrite(expected: []const u8) void {
    const actual = syscall.lastWrite();
    if (actual.len != expected.len) @panic("el proceso no escribio lo esperado");
    for (expected, actual) |wanted, byte| {
        if (wanted != byte) @panic("el proceso no escribio lo esperado");
    }
}

fn testHello() void {
    expectExitWith(.hello, 7, &process.console_grant);
    expectLastWrite("hola desde modo usuario\n");
    passed("programa en modo usuario con write y exit");
}

fn testRegistersSurviveSyscall() void {
    expectExit(.registers, 0);
    passed("el usuario empieza sin datos del kernel y sus registros se conservan");
}

fn testMemoryIsZeroed() void {
    expectExit(.zerocheck, 0);
    passed("la memoria entregada al usuario esta borrada");
}

const FaultCase = struct {
    program: process.Program,
    cause: u64,
    address: ?u64 = null,
};

const stack_bottom: u64 = user_stack_top - user_stack_pages * page_size;

const fault_cases = [_]FaultCase{
    .{ .program = .fault_csr, .cause = trap.cause_illegal_instruction },
    .{ .program = .fault_sret, .cause = trap.cause_illegal_instruction },
    .{ .program = .fault_load_kernel, .cause = trap.cause_load_page_fault, .address = kernel_address },
    .{ .program = .fault_store_kernel, .cause = trap.cause_store_page_fault, .address = kernel_address },
    .{ .program = .fault_jump_kernel, .cause = trap.cause_instruction_page_fault, .address = kernel_address },
    .{ .program = .fault_store_text, .cause = trap.cause_store_page_fault, .address = user_base },
    .{ .program = .fault_exec_stack, .cause = trap.cause_instruction_page_fault, .address = user_stack_top - 16 },
    .{ .program = .fault_stack_guard, .cause = trap.cause_store_page_fault, .address = stack_bottom - 8 },
    .{ .program = .fault_device, .cause = trap.cause_store_page_fault, .address = uart_address },
};

fn testFaultsKillOnlyTheProcess() void {
    for (fault_cases) |case| {
        const result = waitFor(spawnOrPanic(case.program, 0));
        const address_ok = if (case.address) |address| result.address == address else true;
        if (result.kind != .faulted or result.value != case.cause or !address_ok) {
            uart.print("programa: ");
            uart.print(@tagName(case.program));
            uart.print(", scause: ");
            uart.printHex(result.value);
            uart.print(", stval: ");
            uart.printHex(result.address);
            uart.print("\n");
            @panic("un acceso prohibido no se comporto como se esperaba");
        }
    }
    passed("los accesos prohibidos solo matan al proceso");
}

fn testKernelIsNotADeputy() void {
    expectExitWith(.deputy, 0, &process.console_grant);
    // La última escritura cruza dos páginas; las rechazadas no dejaron rastro.
    expectLastWrite("...............\n");
    passed("el kernel rechaza punteros ajenos en las llamadas");
}

fn testSpacesAreIsolated() void {
    const first = spawnOrPanic(.isolated, 0x1111);
    const second = spawnOrPanic(.isolated, 0x2222222);
    const va = user_stack_top - page_size;
    const first_page = abi.fb_uspace_translate(process.spaceOf(first), va, abi.FB_ACCESS_WRITE);
    const second_page = abi.fb_uspace_translate(process.spaceOf(second), va, abi.FB_ACCESS_WRITE);
    if (first_page == 0 or second_page == 0 or first_page == second_page) {
        @panic("dos espacios comparten una pagina");
    }

    const first_result = waitFor(first);
    const second_result = waitFor(second);
    if (first_result.kind != .exited or first_result.value != 0 or
        second_result.kind != .exited or second_result.value != 0)
    {
        @panic("un proceso vio la memoria de otro");
    }
    passed("dos procesos con la misma direccion no se ven");
}

/// Los procesos nunca ceden: solo el timer les quita la CPU. Si el usuario
/// pudiera acapararla, el hilo principal no volvería a ejecutarse.
fn testUserCannotKeepTheCpu() void {
    const minimum_preemptions: u64 = 12;
    const limit = abi.FB_TIMEBASE_HZ * 20;

    const first = spawnOrPanic(.spin, 0);
    const second = spawnOrPanic(.spin, 0);
    const before = thread.preemptions();
    const start = timer.now();

    riscv.enableInterrupts();
    while (thread.preemptions() - before < minimum_preemptions) {
        if (timer.now() - start > limit) @panic("el usuario acaparo la CPU");
    }
    process.requestKill(first);
    process.requestKill(second);
    // Cada fase tiene su propio límite: en una CPU lenta la primera puede
    // gastar casi todo el suyo.
    const kill_start = timer.now();
    while (thread.isAlive(first) or thread.isAlive(second)) {
        if (timer.now() - kill_start > limit) @panic("los procesos no murieron");
    }
    riscv.disableInterrupts();

    if (process.resultOf(first).kind != .killed or process.resultOf(second).kind != .killed) {
        @panic("un proceso expropiado vio sus registros alterados");
    }
    uart.print("[ok] el timer expropia al usuario, cambios: ");
    uart.printDecimal(thread.preemptions() - before);
    uart.print("\n");
}

fn testResourcesAreExhaustedAndReused() void {
    var ids: [max_spaces]u64 = undefined;
    for (&ids) |*id| id.* = spawnOrPanic(.registers, 0);
    if (process.spawn(.registers, 0) != null) @panic("se crearon procesos de mas");
    for (ids) |id| _ = waitFor(id);

    for (0..32) |_| expectExit(.registers, 0);
    passed("agotamiento y reutilizacion de espacios");
}

pub fn run() void {
    testGateRejectsInvalidRequests();
    testKernelCannotDereferenceUserPages();

    // Toda la memoria libre queda sucia: si algo no se borra, zerocheck lo verá.
    const frames_before = poisonFreeFrames();

    testHello();
    testRegistersSurviveSyscall();
    // Otra vez, ya tras ejecutar procesos: entrar en modo usuario no debe activar SUM.
    testKernelCannotDereferenceUserPages();
    testMemoryIsZeroed();
    testFaultsKillOnlyTheProcess();
    testKernelIsNotADeputy();
    testSpacesAreIsolated();
    testUserCannotKeepTheCpu();
    testResourcesAreExhaustedAndReused();

    if (poisonFreeFrames() != frames_before) @panic("los procesos perdieron marcos");
    passed("todos los marcos vuelven al terminar los procesos");
}
