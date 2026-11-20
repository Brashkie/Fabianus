//! Salida mínima del kernel por la UART 16550, en modo de sondeo: el arranque,
//! las autopruebas y los pánicos. El driver completo es un proceso de usuario.

const abi = @import("abi.zig").c;

const base: usize = abi.FB_UART0_BASE;

const reg_thr: usize = 0; // Transmisión
const reg_dll: usize = 0; // Divisor bajo (con DLAB)
const reg_ier: usize = 1; // Habilitación de interrupciones
const reg_dlm: usize = 1; // Divisor alto (con DLAB)
const reg_fcr: usize = 2; // Control de FIFO
const reg_lcr: usize = 3; // Control de línea
const reg_mcr: usize = 4; // Control del módem
const reg_lsr: usize = 5; // Estado de línea

const lcr_8n1: u8 = 0x03;
const lcr_dlab: u8 = 0x80;
const fcr_enable_and_clear: u8 = 0x07;
const lsr_thr_empty: u8 = 0x20;
const mcr_loopback: u8 = 0x10;

fn write(offset: usize, value: u8) void {
    const reg: *volatile u8 = @ptrFromInt(base + offset);
    reg.* = value;
}

fn read(offset: usize) u8 {
    const reg: *volatile u8 = @ptrFromInt(base + offset);
    return reg.*;
}

/// Configura 38400 baudios, 8N1, FIFO activa y sin interrupciones.
pub fn init() void {
    write(reg_ier, 0x00);
    write(reg_lcr, lcr_dlab);
    write(reg_dll, 0x03);
    write(reg_dlm, 0x00);
    write(reg_lcr, lcr_8n1);
    write(reg_fcr, fcr_enable_and_clear);
    write(reg_mcr, 0x00);
}

/// Para las autopruebas: con la UART en bucle, simula un byte llegado de fuera.
pub fn injectByte(byte: u8) void {
    putRaw(byte);
}

pub fn loopbackActive() bool {
    return read(reg_mcr) & mcr_loopback != 0;
}

fn putRaw(byte: u8) void {
    while (read(reg_lsr) & lsr_thr_empty == 0) {}
    write(reg_thr, byte);
}

pub fn putChar(byte: u8) void {
    if (byte == '\n') putRaw('\r');
    putRaw(byte);
}

pub fn print(text: []const u8) void {
    for (text) |byte| putChar(byte);
}

pub fn printDecimal(value: u64) void {
    var digits: [20]u8 = undefined;
    var remaining = value;
    var start = digits.len;
    while (true) {
        start -= 1;
        digits[start] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
        if (remaining == 0) break;
    }
    print(digits[start..]);
}

pub fn printHex(value: u64) void {
    const digits = "0123456789abcdef";
    print("0x");
    var shift: u7 = 64;
    while (shift != 0) {
        shift -= 4;
        putChar(digits[@as(usize, @truncate(value >> @intCast(shift))) & 0xf]);
    }
}
