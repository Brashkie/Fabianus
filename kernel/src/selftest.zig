//! Autopruebas que se ejecutan en cada arranque. Un fallo detiene el kernel.

const abi = @import("abi.zig").c;
const memory = @import("memory.zig");
const riscv = @import("riscv.zig");
const timer = @import("timer.zig");
const trap = @import("trap.zig");
const uart = @import("uart.zig");

fn passed(name: []const u8) void {
    uart.print("[ok] ");
    uart.print(name);
    uart.print("\n");
}

fn testBreakpointReturns() void {
    trap.expectException(trap.cause_breakpoint);
    asm volatile ("ebreak" ::: "memory");
    if (!trap.expectedExceptionSeen()) @panic("el breakpoint no llego al manejador");
    passed("excepcion atendida y retorno correcto");
}

fn testRegistersPreserved() void {
    trap.expectException(trap.cause_breakpoint);
    if (abi.fb_selftest_registers() != 0) @panic("un trap altero los registros");
    if (!trap.expectedExceptionSeen()) @panic("el breakpoint no llego al manejador");
    passed("registros preservados tras un trap");
}

fn testRunningInSupervisorMode() void {
    // mstatus solo es accesible desde modo máquina.
    trap.expectException(trap.cause_illegal_instruction);
    asm volatile ("csrr zero, mstatus" ::: "memory");
    if (!trap.expectedExceptionSeen()) @panic("mstatus accesible: no estamos en supervisor");
    passed("ejecutando en modo supervisor");
}

fn testTimerInterrupts() void {
    const tick_goal: u64 = 10;
    const start = timer.now();
    timer.init();

    riscv.enableInterrupts();
    while (timer.ticks() < tick_goal) riscv.waitForInterrupt();
    riscv.disableInterrupts();

    // Cada vencimiento está al menos un periodo después del anterior.
    if (timer.now() - start < tick_goal * timer.interval) {
        @panic("el timer disparo antes de tiempo");
    }
    uart.print("[ok] timer por interrupcion, ticks: ");
    uart.printHex(timer.ticks());
    uart.print("\n");
}

var seen_frames: [abi.FB_MAX_FRAMES / 8]u8 = [_]u8{0} ** (abi.FB_MAX_FRAMES / 8);

fn frameIndex(address: u64) u64 {
    if (address < memory.base or address & (abi.FB_PAGE_SIZE - 1) != 0) {
        @panic("el asignador entrego una direccion invalida");
    }
    const index = (address - memory.base) / abi.FB_PAGE_SIZE;
    if (index >= memory.frame_count) @panic("el asignador entrego un marco fuera de rango");
    return index;
}

fn expectStatus(actual: u64, expected: u64) void {
    if (actual != expected) @panic("estado inesperado del asignador de marcos");
}

/// Comprueba en ejecución, sobre la frontera real, lo que SPARK demuestra del núcleo.
fn testFrameAllocator() void {
    const end = memory.base + memory.frame_count * abi.FB_PAGE_SIZE;

    expectStatus(abi.fb_frames_init(memory.base, memory.frame_count), abi.FB_FRAMES_ALREADY_INIT);

    // Agota la memoria: cada marco debe aparecer exactamente una vez.
    var allocated: u64 = 0;
    while (true) : (allocated += 1) {
        const address = abi.fb_frames_alloc();
        if (address == 0) break;
        const index = frameIndex(address);
        const mask = @as(u8, 1) << @as(u3, @truncate(index));
        if (seen_frames[index / 8] & mask != 0) @panic("marco entregado dos veces");
        seen_frames[index / 8] |= mask;
    }
    if (allocated != memory.frame_count) @panic("el asignador perdio marcos");

    // La frontera rechaza lo que el núcleo no podría aceptar.
    expectStatus(abi.fb_frames_free(memory.base + 1), abi.FB_FRAMES_MISALIGNED);
    expectStatus(abi.fb_frames_free(memory.base - abi.FB_PAGE_SIZE), abi.FB_FRAMES_OUT_OF_RANGE);
    expectStatus(abi.fb_frames_free(end), abi.FB_FRAMES_OUT_OF_RANGE);

    var index: u64 = 0;
    while (index < memory.frame_count) : (index += 1) {
        const address = memory.base + index * abi.FB_PAGE_SIZE;
        expectStatus(abi.fb_frames_free(address), abi.FB_FRAMES_OK);
        expectStatus(abi.fb_frames_free(address), abi.FB_FRAMES_NOT_ASSIGNED);
    }

    const reused = abi.fb_frames_alloc();
    _ = frameIndex(reused);
    expectStatus(abi.fb_frames_free(reused), abi.FB_FRAMES_OK);

    uart.print("[ok] asignador de marcos, marcos: ");
    uart.printHex(allocated);
    uart.print("\n");
}

extern var __text_start: u8;
extern var __rodata_start: u8;
extern var __stack_guard: u8;
extern var __trap_stack_guard: u8;

fn expectLoadFault(cause: u64, address: u64) void {
    const target: *volatile u64 = @ptrFromInt(address);
    trap.expectException(cause);
    _ = target.*;
    if (!trap.expectedExceptionSeen()) @panic("una lectura prohibida no produjo fallo");
}

fn expectStoreFault(address: u64) void {
    const target: *volatile u64 = @ptrFromInt(address);
    trap.expectException(trap.cause_store_page_fault);
    target.* = 0;
    if (!trap.expectedExceptionSeen()) @panic("una escritura prohibida no produjo fallo");
}

/// Con la paginación aún apagada, solo el PMP puede impedir este acceso.
fn testPmpBlocksUnlistedMemory() void {
    expectLoadFault(trap.cause_load_access_fault, pci_window_address);
    passed("PMP bloquea memoria no autorizada");
}

const pci_window_address: u64 = 0x40000000;

var not_executable: u32 align(4) = 0;

fn testPagingProtections() void {
    expectStoreFault(@intFromPtr(&__text_start));
    passed("el codigo no es escribible");

    expectStoreFault(@intFromPtr(&__rodata_start));
    passed("los datos de solo lectura no son escribibles");

    expectStoreFault(@intFromPtr(&__stack_guard));
    expectStoreFault(@intFromPtr(&__trap_stack_guard));
    passed("paginas de guarda sin mapear");

    expectLoadFault(trap.cause_load_page_fault, pci_window_address);
    passed("direccion sin mapear produce fallo");

    const data_as_code: *const fn () callconv(.c) void = @ptrCast(&not_executable);
    trap.expectException(trap.cause_instruction_page_fault);
    data_as_code();
    if (!trap.expectedExceptionSeen()) @panic("se ejecutaron datos como codigo");
    passed("los datos no son ejecutables");
}

extern fn memset(destination: [*]u8, value: c_int, length: usize) [*]u8;
extern fn memcpy(destination: [*]u8, source: [*]const u8, length: usize) [*]u8;
extern fn memmove(destination: [*]u8, source: [*]const u8, length: usize) [*]u8;

var memory_test_area: [256]u8 align(8) = undefined;
var memory_test_source: [96]u8 align(8) = undefined;

fn expectRegion(start: usize, length: usize, expected_inside: fn (usize) u8) void {
    const outside: u8 = 0xee;
    for (memory_test_area, 0..) |byte, index| {
        const inside = index >= start and index < start + length;
        const expected = if (inside) expected_inside(index - start) else outside;
        if (byte != expected) @panic("una rutina de memoria escribio donde no debia");
    }
}

fn constantByte(_: usize) u8 {
    return 0x5a;
}

var copy_offset: usize = 0;

fn sourceByte(position: usize) u8 {
    return @truncate(copy_offset + position + 1);
}

/// Todas las combinaciones de alineación y de longitud: memset hasta más de
/// tres bloques de 64 bytes, memcpy hasta más de cinco palabras.
fn testMemoryRoutines() void {
    for (0..16) |start| {
        for (0..200) |length| {
            for (&memory_test_area) |*byte| {
                const target: *volatile u8 = byte;
                target.* = 0xee;
            }
            _ = memset(memory_test_area[start..].ptr, 0x5a, length);
            expectRegion(start, length, constantByte);
        }
        for (0..48) |length| {
            for (0..16) |offset| {
                for (&memory_test_area) |*byte| {
                    const target: *volatile u8 = byte;
                    target.* = 0xee;
                }
                for (&memory_test_source, 0..) |*byte, index| {
                    const target: *volatile u8 = byte;
                    target.* = @truncate(index + 1);
                }
                copy_offset = offset;
                _ = memcpy(memory_test_area[start..].ptr, memory_test_source[offset..].ptr, length);
                expectRegion(start, length, sourceByte);
            }
        }
    }
    testMemmoveOverlaps();
    passed("memset, memcpy y memmove con toda alineacion y longitud");
}

/// Regiones solapadas en los dos sentidos, a distancias cortas y largas.
fn testMemmoveOverlaps() void {
    const base: usize = 24;
    for (0..48) |length| {
        for (0..20) |distance| {
            for ([_]bool{ false, true }) |forward| {
                const source_start = if (forward) base + distance else base;
                const target_start = if (forward) base else base + distance;

                for (&memory_test_area, 0..) |*byte, index| {
                    const target: *volatile u8 = byte;
                    target.* = @truncate(index + 1);
                }
                _ = memmove(memory_test_area[target_start..].ptr, memory_test_area[source_start..].ptr, length);

                for (memory_test_area, 0..) |byte, index| {
                    const inside = index >= target_start and index < target_start + length;
                    const expected: u8 = if (inside)
                        @truncate(source_start + (index - target_start) + 1)
                    else
                        @truncate(index + 1);
                    if (byte != expected) @panic("memmove copio mal una region solapada");
                }
            }
        }
    }
}

/// Pruebas que deben correr antes de activar la paginación.
pub fn runBeforePaging() void {
    testBreakpointReturns();
    testRegistersPreserved();
    testRunningInSupervisorMode();
    testPmpBlocksUnlistedMemory();
}

pub fn run() void {
    testMemoryRoutines();
    testPagingProtections();
    testTimerInterrupts();
    testFrameAllocator();
}
