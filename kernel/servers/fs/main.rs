// SPDX-License-Identifier: GPL-3.0-or-later
//! Servidor de archivos de Fabianus: un proceso de usuario entre los clientes
//! y el driver del disco.
//!
//! Toda decisión sobre el formato la toma el núcleo demostrado en SPARK
//! (spark/src/fs_core.ads), enlazado en esta misma imagen: montar, buscar,
//! crear, dónde escribir, borrar, renombrar. Este programa solo habla con el
//! cliente y con el driver, parte las rutas en nombres y mantiene la
//! condición que exige el núcleo: entre llamadas, la tabla y los mapas solo
//! los cambia el propio núcleo.
//!
//! Capabilities que recibe al crearse:
//!   hueco 0: endpoint de peticiones, con Recv. Los clientes le llaman.
//!   hueco 1: endpoint del driver del disco, con Send.
//!   hueco 2: región de metadatos (FB_FS_META_PAGES páginas: superbloque y
//!            tabla). La comparte solo con el driver, que la tiene como su
//!            primera región de datos.
//!   hueco 3: región de datos del cliente, que el driver tiene como segunda
//!            región: el disco lee y escribe en ella sin copias.
//! El argumento es el número de páginas de la región del cliente.
//!
//! Consistencia ante cortes de luz (Hito 36). Cada operación es atómica: tras
//! un corte, el disco tiene el estado de antes o el de después. Se apoya en:
//!   - copia al escribir: los datos van siempre a un bloque que ningún
//!     archivo de la tabla del disco nombra (Plan_Write, Not_In_Table);
//!   - orden: los datos llegan al disco antes que la tabla que los nombra, y
//!     la tabla antes que el superbloque al formatear;
//!   - cada operación cambia una sola entrada de 64 bytes, que cae dentro de
//!     un sector de 512: un sector se escribe entero o no se escribe. Con
//!     directorios (Hito 37) sigue siendo así: cada entrada guarda su
//!     directorio, así que crear, borrar y renombrar, también de un
//!     directorio a otro, cambian solo la entrada que se crea, se borra o se
//!     mueve.
//! Si una escritura de la tabla falla, la de memoria ya no es la del disco:
//! el servidor deja de atender hasta que otro monte el disco.
//!
//! Generaciones (Hito 38). Cada entrada tiene una generación, que el núcleo
//! comprueba en cada uso (Opened). Borrar la sube en la misma entrada que se
//! escribe, así que la entrada y la generación de algo borrado no vuelven a
//! valer aunque otro archivo ocupe la entrada, tampoco tras un corte de luz
//! ni con otro servidor.
//!
//! Manejadores por cliente (Hito 39). El kernel dice quién llama: la marca
//! de la capability del cliente, que solo pone el kernel. Un manejador es
//! un número pequeño que el cliente recibe al buscar o crear y que solo vale
//! para él: la tabla de manejadores abiertos de cada marca la lleva otro
//! paquete demostrado (spark/src/fs_handles.ads), que da la entrada y la
//! generación de lo abierto. Así un cliente no puede fabricar un manejador
//! ni usar el de otro.

#![no_std]
#![no_main]

use core::panic::PanicInfo;
use core::ptr::{read_volatile, write_volatile};
use fb_abi::*;
use fb_user::*;

const CAP_REQUESTS: u64 = 0;
const CAP_DISK: u64 = 1;
const CAP_META: u64 = 2;
const CAP_CLIENT: u64 = 3;

const FILES: usize = FB_FS_FILES as usize;
const BLOCKS: usize = FB_FS_BLOCKS as usize;
const FILE_BLOCKS: usize = FB_FS_FILE_BLOCKS as usize;
const NAME_BYTES: usize = FB_FS_NAME_BYTES as usize;
const PATH_BYTES: usize = FB_FS_PATH_BYTES as usize;
const MAX_CLIENT_PAGES: u64 = 16;

/// Páginas de la región de metadatos, en la numeración del driver.
const SUPER_PAGE: u64 = 0;
const TABLE_PAGE: u64 = 1;
const SUPER_BLOCK: u64 = 0;
const TABLE_BLOCK: u64 = 1;

const EXIT_ARGUMENT: u64 = 0xf1;
const EXIT_NO_MEMORY: u64 = 0xf2;
const EXIT_DISK: u64 = 0xf3;
const EXIT_PANIC: u64 = 0xf4;

#[repr(C)]
struct Entry {
    used: u8,
    kind: u8,
    parent: u8,
    pad: u8,
    length: u32,
    gen: u32,
    name: [u8; NAME_BYTES],
    blocks: [u16; FILE_BLOCKS],
}

#[repr(C)]
struct Super {
    magic: u64,
    version: u32,
    blocks: u32,
    files: u32,
    unused: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Owner {
    used: u8,
    file: u8,
    slot: u8,
    pad: u8,
}

type Table = [Entry; FILES];
type OwnerMap = [Owner; BLOCKS];
type DepthMap = [u8; FILES];
type Name = [u8; NAME_BYTES];

#[repr(C)]
#[derive(Clone, Copy)]
struct Open {
    used: u32,
    file: u32,
    gen: u32,
    pad: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Client {
    badge: u64,
    opens: [Open; FB_FS_MAX_OPEN as usize],
}

type Handles = [Client; FB_FS_CLIENTS as usize];

// El núcleo demostrado (fs_core.ads y fs_handles.ads). Los registros y tablas van por
// referencia, y los resultados por puntero.
extern "C" {
    fn fb_fs_mount(super_block: *const Super, table: *const Table, owner: *mut OwnerMap, depth: *mut DepthMap, status: *mut u64);
    fn fb_fs_format(super_block: *mut Super, table: *mut Table, owner: *mut OwnerMap, depth: *mut DepthMap, keep: u64);
    fn fb_fs_lookup(table: *const Table, owner: *const OwnerMap, depth: *const DepthMap, dir: u64, name: *const Name, file: *mut u64, status: *mut u64);
    fn fb_fs_create(table: *mut Table, owner: *const OwnerMap, depth: *mut DepthMap, dir: u64, name: *const Name, kind: u64, file: *mut u64, status: *mut u64);
    fn fb_fs_block_of(table: *const Table, owner: *const OwnerMap, depth: *const DepthMap, file: u64, gen: u64, slot: u64, block: *mut u64, bytes: *mut u64, status: *mut u64);
    fn fb_fs_plan_write(table: *const Table, owner: *const OwnerMap, depth: *const DepthMap, file: u64, gen: u64, slot: u64, bytes: u64, block: *mut u64, status: *mut u64);
    fn fb_fs_commit_write(table: *mut Table, owner: *mut OwnerMap, depth: *const DepthMap, file: u64, gen: u64, slot: u64, bytes: u64, block: u64, status: *mut u64);
    fn fb_fs_delete(table: *mut Table, owner: *mut OwnerMap, depth: *mut DepthMap, file: u64, gen: u64, status: *mut u64);
    fn fb_fs_rename(table: *mut Table, owner: *const OwnerMap, depth: *mut DepthMap, file: u64, gen: u64, dir: u64, name: *const Name, status: *mut u64);
    fn fb_fs_next_in(table: *const Table, owner: *const OwnerMap, depth: *const DepthMap, dir: u64, gen: u64, from: u64, file: *mut u64, status: *mut u64);
    fn fb_fs_stat(table: *const Table, owner: *const OwnerMap, depth: *const DepthMap, file: u64, gen: u64, kind: *mut u64, length: *mut u64, status: *mut u64);
    fn fb_fs_free_blocks(owner: *const OwnerMap) -> u64;
    fn fb_fs_handles_clear(handles: *mut Handles);
    fn fb_fs_room(handles: *const Handles, badge: u64) -> u64;
    fn fb_fs_open(handles: *mut Handles, badge: u64, file: u64, gen: u64, handle: *mut u64, status: *mut u64);
    fn fb_fs_resolve(handles: *const Handles, badge: u64, handle: u64, file: *mut u64, gen: *mut u64, status: *mut u64);
    fn fb_fs_close(handles: *mut Handles, badge: u64, handle: u64, status: *mut u64);
    fn fb_fs_detach(handles: *mut Handles, badge: u64);
}

/// El servidor: la tabla y el superbloque viven en la región de metadatos;
/// el mapa de bloques y las profundidades, en su pila.
struct Server {
    super_block: *mut Super,
    table: *mut Table,
    owner: OwnerMap,
    depth: DepthMap,
    client_pages: u64,
    /// FB_FS_OK si hay un sistema de archivos montado; si no, lo que se
    /// contesta a todo salvo FORMAT: sin formato, corrupto o, tras fallar una
    /// escritura de la tabla, error de disco.
    state: u64,
    /// 1 si la tabla de memoria es la de un sistema de archivos (montado,
    /// aunque esté corrupto, o formateado): pudo dar manejadores, así que
    /// formatear sube sus generaciones en vez de empezar en 0.
    keep: u64,
    /// Los manejadores abiertos de cada cliente.
    handles: Handles,
    /// La marca de quien hace la petición que se atiende.
    badge: u64,
}

/// Una petición al driver: un bloque del sistema de archivos y una página en
/// la numeración del driver. Devuelve un FB_DISK_*.
fn disk(operation: u64, block: u64, page: u64) -> u64 {
    let sector = FB_FS_FIRST_SECTOR + block * FB_DISK_SECTORS_PER_PAGE;
    let answer = call(CAP_DISK, [operation, sector, page, 0]);
    if answer.status != 0 {
        FB_DISK_ERR_IO
    } else {
        answer.words[0]
    }
}

fn disk_status(status: u64) -> u64 {
    if status == FB_DISK_OK {
        FB_FS_OK
    } else {
        FB_FS_ERR_IO
    }
}

/// Página del cliente, en la numeración del driver.
fn client_page(page: u64) -> u64 {
    FB_FS_META_PAGES + page
}

/// Una ruta copiada de la región del cliente: así no cambia mientras se usa.
/// Se copia por palabras; solo cuentan los primeros `length` bytes.
struct Path {
    words: [u64; PATH_BYTES / 8],
    length: usize,
}

/// Un nombre de la ruta, rellenado con ceros. Las reglas de los nombres las
/// comprueba también el núcleo (Name_Ok); aquí solo hace falta no partir mal.
fn component(bytes: &[u8]) -> Result<Name, u64> {
    if bytes.len() > NAME_BYTES || bytes.contains(&0) || bytes == b"." || bytes == b".." {
        return Err(FB_FS_ERR_REQUEST);
    }
    let mut name = [0u8; NAME_BYTES];
    name[..bytes.len()].copy_from_slice(bytes);
    Ok(name)
}

impl Path {
    fn bytes(&self) -> &[u8] {
        unsafe { core::slice::from_raw_parts(self.words.as_ptr() as *const u8, self.length) }
    }

    /// El siguiente nombre de la ruta desde `at` (varios '/' seguidos cuentan
    /// como uno): dónde empieza y dónde acaba, o None si no quedan.
    fn next(&self, at: usize) -> Option<(usize, usize)> {
        let bytes = self.bytes();
        let mut start = at;
        while start < bytes.len() && bytes[start] == b'/' {
            start += 1;
        }
        if start == bytes.len() {
            return None;
        }
        let mut end = start;
        while end < bytes.len() && bytes[end] != b'/' {
            end += 1;
        }
        Some((start, end))
    }
}

impl Server {
    fn mount(&mut self) {
        let mut status = FB_FS_ERR_UNFORMATTED;
        unsafe { fb_fs_mount(self.super_block, self.table, &mut self.owner, &mut self.depth, &mut status) };
        self.state = status;
        self.keep = (status != FB_FS_ERR_UNFORMATTED) as u64;
    }

    /// Lleva al disco la tabla que acaba de cambiar el núcleo. Si no llega,
    /// el servidor deja de atender.
    fn write_table(&mut self) -> u64 {
        let status = disk_status(disk(FB_DISK_OP_WRITE, TABLE_BLOCK, TABLE_PAGE));
        if status != FB_FS_OK {
            self.state = FB_FS_ERR_IO;
        }
        status
    }

    fn format(&mut self) -> [u64; 4] {
        self.state = FB_FS_ERR_IO;
        unsafe { fb_fs_format(self.super_block, self.table, &mut self.owner, &mut self.depth, self.keep) };
        self.keep = 1;
        // La tabla vacía primero: el superbloque nuevo es lo último.
        let mut status = self.write_table();
        if status == FB_FS_OK {
            status = disk_status(disk(FB_DISK_OP_WRITE, SUPER_BLOCK, SUPER_PAGE));
        }
        self.state = if status == FB_FS_OK { FB_FS_OK } else { FB_FS_ERR_IO };
        [status, 0, 0, 0]
    }

    fn path(&self, page: u64, length: u64) -> Result<Path, u64> {
        if page >= self.client_pages || length == 0 || length > PATH_BYTES as u64 {
            return Err(FB_FS_ERR_REQUEST);
        }
        let mut path = Path { words: [0u64; PATH_BYTES / 8], length: length as usize };
        let source = (FB_FS_CLIENT_BASE + page * FB_PAGE_SIZE) as *const u64;
        for index in 0..path.length.div_ceil(8) {
            path.words[index] = unsafe { read_volatile(source.add(index)) };
        }
        Ok(path)
    }

    /// La entrada Name del directorio Dir.
    fn step(&self, dir: u64, name: &Name) -> Result<u64, u64> {
        let (mut file, mut status) = (0u64, 0u64);
        unsafe { fb_fs_lookup(self.table, &self.owner, &self.depth, dir, name, &mut file, &mut status) };
        if status == FB_FS_OK {
            Ok(file)
        } else {
            Err(status)
        }
    }

    /// La entrada de toda la ruta: FB_FS_ROOT si no tiene nombres.
    fn resolve(&self, path: &Path) -> Result<u64, u64> {
        let mut entry = FB_FS_ROOT;
        let mut at = 0;
        while let Some((start, end)) = path.next(at) {
            entry = self.step(entry, &component(&path.bytes()[start..end])?)?;
            at = end;
        }
        Ok(entry)
    }

    /// El directorio que contiene la ruta, y el último nombre.
    fn resolve_parent(&self, path: &Path) -> Result<(u64, Name), u64> {
        let mut dir = FB_FS_ROOT;
        let Some(mut current) = path.next(0) else {
            return Err(FB_FS_ERR_REQUEST);
        };
        loop {
            let (start, end) = current;
            let name = component(&path.bytes()[start..end])?;
            match path.next(end) {
                None => return Ok((dir, name)),
                Some(following) => {
                    dir = self.step(dir, &name)?;
                    current = following;
                }
            }
        }
    }

    fn entry(&self, file: u64) -> &Entry {
        unsafe { &(*self.table)[file as usize] }
    }

    /// El número de una entrada: ella y su generación.
    fn number(&self, file: u64) -> u64 {
        (self.entry(file).gen as u64) << FB_FS_HANDLE_SHIFT | file
    }

    /// La entrada y la generación que este cliente tiene abiertas en el
    /// manejador. FB_FS_ROOT es la raíz para todos.
    fn opened(&self, handle: u64) -> Result<(u64, u64), u64> {
        if handle == FB_FS_ROOT {
            return Ok((FB_FS_ROOT, 0));
        }
        let (mut file, mut gen, mut status) = (0u64, 0u64, 0u64);
        unsafe { fb_fs_resolve(&self.handles, self.badge, handle, &mut file, &mut gen, &mut status) };
        if status == FB_FS_OK {
            Ok((file, gen))
        } else {
            Err(status)
        }
    }

    /// Abre la entrada para este cliente con su generación de ahora.
    fn open(&mut self, file: u64) -> Result<u64, u64> {
        let gen = self.entry(file).gen as u64;
        let (mut handle, mut status) = (0u64, 0u64);
        unsafe { fb_fs_open(&mut self.handles, self.badge, file, gen, &mut handle, &mut status) };
        if status == FB_FS_OK {
            Ok(handle)
        } else {
            Err(status)
        }
    }

    fn lookup(&mut self, page: u64, length: u64) -> [u64; 4] {
        match self.path(page, length).and_then(|path| self.resolve(&path)) {
            Ok(FB_FS_ROOT) => [FB_FS_OK, FB_FS_ROOT, 0, FB_FS_KIND_DIR],
            Ok(file) => match self.open(file) {
                Ok(handle) => {
                    let entry = self.entry(file);
                    [FB_FS_OK, handle, entry.length as u64, entry.kind as u64]
                }
                Err(status) => [status, 0, 0, 0],
            },
            Err(status) => [status, 0, 0, 0],
        }
    }

    fn create(&mut self, page: u64, length: u64, kind: u64) -> [u64; 4] {
        let (dir, name) = match self.path(page, length).and_then(|path| self.resolve_parent(&path)) {
            Ok(found) => found,
            Err(status) => return [status, 0, 0, 0],
        };
        // Sin un manejador libre no se crea: el cliente no sabría que existe.
        if unsafe { fb_fs_room(&self.handles, self.badge) } != 1 {
            return [FB_FS_ERR_HANDLES, 0, 0, 0];
        }
        let (mut file, mut status) = (0u64, 0u64);
        unsafe { fb_fs_create(self.table, &self.owner, &mut self.depth, dir, &name, kind, &mut file, &mut status) };
        if status == FB_FS_OK {
            status = self.write_table();
        }
        if status != FB_FS_OK {
            return [status, 0, 0, 0];
        }
        // Room lo garantiza (Fs_Handles.Open, Has_Room).
        match self.open(file) {
            Ok(handle) => [FB_FS_OK, handle, 0, 0],
            Err(_) => exit(EXIT_PANIC),
        }
    }

    fn rename(&mut self, handle: u64, page: u64, length: u64) -> [u64; 4] {
        let (file, gen) = match self.opened(handle) {
            Ok(found) => found,
            Err(status) => return [status, 0, 0, 0],
        };
        let (dir, name) = match self.path(page, length).and_then(|path| self.resolve_parent(&path)) {
            Ok(found) => found,
            Err(status) => return [status, 0, 0, 0],
        };
        let mut status = 0u64;
        unsafe { fb_fs_rename(self.table, &self.owner, &mut self.depth, file, gen, dir, &name, &mut status) };
        if status == FB_FS_OK {
            status = self.write_table();
        }
        [status, 0, 0, 0]
    }

    fn read(&self, handle: u64, slot: u64, page: u64) -> [u64; 4] {
        if page >= self.client_pages {
            return [FB_FS_ERR_REQUEST, 0, 0, 0];
        }
        let (file, gen) = match self.opened(handle) {
            Ok(found) => found,
            Err(status) => return [status, 0, 0, 0],
        };
        let (mut block, mut bytes, mut status) = (0u64, 0u64, 0u64);
        unsafe { fb_fs_block_of(self.table, &self.owner, &self.depth, file, gen, slot, &mut block, &mut bytes, &mut status) };
        if status != FB_FS_OK {
            return [status, 0, 0, 0];
        }
        let status = disk_status(disk(FB_DISK_OP_READ, block, client_page(page)));
        [status, if status == FB_FS_OK { bytes } else { 0 }, 0, 0]
    }

    fn write(&mut self, handle: u64, slot_and_bytes: u64, page: u64) -> [u64; 4] {
        if page >= self.client_pages {
            return [FB_FS_ERR_REQUEST, 0, 0, 0];
        }
        let (file, gen) = match self.opened(handle) {
            Ok(found) => found,
            Err(status) => return [status, 0, 0, 0],
        };
        let slot = slot_and_bytes & 0xffff_ffff;
        let bytes = slot_and_bytes >> 32;
        let (mut block, mut status) = (0u64, 0u64);
        unsafe { fb_fs_plan_write(self.table, &self.owner, &self.depth, file, gen, slot, bytes, &mut block, &mut status) };
        if status != FB_FS_OK {
            return [status, 0, 0, 0];
        }
        // Los datos primero, en un bloque que la tabla del disco no nombra;
        // solo si llegaron se anotan en la tabla.
        let status = disk_status(disk(FB_DISK_OP_WRITE, block, client_page(page)));
        if status != FB_FS_OK {
            return [status, 0, 0, 0];
        }
        let mut status = 0u64;
        unsafe { fb_fs_commit_write(self.table, &mut self.owner, &self.depth, file, gen, slot, bytes, block, &mut status) };
        if status == FB_FS_OK {
            status = self.write_table();
        }
        [status, 0, 0, 0]
    }

    fn delete(&mut self, handle: u64) -> [u64; 4] {
        let (file, gen) = match self.opened(handle) {
            Ok(found) => found,
            Err(status) => return [status, 0, 0, 0],
        };
        let mut status = 0u64;
        unsafe { fb_fs_delete(self.table, &mut self.owner, &mut self.depth, file, gen, &mut status) };
        if status == FB_FS_OK {
            status = self.write_table();
        }
        [status, 0, 0, 0]
    }

    fn list(&self, handle: u64, from: u64, page: u64) -> [u64; 4] {
        if page >= self.client_pages {
            return [FB_FS_ERR_REQUEST, 0, 0, 0];
        }
        let (dir, gen) = match self.opened(handle) {
            Ok(found) => found,
            Err(status) => return [status, 0, 0, 0],
        };
        let (mut file, mut status) = (0u64, 0u64);
        unsafe { fb_fs_next_in(self.table, &self.owner, &self.depth, dir, gen, from, &mut file, &mut status) };
        if status != FB_FS_OK {
            return [status, 0, 0, 0];
        }
        if file >= FB_FS_FILES {
            return [FB_FS_OK, FB_FS_FILES, 0, 0];
        }
        let entry = self.entry(file);
        let destination = (FB_FS_CLIENT_BASE + page * FB_PAGE_SIZE) as *mut u8;
        for (index, byte) in entry.name.iter().enumerate() {
            unsafe { write_volatile(destination.add(index), *byte) };
        }
        [FB_FS_OK, self.number(file), entry.length as u64, entry.kind as u64]
    }

    fn stat(&self, handle: u64) -> [u64; 4] {
        let (file, gen) = match self.opened(handle) {
            Ok(found) => found,
            Err(status) => return [status, 0, 0, 0],
        };
        let (mut kind, mut length, mut status) = (0u64, 0u64, 0u64);
        unsafe { fb_fs_stat(self.table, &self.owner, &self.depth, file, gen, &mut kind, &mut length, &mut status) };
        if status != FB_FS_OK {
            return [status, 0, 0, 0];
        }
        let number = if file == FB_FS_ROOT { FB_FS_ROOT } else { self.number(file) };
        [FB_FS_OK, number, length, kind]
    }

    fn close(&mut self, handle: u64) -> [u64; 4] {
        let mut status = 0u64;
        unsafe { fb_fs_close(&mut self.handles, self.badge, handle, &mut status) };
        [status, 0, 0, 0]
    }

    fn detach(&mut self) -> [u64; 4] {
        unsafe { fb_fs_detach(&mut self.handles, self.badge) };
        [FB_FS_OK, 0, 0, 0]
    }

    fn free(&self) -> [u64; 4] {
        [FB_FS_OK, unsafe { fb_fs_free_blocks(&self.owner) }, 0, 0]
    }

    fn serve(&mut self, words: [u64; 4], badge: u64) -> [u64; 4] {
        let [operation, first, second, third] = words;
        // Sin marca no se sabe de quién son los manejadores.
        if badge == 0 {
            return [FB_FS_ERR_DENIED, 0, 0, 0];
        }
        self.badge = badge;
        // Cerrar y despedirse no tocan el disco: valen en cualquier estado.
        match operation {
            FB_FS_OP_FORMAT => return self.format(),
            FB_FS_OP_CLOSE => return self.close(first),
            FB_FS_OP_DETACH => return self.detach(),
            _ => {}
        }
        if self.state != FB_FS_OK {
            return [self.state, 0, 0, 0];
        }
        match operation {
            FB_FS_OP_CREATE => self.create(first, second, third),
            FB_FS_OP_LOOKUP => self.lookup(first, second),
            FB_FS_OP_READ => self.read(first, second, third),
            FB_FS_OP_WRITE => self.write(first, second, third),
            FB_FS_OP_DELETE => self.delete(first),
            FB_FS_OP_RENAME => self.rename(first, second, third),
            FB_FS_OP_LIST => self.list(first, second, third),
            FB_FS_OP_STAT => self.stat(first),
            FB_FS_OP_FREE => self.free(),
            _ => [FB_FS_ERR_REQUEST, 0, 0, 0],
        }
    }
}

fn run(client_pages: u64) -> ! {
    if client_pages == 0 || client_pages > MAX_CLIENT_PAGES {
        exit(EXIT_ARGUMENT);
    }
    if region_map(CAP_META, FB_FS_META_BASE) != 0 || region_map(CAP_CLIENT, FB_FS_CLIENT_BASE) != 0 {
        exit(EXIT_NO_MEMORY);
    }

    // El disco debe llegar hasta el final del sistema de archivos.
    let capacity = call(CAP_DISK, [FB_DISK_OP_CAPACITY, 0, 0, 0]);
    if capacity.status != 0
        || capacity.words[0] != FB_DISK_OK
        || capacity.words[1] < FB_FS_FIRST_SECTOR + FB_FS_BLOCKS * FB_DISK_SECTORS_PER_PAGE
    {
        exit(EXIT_DISK);
    }

    let mut server = Server {
        super_block: FB_FS_META_BASE as *mut Super,
        table: (FB_FS_META_BASE + FB_PAGE_SIZE) as *mut Table,
        owner: [Owner { used: 0, file: 0, slot: 0, pad: 0 }; BLOCKS],
        depth: [0u8; FILES],
        client_pages,
        state: FB_FS_ERR_UNFORMATTED,
        keep: 0,
        handles: [Client { badge: 0, opens: [Open { used: 0, file: 0, gen: 0, pad: 0 }; FB_FS_MAX_OPEN as usize] }; FB_FS_CLIENTS as usize],
        badge: 0,
    };
    unsafe { fb_fs_handles_clear(&mut server.handles) };
    if disk(FB_DISK_OP_READ, SUPER_BLOCK, SUPER_PAGE) != FB_DISK_OK
        || disk(FB_DISK_OP_READ, TABLE_BLOCK, TABLE_PAGE) != FB_DISK_OK
    {
        exit(EXIT_DISK);
    }
    // Lo leído puede ser cualquier cosa: Mount decide si es un sistema de
    // archivos válido. Si no, solo se acepta FORMAT, y lo demás contesta si
    // el disco no tiene formato o está corrupto.
    server.mount();

    loop {
        let message = recv(CAP_REQUESTS);
        if message.status != 0 || message.kind != FB_MSG_CALL {
            continue;
        }
        if message.words[0] == FB_FS_OP_STOP && message.badge != 0 {
            // Con a2 = 1, para también el driver del disco.
            if message.words[1] == 1 {
                call(CAP_DISK, [FB_DISK_OP_STOP, 0, 0, 0]);
            }
            reply([FB_FS_OK, 0, 0, 0]);
            exit(0);
        }
        let answer = server.serve(message.words, message.badge);
        reply(answer);
    }
}

#[no_mangle]
#[link_section = ".text.entry"]
pub extern "C" fn _start(argument: u64) -> ! {
    run(argument)
}

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    exit(EXIT_PANIC)
}
