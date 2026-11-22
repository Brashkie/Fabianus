// SPDX-License-Identifier: GPL-3.0-or-later
//! Autopruebas de la cesión de dispositivos y del driver de UART en Rust.
//!
//! Mientras un driver tiene la UART, el kernel no imprime: los resultados se
//! anuncian cuando el driver ya ha terminado.

const abi = @import("abi.zig").c;
const device_module = @import("device.zig");
const process = @import("process.zig");
const riscv = @import("riscv.zig");
const selftest_ipc = @import("selftest_ipc.zig");
const selftest_user = @import("selftest_user.zig");
const syscall = @import("syscall.zig");
const thread = @import("thread.zig");
const uart = @import("uart.zig");

const Grant = process.Grant;
const endpoint = selftest_ipc.endpoint;
const console = selftest_ipc.console;
const start = selftest_ipc.start;
const passed = selftest_ipc.passed;
const waitBlocked = selftest_ipc.waitBlocked;
const expectEqual = selftest_ipc.expectEqual;

const send: u64 = abi.FB_RIGHT_SEND;
const recv: u64 = abi.FB_RIGHT_RECV;

const device_base: u64 = abi.FB_USER_DEVICE_BASE;

/// Hace de watchdog: un cliente cuyo servidor ha muerto esperaría para siempre.
const wait_limit: u64 = 1 << 20;

pub fn waitExit(id: u64) void {
    var turns: u64 = 0;
    while (thread.isAlive(id)) : (turns += 1) {
        if (turns == wait_limit) {
            // Volcado para diagnosticar un fallo intermitente aún sin causa conocida.
            const u = @import("uart.zig");
            var t: u64 = 0;
            while (t < 8) : (t += 1) {
                const h = if (t == 0) 0 else abi.fb_sched_home(t);
                u.print("hilo ");
                u.printDecimal(t);
                u.print(" estado ");
                u.printDecimal(abi.fb_sched_state(h, t));
                u.print(" contexto ");
                u.printDecimal(abi.fb_sched_context(h, t));
                u.print(" resto ");
                u.printDecimal(abi.fb_sched_remaining(h, t));
                u.print(" espera_a ");
                u.printDecimal(abi.fb_ipc_waits_for(t));
                u.print("\n");
            }
            u.print("esperando a ");
            u.printDecimal(id);
            u.print(" corriendo ");
            u.printDecimal(abi.fb_sched_running(0));
            u.print(" kill ");
            u.printDecimal(@intFromBool(@import("process.zig").killFlag(id)));
            u.print("\n");
            @panic("un proceso no termino a tiempo");
        }
        thread.yield();
    }
}

pub fn expectExit(id: u64, program: process.Program, code: u64) void {
    waitExit(id);
    selftest_ipc.expectExit(id, program, code);
}

pub fn run1(program: process.Program, code: u64, grants: []const Grant) void {
    expectExit(start(program, 0, grants), program, code);
}

fn device(slot: u64, rights: u64) Grant {
    return .{ .slot = slot, .kind = abi.FB_CAP_DEVICE, .object = abi.FB_DEVICE_UART, .rights = rights };
}

fn startDriverIn(mode: u64) u64 {
    const id = start(.uart_driver, mode, &.{
        endpoint(0, 0, recv),
        device(1, send | recv),
        endpoint(2, 1, send),
    });
    waitBlocked(id);
    return id;
}

fn startDriver() u64 {
    return startDriverIn(abi.FB_UART_MODE_TEST);
}

fn expectDriverExit(id: u64, rejected: u64, written: u64) void {
    expectExit(id, .uart_driver, rejected << 32 | written);
}

fn expectFault(id: u64, cause: u64) void {
    while (thread.isAlive(id)) thread.yield();
    const result = process.resultOf(id);
    if (result.kind != .faulted or result.value != cause) @panic("un acceso al dispositivo no fallo como debia");
}

fn testDeviceGate() void {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);

    const ok = abi.FB_USPACE_OK;
    const invalid = abi.FB_USPACE_INVALID;
    const conflict = abi.FB_USPACE_CONFLICT;

    const first = abi.fb_uspace_create();
    const second = abi.fb_uspace_create();
    if (first == 0 or second == 0) @panic("no se pudieron crear espacios de prueba");

    expectEqual(abi.fb_uspace_map_device(0, abi.FB_DEVICE_UART, device_base), invalid);
    expectEqual(abi.fb_uspace_map_device(5, abi.FB_DEVICE_UART, device_base), invalid);
    expectEqual(abi.fb_uspace_map_device(first, abi.FB_DEVICE_UART, 0x1000), invalid);
    expectEqual(abi.fb_uspace_map_device(first, abi.FB_DEVICE_UART, device_base + 1), invalid);

    expectEqual(abi.fb_uspace_map_device(first, abi.FB_DEVICE_COUNT, device_base), invalid);
    expectEqual(abi.fb_uspace_map_device(first, abi.FB_DEVICE_UART, device_base), ok);
    expectEqual(abi.fb_uspace_map_device(second, abi.FB_DEVICE_UART, device_base), conflict);
    expectEqual(abi.fb_uspace_map_device(first, abi.FB_DEVICE_UART, device_base + 4096), conflict);

    // El kernel nunca debe tocar los registros en nombre de un proceso.
    expectEqual(abi.fb_uspace_translate(first, device_base, abi.FB_ACCESS_READ), 0);
    expectEqual(abi.fb_uspace_translate(first, device_base, abi.FB_ACCESS_WRITE), 0);

    expectEqual(abi.fb_uspace_destroy(first), ok);
    expectEqual(abi.fb_uspace_map_device(second, abi.FB_DEVICE_UART, device_base), ok);
    expectEqual(abi.fb_uspace_destroy(second), ok);
}

fn testSignalGate() void {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);

    const queued = abi.FB_IPC_QUEUED;
    const invalid = abi.FB_IPC_INVALID;
    const signal = abi.FB_IPC_SIGNAL;
    const not_ready = abi.FB_IPC_NOT_READY;

    expectEqual(abi.fb_ipc_signal(4), invalid);
    expectEqual(abi.fb_ipc_try_send(4), invalid);
    expectEqual(abi.fb_ipc_clear_signal(4), abi.FB_IPC_CANCEL_INVALID);

    // Dos señales seguidas se acumulan en una.
    expectEqual(abi.fb_ipc_signal(0), queued);
    expectEqual(abi.fb_ipc_signal(0), queued);
    expectEqual(abi.fb_ipc_recv(0, 1), signal);
    expectEqual(abi.fb_ipc_recv(0, 1), queued);

    // Con un receptor esperando, la señal lo despierta y no queda pendiente.
    expectEqual(abi.fb_ipc_signal(0), 1);
    expectEqual(abi.fb_ipc_recv(0, 1), queued);
    expectEqual(abi.fb_ipc_try_send(0), 1);

    // Sin receptor, el envío que no espera no deja rastro.
    expectEqual(abi.fb_ipc_try_send(0), not_ready);
    expectEqual(abi.fb_ipc_recv(0, 1), queued);
    expectEqual(abi.fb_ipc_cancel(1), abi.FB_IPC_OK);

    expectEqual(abi.fb_ipc_signal(0), queued);
    expectEqual(abi.fb_ipc_clear_signal(0), abi.FB_IPC_OK);
    expectEqual(abi.fb_ipc_recv(0, 1), queued);
    expectEqual(abi.fb_ipc_cancel(1), abi.FB_IPC_OK);
}

fn testNoAuthorityOverTheDevice() void {
    run1(.device_denied, 0, &.{});
    run1(.device_rights, 0, &.{ device(0, recv), device(1, send), endpoint(2, 0, send) });
    expectFault(start(.device_touch, 0, &.{}), 13);
    passed("sin capability no se llega al dispositivo");
}

/// Solo uno a la vez, sin ejecución, y la UART vuelve al kernel al morir el dueño.
fn testExclusiveOwnership() void {
    const holder = start(.device_holder, 0, &.{ device(0, send | recv), endpoint(1, 2, recv) });
    waitBlocked(holder);
    run1(.device_thief, 0, &.{ device(0, send | recv), console(1) });
    process.requestKill(holder);
    while (thread.isAlive(holder)) thread.yield();

    expectFault(start(.device_exec, 0, &.{device(0, send | recv)}), 12);
    run1(.hello, 7, &process.console_grant);
    passed("la UART tiene un solo dueno y vuelve al kernel");
}

const client_text = "hola desde el driver en Rust\n";

fn testDriverWrites() void {
    const driver = startDriver();
    const client = start(.uart_client, 0, &.{endpoint(0, 0, send)});
    expectExit(client, .uart_client, 0);
    run1(.uart_stopper, 0, &.{endpoint(0, 0, send)});
    expectDriverExit(driver, 2, client_text.len);
    passed("el driver en Rust escribe y rechaza peticiones invalidas");
}

/// En modo bucle la UART se recibe a sí misma: pasa por la línea de
/// interrupción, el kernel, la señal, el driver y un envío al lector.
fn testInterruptsReachTheReader() void {
    const driver = startDriver();
    const reader = start(.uart_reader, 0, &.{endpoint(0, 1, recv)});
    waitBlocked(reader);
    const client = start(.uart_loop_client, 0, &.{endpoint(0, 0, send)});
    expectExit(client, .uart_loop_client, 0);
    waitBlocked(driver);
    waitBlocked(reader);

    // El driver duerme: este byte solo puede despertarlo por su interrupción,
    // y solo llega si la anterior se confirmó.
    riscv.enableInterrupts();
    uart.injectByte('c');
    expectExit(reader, .uart_reader, 0);
    riscv.disableInterrupts();

    run1(.uart_loop_finish, 0, &.{endpoint(0, 0, send)});
    expectDriverExit(driver, 0, 2);
    passed("las interrupciones de la UART llegan al driver y al lector");
}

/// Una lectura sin datos no bloquea al driver: aplaza la respuesta, sigue
/// atendiendo (a otro lector le dice que ya hay uno esperando) y contesta
/// cuando la interrupción trae el byte.
fn testDeferredRead() void {
    const driver = startDriver();
    run1(.uart_loop_on, 0, &.{endpoint(0, 0, send)});
    const reader = start(.uart_call_reader, 0, &.{endpoint(0, 0, send)});
    waitBlocked(reader);
    waitBlocked(driver);

    const busy = start(.uart_call_reader, 0, &.{endpoint(0, 0, send)});
    expectExit(busy, .uart_call_reader, abi.FB_ERR_BUSY);
    if (thread.state(reader) != abi.FB_THREAD_BLOCKED) @panic("la lectura no se aplazo");

    riscv.enableInterrupts();
    uart.injectByte('q');
    expectExit(reader, .uart_call_reader, 'q');
    riscv.disableInterrupts();

    run1(.uart_loop_finish, 0, &.{endpoint(0, 0, send)});
    expectDriverExit(driver, 0, 0);
    passed("el driver aplaza la lectura hasta que llega la interrupcion");
}

/// En producción ningún cliente puede parar al driver ni tocar el modo bucle.
fn testProductionModeRejectsTestOperations() void {
    const driver = startDriverIn(0);
    run1(.uart_stopper, 0, &.{endpoint(0, 0, send)});
    run1(.uart_loop_on, 0, &.{endpoint(0, 0, send)});
    waitBlocked(driver);
    if (uart.loopbackActive()) @panic("un cliente activo el modo bucle");
    process.requestKill(driver);
    waitExit(driver);
    if (process.resultOf(driver).kind != .killed) @panic("un cliente paro al driver");
    passed("un cliente no puede parar al driver ni usar sus operaciones de prueba");
}

fn killAndWait(id: u64) void {
    process.requestKill(id);
    while (thread.isAlive(id)) thread.yield();
    if (process.resultOf(id).kind != .killed) @panic("el proceso no murio");
}

fn expectDeviceRecovered() void {
    if (device_module.lineEnabled()) @panic("la linea de interrupcion quedo activa");
    if (device_module.uartOwned()) @panic("la UART sigue teniendo dueno");
    if (uart.loopbackActive()) @panic("la UART quedo en modo bucle");
}

/// Morir con una interrupción sin confirmar no puede dejar sorda a la línea, y
/// una señal que nadie llegó a recibir no debe llegarle al siguiente dueño.
fn testDeathDuringInterrupt() void {
    const grants = [_]Grant{ device(0, send | recv), endpoint(1, 0, recv) };

    const in_service = start(.device_irq_taker, 0, &grants);
    waitBlocked(in_service);
    killAndWait(in_service);
    expectDeviceRecovered();
    testInterruptsReachTheReader();

    const unread = start(.device_irq_taker, 1, &grants);
    for (0..256) |_| thread.yield();
    killAndWait(unread);
    expectDeviceRecovered();

    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    expectEqual(abi.fb_ipc_recv(0, 1), abi.FB_IPC_QUEUED);
    expectEqual(abi.fb_ipc_cancel(1), abi.FB_IPC_OK);
    passed("morir con una interrupcion a medias no deja rastro");
}

/// Un driver muerto, incluso a mitad de una prueba de bucle, se puede sustituir.
fn testDriverRestart() void {
    for (0..4) |_| {
        const driver = startDriver();
        const client = start(.uart_loop_on, 0, &.{endpoint(0, 0, send)});
        expectExit(client, .uart_loop_on, 0);
        process.requestKill(driver);
        while (thread.isAlive(driver)) thread.yield();
        if (process.resultOf(driver).kind != .killed) @panic("el driver no murio");
        if (uart.loopbackActive()) @panic("la UART quedo en modo bucle");
    }

    const driver = startDriver();
    const client = start(.uart_client, 0, &.{endpoint(0, 0, send)});
    expectExit(client, .uart_client, 0);
    run1(.uart_stopper, 0, &.{endpoint(0, 0, send)});
    expectDriverExit(driver, 2, client_text.len);
    passed("matar al driver no afecta al kernel y se puede arrancar otro");
}

pub fn run() void {
    testDeviceGate();
    testSignalGate();
    passed("la cesion de dispositivos y las senales rechazan peticiones invalidas");

    const frames_before = selftest_user.poisonFreeFrames();
    testNoAuthorityOverTheDevice();
    testExclusiveOwnership();
    testDriverWrites();
    testInterruptsReachTheReader();
    testDeferredRead();
    testProductionModeRejectsTestOperations();
    testDeathDuringInterrupt();
    testDriverRestart();
    if (selftest_user.poisonFreeFrames() != frames_before) @panic("el driver perdio marcos");
    passed("todos los marcos vuelven tras las pruebas del driver");
}
