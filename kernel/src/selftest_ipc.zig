// SPDX-License-Identifier: GPL-3.0-or-later
//! Autopruebas de capabilities, IPC y del servicio de consola en modo usuario.

const abi = @import("abi.zig").c;
const process = @import("process.zig");
const selftest_user = @import("selftest_user.zig");
const syscall = @import("syscall.zig");
const thread = @import("thread.zig");
const uart = @import("uart.zig");

const Grant = process.Grant;

const send: u64 = abi.FB_RIGHT_SEND;
const recv: u64 = abi.FB_RIGHT_RECV;
const grant: u64 = abi.FB_RIGHT_GRANT;

pub fn passed(name: []const u8) void {
    uart.print("[ok] ");
    uart.print(name);
    uart.print("\n");
}

pub fn endpoint(slot: u64, object: u64, rights: u64) Grant {
    return .{ .slot = slot, .kind = abi.FB_CAP_ENDPOINT, .object = object, .rights = rights };
}

pub fn console(slot: u64) Grant {
    return .{ .slot = slot, .kind = abi.FB_CAP_CONSOLE, .object = 0, .rights = send };
}

pub fn start(program: process.Program, argument: u64, grants: []const Grant) u64 {
    return process.spawnWith(program, argument, grants) orelse @panic("no se pudo crear el proceso");
}

pub fn waitBlocked(id: u64) void {
    while (thread.state(id) != abi.FB_THREAD_BLOCKED) {
        if (!thread.isAlive(id)) {
            const result = process.resultOf(id);
            uart.print("tipo: ");
            uart.print(@tagName(result.kind));
            uart.print(", valor: ");
            uart.printHex(result.value);
            uart.print(", direccion: ");
            uart.printHex(result.address);
            uart.print("\n");
            @panic("el proceso murio antes de bloquearse");
        }
        thread.yield();
    }
}

pub fn expectExit(id: u64, program: process.Program, code: u64) void {
    while (thread.isAlive(id)) thread.yield();
    const result = process.resultOf(id);
    if (result.kind != .exited or result.value != code) {
        uart.print("programa: ");
        uart.print(@tagName(program));
        uart.print(", tipo: ");
        uart.print(@tagName(result.kind));
        uart.print(", valor: ");
        uart.printHex(result.value);
        uart.print("\n");
        @panic("un programa de IPC termino de forma inesperada");
    }
}

pub fn run1(program: process.Program, code: u64, grants: []const Grant) void {
    expectExit(start(program, 0, grants), program, code);
}

pub fn expectEqual(actual: u64, expected: u64) void {
    if (actual != expected) @panic("resultado inesperado de capabilities o IPC");
}

fn expectLastWrite(expected: []const u8) void {
    const actual = syscall.lastWrite();
    if (actual.len != expected.len) @panic("el servicio no escribio lo esperado");
    for (expected, actual) |wanted, byte| {
        if (wanted != byte) @panic("el servicio no escribio lo esperado");
    }
}

fn testCapabilityGate() void {
    const kind = abi.FB_CAP_ENDPOINT;
    const ok = abi.FB_CAP_OK;
    const invalid = abi.FB_CAP_INVALID;
    const denied = abi.FB_CAP_DENIED;
    const occupied = abi.FB_CAP_OCCUPIED;
    const none = abi.FB_CAP_NO_OBJECT;

    expectEqual(abi.fb_cap_grant(0, 0, kind, 0, send), invalid);
    expectEqual(abi.fb_cap_grant(5, 0, kind, 0, send), invalid);
    expectEqual(abi.fb_cap_grant(1, 16, kind, 0, send), invalid);
    expectEqual(abi.fb_cap_grant(1, 0, 0, 0, send), invalid);
    expectEqual(abi.fb_cap_grant(1, 0, abi.FB_CAP_REGION + 1, 0, send), invalid);
    expectEqual(abi.fb_cap_grant(1, 0, kind, 4, send), invalid);
    expectEqual(abi.fb_cap_grant(1, 0, kind, 0, 8), invalid);

    expectEqual(abi.fb_cap_grant(1, 0, kind, 2, send), ok);
    expectEqual(abi.fb_cap_grant(1, 0, kind, 2, send), occupied);

    expectEqual(abi.fb_cap_check(1, 0, kind, send), 2);
    expectEqual(abi.fb_cap_check(1, 0, kind, recv), none);
    expectEqual(abi.fb_cap_check(1, 0, abi.FB_CAP_CONSOLE, send), none);
    expectEqual(abi.fb_cap_check(1, 1, kind, send), none);
    expectEqual(abi.fb_cap_check(0, 0, kind, send), none);
    expectEqual(abi.fb_cap_check(1, 16, kind, send), none);
    expectEqual(abi.fb_cap_check(2, 0, kind, send), none);

    expectEqual(abi.fb_cap_derive(1, 0, 1, send | recv), denied);
    expectEqual(abi.fb_cap_derive(1, 0, 1, send), ok);
    expectEqual(abi.fb_cap_derive(1, 0, 1, send), occupied);
    expectEqual(abi.fb_cap_derive(1, 5, 2, send), denied);
    expectEqual(abi.fb_cap_derive(1, 0, 2, 8), invalid);

    expectEqual(abi.fb_cap_transfer(1, 0, 2, 3), ok);
    expectEqual(abi.fb_cap_check(2, 3, kind, send), 2);
    expectEqual(abi.fb_cap_check(2, 3, kind, recv), none);
    expectEqual(abi.fb_cap_transfer(1, 0, 2, 3), occupied);
    expectEqual(abi.fb_cap_transfer(1, 7, 2, 4), denied);
    expectEqual(abi.fb_cap_transfer(0, 0, 2, 4), invalid);

    expectEqual(abi.fb_cap_delete(1, 1), ok);
    expectEqual(abi.fb_cap_delete(1, 1), denied);
    expectEqual(abi.fb_cap_clear(1), ok);
    expectEqual(abi.fb_cap_clear(2), ok);
    expectEqual(abi.fb_cap_clear(0), invalid);
    expectEqual(abi.fb_cap_held(1, 0), 0);
    expectEqual(abi.fb_cap_held(2, 3), 0);
    passed("las capabilities rechazan peticiones invalidas");
}

fn testIpcGate() void {
    const queued = abi.FB_IPC_QUEUED;
    const invalid = abi.FB_IPC_INVALID;

    expectEqual(abi.fb_ipc_send(4, 1), invalid);
    expectEqual(abi.fb_ipc_send(0, 0), invalid);
    expectEqual(abi.fb_ipc_send(0, 8), invalid);

    expectEqual(abi.fb_ipc_send(0, 5), queued);
    expectEqual(abi.fb_ipc_send(0, 5), invalid);
    expectEqual(abi.fb_ipc_recv(1, 5), invalid);
    expectEqual(abi.fb_ipc_recv(0, 6), 5);
    expectEqual(abi.fb_ipc_cancel(5), abi.FB_IPC_NOT_WAITING);

    expectEqual(abi.fb_ipc_recv(1, 3), queued);
    expectEqual(abi.fb_ipc_cancel(3), abi.FB_IPC_OK);
    expectEqual(abi.fb_ipc_cancel(3), abi.FB_IPC_NOT_WAITING);
    expectEqual(abi.fb_ipc_cancel(0), abi.FB_IPC_CANCEL_INVALID);

    expectEqual(abi.fb_ipc_send(2, 1), queued);
    expectEqual(abi.fb_ipc_send(2, 2), queued);
    expectEqual(abi.fb_ipc_send(2, 3), queued);
    expectEqual(abi.fb_ipc_cancel(2), abi.FB_IPC_OK);
    expectEqual(abi.fb_ipc_recv(2, 7), 1);
    expectEqual(abi.fb_ipc_recv(2, 7), 3);
    expectEqual(abi.fb_ipc_recv(2, 7), queued);
    expectEqual(abi.fb_ipc_cancel(7), abi.FB_IPC_OK);
    passed("las colas de IPC rechazan peticiones invalidas");
}

fn testNoAuthorityWithoutCapabilities() void {
    run1(.no_caps, 0, &.{});
    passed("sin capabilities un proceso no puede actuar");
}

fn testRightsAreEnforced() void {
    run1(.cap_rights, 0, &.{ endpoint(0, 0, send), console(1) });
    passed("los derechos no se pueden ampliar desde modo usuario");
}

const service_message = "cliente via IPC\n";

/// El cliente no tiene consola: solo puede escribir pidiéndoselo al servicio.
fn testConsoleService() void {
    const server_grants = [_]Grant{ endpoint(0, 0, recv), console(1) };
    const client_grants = [_]Grant{endpoint(0, 0, send)};

    // El servicio llega primero y espera.
    const server = start(.console_server, 0, &server_grants);
    waitBlocked(server);
    const client = start(.console_client, 0, &client_grants);
    expectExit(client, .console_client, 0);
    expectExit(server, .console_server, 0);
    expectLastWrite(service_message);

    // El cliente llega primero y espera.
    const early_client = start(.console_client, 0, &client_grants);
    waitBlocked(early_client);
    const late_server = start(.console_server, 0, &server_grants);
    expectExit(early_client, .console_client, 0);
    expectExit(late_server, .console_server, 0);
    expectLastWrite(service_message);
    passed("servicio de consola por IPC en modo usuario");
}

fn testPingPong() void {
    const pong = start(.pong, 0, &.{ endpoint(0, 1, recv), endpoint(1, 2, send) });
    const ping = start(.ping, 0, &.{ endpoint(0, 1, send), endpoint(1, 2, recv) });
    expectExit(ping, .ping, 0);
    expectExit(pong, .pong, 0);
    passed("mensajes de ida y vuelta entre procesos");
}

fn testCapabilityTransfer() void {
    const grantee = start(.grantee, 0, &.{endpoint(0, 3, recv)});
    waitBlocked(grantee);
    const granter = start(.granter, 0, &.{ endpoint(0, 3, send | grant), console(1) });
    expectExit(granter, .granter, 0);
    expectExit(grantee, .grantee, 0);
    expectLastWrite("capability concedida\n");
    passed("cesion de capabilities por IPC");
}

/// Tres emisores en cola: el receptor debe verlos en orden de llegada.
fn testFifoOrder() void {
    var senders: [3]u64 = undefined;
    for (&senders, 1..) |*id, value| {
        id.* = start(.ipc_sender, value, &.{endpoint(0, 3, send)});
        waitBlocked(id.*);
    }
    const receiver = start(.ipc_fifo_receiver, 0, &.{endpoint(0, 3, recv)});
    expectExit(receiver, .ipc_fifo_receiver, 123);
    for (senders) |id| expectExit(id, .ipc_sender, 0);
    passed("los emisores se atienden en orden de llegada");
}

fn testKillWhileBlocked() void {
    const id = start(.ipc_blocked, 0, &.{endpoint(0, 0, recv)});
    waitBlocked(id);
    process.requestKill(id);
    while (thread.isAlive(id)) thread.yield();
    if (process.resultOf(id).kind != .killed) @panic("el proceso bloqueado no murio");

    // La cola debe haber quedado limpia: el endpoint sigue funcionando.
    testPingPongOnEndpointZero();
    passed("se puede matar a un proceso bloqueado en IPC");
}

fn testPingPongOnEndpointZero() void {
    const server = start(.console_server, 0, &.{ endpoint(0, 0, recv), console(1) });
    const client = start(.console_client, 0, &.{endpoint(0, 0, send)});
    expectExit(client, .console_client, 0);
    expectExit(server, .console_server, 0);
}

fn testCapabilitiesDieWithTheProcess() void {
    // Reutiliza espacios: si las tablas no se vaciaran, no podría volver a concederse.
    for (0..16) |_| {
        run1(.no_caps, 0, &.{});
        run1(.cap_rights, 0, &.{ endpoint(0, 0, send), console(1) });
    }
    passed("las capabilities mueren con su proceso");
}

pub fn run() void {
    testCapabilityGate();
    testIpcGate();

    const frames_before = selftest_user.poisonFreeFrames();
    testNoAuthorityWithoutCapabilities();
    testRightsAreEnforced();
    testConsoleService();
    testPingPong();
    testCapabilityTransfer();
    testFifoOrder();
    testKillWhileBlocked();
    testCapabilitiesDieWithTheProcess();
    if (selftest_user.poisonFreeFrames() != frames_before) @panic("el IPC perdio marcos");
    passed("todos los marcos vuelven tras las pruebas de IPC");
}
