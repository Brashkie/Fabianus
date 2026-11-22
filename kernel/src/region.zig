// SPDX-License-Identifier: GPL-3.0-or-later
//! Regiones de memoria compartida entre procesos.
//!
//! SPARK (User_Space) lleva los marcos de cada región y demuestra el
//! aislamiento: dos espacios solo llegan al mismo marco si es de una región a
//! la que los dos están unidos, y un marco propio de un espacio nunca lo ve
//! otro. Cap_Core decide quién puede unirse: hace falta una capability de tipo
//! región, que se cede por IPC como cualquier otra (con Grant). Recv deja
//! mapearla para leer; Send, además, para escribir. Nunca para ejecutar.
//!
//! Vida de una región: la crea el kernel, que la retiene hasta concederla
//! (`release`). Después vive mientras algún espacio esté unido a ella o alguna
//! capability la nombre; un espacio solo se desune al destruirse. Así nunca
//! hay que quitar una página a un proceso vivo, ni avisar a otros harts para
//! que olviden su traducción.

const abi = @import("abi.zig").c;
const kernel_lock = @import("kernel_lock.zig");
const riscv = @import("riscv.zig");

const page_size: u64 = abi.FB_PAGE_SIZE;
pub const max_regions: u64 = abi.FB_USPACE_MAX_REGIONS;

/// Regiones que el kernel aún retiene: ninguna capability la nombra todavía.
var held = [_]bool{false} ** (max_regions + 1);
var freed_count: u64 = 0;

fn enter() u64 {
    const saved = riscv.disableInterruptsSaving();
    kernel_lock.enter();
    return saved;
}

fn leave(saved: u64) void {
    kernel_lock.leave();
    riscv.restoreInterrupts(saved);
}

/// Crea una región de `pages` páginas, ya a cero, y la retiene hasta
/// `release`. Devuelve su número (1 .. max_regions) o null.
pub fn create(pages: u64) ?u64 {
    const saved = enter();
    defer leave(saved);
    const region = abi.fb_uspace_region_create(pages);
    if (region == 0) return null;
    var page: u64 = 0;
    while (page < pages) : (page += 1) {
        const physical = abi.fb_uspace_region_frame(region, page);
        if (physical == 0) @panic("una region nueva sin su pagina");
        const bytes: [*]u8 = @ptrFromInt(physical);
        @memset(bytes[0..page_size], 0);
    }
    held[region] = true;
    return region;
}

/// El objeto de su capability.
pub fn object(region: u64) u64 {
    return region - 1;
}

/// El kernel deja de retenerla: desde ahora vive mientras alguien la alcance.
pub fn release(region: u64) void {
    const saved = enter();
    defer leave(saved);
    held[region] = false;
    reclaimLocked();
}

/// Número de páginas de una región, o 0 si no existe.
pub fn pagesOf(region: u64) u64 {
    var page: u64 = 0;
    while (page < abi.FB_USPACE_MAX_REGION_PAGES and abi.fb_uspace_region_frame(region, page) != 0) : (page += 1) {}
    return page;
}

/// FB_SYS_REGION_MAP: une el espacio a la región de la capability y mapea
/// todas sus páginas desde `va`. Con el cerrojo global (llamada al sistema).
/// Fuera de línea: dentro del despacho de llamadas, sus bucles harían que
/// todas las llamadas guardaran más registros.
pub noinline fn map(space: u64, cap: u64, va: u64) u64 {
    const readable = abi.fb_cap_check(space, cap, abi.FB_CAP_REGION, abi.FB_RIGHT_RECV);
    if (readable == abi.FB_CAP_NO_OBJECT) return abi.FB_ERR_CAP;
    const writable = abi.fb_cap_check(space, cap, abi.FB_CAP_REGION, abi.FB_RIGHT_SEND) != abi.FB_CAP_NO_OBJECT;
    const region = readable + 1;

    if (abi.fb_uspace_region_attach(space, region) != abi.FB_USPACE_OK) return abi.FB_ERR_INVALID;
    const pages = pagesOf(region);
    var page: u64 = 0;
    while (page < pages) : (page += 1) {
        const status = abi.fb_uspace_region_map(space, region, page, va + page * page_size, @intFromBool(writable));
        switch (status) {
            abi.FB_USPACE_OK => {},
            abi.FB_USPACE_CONFLICT => return abi.FB_ERR_BUSY,
            else => return abi.FB_ERR_INVALID,
        }
    }
    return 0;
}

/// FB_SYS_DMA_ADDRESS: la dirección física de una página de la región, para
/// programar DMA. Solo para quien tiene los registros del disco (con su
/// capability con Send) y está unido a la región: SPARK
/// (Region_Frame_For) solo la da si lo está. Con el cerrojo global.
pub noinline fn dmaAddress(space: u64, region_cap: u64, page: u64, device_cap: u64) u64 {
    const device = abi.fb_cap_check(space, device_cap, abi.FB_CAP_DEVICE, abi.FB_RIGHT_SEND);
    if (device != abi.FB_DEVICE_DISK) return abi.FB_ERR_CAP;
    if (@import("device.zig").ownerOf(abi.FB_DEVICE_DISK) != space) return abi.FB_ERR_INVALID;
    const readable = abi.fb_cap_check(space, region_cap, abi.FB_CAP_REGION, abi.FB_RIGHT_RECV);
    if (readable == abi.FB_CAP_NO_OBJECT) return abi.FB_ERR_CAP;
    const physical = abi.fb_uspace_region_frame_for(space, readable + 1, page);
    return if (physical == 0) abi.FB_ERR_INVALID else physical;
}

/// Libera las regiones que nadie alcanza: ni las retiene el kernel, ni hay
/// espacios unidos, ni capabilities que las nombren. Tras destruir un espacio.
pub fn reclaim() void {
    const saved = enter();
    defer leave(saved);
    reclaimLocked();
}

fn reclaimLocked() void {
    var region: u64 = 1;
    while (region <= max_regions) : (region += 1) {
        if (held[region]) continue;
        if (abi.fb_uspace_region_frame(region, 0) == 0) continue;
        if (abi.fb_uspace_region_in_use(region) != 0) continue;
        if (abi.fb_cap_refers(abi.FB_CAP_REGION, object(region)) != 0) continue;
        if (abi.fb_uspace_region_free(region) != abi.FB_USPACE_OK) @panic("no se pudo liberar una region");
        freed_count += 1;
    }
}

/// Regiones liberadas desde el arranque.
pub fn freed() u64 {
    return freed_count;
}

/// Si la región existe.
pub fn alive(region: u64) bool {
    const saved = enter();
    defer leave(saved);
    return abi.fb_uspace_region_frame(region, 0) != 0;
}
