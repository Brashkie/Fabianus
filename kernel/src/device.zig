// SPDX-License-Identifier: GPL-3.0-or-later
//! Cesión de dispositivos a procesos de usuario y entrega de sus interrupciones.
//!
//! Hay dos: la UART (FB_DEVICE_UART) y el disco virtio-blk (FB_DEVICE_DISK).
//! SPARK demuestra que los registros de cada uno solo los tiene un espacio a
//! la vez. Aquí se comprueban las capabilities y se programa el controlador de
//! interrupciones: cada dispositivo tiene su línea y su endpoint.
//!
//! Una interrupción reclamada no se completa hasta que el driver la confirma.
//! Mientras tanto el controlador no vuelve a entregar esa línea, así que un
//! driver lento o colgado no puede inundar al kernel.
//!
//! Si el dueño muere, el kernel deja el dispositivo en un estado conocido
//! antes de que se libere su memoria: un disco con DMA en marcha podría
//! escribir en marcos que ya son de otro.

const abi = @import("abi.zig").c;
const ipc = @import("ipc.zig");
const process = @import("process.zig");
const riscv = @import("riscv.zig");
const uart = @import("uart.zig");

const plic_base: u64 = abi.FB_PLIC_BASE;
const device_base: u64 = abi.FB_USER_DEVICE_BASE;
const page_size: u64 = abi.FB_PAGE_SIZE;

// Contexto 1: el modo supervisor del hart 0.
const plic_enable: u64 = plic_base + 0x2080;
const plic_threshold: u64 = plic_base + 0x201000;
const plic_claim: u64 = plic_base + 0x201004;

const sie_seie: u64 = 1 << 9;

/// Registro Status de virtio-mmio: escribir 0 reinicia el dispositivo y
/// detiene cualquier DMA.
const virtio_status: u64 = 0x70;

const Device = struct {
    /// Dirección física de sus registros.
    base: u64,
    irq: u32,
    owner_space: u64 = 0,
    bound_endpoint: ?u64 = null,
    in_service: bool = false,
};

var devices = [abi.FB_DEVICE_COUNT]Device{
    .{ .base = abi.FB_UART0_BASE, .irq = abi.FB_UART0_IRQ },
    .{ .base = abi.FB_VIRTIO0_BASE, .irq = abi.FB_VIRTIO0_IRQ },
};

fn register(address: u64) *volatile u32 {
    return @ptrFromInt(address);
}

/// Las líneas con un driver que las ha pedido.
fn updateLines() void {
    var mask: u32 = 0;
    for (devices) |d| {
        if (d.bound_endpoint != null) mask |= @as(u32, 1) << @intCast(d.irq);
    }
    register(plic_enable).* = mask;
}

/// Las líneas quedan apagadas hasta que un driver las pida.
pub fn init() void {
    for (devices) |d| register(plic_base + 4 * @as(u64, d.irq)).* = 1;
    register(plic_threshold).* = 0;
    updateLines();
    riscv.setCsr("sie", sie_seie);
}

/// Si alguna línea está encendida.
pub fn lineEnabled() bool {
    return register(plic_enable).* != 0;
}

pub fn uartOwned() bool {
    return devices[abi.FB_DEVICE_UART].owner_space != 0;
}

/// El espacio que tiene los registros del dispositivo, o 0.
pub fn ownerOf(device: u64) u64 {
    return devices[device].owner_space;
}

/// El dispositivo de la capability si tiene ese derecho, o null.
fn authorized(space: u64, cap: u64, right: u64) ?u64 {
    const object = abi.fb_cap_check(space, cap, abi.FB_CAP_DEVICE, right);
    if (object >= abi.FB_DEVICE_COUNT) return null;
    return object;
}

/// Dirección de usuario donde se mapean los registros de un dispositivo.
pub fn userAddress(device: u64) u64 {
    return device_base + device * page_size;
}

/// Mapea los registros en el proceso actual y devuelve su dirección.
pub fn map(cap: u64) u64 {
    const space = process.currentSpace();
    const device = authorized(space, cap, abi.FB_RIGHT_SEND) orelse return abi.FB_ERR_CAP;
    const address = userAddress(device);

    return switch (abi.fb_uspace_map_device(space, device, address)) {
        abi.FB_USPACE_OK => blk: {
            devices[device].owner_space = space;
            break :blk address;
        },
        abi.FB_USPACE_CONFLICT => abi.FB_ERR_BUSY,
        else => abi.FB_ERR_INVALID,
    };
}

/// Las interrupciones llegarán como señales al endpoint indicado.
pub fn bind(cap: u64, endpoint_cap: u64) u64 {
    const space = process.currentSpace();
    const device = authorized(space, cap, abi.FB_RIGHT_RECV) orelse return abi.FB_ERR_CAP;
    const d = &devices[device];
    if (d.owner_space != space or d.bound_endpoint != null) return abi.FB_ERR_BUSY;

    const endpoint = abi.fb_cap_check(space, endpoint_cap, abi.FB_CAP_ENDPOINT, abi.FB_RIGHT_RECV);
    if (endpoint == abi.FB_CAP_NO_OBJECT) return abi.FB_ERR_CAP;

    d.bound_endpoint = endpoint;
    updateLines();
    return 0;
}

fn complete(d: *Device) void {
    register(plic_claim).* = d.irq;
    d.in_service = false;
}

/// El driver ha atendido el dispositivo: la línea puede volver a avisar.
pub fn acknowledge(cap: u64) u64 {
    const space = process.currentSpace();
    const device = authorized(space, cap, abi.FB_RIGHT_RECV) orelse return abi.FB_ERR_CAP;
    const d = &devices[device];
    if (d.owner_space != space or !d.in_service) return abi.FB_ERR_INVALID;
    complete(d);
    return 0;
}

/// Atiende la interrupción externa. Devuelve si despertó a alguien.
pub fn onExternal() bool {
    const irq = register(plic_claim).*;
    if (irq == 0) return false;
    for (&devices) |*d| {
        if (d.irq != irq) continue;
        const endpoint = d.bound_endpoint orelse @panic("interrupcion sin driver");
        d.in_service = true;
        return ipc.signal(endpoint);
    }
    @panic("interrupcion de una linea no habilitada");
}

/// El dueño ha muerto: el kernel recupera sus dispositivos en un estado
/// conocido. Las finalizaciones de una línea apagada se ignoran, así que el
/// orden importa.
pub fn release(space: u64) void {
    for (&devices, 0..) |*d, index| {
        if (d.owner_space != space) continue;

        if (d.in_service) complete(d);
        const endpoint = d.bound_endpoint;
        d.bound_endpoint = null;
        updateLines();
        if (endpoint) |e| {
            if (abi.fb_ipc_clear_signal(e) != abi.FB_IPC_OK) @panic("no se pudo limpiar la senal");
        }
        d.owner_space = 0;
        switch (index) {
            abi.FB_DEVICE_UART => uart.init(),
            // Sin DMA en marcha antes de que se liberen sus regiones.
            abi.FB_DEVICE_DISK => register(d.base + virtio_status).* = 0,
            else => unreachable,
        }
    }
}

/// Si en la primera ranura virtio hay un disco: el número mágico "virt" y el
/// tipo de dispositivo 2 (bloques).
pub fn diskPresent() bool {
    return register(abi.FB_VIRTIO0_BASE).* == 0x74726976 and register(abi.FB_VIRTIO0_BASE + 8).* == 2;
}

/// Estado del disco virtio (registro Status), para las pruebas.
pub fn diskStatus() u32 {
    return register(abi.FB_VIRTIO0_BASE + virtio_status).*;
}
