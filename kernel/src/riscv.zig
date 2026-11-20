//! Acceso a registros de control de RISC-V desde modo supervisor.

const kernel_lock = @import("kernel_lock.zig");

pub inline fn readCsr(comptime name: []const u8) u64 {
    return asm volatile ("csrr %[value], " ++ name
        : [value] "=r" (-> u64),
    );
}

pub inline fn writeCsr(comptime name: []const u8, value: u64) void {
    asm volatile ("csrw " ++ name ++ ", %[value]"
        :
        : [value] "r" (value),
    );
}

pub inline fn setCsr(comptime name: []const u8, mask: u64) void {
    asm volatile ("csrs " ++ name ++ ", %[mask]"
        :
        : [mask] "r" (mask),
    );
}

pub inline fn clearCsr(comptime name: []const u8, mask: u64) void {
    asm volatile ("csrc " ++ name ++ ", %[mask]"
        :
        : [mask] "r" (mask),
    );
}

const sstatus_sie: u64 = 1 << 1;

pub inline fn enableInterrupts() void {
    setCsr("sstatus", sstatus_sie);
}

pub inline fn disableInterrupts() void {
    clearCsr("sstatus", sstatus_sie);
}

/// Entra en una sección crítica del kernel: apaga las interrupciones de este
/// hart y toma el cerrojo global (recursivo). No vale con el cerrojo de un
/// hart tomado: el global va antes. Devuelve lo que hay que pasar a
/// `restoreInterrupts` para dejarlas como estaban.
pub inline fn disableInterruptsSaving() u64 {
    const previous = readCsr("sstatus") & sstatus_sie;
    disableInterrupts();
    kernel_lock.enter();
    return previous;
}

pub inline fn restoreInterrupts(previous: u64) void {
    kernel_lock.leave();
    setCsr("sstatus", previous);
}

/// Solo apaga las interrupciones de este hart, sin cerrojo. Devuelve lo que
/// hay que pasar a `restoreInterruptState`.
pub inline fn interruptsOffSaving() u64 {
    const previous = readCsr("sstatus") & sstatus_sie;
    disableInterrupts();
    return previous;
}

pub inline fn restoreInterruptState(previous: u64) void {
    setCsr("sstatus", previous);
}

pub inline fn waitForInterrupt() void {
    asm volatile ("wfi");
}
