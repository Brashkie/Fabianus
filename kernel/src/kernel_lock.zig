//! Los cerrojos del kernel: uno global y uno por hart.
//!
//! El global protege todo lo que comparten los harts: IPC, procesos, memoria,
//! dormidos y lo compartido del planificador (el hart de cada hilo, sus
//! prioridades base y heredada, qué huecos están usados). El modelo SPARK del
//! planificador de cada hart y su estado local (hilo actual, rodaja, cobro)
//! los toca:
//!  - el propio hart, con el global o con el cerrojo del hart;
//!  - otro hart, con el global y con el cerrojo del hart.
//! Dos accesos de harts distintos nunca coinciden: si uno es de otro hart,
//! tiene el global, que excluye al dueño cuando trabaja con el global, y el
//! cerrojo del hart, que lo excluye cuando trabaja con ese. Así el tick, ceder
//! la CPU, los avisos y el cambio de hilo solo esperan al cerrojo de su hart,
//! y lo que ya va con el global (las llamadas al sistema) no paga otro más.
//!
//! Orden: el global antes que el de un hart, y nunca dos de hart a la vez. Con
//! el de un hart tomado no se pide el global; si se necesitan los dos, primero
//! el global. Así no hay ciclos de espera: ningún interbloqueo.
//!
//! La excepción es `enterHarts`: con el global, varios de hart en orden
//! ascendente, para leer a la vez los modelos de varios harts (la herencia de
//! prioridad). Tampoco crea ciclos: el global lo tiene un solo hart, y quien
//! tiene un cerrojo de hart sin el global no espera a ningún otro cerrojo.
//!
//! Los dos son recursivos por hart. Al cambiar de hilo los cerrojos pasan al
//! hilo que entra, cada uno con sus profundidades, que lleva en su pila
//! (`resumeThread`).

const abi = @import("abi.zig").c;
const build_options = @import("build_options");
const hart = @import("hart.zig");
const riscv = @import("riscv.zig");
const ipi = @import("ipi.zig");
const spinlock = @import("spinlock.zig");

/// De tiques: los harts entran en el orden en que llegan, sin inanición.
var global = spinlock.TicketLock{};

/// El cerrojo de cada hart, en su propia línea de caché.
const HartLock = struct { lock: spinlock.TicketLock align(64) = .{} };
var hart_locks = [_]HartLock{.{}} ** hart.max;

/// Lo que tiene cada hart, en su propia línea de caché: la profundidad del
/// global, los harts a los que avisar en cuanto esta vuelva a 0, y qué cerrojo
/// de hart tiene y con qué profundidad.
const Held = struct {
    global_depth: u64 align(64) = 0,
    pending_ipis: u64 = 0,
    hart_depth: u64 = 0,
    hart_held: hart.Index = 0,
    harts_held: u64 = 0,
};
var helds = [_]Held{.{}} ** hart.max;

inline fn here() *Held {
    return &helds[hart.id()];
}

/// Esperas de más de 100000 instrucciones (de toda la máquina), contadas
/// solo en la compilación de medida: al global y a los de hart.
var long_waits: u64 = 0;
var long_hart_waits: u64 = 0;

pub fn longWaits() u64 {
    return @atomicLoad(u64, &long_waits, .monotonic);
}

pub fn longHartWaits() u64 {
    return @atomicLoad(u64, &long_hart_waits, .monotonic);
}

inline fn acquire(lock: *spinlock.TicketLock, counter: *u64) void {
    if (!build_options.bench) return lock.acquire();
    const start = riscv.readCsr("instret");
    lock.acquire();
    if (riscv.readCsr("instret") - start > 100_000) _ = @atomicRmw(u64, counter, .Add, 1, .monotonic);
}

// --- El global ---

/// Requiere las interrupciones apagadas y no tener el cerrojo de ningún hart.
pub fn enter() void {
    const h = here();
    if (h.global_depth == 0) {
        if (h.hart_depth != 0) @panic("cerrojo global pedido con el de un hart tomado");
        acquire(&global, &long_waits);
    }
    h.global_depth += 1;
}

pub fn leave() void {
    const h = here();
    if (h.global_depth == 0) @panic("se solto el cerrojo del kernel sin tenerlo");
    h.global_depth -= 1;
    if (h.global_depth == 0) releaseGlobal(h);
}

fn releaseGlobal(h: *Held) void {
    global.release();
    // Los avisos anotados dentro, ya sin el cerrojo.
    if (h.pending_ipis != 0) {
        const pending = h.pending_ipis;
        h.pending_ipis = 0;
        ipi.deliverAll(pending);
    }
}

/// Si este hart tiene el cerrojo global.
pub inline fn held() bool {
    return here().global_depth != 0;
}

/// Si alguien tiene el cerrojo global.
pub fn globalBusy() bool {
    return global.held();
}

/// Profundidad del global en este hart.
pub inline fn globalDepth() u64 {
    return here().global_depth;
}

// --- Los de hart ---

/// Toma el cerrojo del hart `target`. Requiere las interrupciones apagadas y
/// no tener el de otro hart.
pub fn enterHart(target: hart.Index) void {
    const h = here();
    if (h.hart_depth != 0) {
        if (h.hart_held != target) @panic("dos cerrojos de hart a la vez");
    } else {
        if (h.harts_held != 0) @panic("cerrojo de hart pedido con varios tomados");
        acquire(&hart_locks[target].lock, &long_hart_waits);
        h.hart_held = target;
    }
    h.hart_depth += 1;
}

/// Con el global y sin ningún cerrojo de hart: toma los de los harts de
/// `mask` (un bit por hart), en orden ascendente. Requiere las interrupciones
/// apagadas.
pub fn enterHarts(mask: u64) void {
    const h = here();
    if (h.global_depth == 0) @panic("varios harts sin el cerrojo global");
    if (h.hart_depth != 0 or h.harts_held != 0) @panic("varios harts con uno ya tomado");
    if (mask == 0 or mask >> @intCast(hart_locks.len) != 0) @panic("mascara de harts invalida");
    var pending = mask;
    while (pending != 0) {
        acquire(&hart_locks[@ctz(pending)].lock, &long_hart_waits);
        pending &= pending - 1;
    }
    h.harts_held = mask;
}

pub fn leaveHarts() void {
    const h = here();
    if (h.harts_held == 0) @panic("se soltaron varios harts sin tenerlos");
    var pending = h.harts_held;
    h.harts_held = 0;
    while (pending != 0) {
        hart_locks[@ctz(pending)].lock.release();
        pending &= pending - 1;
    }
}

pub fn leaveHart(target: hart.Index) void {
    const h = here();
    if (h.hart_depth == 0 or h.hart_held != target) @panic("se solto un cerrojo de hart sin tenerlo");
    h.hart_depth -= 1;
    if (h.hart_depth == 0) hart_locks[target].lock.release();
}

/// Todos los harts.
pub const all_harts: u64 = (@as(u64, 1) << @intCast(hart.max)) - 1;

/// Derecho al modelo propio: con el global ya tomado basta y devuelve false;
/// si no, toma el cerrojo de este hart y devuelve true. Requiere las
/// interrupciones apagadas.
pub inline fn enterOwn() bool {
    const h = here();
    if (h.global_depth != 0) return false;
    const me = hart.id();
    if (h.hart_depth == 0) {
        acquire(&hart_locks[me].lock, &long_hart_waits);
        h.hart_held = me;
    } else if (h.hart_held != me) {
        @panic("dos cerrojos de hart a la vez");
    }
    h.hart_depth += 1;
    return true;
}

/// Suelta lo que tomó `enterOwn` cuando devolvió true.
pub inline fn leaveOwn() void {
    const h = here();
    if (h.hart_depth == 0) @panic("se solto un cerrojo de hart sin tenerlo");
    h.hart_depth -= 1;
    if (h.hart_depth == 0) hart_locks[h.hart_held].lock.release();
}

/// Si este hart tiene derecho al modelo del hart `target`: el propio, con el
/// global o con su cerrojo; el de otro hart, con el global y su cerrojo.
pub fn mayTouch(target: hart.Index) bool {
    const h = here();
    if (h.harts_held != 0) return h.global_depth != 0 and (h.harts_held >> @intCast(target)) & 1 != 0;
    const own_lock = h.hart_depth != 0 and h.hart_held == target;
    if (target == hart.id()) return h.global_depth != 0 or own_lock;
    return h.global_depth != 0 and own_lock;
}

/// Si este hart tiene el cerrojo del hart `target`.
pub fn heldHart(target: hart.Index) bool {
    const h = here();
    return h.hart_depth != 0 and h.hart_held == target;
}

/// Profundidad del cerrojo de hart en este hart.
pub inline fn hartDepth() u64 {
    return here().hart_depth;
}

/// Si el cerrojo del hart `target` está tomado por alguien.
pub fn hartBusy(target: hart.Index) bool {
    return hart_locks[target].lock.held();
}

// --- El cambio de hilo ---

/// Si este hart puede tocar su propio modelo: con el global o con su cerrojo.
pub fn ownsModel() bool {
    const h = here();
    return h.global_depth != 0 or (h.hart_depth != 0 and h.hart_held == hart.id());
}

/// Lo primero que hace un hilo al volver a correr tras un cambio de hilo: el
/// hart pasa a las profundidades de ese hilo. Durante el cambio el hart tenía
/// derecho a su modelo (el global o su cerrojo) con las profundidades del
/// hilo que salió. Si el que entra tiene los mismos cerrojos, que es lo
/// normal, solo cambian las profundidades.
pub inline fn resumeThread(global_depth: u64, hart_depth: u64) void {
    const h = here();
    if ((h.global_depth != 0) == (global_depth != 0) and (h.hart_depth != 0) == (hart_depth != 0)) {
        h.global_depth = global_depth;
        h.hart_depth = hart_depth;
        return;
    }
    resumeChanging(h, global_depth, hart_depth);
}

/// El que entra tiene otros cerrojos. El orden se respeta: si hace falta el
/// global y no se tiene, primero se suelta el del hart; el del hart se toma
/// con el global ya tomado o sin él; el global se suelta el último.
noinline fn resumeChanging(h: *Held, global_depth: u64, hart_depth: u64) void {
    const me = hart.id();
    if (!ownsModel() or (h.hart_depth != 0 and h.hart_held != me)) @panic("cambio de hilo sin derecho al modelo del hart");
    if (global_depth != 0 and h.global_depth == 0) {
        // Mientras no tiene ninguno, el modelo es coherente: el hilo que
        // corre ya es este, y nadie más lo toca sin el cerrojo del hart.
        hart_locks[me].lock.release();
        h.hart_depth = 0;
        acquire(&global, &long_waits);
        h.global_depth = global_depth;
    }
    if (hart_depth != 0 and h.hart_depth == 0) {
        acquire(&hart_locks[me].lock, &long_hart_waits);
        h.hart_held = me;
    } else if (hart_depth == 0 and h.hart_depth != 0) {
        hart_locks[me].lock.release();
    }
    h.hart_depth = hart_depth;
    if (global_depth == 0 and h.global_depth != 0) {
        h.global_depth = 0;
        releaseGlobal(h);
    } else {
        h.global_depth = global_depth;
    }
}

// --- Los avisos ---

/// Con el cerrojo global tomado, anota un aviso al hart `target` para
/// enviarlo al soltarlo y devuelve true; sin él, devuelve false.
pub fn deferIpi(target: u6) bool {
    const h = here();
    if (h.global_depth == 0) return false;
    h.pending_ipis |= @as(u64, 1) << target;
    return true;
}

/// Si este hart tiene avisos anotados sin enviar.
pub fn ipisPending() bool {
    return here().pending_ipis != 0;
}

comptime {
    if (abi.FB_MAX_HARTS > 64) @compileError("los avisos pendientes son una máscara de 64 bits");
}
