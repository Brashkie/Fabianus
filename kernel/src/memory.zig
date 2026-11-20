//! Reparte al asignador SPARK la RAM que queda libre tras la imagen del kernel.

const abi = @import("abi.zig").c;

extern var __image_end: u8;

pub var base: u64 = 0;
pub var frame_count: u64 = 0;

pub fn init() void {
    const page_mask: u64 = abi.FB_PAGE_SIZE - 1;
    const ram_end: u64 = @as(u64, abi.FB_RAM_BASE) + abi.FB_RAM_SIZE;
    base = (@intFromPtr(&__image_end) + page_mask) & ~page_mask;
    frame_count = (ram_end - base) / abi.FB_PAGE_SIZE;

    if (abi.fb_frames_init(base, frame_count) != abi.FB_FRAMES_OK) {
        @panic("no se pudo iniciar el asignador de marcos");
    }
}
