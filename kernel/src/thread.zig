// SPDX-License-Identifier: GPL-3.0-or-later
//! Hilos del kernel: creación, cambio de contexto y expropiación.
//! Qué hilo se ejecuta lo decide el planificador demostrado en SPARK, con un
//! modelo por hart: cada hilo pertenece a un hart y solo corre en él. El hilo
//! 0 de cada hart es su hilo en reposo; el resto de identificadores son
//! globales. El estado de planificación va por hart.
//!
//! Cerrojos (kernel_lock.zig): el modelo y el estado local del propio hart se
//! tocan con el global o con el cerrojo del hart; los de otro hart, con los
//! dos (`lockHart`). Crear, terminar, cambiar parámetros y heredar prioridad
//! llevan siempre el global. Despertar o bloquear dentro de una llamada al
//! sistema se hace con el global tomado, que es lo que impide que la otra
//! parte responda antes de que este hilo esté bloqueado.

const abi_module = @import("abi.zig");
const abi = abi_module.c;
const build_options = @import("build_options");
const paging = @import("paging.zig");
const riscv = @import("riscv.zig");
const timer = @import("timer.zig");
const hart = @import("hart.zig");
const kernel_lock = @import("kernel_lock.zig");
const trap = @import("trap.zig");
const ipi = @import("ipi.zig");

extern var __thread_area_start: u8;
extern var __thread_area_end: u8;

pub const max_threads: usize = abi.FB_MAX_THREADS;
pub const Entry = *const fn (u64) callconv(.c) void;

pub const Interrupts = enum(u64) { off = 0, on = 1 };

const page_size: u64 = abi.FB_PAGE_SIZE;
const kernel_stack_size: u64 = 16 * 1024;
const trap_stack_size: u64 = 8 * 1024;
const slot_size: u64 = page_size + kernel_stack_size + page_size + trap_stack_size;

// fb_context_switch usa estos desplazamientos desde ensamblador.
comptime {
    const Context = abi.fb_context;
    if (@offsetOf(Context, "ra") != abi.FB_CTX_RA or
        @offsetOf(Context, "sp") != abi.FB_CTX_SP or
        @offsetOf(Context, "s") != abi.FB_CTX_S0 or
        @offsetOf(Context, "sscratch") != abi.FB_CTX_SSCRATCH or
        @sizeOf(Context) != abi.FB_CTX_SIZE)
    {
        @compileError("fb_context no coincide con FB_CTX_*");
    }
}

var contexts: [max_threads]abi.fb_context = undefined;
/// El hart de cada hilo.
var home_of = [_]hart.Index{0} ** max_threads;
var satps: [max_threads]u64 = undefined;
var kernel_satp: u64 = 0;

/// Lo que cada hart planifica por su cuenta, con su cerrojo. Va junto, con
/// una sola base, y empieza en su propia línea de caché: dos harts no
/// escriben en la misma.
const Local = struct {
    current: u64 align(64) = 0,
    started: bool = false,
    /// Un hilo despertado supera al actual: hay que cederle la CPU al salir del trap.
    reschedule_pending: bool = false,
    /// La próxima decisión es de una expropiación y se mide.
    measuring: bool = false,
    /// Instante de la última vez que se le cobró la CPU al hilo actual.
    last_charge: u64 = 0,
    /// Todo lo que se ha pasado a SPARK como tiempo gastado, y desde cuándo.
    billed_total: u64 = 0,
    billing_start: u64 = 0,
    /// Lo concedido a la última rodaja.
    granted: u64 = abi.FB_SCHED_MAX_BUDGET,
    current_quantum: u64 = base_quantum,
    switch_cost: u64 = 0,
    decision_started: u64 = 0,
    /// Cambios de hilo en este hart.
    switches: u64 = 0,
    /// El hilo 0 es distinto en cada hart: su hilo en reposo.
    idle_context: abi.fb_context = undefined,
};

var locals = [_]Local{.{}} ** hart.max;

inline fn here() *Local {
    return &locals[hart.id()];
}

var preemption_count: u64 = 0;
var direct_switch_count: u64 = 0;
var declined_count: u64 = 0;
var donation_count: u64 = 0;
var accepted_count: u64 = 0;
var wake_preemption_count: u64 = 0;

inline fn count(counter: *u64) void {
    _ = @atomicRmw(u64, counter, .Add, 1, .monotonic);
}

inline fn load(counter: *const u64) u64 {
    return @atomicLoad(u64, counter, .monotonic);
}

/// Tiempo de CPU de cada hilo: lo escribe su hart, con su cerrojo.
var cpu_time = [_]u64{0} ** max_threads;

/// El mayor exceso observado sobre lo concedido.
var max_overrun: u64 = 0;

inline fn me() hart.Index {
    return hart.id();
}

inline fn contextOfThread(l: *Local, id: u64) *abi.fb_context {
    return if (id == 0) &l.idle_context else &contexts[id];
}

/// El hart de un hilo; el hilo 0 es el del hart actual.
pub fn homeOf(id: u64) hart.Index {
    return if (id == 0) me() else home_of[id];
}

/// Una sección sobre el modelo de un hart, con las interrupciones apagadas:
/// el del propio hart, con el global si ya se tiene o si no con su cerrojo;
/// el de otro hart, con el global y su cerrojo.
pub const Section = struct { saved: u64, target: hart.Index, global: bool, local: bool };

inline fn lockHart(target: hart.Index) Section {
    var section = Section{ .saved = riscv.interruptsOffSaving(), .target = target, .global = false, .local = false };
    if (target == me()) {
        section.local = kernel_lock.enterOwn();
    } else {
        kernel_lock.enter();
        kernel_lock.enterHart(target);
        section.global = true;
    }
    return section;
}

inline fn unlock(section: Section) void {
    if (section.local) kernel_lock.leaveOwn();
    if (section.global) {
        kernel_lock.leaveHart(section.target);
        kernel_lock.leave();
    }
    riscv.restoreInterruptState(section.saved);
}

/// Para las autopruebas que llaman a SPARK directamente: el cerrojo del
/// modelo de este hart.
pub fn lockModel() Section {
    return lockHart(me());
}

pub fn unlockModel(section: Section) void {
    unlock(section);
}

/// En Debug, cada llamada a SPARK sobre el modelo de un hart comprueba que se
/// tiene derecho a él (al estilo de lockdep): una carrera que las pruebas no
/// llegan a provocar se ve igual.
const check_rights = @import("builtin").mode == .Debug;

inline fn right(target: hart.Index) hart.Index {
    if (check_rights and !kernel_lock.mayTouch(target)) @panic("modelo de un hart sin derecho a el");
    return target;
}

/// Lo que además cambia lo compartido: también con el global.
inline fn rightShared(target: hart.Index) hart.Index {
    if (check_rights and !kernel_lock.held()) @panic("planificador compartido sin el cerrojo global");
    return right(target);
}

pub const StackRange = struct { bottom: u64, top: u64 };

fn slotBase(id: u64) u64 {
    return @intFromPtr(&__thread_area_start) + (id - 1) * slot_size;
}

pub fn kernelStack(id: u64) StackRange {
    const bottom = slotBase(id) + page_size;
    return .{ .bottom = bottom, .top = bottom + kernel_stack_size };
}

pub fn trapStack(id: u64) StackRange {
    const bottom = kernelStack(id).top + page_size;
    return .{ .bottom = bottom, .top = bottom + trap_stack_size };
}

/// Página de guarda situada debajo de la pila del hilo.
pub fn kernelStackGuard(id: u64) u64 {
    return slotBase(id);
}

pub fn init() void {
    const area = @intFromPtr(&__thread_area_end) - @intFromPtr(&__thread_area_start);
    if (area != (max_threads - 1) * slot_size) @panic("linker.ld no coincide con thread.zig");
    if (abi.fb_sched_init() != abi.FB_SCHED_OK) @panic("no se pudo iniciar el planificador");
    kernel_satp = paging.kernelSatp();
    satps[0] = kernel_satp;
    initHart();
}

/// El hart actual empieza a planificar: su hilo 0 es el que está corriendo.
pub fn initHart() void {
    const section = lockHart(me());
    defer unlock(section);
    const l = here();
    l.current = 0;
    l.last_charge = timer.now();
    l.billing_start = l.last_charge;
    @atomicStore(bool, &l.started, true, .release);
    ipi.init();
}

/// Elige el siguiente hilo y cambia a él. Requiere derecho al modelo de este
/// hart (el global o su cerrojo).
fn schedule() void {
    const l = here();
    l.reschedule_pending = false;
    const time = timer.now();
    const elapsed = charge(l, time);
    l.billed_total += elapsed;
    const next = abi.fb_sched_pick(right(me()), elapsed);
    if (next == abi.FB_SCHED_NONE) @panic("no hay ningun hilo listo");
    grant(l, time, next);
    // En una expropiación se anota lo que costó decidir, desde la interrupción.
    if (l.measuring) {
        l.measuring = false;
        noteSwitch(l);
    }
    if (next == l.current) return;
    switchTo(l, next);
}

/// Cuenta como gastado por el hilo actual todo lo transcurrido desde el último cobro.
inline fn charge(l: *Local, time: u64) u64 {
    const elapsed = time - l.last_charge;
    l.last_charge = time;
    cpu_time[l.current] += elapsed;
    // Solo el benchmark necesita saber cuánto se pasa cada rodaja.
    if (build_options.bench and elapsed > l.granted) _ = @atomicRmw(u64, &max_overrun, .Max, elapsed - l.granted, .monotonic);
    return elapsed;
}

/// Cobra a SPARK lo gastado hasta ahora, sin elegir a nadie. Hace falta antes
/// de cambiar el contexto con que corre el hilo actual. Requiere derecho al
/// modelo de este hart.
fn chargeNow() u64 {
    const l = here();
    const time = timer.now();
    const elapsed = charge(l, time);
    l.billed_total += elapsed;
    if (abi.fb_sched_charge(right(me()), elapsed) != abi.FB_SCHED_OK) @panic("no se pudo cobrar el tiempo");
    return time;
}

/// Rodaja máxima: entre hilos del mismo nivel el turno rota cada cuanto. Los
/// presupuestos, y con ellos el reparto de la CPU, no cambian. El cuanto es
/// ocho veces lo que cuesta de media cambiar de hilo, entre 1 y 10 ms: en una
/// CPU lenta cada turno sigue dejando trabajo útil.
pub const base_quantum: u64 = abi.FB_TIMEBASE_HZ / 1000;

pub fn quantum() u64 {
    return here().current_quantum;
}

/// Lo que se concedió al hilo en curso de este hart en la última decisión.
pub fn grantedNow() u64 {
    return here().granted;
}

/// La rodaja que se concedería ahora a un hilo de este hart.
pub fn sliceFor(id: u64) u64 {
    const section = lockHart(me());
    defer unlock(section);
    const l = here();
    return sliceRule(abi.fb_sched_remaining(right(me()), id), id, l.current_quantum, l.switch_cost);
}

/// Coste medio de cambiar de hilo, en unidades del reloj.
pub fn switchCost() u64 {
    return here().switch_cost;
}

/// Anota lo que tardó la última decisión de una expropiación, desde la
/// interrupción hasta tener elegido el siguiente y programada su rodaja.
inline fn noteSwitch(l: *Local) void {
    const sample = timer.now() - l.decision_started;
    l.switch_cost = abi.fb_quantum_update(l.switch_cost, sample);
    l.current_quantum = abi.fb_quantum_for(l.switch_cost);
}

/// Por debajo de este coste medio (Quantum_Core.Noise) Slice_For da
/// min(resto, cuanto): el atajo es exacto.
const noise: u64 = 16;

/// La regla de la rodaja (Slice_For en SPARK) para un hilo de este hart, con
/// un atajo exacto: con el coste por debajo del ruido, Slice_For da min(resto,
/// cuanto). Una autoprueba compara el atajo con la función demostrada.
pub inline fn sliceRule(remaining: u64, next: u64, quantum_value: u64, cost: u64) u64 {
    if (cost < noise) return @min(remaining, quantum_value);
    return abi.fb_sched_slice(right(me()), next, quantum_value, cost);
}

inline fn grant(l: *Local, time: u64, next: u64) void {
    grantKnown(l, time, next, abi.fb_sched_remaining(right(me()), next));
}

/// Como grant, con lo que le queda al contexto de `next` ya sabido.
inline fn grantKnown(l: *Local, time: u64, next: u64, remaining: u64) void {
    l.granted = remaining;
    // El hilo en reposo de un secundario, sin nadie más listo: no hace falta
    // tick, los avisos lo despiertan. Así no compite por el cerrojo en balde.
    if (next == 0 and me() != 0 and abi.fb_sched_alone(right(me())) == 1) {
        timer.sleepIdle();
        return;
    }
    timer.limitSlice(time, sliceRule(l.granted, next, l.current_quantum, l.switch_cost));
}

/// Cambia de hilo dentro del mismo hart, con derecho a su modelo. Los
/// cerrojos pasan al hilo que entra (kernel_lock.resumeThread): cada hilo
/// guarda sus profundidades en su propia pila.
inline fn switchTo(l: *Local, next: u64) void {
    const previous = l.current;
    l.current = next;
    @atomicStore(u64, &l.switches, l.switches +% 1, .monotonic);
    if (satps[next] != satps[previous]) paging.activate(satps[next]);
    const global_depth = kernel_lock.globalDepth();
    const hart_depth = kernel_lock.hartDepth();
    abi.fb_context_switch(contextOfThread(l, previous), contextOfThread(l, next));
    kernel_lock.resumeThread(global_depth, hart_depth);
}

/// Primer código de un hilo nuevo (desde fb_thread_start): empieza sin
/// ningún cerrojo, y suelta los que tuviera quien le cedió la CPU.
export fn fb_thread_begin() callconv(.c) void {
    kernel_lock.resumeThread(0, 0);
}

/// Crea un hilo listo en el hart actual. Devuelve su identificador, o null si
/// no quedan huecos.
pub fn spawn(entry: Entry, argument: u64, interrupts: Interrupts) ?u64 {
    return spawnOn(me(), entry, argument, interrupts, kernel_satp);
}

/// Como `spawn`, pero el hilo se ejecuta con las tablas indicadas.
pub fn spawnInSpace(entry: Entry, argument: u64, interrupts: Interrupts, satp: u64) ?u64 {
    return spawnOn(me(), entry, argument, interrupts, satp);
}

/// Un hilo del kernel en el hart `target`.
pub fn spawnKernelOn(target: u64, entry: Entry, argument: u64, interrupts: Interrupts) ?u64 {
    return spawnOn(target, entry, argument, interrupts, kernel_satp);
}

/// Crea un hilo listo que pertenece al hart `target`. Con el global, y el
/// cerrojo de `target` desde que el hilo existe hasta que su contexto está
/// listo: su hart no puede elegirlo a medias.
pub fn spawnOn(target: u64, entry: Entry, argument: u64, interrupts: Interrupts, satp: u64) ?u64 {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    if (target >= hart.max or !@atomicLoad(bool, &locals[target].started, .acquire)) return null;
    const home: hart.Index = @intCast(target);

    const section = lockHart(home);
    const id = abi.fb_sched_create(rightShared(home));
    if (id == abi.FB_SCHED_NONE) {
        unlock(section);
        return null;
    }

    home_of[id] = home;
    satps[id] = satp;
    cpu_time[id] = 0;
    var saved_registers = [_]u64{0} ** 12;
    saved_registers[0] = @intFromPtr(entry);
    saved_registers[1] = argument;
    saved_registers[2] = @intFromEnum(interrupts);
    contexts[id] = .{
        .ra = @intFromPtr(&abi.fb_thread_start),
        .sp = kernelStack(id).top,
        .s = saved_registers,
        .sscratch = trap.stackTop(trapStack(id).top, target),
    };
    unlock(section);
    // Su hart puede estar dormido sin tick.
    if (home != me()) ipi.send(home);
    return id;
}

pub fn yield() void {
    const section = lockHart(me());
    defer unlock(section);
    schedule();
}

/// Bloquea el hilo actual hasta que otro llame a `unblock`.
pub fn block() void {
    const section = lockHart(me());
    defer unlock(section);
    if (abi.fb_sched_block(right(me()), here().current) != abi.FB_SCHED_OK) @panic("no se pudo bloquear el hilo");
    schedule();
}

/// Bloquea el hilo actual y despierta a `peer`, que estaba bloqueado. Si
/// `donate`, `peer` corre con el contexto del hilo actual hasta que le responda.
/// La CPU pasa directamente a `peer` si con ello no se salta ninguna prioridad;
/// el turno del round-robin no cambia.
pub fn blockAndSwitchTo(peer: u64, donate: bool) void {
    // Otro hart: sin cesión directa ni préstamo. Se le despierta y este se
    // bloquea; aquel lo verá en su próximo turno.
    if (homeOf(peer) != me()) {
        unblock(peer);
        block();
        return;
    }

    const section = lockHart(me());
    defer unlock(section);
    const l = here();
    const time = timer.now();
    const elapsed = time - l.last_charge;
    // Una sola llamada: la cesión, lo que le queda al contexto de `peer` y si
    // hubo préstamo (demostrado en Sched_Gate.Hand_Off_Grant).
    var granted: u64 = 0;
    var donated: u64 = 0;
    const status = abi.fb_sched_hand_off_grant(right(me()), peer, elapsed, @intFromBool(donate), &granted, &donated);
    if (status != abi.FB_SCHED_OK and status != abi.FB_SCHED_DECLINED) @panic("cesion directa invalida");
    l.billed_total += elapsed;
    _ = charge(l, time);
    if (donate and donated != 0) count(&donation_count);

    if (status == abi.FB_SCHED_OK) {
        grantKnown(l, time, peer, granted);
        count(&direct_switch_count);
        switchTo(l, peer);
        return;
    }

    // Hay alguien con más derecho a la CPU: decide el planificador.
    count(&declined_count);
    schedule();
}

/// `server` atiende a `client`, que espera su respuesta, y pasa a usar su
/// contexto. Si ya usaba uno prestado, solo lo cambia por el de un cliente de más
/// prioridad, y devuelve el anterior. Devuelve si tomó el contexto.
pub fn adopt(server: u64, client: u64) bool {
    // Los préstamos son dentro de un mismo hart.
    const home = homeOf(server);
    if (home != homeOf(client)) return false;

    const section = lockHart(home);
    defer unlock(section);
    const local = home == me();
    const time = if (local) chargeNow() else 0;
    const status = abi.fb_sched_adopt(right(home), server, client);
    if (status == abi.FB_SCHED_WRONG_STATE) return false;
    if (status != abi.FB_SCHED_OK) @panic("no se pudo adoptar el contexto");
    count(&donation_count);
    if (local) {
        const l = here();
        if (server == l.current) grant(l, time, l.current);
        if (abi.fb_sched_should_yield(right(me())) != 0) l.reschedule_pending = true;
    }
    return true;
}

/// El hilo actual atiende la llamada de `client`, que esperaba en cola.
pub fn acceptCall(client: u64) void {
    if (adopt(here().current, client)) count(&accepted_count);
}

pub fn donations() u64 {
    return load(&donation_count);
}

/// Llamadas recibidas de la cola en las que el servidor tomó el contexto.
pub fn acceptedCalls() u64 {
    return load(&accepted_count);
}

pub fn contextOf(id: u64) u64 {
    const home = homeOf(id);
    const section = lockHart(home);
    defer unlock(section);
    return abi.fb_sched_context(right(home), id);
}

pub fn directSwitches() u64 {
    return load(&direct_switch_count);
}

pub fn declinedSwitches() u64 {
    return load(&declined_count);
}

pub fn wakePreemptions() u64 {
    return load(&wake_preemption_count);
}

/// Fija la prioridad y el presupuesto de un hilo. Solo para el kernel: aumentar
/// un presupuesto aumenta lo que pueden tener que esperar los demás.
pub fn setParams(id: u64, level: u64, budget: u64) void {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    setParamsLocked(id, level, budget);
    // Si espera una respuesta, su nueva urgencia debe llegar a quien lo
    // atiende: quizá con otro contexto aplazado, quizá en otro hart.
    const server = abi.fb_ipc_waits_for(id);
    if (server != 0) @import("ipc.zig").refreshChain(server);
}

fn setParamsLocked(id: u64, level: u64, budget: u64) void {
    const home = homeOf(id);
    const section = lockHart(home);
    defer unlock(section);
    if (home != me()) {
        if (abi.fb_sched_set_params(rightShared(home), id, level, budget) != abi.FB_SCHED_OK) @panic("parametros de planificacion invalidos");
        return;
    }
    // Lo ya gastado corresponde al presupuesto anterior, no al que empieza ahora.
    const l = here();
    const time = chargeNow();
    if (abi.fb_sched_set_params(rightShared(home), id, level, budget) != abi.FB_SCHED_OK) @panic("parametros de planificacion invalidos");
    grant(l, time, l.current);
    if (abi.fb_sched_should_yield(right(me())) != 0) l.reschedule_pending = true;
}

/// Tiempo de CPU cobrado a un hilo desde que se creó.
pub fn cpuTime(id: u64) u64 {
    const section = lockHart(homeOf(id));
    defer unlock(section);
    return cpu_time[id];
}

/// Cada unidad de tiempo se cobra exactamente una vez: lo pasado a SPARK es
/// justo el tiempo transcurrido hasta el último cobro.
pub fn billingConsistent() bool {
    const section = lockHart(me());
    defer unlock(section);
    const l = here();
    return l.billed_total == l.last_charge - l.billing_start;
}

pub fn remainingOf(id: u64) u64 {
    const home = homeOf(id);
    const section = lockHart(home);
    defer unlock(section);
    return abi.fb_sched_remaining(right(home), id);
}

pub fn maxOverrun() u64 {
    return @atomicLoad(u64, &max_overrun, .monotonic);
}

pub fn resetMaxOverrun() void {
    @atomicStore(u64, &max_overrun, 0, .monotonic);
}

/// Al terminar una llamada al sistema: si despertó a alguien con más prioridad,
/// este se ejecuta ya, sin esperar al próximo periodo del timer.
pub fn rescheduleIfOutranked() void {
    if (!here().reschedule_pending) return;
    const section = lockHart(me());
    defer unlock(section);
    count(&wake_preemption_count);
    schedule();
}

pub fn unblock(id: u64) void {
    const home = homeOf(id);
    if (home != me()) {
        // De otro hart: se despierta en el modelo de su hart. Si allí supera
        // al que corre, SPARK dice a qué hart avisar (demostrado: al suyo).
        // El aviso sale ya sin el cerrojo de aquel hart.
        const section = lockHart(home);
        _ = right(home);
        const status = abi.fb_sched_wake_remote(id);
        unlock(section);
        if (status >= abi.FB_SCHED_NOTIFY_BASE) {
            ipi.send(status - abi.FB_SCHED_NOTIFY_BASE);
        } else if (status != abi.FB_SCHED_OK) {
            @panic("no se pudo desbloquear el hilo");
        }
        return;
    }
    const section = lockHart(home);
    defer unlock(section);
    // Si el hilo actual pierde su contexto al despertar `id` (era de `id`, o
    // `id` está antes en la misma cadena de préstamos), cobra antes.
    const l = here();
    const own = abi.fb_sched_context(right(home), l.current);
    const reclaims = id != l.current and (own == id or (own != l.current and abi.fb_sched_context(right(home), id) == own));
    const time = if (reclaims) chargeNow() else 0;
    const status = abi.fb_sched_unblock(right(home), id);
    if (status == abi.FB_SCHED_YIELD) {
        l.reschedule_pending = true;
    } else if (status != abi.FB_SCHED_OK) {
        @panic("no se pudo desbloquear el hilo");
    }
    if (reclaims) grant(l, time, l.current);
}

/// Lo que hay que hacer tras cambiar el suelo de hilos de los harts de
/// `targets` (un bit por hart): en este, ceder si toca; en los demás, avisar.
/// Con el cerrojo global.
fn notifyHarts(targets: u64) void {
    var pending = targets;
    while (pending != 0) {
        const target: hart.Index = @intCast(@ctz(pending));
        pending &= pending - 1;
        if (target == me()) {
            const section = lockHart(me());
            if (abi.fb_sched_should_yield(right(me())) != 0) here().reschedule_pending = true;
            unlock(section);
        } else {
            ipi.send(target);
        }
    }
}

fn notifyMask(status: u64) u64 {
    if (status == abi.FB_SCHED_OK) return 0;
    if (status < abi.FB_SCHED_NOTIFY_BASE or status - abi.FB_SCHED_NOTIFY_BASE >= hart.max) @panic("no se pudo recalcular la herencia");
    return @as(u64, 1) << @intCast(status - abi.FB_SCHED_NOTIFY_BASE);
}

/// Recalcula el suelo de `server` con todos sus clientes, de cualquier hart
/// (SPARK: Inherit_Gate.Refresh). Con el cerrojo global.
pub fn refreshFloor(server: u64) void {
    const saved = riscv.interruptsOffSaving();
    _ = rightShared(me());
    kernel_lock.enterHarts(kernel_lock.all_harts);
    const status = abi.fb_inherit_refresh(server);
    kernel_lock.leaveHarts();
    riscv.restoreInterruptState(saved);
    notifyHarts(notifyMask(status));
}

inline fn hartBit(h: hart.Index) u64 {
    return @as(u64, 1) << @intCast(h);
}

/// Veces que una operación fusionada pidió más cerrojos de los dos harts.
var unheld_count: u64 = 0;

pub fn unheldRetries() u64 {
    return load(&unheld_count);
}

/// Llamar y heredar (SPARK: Inherit_Gate.Call_Wake). `server`, de otro hart y
/// bloqueado esperando peticiones, acaba de recibir una llamada: en una sola
/// pasada hereda el mayor nivel de sus clientes y despierta. Basta con los
/// cerrojos de este hart y del suyo; si tiene clientes en otros harts
/// (aplazados), SPARK lo dice sin tocar nada y se repite con todos.
/// Con el cerrojo global.
pub fn wakeInheriting(server: u64) void {
    const saved = riscv.interruptsOffSaving();
    _ = rightShared(me());
    var held = hartBit(me()) | hartBit(homeOf(server));
    var status: u64 = undefined;
    while (true) {
        kernel_lock.enterHarts(held);
        status = abi.fb_inherit_call_wake(server, held);
        kernel_lock.leaveHarts();
        if (status != abi.FB_INHERIT_UNHELD or held == kernel_lock.all_harts) break;
        count(&unheld_count);
        held = kernel_lock.all_harts;
    }
    riscv.restoreInterruptState(saved);
    if (status == abi.FB_INHERIT_UNHELD) @panic("faltan cerrojos para despertar al servidor");
    notifyHarts(notifyMask(status));
}

/// Responder y heredar (SPARK: Inherit_Gate.Reply_Wake). `server` acaba de
/// contestar a `client`, de otro hart: en una sola pasada despierta al
/// cliente y recalcula el suelo del servidor con los clientes que le quedan.
/// Mismos cerrojos que `wakeInheriting`. Si `blocking`, el servidor (el hilo
/// actual) va a bloquearse ya: este hart elegirá de todos modos y no hace
/// falta mirar si debe ceder. Con el cerrojo global.
pub fn replyWaking(server: u64, client: u64, blocking: bool) void {
    const saved = riscv.interruptsOffSaving();
    _ = rightShared(me());
    var held = hartBit(homeOf(server)) | hartBit(homeOf(client));
    var targets: u64 = 0;
    var status: u64 = undefined;
    while (true) {
        kernel_lock.enterHarts(held);
        status = abi.fb_inherit_reply_wake(server, client, held, &targets);
        kernel_lock.leaveHarts();
        if (status != abi.FB_INHERIT_UNHELD or held == kernel_lock.all_harts) break;
        count(&unheld_count);
        held = kernel_lock.all_harts;
    }
    riscv.restoreInterruptState(saved);
    if (status != abi.FB_SCHED_OK) @panic("no se pudo responder heredando");
    notifyHarts(if (blocking) targets & ~hartBit(me()) else targets);
}

/// Recalcula toda la cadena de espera que empieza en `server`
/// (SPARK: Inherit_Gate.Refresh_Chain). Con el cerrojo global.
pub fn refreshFloorChain(server: u64) void {
    const saved = riscv.interruptsOffSaving();
    _ = rightShared(me());
    kernel_lock.enterHarts(kernel_lock.all_harts);
    var targets: u64 = 0;
    const status = abi.fb_inherit_refresh_chain(server, &targets);
    kernel_lock.leaveHarts();
    riscv.restoreInterruptState(saved);
    if (status == abi.FB_INHERIT_CYCLE) @panic("la cadena de espera tiene un ciclo");
    if (status != abi.FB_SCHED_OK) @panic("no se pudo recalcular la cadena");
    notifyHarts(targets);
}

/// Si la regla de la herencia se cumple en todos los servidores
/// (SPARK: Inherit_Gate.Holds). Con el cerrojo global.
pub fn inheritanceHolds() bool {
    const saved = riscv.interruptsOffSaving();
    _ = rightShared(me());
    kernel_lock.enterHarts(kernel_lock.all_harts);
    const holds = abi.fb_inherit_holds() == 1;
    kernel_lock.leaveHarts();
    riscv.restoreInterruptState(saved);
    return holds;
}

/// Si un hilo de este hart hereda un suelo. Para el camino rápido del IPC:
/// con derecho al modelo propio (el global de la llamada al sistema), sin
/// tomar nada más.
pub inline fn hasFloorHere(id: u64) bool {
    if (check_rights) {
        if (homeOf(id) != me()) @panic("suelo de un hilo de otro hart sin su cerrojo");
        _ = right(me());
    }
    return abi.fb_sched_has_floor(id) != 0;
}


/// La prioridad con que corre un hilo, en el modelo de su hart.
pub fn priorityOf(id: u64) u64 {
    const section = lockHart(homeOf(id));
    defer unlock(section);
    _ = right(homeOf(id));
    return abi.fb_sched_priority_of(id);
}

/// El hilo pasa a ser el siguiente de su nivel, en el modelo de su hart.
pub fn promote(id: u64) bool {
    const home = homeOf(id);
    const section = lockHart(home);
    defer unlock(section);
    return abi.fb_sched_promote(right(home), id) == abi.FB_SCHED_OK;
}

pub fn isAlive(id: u64) bool {
    return state(id) != abi.FB_THREAD_FREE;
}

pub fn state(id: u64) u64 {
    const home = homeOf(id);
    const section = lockHart(home);
    defer unlock(section);
    return abi.fb_sched_state(right(home), id);
}

/// El hilo que corre ahora en el hart `h`, según su modelo.
pub fn runningOn(h: hart.Index) u64 {
    const section = lockHart(h);
    defer unlock(section);
    return abi.fb_sched_running(right(h));
}

pub inline fn currentId() u64 {
    return here().current;
}

/// Devuelve el hilo actual a las tablas del kernel, para poder destruir las suyas.
/// Requiere interrupciones apagadas.
pub fn useKernelSpace() void {
    const id = here().current;
    if (satps[id] == kernel_satp) return;
    satps[id] = kernel_satp;
    paging.activate(kernel_satp);
}

pub fn preemptions() u64 {
    return load(&preemption_count);
}

/// Llamado desde el manejador de traps en cada interrupción del timer, sin
/// el cerrojo global.
pub fn preempt() void {
    const l = here();
    if (!l.started) return;
    count(&preemption_count);
    const section = lockHart(me());
    defer unlock(section);
    // Solo se mide el coste de cambiar en las expropiaciones: es donde el
    // cuanto importa, y así ceder o hacer IPC no pagan la medida.
    l.decision_started = timer.now();
    l.measuring = true;
    schedule();
}

/// Llamado desde el manejador de traps cuando otro hart avisa a este: vuelve a
/// planificar, sin medir el coste como en una expropiación.
pub fn notified() void {
    const l = here();
    if (!l.started) return;
    const section = lockHart(me());
    defer unlock(section);
    const before = l.switches;
    schedule();
    if (l.switches != before) count(&notified_switch_count);
}

var notified_switch_count: u64 = 0;

/// Cambios de hilo en un hart.
pub fn switchesOf(h: u64) u64 {
    return @atomicLoad(u64, &locals[h].switches, .monotonic);
}

/// Avisos que acabaron en un cambio de hilo: el despertado corrió al momento.
pub fn notifiedSwitches() u64 {
    return load(&notified_switch_count);
}

export fn fb_thread_exit() callconv(.c) noreturn {
    riscv.disableInterrupts();
    // Terminar libera el hueco: con el global, que basta para el propio modelo.
    kernel_lock.enter();
    // Lo gastado hasta aquí se cobra al contexto con que corría.
    _ = chargeNow();
    if (abi.fb_sched_exit(rightShared(me()), here().current) != abi.FB_SCHED_OK) @panic("no se pudo terminar el hilo");
    schedule();
    @panic("un hilo terminado volvio a ejecutarse");
}

comptime {
    abi_module.checkParams(@TypeOf(abi.fb_thread_exit), @TypeOf(fb_thread_exit));
}
