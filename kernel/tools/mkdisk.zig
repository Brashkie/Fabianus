// SPDX-License-Identifier: GPL-3.0-or-later
//! Genera la imagen del disco de pruebas: 2048 sectores de 512 bytes (1 MiB).
//! La palabra i (de 8 bytes, little endian) del sector s vale s * 2^32 + i,
//! así que cualquier lectura se puede comprobar sin guardar una copia.
//! QEMU la abre con snapshot=on: lo que escriben las pruebas se pierde al
//! apagar y cada arranque empieza con el mismo disco.

const std = @import("std");

pub const sectors: u64 = 2048;
pub const sector_bytes: u64 = 512;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arguments = try std.process.argsAlloc(arena.allocator());

    var file = try std.fs.cwd().createFile(arguments[1], .{});
    defer file.close();
    var buffered = std.io.bufferedWriter(file.writer());
    const writer = buffered.writer();

    var sector: u64 = 0;
    while (sector < sectors) : (sector += 1) {
        var word: u64 = 0;
        while (word < sector_bytes / 8) : (word += 1) {
            try writer.writeInt(u64, (sector << 32) | word, .little);
        }
    }
    try buffered.flush();
}
