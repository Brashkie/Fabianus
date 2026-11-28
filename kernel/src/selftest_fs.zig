// SPDX-License-Identifier: GPL-3.0-or-later
//! Autopruebas del sistema de archivos (Hito 35; directorios, Hito 37;
//! generaciones, Hito 38; manejadores por cliente, Hito 39): los núcleos
//! demostrados en SPARK (fs_core y fs_handles), llamados directamente, y el
//! servidor de archivos en Rust entre sus clientes y el driver del disco.

const abi = @import("abi.zig").c;
const device = @import("device.zig");
const process = @import("process.zig");
const riscv = @import("riscv.zig");
const region = @import("region.zig");
const selftest_ipc = @import("selftest_ipc.zig");
const selftest_user = @import("selftest_user.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");
const uart = @import("uart.zig");

const send: u64 = abi.FB_RIGHT_SEND;
const recv: u64 = abi.FB_RIGHT_RECV;

const files = abi.FB_FS_FILES;
const blocks = abi.FB_FS_BLOCKS;
const file_blocks = abi.FB_FS_FILE_BLOCKS;
const data_blocks = blocks - abi.FB_FS_FIRST_DATA;

const Table = [files]abi.fb_fs_entry;
const Owners = [blocks]abi.fb_fs_owner;
const Depths = [files]u8;
const root = abi.FB_FS_ROOT;
const kind_file = abi.FB_FS_KIND_FILE;
const kind_dir = abi.FB_FS_KIND_DIR;

var super_block: abi.fb_fs_super = undefined;
var table: Table = undefined;
var owners: Owners = undefined;
var depths: Depths = undefined;
var copy: Table = undefined;
var rebuilt: Owners = undefined;
var rebuilt_depths: Depths = undefined;

fn passed(name: []const u8) void {
    uart.print("[ok] ");
    uart.print(name);
    uart.print("\n");
}

fn mountStatus(super: *const abi.fb_fs_super, entries: *const Table, map: *Owners) u64 {
    var status: u64 = abi.FB_FS_OK;
    abi.fb_fs_mount(super, &entries[0], &map[0], &rebuilt_depths[0], &status);
    return status;
}

/// Formatea sin generaciones de antes (Keep = 0).
fn format() void {
    formatKeeping(0);
}

fn formatKeeping(keep: u64) void {
    abi.fb_fs_format(&super_block, &table[0], &owners[0], &depths[0], keep);
}

/// La generación que tiene ahora una entrada: con ella, su manejador vale.
fn genOf(file: u64) u64 {
    return if (file < files) table[file].gen else 0;
}

const gen_last: u32 = 0xffff_ffff;

fn create(dir: u64, name: *const [abi.FB_FS_NAME_BYTES]u8, kind: u64, file: *u64) u64 {
    var status: u64 = 0;
    abi.fb_fs_create(&table[0], &owners[0], &depths[0], dir, name, kind, file, &status);
    return status;
}

fn rename(file: u64, gen: u64, dir: u64, name: *const [abi.FB_FS_NAME_BYTES]u8) u64 {
    var status: u64 = 0;
    abi.fb_fs_rename(&table[0], &owners[0], &depths[0], file, gen, dir, name, &status);
    return status;
}

fn delete(file: u64, gen: u64) u64 {
    var status: u64 = 0;
    abi.fb_fs_delete(&table[0], &owners[0], &depths[0], file, gen, &status);
    return status;
}

fn planWrite(file: u64, gen: u64, slot: u64, bytes: u64, block: *u64) u64 {
    var status: u64 = 0;
    abi.fb_fs_plan_write(&table[0], &owners[0], &depths[0], file, gen, slot, bytes, block, &status);
    return status;
}

fn commitWrite(file: u64, gen: u64, slot: u64, bytes: u64, block: u64) u64 {
    var status: u64 = 0;
    abi.fb_fs_commit_write(&table[0], &owners[0], &depths[0], file, gen, slot, bytes, block, &status);
    return status;
}

fn nextIn(dir: u64, gen: u64, from: u64, file: *u64) u64 {
    var status: u64 = 0;
    abi.fb_fs_next_in(&table[0], &owners[0], &depths[0], dir, gen, from, file, &status);
    return status;
}

/// Lo que promete Step_Ok, comprobado a mano entre dos tablas: ninguna
/// generación baja, y una entrada en uso que conserva la generación sigue en
/// uso y con el mismo tipo.
fn stepByHand(old: *const Table, new: *const Table) bool {
    for (old, new) |before, after| {
        if (after.gen < before.gen) return false;
        if (before.used == 1 and after.gen == before.gen and (after.used != 1 or after.kind != before.kind)) return false;
    }
    return true;
}

fn mount(super: *const abi.fb_fs_super, entries: *const Table, map: *Owners) bool {
    return mountStatus(super, entries, map) == abi.FB_FS_OK;
}

fn nameOf(prefix: u8, number: u64) [abi.FB_FS_NAME_BYTES]u8 {
    var name = [_]u8{0} ** abi.FB_FS_NAME_BYTES;
    name[0] = prefix;
    name[1] = '0' + @as(u8, @intCast(number / 10));
    name[2] = '0' + @as(u8, @intCast(number % 10));
    return name;
}

/// Lo que dicen los teoremas, comprobado aparte, sin el núcleo: ningún
/// bloque de datos está dos veces en la tabla, y todos están en la zona de
/// datos.
fn disjointByHand(entries: *const Table) bool {
    var seen = [_]bool{false} ** blocks;
    for (entries) |entry| {
        if (entry.used != 1) continue;
        const count = (entry.length + abi.FB_PAGE_SIZE - 1) / abi.FB_PAGE_SIZE;
        for (entry.blocks[0..count]) |block| {
            if (block < abi.FB_FS_FIRST_DATA or block >= blocks or seen[block]) return false;
            seen[block] = true;
        }
    }
    return true;
}

/// El primer directorio en uso desde `from` (dando la vuelta), o la raíz.
fn usedDir(from: u64) u64 {
    for (0..files) |offset| {
        const index = (from + offset) % files;
        if (table[index].used == 1 and table[index].kind == kind_dir) return index;
    }
    return root;
}

/// La primera entrada en uso desde `from` (dando la vuelta), o `from`.
fn usedEntry(from: u64) u64 {
    for (0..files) |offset| {
        const index = (from + offset) % files;
        if (table[index].used == 1) return index;
    }
    return from;
}

/// Y toda entrada cuelga de la raíz: subiendo de directorio en directorio
/// se llega a ella en menos de 64 pasos, y cada paso es un directorio en uso.
fn treeByHand(entries: *const Table) bool {
    for (entries) |entry| {
        if (entry.used != 1) continue;
        var parent: u64 = entry.parent;
        var steps: u64 = 0;
        while (parent != root) : (steps += 1) {
            if (steps >= files or parent >= files) return false;
            const up = entries[parent];
            if (up.used != 1 or up.kind != kind_dir) return false;
            parent = up.parent;
        }
    }
    return true;
}

fn freeByHand(map: *const Owners) u64 {
    var count: u64 = 0;
    for (map[abi.FB_FS_FIRST_DATA..]) |owner| {
        if (owner.used == 0) count += 1;
    }
    return count;
}

/// Un sistema vacío se monta, y tiene todos sus bloques de datos libres.
fn testFormatMounts() void {
    format();
    if (!mount(&super_block, &table, &rebuilt)) @panic("un sistema de archivos recien formateado no se monta");
    if (abi.fb_fs_free_blocks(&owners[0]) != data_blocks) @panic("un sistema recien formateado no tiene todos los bloques libres");
    passed("un sistema de archivos recien formateado se monta con todos sus bloques libres");
}

/// Una secuencia larga de crear archivos y directorios, escribir, borrar y
/// renombrar, como la haría el servidor. Tras cada paso la tabla se vuelve a
/// montar desde cero: el mapa de bloques y las profundidades que el núcleo
/// mantiene paso a paso son los que se deducen de la tabla, ningún bloque se
/// repite y todo cuelga de la raíz (comprobado a mano, sin el núcleo).
fn checkAfterStep() void {
    if (!mount(&super_block, &table, &rebuilt)) @panic("tras una operacion, la tabla no se monta");
    if (!std.mem.eql(u8, std.mem.asBytes(&rebuilt), std.mem.asBytes(&owners))) @panic("el mapa de bloques no es el que se deduce de la tabla");
    if (!std.mem.eql(u8, &rebuilt_depths, &depths)) @panic("las profundidades no son las que se deducen de la tabla");
    if (!disjointByHand(&table)) @panic("un bloque esta en dos sitios de la tabla");
    if (!treeByHand(&table)) @panic("una entrada no cuelga de la raiz");
    if (abi.fb_fs_free_blocks(&owners[0]) != freeByHand(&owners)) @panic("los bloques libres no cuadran");
}

fn testOperationsKeepTableValid() void {
    format();
    var seed: u64 = 0x5eed_f5;
    var step: u64 = 0;
    var created: u64 = 0;
    var dirs: u64 = 0;
    var written: u64 = 0;
    var deleted: u64 = 0;
    var renamed: u64 = 0;
    var refused: u64 = 0;
    var full: u64 = 0;
    var stale: u64 = 0;
    // Manejadores de lo que se borró: no deben volver a valer nunca.
    var dead: [32][2]u64 = undefined;
    var dead_count: u64 = 0;
    while (step < 800) : (step += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const random = seed >> 24;
        // Casi siempre un directorio que existe (si no, la raíz); a veces
        // una entrada cualquiera, y entonces el núcleo puede negarse.
        const dir = if (random & 0x700000 == 0) (random >> 40) % files else usedDir((random >> 40) % files);
        // Renombrar mueve sobre todo directorios: así salen ciclos.
        const file = switch (random % 12) {
            5 => usedEntry((random >> 8) % files),
            6 => usedDir((random >> 8) % files),
            else => (random >> 8) % files,
        };
        // Casi siempre la generación de ahora; a veces la siguiente, que no
        // vale. (random tiene 40 bits.)
        const gen = genOf(file) + @intFromBool((random >> 28) & 15 == 0);
        const name = nameOf('n', (random >> 16) % 40);
        var result: u64 = 0;
        const before = table;
        var status: u64 = abi.FB_FS_OK;
        switch (random % 12) {
            0, 1 => {
                if (create(dir, &name, kind_file, &result) == abi.FB_FS_OK) created += 1;
            },
            2 => {
                status = delete(file, gen);
                if (status == abi.FB_FS_OK) {
                    deleted += 1;
                    dead[dead_count % dead.len] = .{ file, gen };
                    dead_count += 1;
                }
                if (status == abi.FB_FS_ERR_NOT_EMPTY) refused += 1;
            },
            3, 4 => {
                if (create(dir, &name, kind_dir, &result) == abi.FB_FS_OK) dirs += 1;
            },
            5, 6 => {
                // Antes y después de un rechazo, la tabla es la misma.
                const new_name = nameOf('r', (random >> 16) % 100);
                status = rename(file, gen, dir, &new_name);
                if (status == abi.FB_FS_OK) renamed += 1;
                if (status != abi.FB_FS_OK and !std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&table))) @panic("renombrar sin exito cambio la tabla");
                if (status == abi.FB_FS_ERR_REQUEST and file < files and table[file].used == 1 and dir < files and table[dir].used == 1) refused += 1;
            },
            else => {
                // Escribe en el bloque siguiente al último, o en uno que ya tiene.
                const count = (table[file].length + abi.FB_PAGE_SIZE - 1) / abi.FB_PAGE_SIZE;
                const slot = if (random & 0x10000 != 0) count else (random >> 20) % (count + 1);
                const bytes = 1 + (random >> 32) % abi.FB_PAGE_SIZE;
                var block: u64 = 0;
                status = planWrite(file, gen, slot, bytes, &block);
                if (status == abi.FB_FS_ERR_FULL) full += 1;
                if (status == abi.FB_FS_OK) {
                    if (commitWrite(file, gen, slot, bytes, block) != abi.FB_FS_OK) @panic("una escritura planeada no se pudo anotar");
                    written += 1;
                }
            },
        }
        if (status == abi.FB_FS_ERR_STALE) {
            stale += 1;
            if (!std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&table))) @panic("un manejador que no vale cambio la tabla");
        }
        if (!stepByHand(&before, &table)) @panic("una operacion bajo una generacion o cambio un objeto sin subirla");
        checkAfterStep();
        for (dead[0..@min(dead_count, dead.len)]) |handle| {
            var block: u64 = 0;
            if (planWrite(handle[0], handle[1], 0, 1, &block) != abi.FB_FS_ERR_STALE) @panic("el manejador de algo borrado volvio a valer");
        }
    }
    // Y después, llenar el disco: cada archivo crece hasta que no quede sitio.
    var file: u64 = 0;
    var attempts: u64 = 0;
    while (full == 0) : (file = (file + 1) % files) {
        attempts += 1;
        if (attempts > 4 * files * file_blocks) @panic("llenar el disco no termino");
        var result: u64 = 0;
        if (table[file].used != 1) {
            const name = nameOf('m', file);
            if (create(root, &name, kind_file, &result) != abi.FB_FS_OK) continue;
        }
        if (table[file].kind == kind_dir) continue;
        const count = (table[file].length + abi.FB_PAGE_SIZE - 1) / abi.FB_PAGE_SIZE;
        if (count == file_blocks) continue;
        var block: u64 = 0;
        if (planWrite(file, genOf(file), count, abi.FB_PAGE_SIZE, &block) == abi.FB_FS_ERR_FULL) {
            full += 1;
        } else {
            if (commitWrite(file, genOf(file), count, abi.FB_PAGE_SIZE, block) != abi.FB_FS_OK) @panic("una escritura planeada no se pudo anotar");
            written += 1;
        }
        checkAfterStep();
    }
    if (abi.fb_fs_free_blocks(&owners[0]) != 0) @panic("el disco dijo lleno con bloques libres");
    if (created < 20 or dirs < 10 or renamed < 10 or refused < 3 or written < 100 or deleted < 5 or full == 0 or stale < 10 or dead_count < 5) {
        uart.print("creados ");
        uart.printDecimal(created);
        uart.print(", directorios ");
        uart.printDecimal(dirs);
        uart.print(", renombrados ");
        uart.printDecimal(renamed);
        uart.print(", rechazos ");
        uart.printDecimal(refused);
        uart.print(", escritos ");
        uart.printDecimal(written);
        uart.print(", borrados ");
        uart.printDecimal(deleted);
        uart.print(", llenos ");
        uart.printDecimal(full);
        uart.print(", caducados ");
        uart.printDecimal(stale);
        uart.print("\n");
        @panic("la secuencia de operaciones no ejercito todos los casos");
    }
    passed("800 operaciones del nucleo SPARK (archivos, directorios, renombrar, generaciones) y llenar el disco: tras cada paso la tabla se monta, ningun bloque se repite, todo cuelga de la raiz, ninguna generacion baja y nada borrado vuelve a valer con su entrada y su generacion");
}

/// Una tabla válida con dos archivos, en `table`.
fn twoFiles() void {
    format();
    var file_a: u64 = 0;
    var file_b: u64 = 0;
    var block: u64 = 0;
    const name_a = nameOf('a', 1);
    const name_b = nameOf('b', 2);
    _ = create(root, &name_a, kind_file, &file_a);
    _ = create(root, &name_b, kind_file, &file_b);
    for ([_]u64{ file_a, file_a, file_b, file_b }, [_]u64{ 0, 1, 0, 1 }) |file, slot| {
        if (planWrite(file, genOf(file), slot, abi.FB_PAGE_SIZE, &block) != abi.FB_FS_OK) @panic("no se pudo preparar la tabla de dos archivos");
        _ = commitWrite(file, genOf(file), slot, abi.FB_PAGE_SIZE, block);
    }
    if (!mount(&super_block, &table, &rebuilt)) @panic("la tabla de dos archivos no se monta");
}

/// Un superbloque ajeno es un disco sin formato; con el superbloque bueno y la
/// tabla mal, el disco está corrupto. La prueba de cortes de luz distingue
/// los dos: un corte puede dejar el primero, nunca el segundo.
fn expectRejected(what: []const u8, expected: u64) void {
    const status = mountStatus(&super_block, &copy, &rebuilt);
    if (status != expected) {
        uart.print(what);
        uart.print(": estado ");
        uart.printDecimal(status);
        uart.print("\n");
        @panic("montar no rechazo como debia un disco invalido");
    }
}

/// Una entrada de directorio, para escribirla a mano en una tabla.
fn dirEntry(parent: u8, name: [abi.FB_FS_NAME_BYTES]u8) abi.fb_fs_entry {
    var entry = std.mem.zeroes(abi.fb_fs_entry);
    entry.used = 1;
    entry.kind = kind_dir;
    entry.parent = parent;
    entry.name = name;
    return entry;
}

/// Montar rechaza todo disco que rompa el formato: el mismo bloque en dos
/// archivos o dos veces en uno, bloques de los metadatos o fuera del disco,
/// longitudes imposibles, nombres repetidos o que no valen, directorios que
/// no lo son o que forman un ciclo, y un superbloque ajeno. Las entradas
/// libres pueden tener cualquier cosa.
fn testMountRejectsCorruption() void {
    twoFiles();
    const a: usize = 0;
    const b: usize = 1;
    const corrupt = abi.FB_FS_ERR_CORRUPT;
    const unformatted = abi.FB_FS_ERR_UNFORMATTED;

    copy = table;
    copy[b].blocks[0] = copy[a].blocks[1];
    expectRejected("un bloque en dos archivos", corrupt);
    copy = table;
    copy[a].blocks[1] = copy[a].blocks[0];
    expectRejected("un bloque dos veces en un archivo", corrupt);
    copy = table;
    copy[a].blocks[0] = 1;
    expectRejected("un bloque de la tabla", corrupt);
    copy = table;
    copy[a].blocks[0] = 0;
    expectRejected("el superbloque como dato", corrupt);
    copy = table;
    copy[a].blocks[0] = blocks;
    expectRejected("un bloque fuera del sistema de archivos", corrupt);
    copy = table;
    copy[a].length = file_blocks * abi.FB_PAGE_SIZE + 1;
    expectRejected("una longitud demasiado grande", corrupt);
    copy = table;
    copy[a].length = 3 * abi.FB_PAGE_SIZE;
    expectRejected("una longitud con mas bloques que los anotados", corrupt);
    copy = table;
    copy[a].blocks[5] = 77;
    expectRejected("un bloque despues del ultimo", corrupt);
    copy = table;
    copy[a].used = 2;
    expectRejected("una marca de uso desconocida", corrupt);
    copy = table;
    copy[b].name = copy[a].name;
    expectRejected("dos archivos con el mismo nombre", corrupt);
    copy = table;
    copy[a].name[0] = 0;
    expectRejected("un nombre vacio", corrupt);
    copy = table;
    copy[a].name[1] = '/';
    expectRejected("un nombre con barra", corrupt);
    copy = table;
    copy[a].name = nameOf('.', 0);
    copy[a].name[1] = 0;
    copy[a].name[2] = 0;
    expectRejected("el nombre .", corrupt);
    copy[a].name[1] = '.';
    expectRejected("el nombre ..", corrupt);
    copy = table;
    copy[a].name[5] = 'x';
    expectRejected("un nombre con algo tras el final", corrupt);
    copy = table;
    copy[a].kind = 2;
    expectRejected("un tipo desconocido", corrupt);
    copy = table;
    copy[a].kind = kind_dir;
    expectRejected("un directorio con bloques", corrupt);
    copy = table;
    copy[b].parent = @intCast(a);
    expectRejected("un archivo como directorio", corrupt);
    copy = table;
    copy[b].parent = 5;
    expectRejected("un directorio que no existe", corrupt);
    copy = table;
    copy[b].parent = files;
    expectRejected("un directorio fuera de la tabla", corrupt);
    copy = table;
    copy[2] = dirEntry(3, nameOf('d', 2));
    copy[3] = dirEntry(2, nameOf('d', 3));
    expectRejected("dos directorios uno dentro del otro", corrupt);
    copy = table;
    copy[2] = dirEntry(2, nameOf('d', 2));
    expectRejected("un directorio dentro de si mismo", corrupt);
    copy = table;
    copy[2] = dirEntry(root, nameOf('d', 2));
    copy[3] = dirEntry(4, nameOf('d', 3));
    copy[4] = dirEntry(3, nameOf('d', 4));
    copy[b].parent = 4;
    expectRejected("un ciclo que no pasa por la raiz", corrupt);

    const good = super_block;
    copy = table;
    super_block.magic ^= 1;
    expectRejected("otro numero magico", unformatted);
    super_block = good;
    super_block.version += 1;
    expectRejected("otra version", unformatted);
    super_block = good;
    super_block.blocks -= 1;
    expectRejected("otro numero de bloques", unformatted);
    super_block = good;

    // Basura en una entrada libre: no cuenta.
    copy = table;
    copy[5].length = 0xffff_ffff;
    copy[5].blocks[0] = copy[a].blocks[0];
    copy[5].name = copy[a].name;
    if (!mount(&super_block, &copy, &rebuilt)) @panic("una entrada libre con basura impidio montar");
    // El mismo nombre en dos directorios distintos sí vale.
    copy = table;
    copy[2] = dirEntry(root, nameOf('d', 2));
    copy[b].parent = 2;
    copy[b].name = copy[a].name;
    if (!mount(&super_block, &copy, &rebuilt)) @panic("el mismo nombre en dos directorios impidio montar");
    passed("montar rechaza 26 formas de tabla o superbloque invalidos (sin formato o corrupto), ciclos de directorios incluidos, y acepta basura en entradas libres");
}

/// Anotar una escritura exige lo mismo que planearla: siempre un bloque libre,
/// también al reescribir (copia al escribir), y ningún hueco. Al reescribir,
/// el bloque viejo queda libre.
fn testCommitChecksPlan() void {
    twoFiles();
    const used_block = table[1].blocks[0];
    if (commitWrite(0, 0, 2, 10, used_block) != abi.FB_FS_ERR_REQUEST) @panic("se anoto un bloque que ya era de otro archivo");
    const own_block = table[0].blocks[1];
    if (commitWrite(0, 0, 1, 10, own_block) != abi.FB_FS_ERR_REQUEST) @panic("se reescribio un bloque en su sitio");
    if (commitWrite(0, 0, 3, 10, 200) != abi.FB_FS_ERR_REQUEST) @panic("se anoto una escritura con un hueco");
    if (commitWrite(0, 0, 2, 10, 1) != abi.FB_FS_ERR_REQUEST) @panic("se anoto un bloque de la tabla");
    if (commitWrite(0, 1, 2, 10, 200) != abi.FB_FS_ERR_REQUEST) @panic("se anoto una escritura con un manejador que no vale");
    if (!mount(&super_block, &table, &rebuilt)) @panic("tras rechazar, la tabla no se monta");

    // Reescribir la posición 1 en el bloque libre 200: el viejo queda libre.
    const free_before = abi.fb_fs_free_blocks(&owners[0]);
    var planned: u64 = 0;
    if (planWrite(0, 0, 1, 10, &planned) != abi.FB_FS_OK or planned == own_block) @panic("reescribir no planeo un bloque libre");
    if (commitWrite(0, 0, 1, 10, 200) != abi.FB_FS_OK or table[0].blocks[1] != 200) @panic("no se anoto la copia de un bloque");
    if (owners[own_block].used != 0 or owners[200].used != 1) @panic("la copia no libero el bloque viejo");
    if (abi.fb_fs_free_blocks(&owners[0]) != free_before) @panic("la copia cambio los bloques libres");
    if (table[0].length != 2 * abi.FB_PAGE_SIZE) @panic("la copia cambio la longitud");
    checkAfterStep();
    passed("anotar una escritura rechaza bloques ajenos, de metadatos, en su sitio o con huecos; la copia libera el viejo");
}

/// Directorios en el núcleo: a/b/c. Un directorio no puede ir dentro de sí
/// mismo ni de un descendiente, ni borrarse con algo dentro, ni escribirse;
/// renombrar mueve el subárbol entero y solo cambia una entrada.
fn testDirectoryTree() void {
    format();
    var a: u64 = 0;
    var b: u64 = 0;
    var c: u64 = 0;
    var f: u64 = 0;
    const name_a = nameOf('a', 0);
    const name_b = nameOf('b', 0);
    const name_c = nameOf('c', 0);
    const name_f = nameOf('f', 0);
    if (create(root, &name_a, kind_dir, &a) != abi.FB_FS_OK or
        create(a, &name_b, kind_dir, &b) != abi.FB_FS_OK or
        create(b, &name_c, kind_dir, &c) != abi.FB_FS_OK or
        create(c, &name_f, kind_file, &f) != abi.FB_FS_OK) @panic("no se pudo crear a/b/c/f");
    if (depths[a] != 1 or depths[b] != 2 or depths[c] != 3 or depths[f] != 4) @panic("las profundidades de a/b/c/f no son 1, 2, 3, 4");
    var other: u64 = 0;
    if (create(f, &name_a, kind_file, &other) != abi.FB_FS_ERR_NOT_DIR) @panic("se creo algo dentro de un archivo");
    if (create(b, &name_c, kind_file, &other) != abi.FB_FS_ERR_EXISTS or other != c) @panic("se repitio un nombre en un directorio");
    if (create(60, &name_a, kind_file, &other) != abi.FB_FS_ERR_NOT_FOUND) @panic("se creo algo en un directorio que no existe");
    if (create(200, &name_a, kind_file, &other) != abi.FB_FS_ERR_REQUEST) @panic("se creo algo en un directorio fuera de la tabla");
    var block: u64 = 0;
    if (planWrite(c, genOf(c), 0, 10, &block) != abi.FB_FS_ERR_IS_DIR) @panic("se planeo escribir en un directorio");
    if (delete(b, genOf(b)) != abi.FB_FS_ERR_NOT_EMPTY) @panic("se borro un directorio con algo dentro");

    // Ciclos: a dentro de c, de b o de sí mismo. La tabla no cambia.
    const before = table;
    const depths_before = depths;
    for ([_]u64{ c, b, a }) |target| {
        if (rename(a, genOf(a), target, &name_a) != abi.FB_FS_ERR_REQUEST) @panic("un directorio fue a parar dentro de si mismo");
    }
    if (!std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&table)) or !std.mem.eql(u8, &depths_before, &depths)) @panic("un renombrado rechazado cambio la tabla");

    // c sube a la raíz con f dentro: solo cambia la entrada de c, y las
    // profundidades de c y f.
    if (rename(c, genOf(c), root, &name_c) != abi.FB_FS_OK) @panic("no se pudo subir c a la raiz");
    for (table, before, 0..) |now, old, index| {
        const same = std.mem.eql(u8, std.mem.asBytes(&now), std.mem.asBytes(&old));
        if (same != (index != c)) @panic("renombrar cambio otra entrada");
    }
    if (depths[c] != 1 or depths[f] != 2 or depths[b] != 2) @panic("renombrar no recalculo las profundidades");
    // Y ahora a sí puede ir dentro de c: c ya no cuelga de a.
    if (rename(a, genOf(a), c, &name_a) != abi.FB_FS_OK or depths[b] != 3) @panic("no se pudo meter a en c");
    checkAfterStep();
    passed("directorios en el nucleo: sin ciclos ni nombres repetidos, no se borran con algo dentro, y renombrar mueve el subarbol cambiando una sola entrada");
}

/// Manejadores en el núcleo (Hito 38). Borrar sube la generación y la
/// entrada se reutiliza con la nueva; renombrar la conserva; una entrada que
/// llega a la última generación se retira; formatear sube todas (o empieza
/// en 0 sin tabla de antes); listar exige un directorio que valga.
fn testHandles() void {
    format();
    const name_a = nameOf('a', 0);
    const name_b = nameOf('b', 0);
    var a: u64 = 0;
    var b: u64 = 0;
    var block: u64 = 0;
    if (create(root, &name_a, kind_file, &a) != abi.FB_FS_OK or a != 0 or genOf(a) != 0) @panic("el primer archivo no fue la entrada 0 con generacion 0");
    if (planWrite(a, 0, 0, 10, &block) != abi.FB_FS_OK or commitWrite(a, 0, 0, 10, block) != abi.FB_FS_OK) @panic("no se pudo escribir con un manejador que vale");
    if (delete(a, 1) != abi.FB_FS_ERR_STALE or table[a].used != 1) @panic("se borro con un manejador que no vale");
    if (delete(a, 0) != abi.FB_FS_OK or table[a].gen != 1) @panic("borrar no subio la generacion");
    // La entrada 0 se reutiliza con la generación 1: el manejador (0, 0) no
    // vale para nada.
    if (create(root, &name_b, kind_file, &b) != abi.FB_FS_OK or b != 0 or genOf(b) != 1) @panic("crear no conservo la generacion de la entrada libre");
    if (planWrite(0, 0, 0, 10, &block) != abi.FB_FS_ERR_STALE or delete(0, 0) != abi.FB_FS_ERR_STALE or rename(0, 0, root, &name_a) != abi.FB_FS_ERR_STALE) @panic("un manejador viejo valio para la entrada reutilizada");
    var listed: u64 = 0;
    if (nextIn(root, 0, 0, &listed) != abi.FB_FS_OK or listed != b) @panic("no se listo la raiz");
    if (nextIn(root, 1, 0, &listed) != abi.FB_FS_ERR_REQUEST or listed != files) @panic("se listo la raiz con otra generacion");
    if (nextIn(b, 1, 0, &listed) != abi.FB_FS_ERR_NOT_DIR) @panic("se listo un archivo");
    if (nextIn(b, 0, 0, &listed) != abi.FB_FS_ERR_STALE) @panic("se listo con un manejador que no vale");
    if (nextIn(files, 0, 0, &listed) != abi.FB_FS_ERR_REQUEST) @panic("se listo un directorio fuera de la tabla");
    // Renombrar conserva la generación.
    if (rename(b, 1, root, &name_a) != abi.FB_FS_OK or genOf(b) != 1) @panic("renombrar cambio la generacion");

    // Retirada: con la penúltima generación, borrar la deja en la última y
    // la entrada no se vuelve a usar.
    table[b].gen = gen_last - 1;
    if (!mount(&super_block, &table, &rebuilt)) @panic("una entrada con la penultima generacion no se monto");
    if (delete(b, gen_last - 1) != abi.FB_FS_OK or table[b].gen != gen_last) @panic("borrar no llevo la generacion a la ultima");
    var count: u64 = 0;
    var other: u64 = 0;
    while (count < files - 1) : (count += 1) {
        const name = nameOf('m', count);
        if (create(root, &name, kind_file, &other) != abi.FB_FS_OK or other == b) @panic("se reutilizo una entrada retirada");
    }
    const extra = nameOf('x', 0);
    if (create(root, &extra, kind_file, &other) != abi.FB_FS_ERR_FULL) @panic("con todas las demas en uso, se uso la retirada");
    checkAfterStep();

    // Una entrada en uso con la última generación es un disco corrupto.
    copy = table;
    copy[b] = copy[1];
    copy[b].name = nameOf('z', 0);
    copy[b].length = 0;
    copy[b].blocks = [_]u16{0} ** file_blocks;
    copy[b].gen = gen_last;
    expectRejected("una entrada en uso con la ultima generacion", abi.FB_FS_ERR_CORRUPT);
    copy[b].gen = gen_last - 1;
    if (mountStatus(&super_block, &copy, &rebuilt) != abi.FB_FS_OK) @panic("una entrada en uso con la penultima generacion no se monto");

    // Formatear con la tabla de antes: cada generación sube uno, la retirada
    // sigue retirada. Sin ella, todas en 0.
    table[5].gen = 41;
    const old_one = table[1].gen;
    formatKeeping(1);
    if (table[5].gen != 42 or table[1].gen != old_one + 1 or table[b].gen != gen_last or table[1].used != 0) @panic("formatear no subio las generaciones");
    if (!mount(&super_block, &table, &rebuilt)) @panic("tras formatear conservando, la tabla no se monta");
    format();
    for (table) |entry| {
        if (entry.gen != 0) @panic("formatear sin tabla de antes no empezo en 0");
    }
    passed("generaciones en el nucleo: borrar sube la generacion, la entrada se reutiliza sin que valga la generacion vieja, renombrar la conserva, la ultima generacion retira la entrada y formatear las sube todas");
}

// ---------------------------------------------------------------------------
// Manejadores por cliente (Hito 39): Fs_Handles frente a un modelo.

const Handles = [abi.FB_FS_CLIENTS]abi.fb_fs_client;
const max_open = abi.FB_FS_MAX_OPEN;

comptime {
    // El mismo tamaño que en fs_handles.ads: 8 + 16 x 16 bytes por cliente.
    if (@sizeOf(abi.fb_fs_client) != 8 + max_open * 16) @compileError("fb_fs_client no coincide con Fs_Handles.Client_Record");
}

var handle_table: Handles = undefined;

const OpenModel = struct { used: bool = false, file: u64 = 0, gen: u64 = 0 };
const ClientModel = struct {
    bound: bool = false,
    opens: [max_open]OpenModel = [_]OpenModel{.{}} ** max_open,

    fn lowestFree(self: *const ClientModel) ?u64 {
        for (self.opens, 0..) |open, index| {
            if (!open.used) return index;
        }
        return null;
    }
};

/// Lo que promete Only_Client, comprobado a mano: solo cambia la fila de la
/// marca que pide (que sigue siendo suya o queda libre) o una libre que pasa
/// a ser suya; sin marca, nada.
fn onlyClientByHand(old: *const Handles, new: *const Handles, badge: u64) bool {
    for (old, new) |before, after| {
        if (std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&after))) continue;
        if (badge == 0) return false;
        const mine = (before.badge == badge and (after.badge == badge or after.badge == 0)) or
            (before.badge == 0 and after.badge == badge);
        if (!mine) return false;
    }
    return true;
}

/// Table_Ok a mano: una fila libre no tiene nada abierto, lo abierto nombra
/// una entrada y ninguna marca tiene dos filas.
fn handlesOkByHand(handles: *const Handles) bool {
    for (handles, 0..) |row, index| {
        for (row.opens) |open| {
            if (open.used != 0 and (row.badge == 0 or open.file >= files)) return false;
        }
        if (row.badge == 0) continue;
        for (handles[index + 1 ..]) |other| {
            if (other.badge == row.badge) return false;
        }
    }
    return true;
}

fn resolveHandle(badge: u64, handle: u64, file: *u64, gen: *u64) u64 {
    var status: u64 = 0;
    abi.fb_fs_resolve(&handle_table[0], badge, handle, file, gen, &status);
    return status;
}

/// Lo que cada cliente ve en cada manejador es lo del modelo.
fn handlesMatchModel(badges: []const u64, model: []const ClientModel) bool {
    var bound: u64 = 0;
    for (badges, model) |badge, client| {
        if (client.bound) bound += 1;
        for (client.opens, 0..) |open, handle| {
            var file: u64 = 0;
            var gen: u64 = 0;
            const status = resolveHandle(badge, handle, &file, &gen);
            const expected: u64 = if (badge == 0) abi.FB_FS_ERR_DENIED else if (open.used) abi.FB_FS_OK else abi.FB_FS_ERR_BAD_HANDLE;
            if (status != expected) return false;
            if (open.used and (file != open.file or gen != open.gen)) return false;
        }
    }
    var rows: u64 = 0;
    for (handle_table) |row| {
        if (row.badge != 0) rows += 1;
    }
    return rows == bound;
}

/// Una secuencia aleatoria de 4000 peticiones de seis clientes (cinco
/// marcas, una de ellas la más alta, y uno sin marca) frente a un modelo de
/// lo que cada cliente tiene abierto. Caben cuatro clientes: el quinto
/// espera a que otro se despida.
fn testClientHandles() void {
    const badges = [_]u64{ 0, 0x39_0001, 0x39_0002, 0xffff_ffff_ffff_ffff, 1, 0x8000_0000_0000_0000 };
    var model = [_]ClientModel{.{}} ** badges.len;
    abi.fb_fs_handles_clear(&handle_table[0]);
    var seed: u64 = 0x39_5eed;
    var opened: u64 = 0;
    var resolved: u64 = 0;
    var closed: u64 = 0;
    var detached: u64 = 0;
    var bad: u64 = 0;
    var denied: u64 = 0;
    var no_slot: u64 = 0;
    var no_row: u64 = 0;
    var refused: u64 = 0;
    var step: u64 = 0;
    while (step < 4000) : (step += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const random = seed >> 24;
        const who: usize = @intCast(random % badges.len);
        const badge = badges[who];
        const client = &model[who];
        // Casi siempre un manejador posible; a veces uno fuera de rango.
        const handle: u64 = switch ((random >> 8) % 8) {
            0 => random >> 12,
            1 => max_open,
            else => (random >> 12) % max_open,
        };
        const file: u64 = if ((random >> 20) % 16 == 0) files + (random >> 24) % 3 else (random >> 24) % files;
        const gen: u64 = if ((random >> 30) % 32 == 0) 1 << 32 else (random >> 30) % 1000;
        const before = handle_table;
        var status: u64 = 0;
        switch ((random >> 4) % 32) {
            0...13 => {
                const bound_count = blk: {
                    var count: u64 = 0;
                    for (model) |other| count += @intFromBool(other.bound);
                    break :blk count;
                };
                const free = client.lowestFree();
                const room = badge != 0 and (if (client.bound) free != null else bound_count < abi.FB_FS_CLIENTS);
                if ((abi.fb_fs_room(&handle_table[0], badge) == 1) != room) @panic("Room no dice lo que el modelo");
                var got: u64 = 0;
                abi.fb_fs_open(&handle_table[0], badge, file, gen, &got, &status);
                const expected: u64 = if (badge == 0) abi.FB_FS_ERR_DENIED else if (file >= files or gen > 0xffff_ffff) abi.FB_FS_ERR_REQUEST else if (!room) abi.FB_FS_ERR_HANDLES else abi.FB_FS_OK;
                if (status != expected) @panic("abrir no contesto lo que el modelo");
                if (status == abi.FB_FS_OK) {
                    // El manejador libre más bajo, como un descriptor de Linux.
                    const slot: u64 = if (client.bound) free.? else 0;
                    if (got != slot) @panic("abrir no dio el manejador libre mas bajo");
                    client.bound = true;
                    client.opens[slot] = .{ .used = true, .file = file, .gen = gen };
                    opened += 1;
                }
                if (status == abi.FB_FS_ERR_HANDLES) {
                    if (client.bound) no_slot += 1 else no_row += 1;
                }
                if (status == abi.FB_FS_ERR_REQUEST) refused += 1;
            },
            14...22 => {
                var found_file: u64 = 0;
                var found_gen: u64 = 0;
                status = resolveHandle(badge, handle, &found_file, &found_gen);
                if (status == abi.FB_FS_OK) resolved += 1;
            },
            23...30 => {
                abi.fb_fs_close(&handle_table[0], badge, handle, &status);
                const expected: u64 = if (badge == 0) abi.FB_FS_ERR_DENIED else if (handle < max_open and client.opens[handle].used) abi.FB_FS_OK else abi.FB_FS_ERR_BAD_HANDLE;
                if (status != expected) @panic("cerrar no contesto lo que el modelo");
                if (status == abi.FB_FS_OK) {
                    client.opens[handle].used = false;
                    closed += 1;
                }
            },
            else => {
                abi.fb_fs_detach(&handle_table[0], badge);
                if (badge != 0) {
                    client.* = .{};
                    detached += 1;
                }
            },
        }
        if (status == abi.FB_FS_ERR_BAD_HANDLE) bad += 1;
        if (status == abi.FB_FS_ERR_DENIED) denied += 1;
        if (status != abi.FB_FS_OK and !std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&handle_table))) @panic("una peticion rechazada cambio la tabla de manejadores");
        if (!handlesOkByHand(&handle_table)) @panic("la tabla de manejadores dejo de ser valida");
        if (!onlyClientByHand(&before, &handle_table, badge)) @panic("un cliente cambio la fila de otro");
        if (!handlesMatchModel(&badges, &model)) @panic("un cliente ve algo distinto de lo que abrio");
    }

    // Después, a propósito: un cliente con sus 16 manejadores, y un quinto
    // cliente sin fila hasta que otro se despide.
    for (&model, badges) |*client, badge| {
        abi.fb_fs_detach(&handle_table[0], badge);
        client.* = .{};
    }
    var handle: u64 = 0;
    while (handle < max_open) : (handle += 1) {
        var got: u64 = 0;
        var status: u64 = 0;
        abi.fb_fs_open(&handle_table[0], badges[1], handle, 7, &got, &status);
        if (status != abi.FB_FS_OK or got != handle) @panic("un cliente no pudo abrir sus 16 manejadores");
    }
    if (abi.fb_fs_room(&handle_table[0], badges[1]) != 0) @panic("Room vio sitio con 16 manejadores abiertos");
    for (badges[2..5]) |badge| {
        if (abi.fb_fs_room(&handle_table[0], badge) != 1) @panic("Room no vio una fila libre");
        var got: u64 = 0;
        var status: u64 = 0;
        abi.fb_fs_open(&handle_table[0], badge, 1, 1, &got, &status);
        if (status != abi.FB_FS_OK or got != 0) @panic("un cliente nuevo no tomo una fila libre");
    }
    if (abi.fb_fs_room(&handle_table[0], badges[5]) != 0) @panic("Room vio una fila con cuatro clientes");
    abi.fb_fs_detach(&handle_table[0], badges[3]);
    if (abi.fb_fs_room(&handle_table[0], badges[5]) != 1) @panic("despedirse no libero la fila");
    var file: u64 = 0;
    var gen: u64 = 0;
    if (resolveHandle(badges[3], 0, &file, &gen) != abi.FB_FS_ERR_BAD_HANDLE) @panic("tras despedirse un manejador siguio abierto");
    if (resolveHandle(badges[1], max_open - 1, &file, &gen) != abi.FB_FS_OK or file != max_open - 1 or gen != 7) @panic("despedirse cerro los de otro");

    if (opened < 500 or resolved < 200 or closed < 100 or detached < 30 or bad < 200 or denied < 50 or no_slot == 0 or no_row < 5 or refused < 20) {
        uart.print("abiertos ");
        uart.printDecimal(opened);
        uart.print(", resueltos ");
        uart.printDecimal(resolved);
        uart.print(", cerrados ");
        uart.printDecimal(closed);
        uart.print(", despedidas ");
        uart.printDecimal(detached);
        uart.print(", no abiertos ");
        uart.printDecimal(bad);
        uart.print(", sin marca ");
        uart.printDecimal(denied);
        uart.print(", sin manejador ");
        uart.printDecimal(no_slot);
        uart.print(", sin fila ");
        uart.printDecimal(no_row);
        uart.print(", rechazos ");
        uart.printDecimal(refused);
        uart.print("\n");
        @panic("la secuencia de manejadores no ejercito todos los casos");
    }
    passed("4000 peticiones a la tabla de manejadores (SPARK) de seis clientes, uno sin marca: cada uno ve justo lo que abrio, nadie cambia la fila de otro, 16 manejadores por cliente y 4 clientes");
}

// ---------------------------------------------------------------------------
// El servidor de archivos de extremo a extremo.

fn regionCap(slot: u64, number: u64, rights: u64) process.Grant {
    return .{ .slot = slot, .kind = abi.FB_CAP_REGION, .object = region.object(number), .rights = rights };
}

fn createOrPanic(pages: u64) u64 {
    return region.create(pages) orelse @panic("no se pudo crear una region para el sistema de archivos");
}

fn spawnOrPanic(target: u64, program: process.Program, argument: u64, grants: []const process.Grant) u64 {
    return process.spawnWithOn(target, program, argument, grants) orelse @panic("no se pudo crear el proceso");
}

/// Espera con las interrupciones encendidas: las del disco llegan al hart 0.
fn waitDone(id: u64) process.Result {
    const limit = timer.now() + 60 * abi.FB_TIMEBASE_HZ;
    riscv.enableInterrupts();
    defer riscv.disableInterrupts();
    while (thread.isAlive(id)) {
        if (timer.now() > limit) @panic("un proceso del sistema de archivos no termino");
        thread.yield();
    }
    return process.resultOf(id);
}

fn expectExit(id: u64, what: []const u8) void {
    const result = waitDone(id);
    if (result.kind != .exited or result.value != 0) {
        uart.print(what);
        uart.print(": tipo ");
        uart.print(@tagName(result.kind));
        uart.print(", paso ");
        uart.printDecimal(result.value >> 8);
        uart.print(", estado ");
        uart.printHex(result.value & 0xff);
        uart.print("\n");
        @panic("un proceso del sistema de archivos termino mal");
    }
}

const client_pages: u64 = 4;
const requests_endpoint: u64 = 2;

fn startServer(target: u64, meta: u64, data: u64) u64 {
    return spawnOrPanic(target, .fs_server, client_pages, &.{
        selftest_ipc.endpoint(0, requests_endpoint, recv),
        selftest_ipc.endpoint(1, 0, send),
        regionCap(2, meta, send | recv),
        regionCap(3, data, send | recv),
    });
}

/// Marcas de los clientes del servidor de archivos: las pone el kernel.
const badge_check: u64 = 0x39_a000;
const badge_crash: u64 = 0x39_c000;

/// El cliente de prueba hace de cinco clientes (las marcas A..E) y de uno
/// sin marca, con el mismo endpoint.
fn startClient(argument: u64, data: u64) u64 {
    return spawnOrPanic(0, .fs_check, argument, &.{
        selftest_ipc.badged(0, requests_endpoint, send, badge_check),
        regionCap(1, data, send | recv),
        selftest_ipc.badged(2, requests_endpoint, send, badge_check + 1),
        selftest_ipc.endpoint(3, requests_endpoint, send),
        selftest_ipc.badged(4, requests_endpoint, send, badge_check + 2),
        selftest_ipc.badged(5, requests_endpoint, send, badge_check + 3),
        selftest_ipc.badged(6, requests_endpoint, send, badge_check + 4),
    });
}

/// Un cliente formatea, crea, escribe, lee, lista, borra y llena el disco a
/// través del servidor en Rust y el driver; los datos van por DMA a su región.
/// Después otros tres servidores, uno tras otro, montan el mismo disco y
/// encuentran lo escrito, lo creado, lo borrado y lo ampliado. Al final todo se para y los
/// marcos vuelven.
fn testFileSystemThroughServer(harts: u64) void {
    const frames_before = selftest_user.poisonFreeFrames();
    const queue = createOrPanic(1);
    const meta = createOrPanic(abi.FB_FS_META_PAGES);
    const data = createOrPanic(client_pages);
    const far = harts - 1;
    const driver = spawnOrPanic(far, .disk_driver, 0, &.{
        selftest_ipc.endpoint(0, 0, recv),
        .{ .slot = 1, .kind = abi.FB_CAP_DEVICE, .object = abi.FB_DEVICE_DISK, .rights = send | recv },
        selftest_ipc.endpoint(2, 1, recv),
        regionCap(3, queue, send | recv),
        regionCap(4, meta, send | recv),
        regionCap(5, data, send | recv),
    });

    const first_server = startServer(far, meta, data);
    expectExit(startClient(1, data), "cliente, primera pasada");
    expectExit(first_server, "primer servidor");

    // Otro servidor, sin nada en memoria: lo que hay lo lee del disco. Borra
    // el archivo vacío que dejó el primero, y un tercero ya no lo encuentra.
    const second_server = startServer(0, meta, data);
    expectExit(startClient(2, data), "cliente, segunda pasada");
    expectExit(second_server, "segundo servidor");
    const third_server = startServer(far, meta, data);
    expectExit(startClient(3, data), "cliente, tercera pasada");
    expectExit(third_server, "tercer servidor");
    // El tercero amplía "hello" como lo último que hace; un cuarto lo ve.
    const fourth_server = startServer(0, meta, data);
    expectExit(startClient(4, data), "cliente, cuarta pasada");
    expectExit(fourth_server, "cuarto servidor");
    expectExit(driver, "driver del disco");

    region.release(queue);
    region.release(meta);
    region.release(data);
    if (device.ownerOf(abi.FB_DEVICE_DISK) != 0) @panic("el disco siguio teniendo dueno");
    if (device.diskStatus() != 0) @panic("el disco no quedo reiniciado");
    if (region.alive(queue) or region.alive(meta) or region.alive(data)) @panic("las regiones del sistema de archivos siguieron vivas");
    if (selftest_user.poisonFreeFrames() != frames_before) @panic("el sistema de archivos perdio marcos");
    passed(if (harts > 1)
        "sistema de archivos en Rust con nucleo SPARK (driver en otro hart): crear, escribir, leer, borrar, directorios, renombrar, generaciones, manejadores de cada cliente, llenar y montar de nuevo"
    else
        "sistema de archivos en Rust con nucleo SPARK: crear, escribir, leer, borrar, directorios, renombrar, generaciones, manejadores de cada cliente, llenar y montar de nuevo");
}

// ---------------------------------------------------------------------------
// Cortes de luz (Hito 36).

fn startCrashClient(argument: u64, data: u64) u64 {
    return spawnOrPanic(0, .fs_crash, argument, &.{
        selftest_ipc.badged(0, requests_endpoint, send, badge_crash),
        regionCap(1, data, send | recv),
        selftest_ipc.endpoint(2, 0, send),
    });
}

// Lo mismo que en tests/fs_crash.rs.
const crash_run: u64 = 1;
const crash_check: u64 = 2;
const crash_check_any: u64 = 3;
const crash_transient: u64 = 4;
const crash_after_transient: u64 = 5;
const crash_junk: u64 = 6;
const crash_result: u64 = 1 << 40;
const crash_operations: u64 = 21;

/// Basura en el superbloque y la tabla, con un servidor que después para: el
/// siguiente encuentra el disco sin formato y formatea con generaciones 0.
fn junkDisk(target: u64, meta: u64, data: u64) void {
    const server = startServer(target, meta, data);
    expectExit(startCrashClient(crash_junk, data), "basura en el disco");
    expectExit(server, "servidor de la basura");
}

/// Espera a un cliente de la prueba de cortes y devuelve lo que contestó.
fn expectResult(id: u64, what: []const u8, point: u64) u64 {
    const result = waitDone(id);
    if (result.kind != .exited or result.value & crash_result == 0) {
        uart.print(what);
        uart.print(" (punto ");
        uart.printHex(point);
        uart.print("): tipo ");
        uart.print(@tagName(result.kind));
        uart.print(", paso ");
        uart.printHex(result.value >> 8);
        uart.print(", valor ");
        uart.printHex(result.value & 0xff);
        uart.print("\n");
        @panic("la prueba de cortes de luz encontro un disco que no es ni el de antes ni el de despues");
    }
    return result.value & 0xffff;
}

/// Cada operación del sistema de archivos es atómica frente a un corte de
/// luz. Una carga fija (formatear desde un disco con basura, crear,
/// escribir, reescribir, borrar y reutilizar) se corta en cada sector que
/// escribe: tras 0, 1, 2... sectores. La escritura que cruza el límite llega
/// al disco a medias (sus primeros sectores; y, en otra vuelta, sus últimos).
/// Después, un servidor nuevo monta el disco y el cliente comprueba que está
/// en el estado de antes de la operación cortada o en el de después, con los
/// datos de cada archivo. Al final, un fallo pasajero: si falla la escritura
/// de la tabla, el servidor deja de atender y el disco sigue como estaba.
fn testCrashConsistency(harts: u64) void {
    const frames_before = selftest_user.poisonFreeFrames();
    const queue = createOrPanic(1);
    const meta = createOrPanic(abi.FB_FS_META_PAGES);
    const data = createOrPanic(client_pages);
    const far = harts - 1;
    const driver = spawnOrPanic(far, .disk_driver, 0, &.{
        selftest_ipc.endpoint(0, 0, recv),
        .{ .slot = 1, .kind = abi.FB_CAP_DEVICE, .object = abi.FB_DEVICE_DISK, .rights = send | recv },
        selftest_ipc.endpoint(2, 1, recv),
        regionCap(3, queue, send | recv),
        regionCap(4, meta, send | recv),
        regionCap(5, data, send | recv),
    });

    var points: u64 = 0;
    var before: u64 = 0;
    var after: u64 = 0;
    // Basura una vez; después la deja cada comprobación para la vuelta
    // siguiente.
    junkDisk(far, meta, data);
    for ([_]u64{ abi.FB_DISK_TEAR_FIRST, abi.FB_DISK_TEAR_LAST }) |tear| {
        var sectors: u64 = 0;
        while (true) : (sectors += 1) {
            // Con un número entero de páginas no hay escritura a medias: ya
            // se probó con la primera forma.
            if (tear == abi.FB_DISK_TEAR_LAST and sectors % abi.FB_DISK_SECTORS_PER_PAGE == 0) continue;
            const point = tear << 32 | sectors;
            const server = startServer(if (sectors % 2 == 0) far else 0, meta, data);
            const failed_at = expectResult(startCrashClient(crash_run | tear << 8 | sectors << 16, data), "correr hasta el corte", point);
            expectExit(server, "servidor del corte");
            const checker = startServer(0, meta, data);
            const state = expectResult(startCrashClient(crash_check | failed_at << 8, data), "montar tras el corte", point);
            expectExit(checker, "servidor tras el corte");
            points += 1;
            if (state == failed_at + 1) after += 1 else before += 1;
            if (failed_at == crash_operations) break;
        }
    }

    const server = startServer(far, meta, data);
    expectExit(startCrashClient(crash_transient, data), "fallo pasajero");
    expectExit(server, "servidor del fallo pasajero");
    const last = startServer(0, meta, data);
    expectExit(startCrashClient(crash_after_transient, data), "montar tras el fallo pasajero");
    expectExit(last, "servidor tras el fallo pasajero");
    expectExit(driver, "driver del disco");

    region.release(queue);
    region.release(meta);
    region.release(data);
    if (device.ownerOf(abi.FB_DEVICE_DISK) != 0) @panic("el disco siguio teniendo dueno");
    if (selftest_user.poisonFreeFrames() != frames_before) @panic("la prueba de cortes perdio marcos");
    // Los dos desenlaces deben haber salido: si todo corte dejara el estado
    // de antes (o el de después), la prueba no estaría mirando lo que cree.
    if (before == 0 or after == 0 or points < 2 * crash_operations) @panic("la prueba de cortes no ejercito los dos desenlaces");
    uart.print("cortes de luz: ");
    uart.printDecimal(points);
    uart.print(" puntos, ");
    uart.printDecimal(before);
    uart.print(" con el estado de antes y ");
    uart.printDecimal(after);
    uart.print(" con el de despues\n");
    passed("cada operacion del sistema de archivos es atomica ante un corte de luz en cualquier sector, y un fallo pasajero no deja la tabla desfasada");
}

/// Cortes de verdad: QEMU se mata desde fuera en un momento cualquiera
/// mientras esto repite la carga de tests/fs_crash.rs (sin corte simulado).
/// Cada vuelta empieza con basura en el superbloque y la tabla.
pub fn killLoop(harts: u64) noreturn {
    const queue = createOrPanic(1);
    const meta = createOrPanic(abi.FB_FS_META_PAGES);
    const data = createOrPanic(client_pages);
    _ = spawnOrPanic(harts - 1, .disk_driver, 0, &.{
        selftest_ipc.endpoint(0, 0, recv),
        .{ .slot = 1, .kind = abi.FB_CAP_DEVICE, .object = abi.FB_DEVICE_DISK, .rights = send | recv },
        selftest_ipc.endpoint(2, 1, recv),
        regionCap(3, queue, send | recv),
        regionCap(4, meta, send | recv),
        regionCap(5, data, send | recv),
    });
    var round: u64 = 1;
    while (true) : (round += 1) {
        junkDisk(0, meta, data);
        const server = startServer(0, meta, data);
        const done = expectResult(startCrashClient(crash_run | 0xffff_ffff << 16, data), "vuelta sin corte", round);
        if (done != crash_operations) @panic("una vuelta sin corte no termino la carga");
        expectExit(server, "servidor de la vuelta");
        uart.print("vuelta ");
        uart.printDecimal(round);
        uart.print("\n");
    }
}

/// Tras matar QEMU: el disco debe estar en uno de los estados de la carga.
pub fn killCheck(harts: u64) void {
    const queue = createOrPanic(1);
    const meta = createOrPanic(abi.FB_FS_META_PAGES);
    const data = createOrPanic(client_pages);
    const driver = spawnOrPanic(harts - 1, .disk_driver, 0, &.{
        selftest_ipc.endpoint(0, 0, recv),
        .{ .slot = 1, .kind = abi.FB_CAP_DEVICE, .object = abi.FB_DEVICE_DISK, .rights = send | recv },
        selftest_ipc.endpoint(2, 1, recv),
        regionCap(3, queue, send | recv),
        regionCap(4, meta, send | recv),
        regionCap(5, data, send | recv),
    });
    const server = startServer(0, meta, data);
    const state = expectResult(startCrashClient(crash_check_any, data), "montar tras matar QEMU", 0);
    expectExit(server, "servidor tras matar QEMU");
    expectExit(driver, "driver del disco");
    uart.print("estado ");
    uart.printDecimal(state);
    uart.print("\n");
}

pub fn run(harts: u64) void {
    testFormatMounts();
    testOperationsKeepTableValid();
    testMountRejectsCorruption();
    testCommitChecksPlan();
    testDirectoryTree();
    testHandles();
    testClientHandles();
    testFileSystemThroughServer(harts);
    testCrashConsistency(harts);
}

const std = @import("std");
