//! Manejador de panic propio. Sustituye a `std.debug.FullPanic`, que metería
//! en el kernel el formateador de la biblioteca estándar de Zig.
//! Zig exige exactamente estos nombres en el espacio de nombres `panic` raíz.

const platform = @import("platform.zig");
const uart = @import("uart.zig");

fn stop(message: []const u8) noreturn {
    @branchHint(.cold);
    // Un driver puede haber dejado la UART en cualquier estado.
    uart.init();
    uart.print("\nPANIC: ");
    uart.print(message);
    uart.print("\n");
    platform.poweroffFail();
}

pub fn call(message: []const u8, _: ?usize) noreturn {
    stop(message);
}

pub fn sentinelMismatch(_: anytype, _: anytype) noreturn {
    stop("sentinela incorrecto");
}

pub fn unwrapError(_: anyerror) noreturn {
    stop("error desempaquetado");
}

pub fn outOfBounds(_: usize, _: usize) noreturn {
    stop("indice fuera de rango");
}

pub fn startGreaterThanEnd(_: usize, _: usize) noreturn {
    stop("inicio de slice mayor que el final");
}

pub fn inactiveUnionField(_: anytype, _: anytype) noreturn {
    stop("campo inactivo de union");
}

pub fn sliceCastLenRemainder(_: usize) noreturn {
    stop("longitud de slice no divisible");
}

pub fn reachedUnreachable() noreturn {
    stop("se alcanzo codigo inalcanzable");
}

pub fn unwrapNull() noreturn {
    stop("opcional nulo desempaquetado");
}

pub fn castToNull() noreturn {
    stop("conversion a puntero nulo");
}

pub fn incorrectAlignment() noreturn {
    stop("alineacion incorrecta");
}

pub fn invalidErrorCode() noreturn {
    stop("codigo de error invalido");
}

pub fn castTruncatedData() noreturn {
    stop("conversion con perdida de datos");
}

pub fn negativeToUnsigned() noreturn {
    stop("negativo convertido a sin signo");
}

pub fn integerOverflow() noreturn {
    stop("desbordamiento de entero");
}

pub fn shlOverflow() noreturn {
    stop("desbordamiento en desplazamiento izquierdo");
}

pub fn shrOverflow() noreturn {
    stop("desbordamiento en desplazamiento derecho");
}

pub fn divideByZero() noreturn {
    stop("division por cero");
}

pub fn exactDivisionRemainder() noreturn {
    stop("division exacta con resto");
}

pub fn integerPartOutOfBounds() noreturn {
    stop("parte entera fuera de rango");
}

pub fn corruptSwitch() noreturn {
    stop("switch corrupto");
}

pub fn shiftRhsTooBig() noreturn {
    stop("desplazamiento demasiado grande");
}

pub fn invalidEnumValue() noreturn {
    stop("valor de enum invalido");
}

pub fn forLenMismatch() noreturn {
    stop("longitudes distintas en for");
}

pub fn memcpyLenMismatch() noreturn {
    stop("longitudes distintas en memcpy");
}

pub fn memcpyAlias() noreturn {
    stop("memcpy con regiones solapadas");
}

pub fn noreturnReturned() noreturn {
    stop("una funcion noreturn retorno");
}
