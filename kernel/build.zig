// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");

const Crash = enum { none, panic, trap, stack, thread_stack };

pub fn build(b: *std.Build) void {
    // rv64imac con Sstc: el kernel no usa coma flotante.
    const riscv = std.Target.riscv;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &riscv.cpu.generic_rv64 },
        .cpu_features_add = riscv.featureSet(&.{ .m, .a, .c, .zicsr, .zifencei, .sstc }),
    });
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });
    const qemu = b.option([]const u8, "qemu", "Ruta a qemu-system-riscv64") orelse
        "qemu-system-riscv64";
    const alr = b.option([]const u8, "alr", "Ruta a alr (Alire)") orelse "alr";
    const rustc = b.option([]const u8, "rustc", "Ruta a rustc") orelse "rustc";
    const smp = b.option([]const u8, "smp", "Número de harts en QEMU") orelse "1";
    const harts = std.fmt.parseInt(u64, smp, 10) catch @panic("smp debe ser un número");
    const cpu = b.option([]const u8, "cpu", "Modelo de CPU en QEMU") orelse "rv64";
    const crash = b.option(Crash, "crash", "Provoca un fallo para probar su detección") orelse .none;

    const options = b.addOptions();
    options.addOption(Crash, "crash", crash);
    const bench = b.option(bool, "bench", "Ejecuta el benchmark en lugar de las autopruebas") orelse false;
    options.addOption(bool, "bench", bench);
    options.addOption(u64, "harts", harts);

    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // El kernel se enlaza en 0x80000000, fuera del alcance del modelo medlow.
        .code_model = .medium,
        .single_threaded = true,
        .unwind_tables = .none,
    });
    kernel_module.addOptions("build_options", options);
    kernel_module.addIncludePath(b.path("abi"));
    kernel_module.addAssemblyFile(b.path("arch/riscv64/boot.S"));
    kernel_module.addAssemblyFile(b.path("arch/riscv64/trap.S"));
    kernel_module.addAssemblyFile(b.path("arch/riscv64/selftest.S"));
    kernel_module.addAssemblyFile(b.path("arch/riscv64/mem.S"));
    kernel_module.addAssemblyFile(b.path("arch/riscv64/switch.S"));
    kernel_module.addAssemblyFile(b.path("arch/riscv64/user.S"));

    // Driver en Rust: un proceso de usuario sin más dependencias que `core`.
    const genabi_module = b.createModule(.{
        .root_source_file = b.path("tools/genabi.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    genabi_module.addIncludePath(b.path("abi"));
    const genabi = b.addExecutable(.{ .name = "genabi", .root_module = genabi_module });
    const genabi_run = b.addRunArtifact(genabi);
    const rust_abi_source = genabi_run.addOutputFileArg("fb_abi.rs");

    const rust_flags = [_][]const u8{
        rustc,
        "--edition=2021",
        "--target=riscv64imac-unknown-none-elf",
        "-Copt-level=s",
        "-Cpanic=abort",
        "-Coverflow-checks=on",
        "-Cforce-unwind-tables=no",
    };
    const rust_abi = b.addSystemCommand(&rust_flags);
    rust_abi.addArgs(&.{ "--crate-type=rlib", "--crate-name=fb_abi" });
    rust_abi.addFileArg(rust_abi_source);
    rust_abi.addArg("-o");
    const rust_abi_library = rust_abi.addOutputFileArg("libfb_abi.rlib");

    const uart_driver = b.addSystemCommand(&rust_flags);
    uart_driver.addArgs(&.{ "--crate-type=bin", "--crate-name=uart_driver" });
    uart_driver.addFileArg(b.path("drivers/uart/main.rs"));
    uart_driver.addPrefixedFileArg("--extern=fb_abi=", rust_abi_library);
    uart_driver.addPrefixedFileArg("-Clink-arg=-T", b.path("drivers/uart/driver.ld"));
    uart_driver.addArg("-o");
    const uart_driver_elf = uart_driver.addOutputFileArg("uart_driver.elf");
    b.getInstallStep().dependOn(&b.addInstallBinFile(uart_driver_elf, "uart_driver.elf").step);

    // user.S incluye esta imagen plana: entra en el kernel solo como datos.
    const uart_driver_image = b.addObjCopy(uart_driver_elf, .{
        .basename = "uart_driver.bin",
        .format = .bin,
    });
    kernel_module.addIncludePath(uart_driver_image.getOutput().dirname());

    // El driver del disco, igual: Rust sin más que `core`, como datos para user.S.
    const disk_driver = b.addSystemCommand(&rust_flags);
    disk_driver.addArgs(&.{ "--crate-type=bin", "--crate-name=disk_driver" });
    disk_driver.addFileArg(b.path("drivers/disk/main.rs"));
    disk_driver.addPrefixedFileArg("--extern=fb_abi=", rust_abi_library);
    disk_driver.addPrefixedFileArg("-Clink-arg=-T", b.path("drivers/uart/driver.ld"));
    disk_driver.addArg("-o");
    const disk_driver_elf = disk_driver.addOutputFileArg("disk_driver.elf");
    b.getInstallStep().dependOn(&b.addInstallBinFile(disk_driver_elf, "disk_driver.elf").step);
    const disk_driver_image = b.addObjCopy(disk_driver_elf, .{
        .basename = "disk_driver.bin",
        .format = .bin,
    });
    kernel_module.addIncludePath(disk_driver_image.getOutput().dirname());

    // La imagen del disco de pruebas, con un patrón conocido (tools/mkdisk.zig).
    const mkdisk = b.addExecutable(.{ .name = "mkdisk", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/mkdisk.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const mkdisk_run = b.addRunArtifact(mkdisk);
    const disk_image = mkdisk_run.addOutputFileArg("disk.img");
    b.getInstallStep().dependOn(&b.addInstallFile(disk_image, "disk.img").step);

    const kernel = b.addExecutable(.{
        .name = "fabianus.elf",
        .root_module = kernel_module,
    });
    // El módulo SPARK se compila sin comprobaciones en tiempo de ejecución,
    // así que la demostración es un requisito para poder compilarlo.
    // Todos los núcleos, con 60 s por comprobación: la demostración completa
    // pasa de unos 48 a unos 10 minutos. Con el límite por defecto, las
    // comprobaciones más justas no terminan cuando compiten entre sí.
    const prove_switches = [_][]const u8{ "-j0", "--timeout=60" };
    const spark_prove = b.addSystemCommand(&(.{ alr, "-n", "exec", "--", "gnatprove", "-P", "fabianus_core.gpr" } ++ prove_switches));
    spark_prove.setCwd(b.path("spark"));
    spark_prove.has_side_effects = true;

    const spark_build = b.addSystemCommand(&.{ alr, "-n", "build" });
    spark_build.setCwd(b.path("spark"));
    spark_build.has_side_effects = true;
    spark_build.step.dependOn(&spark_prove.step);
    kernel.step.dependOn(&spark_build.step);
    kernel.addObjectFile(b.path("spark/lib/libfabianus_core.a"));

    const prove_report = b.addSystemCommand(&(.{ alr, "-n", "exec", "--", "gnatprove", "-P", "fabianus_core.gpr", "--report=all" } ++ prove_switches));
    prove_report.setCwd(b.path("spark"));
    prove_report.has_side_effects = true;
    const prove_step = b.step("prove", "Demuestra el módulo SPARK y muestra cada comprobación");
    prove_step.dependOn(&prove_report.step);

    kernel.setLinkerScript(b.path("arch/riscv64/linker.ld"));
    kernel.entry = .{ .symbol_name = "_start" };
    // Nada de runtimes del compilador dentro de la imagen del kernel.
    kernel.bundle_compiler_rt = false;
    kernel.bundle_ubsan_rt = false;
    b.installArtifact(kernel);

    const run_qemu = b.addSystemCommand(&.{
        qemu,
        "-machine", "virt",
        "-cpu",     cpu,
        "-smp",     smp,
        "-m",       "128M",
        "-nographic",
        // Sin esto QEMU carga OpenSBI en 0x80000000, donde vive el kernel.
        "-bios",    "none",
        "-kernel",
    });
    run_qemu.addArtifactArg(kernel);
    // El disco virtio en la primera ranura, en modo moderno. Con snapshot=on
    // lo escrito se pierde al apagar: cada arranque ve el mismo disco.
    run_qemu.addArgs(&.{ "-global", "virtio-mmio.force-legacy=false", "-drive" });
    run_qemu.addPrefixedFileArg("if=none,format=raw,id=disk0,snapshot=on,file=", disk_image);
    run_qemu.addArgs(&.{ "-device", "virtio-blk-device,drive=disk0,bus=virtio-mmio-bus.0" });
    // Con icount, instret cuenta instrucciones de forma determinista.
    if (bench) run_qemu.addArgs(&.{ "-icount", "shift=0,sleep=off" });

    const run_step = b.step("run", "Compila y arranca el kernel en QEMU");
    run_step.dependOn(&run_qemu.step);
}
