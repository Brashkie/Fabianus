// SPDX-License-Identifier: GPL-3.0-or-later
//! Describe el mapa de memoria del kernel y activa Sv39.
//! Las tablas las construye y las demuestra el módulo SPARK.

const abi = @import("abi.zig").c;
const riscv = @import("riscv.zig");
const smp = @import("smp.zig");
const thread = @import("thread.zig");

extern var __text_start: u8;
extern var __text_end: u8;
extern var __rodata_start: u8;
extern var __rodata_end: u8;
extern var __data_start: u8;
extern var __data_end: u8;
extern var __stack_bottom: u8;
extern var __stack_top: u8;
extern var __trap_stack_bottom: u8;
extern var __trap_stack_top: u8;
extern var __image_end: u8;

const satp_mode_sv39: u64 = 8 << 60;

fn address(symbol: *u8) u64 {
    return @intFromPtr(symbol);
}

const RegionList = struct {
    items: [abi.FB_PAGING_MAX_REGIONS]abi.fb_region = undefined,
    count: u64 = 0,

    /// Añade una región con dirección virtual igual a la física.
    fn add(self: *RegionList, start: u64, end: u64, perm: u64, size: u64) void {
        if (self.count == self.items.len) @panic("demasiadas regiones de memoria");
        self.items[self.count] = .{
            .va = start,
            .pa = start,
            .length = end - start,
            .perm = perm,
            .size = size,
        };
        self.count += 1;
    }
};

fn alignUp(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}

/// Valor de satp para unas tablas cuya raíz está en esa página física.
pub fn satpFor(root_ppn: u64) u64 {
    return satp_mode_sv39 | root_ppn;
}

pub fn kernelSatp() u64 {
    return satpFor(@intFromPtr(&abi.fb_page_pool) / abi.FB_PAGE_SIZE);
}

/// Cambia de tablas e invalida la TLB. El kernel está mapeado igual en todas.
pub fn activate(satp: u64) void {
    asm volatile ("sfence.vma zero, zero");
    riscv.writeCsr("satp", satp);
    asm volatile ("sfence.vma zero, zero");
}

pub fn init() void {
    const image_end = address(&__image_end);
    const ram_end: u64 = @as(u64, abi.FB_RAM_BASE) + abi.FB_RAM_SIZE;
    const first_megapage = alignUp(image_end, abi.FB_MEGAPAGE_SIZE);

    var regions = RegionList{};
    regions.add(address(&__text_start), address(&__text_end), abi.FB_PERM_READ_EXECUTE, abi.FB_PAGE_4K);
    regions.add(address(&__rodata_start), address(&__rodata_end), abi.FB_PERM_READ, abi.FB_PAGE_4K);
    regions.add(address(&__data_start), address(&__data_end), abi.FB_PERM_READ_WRITE, abi.FB_PAGE_4K);
    regions.add(address(&__stack_bottom), address(&__stack_top), abi.FB_PERM_READ_WRITE, abi.FB_PAGE_4K);
    regions.add(address(&__trap_stack_bottom), address(&__trap_stack_top), abi.FB_PERM_READ_WRITE, abi.FB_PAGE_4K);

    // Las pilas de cada hilo; sus páginas de guarda quedan sin mapear.
    var id: u64 = 1;
    while (id < thread.max_threads) : (id += 1) {
        const stack = thread.kernelStack(id);
        regions.add(stack.bottom, stack.top, abi.FB_PERM_READ_WRITE, abi.FB_PAGE_4K);
        const trap_stack = thread.trapStack(id);
        regions.add(trap_stack.bottom, trap_stack.top, abi.FB_PERM_READ_WRITE, abi.FB_PAGE_4K);
    }

    // Las pilas de los harts secundarios, cada una con su página de guarda.
    var hart: u64 = 1;
    while (hart < abi.FB_MAX_HARTS) : (hart += 1) {
        const stack = smp.hartStack(hart);
        regions.add(stack.bottom, stack.top, abi.FB_PERM_READ_WRITE, abi.FB_PAGE_4K);
        const trap_stack = smp.hartTrapStack(hart);
        regions.add(trap_stack.bottom, trap_stack.top, abi.FB_PERM_READ_WRITE, abi.FB_PAGE_4K);
    }

    // RAM libre: páginas de 4 KiB hasta el primer límite de 2 MiB y megapáginas después.
    regions.add(image_end, first_megapage, abi.FB_PERM_READ_WRITE, abi.FB_PAGE_4K);
    regions.add(first_megapage, ram_end, abi.FB_PERM_READ_WRITE, abi.FB_PAGE_2M);

    regions.add(abi.FB_UART0_BASE, abi.FB_UART0_BASE + abi.FB_PAGE_SIZE, abi.FB_PERM_READ_WRITE, abi.FB_PAGE_4K);
    // El disco: el kernel solo lo lee para saber si está y lo reinicia si su
    // driver muere.
    regions.add(abi.FB_VIRTIO0_BASE, abi.FB_VIRTIO0_BASE + abi.FB_PAGE_SIZE, abi.FB_PERM_READ_WRITE, abi.FB_PAGE_4K);
    regions.add(abi.FB_PLIC_BASE, abi.FB_PLIC_BASE + abi.FB_PLIC_SIZE, abi.FB_PERM_READ_WRITE, abi.FB_PAGE_2M);
    // La página de las palabras msip del CLINT, para avisar a otros harts. El
    // PMP solo deja escribir sus primeros 16 bytes.
    regions.add(abi.FB_CLINT_BASE, abi.FB_CLINT_BASE + abi.FB_PAGE_SIZE, abi.FB_PERM_READ_WRITE, abi.FB_PAGE_4K);
    regions.add(
        abi.FB_TEST_FINISHER_BASE,
        abi.FB_TEST_FINISHER_BASE + abi.FB_PAGE_SIZE,
        abi.FB_PERM_READ_WRITE,
        abi.FB_PAGE_4K,
    );

    const pool_base = @intFromPtr(&abi.fb_page_pool);
    if (abi.fb_paging_build(&regions.items, regions.count, pool_base) != abi.FB_PAGING_OK) {
        @panic("no se pudieron construir las tablas de paginas");
    }

    activate(kernelSatp());
}
