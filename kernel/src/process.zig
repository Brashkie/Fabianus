//! Procesos de usuario: un espacio de direcciones propio y un hilo que lo ejecuta.

const abi = @import("abi.zig").c;
const device = @import("device.zig");
const ipc = @import("ipc.zig");
const sleep = @import("sleep.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const riscv = @import("riscv.zig");
const thread = @import("thread.zig");
const hart = @import("hart.zig");
const ipi = @import("ipi.zig");

const page_size: u64 = abi.FB_PAGE_SIZE;
const user_base: u64 = abi.FB_USER_BASE;
const user_stack_top: u64 = abi.FB_USER_STACK_TOP;
const user_stack_pages: u64 = abi.FB_USER_STACK_PAGES;

/// Mismo orden que la tabla del final de arch/riscv64/user.S.
pub const Program = enum(usize) {
    hello,
    registers,
    spin,
    isolated,
    zerocheck,
    deputy,
    fault_csr,
    fault_sret,
    fault_load_kernel,
    fault_store_kernel,
    fault_jump_kernel,
    fault_store_text,
    fault_exec_stack,
    fault_stack_guard,
    fault_device,
    bench_syscall,
    bench_yield,
    no_caps,
    cap_rights,
    console_server,
    console_client,
    ping,
    pong,
    granter,
    grantee,
    ipc_sender,
    ipc_fifo_receiver,
    ipc_blocked,
    bench_ping,
    bench_pong,
    uart_driver,
    device_denied,
    device_rights,
    device_touch,
    device_holder,
    device_thief,
    device_exec,
    uart_client,
    uart_stopper,
    uart_reader,
    uart_loop_client,
    uart_loop_finish,
    device_irq_taker,
    uart_loop_on,
    bench_write,
    bench_driver_client,
    bench_loop_writer,
    bench_loop_reader,
    call_client,
    call_server,
    call_server_dies,
    call_expect_peer,
    send_expect_peer,
    call_checks,
    call_server_lost,
    call_long,
    call_server_pair,
    call_once,
    sched_set,
    sched_lower,
    defer_server,
    go_sender,
    reply_to_other,
    defer_then_die,
    defer_three,
    defer_then_serve,
    defer_wait,
    uart_call_reader,
    bench_call_read,
    bench_defer_reader,
    bench_defer_writer,
    latency_probe,
    call_forwarder,
    sleep_forever,
    signal_taker,
    bench_call,
    bench_serve,
    bench_xcall,
    bench_xserve,
    call_server_spin,
};

/// Capability que el kernel concede a un proceso al crearlo.
pub const Grant = struct { slot: u64, kind: u64, object: u64, rights: u64 };

/// Consola en el hueco 0: la mínima autoridad para imprimir.
pub const console_grant = [_]Grant{.{
    .slot = 0,
    .kind = abi.FB_CAP_CONSOLE,
    .object = 0,
    .rights = abi.FB_RIGHT_SEND,
}};

extern const fb_user_program_table: [@typeInfo(Program).@"enum".fields.len][2]u64;

pub const Kind = enum { running, exited, faulted, killed };

pub const Result = struct {
    kind: Kind = .running,
    /// Código de salida, o scause si el proceso falló.
    value: u64 = 0,
    /// stval si el proceso falló.
    address: u64 = 0,
};

var spaces = [_]u64{0} ** thread.max_threads;
var results = [_]Result{.{}} ** thread.max_threads;
var kill_flags = [_]bool{false} ** thread.max_threads;

pub fn init() void {
    const kernel_root: [*]const u64 = @ptrCast(@alignCast(&abi.fb_page_pool));
    const status = abi.fb_uspace_init(
        @intFromPtr(&abi.fb_user_pool),
        memory.base,
        memory.frame_count,
        kernel_root,
    );
    if (status != abi.FB_USPACE_OK) @panic("no se pudieron iniciar los espacios de usuario");
}

/// Reserva y mapea una página ya borrada: nada de su dueño anterior llega aquí.
fn mapZeroed(space: u64, va: u64, perm: u64) ?[*]u8 {
    const physical = abi.fb_uspace_map(space, va, perm);
    if (physical < page_size) return null;
    const page: [*]u8 = @ptrFromInt(physical);
    @memset(page[0..page_size], 0);
    return page;
}

fn loadImage(space: u64, image: []const u8) bool {
    var offset: usize = 0;
    while (offset < image.len) : (offset += page_size) {
        const page = mapZeroed(space, user_base + offset, abi.FB_PERM_READ_EXECUTE) orelse return false;
        const length = @min(image.len - offset, page_size);
        @memcpy(page[0..length], image[offset..][0..length]);
    }

    var index: u64 = 1;
    while (index <= user_stack_pages) : (index += 1) {
        _ = mapZeroed(space, user_stack_top - index * page_size, abi.FB_PERM_READ_WRITE) orelse return false;
    }
    return true;
}

fn destroySpace(space: u64) void {
    device.release(space);
    if (abi.fb_cap_clear(space) != abi.FB_CAP_OK) @panic("no se pudieron borrar las capabilities");
    if (abi.fb_uspace_destroy(space) != abi.FB_USPACE_OK) @panic("no se pudo destruir el espacio");
}

fn userMain(argument: u64) callconv(.c) void {
    abi.fb_enter_user(user_base, user_stack_top, argument);
}

/// Crea un proceso listo. Devuelve el hilo, o null si falta algún recurso.
pub fn spawn(program: Program, argument: u64) ?u64 {
    return spawnWith(program, argument, &.{});
}

/// Como `spawn`, concediendo además las capabilities indicadas.
pub fn spawnWith(program: Program, argument: u64, grants: []const Grant) ?u64 {
    return spawnWithOn(@import("hart.zig").id(), program, argument, grants);
}

/// Como `spawnWith`, en el hart `target`.
pub fn spawnWithOn(target: u64, program: Program, argument: u64, grants: []const Grant) ?u64 {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);

    const space = abi.fb_uspace_create();
    if (space == 0) return null;

    const bounds = fb_user_program_table[@intFromEnum(program)];
    const image: [*]const u8 = @ptrFromInt(bounds[0]);
    if (!loadImage(space, image[0 .. bounds[1] - bounds[0]])) {
        destroySpace(space);
        return null;
    }

    for (grants) |grant| {
        if (abi.fb_cap_grant(space, grant.slot, grant.kind, grant.object, grant.rights) != abi.FB_CAP_OK) {
            @panic("concesion de capability invalida");
        }
    }

    const satp = paging.satpFor(abi.fb_uspace_root(space));
    const id = thread.spawnOn(target, userMain, argument, .off, satp) orelse {
        destroySpace(space);
        return null;
    };

    spaces[id] = space;
    results[id] = .{};
    kill_flags[id] = false;
    return id;
}

/// Espacio del proceso actual; solo tiene sentido al atender una llamada suya.
pub fn currentSpace() u64 {
    return spaces[thread.currentId()];
}

pub fn spaceOf(id: u64) u64 {
    return spaces[id];
}

pub fn resultOf(id: u64) Result {
    return results[id];
}

/// El proceso morirá en la próxima interrupción que lo encuentre en modo usuario,
/// o en cuanto despierte si estaba esperando en un endpoint.
pub fn requestKill(id: u64) void {
    const saved = riscv.disableInterruptsSaving();
    defer riscv.restoreInterrupts(saved);
    @atomicStore(bool, &kill_flags[id], true, .seq_cst);
    const server = abi.fb_ipc_waits_for(id);
    if (abi.fb_ipc_cancel(id) == abi.FB_IPC_OK) {
        thread.unblock(id);
        // Al despertar recupera su contexto de toda la cadena que lo usaba:
        // los de más abajo pueden quedar con menos urgencia que sus clientes.
        ipc.refreshChain(server);
    }
    _ = sleep.cancel(id);
    // Si corre en otro hart, que se entere ya y no en su próximo tick.
    const home = thread.homeOf(id);
    if (home != hart.id()) ipi.send(home);
}

/// Si se ha pedido matar al proceso del hilo. Para diagnósticos.
pub fn killFlag(id: u64) bool {
    return kill_flags[id];
}

pub fn killRequested() bool {
    return @atomicLoad(bool, &kill_flags[thread.currentId()], .seq_cst);
}

/// Termina el proceso actual desde su trap. Sus tablas siguen activas hasta aquí,
/// así que primero hay que salir de ellas y solo entonces destruirlas.
pub fn terminateCurrent(result: Result) noreturn {
    const id = thread.currentId();
    if (spaces[id] == 0) @panic("un hilo del kernel no es un proceso");

    results[id] = result;
    thread.useKernelSpace();
    ipc.onDeath(id, spaces[id]);
    destroySpace(spaces[id]);
    spaces[id] = 0;
    abi.fb_thread_exit();
    @panic("un proceso terminado volvio a ejecutarse");
}
