//! Cesión de la UART a un proceso de usuario y entrega de sus interrupciones.
//!
//! SPARK demuestra que solo un espacio puede tener los registros. Aquí se
//! comprueban las capabilities y se programa el controlador de interrupciones.
//!
//! Una interrupción reclamada no se completa hasta que el driver la confirma.
//! Mientras tanto el controlador no vuelve a entregar esa línea, así que un
//! driver lento o colgado no puede inundar al kernel.

const abi = @import("abi.zig").c;
const ipc = @import("ipc.zig");
const process = @import("process.zig");
const riscv = @import("riscv.zig");
const uart = @import("uart.zig");

const plic_base: u64 = abi.FB_PLIC_BASE;
const uart_irq: u32 = abi.FB_UART0_IRQ;
const device_base: u64 = abi.FB_USER_DEVICE_BASE;

// Contexto 1: el modo supervisor del hart 0.
const plic_enable: u64 = plic_base + 0x2080;
const plic_threshold: u64 = plic_base + 0x201000;
const plic_claim: u64 = plic_base + 0x201004;

const sie_seie: u64 = 1 << 9;

var owner_space: u64 = 0;
var bound_endpoint: ?u64 = null;
var in_service = false;

fn register(address: u64) *volatile u32 {
    return @ptrFromInt(address);
}

fn setLineEnabled(enabled: bool) void {
    register(plic_enable).* = if (enabled) @as(u32, 1) << @intCast(uart_irq) else 0;
}

/// La línea queda apagada hasta que un driver la pida.
pub fn init() void {
    register(plic_base + 4 * @as(u64, uart_irq)).* = 1;
    register(plic_threshold).* = 0;
    setLineEnabled(false);
    riscv.setCsr("sie", sie_seie);
}

pub fn lineEnabled() bool {
    return register(plic_enable).* != 0;
}

pub fn uartOwned() bool {
    return owner_space != 0;
}

fn authorized(space: u64, cap: u64, right: u64) bool {
    return abi.fb_cap_check(space, cap, abi.FB_CAP_DEVICE, right) == abi.FB_DEVICE_UART;
}

/// Mapea los registros en el proceso actual y devuelve su dirección.
pub fn map(cap: u64) u64 {
    const space = process.currentSpace();
    if (!authorized(space, cap, abi.FB_RIGHT_SEND)) return abi.FB_ERR_CAP;

    return switch (abi.fb_uspace_map_device(space, device_base)) {
        abi.FB_USPACE_OK => blk: {
            owner_space = space;
            break :blk device_base;
        },
        abi.FB_USPACE_CONFLICT => abi.FB_ERR_BUSY,
        else => abi.FB_ERR_INVALID,
    };
}

/// Las interrupciones llegarán como señales al endpoint indicado.
pub fn bind(cap: u64, endpoint_cap: u64) u64 {
    const space = process.currentSpace();
    if (!authorized(space, cap, abi.FB_RIGHT_RECV)) return abi.FB_ERR_CAP;
    if (owner_space != space or bound_endpoint != null) return abi.FB_ERR_BUSY;

    const endpoint = abi.fb_cap_check(space, endpoint_cap, abi.FB_CAP_ENDPOINT, abi.FB_RIGHT_RECV);
    if (endpoint == abi.FB_CAP_NO_OBJECT) return abi.FB_ERR_CAP;

    bound_endpoint = endpoint;
    setLineEnabled(true);
    return 0;
}

fn complete() void {
    register(plic_claim).* = uart_irq;
    in_service = false;
}

/// El driver ha atendido el dispositivo: la línea puede volver a avisar.
pub fn acknowledge(cap: u64) u64 {
    const space = process.currentSpace();
    if (!authorized(space, cap, abi.FB_RIGHT_RECV)) return abi.FB_ERR_CAP;
    if (owner_space != space or !in_service) return abi.FB_ERR_INVALID;
    complete();
    return 0;
}

/// Atiende la interrupción externa. Devuelve si despertó a alguien.
pub fn onExternal() bool {
    const irq = register(plic_claim).*;
    if (irq == 0) return false;
    if (irq != uart_irq) @panic("interrupcion de una linea no habilitada");

    const endpoint = bound_endpoint orelse @panic("interrupcion sin driver");
    in_service = true;
    return ipc.signal(endpoint);
}

/// El dueño ha muerto: el kernel recupera la UART en un estado conocido. Las
/// finalizaciones de una línea apagada se ignoran, así que el orden importa.
pub fn release(space: u64) void {
    if (owner_space != space) return;

    if (in_service) complete();
    setLineEnabled(false);
    if (bound_endpoint) |endpoint| {
        if (abi.fb_ipc_clear_signal(endpoint) != abi.FB_IPC_OK) @panic("no se pudo limpiar la senal");
        bound_endpoint = null;
    }
    owner_space = 0;
    uart.init();
}
