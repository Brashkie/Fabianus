// SPDX-License-Identifier: GPL-3.0-or-later
//! Cliente de prueba del servidor de archivos (Hito 35; directorios, Hito 37;
//! generaciones, Hito 38; manejadores por cliente, Hito 39).
//!
//! Hueco 0: endpoint del servidor, con Send y la marca del cliente A. Hueco
//! 1: la región de datos que comparte con el servidor y el driver (4
//! páginas), que mapea en FB_USER_SHARED_BASE. Huecos 2, 4, 5 y 6: el mismo
//! endpoint con las marcas de otros cuatro clientes (B, C, D y E); hueco 3:
//! el mismo endpoint sin marca. Con ellos un solo proceso hace de varios
//! clientes: el servidor solo distingue marcas.
//!
//! Argumento 1: el disco aún no tiene sistema de archivos. Lo formatea y
//! prueba crear, escribir, leer, listar, borrar, los directorios, renombrar,
//! las generaciones, los manejadores de cada cliente y los límites; deja el
//! archivo "hello" con datos y, lo último, crea el archivo vacío "empty".
//! Para el servidor.
//! Argumento 2: con un servidor nuevo sobre el mismo disco, comprueba que
//! ningún manejador sigue abierto, que "hello" y "empty" siguen ahí, borra
//! "empty" y para el servidor.
//! Argumento 3: con otro servidor nuevo, comprueba que "empty" ya no está y
//! "hello" sí; lo último, amplía el segundo bloque de "hello" a 200 bytes. Para
//! el servidor.
//! Argumento 4: con un cuarto servidor, comprueba la ampliación; después
//! formatea y comprueba que el manejador abierto de "hello" contesta que
//! caducó. Para el servidor y el driver.
//! Argumento 0x10 | operación << 8 | vueltas << 16: medida (benchmark.zig).
//! Formatea, prepara el archivo "bench" con un bloque y repite la operación;
//! sale con lo que tardó (ver `bench`) y para el servidor y el driver.
//!
//! Sale con 0 si todo fue bien; si no, con el paso en los bits 8 y
//! siguientes y el estado recibido en los 8 bits bajos.

#![no_std]
#![no_main]

use core::arch::asm;
use core::panic::PanicInfo;
use core::ptr::{read_volatile, write_volatile};
use fb_abi::*;
use fb_user::*;

const CAP_FS: u64 = 0;
const CAP_DATA: u64 = 1;
const CAP_B: u64 = 2;
const CAP_PLAIN: u64 = 3;
const CAP_C: u64 = 4;
const CAP_D: u64 = 5;
const CAP_E: u64 = 6;
const SHARED: u64 = FB_USER_SHARED_BASE;
const PAGES: u64 = 4;
const WORDS: u64 = FB_PAGE_SIZE / 8;

const HELLO_LENGTH: u64 = 4096 + 100;
/// Las rutas van en la última página de la región.
const PATH_PAGE: u64 = PAGES - 1;

fn fail(step: u64, status: u64) -> ! {
    exit((step << 8) | (status & 0xff))
}

/// Una petición como el cliente de la capability `cap`.
fn fs_as(cap: u64, words: [u64; 4]) -> [u64; 4] {
    let answer = call(cap, words);
    if answer.status != 0 {
        fail(0xff, answer.status);
    }
    answer.words
}

/// Una petición como el cliente A.
fn fs(words: [u64; 4]) -> [u64; 4] {
    fs_as(CAP_FS, words)
}

/// Pone una ruta en su página y devuelve su longitud.
fn put_path(path: &[u8]) -> u64 {
    let base = (SHARED + PATH_PAGE * FB_PAGE_SIZE) as *mut u8;
    for (index, byte) in path.iter().enumerate() {
        unsafe { write_volatile(base.add(index), *byte) };
    }
    path.len() as u64
}

fn numbered(prefix: u8, number: u64) -> [u8; 3] {
    [prefix, b'0' + (number / 10) as u8, b'0' + (number % 10) as u8]
}

/// Los primeros 8 bytes de un nombre rellenado con ceros, como palabra.
fn first_word(text: &[u8]) -> u64 {
    let mut bytes = [0u8; 8];
    let count = text.len().min(8);
    bytes[..count].copy_from_slice(&text[..count]);
    u64::from_le_bytes(bytes)
}

/// La entrada de un número (lo que dan STAT y LIST): desde dónde seguir
/// listando.
fn entry_of(number: u64) -> u64 {
    number & ((1 << FB_FS_HANDLE_SHIFT) - 1)
}

fn expect(step: u64, answer: [u64; 4], status: u64) -> [u64; 4] {
    if answer[0] != status {
        fail(step, answer[0]);
    }
    answer
}

/// Crea y devuelve el manejador abierto (0 si no se creó).
fn create_kind(step: u64, path: &[u8], kind: u64, status: u64) -> u64 {
    let length = put_path(path);
    expect(step, fs([FB_FS_OP_CREATE, PATH_PAGE, length, kind]), status)[1]
}

fn create(step: u64, path: &[u8], status: u64) -> u64 {
    create_kind(step, path, FB_FS_KIND_FILE, status)
}

fn mkdir(step: u64, path: &[u8], status: u64) -> u64 {
    create_kind(step, path, FB_FS_KIND_DIR, status)
}

/// Crea sin quedarse el manejador.
fn create_closed(step: u64, path: &[u8], status: u64) {
    let handle = create(step, path, status);
    if status == FB_FS_OK {
        close_ok(step, handle);
    }
}

fn lookup_as(cap: u64, path: &[u8]) -> [u64; 4] {
    let length = put_path(path);
    fs_as(cap, [FB_FS_OP_LOOKUP, PATH_PAGE, length, 0])
}

/// Abre un manejador (si la ruta existe).
fn lookup(path: &[u8]) -> [u64; 4] {
    lookup_as(CAP_FS, path)
}

fn stat(handle: u64) -> [u64; 4] {
    fs([FB_FS_OP_STAT, handle, 0, 0])
}

/// El número de lo que nombra un manejador.
fn number(step: u64, handle: u64) -> u64 {
    expect(step, stat(handle), FB_FS_OK)[1]
}

fn close(handle: u64) -> u64 {
    fs([FB_FS_OP_CLOSE, handle, 0, 0])[0]
}

fn close_ok(step: u64, handle: u64) {
    let status = close(handle);
    if status != FB_FS_OK {
        fail(step, status);
    }
}

/// Como LOOKUP sin dejar nada abierto: el número, la longitud y el tipo.
fn number_of(path: &[u8]) -> [u64; 4] {
    let found = lookup(path);
    if found[0] != FB_FS_OK || found[1] == FB_FS_ROOT {
        return found;
    }
    let info = stat(found[1]);
    close_ok(0xfa, found[1]);
    info
}

fn rename(handle: u64, path: &[u8]) -> u64 {
    let length = put_path(path);
    fs([FB_FS_OP_RENAME, handle, PATH_PAGE, length])[0]
}

fn delete(handle: u64) -> u64 {
    fs([FB_FS_OP_DELETE, handle, 0, 0])[0]
}

/// Borra y cierra.
fn remove(step: u64, handle: u64) {
    let status = delete(handle);
    if status != FB_FS_OK {
        fail(step, status);
    }
    close_ok(step, handle);
}

fn list(dir: u64, from: u64) -> [u64; 4] {
    fs([FB_FS_OP_LIST, dir, from, PATH_PAGE])
}

fn write(file: u64, slot: u64, bytes: u64, page: u64) -> u64 {
    fs([FB_FS_OP_WRITE, file, slot | (bytes << 32), page])[0]
}

fn read(file: u64, slot: u64, page: u64) -> [u64; 4] {
    fs([FB_FS_OP_READ, file, slot, page])
}

fn page_word(page: u64, index: u64) -> *mut u64 {
    (SHARED + page * FB_PAGE_SIZE + index * 8) as *mut u64
}

/// Llena una página con un patrón que depende de `tag`.
fn fill(page: u64, tag: u64) {
    for index in 0..WORDS {
        unsafe { write_volatile(page_word(page, index), (tag << 32) | index) };
    }
}

/// Comprueba los primeros `bytes` bytes (múltiplo de 4) de una página.
fn check(step: u64, page: u64, tag: u64, bytes: u64) {
    for index in 0..bytes / 8 {
        if unsafe { read_volatile(page_word(page, index)) } != (tag << 32) | index {
            fail(step, index);
        }
    }
    if bytes % 8 != 0 {
        let index = bytes / 8;
        let low = unsafe { read_volatile(page_word(page, index)) } & 0xffff_ffff;
        if low != index {
            fail(step, 0xee);
        }
    }
}

fn hello() -> &'static [u8] {
    b"hello"
}

/// Lo que deja la primera pasada: "hello" con 4096 + 100 bytes.
fn check_hello(step: u64) {
    check_hello_with(step, 100);
}

/// "hello": un bloque entero y `tail` bytes del segundo. Abre un manejador
/// y lo cierra.
fn check_hello_with(step: u64, tail: u64) {
    let found = expect(step, lookup(hello()), FB_FS_OK);
    if found[2] != 4096 + tail {
        fail(step + 1, found[2]);
    }
    let file = found[1];
    let first = expect(step + 2, read(file, 0, 2), FB_FS_OK);
    if first[1] != 4096 {
        fail(step + 3, first[1]);
    }
    check(step + 4, 2, 0xf500, 4096);
    let second = expect(step + 5, read(file, 1, 3), FB_FS_OK);
    if second[1] != tail {
        fail(step + 6, second[1]);
    }
    check(step + 7, 3, 0xf501, tail);
    close_ok(step + 7, file);
}

fn first_pass() {
    // Sin formatear: el disco tiene el patrón de mkdisk.
    expect(1, lookup(hello()), FB_FS_ERR_UNFORMATTED);
    expect(2, fs([FB_FS_OP_FORMAT, 0, 0, 0]), FB_FS_OK);
    let free = expect(3, fs([FB_FS_OP_FREE, 0, 0, 0]), FB_FS_OK)[1];
    if free != FB_FS_BLOCKS - FB_FS_FIRST_DATA {
        fail(4, free);
    }

    // Crear: el nombre no se repite y no puede estar vacío. El primer
    // manejador de un cliente es el 0.
    let file = create(5, hello(), FB_FS_OK);
    if file != 0 {
        fail(5, file);
    }
    if create(6, hello(), FB_FS_ERR_EXISTS) != 0 {
        fail(7, 0);
    }
    create(8, b"", FB_FS_ERR_REQUEST);

    // Escribir un bloque entero y 100 bytes del siguiente, y leerlos.
    fill(0, 0xf500);
    fill(1, 0xf501);
    if write(file, 0, 4096, 0) != FB_FS_OK {
        fail(9, 0);
    }
    if write(file, 1, 100, 1) != FB_FS_OK {
        fail(10, 0);
    }
    check_hello(11);

    // Límites: más allá del final, un hueco, una página que no hay, 0
    // bytes, manejadores que no están abiertos.
    expect(20, read(file, 2, 0), FB_FS_ERR_REQUEST);
    if write(file, 3, 10, 0) != FB_FS_ERR_REQUEST {
        fail(21, 0);
    }
    if write(file, 0, 10, PAGES) != FB_FS_ERR_REQUEST {
        fail(22, 0);
    }
    expect(23, read(file, 0, PAGES), FB_FS_ERR_REQUEST);
    if write(file, 0, 0, 0) != FB_FS_ERR_REQUEST {
        fail(24, 0);
    }
    if write(file, 0, 4097, 0) != FB_FS_ERR_REQUEST {
        fail(25, 0);
    }
    expect(26, read(FB_FS_MAX_OPEN - 1, 0, 0), FB_FS_ERR_BAD_HANDLE);
    expect(27, read(FB_FS_FILES, 0, 0), FB_FS_ERR_BAD_HANDLE);
    expect(28, lookup(b"nada"), FB_FS_ERR_NOT_FOUND);

    // Reescribir un bloque no cambia la longitud ni gasta bloques.
    let before = fs([FB_FS_OP_FREE, 0, 0, 0])[1];
    if write(file, 0, 4096, 0) != FB_FS_OK {
        fail(29, 0);
    }
    if fs([FB_FS_OP_FREE, 0, 0, 0])[1] != before || stat(file)[2] != HELLO_LENGTH {
        fail(30, 0);
    }

    // Un archivo de 16 bloques; el 17 no cabe.
    let big = create(31, b"big", FB_FS_OK);
    for slot in 0..FB_FS_FILE_BLOCKS {
        fill(0, 0xb000 + slot);
        if write(big, slot, 4096, 0) != FB_FS_OK {
            fail(32, slot);
        }
    }
    if write(big, FB_FS_FILE_BLOCKS, 4096, 0) != FB_FS_ERR_REQUEST {
        fail(33, 0);
    }
    expect(34, read(big, 9, 1), FB_FS_OK);
    check(35, 1, 0xb009, 4096);
    if fs([FB_FS_OP_FREE, 0, 0, 0])[1] != before - FB_FS_FILE_BLOCKS {
        fail(36, 0);
    }

    // Listar: los dos, en orden, con su nombre en la página. LIST da
    // números, los mismos que STAT.
    let (file_number, big_number) = (number(37, file), number(37, big));
    let listed = expect(37, list(FB_FS_ROOT, 0), FB_FS_OK);
    if listed[1] != file_number || listed[2] != HELLO_LENGTH || listed[3] != FB_FS_KIND_FILE {
        fail(38, listed[1]);
    }
    if unsafe { read_volatile(page_word(PATH_PAGE, 0)) } != first_word(hello()) {
        fail(39, 0);
    }
    let listed = list(FB_FS_ROOT, entry_of(file_number) + 1);
    if listed[1] != big_number || listed[2] != FB_FS_FILE_BLOCKS * 4096 {
        fail(40, listed[1]);
    }
    if list(FB_FS_ROOT, entry_of(big_number) + 1)[1] != FB_FS_FILES {
        fail(41, 0);
    }

    // Borrar devuelve sus bloques; el nombre deja de existir. El manejador
    // sigue abierto, caducado, hasta que se cierra.
    if delete(big) != FB_FS_OK {
        fail(42, 0);
    }
    if fs([FB_FS_OP_FREE, 0, 0, 0])[1] != before {
        fail(43, 0);
    }
    expect(44, lookup(b"big"), FB_FS_ERR_NOT_FOUND);
    if delete(big) != FB_FS_ERR_STALE {
        fail(45, 0);
    }
    expect(45, stat(big), FB_FS_ERR_STALE);
    close_ok(45, big);
    if close(big) != FB_FS_ERR_BAD_HANDLE || close(FB_FS_ROOT) != FB_FS_ERR_BAD_HANDLE {
        fail(45, 1);
    }

    // La tabla se llena: 64 archivos en total.
    for number in 0..FB_FS_FILES - 1 {
        create_closed(46, &numbered(b'f', number), FB_FS_OK);
    }
    create(47, b"extra", FB_FS_ERR_FULL);
    mkdir(47, b"extra", FB_FS_ERR_FULL);
    for number in 0..FB_FS_FILES - 1 {
        let found = expect(48, lookup(&numbered(b'f', number)), FB_FS_OK);
        remove(49, found[1]);
    }

    // El disco se llena: archivos de 16 bloques hasta que no quede ninguno.
    fill(0, 0xd000);
    let mut written = 0u64;
    let mut number = 0u64;
    'files: loop {
        let full = create(50, &numbered(b'd', number), FB_FS_OK);
        for slot in 0..FB_FS_FILE_BLOCKS {
            match write(full, slot, 4096, 0) {
                FB_FS_OK => written += 1,
                FB_FS_ERR_FULL => {
                    close_ok(50, full);
                    break 'files;
                }
                other => fail(51, other),
            }
        }
        close_ok(50, full);
        number += 1;
    }
    if written != before || fs([FB_FS_OP_FREE, 0, 0, 0])[1] != 0 {
        fail(52, written);
    }
    // Reescribir necesita un bloque libre (copia al escribir): con el disco
    // lleno no se puede, y "hello" no cambia (lo mira check_hello abajo).
    if write(file, 0, 4096, 0) != FB_FS_ERR_FULL {
        fail(57, 0);
    }
    for index in 0..=number {
        let found = expect(53, lookup(&numbered(b'd', index)), FB_FS_OK);
        remove(54, found[1]);
    }
    if fs([FB_FS_OP_FREE, 0, 0, 0])[1] != before {
        fail(55, 0);
    }
    // "hello" no se ha movido.
    check_hello(56);
    directories(file, before);
    generations(file, before);
    clients(file, before);
    // Lo último: un archivo vacío. Solo llega al disco si crear escribe la tabla.
    create_closed(66, b"empty", FB_FS_OK);
}

/// Directorios y renombrar (Hito 37). Lo deja todo como estaba: solo
/// "hello" y `free` bloques libres, y abierto solo `hello_file`.
fn directories(hello_file: u64, free: u64) {
    // La raíz es un directorio sin entrada propia.
    let root = expect(70, lookup(b"/"), FB_FS_OK);
    if root[1] != FB_FS_ROOT || root[3] != FB_FS_KIND_DIR {
        fail(71, root[1]);
    }
    if number(71, FB_FS_ROOT) != FB_FS_ROOT {
        fail(71, 1);
    }
    let docs = mkdir(72, b"docs", FB_FS_OK);
    mkdir(73, b"docs", FB_FS_ERR_EXISTS);
    create(73, b"/docs", FB_FS_ERR_EXISTS);
    let found = expect(74, number_of(b"//docs/"), FB_FS_OK);
    if found[1] != number(74, docs) || found[2] != 0 || found[3] != FB_FS_KIND_DIR {
        fail(75, found[1]);
    }
    // Un archivo dentro; el mismo nombre en otro directorio es otro archivo.
    let note = create(76, b"docs/note", FB_FS_OK);
    create(77, b"docs/note", FB_FS_ERR_EXISTS);
    expect(78, lookup(b"note"), FB_FS_ERR_NOT_FOUND);
    let top_note = create(79, b"note", FB_FS_OK);
    let note_number = number(79, note);
    if number(80, top_note) == note_number || expect(80, number_of(b"docs/note"), FB_FS_OK)[1] != note_number {
        fail(80, top_note);
    }
    remove(81, top_note);
    fill(0, 0xd0c0);
    if write(note, 0, 4096, 0) != FB_FS_OK {
        fail(82, 0);
    }
    // Errores de ruta: un archivo en medio, un directorio que no existe,
    // nombres que no valen, rutas vacías o demasiado largas.
    create(83, b"hello/x", FB_FS_ERR_NOT_DIR);
    expect(84, lookup(b"hello/x"), FB_FS_ERR_NOT_DIR);
    create(85, b"nada/x", FB_FS_ERR_NOT_FOUND);
    create(86, b"docs/./x", FB_FS_ERR_REQUEST);
    create(86, b"docs/..", FB_FS_ERR_REQUEST);
    create(87, b"a234567890123456789012345", FB_FS_ERR_REQUEST);
    create(87, b"/", FB_FS_ERR_REQUEST);
    create_kind(88, b"docs/y", 7, FB_FS_ERR_REQUEST);
    expect(89, fs([FB_FS_OP_LOOKUP, PATH_PAGE, 0, 0]), FB_FS_ERR_REQUEST);
    expect(89, fs([FB_FS_OP_LOOKUP, PATH_PAGE, FB_FS_PATH_BYTES + 1, 0]), FB_FS_ERR_REQUEST);
    expect(89, fs([FB_FS_OP_LOOKUP, PAGES, 4, 0]), FB_FS_ERR_REQUEST);
    // Un directorio no se lee ni se escribe.
    if write(docs, 0, 10, 0) != FB_FS_ERR_IS_DIR {
        fail(90, 0);
    }
    expect(91, read(docs, 0, 0), FB_FS_ERR_IS_DIR);

    // Subdirectorios y listar un directorio.
    let sub = mkdir(92, b"docs/sub", FB_FS_OK);
    let deep = mkdir(93, b"docs/sub/deep", FB_FS_OK);
    let (sub_number, deep_number) = (number(93, sub), number(93, deep));
    let first = expect(94, list(docs, 0), FB_FS_OK);
    let second = list(docs, entry_of(first[1]) + 1);
    let (low, high) =
        if entry_of(note_number) < entry_of(sub_number) { (note_number, sub_number) } else { (sub_number, note_number) };
    if (first[1], second[1]) != (low, high) {
        fail(95, first[1]);
    }
    if list(docs, entry_of(second[1]) + 1)[1] != FB_FS_FILES || list(deep, 0)[1] != FB_FS_FILES {
        fail(96, 0);
    }
    let listed = list(sub, 0);
    if listed[1] != deep_number || listed[3] != FB_FS_KIND_DIR
        || unsafe { read_volatile(page_word(PATH_PAGE, 0)) } != first_word(b"deep")
    {
        fail(97, listed[1]);
    }
    // Un directorio con algo dentro no se borra.
    if delete(docs) != FB_FS_ERR_NOT_EMPTY || delete(sub) != FB_FS_ERR_NOT_EMPTY {
        fail(98, 0);
    }

    // Renombrar a otro directorio: la misma entrada, con sus datos.
    if rename(note, b"docs/sub/note2") != FB_FS_OK {
        fail(100, 0);
    }
    expect(101, lookup(b"docs/note"), FB_FS_ERR_NOT_FOUND);
    let moved = expect(102, number_of(b"docs/sub/note2"), FB_FS_OK);
    if moved[1] != note_number || moved[2] != 4096 {
        fail(103, moved[1]);
    }
    expect(104, read(note, 0, 1), FB_FS_OK);
    check(105, 1, 0xd0c0, 4096);
    // No sustituye a otra entrada; a sí misma sí (no cambia nada).
    if rename(note, b"hello") != FB_FS_ERR_EXISTS || rename(note, b"docs/sub/deep") != FB_FS_ERR_EXISTS {
        fail(106, 0);
    }
    if rename(note, b"docs/sub/note2") != FB_FS_OK {
        fail(107, 0);
    }
    // Un directorio no puede ir dentro de sí mismo ni de un descendiente.
    if rename(docs, b"docs/x") != FB_FS_ERR_REQUEST
        || rename(docs, b"docs/sub/deep/x") != FB_FS_ERR_REQUEST
        || rename(sub, b"docs/sub/deep/sub") != FB_FS_ERR_REQUEST
    {
        fail(108, 0);
    }
    expect(109, number_of(b"docs/sub/deep"), FB_FS_OK);
    // Errores de ruta y de manejador al renombrar. La raíz no se renombra.
    if rename(note, b"hello/x") != FB_FS_ERR_NOT_DIR
        || rename(note, b"nada/x") != FB_FS_ERR_NOT_FOUND
        || rename(note, b"/") != FB_FS_ERR_REQUEST
        || rename(note, b"docs/..") != FB_FS_ERR_REQUEST
        || rename(FB_FS_MAX_OPEN, b"x") != FB_FS_ERR_BAD_HANDLE
        || rename(FB_FS_MAX_OPEN - 1, b"x") != FB_FS_ERR_BAD_HANDLE
        || rename(FB_FS_ROOT, b"x") != FB_FS_ERR_REQUEST
    {
        fail(110, 0);
    }
    // Mover un directorio mueve todo lo que tiene dentro.
    if rename(sub, b"moved") != FB_FS_OK {
        fail(111, 0);
    }
    expect(112, lookup(b"docs/sub"), FB_FS_ERR_NOT_FOUND);
    if expect(113, number_of(b"moved/deep"), FB_FS_OK)[1] != deep_number
        || expect(114, number_of(b"moved/note2"), FB_FS_OK)[1] != note_number
    {
        fail(115, 0);
    }
    // Y de vuelta, más hondo: docs/moved.
    if rename(sub, b"docs/moved") != FB_FS_OK
        || expect(116, number_of(b"docs/moved/deep"), FB_FS_OK)[1] != deep_number
    {
        fail(117, 0);
    }

    // Una cadena de 30 directorios: el de arriba no puede ir dentro del de
    // abajo, y el de abajo sí puede subir a la raíz. Solo quedan abiertos
    // el de arriba y el de abajo.
    let mut path = [0u8; 64];
    let mut chain = [0u64; 30];
    let (mut top, mut bottom) = (0u64, 0u64);
    for level in 0..30 {
        path[level * 2] = b'c';
        let handle = mkdir(118, &path[..level * 2 + 1], FB_FS_OK);
        chain[level] = number(118, handle);
        match level {
            0 => top = handle,
            29 => bottom = handle,
            _ => close_ok(118, handle),
        }
        path[level * 2 + 1] = b'/';
    }
    path[60] = b'x';
    if rename(top, &path[..61]) != FB_FS_ERR_REQUEST {
        fail(119, 0);
    }
    if rename(bottom, b"bottom") != FB_FS_OK || expect(120, number_of(b"bottom"), FB_FS_OK)[1] != chain[29] {
        fail(121, 0);
    }
    if rename(top, b"bottom/top") != FB_FS_OK
        || expect(122, lookup(&path[..57]), FB_FS_ERR_NOT_FOUND)[0] != FB_FS_ERR_NOT_FOUND
    {
        fail(123, 0);
    }
    // bottom/top/c/c/.../c: 29 niveles bajo "bottom".
    let mut deep_path = [0u8; 80];
    deep_path[..10].copy_from_slice(b"bottom/top");
    for level in 1..29 {
        deep_path[10 + (level - 1) * 2..10 + level * 2].copy_from_slice(b"/c");
    }
    if expect(124, number_of(&deep_path[..66]), FB_FS_OK)[1] != chain[28] {
        fail(125, 0);
    }
    // Borrar la cadena de abajo arriba, buscando cada uno por su ruta.
    for level in (1..29).rev() {
        let found = expect(126, lookup(&deep_path[..10 + level * 2]), FB_FS_OK);
        if number(126, found[1]) != chain[level] {
            fail(126, level as u64);
        }
        remove(126, found[1]);
    }
    remove(127, top);
    remove(127, bottom);

    // Todo fuera: de dentro afuera.
    for handle in [note, deep, sub, docs] {
        remove(128, handle);
    }
    let hello_number = number(129, hello_file);
    if fs([FB_FS_OP_FREE, 0, 0, 0])[1] != free || list(FB_FS_ROOT, 0)[1] != hello_number
        || list(FB_FS_ROOT, entry_of(hello_number) + 1)[1] != FB_FS_FILES
    {
        fail(129, 0);
    }
}

/// Generaciones (Hito 38). Lo deja todo como estaba: solo "hello" y `free`
/// bloques libres, y abierto solo `hello_file`.
fn generations(hello_file: u64, free: u64) {
    // Un archivo con datos, borrado: su entrada la ocupa otro, con otra
    // generación. El manejador del borrado sigue abierto.
    let old = create(130, b"h1", FB_FS_OK);
    let old_number = number(130, old);
    fill(0, 0x4100);
    if write(old, 0, 4096, 0) != FB_FS_OK || delete(old) != FB_FS_OK {
        fail(131, 0);
    }
    let new = create(132, b"h2", FB_FS_OK);
    let new_number = number(132, new);
    if entry_of(new_number) != entry_of(old_number)
        || new_number >> FB_FS_HANDLE_SHIFT != (old_number >> FB_FS_HANDLE_SHIFT) + 1
        || new == old
    {
        fail(133, new_number);
    }
    fill(1, 0x4200);
    if write(new, 0, 100, 1) != FB_FS_OK {
        fail(134, 0);
    }
    // El manejador viejo no vale para nada, ni lee los datos del nuevo.
    expect(135, read(old, 0, 2), FB_FS_ERR_STALE);
    if write(old, 0, 10, 0) != FB_FS_ERR_STALE
        || delete(old) != FB_FS_ERR_STALE
        || rename(old, b"h9") != FB_FS_ERR_STALE
    {
        fail(136, 0);
    }
    expect(137, list(old, 0), FB_FS_ERR_STALE);
    expect(137, stat(old), FB_FS_ERR_STALE);
    // Un número no es un manejador: el del archivo nuevo, o cualquier otro
    // que no esté abierto, no vale.
    expect(138, read(new_number, 0, 2), FB_FS_ERR_BAD_HANDLE);
    expect(138, read(new | 1 << FB_FS_HANDLE_SHIFT, 0, 2), FB_FS_ERR_BAD_HANDLE);
    expect(138, read(new | 1 << 50, 0, 2), FB_FS_ERR_BAD_HANDLE);
    // El nuevo sigue intacto, con sus 100 bytes.
    if expect(139, read(new, 0, 2), FB_FS_OK)[1] != 100 {
        fail(139, 0);
    }
    check(140, 2, 0x4200, 100);
    close_ok(140, old);

    // Renombrar no cambia el manejador ni el número, ni siquiera de
    // directorio.
    let dir = mkdir(141, b"hd", FB_FS_OK);
    let dir_number = number(141, dir);
    if rename(new, b"hd/h3") != FB_FS_OK || expect(142, number_of(b"hd/h3"), FB_FS_OK)[1] != new_number {
        fail(143, 0);
    }
    expect(144, read(new, 0, 2), FB_FS_OK);
    // Listar da números; con un archivo, no es un directorio.
    if expect(145, list(dir, 0), FB_FS_OK)[1] != new_number {
        fail(146, 0);
    }
    expect(147, list(new, 0), FB_FS_ERR_NOT_DIR);
    expect(148, list(FB_FS_ROOT | 1 << FB_FS_HANDLE_SHIFT, 0), FB_FS_ERR_BAD_HANDLE);
    expect(148, list(FB_FS_FILES, 0), FB_FS_ERR_BAD_HANDLE);
    // Un directorio borrado: su manejador no lista, aunque otro ocupe su
    // entrada (la primera libre).
    if rename(new, b"h2") != FB_FS_OK || delete(dir) != FB_FS_OK {
        fail(149, 0);
    }
    let other = mkdir(150, b"hd2", FB_FS_OK);
    expect(151, list(dir, 0), FB_FS_ERR_STALE);
    if entry_of(number(152, other)) != entry_of(dir_number) {
        fail(152, other);
    }
    close_ok(152, dir);
    remove(152, other);
    remove(152, new);

    // Nombres: 20 bytes, no más.
    create_closed(153, b"a2345678901234567890", FB_FS_OK);
    create(154, b"a23456789012345678901", FB_FS_ERR_REQUEST);
    let longest = expect(155, lookup(b"a2345678901234567890"), FB_FS_OK)[1];
    remove(155, longest);
    let hello_number = number(156, hello_file);
    if fs([FB_FS_OP_FREE, 0, 0, 0])[1] != free || list(FB_FS_ROOT, 0)[1] != hello_number
        || list(FB_FS_ROOT, entry_of(hello_number) + 1)[1] != FB_FS_FILES
    {
        fail(156, 0);
    }
}

/// Manejadores por cliente (Hito 39): el servidor solo sabe de cada cliente
/// su marca, y cada marca tiene sus manejadores. Lo deja todo como estaba:
/// solo "hello" y `free` bloques libres, abierto solo `hello_file` en A y
/// ningún otro cliente.
fn clients(hello_file: u64, free: u64) {
    let hello_number = number(160, hello_file);
    // A abre "hello" otra vez: otro manejador, el mismo archivo.
    let a_hello = expect(161, lookup(hello()), FB_FS_OK)[1];
    if a_hello == hello_file || number(161, a_hello) != hello_number {
        fail(162, a_hello);
    }
    // B no tiene nada abierto: ni los manejadores de A ni ningún otro le
    // valen, para nada.
    for handle in [hello_file, a_hello, FB_FS_MAX_OPEN - 1, FB_FS_MAX_OPEN, 1 << 40] {
        expect(163, fs_as(CAP_B, [FB_FS_OP_READ, handle, 0, 2]), FB_FS_ERR_BAD_HANDLE);
        expect(164, fs_as(CAP_B, [FB_FS_OP_WRITE, handle, 10 << 32, 0]), FB_FS_ERR_BAD_HANDLE);
        expect(165, fs_as(CAP_B, [FB_FS_OP_DELETE, handle, 0, 0]), FB_FS_ERR_BAD_HANDLE);
        let length = put_path(b"stolen");
        expect(166, fs_as(CAP_B, [FB_FS_OP_RENAME, handle, PATH_PAGE, length]), FB_FS_ERR_BAD_HANDLE);
        expect(167, fs_as(CAP_B, [FB_FS_OP_LIST, handle, 0, PATH_PAGE]), FB_FS_ERR_BAD_HANDLE);
        expect(168, fs_as(CAP_B, [FB_FS_OP_STAT, handle, 0, 0]), FB_FS_ERR_BAD_HANDLE);
        expect(169, fs_as(CAP_B, [FB_FS_OP_CLOSE, handle, 0, 0]), FB_FS_ERR_BAD_HANDLE);
    }
    // La raíz vale para todos.
    expect(170, fs_as(CAP_B, [FB_FS_OP_LIST, FB_FS_ROOT, 0, PATH_PAGE]), FB_FS_OK);
    // A sigue con los suyos, y "hello" intacto.
    check_hello(171);
    if number(179, a_hello) != hello_number {
        fail(179, 0);
    }

    // B abre "hello": su primer manejador es el 0, el mismo número que el
    // "hello" de A, pero de B. Cerrarlo no cierra el de A.
    let b_hello = expect(180, lookup_as(CAP_B, hello()), FB_FS_OK)[1];
    if b_hello != hello_file {
        fail(181, b_hello);
    }
    expect(182, fs_as(CAP_B, [FB_FS_OP_READ, b_hello, 0, 2]), FB_FS_OK);
    check(183, 2, 0xf500, 4096);
    expect(184, fs_as(CAP_B, [FB_FS_OP_CLOSE, b_hello, 0, 0]), FB_FS_OK);
    expect(185, fs_as(CAP_B, [FB_FS_OP_READ, b_hello, 0, 2]), FB_FS_ERR_BAD_HANDLE);
    expect(185, read(hello_file, 0, 2), FB_FS_OK);

    // Sin marca, nada: tampoco formatear, ni parar el servidor, ni cerrar.
    let length = put_path(hello());
    for words in [
        [FB_FS_OP_LOOKUP, PATH_PAGE, length, 0],
        [FB_FS_OP_READ, hello_file, 0, 2],
        [FB_FS_OP_FORMAT, 0, 0, 0],
        [FB_FS_OP_FREE, 0, 0, 0],
        [FB_FS_OP_STOP, 0, 0, 0],
        [FB_FS_OP_CLOSE, hello_file, 0, 0],
        [FB_FS_OP_DETACH, 0, 0, 0],
    ] {
        expect(186, fs_as(CAP_PLAIN, words), FB_FS_ERR_DENIED);
    }
    if fs([FB_FS_OP_FREE, 0, 0, 0])[1] != free {
        fail(187, 0);
    }
    expect(188, read(hello_file, 0, 2), FB_FS_OK);

    // A tiene 16 manejadores: abiertos hello_file y a_hello, caben 14 más.
    let mut extra = [0u64; FB_FS_MAX_OPEN as usize];
    let mut count = 0usize;
    loop {
        let found = lookup(hello());
        if found[0] == FB_FS_ERR_HANDLES {
            break;
        }
        expect(189, found, FB_FS_OK);
        if count == extra.len() {
            fail(190, 0xff);
        }
        extra[count] = found[1];
        count += 1;
    }
    if count as u64 != FB_FS_MAX_OPEN - 2 {
        fail(190, count as u64);
    }
    // Sin un manejador libre no se crea nada.
    create(191, b"zz", FB_FS_ERR_HANDLES);
    mkdir(191, b"zz", FB_FS_ERR_HANDLES);
    expect(192, lookup_as(CAP_B, b"zz"), FB_FS_ERR_NOT_FOUND);
    // Uno cerrado queda libre: es el que da la siguiente búsqueda.
    close_ok(193, extra[3]);
    let again = expect(194, lookup(hello()), FB_FS_OK)[1];
    if again != extra[3] {
        fail(195, again);
    }
    for handle in &extra[..count] {
        close_ok(196, *handle);
    }

    // Caben FB_FS_CLIENTS clientes: A, B (sin nada abierto, pero con fila),
    // C y D. E no cabe hasta que B se despide.
    let c_hello = expect(197, lookup_as(CAP_C, hello()), FB_FS_OK)[1];
    let d_hello = expect(198, lookup_as(CAP_D, hello()), FB_FS_OK)[1];
    expect(199, lookup_as(CAP_E, hello()), FB_FS_ERR_HANDLES);
    let length = put_path(b"zz");
    expect(199, fs_as(CAP_E, [FB_FS_OP_CREATE, PATH_PAGE, length, FB_FS_KIND_FILE]), FB_FS_ERR_HANDLES);
    expect(200, fs_as(CAP_B, [FB_FS_OP_DETACH, 0, 0, 0]), FB_FS_OK);
    let e_hello = expect(201, lookup_as(CAP_E, hello()), FB_FS_OK)[1];
    // Despedirse cierra todo lo del que se despide, y nada de los demás.
    expect(202, fs_as(CAP_D, [FB_FS_OP_DETACH, 0, 0, 0]), FB_FS_OK);
    expect(203, fs_as(CAP_D, [FB_FS_OP_STAT, d_hello, 0, 0]), FB_FS_ERR_BAD_HANDLE);
    if expect(204, fs_as(CAP_C, [FB_FS_OP_STAT, c_hello, 0, 0]), FB_FS_OK)[1] != hello_number
        || expect(204, fs_as(CAP_E, [FB_FS_OP_STAT, e_hello, 0, 0]), FB_FS_OK)[1] != hello_number
    {
        fail(204, 0);
    }

    // A borra un archivo que C tiene abierto: el manejador de C sigue
    // abierto, pero caducado.
    let t = create(205, b"t", FB_FS_OK);
    let c_t = expect(206, lookup_as(CAP_C, b"t"), FB_FS_OK)[1];
    if delete(t) != FB_FS_OK {
        fail(207, 0);
    }
    expect(208, fs_as(CAP_C, [FB_FS_OP_READ, c_t, 0, 2]), FB_FS_ERR_STALE);
    expect(208, fs_as(CAP_C, [FB_FS_OP_STAT, c_t, 0, 0]), FB_FS_ERR_STALE);
    close_ok(209, t);
    expect(210, fs_as(CAP_C, [FB_FS_OP_CLOSE, c_t, 0, 0]), FB_FS_OK);

    // Todos se despiden; A solo conserva hello_file.
    for cap in [CAP_C, CAP_E] {
        expect(211, fs_as(cap, [FB_FS_OP_DETACH, 0, 0, 0]), FB_FS_OK);
    }
    close_ok(212, a_hello);
    expect(213, stat(a_hello), FB_FS_ERR_BAD_HANDLE);
    if fs([FB_FS_OP_FREE, 0, 0, 0])[1] != free || list(FB_FS_ROOT, 0)[1] != hello_number
        || list(FB_FS_ROOT, entry_of(hello_number) + 1)[1] != FB_FS_FILES
    {
        fail(214, 0);
    }
}

/// Lo que hay al montar de nuevo: "hello" con sus datos y nada más gastado.
fn check_mounted(step: u64) {
    check_hello(step);
    let free = fs([FB_FS_OP_FREE, 0, 0, 0])[1];
    if free != FB_FS_BLOCKS - FB_FS_FIRST_DATA - 2 {
        fail(step + 8, free);
    }
    if list(FB_FS_ROOT, 0)[1] != number_of(hello())[1] {
        fail(step + 9, 0);
    }
}

const BENCH_OPEN_FIRST: u64 = 1;
const BENCH_OPEN_LAST: u64 = 2;
const BENCH_READ: u64 = 3;
const BENCH_WRITE: u64 = 4;
const BENCH_CREATE_DELETE: u64 = 5;
const BENCH_OPEN_DEEP: u64 = 6;
const BENCH_RENAME: u64 = 7;
const BENCH_STAT: u64 = 8;

fn rdtime() -> u64 {
    let value: u64;
    unsafe { asm!("rdtime {0}", out(reg) value, options(nomem, nostack)) };
    value
}

fn rdinstret() -> u64 {
    let value: u64;
    unsafe { asm!("rdinstret {0}", out(reg) value, options(nomem, nostack)) };
    value
}

/// Repite una operación. Abrir y cerrar (LOOKUP y CLOSE) y STAT no tocan el
/// disco: se miden con el reloj (unidades de 100 ns), como open, close y
/// fstat en Linux. Lo demás espera al disco y se mide en instrucciones de
/// toda la máquina (instret, global con -icount), como el Hito 34.
fn bench(operation: u64, rounds: u64) -> u64 {
    expect(1, fs([FB_FS_OP_FORMAT, 0, 0, 0]), FB_FS_OK);
    if operation == BENCH_OPEN_LAST {
        // La tabla llena: "bench" es la última entrada.
        for number in 0..FB_FS_FILES - 1 {
            create_closed(2, &numbered(b'f', number), FB_FS_OK);
        }
    }
    // Para buscar a fondo y renombrar: d1/d2/d3, y "bench" dentro.
    let deep = operation == BENCH_OPEN_DEEP || operation == BENCH_RENAME;
    let (bench_path, other_path): (&[u8], &[u8]) =
        if deep { (b"d1/d2/d3/bench", b"d1/bench") } else { (b"bench", b"other") };
    if deep {
        create_kind(2, b"d1", FB_FS_KIND_DIR, FB_FS_OK);
        create_kind(2, b"d1/d2", FB_FS_KIND_DIR, FB_FS_OK);
        create_kind(2, b"d1/d2/d3", FB_FS_KIND_DIR, FB_FS_OK);
    }
    let file = create(3, bench_path, FB_FS_OK);
    fill(0, 0xbe00);
    if write(file, 0, 4096, 0) != FB_FS_OK {
        fail(4, 0);
    }
    let (begin_time, begin_count) = (rdtime(), rdinstret());
    for round in 0..rounds {
        let status = match operation {
            BENCH_OPEN_FIRST | BENCH_OPEN_LAST | BENCH_OPEN_DEEP => {
                let found = lookup(bench_path);
                if found[0] != FB_FS_OK {
                    fail(5, found[0]);
                }
                close(found[1])
            }
            BENCH_STAT => stat(file)[0],
            BENCH_READ => read(file, 0, 1)[0],
            BENCH_WRITE => write(file, 0, 4096, 0),
            BENCH_CREATE_DELETE => {
                let created = create(5, other_path, FB_FS_OK);
                let status = delete(created);
                if status != FB_FS_OK {
                    fail(5, status);
                }
                close(created)
            }
            // De un directorio a otro y de vuelta.
            BENCH_RENAME => rename(file, if round % 2 == 0 { other_path } else { bench_path }),
            _ => fail(6, operation),
        };
        if status != FB_FS_OK {
            fail(7, status);
        }
    }
    let (time, count) = (rdtime() - begin_time, rdinstret() - begin_count);
    match operation {
        BENCH_OPEN_FIRST | BENCH_OPEN_LAST | BENCH_OPEN_DEEP | BENCH_STAT => time,
        _ => count,
    }
}

#[no_mangle]
#[link_section = ".text.entry"]
pub extern "C" fn _start(argument: u64) -> ! {
    if region_map(CAP_DATA, SHARED) != 0 {
        fail(0xfe, 0);
    }
    if argument & 0xff == 0x10 {
        let result = bench((argument >> 8) & 0xff, argument >> 16);
        expect(0xfc, fs([FB_FS_OP_STOP, 1, 0, 0]), FB_FS_OK);
        exit(result);
    }
    match argument {
        1 => first_pass(),
        2 => {
            // Un servidor nuevo no tiene nada abierto: el manejador 0 de la
            // pasada anterior no vale.
            expect(19, read(0, 0, 0), FB_FS_ERR_BAD_HANDLE);
            check_mounted(1);
            let empty = expect(20, lookup(b"empty"), FB_FS_OK);
            if empty[2] != 0 {
                fail(21, empty[2]);
            }
            // Lo último: borrarlo. Solo llega al disco si borrar escribe la tabla.
            if delete(empty[1]) != FB_FS_OK {
                fail(22, 0);
            }
        }
        3 => {
            check_mounted(1);
            expect(20, lookup(b"empty"), FB_FS_ERR_NOT_FOUND);
            // Lo último: escribir. La longitud nueva solo llega al disco si
            // escribir anota la tabla.
            let file = lookup(hello())[1];
            fill(1, 0xf501);
            if write(file, 1, 200, 1) != FB_FS_OK {
                fail(21, 0);
            }
        }
        4 => {
            check_hello_with(1, 200);
            // Formatear un disco montado: el manejador abierto de antes
            // contesta que caducó, aunque otro archivo ocupe su entrada.
            let old = lookup(hello())[1];
            let old_number = number(19, old);
            expect(20, fs([FB_FS_OP_FORMAT, 0, 0, 0]), FB_FS_OK);
            let new = create(21, b"x", FB_FS_OK);
            let new_number = number(21, new);
            if entry_of(new_number) != entry_of(old_number) || new_number == old_number {
                fail(22, new_number);
            }
            expect(23, read(old, 0, 0), FB_FS_ERR_STALE);
        }
        _ => fail(0xfd, argument),
    }
    let stop_driver = if argument == 4 { 1 } else { 0 };
    expect(0xfc, fs([FB_FS_OP_STOP, stop_driver, 0, 0]), FB_FS_OK);
    exit(0)
}

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    exit(0xfb)
}
