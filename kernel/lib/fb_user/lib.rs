// SPDX-License-Identifier: GPL-3.0-or-later
//! Llamadas al sistema de Fabianus para programas de usuario en Rust.
//!
//! Solo envuelve `ecall`: sin asignación de memoria ni datos globales, porque
//! la imagen de un programa de usuario es de solo lectura.

#![no_std]

use core::arch::asm;
use fb_abi::*;

/// Termina el proceso con `code`.
pub fn exit(code: u64) -> ! {
    unsafe {
        asm!("ecall", in("a7") FB_SYS_EXIT, in("a0") code, options(noreturn, nostack));
    }
}

/// Una llamada al sistema de hasta tres argumentos.
pub fn syscall3(number: u64, first: u64, second: u64, third: u64) -> u64 {
    let result: u64;
    unsafe {
        asm!(
            "ecall",
            in("a7") number,
            inlateout("a0") first => result,
            in("a1") second,
            in("a2") third,
            options(nostack),
        );
    }
    result
}

/// Un error de una llamada al sistema es un valor muy alto (FB_ERR_*).
pub fn failed(result: u64) -> bool {
    result > u64::MAX - 64
}

/// Mapea la región compartida del hueco `cap` en `va`.
pub fn region_map(cap: u64, va: u64) -> u64 {
    syscall3(FB_SYS_REGION_MAP, cap, va, 0)
}

/// Lo que llega en un recv o en la respuesta de un call. `badge` es la marca
/// de la capability con que enviaron (solo en recv; la pone el kernel).
pub struct Message {
    pub status: u64,
    pub kind: u64,
    pub words: [u64; 4],
    pub badge: u64,
}

/// Espera un mensaje en el endpoint `cap`, sin aceptar capabilities.
pub fn recv(cap: u64) -> Message {
    let (status, a1, a2, a3, a4, kind, badge): (u64, u64, u64, u64, u64, u64, u64);
    unsafe {
        asm!(
            "ecall",
            in("a7") FB_SYS_RECV,
            inlateout("a0") cap => status,
            inlateout("a1") FB_CAP_SLOT_NONE => a1,
            lateout("a2") a2,
            lateout("a3") a3,
            lateout("a4") a4,
            lateout("a5") kind,
            lateout("a6") badge,
            options(nostack),
        );
    }
    Message { status, kind, words: [a1, a2, a3, a4], badge }
}

/// Llama al servidor del endpoint `cap` y espera su respuesta.
pub fn call(cap: u64, words: [u64; 4]) -> Message {
    let (status, a1, a2, a3, a4, kind): (u64, u64, u64, u64, u64, u64);
    unsafe {
        asm!(
            "ecall",
            in("a7") FB_SYS_CALL,
            inlateout("a0") cap => status,
            inlateout("a1") words[0] => a1,
            inlateout("a2") words[1] => a2,
            inlateout("a3") words[2] => a3,
            inlateout("a4") words[3] => a4,
            inlateout("a5") FB_CAP_SLOT_NONE => kind,
            options(nostack),
        );
    }
    Message { status, kind, words: [a1, a2, a3, a4], badge: 0 }
}

/// Contesta la llamada que se acaba de recibir.
pub fn reply(words: [u64; 4]) -> u64 {
    let status: u64;
    unsafe {
        asm!(
            "ecall",
            in("a7") FB_SYS_REPLY,
            inlateout("a0") 0u64 => status,
            in("a1") words[0],
            in("a2") words[1],
            in("a3") words[2],
            in("a4") words[3],
            in("a5") FB_CAP_SLOT_NONE,
            options(nostack),
        );
    }
    status
}
