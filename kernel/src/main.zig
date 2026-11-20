//! Punto de entrada de Fabianus en Zig. Se ejecuta en modo supervisor.

const abi_module = @import("abi.zig");
const abi = abi_module.c;
const benchmark = @import("benchmark.zig");
const build_options = @import("build_options");
const device = @import("device.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const platform = @import("platform.zig");
const process = @import("process.zig");
const selftest = @import("selftest.zig");
const selftest_threads = @import("selftest_threads.zig");
const selftest_ipc = @import("selftest_ipc.zig");
const selftest_call = @import("selftest_call.zig");
const selftest_sched = @import("selftest_sched.zig");
const selftest_sleep = @import("selftest_sleep.zig");
const selftest_smp = @import("selftest_smp.zig");
const smp = @import("smp.zig");
const riscv = @import("riscv.zig");
const selftest_driver = @import("selftest_driver.zig");
const selftest_user = @import("selftest_user.zig");
const thread = @import("thread.zig");
const trap = @import("trap.zig");
const uart = @import("uart.zig");

pub const panic = @import("panic.zig");

comptime {
    abi_module.checkParams(@TypeOf(abi.fb_kmain), @TypeOf(fb_kmain));
}

/// Permite provocar un fallo para comprobar que se detecta (`-Dcrash=...`).
fn crashIfRequested() void {
    switch (build_options.crash) {
        .none => {},
        .panic => @panic("fallo provocado"),
        .trap => asm volatile ("unimp" ::: "memory"),
        .thread_stack => selftest_threads.crashThreadStack(),
        // Agota la pila hasta golpear la página de guarda.
        .stack => asm volatile (
            \\1:
            \\addi sp, sp, -2048
            \\addi sp, sp, -2048
            \\sd zero, 0(sp)
            \\j 1b
            ::: "memory"),
    }
}

export fn fb_kmain(hart_id: u64, boot_flags: u64) callconv(.c) noreturn {
    uart.init();
    trap.init();
    // El usuario puede leer el reloj con rdtime, como en Linux.
    riscv.writeCsr("scounteren", 1 << 1);

    uart.print("\nFabianus 0.0.10\n");
    uart.print("arch: riscv64, hart: ");
    uart.printHex(hart_id);
    uart.print("\n");

    if (boot_flags & abi.FB_BOOT_FLAG_SSTC == 0) @panic("el hardware no tiene Sstc");

    memory.init();
    selftest.runBeforePaging();
    paging.init();
    uart.print("paginacion: Sv39 activa\n");
    thread.init();
    process.init();
    device.init();

    if (build_options.bench) {
        // Las medidas de un hart, solo con un hart: con más, los secundarios
        // giran esperando su arranque y bajo -icount eso corre el reloj.
        if (build_options.harts == 1) benchmark.run();
        benchmark.runSmp(smp.start(build_options.harts));
        platform.poweroffPass();
    }

    // Los harts secundarios arrancan después de activar la paginación: la
    // necesitan para llegar a su pila y a su código.
    const harts = smp.start(build_options.harts);
    selftest.run();
    selftest_smp.run(harts);
    selftest_threads.run();
    selftest_user.run();
    selftest_ipc.run();
    selftest_sched.run();
    selftest_sleep.run();
    selftest_call.run();
    selftest_driver.run();
    crashIfRequested();

    uart.print("boot: ok\n");
    platform.poweroffPass();
}
