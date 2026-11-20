//! Avisos entre harts (IPI).
//!
//! Para avisar a un hart, el kernel escribe 1 en su palabra msip del CLINT: es
//! lo único del CLINT que el PMP le deja tocar. Eso levanta una interrupción
//! de software de modo máquina en el destino. Su manejador en boot.S borra
//! msip y levanta la interrupción de software de supervisor, que atiende el
//! kernel del destino con el cerrojo de su hart: vuelve a planificar y, si
//! viene de modo usuario, mira si hay que matar al proceso.
//!
//! Con el cerrojo global tomado, el aviso solo se anota, y se envía al
//! soltarlo: el hilo despertado casi siempre se bloqueó dentro de una llamada
//! al sistema, con el global, y al volver a correr lo necesita; si no, se
//! quedaría girando en el cerrojo que aún tiene quien le avisó.

const abi = @import("abi.zig").c;
const hart = @import("hart.zig");
const kernel_lock = @import("kernel_lock.zig");
const riscv = @import("riscv.zig");

const sie_ssie: u64 = 1 << 1;
const sip_ssip: u64 = 1 << 1;

var sent_count: u64 = 0;
var deferred_count: u64 = 0;
var received_count = [_]u64{0} ** hart.max;

/// Activa la recepción de avisos en el hart actual.
pub fn init() void {
    riscv.setCsr("sie", sie_ssie);
}

/// Avisa al hart `target`; con el cerrojo global tomado, en cuanto se suelte.
pub fn send(target: u64) void {
    if (target >= hart.max) @panic("aviso a un hart que no existe");
    if (kernel_lock.deferIpi(@intCast(target))) {
        _ = @atomicRmw(u64, &deferred_count, .Add, 1, .monotonic);
        return;
    }
    deliver(target);
}

/// Envía los avisos anotados (un bit por hart). Lo llama kernel_lock al soltar
/// el cerrojo global, con las interrupciones apagadas.
pub fn deliverAll(harts: u64) void {
    var mask = harts;
    while (mask != 0) : (mask &= mask - 1) deliver(@ctz(mask));
}

/// El aviso se ve después de todo lo escrito antes, también lo escrito con un
/// cerrojo tomado: soltarlo es una escritura de liberación, y el destino toma
/// ese mismo cerrojo antes de leerlo (el de su hart para su modelo, el global
/// para lo demás).
fn deliver(target: u64) void {
    const msip: *volatile u32 = @ptrFromInt(abi.FB_CLINT_BASE + 4 * target);
    asm volatile ("fence w, o" ::: "memory");
    msip.* = 1;
    _ = @atomicRmw(u64, &sent_count, .Add, 1, .monotonic);
}

/// Atiende el aviso en el hart actual: borra la interrupción pendiente.
pub fn acknowledge() void {
    riscv.clearCsr("sip", sip_ssip);
    _ = @atomicRmw(u64, &received_count[hart.id()], .Add, 1, .monotonic);
}

pub fn sent() u64 {
    return @atomicLoad(u64, &sent_count, .monotonic);
}

/// Avisos que esperaron a que se soltara el cerrojo global.
pub fn deferred() u64 {
    return @atomicLoad(u64, &deferred_count, .monotonic);
}

/// Si este hart tiene avisos anotados sin enviar.
pub fn pendingHere() bool {
    return kernel_lock.ipisPending();
}

/// Avisos atendidos por un hart.
pub fn received(h: u64) u64 {
    return @atomicLoad(u64, &received_count[h], .monotonic);
}
