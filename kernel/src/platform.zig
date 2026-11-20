//! Parada y apagado de la máquina. El apagado solo existe en QEMU `virt`.

const abi = @import("abi.zig").c;
const riscv = @import("riscv.zig");

pub fn halt() noreturn {
    while (true) riscv.waitForInterrupt();
}

fn finish(value: u32) noreturn {
    const finisher: *volatile u32 = @ptrFromInt(abi.FB_TEST_FINISHER_BASE);
    finisher.* = value;
    halt();
}

/// Termina QEMU con código de salida 0.
pub fn poweroffPass() noreturn {
    finish(abi.FB_TEST_FINISHER_PASS);
}

/// Termina QEMU con un código de salida distinto de 0.
pub fn poweroffFail() noreturn {
    finish(abi.FB_TEST_FINISHER_FAIL | (1 << 16));
}
