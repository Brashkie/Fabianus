//! Cerrojo de giro para varios harts.
//!
//! Adquirir es un amoswap.w.aq que pone 1 y devuelve lo que había: solo entra
//! quien lee 0, y como el intercambio es atómico, dos harts nunca leen 0 a la
//! vez. Mientras está tomado se gira con lecturas normales, sin escribir, para
//! no pelear por la línea de caché. Soltar es un amoswap.w.rl que pone 0.
//! .aq y .rl dan el orden: nada de lo que hay dentro se adelanta a la entrada
//! ni se retrasa tras la salida (RVWMO).

pub const SpinLock = struct {
    state: u32 = 0,

    pub fn acquire(self: *SpinLock) void {
        while (true) {
            if (swapAcquire(&self.state, 1) == 0) return;
            while (@atomicLoad(u32, &self.state, .monotonic) != 0) {}
        }
    }

    pub fn release(self: *SpinLock) void {
        asm volatile ("amoswap.w.rl zero, zero, (%[address])"
            :
            : [address] "r" (&self.state),
            : "memory"
        );
    }

    pub fn held(self: *const SpinLock) bool {
        return @atomicLoad(u32, &self.state, .monotonic) != 0;
    }
};

/// Cerrojo de tiques: cada hart saca un número con amoadd y entra cuando
/// `serving` llega a él, así que entran en el orden en que llegaron. Con N
/// harts, quien espera deja pasar como mucho N - 1 secciones críticas antes de
/// la suya: nadie se queda fuera mientras los demás sigan saliendo. El de
/// amoswap no da esa cota: un hart que entra y sale sin parar puede ganarlo
/// siempre.
///
/// Solo quien tiene el cerrojo escribe `serving`. Los contadores dan la
/// vuelta a los 2^32, pero solo importa la igualdad y nunca hay más de N
/// tiques pendientes. La lectura con acquire que ve el turno propio ordena la
/// sección crítica detrás; la escritura con release al soltar, delante.
pub const TicketLock = struct {
    next: u32 = 0,
    serving: u32 = 0,

    pub fn acquire(self: *TicketLock) void {
        const ticket = asm volatile ("amoadd.w %[previous], %[one], (%[address])"
            : [previous] "=r" (-> u32),
            : [one] "r" (@as(u32, 1)),
              [address] "r" (&self.next),
            : "memory"
        );
        while (@atomicLoad(u32, &self.serving, .acquire) != ticket) {}
    }

    pub fn release(self: *TicketLock) void {
        const turn = @atomicLoad(u32, &self.serving, .monotonic);
        @atomicStore(u32, &self.serving, turn +% 1, .release);
    }

    pub fn held(self: *const TicketLock) bool {
        return @atomicLoad(u32, &self.next, .monotonic) != @atomicLoad(u32, &self.serving, .monotonic);
    }
};

inline fn swapAcquire(address: *u32, value: u32) u32 {
    return asm volatile ("amoswap.w.aq %[previous], %[value], (%[address])"
        : [previous] "=r" (-> u32),
        : [value] "r" (value),
          [address] "r" (address),
        : "memory"
    );
}
