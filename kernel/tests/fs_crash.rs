// SPDX-License-Identifier: GPL-3.0-or-later
//! Prueba de cortes de luz del sistema de archivos (Hito 36; con
//! directorios y renombrar, Hito 37; generaciones, Hito 38; manejadores por
//! cliente, Hito 39).
//!
//! Hueco 0: endpoint del servidor de archivos, con Send y una marca. Hueco 1: la región
//! de datos que comparte con el servidor y el driver (4 páginas), que mapea
//! en FB_USER_SHARED_BASE. Hueco 2: endpoint del driver del disco, con Send:
//! para escribir basura directamente en el disco, programar el corte
//! (FB_DISK_OP_CUT) y volver a dar la luz (FB_DISK_OP_POWER).
//!
//! Una carga fija de operaciones (WORK) lleva el disco por los estados S_0
//! (sin formato: basura en el superbloque y la tabla), S_1 (recién
//! formateado) ... S_N. S_j es lo que queda tras las j primeras operaciones.
//! Que cada operación sea atómica significa: si la luz se va durante la
//! operación f, al montar de nuevo el disco está en S_f o en S_(f+1), nunca
//! en otra cosa (ni corrupto, ni con un archivo a medias, ni con datos de un
//! archivo borrado, ni con una entrada en los dos directorios o en ninguno).
//!
//! El modelo sabe también qué entrada ocupa cada objeto y la generación de
//! cada entrada, así que sabe su número (entrada y generación, lo que da
//! STAT): el disco debe dar ese. Un objeto creado en la entrada de uno
//! borrado debe tener la generación siguiente: así se comprueba que la
//! generación llega al disco con el borrado, en la misma escritura. (Los
//! manejadores abiertos no sobreviven a un servidor: tras el corte, el
//! servidor nuevo empieza sin ninguno.)
//!
//! Argumentos (en los 8 bits bajos, el modo):
//!   JUNK: escribe basura en el superbloque y la tabla y para el servidor. El
//!     siguiente servidor encuentra el disco sin formato, así que al
//!     formatear las generaciones empiezan en 0, como espera el modelo.
//!   RUN | parte << 8 | sectores << 16: tras JUNK o CHECK, con un servidor nuevo,
//!     programa el corte tras `sectores` sectores (la escritura que
//!     cruza el límite escribe sus primeros o sus últimos sectores, según
//!     `parte`) y ejecuta la carga hasta la primera operación que falla.
//!     Para el servidor, vuelve a dar la luz y sale con RESULT | f, donde f es
//!     esa operación (N si el corte no llegó).
//!   CHECK | f << 8: con un servidor nuevo, comprueba que el disco está en
//!     S_f o S_(f+1). Después escribe basura, como JUNK, para la vuelta
//!     siguiente. Sale con RESULT | j, el estado que encontró, y para el
//!     servidor.
//!   CHECK_ANY: como CHECK, pero vale cualquier S_j: para cuando se mata QEMU
//!     sin saber en qué operación. Para el servidor y el driver.
//!   TRANSIENT: un fallo pasajero. Con un archivo escrito, falla la escritura
//!     de la tabla al borrarlo y vuelve la luz: el servidor ya no debe atender
//!     (su tabla ya no es la del disco). Para el servidor.
//!   AFTER_TRANSIENT: con un servidor nuevo, el archivo sigue con sus datos.
//!     Para el servidor y el driver.
//!
//! Si algo falla, sale con el paso en los bits 8 y siguientes y el valor
//! recibido en los 8 bits bajos (siempre por debajo de RESULT).

#![no_std]
#![no_main]

use core::panic::PanicInfo;
use core::ptr::{read_volatile, write_volatile};
use fb_abi::*;
use fb_user::*;

const CAP_FS: u64 = 0;
const CAP_DATA: u64 = 1;
const CAP_DISK: u64 = 2;
const SHARED: u64 = FB_USER_SHARED_BASE;
const WORDS: u64 = FB_PAGE_SIZE / 8;

const RUN: u64 = 1;
const CHECK: u64 = 2;
const CHECK_ANY: u64 = 3;
const TRANSIENT: u64 = 4;
const AFTER_TRANSIENT: u64 = 5;
const JUNK: u64 = 6;

const RESULT: u64 = 1 << 40;

// La carga. Cada operación: tipo, objeto y tres valores. Los objetos tienen
// una identidad fija (0 = "a", 1 = "b"... en los datos), aunque cambien de
// nombre o de directorio:
//   CREATE, MKDIR: directorio (un objeto, o ROOT) y nombre;
//   WRITE: posición, bytes y versión de los datos;
//   RENAME: directorio nuevo y nombre nuevo.
const FORMAT: u64 = 0;
const CREATE: u64 = 1;
const WRITE: u64 = 2;
const DELETE: u64 = 3;
const MKDIR: u64 = 4;
const RENAME: u64 = 5;

const ROOT: u64 = 99;
const OBJECTS: usize = 6;
const SLOTS: usize = 2;
/// Página de la región para las rutas.
const PATH_PAGE: u64 = 3;

const A: u64 = 0;
const B: u64 = 1;
const C: u64 = 2;
const D: u64 = 3;
const X: u64 = 4;
const Y: u64 = 5;

const WORK: [[u64; 5]; 21] = [
    [FORMAT, 0, 0, 0, 0],
    [CREATE, A, ROOT, b'a' as u64, 0],
    [WRITE, A, 0, 4096, 1],
    [WRITE, A, 1, 1000, 1],
    [MKDIR, X, ROOT, b'x' as u64, 0],
    // Un archivo dentro de un directorio.
    [CREATE, B, X, b'b' as u64, 0],
    [WRITE, B, 0, 4096, 1],
    // Reescribir: copia al escribir.
    [WRITE, A, 0, 4096, 2],
    // Reescribir y alargar.
    [WRITE, A, 1, 3000, 2],
    [MKDIR, Y, X, b'y' as u64, 0],
    // Mover un archivo a otro directorio, con otro nombre: x/b -> x/y/e.
    [RENAME, B, Y, b'e' as u64, 0],
    // Borrar "a": sus bloques quedan libres con sus datos dentro.
    [DELETE, A, 0, 0, 0],
    // "c" ocupa la entrada de "a" y uno de sus bloques.
    [CREATE, C, Y, b'c' as u64, 0],
    [WRITE, C, 0, 4096, 1],
    [WRITE, B, 1, 4096, 1],
    // Mover un directorio con cosas dentro a la raíz: x/y -> z.
    [RENAME, Y, ROOT, b'z' as u64, 0],
    // Reescribir menos de un bloque: la longitud no cambia.
    [WRITE, C, 0, 2048, 2],
    [DELETE, B, 0, 0, 0],
    // Borrar un directorio, ya vacío.
    [DELETE, X, 0, 0, 0],
    [CREATE, D, ROOT, b'd' as u64, 0],
    [WRITE, D, 0, 512, 1],
];
const N: usize = WORK.len();

fn fail(step: u64, value: u64) -> ! {
    exit((step << 8) | (value & 0xff))
}

fn fs(words: [u64; 4]) -> [u64; 4] {
    let answer = call(CAP_FS, words);
    if answer.status != 0 {
        fail(0xff, answer.status);
    }
    answer.words
}

fn disk(words: [u64; 4]) -> u64 {
    let answer = call(CAP_DISK, words);
    if answer.status != 0 {
        fail(0xfe, answer.status);
    }
    answer.words[0]
}

fn page_word(page: u64, index: u64) -> *mut u64 {
    (SHARED + page * FB_PAGE_SIZE + index * 8) as *mut u64
}

fn pattern(object: usize, slot: u64, version: u64, index: u64) -> u64 {
    ((b'a' as u64 + object as u64) << 48) | (slot << 40) | (version << 32) | index
}

fn fill(page: u64, object: usize, slot: u64, version: u64) {
    for index in 0..WORDS {
        unsafe { write_volatile(page_word(page, index), pattern(object, slot, version, index)) };
    }
}

// ---------------------------------------------------------------------------
// El modelo: lo que debe haber tras las j primeras operaciones.

const FILES: usize = FB_FS_FILES as usize;

#[derive(Clone, Copy)]
struct Object {
    exists: bool,
    dir: bool,
    parent: u64,
    name: u8,
    length: u64,
    versions: [u64; SLOTS],
    /// Su número: el de ahora si existe, el último si se borró, 0 si nunca
    /// se creó.
    number: u64,
}

struct State {
    formatted: bool,
    objects: [Object; OBJECTS],
    used: [bool; FILES],
    gens: [u64; FILES],
}

const NOTHING: Object = Object { exists: false, dir: false, parent: ROOT, name: 0, length: 0, versions: [0; SLOTS], number: 0 };

fn entry_of(number: u64) -> usize {
    (number & ((1 << FB_FS_HANDLE_SHIFT) - 1)) as usize
}

fn model(j: usize) -> State {
    let mut state = State { formatted: false, objects: [NOTHING; OBJECTS], used: [false; FILES], gens: [0; FILES] };
    for op in WORK.iter().take(j) {
        let [kind, object, first, second, third] = *op;
        match kind {
            FORMAT => {
                // Desde un disco sin formato: todas las generaciones en 0.
                state.formatted = true;
                state.objects = [NOTHING; OBJECTS];
                state.used = [false; FILES];
                state.gens = [0; FILES];
            }
            CREATE | MKDIR => {
                // La primera entrada libre, con la generación que tenga.
                let free = state.used.iter().position(|used| !used).unwrap_or(0);
                state.used[free] = true;
                let number = state.gens[free] << FB_FS_HANDLE_SHIFT | free as u64;
                state.objects[object as usize] =
                    Object { exists: true, dir: kind == MKDIR, parent: first, name: second as u8, number, ..NOTHING }
            }
            DELETE => {
                let entry = &mut state.objects[object as usize];
                let free = entry_of(entry.number);
                state.used[free] = false;
                state.gens[free] += 1;
                entry.exists = false;
            }
            _ => {}
        }
        let entry = &mut state.objects[object as usize];
        match kind {
            WRITE => {
                entry.versions[first as usize] = third;
                entry.length = entry.length.max(first * FB_PAGE_SIZE + second);
            }
            RENAME => {
                entry.parent = first;
                entry.name = second as u8;
            }
            _ => {}
        }
    }
    state
}

/// La ruta de un objeto (o de ROOT, "/") en el modelo.
struct PathText {
    bytes: [u8; 16],
    length: usize,
}

fn path_of(state: &State, object: u64) -> PathText {
    let mut names = [0u8; OBJECTS];
    let mut depth = 0;
    let mut at = object;
    while at != ROOT {
        names[depth] = state.objects[at as usize].name;
        depth += 1;
        at = state.objects[at as usize].parent;
    }
    let mut path = PathText { bytes: [0u8; 16], length: 1 };
    path.bytes[0] = b'/';
    for level in (0..depth).rev() {
        path.bytes[path.length] = names[level];
        path.bytes[path.length + 1] = b'/';
        path.length += 2;
    }
    path
}

/// Pone una ruta en su página y devuelve su longitud.
fn put_path(path: &[u8]) -> u64 {
    let base = (SHARED + PATH_PAGE * FB_PAGE_SIZE) as *mut u8;
    for (index, byte) in path.iter().enumerate() {
        unsafe { write_volatile(base.add(index), *byte) };
    }
    path.len() as u64
}

fn lookup(path: &[u8]) -> [u64; 4] {
    let length = put_path(path);
    fs([FB_FS_OP_LOOKUP, PATH_PAGE, length, 0])
}

fn create(path: &[u8], kind: u64) -> [u64; 4] {
    let length = put_path(path);
    fs([FB_FS_OP_CREATE, PATH_PAGE, length, kind])
}

/// La ruta del directorio `parent` seguida de `name`.
fn child_path(state: &State, parent: u64, name: u8) -> PathText {
    let mut path = path_of(state, parent);
    path.bytes[path.length] = name;
    path.length += 1;
    path
}

fn blocks_of(length: u64) -> u64 {
    length.div_ceil(FB_PAGE_SIZE)
}

/// ¿Está el disco, visto por el servidor, en S_j? Devuelve 0 si sí; si no,
/// en qué comprobación no cuadra. Abre un manejador por objeto; al empezar
/// cierra todos los de la vez anterior (DETACH).
fn matches(j: usize) -> u64 {
    let state = model(j);
    if fs([FB_FS_OP_DETACH, 0, 0, 0])[0] != FB_FS_OK {
        return 11;
    }
    let free = fs([FB_FS_OP_FREE, 0, 0, 0]);
    if !state.formatted {
        return if free[0] == FB_FS_ERR_UNFORMATTED { 0 } else { 1 };
    }
    if free[0] != FB_FS_OK {
        return 2;
    }
    let mut used = 0;
    // Manejador de cada objeto, y cuántos hijos tiene cada directorio.
    let mut handles = [FB_FS_FILES; OBJECTS];
    let mut children = [0u64; OBJECTS + 1];
    for (object, item) in state.objects.iter().enumerate() {
        if !item.exists {
            continue;
        }
        let parent = if item.parent == ROOT { OBJECTS } else { item.parent as usize };
        children[parent] += 1;
        used += blocks_of(item.length);
        let path = path_of(&state, object as u64);
        let found = lookup(&path.bytes[..path.length]);
        let kind = if item.dir { FB_FS_KIND_DIR } else { FB_FS_KIND_FILE };
        if found[0] != FB_FS_OK || found[2] != item.length || found[3] != kind {
            return 3;
        }
        handles[object] = found[1];
        let info = fs([FB_FS_OP_STAT, found[1], 0, 0]);
        if info[0] != FB_FS_OK || info[1] != item.number {
            return 9;
        }
        for slot in 0..blocks_of(item.length) {
            let answer = fs([FB_FS_OP_READ, found[1], slot, 1]);
            let bytes = (item.length - slot * FB_PAGE_SIZE).min(FB_PAGE_SIZE);
            if answer[0] != FB_FS_OK || answer[1] != bytes {
                return 4;
            }
            let version = item.versions[slot as usize];
            for index in 0..bytes / 8 {
                if unsafe { read_volatile(page_word(1, index)) } != pattern(object, slot, version, index) {
                    return 5;
                }
            }
        }
    }
    if free[1] != FB_FS_BLOCKS - FB_FS_FIRST_DATA - used {
        return 6;
    }
    // Y nada más: cada directorio tiene justo los hijos del modelo.
    for (index, expected) in children.iter().enumerate() {
        let dir = if index == OBJECTS { FB_FS_ROOT } else { handles[index] };
        // Solo los directorios que existen: listar un archivo es un error.
        if dir == FB_FS_FILES || (index < OBJECTS && !state.objects[index].dir) {
            continue;
        }
        let mut listed = 0;
        let mut from = 0;
        loop {
            let next = fs([FB_FS_OP_LIST, dir, from, 2]);
            if next[0] != FB_FS_OK {
                return 7;
            }
            // El final es FB_FS_FILES justo: un número con generación puede
            // ser mayor.
            if next[1] == FB_FS_FILES {
                break;
            }
            listed += 1;
            from = entry_of(next[1]) as u64 + 1;
        }
        if listed != *expected {
            return 8;
        }
    }
    0
}

// ---------------------------------------------------------------------------
// Los modos.

/// Basura en el superbloque y la tabla, escrita directamente con el driver:
/// el disco queda sin formato (S_0).
fn junk() {
    for index in 0..WORDS {
        unsafe { write_volatile(page_word(0, index), 0x6a75_6e6b_0000_0000 | index) };
    }
    for block in 0..FB_FS_FIRST_DATA {
        let sector = FB_FS_FIRST_SECTOR + block * FB_DISK_SECTORS_PER_PAGE;
        let status = disk([FB_DISK_OP_WRITE, sector, FB_FS_META_PAGES, 0]);
        if status != FB_DISK_OK {
            fail(0xf0, status);
        }
    }
}

/// Ejecuta la carga hasta la primera operación que falla, con un servidor
/// que encontró el disco sin formato (tras JUNK).
fn run(tear: u64, sectors: u64) -> u64 {
    if disk([FB_DISK_OP_CUT, sectors, tear, 0]) != FB_DISK_OK {
        fail(0xf1, 0);
    }
    let mut ids = [0u64; OBJECTS];
    for (index, op) in WORK.iter().enumerate() {
        let [kind, object, first, second, third] = *op;
        let id = ids[object as usize];
        // Las rutas, según el modelo justo antes de esta operación.
        let state = model(index);
        let status = match kind {
            FORMAT => fs([FB_FS_OP_FORMAT, 0, 0, 0])[0],
            CREATE | MKDIR => {
                let path = child_path(&state, first, second as u8);
                let made = if kind == MKDIR { FB_FS_KIND_DIR } else { FB_FS_KIND_FILE };
                let answer = create(&path.bytes[..path.length], made);
                ids[object as usize] = answer[1];
                // Lo creado tiene el número que dice el modelo.
                if answer[0] == FB_FS_OK {
                    let info = fs([FB_FS_OP_STAT, answer[1], 0, 0]);
                    if info[0] != FB_FS_OK || info[1] != model(index + 1).objects[object as usize].number {
                        fail(0x40 + index as u64, info[1]);
                    }
                }
                answer[0]
            }
            WRITE => {
                fill(0, object as usize, first, third);
                fs([FB_FS_OP_WRITE, id, first | (second << 32), 0])[0]
            }
            RENAME => {
                let path = child_path(&state, first, second as u8);
                let length = put_path(&path.bytes[..path.length]);
                fs([FB_FS_OP_RENAME, id, PATH_PAGE, length])[0]
            }
            _ => fs([FB_FS_OP_DELETE, id, 0, 0])[0],
        };
        if status != FB_FS_OK {
            // Sin luz, todo falla con error de disco; otra cosa es un fallo.
            if status != FB_FS_ERR_IO {
                fail(0x10 + index as u64, status);
            }
            return index as u64;
        }
    }
    N as u64
}

fn stop_server(driver_too: bool) {
    if fs([FB_FS_OP_STOP, driver_too as u64, 0, 0])[0] != FB_FS_OK {
        fail(0xfd, 0);
    }
}

fn transient() {
    if fs([FB_FS_OP_FORMAT, 0, 0, 0])[0] != FB_FS_OK {
        fail(1, 0);
    }
    let created = create(b"a", FB_FS_KIND_FILE);
    fill(0, 0, 0, 1);
    if created[0] != FB_FS_OK || fs([FB_FS_OP_WRITE, created[1], 4096 << 32, 0])[0] != FB_FS_OK {
        fail(2, 0);
    }
    // Falla la escritura de la tabla al borrar; después vuelve la luz.
    disk([FB_DISK_OP_CUT, 0, FB_DISK_TEAR_FIRST, 0]);
    let status = fs([FB_FS_OP_DELETE, created[1], 0, 0])[0];
    if status != FB_FS_ERR_IO {
        fail(3, status);
    }
    disk([FB_DISK_OP_POWER, 0, 0, 0]);
    // La tabla de memoria ya no es la del disco: no atiende nada más.
    for (step, request) in [
        (4, [FB_FS_OP_CREATE, PATH_PAGE, put_path(b"b"), FB_FS_KIND_FILE]),
        (5, [FB_FS_OP_FREE, 0, 0, 0]),
        (6, [FB_FS_OP_LOOKUP, PATH_PAGE, put_path(b"a"), 0]),
    ] {
        let status = fs(request)[0];
        if status != FB_FS_ERR_IO {
            fail(step, status);
        }
    }
}

#[no_mangle]
#[link_section = ".text.entry"]
pub extern "C" fn _start(argument: u64) -> ! {
    if region_map(CAP_DATA, SHARED) != 0 {
        fail(0xfc, 0);
    }
    match argument & 0xff {
        JUNK => {
            junk();
            stop_server(false);
            exit(0)
        }
        RUN => {
            let failed_at = run((argument >> 8) & 0xff, argument >> 16);
            stop_server(false);
            if disk([FB_DISK_OP_POWER, 0, 0, 0]) != FB_DISK_OK {
                fail(0xf2, 0);
            }
            exit(RESULT | failed_at)
        }
        CHECK => {
            let failed_at = (argument >> 8) as usize;
            if failed_at > N {
                fail(0xf3, 0);
            }
            let mut found = None;
            for j in failed_at..=(failed_at + 1).min(N) {
                if matches(j) == 0 {
                    found = Some(j);
                    break;
                }
            }
            let Some(state) = found else {
                // Lo que no cuadra con S_f, para el diagnóstico.
                fail(0x20 + failed_at as u64, matches(failed_at));
            };
            // El siguiente servidor encontrará el disco sin formato.
            junk();
            stop_server(false);
            exit(RESULT | state as u64)
        }
        CHECK_ANY => {
            let Some(state) = (0..=N).find(|&j| matches(j) == 0) else {
                // El estado que más se parece: el que falla en la
                // comprobación más tardía.
                let best = (0..=N).max_by_key(|&j| matches(j)).unwrap_or(0);
                fail(0x30 + best as u64, matches(best));
            };
            stop_server(true);
            exit(RESULT | state as u64)
        }
        TRANSIENT => {
            transient();
            stop_server(false);
            exit(0)
        }
        AFTER_TRANSIENT => {
            // El archivo que no se llegó a borrar sigue ahí, con sus datos.
            let found = lookup(b"a");
            if found[0] != FB_FS_OK || found[2] != FB_PAGE_SIZE {
                fail(1, found[0]);
            }
            if fs([FB_FS_OP_READ, found[1], 0, 1])[0] != FB_FS_OK {
                fail(2, 0);
            }
            for index in 0..WORDS {
                if unsafe { read_volatile(page_word(1, index)) } != pattern(0, 0, 1, index) {
                    fail(3, index);
                }
            }
            if lookup(b"b")[0] != FB_FS_ERR_NOT_FOUND {
                fail(4, 0);
            }
            stop_server(true);
            exit(0)
        }
        _ => fail(0xfb, argument),
    }
}

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    exit(0xfa)
}
