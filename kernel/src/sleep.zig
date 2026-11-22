// SPDX-License-Identifier: GPL-3.0-or-later
//! Hilos dormidos hasta un instante. SPARK guarda los vencimientos y demuestra
//! que nadie despierta antes del suyo; el temporizador se programa con el más
//! próximo, así que tampoco nadie se queda dormido sin interrupción prevista.

const abi = @import("abi.zig").c;
const riscv = @import("riscv.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");

var wake_count: u64 = 0;

/// Copia del vencimiento más próximo, para leerlo sin el cerrojo global: el
/// tick de cada hart mira aquí si tiene que tomarlo. Se actualiza, con el
/// global, tras cada cambio. Quien se duerme lo actualiza en su propio hart
/// antes de programar su timer, así que su hart nunca lo ve más tarde de lo
/// que es; otro hart puede verlo atrasado, y solo despertaría a alguien un
/// poco más tarde de lo que podría, nunca antes de su instante.
var earliest_copy: u64 = abi.FB_SLEEP_NONE;

/// Vuelve a copiar el vencimiento más próximo. Requiere el cerrojo global.
pub fn refresh() void {
    @atomicStore(u64, &earliest_copy, abi.fb_sleep_earliest(), .release);
}

/// El vencimiento más próximo, sin cerrojo.
pub fn earliest() u64 {
    return @atomicLoad(u64, &earliest_copy, .acquire);
}

/// Desde el tick, sin cerrojos: si ya venció alguien, toma el global y despierta.
pub fn wakeDue() void {
    if (timer.now() < earliest()) return;
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    wakeExpired();
}

/// Duerme el hilo actual hasta `deadline`. Si ya pasó, vuelve en seguida.
pub fn sleepUntil(deadline: u64) u64 {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    if (deadline <= timer.now()) return 0;
    if (abi.fb_sleep_arm(thread.currentId(), deadline) != abi.FB_SLEEP_OK) return abi.FB_ERR_INVALID;
    refresh();
    thread.block();
    return 0;
}

/// Despierta a todos los que ya vencieron. Requiere el cerrojo global.
pub fn wakeExpired() void {
    const time = timer.now();
    while (true) {
        const id = abi.fb_sleep_take_expired(time);
        if (id == abi.FB_SLEEP_NONE) return refresh();
        wake_count += 1;
        thread.unblock(id);
        // Quien despierta de dormir va el primero de su nivel. Tras esta
        // interrupción siempre se replanifica, así que corre en seguida si
        // nadie de más prioridad está listo.
        if (!thread.promote(id)) @panic("no se pudo adelantar al hilo despertado");
    }
}

/// Si el hilo dormía, lo despierta antes de tiempo. Devuelve si dormía.
pub fn cancel(id: u64) bool {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    if (abi.fb_sleep_disarm(id) != abi.FB_SLEEP_OK) return false;
    refresh();
    thread.unblock(id);
    return true;
}

/// Hilos despertados por su vencimiento desde el arranque.
pub fn wakes() u64 {
    return wake_count;
}
