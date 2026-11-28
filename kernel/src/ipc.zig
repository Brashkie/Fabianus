// SPDX-License-Identifier: GPL-3.0-or-later
//! IPC síncrono. SPARK decide quién se encuentra con quién; aquí se mueven los
//! registros del mensaje entre los marcos de trap de los dos procesos.
//!
//! Protocolo: send(cap=a0, mensaje=a1..a4, capability a ceder=a5) y
//! recv(cap=a0, hueco destino=a1), que devuelve el mensaje en a1..a4 y en a5
//! FB_MSG_CAP si llegó una capability o FB_MSG_SIGNAL si es una interrupción.
//!
//! call(cap=a0, mensaje=a1..a4, a5=FB_CAP_SLOT_NONE) envía y espera la respuesta
//! en a1..a4. reply(mensaje=a1..a4) contesta sin bloquearse nunca, y
//! reply_recv(cap=a0, mensaje=a1..a4) contesta y espera la siguiente petición.
//! En una llamada la CPU pasa directamente al otro extremo, sin planificador, y
//! el servidor trabaja con el contexto de planificación del cliente hasta que
//! le responde: su prioridad y su presupuesto.
//!
//! Quien recibe un mensaje encuentra en a6 la marca de la capability con que
//! se lo enviaron (Cap_Core.Badge_Of; 0 en una señal). Solo el kernel pone
//! marcas, así que un servidor sabe qué cliente le habla.
//!
//! Quien recibe una llamada lo sabe por FB_MSG_CALL en a5. Puede contestar ya o
//! aplazarla con defer, que devuelve en a1 el cliente; más tarde la contesta con
//! reply_to(cliente=a0, mensaje=a1..a4). Mientras tanto puede recibir otras.
//! Aplazar no devuelve el contexto prestado: el servidor sigue trabajando con el
//! del cliente más urgente que tenga pendiente.

const abi = @import("abi.zig").c;
const process = @import("process.zig");
const thread = @import("thread.zig");
const kernel_lock = @import("kernel_lock.zig");
const riscv = @import("riscv.zig");

const a0: usize = 10;
const a1: usize = 11;
const a2: usize = 12;
const a3: usize = 13;
const a4: usize = 14;
const a5: usize = 15;
const a6: usize = 16;

/// Marco del trap de cada hilo mientras espera en un endpoint o una respuesta.
var waiting: [thread.max_threads]?*abi.fb_trap_frame = [_]?*abi.fb_trap_frame{null} ** thread.max_threads;

/// Marca de la capability con que envió cada hilo que espera a su receptor.
/// Se toma al enviar: es la de ese momento aunque después cambie el hueco.
var sent_badge = [_]u64{0} ** thread.max_threads;

/// Servidores que pueden tener respuestas aplazadas. Solo dice dónde buscar: la
/// búsqueda lo borra cuando ya no queda ninguna.
var deferring = [_]bool{false} ** thread.max_threads;
var readopted_count: u64 = 0;
var deferred_count: u64 = 0;

var boost_count: u64 = 0;
var recompute_count: u64 = 0;

/// Herencia de prioridad. La regla que se mantiene: un servidor nunca corre
/// con menos urgencia que un cliente que espera su respuesta (en curso o
/// aplazada). En Debug se comprueba en cada llamada al sistema
/// (`checkInheritance`).
///
/// Dentro de un hart la urgencia suele viajar con el contexto prestado, que
/// además lleva el presupuesto. Lo que no viaja así se hereda como suelo del
/// servidor (SPARK: Floors, el hilo corre al menos con él use el contexto que
/// use): la de un cliente de otro hart, porque cada hart lleva su
/// contabilidad, y la de un cliente que a su vez hereda. Entre harts se
/// hereda solo la urgencia, nunca tiempo de CPU.
///
/// El suelo cuenta a todos los clientes que esperan, de cualquier hart; pero
/// en el camino rápido de un mismo hart no se calcula: ahí basta el contexto.
/// Es transitiva, porque la prioridad de un cliente ya cuenta lo que él
/// hereda. Aquí el servidor es quien corre, así que no espera a nadie y no
/// hay cadena debajo que actualizar. En una cadena ya montada todos menos el
/// último están bloqueados y no aceptan clientes, así que solo cambia algo al
/// matar, cancelar o cambiar parámetros: eso lo rehace `refreshChain`.
///
/// El suelo lo calcula y lo fija SPARK (Inherit_Gate.Refresh): queda en
/// exactamente el mayor nivel de los clientes que esperan, y con él el
/// servidor cumple la regla. El kernel no guarda ninguna copia: si un hilo
/// hereda se lee del modelo.
///
/// Entre harts, llamar y contestar van fusionados con la herencia
/// (Inherit_Gate.Call_Wake y Reply_Wake): despertar al otro extremo y
/// recalcular el suelo es una sola operación SPARK, con solo los cerrojos de
/// los dos harts, y está demostrado que la regla se conserva en todos los
/// hilos.
pub fn updateBoost(server: u64) void {
    if (server == 0 or server >= thread.max_threads) return;
    boost_count += 1;
    thread.refreshFloor(server);
}

/// Hay que recalcular el suelo de quien atiende a `client`: el contexto no
/// lleva toda su urgencia, porque es de otro hart o porque él mismo hereda.
inline fn needsFloor(client: u64, server: u64) bool {
    return thread.homeOf(client) != thread.homeOf(server) or thread.hasFloorHere(client);
}

/// Veces que se recalculó el suelo de un servidor.
pub fn boosts() u64 {
    return boost_count;
}

/// Veces que se rehízo la herencia de una cadena.
pub fn recomputations() u64 {
    return recompute_count;
}

/// Si el servidor tiene respuestas aplazadas, pasa a usar el contexto del cliente
/// aplazado más prioritario. SPARK solo deja cambiar a uno de más prioridad, así
/// que basta con ofrecerle todos: se queda con el mayor.
fn readoptContexts(server: u64) void {
    if (!deferring[server]) return;
    var pending = false;
    var client: u64 = 1;
    while (client < thread.max_threads) : (client += 1) {
        if (abi.fb_ipc_waits_for(client) != server) continue;
        pending = true;
        if (thread.adopt(server, client)) readopted_count += 1;
    }
    if (!pending) deferring[server] = false;
}

/// Rehace la herencia de la cadena que empieza en `server` tras algo que
/// cambia la urgencia de quien espera sin pasar por el IPC: cancelar una
/// espera (al matar) o cambiar los parámetros de un hilo bloqueado.
///
/// Por qué basta esta cadena: lo que cambia es la urgencia de un hilo que
/// espera a `server` y la de quienes usan su contexto, que se lo prestó al
/// llamar y por eso son justo los de más abajo en la cadena. El último, que no
/// espera a nadie, vuelve antes a elegir entre sus aplazados. Luego SPARK
/// (Inherit_Gate.Refresh_Chain) recalcula cada suelo de arriba abajo y
/// demuestra que la regla queda cumplida en todos los eslabones.
pub fn refreshChain(server: u64) void {
    if (server == 0 or server >= thread.max_threads) return;
    recompute_count += 1;
    var last = server;
    for (0..thread.max_threads) |_| {
        const next = abi.fb_ipc_waits_for(last);
        if (next == 0) break;
        last = next;
    } else @panic("la cadena de espera tiene un ciclo");
    readoptContexts(last);
    thread.refreshFloorChain(server);
}

/// La regla de la herencia, comprobada con la misma definición que SPARK
/// demuestra (Inherit_Gate.Holds). Con el cerrojo global.
pub fn checkInheritance() void {
    if (!thread.inheritanceHolds()) @panic("un servidor corre con menos urgencia que su cliente");
}

/// Para las autopruebas: si la regla se cumple ahora, tomando el global.
pub fn ruleHolds() bool {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    kernel_lock.enter();
    defer kernel_lock.leave();
    return thread.inheritanceHolds();
}

/// Respuestas aplazadas desde el arranque.
pub fn deferrals() u64 {
    return deferred_count;
}

/// Veces que un servidor volvió a tomar el contexto de un cliente aplazado.
pub fn readoptions() u64 {
    return readopted_count;
}

fn endpointOf(space: u64, cap: u64, right: u64) ?u64 {
    const object = abi.fb_cap_check(space, cap, abi.FB_CAP_ENDPOINT, right);
    return if (object == abi.FB_CAP_NO_OBJECT) null else object;
}

/// El emisor recibe en a0 si la cesión de la capability salió bien.
fn deliver(sender: *abi.fb_trap_frame, sender_id: u64, receiver: *abi.fb_trap_frame, receiver_id: u64) void {
    const destination = receiver.regs[a1];
    const offered = sender.regs[a5];
    receiver.regs[a6] = sent_badge[sender_id];

    receiver.regs[a1] = sender.regs[a1];
    receiver.regs[a2] = sender.regs[a2];
    receiver.regs[a3] = sender.regs[a3];
    receiver.regs[a4] = sender.regs[a4];
    receiver.regs[a0] = 0;
    receiver.regs[a5] = 0;
    sender.regs[a0] = 0;

    if (offered == abi.FB_CAP_SLOT_NONE) return;

    const moved = destination != abi.FB_CAP_SLOT_NONE and
        abi.fb_cap_transfer(process.spaceOf(sender_id), offered, process.spaceOf(receiver_id), destination) == abi.FB_CAP_OK;
    if (moved) {
        receiver.regs[a5] = abi.FB_MSG_CAP;
    } else {
        sender.regs[a0] = abi.FB_ERR_CAP;
    }
}

fn deliverSignal(receiver: *abi.fb_trap_frame) void {
    receiver.regs[a0] = 0;
    receiver.regs[a1] = 0;
    receiver.regs[a2] = 0;
    receiver.regs[a3] = 0;
    receiver.regs[a4] = 0;
    receiver.regs[a5] = abi.FB_MSG_SIGNAL;
    receiver.regs[a6] = 0;
}

fn takeWaiting(id: u64) *abi.fb_trap_frame {
    const frame = waiting[id] orelse @panic("hilo emparejado sin marco de espera");
    waiting[id] = null;
    return frame;
}

/// Tras despertar: un proceso con orden de morir no vuelve a modo usuario.
fn finishWait(frame: *abi.fb_trap_frame, id: u64) u64 {
    if (process.killRequested()) {
        waiting[id] = null;
        process.terminateCurrent(.{ .kind = .killed });
    }
    return frame.regs[a0];
}

/// Espera a que el otro extremo complete la operación, que deja el resultado en a0.
fn wait(frame: *abi.fb_trap_frame, id: u64) u64 {
    waiting[id] = frame;
    thread.block();
    return finishWait(frame, id);
}

fn waitSwitchingTo(frame: *abi.fb_trap_frame, id: u64, peer: u64, donate: bool) u64 {
    waiting[id] = frame;
    thread.blockAndSwitchTo(peer, donate);
    return finishWait(frame, id);
}

/// Toma el mensaje del emisor. Si hizo una llamada, sigue esperando la respuesta.
fn acceptSender(peer: u64, frame: *abi.fb_trap_frame, id: u64) void {
    const sender = takeWaiting(peer);
    deliver(sender, peer, frame, id);
    if (abi.fb_ipc_waits_for(peer) != 0) {
        waiting[peer] = sender;
        frame.regs[a5] = abi.FB_MSG_CALL;
        thread.acceptCall(peer);
        if (needsFloor(peer, id)) updateBoost(id);
    } else {
        thread.unblock(peer);
    }
}

pub fn send(frame: *abi.fb_trap_frame) u64 {
    const id = thread.currentId();
    const space = process.currentSpace();
    const endpoint = endpointOf(space, frame.regs[a0], abi.FB_RIGHT_SEND) orelse return abi.FB_ERR_CAP;

    // Ceder una capability exige el derecho Grant sobre el endpoint.
    const offered = frame.regs[a5];
    if (offered != abi.FB_CAP_SLOT_NONE) {
        if (endpointOf(space, frame.regs[a0], abi.FB_RIGHT_GRANT) == null) return abi.FB_ERR_CAP;
        if (abi.fb_cap_held(space, offered) == 0) return abi.FB_ERR_CAP;
    }

    sent_badge[id] = abi.fb_cap_badge(space, frame.regs[a0]);
    const peer = abi.fb_ipc_send(endpoint, id);
    if (peer == abi.FB_IPC_INVALID) return abi.FB_ERR_INVALID;
    if (peer == abi.FB_IPC_QUEUED) return wait(frame, id);

    deliver(frame, id, takeWaiting(peer), peer);
    thread.unblock(peer);
    return frame.regs[a0];
}

pub fn recv(frame: *abi.fb_trap_frame) u64 {
    const id = thread.currentId();
    const endpoint = endpointOf(process.currentSpace(), frame.regs[a0], abi.FB_RIGHT_RECV) orelse return abi.FB_ERR_CAP;

    const peer = abi.fb_ipc_recv(endpoint, id);
    if (peer == abi.FB_IPC_INVALID) return abi.FB_ERR_INVALID;
    if (peer == abi.FB_IPC_QUEUED) return wait(frame, id);
    if (peer == abi.FB_IPC_SIGNAL) {
        deliverSignal(frame);
        return 0;
    }

    acceptSender(peer, frame, id);
    return frame.regs[a0];
}

/// Como send, pero sin esperar y sin ceder capabilities.
pub fn trySend(frame: *abi.fb_trap_frame) u64 {
    const id = thread.currentId();
    const space = process.currentSpace();
    const endpoint = endpointOf(space, frame.regs[a0], abi.FB_RIGHT_SEND) orelse return abi.FB_ERR_CAP;
    if (frame.regs[a5] != abi.FB_CAP_SLOT_NONE) return abi.FB_ERR_INVALID;

    sent_badge[id] = abi.fb_cap_badge(space, frame.regs[a0]);
    const peer = abi.fb_ipc_try_send(endpoint);
    if (peer == abi.FB_IPC_INVALID) return abi.FB_ERR_INVALID;
    if (peer == abi.FB_IPC_NOT_READY) return abi.FB_ERR_NOT_READY;

    deliver(frame, id, takeWaiting(peer), peer);
    thread.unblock(peer);
    return frame.regs[a0];
}

/// Envía y espera la respuesta. Una llamada no puede ceder capabilities.
pub fn call(frame: *abi.fb_trap_frame) u64 {
    const id = thread.currentId();
    const space = process.currentSpace();
    const endpoint = endpointOf(space, frame.regs[a0], abi.FB_RIGHT_SEND) orelse return abi.FB_ERR_CAP;
    if (frame.regs[a5] != abi.FB_CAP_SLOT_NONE) return abi.FB_ERR_INVALID;

    sent_badge[id] = abi.fb_cap_badge(space, frame.regs[a0]);
    const peer = abi.fb_ipc_call(endpoint, id);
    if (peer == abi.FB_IPC_INVALID) return abi.FB_ERR_INVALID;
    if (peer == abi.FB_IPC_QUEUED) return wait(frame, id);

    const server = takeWaiting(peer);
    deliver(frame, id, server, peer);
    server.regs[a5] = abi.FB_MSG_CALL;
    if (thread.homeOf(peer) != thread.homeOf(id)) {
        // Otro hart, sin cesión directa ni préstamo: llamar y heredar. El
        // servidor hereda y despierta en una sola pasada, así el aviso a su
        // hart ya cuenta con lo heredado.
        boost_count += 1;
        thread.wakeInheriting(peer);
        return wait(frame, id);
    }
    // Con suelo propio, el contexto prestado no lleva toda la urgencia.
    if (thread.hasFloorHere(id)) updateBoost(peer);
    return waitSwitchingTo(frame, id, peer, true);
}

/// `server` acaba de contestar a `caller`: lo despierta y deja al día la
/// herencia de `server`. Si el cliente es de otro hart y el servidor heredaba,
/// responder y heredar van en una sola pasada.
fn release(server: u64, caller: u64) void {
    if (thread.hasFloorHere(server)) {
        if (thread.homeOf(caller) != thread.homeOf(server)) {
            boost_count += 1;
            thread.replyWaking(server, caller, false);
        } else {
            thread.unblock(caller);
            updateBoost(server);
        }
    } else {
        thread.unblock(caller);
    }
    readoptContexts(server);
}

/// Copia la respuesta al cliente, que sigue bloqueado hasta que alguien lo despierte.
fn answer(caller: u64, server: *abi.fb_trap_frame) void {
    const target = takeWaiting(caller);
    target.regs[a0] = 0;
    target.regs[a1] = server.regs[a1];
    target.regs[a2] = server.regs[a2];
    target.regs[a3] = server.regs[a3];
    target.regs[a4] = server.regs[a4];
    target.regs[a5] = 0;
}

pub fn reply(frame: *abi.fb_trap_frame) u64 {
    const caller = abi.fb_ipc_reply(thread.currentId());
    if (caller == abi.FB_IPC_INVALID) return abi.FB_ERR_INVALID;

    answer(caller, frame);
    release(thread.currentId(), caller);
    return 0;
}

/// Aplaza la respuesta que se debe. El cliente sigue esperando y el servidor
/// puede recibir otras peticiones, conservando el contexto prestado.
pub fn deferReply(frame: *abi.fb_trap_frame) u64 {
    const id = thread.currentId();
    const caller = abi.fb_ipc_defer(id);
    if (caller == abi.FB_IPC_INVALID) return abi.FB_ERR_INVALID;
    deferring[id] = true;
    deferred_count += 1;
    frame.regs[a1] = caller;
    return 0;
}

/// Contesta una respuesta aplazada. SPARK solo lo permite si ese cliente llamó
/// a este servidor y su respuesta se aplazó.
pub fn replyTo(frame: *abi.fb_trap_frame) u64 {
    const caller = frame.regs[a0];
    if (abi.fb_ipc_reply_held(thread.currentId(), caller) == abi.FB_IPC_INVALID) return abi.FB_ERR_INVALID;
    answer(caller, frame);
    release(thread.currentId(), caller);
    return 0;
}

/// Si el cliente ya no existe no hay nada que contestar: se sigue recibiendo.
pub fn replyRecv(frame: *abi.fb_trap_frame) u64 {
    const id = thread.currentId();
    const endpoint = endpointOf(process.currentSpace(), frame.regs[a0], abi.FB_RIGHT_RECV) orelse return abi.FB_ERR_CAP;

    const caller = abi.fb_ipc_reply(id);
    const answered = caller != abi.FB_IPC_INVALID;
    if (answered) answer(caller, frame);

    frame.regs[a1] = abi.FB_CAP_SLOT_NONE;
    const peer = abi.fb_ipc_recv(endpoint, id);

    if (peer == abi.FB_IPC_QUEUED) {
        // Con respuestas aplazadas, antes de esperar hay que volver a tomar un
        // contexto: no se cede la CPU directamente.
        if (answered and !deferring[id]) {
            if (thread.hasFloorHere(id)) {
                if (thread.homeOf(caller) != thread.homeOf(id)) {
                    // Otro hart: responder y heredar, y esperar.
                    boost_count += 1;
                    thread.replyWaking(id, caller, true);
                    return wait(frame, id);
                }
                updateBoost(id);
            }
            return waitSwitchingTo(frame, id, caller, false);
        }
        if (answered) release(id, caller);
        return wait(frame, id);
    }

    if (answered) release(id, caller);
    if (peer == abi.FB_IPC_INVALID) return abi.FB_ERR_INVALID;
    if (peer == abi.FB_IPC_SIGNAL) {
        deliverSignal(frame);
        return 0;
    }

    acceptSender(peer, frame, id);
    return frame.regs[a0];
}

/// Avisa de una interrupción. Devuelve si despertó a un receptor.
pub fn signal(endpoint: u64) bool {
    const peer = abi.fb_ipc_signal(endpoint);
    if (peer == abi.FB_IPC_INVALID) @panic("senal a un endpoint invalido");
    if (peer == abi.FB_IPC_QUEUED) return false;

    deliverSignal(takeWaiting(peer));
    thread.unblock(peer);
    return true;
}

fn failWaiter(id: u64) void {
    takeWaiting(id).regs[a0] = abi.FB_ERR_PEER;
    thread.unblock(id);
}

/// El proceso termina: nadie debe quedarse esperando algo que ya no llegará.
/// Debe llamarse mientras el proceso conserva sus capabilities.
pub fn onDeath(id: u64, space: u64) void {
    deferring[id] = false;
    const orphan = abi.fb_ipc_reply(id);
    if (orphan != abi.FB_IPC_INVALID) failWaiter(orphan);
    while (true) {
        const held = abi.fb_ipc_abort_held(id);
        if (held == abi.FB_IPC_INVALID) break;
        failWaiter(held);
    }

    var endpoint: u64 = 0;
    while (endpoint < abi.FB_IPC_ENDPOINTS) : (endpoint += 1) {
        if (abi.fb_cap_holds_receive(space, endpoint) == 0) continue;
        if (abi.fb_cap_other_receiver(space, endpoint) != 0) continue;

        while (true) {
            const sender = abi.fb_ipc_abort_sender(endpoint);
            if (sender == abi.FB_IPC_NOT_READY or sender == abi.FB_IPC_INVALID) break;
            failWaiter(sender);
        }
    }
}
