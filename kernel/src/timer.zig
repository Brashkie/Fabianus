// SPDX-License-Identifier: GPL-3.0-or-later
//! Timer periódico de supervisor basado en la extensión Sstc. Cada hart tiene
//! el suyo (stimecmp es por hart), así que el estado va por hart.

const abi = @import("abi.zig").c;
const hart = @import("hart.zig");
const riscv = @import("riscv.zig");
const sleep = @import("sleep.zig");

pub const hz: u64 = 100;
pub const interval: u64 = abi.FB_TIMEBASE_HZ / hz;

const sie_stie: u64 = 1 << 5;

/// El timer de cada hart, en su propia línea de caché.
const Local = struct {
    tick_count: u64 align(64) = 0,
    deadline: u64 = 0,
    armed: u64 = 0,
    early_count: u64 = 0,
    idle_sleeps: u64 = 0,
};
var locals = [_]Local{.{}} ** hart.max;

inline fn here() *Local {
    return &locals[hart.id()];
}

pub fn now() u64 {
    return riscv.readCsr("time");
}

/// Periodos del timer de este hart.
pub fn ticks() u64 {
    return @atomicLoad(u64, &here().tick_count, .monotonic);
}

/// Cuántas veces el timer de este hart ha disparado antes de tiempo para
/// cortar un presupuesto.
pub fn earlyFires() u64 {
    return @atomicLoad(u64, &here().early_count, .monotonic);
}

/// Instante para el que está programada la próxima interrupción de este hart.
pub fn armedAt() u64 {
    return here().armed;
}

inline fn arm(l: *Local, target: u64) void {
    if (target == l.armed) return;
    l.armed = target;
    riscv.writeCsr("stimecmp", target);
}

/// Si el timer de este hart ya está en marcha.
pub fn running() bool {
    return here().deadline != 0;
}

/// Programa el primer vencimiento de este hart. Requiere interrupciones
/// globales para disparar.
pub fn init() void {
    const l = here();
    l.deadline = now() + interval;
    arm(l, l.deadline);
    riscv.setCsr("sie", sie_stie);
}

/// Atiende la interrupción: escribir stimecmp es lo que la desactiva.
pub fn onInterrupt() void {
    const l = here();
    if (now() < l.deadline) {
        // No era el periodo: era el final de un presupuesto.
        _ = @atomicRmw(u64, &l.early_count, .Add, 1, .monotonic);
        l.armed = l.deadline;
        riscv.writeCsr("stimecmp", l.deadline);
        return;
    }

    _ = @atomicRmw(u64, &l.tick_count, .Add, 1, .monotonic);

    // Los vencimientos se suman para no acumular deriva. Si el kernel se
    // retrasó más de un periodo, se salta para no encadenar interrupciones.
    l.deadline += interval;
    const current = now();
    if (l.deadline <= current) l.deadline = current + interval;
    l.armed = l.deadline;
    riscv.writeCsr("stimecmp", l.deadline);
}

/// El hart no tiene nada que hacer: duerme sin tick, hasta el primer hilo
/// dormido que tenga que despertar o hasta que otro hart le avise.
pub fn sleepIdle() void {
    const l = here();
    if (l.deadline == 0) return;
    _ = @atomicRmw(u64, &l.idle_sleeps, .Add, 1, .monotonic);
    arm(l, sleep.earliest());
}

/// Interrupciones de timer atendidas por un hart (periodos y finales de rodaja).
pub fn interruptsOf(h: u64) u64 {
    return @atomicLoad(u64, &locals[h].tick_count, .monotonic) + @atomicLoad(u64, &locals[h].early_count, .monotonic);
}

/// Veces que este hart se ha dormido sin tick.
pub fn idleSleeps(h: u64) u64 {
    return @atomicLoad(u64, &locals[h].idle_sleeps, .monotonic);
}

/// El hilo que entra no debe pasarse de su presupuesto: adelanta el disparo si
/// este se agota antes del próximo periodo. El periodo en sí no cambia.
pub fn limitSlice(current: u64, remaining: u64) void {
    const l = here();
    if (l.deadline == 0) return;
    // También antes del primer hilo dormido que tenga que despertar.
    arm(l, @min(@min(l.deadline, current + remaining), sleep.earliest()));
}
