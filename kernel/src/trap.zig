//! Clasificación de traps en modo supervisor.

const abi_module = @import("abi.zig");
const abi = abi_module.c;
const device = @import("device.zig");
const process = @import("process.zig");
const riscv = @import("riscv.zig");
const syscall = @import("syscall.zig");
const thread = @import("thread.zig");
const sleep = @import("sleep.zig");
const timer = @import("timer.zig");
const hart = @import("hart.zig");
const ipi = @import("ipi.zig");
const kernel_lock = @import("kernel_lock.zig");
const uart = @import("uart.zig");

const interrupt_bit: u64 = 1 << 63;
const interrupt_supervisor_software: u64 = 1;
const interrupt_supervisor_timer: u64 = 5;
const interrupt_supervisor_external: u64 = 9;

pub const cause_load_access_fault: u64 = 5;
pub const cause_store_access_fault: u64 = 7;
pub const cause_illegal_instruction: u64 = 2;
pub const cause_breakpoint: u64 = 3;
pub const cause_instruction_page_fault: u64 = 12;
pub const cause_load_page_fault: u64 = 13;
pub const cause_store_page_fault: u64 = 15;
pub const cause_user_ecall: u64 = 8;

const sstatus_spp: u64 = 1 << 8;

const reg_ra: usize = 1;

extern var __trap_stack_top: u8;

const no_cause: u64 = ~@as(u64, 0);

var expected_cause: u64 = no_cause;
var expected_seen: bool = false;

// El ensamblador usa estos desplazamientos: deben coincidir con la estructura.
comptime {
    const Frame = abi.fb_trap_frame;
    if (@offsetOf(Frame, "regs") != abi.FB_TF_REGS or
        @offsetOf(Frame, "sepc") != abi.FB_TF_SEPC or
        @offsetOf(Frame, "sstatus") != abi.FB_TF_SSTATUS or
        @offsetOf(Frame, "scause") != abi.FB_TF_SCAUSE or
        @offsetOf(Frame, "stval") != abi.FB_TF_STVAL or
        @sizeOf(Frame) != abi.FB_TF_SIZE)
    {
        @compileError("fb_trap_frame no coincide con FB_TF_*");
    }
    abi_module.checkParams(@TypeOf(abi.fb_trap_handler), @TypeOf(fb_trap_handler));
}

/// Prepara los traps del hart actual: vector y pila de traps, con el número de
/// hart encima de la pila para que la entrada pueda recuperarlo.
pub fn initHart(trap_stack_top: u64) void {
    riscv.writeCsr("sscratch", stackTop(trap_stack_top, hart.id()));
    riscv.writeCsr("stvec", @intFromPtr(&abi.fb_trap_entry));
}

pub fn init() void {
    initHart(@intFromPtr(&__trap_stack_top));
}

/// La cima útil de una pila de traps: los 16 bytes de arriba guardan, en los
/// 8 superiores, el hart al que pertenece el hilo.
pub fn stackTop(top: u64, owner: u64) u64 {
    const word: *u64 = @ptrFromInt(top - 8);
    word.* = owner;
    return top - 16;
}

/// Anuncia que la siguiente excepción de esa causa es parte de una prueba:
/// el manejador la absorberá y saltará la instrucción que la provocó.
pub fn expectException(cause: u64) void {
    @atomicStore(bool, &expected_seen, false, .seq_cst);
    @atomicStore(u64, &expected_cause, cause, .seq_cst);
}

pub fn expectedExceptionSeen() bool {
    return @atomicLoad(bool, &expected_seen, .seq_cst);
}

fn instructionLength(address: u64) u64 {
    const first_halfword: *const u16 = @ptrFromInt(address);
    return if (first_halfword.* & 0b11 == 0b11) 4 else 2;
}

fn cameFromUser(frame: *const abi.fb_trap_frame) bool {
    return frame.sstatus & sstatus_spp == 0;
}

/// Si al proceso actual le han pedido morir, muere aquí, con el cerrojo global.
fn killIfRequested(frame: *abi.fb_trap_frame) void {
    if (cameFromUser(frame) and process.killRequested()) {
        kernel_lock.enter();
        process.terminateCurrent(.{ .kind = .killed });
    }
}

/// El tick y los avisos solo toman el cerrojo de este hart; el global, solo si
/// hay que despertar dormidos o matar.
fn handleInterrupt(code: u64, frame: *abi.fb_trap_frame) void {
    switch (code) {
        interrupt_supervisor_software => {
            // Aviso de otro hart: despertó a un hilo de este, o pidió matar.
            ipi.acknowledge();
            killIfRequested(frame);
            thread.notified();
        },
        interrupt_supervisor_timer => {
            sleep.wakeDue();
            timer.onInterrupt();
            killIfRequested(frame);
            thread.preempt();
        },
        interrupt_supervisor_external => {
            kernel_lock.enter();
            defer kernel_lock.leave();
            if (device.onExternal()) thread.preempt();
        },
        else => fatal(frame),
    }
}

fn handleException(frame: *abi.fb_trap_frame) void {
    // Un fallo del usuario solo le afecta a él: el kernel sigue funcionando.
    if (cameFromUser(frame)) {
        if (frame.scause == cause_user_ecall) {
            syscall.handle(frame);
            thread.rescheduleIfOutranked();
        } else {
            process.terminateCurrent(.{
                .kind = .faulted,
                .value = frame.scause,
                .address = frame.stval,
            });
        }
        return;
    }

    if (@atomicLoad(u64, &expected_cause, .seq_cst) != frame.scause) fatal(frame);

    @atomicStore(u64, &expected_cause, no_cause, .seq_cst);
    @atomicStore(bool, &expected_seen, true, .seq_cst);

    // Si falló la búsqueda de la instrucción no hay nada que saltar: se vuelve
    // a quien hizo la llamada.
    if (frame.scause == cause_instruction_page_fault) {
        frame.sepc = frame.regs[reg_ra];
    } else {
        frame.sepc += instructionLength(frame.sepc);
    }
}

fn fatal(frame: *abi.fb_trap_frame) noreturn {
    uart.init();
    uart.print("\ntrap no esperado\n  scause: ");
    uart.printHex(frame.scause);
    uart.print("\n  sepc:   ");
    uart.printHex(frame.sepc);
    uart.print("\n  stval:  ");
    uart.printHex(frame.stval);
    @panic("trap no esperado");
}

export fn fb_trap_handler(raw_frame: [*c]abi.fb_trap_frame) callconv(.c) void {
    const frame: *abi.fb_trap_frame = raw_frame;
    if (frame.scause & interrupt_bit != 0) {
        handleInterrupt(frame.scause & ~interrupt_bit, frame);
    } else {
        // Llamadas al sistema y fallos: con el cerrojo global.
        kernel_lock.enter();
        defer kernel_lock.leave();
        handleException(frame);
    }
}
