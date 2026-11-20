//! Autopruebas de llamada y respuesta, del cambio directo y de la muerte de servidores.

const abi = @import("abi.zig").c;
const ipc = @import("ipc.zig");
const process = @import("process.zig");
const riscv = @import("riscv.zig");
const selftest_driver = @import("selftest_driver.zig");
const selftest_ipc = @import("selftest_ipc.zig");
const selftest_user = @import("selftest_user.zig");
const thread = @import("thread.zig");

const Grant = process.Grant;
const endpoint = selftest_ipc.endpoint;
const start = selftest_ipc.start;
const passed = selftest_ipc.passed;
const waitBlocked = selftest_ipc.waitBlocked;
const expectEqual = selftest_ipc.expectEqual;
const expectExit = selftest_driver.expectExit;
const run1 = selftest_driver.run1;
const waitExit = selftest_driver.waitExit;

const send: u64 = abi.FB_RIGHT_SEND;
const recv: u64 = abi.FB_RIGHT_RECV;

const grant: u64 = abi.FB_RIGHT_GRANT;

const client_grants = [_]Grant{endpoint(0, 0, send)};
const server_grants = [_]Grant{endpoint(0, 0, recv)};

fn testCallGate() void {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);

    const queued = abi.FB_IPC_QUEUED;
    const invalid = abi.FB_IPC_INVALID;
    const not_ready = abi.FB_IPC_NOT_READY;

    expectEqual(abi.fb_ipc_call(4, 1), invalid);
    expectEqual(abi.fb_ipc_call(0, 0), invalid);
    expectEqual(abi.fb_ipc_call(0, 8), invalid);
    expectEqual(abi.fb_ipc_reply(0), invalid);
    expectEqual(abi.fb_ipc_reply(8), invalid);
    expectEqual(abi.fb_ipc_reply(2), invalid);
    expectEqual(abi.fb_ipc_waits_for(1), 0);
    expectEqual(abi.fb_ipc_waits_for(0), 0);
    expectEqual(abi.fb_ipc_waits_for(8), 0);

    // El servidor llega primero.
    expectEqual(abi.fb_ipc_recv(0, 2), queued);
    expectEqual(abi.fb_ipc_call(0, 1), 2);
    expectEqual(abi.fb_ipc_waits_for(1), 2);

    // Quien espera respuesta no puede hacer nada más, y quien la debe no puede recibir.
    expectEqual(abi.fb_ipc_call(1, 1), invalid);
    expectEqual(abi.fb_ipc_send(1, 1), invalid);
    expectEqual(abi.fb_ipc_recv(1, 1), invalid);
    expectEqual(abi.fb_ipc_recv(1, 2), invalid);

    expectEqual(abi.fb_ipc_reply(2), 1);
    expectEqual(abi.fb_ipc_reply(2), invalid);
    expectEqual(abi.fb_ipc_waits_for(1), 0);

    // El cliente llega primero, y muere esperando la respuesta.
    expectEqual(abi.fb_ipc_call(0, 1), queued);
    expectEqual(abi.fb_ipc_recv(0, 2), 1);
    expectEqual(abi.fb_ipc_waits_for(1), 2);
    expectEqual(abi.fb_ipc_cancel(1), abi.FB_IPC_OK);
    expectEqual(abi.fb_ipc_waits_for(1), 0);
    expectEqual(abi.fb_ipc_reply(2), invalid);

    // Un endpoint sin servidor: los emisores salen en orden.
    expectEqual(abi.fb_ipc_abort_sender(4), invalid);
    expectEqual(abi.fb_ipc_abort_sender(0), not_ready);
    expectEqual(abi.fb_ipc_send(0, 3), queued);
    expectEqual(abi.fb_ipc_call(0, 4), queued);
    expectEqual(abi.fb_ipc_abort_sender(0), 3);
    expectEqual(abi.fb_ipc_abort_sender(0), 4);
    expectEqual(abi.fb_ipc_abort_sender(0), not_ready);
    expectEqual(abi.fb_ipc_waits_for(4), 0);

    // Una llamada cancelada en la cola no deja rastro para el siguiente uso del hilo.
    expectEqual(abi.fb_ipc_call(0, 1), queued);
    expectEqual(abi.fb_ipc_cancel(1), abi.FB_IPC_OK);
    expectEqual(abi.fb_ipc_send(0, 1), queued);
    expectEqual(abi.fb_ipc_recv(0, 2), 1);
    expectEqual(abi.fb_ipc_waits_for(1), 0);
    expectEqual(abi.fb_ipc_reply(2), invalid);

    // Un envío normal no crea ningún enlace.
    expectEqual(abi.fb_ipc_recv(0, 2), queued);
    expectEqual(abi.fb_ipc_send(0, 1), 2);
    expectEqual(abi.fb_ipc_reply(2), invalid);
    passed("las llamadas rechazan peticiones invalidas");
}

fn testReceiverQueries() void {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);

    const kind = abi.FB_CAP_ENDPOINT;
    expectEqual(abi.fb_cap_holds_receive(1, 2), 0);
    expectEqual(abi.fb_cap_other_receiver(1, 2), 0);
    expectEqual(abi.fb_cap_holds_receive(0, 2), 0);
    expectEqual(abi.fb_cap_other_receiver(0, 2), 1);

    expectEqual(abi.fb_cap_grant(1, 3, kind, 2, send), abi.FB_CAP_OK);
    expectEqual(abi.fb_cap_holds_receive(1, 2), 0);
    expectEqual(abi.fb_cap_other_receiver(2, 2), 0);

    expectEqual(abi.fb_cap_grant(1, 4, kind, 2, recv), abi.FB_CAP_OK);
    expectEqual(abi.fb_cap_holds_receive(1, 2), 1);
    expectEqual(abi.fb_cap_holds_receive(1, 3), 0);
    expectEqual(abi.fb_cap_other_receiver(1, 2), 0);
    expectEqual(abi.fb_cap_other_receiver(2, 2), 1);
    expectEqual(abi.fb_cap_other_receiver(2, 3), 0);

    expectEqual(abi.fb_cap_clear(1), abi.FB_CAP_OK);
    expectEqual(abi.fb_cap_other_receiver(2, 2), 0);
    passed("el kernel sabe si un endpoint se queda sin servidor");
}

fn testCallsFromTwoClients() void {
    const before = thread.directSwitches();

    const server = start(.call_server, 2, &server_grants);
    waitBlocked(server);
    const first = start(.call_client, 1, &client_grants);
    const second = start(.call_client, 1000, &client_grants);
    expectExit(first, .call_client, 0);
    expectExit(second, .call_client, 0);
    expectExit(server, .call_server, 0);

    if (thread.directSwitches() == before) @panic("no hubo ningun cambio directo");
    passed("llamadas y respuestas de dos clientes, con cambio directo");
}

fn testClientArrivesFirst() void {
    const client = start(.call_client, 1, &client_grants);
    waitBlocked(client);

    // Que muera un proceso sin relación con el endpoint no afecta al cliente.
    run1(.no_caps, 0, &.{});
    if (thread.state(client) != abi.FB_THREAD_BLOCKED) @panic("se aviso a un cliente sin motivo");

    const server = start(.call_server, 1, &server_grants);
    expectExit(client, .call_client, 0);
    expectExit(server, .call_server, 0);
    passed("una llamada en cola se atiende al llegar el servidor");
}

/// Con reply_recv no hay hueco destino: la cesión debe fallar para el emisor.
fn testReplyRecvTakesNoCapability() void {
    const server = start(.call_server, 1, &server_grants);
    waitBlocked(server);
    const granter = start(.granter, 0, &.{ endpoint(0, 0, send | grant), selftest_ipc.console(1) });
    expectExit(granter, .granter, abi.FB_ERR_CAP);
    const client = start(.call_client, 1, &client_grants);
    expectExit(client, .call_client, 0);
    expectExit(server, .call_server, 0);
    passed("reply_recv no acepta capabilities");
}

fn testReplyRecvDeliversSignal() void {
    const id = start(.signal_taker, 0, &server_grants);
    const saved = riscv.disableInterruptsSaving();
    if (ipc.signal(0)) @panic("no habia nadie a quien despertar");
    riscv.restoreInterrupts(saved);
    expectExit(id, .signal_taker, 0);
    passed("reply_recv entrega las senales");
}

/// Al responder a uno con otro ya en cola, ninguno de los dos se queda esperando.
fn testReplyWithAnotherCallerQueued() void {
    // El servidor espera a base de ceder la CPU: el hilo principal necesita sus
    // turnos, sin la deuda que arrastre de pruebas anteriores.
    thread.setParams(0, abi.FB_PRIO_NORMAL, abi.FB_SCHED_DEFAULT_BUDGET);
    const server = start(.call_server_pair, 0, &server_grants);
    waitBlocked(server);
    const first = start(.call_once, 10, &client_grants);
    waitBlocked(first);
    const second = start(.call_once, 20, &client_grants);
    waitBlocked(second);
    expectExit(first, .call_once, 0);
    expectExit(second, .call_once, 0);
    expectExit(server, .call_server_pair, 0);
    passed("responder con otro cliente en cola despierta a los dos");
}

fn testDeferGate() void {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    const invalid = abi.FB_IPC_INVALID;
    expectEqual(abi.fb_ipc_defer(0), invalid);
    expectEqual(abi.fb_ipc_defer(8), invalid);
    expectEqual(abi.fb_ipc_defer(1), invalid);
    expectEqual(abi.fb_ipc_reply_held(1, 2), invalid);
    expectEqual(abi.fb_ipc_reply_held(1, 0), invalid);
    expectEqual(abi.fb_ipc_reply_held(8, 1), invalid);
    expectEqual(abi.fb_ipc_abort_held(1), invalid);
    expectEqual(abi.fb_ipc_abort_held(0), invalid);
    passed("aplazar y contestar lo aplazado rechazan peticiones invalidas");
}

const defer_grants = [_]Grant{ endpoint(0, 0, recv), endpoint(1, 1, recv) };
const go_grants = [_]Grant{endpoint(0, 1, send)};

/// El servidor aplaza al primer cliente, atiende al segundo y solo después
/// contesta al primero. Nadie más puede contestarle.
fn testDeferredReply() void {
    const server = start(.defer_server, 0, &defer_grants);
    waitBlocked(server);
    const first = start(.call_once, 10, &client_grants);
    waitBlocked(first);
    waitBlocked(server);
    expectContext(server, first, "aplazar no conservo el contexto prestado");

    expectExit(start(.reply_to_other, first, &.{}), .reply_to_other, abi.FB_ERR_INVALID);

    const second = start(.call_once, 20, &client_grants);
    expectExit(second, .call_once, 0);
    if (thread.state(first) != abi.FB_THREAD_BLOCKED) @panic("se contesto a un cliente aplazado antes de tiempo");
    waitBlocked(server);
    expectContext(server, first, "un cliente igual de urgente se llevo el contexto");

    run1(.go_sender, 0, &go_grants);
    expectExit(first, .call_once, 0);
    expectExit(server, .defer_server, 0);
    passed("un servidor aplaza una respuesta, atiende a otro y contesta despues");
}

/// La llamada llega antes que el servidor: al recibirla de la cola también se
/// sabe que es una llamada, y también se puede aplazar.
fn testDeferredQueuedCall() void {
    const first = start(.call_once, 10, &client_grants);
    waitBlocked(first);
    const server = start(.defer_server, 0, &defer_grants);
    waitBlocked(server);
    expectExit(start(.call_once, 20, &client_grants), .call_once, 0);
    if (thread.state(first) != abi.FB_THREAD_BLOCKED) @panic("se contesto a un cliente aplazado antes de tiempo");
    run1(.go_sender, 0, &go_grants);
    expectExit(first, .call_once, 0);
    expectExit(server, .defer_server, 0);
    passed("una llamada que esperaba en cola tambien se reconoce y se aplaza");
}

fn expectContext(id: u64, expected: u64, message: []const u8) void {
    if (thread.contextOf(id) != expected) @panic(message);
}

/// Un cliente creado con su prioridad, antes de que llegue a ejecutarse.
fn startAt(argument: u64, level: u64) u64 {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    const id = start(.call_once, argument, &client_grants);
    thread.setParams(id, level, abi.FB_SCHED_DEFAULT_BUDGET);
    return id;
}

/// Da permiso al servidor con una señal del kernel: los cuatro espacios de
/// usuario ya están ocupados por el servidor y sus tres clientes.
fn sendGo() void {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    _ = ipc.signal(1);
}

/// Tres llamadas aplazadas, de prioridad normal, baja y alta. El servidor
/// trabaja siempre con el contexto de la más urgente pendiente: al llegar la
/// alta cambia a ella, y al contestarla vuelve a la normal, no a la baja.
fn testDeferredKeepsMostUrgent() void {
    const readopted_before = ipc.readoptions();
    const server = start(.defer_three, 0, &defer_grants);
    waitBlocked(server);

    const first = startAt(10, abi.FB_PRIO_NORMAL);
    waitBlocked(first);
    waitBlocked(server);
    expectContext(server, first, "aplazar no conservo el contexto prestado");

    const lower = startAt(20, abi.FB_PRIO_LOW);
    waitBlocked(lower);
    waitBlocked(server);
    expectContext(server, first, "un cliente menos urgente se llevo el contexto");

    const urgent = startAt(30, abi.FB_PRIO_HIGH);
    waitBlocked(urgent);
    waitBlocked(server);
    expectContext(server, urgent, "el cliente mas urgente no presto su contexto");

    sendGo();
    expectExit(urgent, .call_once, 0);
    waitBlocked(server);
    expectContext(server, first, "al contestar no se tomo el contexto del aplazado mas urgente");
    if (ipc.readoptions() == readopted_before) @panic("no se volvio a tomar ningun contexto");

    sendGo();
    expectExit(lower, .call_once, 0);
    waitBlocked(server);
    expectContext(server, first, "contestar a otro solto el contexto");

    sendGo();
    expectExit(first, .call_once, 0);
    expectExit(server, .defer_three, 0);
    passed("con varias respuestas aplazadas se usa el contexto de la mas urgente");
}

/// Con una respuesta aplazada, el servidor toma el contexto de clientes más
/// urgentes mientras los atiende. Al contestarles, con reply o con reply_recv
/// (haya o no otra llamada en cola), vuelve a tomar el del aplazado.
fn testAnswersReadopt() void {
    const server = start(.defer_then_serve, 0, &defer_grants);
    waitBlocked(server);
    const first = startAt(10, abi.FB_PRIO_NORMAL);
    waitBlocked(first);
    waitBlocked(server);
    expectContext(server, first, "aplazar no conservo el contexto prestado");

    expectExit(startAt(20, abi.FB_PRIO_HIGH), .call_once, 0);
    waitBlocked(server);
    expectContext(server, first, "reply no volvio a tomar el contexto del aplazado");

    // reply_recv con otra llamada ya en cola: el servidor espera permiso
    // mientras las dos llamadas se encolan, y aplaza la segunda.
    const urgent = startAt(30, abi.FB_PRIO_HIGH);
    waitBlocked(urgent);
    const queued = startAt(40, abi.FB_PRIO_NORMAL);
    waitBlocked(queued);
    sendGo();
    expectExit(urgent, .call_once, 0);
    waitBlocked(server);
    expectContext(server, first, "reply_recv con cola no volvio a tomar el contexto del aplazado");
    sendGo();
    expectExit(queued, .call_once, 0);

    // reply_recv sin nadie en cola.
    expectExit(startAt(50, abi.FB_PRIO_HIGH), .call_once, 0);
    waitBlocked(server);
    expectContext(server, first, "reply_recv sin cola no volvio a tomar el contexto del aplazado");
    expectExit(startAt(60, abi.FB_PRIO_NORMAL), .call_once, 0);

    waitBlocked(server);
    sendGo();
    expectExit(first, .call_once, 0);
    expectExit(server, .defer_then_serve, 0);
    passed("contestar con reply o reply_recv vuelve al contexto del aplazado");
}

/// Un cliente aplazado que gana urgencia mientras espera (aquí, porque el
/// kernel le cambia los parámetros) hace que el servidor vuelva a elegir: pasa
/// a su contexto sin esperar a su siguiente operación de IPC.
fn testDeferredGainsUrgency() void {
    const server = start(.defer_three, 0, &defer_grants);
    waitBlocked(server);
    const first = startAt(10, abi.FB_PRIO_NORMAL);
    waitBlocked(first);
    waitBlocked(server);
    const lower = startAt(20, abi.FB_PRIO_LOW);
    waitBlocked(lower);
    waitBlocked(server);
    expectContext(server, first, "un cliente menos urgente se llevo el contexto");

    const recomputed = ipc.recomputations();
    thread.setParams(lower, abi.FB_PRIO_HIGH, abi.FB_SCHED_DEFAULT_BUDGET);
    if (ipc.recomputations() == recomputed) @panic("cambiar a quien espera no rehizo la herencia");
    expectContext(server, lower, "un aplazado que gano urgencia no hizo cambiar de contexto");
    if (thread.priorityOf(server) != abi.FB_PRIO_HIGH) @panic("el servidor no corre con la urgencia del aplazado");
    if (!ipc.ruleHolds()) @panic("tras cambiar a un aplazado no se cumple la regla de la herencia");

    const third = startAt(30, abi.FB_PRIO_LOW);
    waitBlocked(third);
    waitBlocked(server);
    expectContext(server, lower, "un cliente menos urgente se llevo el contexto");
    sendGo();
    expectExit(third, .call_once, 0);
    waitBlocked(server);
    sendGo();
    expectExit(lower, .call_once, 0);
    waitBlocked(server);
    expectContext(server, first, "al contestar no se volvio al aplazado que quedaba");
    sendGo();
    expectExit(first, .call_once, 0);
    expectExit(server, .defer_three, 0);
    passed("un aplazado que gana urgencia hace volver a elegir el contexto");
}

const chain_head = [_]Grant{endpoint(0, 0, send)};
const chain_middle = [_]Grant{ endpoint(0, 0, recv), endpoint(1, 1, send) };
const chain_last = [_]Grant{endpoint(0, 1, recv)};

/// Como startAt, con cualquier programa.
fn startWith(program: process.Program, grants: []const Grant, level: u64) u64 {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    const id = start(program, 0, grants);
    thread.setParams(id, level, abi.FB_SCHED_DEFAULT_BUDGET);
    return id;
}

/// Cadena A -> B -> C en un hart, de prioridad alta, normal y baja: B y C
/// trabajan con el contexto de A. Si A muere, lo recupera de los dos y cada
/// uno vuelve al suyo; C, que aún debe la respuesta a B, no puede quedar con
/// menos urgencia que él.
fn testChainHeadDies() void {
    const last = startWith(.call_server_lost, &chain_last, abi.FB_PRIO_LOW);
    waitBlocked(last);
    const middle = startWith(.call_forwarder, &chain_middle, abi.FB_PRIO_NORMAL);
    waitBlocked(middle);
    const head = startWith(.call_expect_peer, &chain_head, abi.FB_PRIO_HIGH);

    while (@import("sleep.zig").earliest() == abi.FB_SLEEP_NONE) {
        if (!thread.isAlive(last)) @panic("el final de la cadena murio antes de dormirse");
        thread.yield();
    }
    if (abi.fb_ipc_waits_for(head) != middle or abi.fb_ipc_waits_for(middle) != last) @panic("la cadena no quedo montada");
    expectContext(last, head, "el final de la cadena no trabaja con el contexto del primero");
    if (thread.priorityOf(last) != abi.FB_PRIO_HIGH) @panic("el final de la cadena no corre con la urgencia del primero");

    killAndWait(head);
    if (thread.priorityOf(middle) != abi.FB_PRIO_NORMAL) @panic("muerto el primero, el del medio no volvio a su prioridad");
    if (thread.priorityOf(last) != abi.FB_PRIO_NORMAL) @panic("muerto el primero, el final quedo con menos urgencia que su cliente");
    if (!ipc.ruleHolds()) @panic("muerto el primero, no se cumple la regla de la herencia");

    killAndWait(middle);
    if (thread.priorityOf(last) != abi.FB_PRIO_LOW) @panic("sin clientes, el final siguio con lo heredado");
    killAndWait(last);
    passed("si muere el primero de una cadena, nadie queda por debajo de su cliente");
}

/// Si muere el cliente aplazado más urgente, el servidor pasa al siguiente.
fn testUrgentDeferredDies() void {
    const server = start(.defer_three, 0, &defer_grants);
    waitBlocked(server);
    const first = startAt(10, abi.FB_PRIO_NORMAL);
    waitBlocked(first);
    waitBlocked(server);
    const equal = startAt(20, abi.FB_PRIO_NORMAL);
    waitBlocked(equal);
    waitBlocked(server);
    expectContext(server, first, "un cliente igual de urgente se llevo el contexto");
    const urgent = startAt(30, abi.FB_PRIO_HIGH);
    waitBlocked(urgent);
    waitBlocked(server);
    expectContext(server, urgent, "el cliente mas urgente no presto su contexto");

    killAndWait(urgent);
    const now = thread.contextOf(server);
    if (now != first and now != equal) @panic("al morir el aplazado mas urgente no se tomo el siguiente");
    killAndWait(server);
    expectExit(first, .call_once, 1);
    expectExit(equal, .call_once, 1);
    passed("si muere el aplazado mas urgente, se usa el contexto del siguiente");
}

/// Si el cliente aplazado muere, contestarle después no vale, y el servidor
/// deja de usar su contexto.
fn testDeferredCallerDies() void {
    const server = start(.defer_server, 0, &defer_grants);
    waitBlocked(server);
    const first = start(.call_once, 10, &client_grants);
    waitBlocked(first);
    waitBlocked(server);
    expectContext(server, first, "aplazar no conservo el contexto prestado");
    killAndWait(first);
    expectContext(server, server, "el servidor siguio usando el contexto de un muerto");

    expectExit(start(.call_once, 20, &client_grants), .call_once, 0);
    run1(.go_sender, 0, &go_grants);
    expectExit(server, .defer_server, abi.FB_ERR_INVALID);
    passed("contestar a un cliente aplazado que murio no hace nada");
}

/// Si el servidor muere con respuestas aplazadas, sus clientes se enteran.
fn testServerDiesWithDeferred() void {
    const server = start(.defer_then_die, 0, &server_grants);
    waitBlocked(server);
    const client = start(.call_expect_peer, 0, &client_grants);
    expectExit(client, .call_expect_peer, 0);
    expectExit(server, .defer_then_die, 0);
    passed("si el servidor muere con respuestas aplazadas, el cliente se entera");
}

fn testChecks() void {
    run1(.call_checks, 0, &client_grants);
    passed("responder o llamar sin derecho no funciona");
}

fn testServerDiesOwingReply() void {
    const server = start(.call_server_dies, 0, &server_grants);
    waitBlocked(server);
    const client = start(.call_expect_peer, 0, &client_grants);
    expectExit(client, .call_expect_peer, 0);
    expectExit(server, .call_server_dies, 0);
    passed("si el servidor muere debiendo una respuesta, el cliente se entera");
}

fn killAndWait(id: u64) void {
    process.requestKill(id);
    waitExit(id);
}

fn testEndpointLosesItsLastServer() void {
    const server = start(.spin, 0, &server_grants);
    const caller = start(.call_expect_peer, 0, &client_grants);
    const sender = start(.send_expect_peer, 0, &client_grants);
    waitBlocked(caller);
    waitBlocked(sender);
    killAndWait(server);
    expectExit(caller, .call_expect_peer, 0);
    expectExit(sender, .send_expect_peer, 0);

    // Mientras quede otro servidor capaz de recibir, los clientes siguen en cola.
    const main = start(.spin, 0, &server_grants);
    const backup = start(.spin, 0, &server_grants);
    const waiting = start(.call_expect_peer, 0, &client_grants);
    waitBlocked(waiting);
    killAndWait(main);
    if (thread.state(waiting) != abi.FB_THREAD_BLOCKED) @panic("se aviso al cliente con un servidor vivo");
    killAndWait(backup);
    expectExit(waiting, .call_expect_peer, 0);
    passed("un endpoint sin servidores despierta a sus clientes con error");
}

fn testCallerDiesAwaitingReply() void {
    const server = start(.call_server_lost, 0, &server_grants);
    waitBlocked(server);
    const client = start(.call_expect_peer, 0, &client_grants);
    // El servidor recibe la llamada, comprueba que no puede recibir otra y se
    // duerme. Solo entonces muere el cliente: si muriera antes, el servidor ya
    // no debería nada y su segundo recv esperaría para siempre, con razón.
    while (@import("sleep.zig").earliest() == abi.FB_SLEEP_NONE) {
        if (!thread.isAlive(server)) @panic("el servidor murio antes de dormirse");
        thread.yield();
    }
    killAndWait(client);
    if (process.resultOf(client).kind != .killed) @panic("el cliente no murio");
    if (!@import("sleep.zig").cancel(server)) @panic("el servidor no estaba dormido");
    expectExit(server, .call_server_lost, 0);
    passed("si el cliente muere, responder no despierta a nadie");
}

/// Dos procesos llamándose no pueden quedarse con la CPU: el hilo principal
/// solo avanza si el timer sigue repartiendo turnos.
fn testDirectSwitchDoesNotMonopolize() void {
    const server = start(.call_server, 1, &server_grants);
    waitBlocked(server);
    const client = start(.call_long, 0, &client_grants);

    var turns: u64 = 0;
    while (thread.isAlive(client)) : (turns += 1) thread.yield();
    expectExit(client, .call_long, 0);
    expectExit(server, .call_server, 0);
    if (turns < 4) @panic("el cambio directo acaparo la CPU");
    passed("el cambio directo no acapara la CPU");
}

pub fn run() void {
    testCallGate();
    testReceiverQueries();

    const frames_before = selftest_user.poisonFreeFrames();
    testCallsFromTwoClients();
    testClientArrivesFirst();
    testReplyRecvTakesNoCapability();
    testReplyRecvDeliversSignal();
    testReplyWithAnotherCallerQueued();
    testDeferGate();
    testDeferredReply();
    testDeferredQueuedCall();
    testDeferredKeepsMostUrgent();
    testAnswersReadopt();
    testDeferredGainsUrgency();
    testChainHeadDies();
    testUrgentDeferredDies();
    testDeferredCallerDies();
    testServerDiesWithDeferred();
    testChecks();
    if (!thread.billingConsistent()) @panic("las llamadas cobraron mal el tiempo");
    testServerDiesOwingReply();
    testEndpointLosesItsLastServer();
    testCallerDiesAwaitingReply();
    testDirectSwitchDoesNotMonopolize();
    if (selftest_user.poisonFreeFrames() != frames_before) @panic("las llamadas perdieron marcos");
    passed("todos los marcos vuelven tras las llamadas");
}
