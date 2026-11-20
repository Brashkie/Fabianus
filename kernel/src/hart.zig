//! Identidad del hart en el que se ejecuta el kernel.
//!
//! El kernel guarda el número de hart en tp. boot.S lo pone al arrancar, y en
//! cada trap la entrada lo vuelve a cargar desde la cima de la pila de traps
//! del hilo (cada hilo pertenece a un hart), porque el usuario puede cambiar tp.

const std = @import("std");
const abi = @import("abi.zig").c;

pub const max: usize = abi.FB_MAX_HARTS;

/// Un número de hart válido (boot.S aparca los harts >= max).
pub const Index = std.math.IntFittingRange(0, max - 1);

comptime {
    // Así cualquier valor de Index es un índice válido de los arreglos por hart.
    if (std.math.maxInt(Index) != max - 1) @compileError("FB_MAX_HARTS debe ser potencia de dos");
}

/// El hart actual. Los hilos no cambian de hart, así que tp no cambia
/// mientras corre un mismo hilo: el asm no es volátil y el compilador puede
/// reutilizar la lectura. El tipo acotado le quita las comprobaciones de
/// límites a los arreglos por hart.
pub inline fn id() Index {
    const raw = asm ("mv %[value], tp"
        : [value] "=r" (-> usize),
    );
    return @truncate(raw);
}
