// SPDX-License-Identifier: GPL-3.0-or-later
//! Genera las constantes de Rust a partir de abi/fabianus.h, para que la ABI
//! siga teniendo una única fuente de verdad.

const std = @import("std");

const c = @cImport({
    // Solo las constantes: las declaraciones de C no hacen falta aquí.
    @cDefine("__ASSEMBLER__", "1");
    @cInclude("fabianus.h");
});

const names = [_][]const u8{
    "FB_SYS_EXIT",        "FB_SYS_YIELD",        "FB_SYS_RECV",         "FB_SYS_TRY_SEND",
    "FB_SYS_DEVICE_MAP",  "FB_SYS_IRQ_BIND",     "FB_SYS_IRQ_ACK",      "FB_ERR_NOT_READY",
    "FB_CAP_SLOT_NONE",   "FB_MSG_SIGNAL",       "FB_USER_DEVICE_BASE", "FB_UART_MODE_TEST",
    "FB_UART_OP_WRITE",   "FB_UART_OP_LOOPBACK", "FB_UART_OP_STOP",     "FB_UART_OP_READ",
    "FB_SYS_REPLY",       "FB_SYS_DEFER",        "FB_SYS_REPLY_TO",     "FB_MSG_CALL",
    "FB_ERR_BUSY",        "FB_ERR_INVALID",
    "FB_SYS_REGION_MAP",  "FB_SYS_DMA_ADDRESS",  "FB_DISK_OP_STOP",     "FB_DISK_OP_READ",
    "FB_DISK_OP_WRITE",   "FB_DISK_OP_CAPACITY", "FB_DISK_OK",          "FB_DISK_ERR_REQUEST",
    "FB_DISK_ERR_IO",     "FB_DISK_SECTORS_PER_PAGE", "FB_DISK_QUEUE_BASE", "FB_DISK_DATA_BASE",
    "FB_PAGE_SIZE",
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const arguments = try std.process.argsAlloc(allocator);
    var file = try std.fs.cwd().createFile(arguments[1], .{});
    defer file.close();

    const writer = file.writer();
    try writer.writeAll("#![no_std]\n");
    inline for (names) |name| {
        try writer.print("pub const {s}: u64 = {d};\n", .{ name, @as(u64, @field(c, name)) });
    }
}
