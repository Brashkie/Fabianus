//! Driver de la UART 16550 de Fabianus. Es un proceso de usuario corriente: si
//! falla, muere él solo y el kernel puede arrancar otro.
//!
//! Capabilities que recibe al crearse:
//!   hueco 0: endpoint de peticiones, con Recv. Por él llegan también las interrupciones.
//!   hueco 1: el dispositivo, con Send (registros) y Recv (interrupciones).
//!   hueco 2: endpoint hacia el lector de la entrada, con Send.
//!
//! Nunca se bloquea por culpa de un cliente: solo espera cuando no tiene nada
//! que hacer. Las peticiones pueden llegar con send o con call; a una llamada
//! siempre contesta antes de volver a recibir. Una lectura (READ) sin datos se
//! aplaza: el driver sigue atendiendo y contesta cuando la interrupción trae la
//! entrada. Si nadie lee con call, la entrada se empuja al lector del hueco 2
//! con un envío que no puede quedarse en cola.
//!
//! El código se carga como solo lectura y ejecución, así que no puede haber
//! variables globales: el enlazador rechaza la imagen si aparece alguna.

#![no_std]
#![no_main]

use core::arch::asm;
use core::panic::PanicInfo;
use core::ptr::{read_volatile, write_volatile};
use fb_abi::*;

const CAP_REQUESTS: u64 = 0;
const CAP_DEVICE: u64 = 1;
const CAP_READER: u64 = 2;

const REG_DATA: usize = 0;
const REG_IER: usize = 1;
const REG_FCR: usize = 2;
const REG_LCR: usize = 3;
const REG_MCR: usize = 4;
const REG_LSR: usize = 5;

const IER_RX: u8 = 0x01;
const LCR_8N1: u8 = 0x03;
const LCR_DLAB: u8 = 0x80;
const FCR_ENABLE_AND_CLEAR: u8 = 0x07;
const MCR_LOOPBACK: u8 = 0x10;
const LSR_RX_READY: u8 = 0x01;
const LSR_TX_EMPTY: u8 = 0x20;

const MESSAGE_BYTES: usize = 24;
const RING_BYTES: usize = 64;
const FLUSH_ATTEMPTS: u32 = 64;

const EXIT_NO_DEVICE: u64 = 0xd1;
const EXIT_NO_INTERRUPT: u64 = 0xd2;
const EXIT_PANIC: u64 = 0xd3;

struct Message {
    status: u64,
    kind: u64,
    words: [u64; 4],
}

fn exit(code: u64) -> ! {
    unsafe {
        asm!("ecall", in("a7") FB_SYS_EXIT, in("a0") code, options(noreturn, nostack));
    }
}

fn call2(number: u64, first: u64, second: u64) -> u64 {
    let result: u64;
    unsafe {
        asm!("ecall", in("a7") number, inlateout("a0") first => result, in("a1") second, options(nostack));
    }
    result
}

fn recv(cap: u64) -> Message {
    let (status, a1, a2, a3, a4, kind): (u64, u64, u64, u64, u64, u64);
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
            options(nostack),
        );
    }
    Message { status, kind, words: [a1, a2, a3, a4] }
}

fn send_words(number: u64, first: u64, words: [u64; 4]) -> u64 {
    let status: u64;
    unsafe {
        asm!(
            "ecall",
            in("a7") number,
            inlateout("a0") first => status,
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

/// Contesta la llamada que se acaba de recibir.
fn reply(words: [u64; 4]) -> u64 {
    send_words(FB_SYS_REPLY, 0, words)
}

/// Aplaza la llamada que se acaba de recibir. Devuelve con quién queda pendiente.
fn defer_reply() -> Option<u64> {
    let (status, caller): (u64, u64);
    unsafe {
        asm!("ecall", in("a7") FB_SYS_DEFER, lateout("a0") status, lateout("a1") caller, options(nostack));
    }
    if status == 0 { Some(caller) } else { None }
}

/// Contesta una llamada aplazada.
fn reply_to(caller: u64, words: [u64; 4]) -> u64 {
    send_words(FB_SYS_REPLY_TO, caller, words)
}

fn try_send(cap: u64, words: [u64; 4]) -> u64 {
    let status: u64;
    unsafe {
        asm!(
            "ecall",
            in("a7") FB_SYS_TRY_SEND,
            inlateout("a0") cap => status,
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

struct Uart {
    base: *mut u8,
}

impl Uart {
    fn write(&self, register: usize, value: u8) {
        unsafe { write_volatile(self.base.add(register), value) }
    }

    fn read(&self, register: usize) -> u8 {
        unsafe { read_volatile(self.base.add(register)) }
    }

    /// 38400 baudios, 8N1 y FIFO activa, con avisos solo al recibir.
    fn start(&self) {
        self.write(REG_IER, 0);
        self.write(REG_LCR, LCR_DLAB);
        self.write(REG_DATA, 3);
        self.write(REG_IER, 0);
        self.write(REG_LCR, LCR_8N1);
        self.write(REG_FCR, FCR_ENABLE_AND_CLEAR);
        self.write(REG_MCR, 0);
        self.write(REG_IER, IER_RX);
    }

    fn put_raw(&self, byte: u8) {
        while self.read(REG_LSR) & LSR_TX_EMPTY == 0 {}
        self.write(REG_DATA, byte);
    }

    fn put(&self, byte: u8) {
        if byte == b'\n' {
            self.put_raw(b'\r');
        }
        self.put_raw(byte);
    }

    fn loopback(&self, enabled: bool) {
        self.write(REG_MCR, if enabled { MCR_LOOPBACK } else { 0 });
    }

    fn received(&self) -> Option<u8> {
        if self.read(REG_LSR) & LSR_RX_READY == 0 {
            None
        } else {
            Some(self.read(REG_DATA))
        }
    }
}

/// Entrada pendiente de entregar. Si se llena, lo nuevo se pierde y se cuenta.
struct Ring {
    bytes: [u8; RING_BYTES],
    head: usize,
    length: usize,
    dropped: u64,
}

impl Ring {
    fn push(&mut self, byte: u8) {
        if self.length == RING_BYTES {
            self.dropped += 1;
            return;
        }
        self.bytes[(self.head + self.length) % RING_BYTES] = byte;
        self.length += 1;
    }

    /// Primer tramo de la entrada, listo para enviarlo. No lo retira.
    fn peek(&self) -> [u64; 4] {
        let count = if self.length < MESSAGE_BYTES { self.length } else { MESSAGE_BYTES };
        let mut words = [count as u64, 0, 0, 0];
        for position in 0..count {
            let byte = self.bytes[(self.head + position) % RING_BYTES] as u64;
            words[1 + position / 8] |= byte << (8 * (position % 8));
        }
        words
    }

    fn discard(&mut self, count: usize) {
        self.head = (self.head + count) % RING_BYTES;
        self.length -= count;
    }
}

/// Un lector que no está esperando no puede detener al driver: tras unos
/// intentos, la entrada se queda guardada hasta el próximo aviso.
fn flush(ring: &mut Ring) {
    let mut attempts = 0;
    while ring.length != 0 {
        let words = ring.peek();
        let status = try_send(CAP_READER, words);
        if status == 0 {
            ring.discard(words[0] as usize);
        } else if status == FB_ERR_NOT_READY && attempts < FLUSH_ATTEMPTS {
            attempts += 1;
            call2(FB_SYS_YIELD, 0, 0);
        } else {
            return;
        }
    }
}

/// Si hay un lector aplazado y entrada, se la entrega. Si el lector murió, la
/// entrada se queda para el siguiente.
fn answer_reader(ring: &mut Ring, reader: &mut Option<u64>) {
    if let Some(caller) = *reader {
        if ring.length != 0 {
            let words = ring.peek();
            if reply_to(caller, words) == 0 {
                ring.discard(words[0] as usize);
            }
            *reader = None;
        }
    }
}

fn drain(uart: &Uart, ring: &mut Ring) {
    while let Some(byte) = uart.received() {
        ring.push(byte);
    }
}

fn write_message(uart: &Uart, words: &[u64; 4], length: usize) {
    for position in 0..length {
        uart.put((words[1 + position / 8] >> (8 * (position % 8))) as u8);
    }
}

fn run(test_mode: bool) -> ! {
    let address = call2(FB_SYS_DEVICE_MAP, CAP_DEVICE, 0);
    if address != FB_USER_DEVICE_BASE {
        exit(EXIT_NO_DEVICE);
    }

    let uart = Uart { base: address as *mut u8 };
    uart.start();

    if call2(FB_SYS_IRQ_BIND, CAP_DEVICE, CAP_REQUESTS) != 0 {
        exit(EXIT_NO_INTERRUPT);
    }

    let mut ring = Ring { bytes: [0; RING_BYTES], head: 0, length: 0, dropped: 0 };
    let mut written: u64 = 0;
    let mut rejected: u64 = 0;
    // Lector cuya llamada está aplazada, y si alguien lee ya con llamadas.
    let mut reader: Option<u64> = None;
    let mut pulled = false;

    loop {
        let message = recv(CAP_REQUESTS);
        if message.status != 0 {
            rejected += 1;
            continue;
        }

        let is_call = message.kind == FB_MSG_CALL;
        if message.kind == FB_MSG_SIGNAL {
            drain(&uart, &mut ring);
            call2(FB_SYS_IRQ_ACK, CAP_DEVICE, 0);
        } else {
            let operation = message.words[0] & 0xff;
            let length = (message.words[0] >> 8) as usize;
            // Lo que se contesta a una llamada; a un envío no se le contesta.
            let mut answer = Some([0, 0, 0, 0]);
            match operation {
                FB_UART_OP_WRITE if length <= MESSAGE_BYTES => {
                    write_message(&uart, &message.words, length);
                    written += length as u64;
                    answer = Some([length as u64, 0, 0, 0]);
                }
                FB_UART_OP_READ if is_call => {
                    pulled = true;
                    drain(&uart, &mut ring);
                    if reader.is_some() {
                        answer = Some([FB_ERR_BUSY, 0, 0, 0]);
                    } else if ring.length != 0 {
                        let words = ring.peek();
                        ring.discard(words[0] as usize);
                        answer = Some(words);
                    } else {
                        reader = defer_reply();
                        answer = None;
                    }
                }
                // Dejar la UART en bucle o parar el driver solo se permite en las pruebas.
                FB_UART_OP_LOOPBACK if test_mode => uart.loopback(message.words[1] != 0),
                FB_UART_OP_STOP if test_mode => {
                    drain(&uart, &mut ring);
                    flush(&mut ring);
                    exit((rejected + ring.dropped) << 32 | written);
                }
                _ => {
                    rejected += 1;
                    answer = Some([FB_ERR_INVALID, 0, 0, 0]);
                }
            }
            if is_call {
                if let Some(words) = answer {
                    reply(words);
                }
            }
        }
        answer_reader(&mut ring, &mut reader);
        if !pulled {
            flush(&mut ring);
        }
    }
}

#[no_mangle]
#[link_section = ".text.entry"]
pub extern "C" fn _start(argument: u64) -> ! {
    run(argument == FB_UART_MODE_TEST)
}

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    exit(EXIT_PANIC)
}
