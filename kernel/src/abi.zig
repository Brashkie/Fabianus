// SPDX-License-Identifier: GPL-3.0-or-later
//! Importa una sola vez la ABI común para que todos los módulos compartan tipos.

pub const c = @cImport(@cInclude("fabianus.h"));

/// Falla la compilación si los parámetros se apartan de la declaración en C.
/// El retorno no se compara porque translate-c convierte `_Noreturn` en `void`.
pub fn checkParams(comptime Declared: type, comptime Defined: type) void {
    const declared = @typeInfo(Declared).@"fn";
    const defined = @typeInfo(Defined).@"fn";
    if (declared.params.len != defined.params.len) {
        @compileError("la función no coincide con abi/fabianus.h");
    }
    for (declared.params, defined.params) |c_param, zig_param| {
        if (c_param.type != zig_param.type) {
            @compileError("la función no coincide con abi/fabianus.h");
        }
    }
}
