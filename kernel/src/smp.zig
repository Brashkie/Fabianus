//! Arranque de los harts secundarios.
//!
//! Todos los harts preparan su modo máquina en boot.S. Los secundarios esperan
//! a que el kernel los suelte con fb_harts_release, toman su pila y llegan a
//! fb_secondary_main en modo supervisor. Allí preparan sus traps y su timer y
//! pasan a ser el hilo en reposo (hilo 0) de su propio planificador: duermen
//! con wfi y su timer los despierta para ejecutar los hilos que les toquen.

const abi = @import("abi.zig").c;
const build_options = @import("build_options");
const paging = @import("paging.zig");
const riscv = @import("riscv.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");
const trap = @import("trap.zig");

/// En .data y no en .bss: el hart de arranque borra .bss mientras los
/// secundarios ya la están leyendo.
export var fb_harts_release: u64 linksection(".data") = 0;

var harts_online: u64 = 1;

extern var __hart_area_start: u8;

pub const Stack = struct { bottom: u64, top: u64 };

/// Cada hart secundario: guarda, pila, guarda y pila de traps.
const hart_slot: u64 = 2 * abi.FB_PAGE_SIZE + abi.FB_HART_STACK_SIZE + hart_trap_stack_size;
const hart_trap_stack_size: u64 = 8 * 1024;

fn hartSlot(hart: u64) u64 {
    return @intFromPtr(&__hart_area_start) + (hart - 1) * hart_slot;
}

/// La pila de un hart secundario (1 .. FB_MAX_HARTS - 1).
pub fn hartStack(hart: u64) Stack {
    const bottom = hartSlot(hart) + abi.FB_PAGE_SIZE;
    return .{ .bottom = bottom, .top = bottom + abi.FB_HART_STACK_SIZE };
}

/// La pila de traps de un hart secundario.
pub fn hartTrapStack(hart: u64) Stack {
    const bottom = hartStack(hart).top + abi.FB_PAGE_SIZE;
    return .{ .bottom = bottom, .top = bottom + hart_trap_stack_size };
}

/// Suelta a los secundarios y espera a que se registren. Devuelve cuántos
/// harts hay en línea, contando el de arranque.
pub fn start(expected: u64) u64 {
    @atomicStore(u64, &fb_harts_release, 1, .release);
    const begin = timer.now();
    while (@atomicLoad(u64, &harts_online, .acquire) < expected) {
        if (timer.now() - begin > abi.FB_TIMEBASE_HZ) break;
    }
    return online();
}

pub fn online() u64 {
    return @atomicLoad(u64, &harts_online, .acquire);
}

export fn fb_secondary_main(hart: u64) callconv(.c) noreturn {
    paging.activate(paging.kernelSatp());
    trap.initHart(hartTrapStack(hart).top);
    // Como en el hart de arranque: el usuario lee el reloj, y en la compilación
    // de medida también instret.
    riscv.writeCsr("scounteren", if (build_options.bench) (1 << 1) | (1 << 2) else 1 << 1);
    {
        const saved = riscv.disableInterruptsSaving();
        defer riscv.restoreInterrupts(saved);
        thread.initHart();
        // El hilo en reposo, con la prioridad mínima: cualquier hilo normal
        // que despierte en este hart lo supera, y así se avisa al hart.
        thread.setParams(0, abi.FB_PRIO_LOW, abi.FB_SCHED_DEFAULT_BUDGET);
        timer.init();
    }
    _ = @atomicRmw(u64, &harts_online, .Add, 1, .acq_rel);

    // El hilo en reposo: con las interrupciones encendidas, wfi espera al
    // timer, que expropia y pone a correr lo que haya listo en este hart.
    riscv.enableInterrupts();
    while (true) riscv.waitForInterrupt();
}
