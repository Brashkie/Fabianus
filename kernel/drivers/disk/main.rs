// SPDX-License-Identifier: GPL-3.0-or-later
//! Driver del disco virtio-blk de Fabianus (virtio-mmio moderno, versión 2).
//! Es un proceso de usuario corriente: si falla, muere él solo, y el kernel
//! reinicia el dispositivo antes de liberar su memoria.
//!
//! Capabilities que recibe al crearse:
//!   hueco 0: endpoint de peticiones, con Recv. Los clientes le llaman.
//!   hueco 1: el disco, con Send (registros y DMA) y Recv (interrupciones).
//!   hueco 2: endpoint de interrupciones, con Recv: solo llegan señales.
//!   hueco 3: región de la cola (una página), solo suya.
//!   hueco 4: región de datos, compartida con los clientes.
//!
//! Los datos nunca se copian: el disco lee y escribe por DMA directamente en
//! la región que comparte el cliente. El kernel solo le da la dirección física
//! de las páginas de regiones a las que está unido (SPARK: Region_Frame_For).
//! Sin IOMMU, un driver de DMA podría pedir al disco que escriba en cualquier
//! sitio: este proceso es de confianza para eso, como en cualquier sistema sin
//! IOMMU.
//!
//! Atiende las peticiones de una en una: aplaza la llamada, espera la
//! interrupción del disco y la contesta. No hay variables globales: la imagen es de solo lectura.

#![no_std]
#![no_main]

use core::arch::asm;
use core::panic::PanicInfo;
use core::ptr::{read_volatile, write_volatile};
use fb_abi::*;

const CAP_REQUESTS: u64 = 0;
const CAP_DEVICE: u64 = 1;
const CAP_INTERRUPTS: u64 = 2;
const CAP_QUEUE: u64 = 3;
const CAP_DATA: u64 = 4;

// Registros de virtio-mmio.
const REG_MAGIC: usize = 0x000;
const REG_VERSION: usize = 0x004;
const REG_DEVICE_ID: usize = 0x008;
const REG_DEVICE_FEATURES: usize = 0x010;
const REG_DEVICE_FEATURES_SEL: usize = 0x014;
const REG_DRIVER_FEATURES: usize = 0x020;
const REG_DRIVER_FEATURES_SEL: usize = 0x024;
const REG_QUEUE_SEL: usize = 0x030;
const REG_QUEUE_NUM_MAX: usize = 0x034;
const REG_QUEUE_NUM: usize = 0x038;
const REG_QUEUE_READY: usize = 0x044;
const REG_QUEUE_NOTIFY: usize = 0x050;
const REG_INTERRUPT_STATUS: usize = 0x060;
const REG_INTERRUPT_ACK: usize = 0x064;
const REG_STATUS: usize = 0x070;
const REG_QUEUE_DESC_LOW: usize = 0x080;
const REG_QUEUE_DESC_HIGH: usize = 0x084;
const REG_QUEUE_DRIVER_LOW: usize = 0x090;
const REG_QUEUE_DRIVER_HIGH: usize = 0x094;
const REG_QUEUE_DEVICE_LOW: usize = 0x0a0;
const REG_QUEUE_DEVICE_HIGH: usize = 0x0a4;
const REG_CAPACITY_LOW: usize = 0x100;
const REG_CAPACITY_HIGH: usize = 0x104;

const MAGIC: u32 = 0x7472_6976;
const DEVICE_BLOCK: u32 = 2;

const STATUS_ACKNOWLEDGE: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_DRIVER_OK: u32 = 4;
const STATUS_FEATURES_OK: u32 = 8;

/// VIRTIO_F_VERSION_1 es el bit 32: el bit 0 del segundo grupo.
const FEATURE_VERSION_1_HIGH: u32 = 1;

const QUEUE_SIZE: u16 = 8;

// Distribución de la página de la cola.
const DESC_OFFSET: u64 = 0;
const AVAIL_OFFSET: u64 = 128;
const USED_OFFSET: u64 = 512;
const HEADER_OFFSET: u64 = 1024;
const STATUS_OFFSET: u64 = 1040;

const DESC_NEXT: u16 = 1;
const DESC_WRITE: u16 = 2;

const REQUEST_IN: u32 = 0;
const REQUEST_OUT: u32 = 1;

const MAX_DATA_PAGES: usize = 16;

const EXIT_NO_DEVICE: u64 = 0xe1;
const EXIT_NOT_VIRTIO_BLOCK: u64 = 0xe2;
const EXIT_FEATURES: u64 = 0xe3;
const EXIT_QUEUE: u64 = 0xe4;
const EXIT_NO_MEMORY: u64 = 0xe5;
const EXIT_NO_INTERRUPT: u64 = 0xe6;
const EXIT_PANIC: u64 = 0xe7;
const EXIT_NO_ACK: u64 = 0xe8;

fn exit(code: u64) -> ! {
    unsafe {
        asm!("ecall", in("a7") FB_SYS_EXIT, in("a0") code, options(noreturn, nostack));
    }
}

fn syscall3(number: u64, first: u64, second: u64, third: u64) -> u64 {
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
fn failed(result: u64) -> bool {
    result > u64::MAX - 64
}

struct Message {
    status: u64,
    kind: u64,
    words: [u64; 4],
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

/// Contesta la llamada que se acaba de recibir.
fn reply(first: u64, second: u64) {
    unsafe {
        asm!(
            "ecall",
            in("a7") FB_SYS_REPLY,
            inlateout("a0") 0u64 => _,
            in("a1") first,
            in("a2") second,
            in("a3") 0u64,
            in("a4") 0u64,
            in("a5") FB_CAP_SLOT_NONE,
            options(nostack),
        );
    }
}

/// Aplaza la llamada que se acaba de recibir: un servidor que debe una
/// respuesta no puede recibir nada más (Ipc_Core). Devuelve con quién queda
/// pendiente.
fn defer_reply() -> u64 {
    let (status, caller): (u64, u64);
    unsafe {
        asm!("ecall", in("a7") FB_SYS_DEFER, lateout("a0") status, lateout("a1") caller, options(nostack));
    }
    if status != 0 {
        exit(EXIT_NO_INTERRUPT);
    }
    caller
}

/// Contesta una llamada aplazada.
fn reply_to(caller: u64, first: u64) {
    unsafe {
        asm!(
            "ecall",
            in("a7") FB_SYS_REPLY_TO,
            inlateout("a0") caller => _,
            in("a1") first,
            in("a2") 0u64,
            in("a3") 0u64,
            in("a4") 0u64,
            in("a5") FB_CAP_SLOT_NONE,
            options(nostack),
        );
    }
}

fn fence() {
    unsafe { asm!("fence rw, rw", options(nostack)) }
}

struct Mmio {
    base: u64,
}

impl Mmio {
    fn read(&self, register: usize) -> u32 {
        unsafe { read_volatile((self.base as usize + register) as *const u32) }
    }

    fn write(&self, register: usize, value: u32) {
        unsafe { write_volatile((self.base as usize + register) as *mut u32, value) }
    }

    fn write64(&self, low: usize, high: usize, value: u64) {
        self.write(low, value as u32);
        self.write(high, (value >> 32) as u32);
    }
}

/// Memoria de la cola: la ve el driver en `virt` y el disco en `phys`.
struct Queue {
    virt: u64,
    phys: u64,
    /// El último used.idx ya atendido.
    seen: u16,
}

impl Queue {
    fn put16(&self, offset: u64, value: u16) {
        unsafe { write_volatile((self.virt + offset) as *mut u16, value) }
    }

    fn put32(&self, offset: u64, value: u32) {
        unsafe { write_volatile((self.virt + offset) as *mut u32, value) }
    }

    fn put64(&self, offset: u64, value: u64) {
        unsafe { write_volatile((self.virt + offset) as *mut u64, value) }
    }

    fn get8(&self, offset: u64) -> u8 {
        unsafe { read_volatile((self.virt + offset) as *const u8) }
    }

    fn get16(&self, offset: u64) -> u16 {
        unsafe { read_volatile((self.virt + offset) as *const u16) }
    }

    fn descriptor(&self, index: u64, address: u64, length: u32, flags: u16, next: u16) {
        let at = DESC_OFFSET + 16 * index;
        self.put64(at, address);
        self.put32(at + 8, length);
        self.put16(at + 12, flags);
        self.put16(at + 14, next);
    }
}

/// Arranca el dispositivo según la secuencia de virtio 1.x y prepara la cola 0.
fn start(device: &Mmio, queue: &Queue) -> u64 {
    if device.read(REG_MAGIC) != MAGIC || device.read(REG_VERSION) != 2 {
        exit(EXIT_NOT_VIRTIO_BLOCK);
    }
    if device.read(REG_DEVICE_ID) != DEVICE_BLOCK {
        exit(EXIT_NOT_VIRTIO_BLOCK);
    }

    device.write(REG_STATUS, 0);
    device.write(REG_STATUS, STATUS_ACKNOWLEDGE);
    device.write(REG_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // Solo VERSION_1: sin ninguna otra característica opcional.
    device.write(REG_DEVICE_FEATURES_SEL, 1);
    if device.read(REG_DEVICE_FEATURES) & FEATURE_VERSION_1_HIGH == 0 {
        exit(EXIT_FEATURES);
    }
    device.write(REG_DRIVER_FEATURES_SEL, 1);
    device.write(REG_DRIVER_FEATURES, FEATURE_VERSION_1_HIGH);
    device.write(REG_DRIVER_FEATURES_SEL, 0);
    device.write(REG_DRIVER_FEATURES, 0);
    device.write(REG_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);
    if device.read(REG_STATUS) & STATUS_FEATURES_OK == 0 {
        exit(EXIT_FEATURES);
    }

    device.write(REG_QUEUE_SEL, 0);
    if device.read(REG_QUEUE_NUM_MAX) < QUEUE_SIZE as u32 {
        exit(EXIT_QUEUE);
    }
    device.write(REG_QUEUE_NUM, QUEUE_SIZE as u32);
    device.write64(REG_QUEUE_DESC_LOW, REG_QUEUE_DESC_HIGH, queue.phys + DESC_OFFSET);
    device.write64(REG_QUEUE_DRIVER_LOW, REG_QUEUE_DRIVER_HIGH, queue.phys + AVAIL_OFFSET);
    device.write64(REG_QUEUE_DEVICE_LOW, REG_QUEUE_DEVICE_HIGH, queue.phys + USED_OFFSET);
    device.write(REG_QUEUE_READY, 1);

    device.write(
        REG_STATUS,
        STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK,
    );

    (device.read(REG_CAPACITY_LOW) as u64) | ((device.read(REG_CAPACITY_HIGH) as u64) << 32)
}

/// Espera la interrupción que dice que el disco terminó la petición en curso.
fn wait_completion(device: &Mmio, queue: &mut Queue) {
    loop {
        let message = recv(CAP_INTERRUPTS);
        if message.status != 0 || message.kind != FB_MSG_SIGNAL {
            exit(EXIT_NO_INTERRUPT);
        }
        let pending = device.read(REG_INTERRUPT_STATUS);
        device.write(REG_INTERRUPT_ACK, pending);
        if failed(syscall3(FB_SYS_IRQ_ACK, CAP_DEVICE, 0, 0)) {
            exit(EXIT_NO_ACK);
        }
        fence();
        let used = queue.get16(USED_OFFSET + 2);
        if used != queue.seen {
            queue.seen = used;
            return;
        }
    }
}

/// Una página entre el disco y la página `data` de la región. Devuelve un FB_DISK_*.
fn transfer(device: &Mmio, queue: &mut Queue, write: bool, sector: u64, data: u64) -> u64 {
    queue.put32(HEADER_OFFSET, if write { REQUEST_OUT } else { REQUEST_IN });
    queue.put32(HEADER_OFFSET + 4, 0);
    queue.put64(HEADER_OFFSET + 8, sector);
    unsafe { write_volatile((queue.virt + STATUS_OFFSET) as *mut u8, 0xff) }

    queue.descriptor(0, queue.phys + HEADER_OFFSET, 16, DESC_NEXT, 1);
    // Al leer, el disco escribe en la página del cliente.
    let data_flags = if write { DESC_NEXT } else { DESC_NEXT | DESC_WRITE };
    queue.descriptor(1, data, FB_PAGE_SIZE as u32, data_flags, 2);
    queue.descriptor(2, queue.phys + STATUS_OFFSET, 1, DESC_WRITE, 0);

    let index = queue.get16(AVAIL_OFFSET + 2);
    queue.put16(AVAIL_OFFSET + 4 + 2 * (index % QUEUE_SIZE) as u64, 0);
    fence();
    queue.put16(AVAIL_OFFSET + 2, index.wrapping_add(1));
    fence();
    device.write(REG_QUEUE_NOTIFY, 0);

    wait_completion(device, queue);
    fence();
    if queue.get8(STATUS_OFFSET) == 0 {
        FB_DISK_OK
    } else {
        FB_DISK_ERR_IO
    }
}

fn run() -> ! {
    let base = syscall3(FB_SYS_DEVICE_MAP, CAP_DEVICE, 0, 0);
    if failed(base) {
        exit(EXIT_NO_DEVICE);
    }
    let device = Mmio { base };

    if syscall3(FB_SYS_REGION_MAP, CAP_QUEUE, FB_DISK_QUEUE_BASE, 0) != 0
        || syscall3(FB_SYS_REGION_MAP, CAP_DATA, FB_DISK_DATA_BASE, 0) != 0
    {
        exit(EXIT_NO_MEMORY);
    }
    if syscall3(FB_SYS_IRQ_BIND, CAP_DEVICE, CAP_INTERRUPTS, 0) != 0 {
        exit(EXIT_NO_INTERRUPT);
    }

    let queue_phys = syscall3(FB_SYS_DMA_ADDRESS, CAP_QUEUE, 0, CAP_DEVICE);
    if failed(queue_phys) {
        exit(EXIT_NO_MEMORY);
    }
    let mut queue = Queue { virt: FB_DISK_QUEUE_BASE, phys: queue_phys, seen: 0 };

    // Las direcciones físicas de las páginas de datos: hasta que el kernel diga
    // que no hay más.
    let mut data = [0u64; MAX_DATA_PAGES];
    let mut pages = 0usize;
    while pages < MAX_DATA_PAGES {
        let physical = syscall3(FB_SYS_DMA_ADDRESS, CAP_DATA, pages as u64, CAP_DEVICE);
        if failed(physical) {
            break;
        }
        data[pages] = physical;
        pages += 1;
    }
    if pages == 0 {
        exit(EXIT_NO_MEMORY);
    }

    let capacity = start(&device, &queue);

    loop {
        let message = recv(CAP_REQUESTS);
        if message.status != 0 {
            continue;
        }
        let [operation, sector, page, _] = message.words;
        match operation {
            FB_DISK_OP_STOP => {
                reply(FB_DISK_OK, 0);
                device.write(REG_STATUS, 0);
                exit(0);
            }
            FB_DISK_OP_CAPACITY => reply(FB_DISK_OK, capacity),
            FB_DISK_OP_READ | FB_DISK_OP_WRITE => {
                // La página y los sectores se comprueban aquí; el disco
                // también rechazaría sectores fuera de rango.
                let fits = sector <= capacity && capacity - sector >= FB_DISK_SECTORS_PER_PAGE;
                if page >= pages as u64 || !fits {
                    reply(FB_DISK_ERR_REQUEST, 0);
                } else {
                    // Mientras el disco trabaja, la llamada queda aplazada:
                    // así el driver puede esperar la interrupción.
                    let caller = defer_reply();
                    let write = operation == FB_DISK_OP_WRITE;
                    let status = transfer(&device, &mut queue, write, sector, data[page as usize]);
                    reply_to(caller, status);
                }
            }
            _ => reply(FB_DISK_ERR_REQUEST, 0),
        }
    }
}

#[no_mangle]
#[link_section = ".text.entry"]
pub extern "C" fn _start(_argument: u64) -> ! {
    run()
}

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    exit(EXIT_PANIC)
}
