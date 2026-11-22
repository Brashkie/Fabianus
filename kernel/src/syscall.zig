// SPDX-License-Identifier: GPL-3.0-or-later
//! Llamadas al sistema. El kernel nunca toca una dirección de usuario directamente:
//! cada página se traduce con la función demostrada en SPARK y se lee por su
//! dirección física. Por eso sstatus.SUM está siempre a cero.
//!
//! Toda operación con autoridad exige una capability. Solo exit, yield y la
//! consulta del propio identificador no afectan a nada más que al proceso.

const abi = @import("abi.zig").c;
const device = @import("device.zig");
const ipc = @import("ipc.zig");
const process = @import("process.zig");
const region = @import("region.zig");
const sleep = @import("sleep.zig");
const thread = @import("thread.zig");
const uart = @import("uart.zig");

const reg_a0: usize = 10;
const reg_a1: usize = 11;
const reg_a2: usize = 12;
const reg_a7: usize = 17;

const ecall_length: u64 = 4;
const page_size: u64 = abi.FB_PAGE_SIZE;

var last_write: [abi.FB_SYS_WRITE_MAX]u8 = undefined;
var last_write_length: usize = 0;

/// Lo último que imprimió un proceso, para las autopruebas.
pub fn lastWrite() []const u8 {
    return last_write[0..last_write_length];
}

/// Copia todo o nada: una dirección inválida no deja ninguna salida a medias.
fn copyFromUser(space: u64, source: u64, destination: []u8) bool {
    var copied: usize = 0;
    while (copied < destination.len) {
        // Si la suma da la vuelta, cae por debajo de la ventana de usuario y se rechaza.
        const va = source +% copied;
        const physical = abi.fb_uspace_translate(space, va, abi.FB_ACCESS_READ);
        if (physical == 0) return false;

        const offset = va & (page_size - 1);
        const length = @min(destination.len - copied, page_size - offset);
        const page: [*]const u8 = @ptrFromInt(physical + offset);
        @memcpy(destination[copied..][0..length], page[0..length]);
        copied += length;
    }
    return true;
}

fn write(cap: u64, address: u64, length: u64) u64 {
    const object = abi.fb_cap_check(process.currentSpace(), cap, abi.FB_CAP_CONSOLE, abi.FB_RIGHT_SEND);
    if (object == abi.FB_CAP_NO_OBJECT) return abi.FB_ERR_CAP;

    // La UART tiene un driver: el kernel no escribe en un dispositivo ajeno.
    if (device.uartOwned()) return abi.FB_ERR_BUSY;

    if (length > abi.FB_SYS_WRITE_MAX) return abi.FB_ERR_INVALID;

    var buffer: [abi.FB_SYS_WRITE_MAX]u8 = undefined;
    const data = buffer[0..length];
    if (!copyFromUser(process.currentSpace(), address, data)) return abi.FB_ERR_FAULT;

    uart.print(data);
    @memcpy(last_write[0..length], data);
    last_write_length = length;
    return length;
}

fn capStatus(status: u64) u64 {
    return if (status == abi.FB_CAP_OK) 0 else abi.FB_ERR_CAP;
}

/// Se ejecuta con las interrupciones apagadas, sobre la pila de traps del hilo.
/// Fija prioridad y presupuesto del propio hilo. Exige una capability de
/// planificación, y la prioridad no puede pasar de la que esta autoriza.
fn schedSet(cap: u64, level: u64, budget: u64) u64 {
    const max_level = abi.fb_cap_check(process.currentSpace(), cap, abi.FB_CAP_SCHED, abi.FB_RIGHT_SEND);
    if (max_level == abi.FB_CAP_NO_OBJECT) return abi.FB_ERR_CAP;
    if (level > max_level or budget == 0 or budget > abi.FB_SCHED_MAX_BUDGET) return abi.FB_ERR_INVALID;
    thread.setParams(thread.currentId(), level, budget);
    return 0;
}

pub fn handle(frame: *abi.fb_trap_frame) void {
    // En Debug, como la comprobación de derechos del planificador: toda
    // llamada al sistema toca estado compartido y va con el cerrojo global.
    if (@import("builtin").mode == .Debug) {
        if (!@import("kernel_lock.zig").held()) @panic("llamada al sistema sin el cerrojo global");
        // Y la regla de la herencia, con todo lo anterior ya terminado.
        ipc.checkInheritance();
    }
    frame.sepc += ecall_length;

    // Con una orden de morir pendiente no se atiende nada: si no, una espera
    // sin fin (dormir, recibir sin emisor) la dejaría sin cumplir para
    // siempre. requestKill toma el global, así que o la vemos aquí o llega
    // cuando ya esperamos y cancela la espera.
    if (process.killRequestedAt(frame)) process.terminateCurrent(.{ .kind = .killed });

    const a0 = frame.regs[reg_a0];
    frame.regs[reg_a0] = switch (frame.regs[reg_a7]) {
        abi.FB_SYS_EXIT => process.terminateCurrent(.{ .kind = .exited, .value = a0 }),
        abi.FB_SYS_WRITE => write(a0, frame.regs[reg_a1], frame.regs[reg_a2]),
        abi.FB_SYS_SEND => ipc.send(frame),
        abi.FB_SYS_RECV => ipc.recv(frame),
        abi.FB_SYS_TRY_SEND => ipc.trySend(frame),
        abi.FB_SYS_CALL => ipc.call(frame),
        abi.FB_SYS_REPLY => ipc.reply(frame),
        abi.FB_SYS_REPLY_RECV => ipc.replyRecv(frame),
        abi.FB_SYS_DEVICE_MAP => device.map(a0),
        abi.FB_SYS_IRQ_BIND => device.bind(a0, frame.regs[reg_a1]),
        abi.FB_SYS_IRQ_ACK => device.acknowledge(a0),
        abi.FB_SYS_CAP_DERIVE => capStatus(abi.fb_cap_derive(process.currentSpace(), a0, frame.regs[reg_a1], frame.regs[reg_a2])),
        abi.FB_SYS_CAP_DELETE => capStatus(abi.fb_cap_delete(process.currentSpace(), a0)),
        abi.FB_SYS_YIELD => blk: {
            thread.yield();
            break :blk 0;
        },
        abi.FB_SYS_THREAD_ID => thread.currentId(),
        abi.FB_SYS_SCHED_SET => schedSet(a0, frame.regs[reg_a1], frame.regs[reg_a2]),
        abi.FB_SYS_DEFER => ipc.deferReply(frame),
        abi.FB_SYS_REPLY_TO => ipc.replyTo(frame),
        abi.FB_SYS_REGION_MAP => region.map(process.currentSpace(), a0, frame.regs[reg_a1]),
        abi.FB_SYS_DMA_ADDRESS => region.dmaAddress(process.currentSpace(), a0, frame.regs[reg_a1], frame.regs[reg_a2]),
        abi.FB_SYS_SLEEP_UNTIL => blk: {
            const status = sleep.sleepUntil(a0);
            // Si lo despertaron para matarlo, muere ya.
            if (process.killRequested()) process.terminateCurrent(.{ .kind = .killed });
            break :blk status;
        },
        else => abi.FB_ERR_NOSYS,
    };
}
