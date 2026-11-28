# Fabianus — changelog

A from-scratch kernel for 64-bit RISC-V (rv64imac, QEMU `virt`, no firmware).
Every milestone is delivered with three kinds of backing: a mathematical
foundation, verification (what is proved and what is only tested) and
experimental evidence.

- **Languages:** Zig (core), Ada/SPARK (proved parts), assembly, Rust (UART
  and disk drivers and the file system server, as user processes), C
  (common ABI and Linux comparison).
  D and VHDL are decided but not used yet.
- **License:** GPL-3.0-or-later. Every source file carries the line
  `SPDX-License-Identifier: GPL-3.0-or-later`.
- **Instructions per operation:** measured in QEMU with `-icount`.
- **"Proved":** checked by GNATprove over the whole SPARK code base, as a
  mandatory gate before compiling.

---

## Milestone 39 — Handles that belong to one client

- **Goal:** in milestone 38 a handle was the table entry and its
  generation. Any client that knew both could build a handle without ever
  looking the file up, and use it. Now a handle is a small number that the
  file system server gives to one client, like a Linux file descriptor, and
  that is worth nothing to any other client.
- **Badges (kernel):** every capability carries a 64-bit badge. Only the
  kernel sets it, when it grants the capability; deriving and transferring
  keep it. When a server receives a message, the kernel puts in `a6` the
  badge of the capability the sender used. So the server knows which client
  is calling, and a client cannot pretend to be another.
  - The badge is read when the message is sent, so a sender waiting in the
    queue keeps the badge it sent with.
  - User programs that receive messages now treat `a6` as overwritten by
    `recv`; the UART and disk drivers were updated.
- **Handles (server):** a new SPARK package, `Fs_Handles`, keeps one row per
  client badge (4 clients, 16 handles each), with the entry and generation
  that each open handle names.
  - `LOOKUP` and `CREATE` open a handle (the lowest free one, as in Linux),
    `CLOSE` releases it, `DETACH` releases all of a client's handles and its
    row. `STAT` gives what a handle names: its number (entry and
    generation), length and kind. `LIST` gives numbers, not handles.
  - A handle that the client has not opened answers the new error
    `BAD_HANDLE`, even if another client has it open. A request without a
    badge answers `DENIED`; no free handle or row, `HANDLES`.
  - The generation check of milestone 38 still runs on every use: a handle
    open on something deleted answers `STALE` until it is closed.
  - `CREATE` first checks that the client can open one more handle (`Room`),
    so it never creates a file that it then could not hand back.
  - The root is the handle `FB_FS_ROOT` for every client.
- **Proved in SPARK:**
  - `Cap_Core`: `Subsumes` now requires the same badge, so `Covered` (no
    operation a process can ask for creates authority) also covers badges.
    `Lemma_Badges_Kept`: after any such operation, every capability carries
    a badge that some capability already had.
  - `Fs_Handles`: `Resolve` answers only what the same badge has open in
    that handle (`Holds`). Every operation is a step `Only_Client`: it
    changes only the row of the badge that asks, or a free row that becomes
    its own. `Lemma_Only_Owner`: in any history of such steps, if a client
    ends up holding something in a handle that it did not hold there at the
    start, one of the steps was a request with its badge. `Open` gives the
    lowest free handle and succeeds whenever `Room` says so.
  - `Fs_Core.Stat` answers only for a valid entry and generation.
- **Tests:**
  - kernel: badges are kept by derive and transfer and cleared with the
    capability;
  - kernel: 4000 random requests to `Fs_Handles` from six clients (five
    badges, one of them the highest, and one without a badge), checked after
    each step against a model of what each client has open, with
    `Only_Client` and the table invariant checked by hand; then a client
    with its 16 handles open and a fifth client without a row;
  - through the server, one process acts as five clients and one without a
    badge (several capabilities to the same endpoint): a second
    client cannot read, write, delete, rename, list, stat or close with
    any handle of the first, even with the same number; each client's
    handle 0 is its own; the unbadged capability is `DENIED` for everything,
    including `FORMAT` and `STOP`; with 16 handles open, `LOOKUP` and
    `CREATE` answer `HANDLES` and nothing is created; a fifth client waits
    until another one sends `DETACH`, which closes only that client's
    handles; a handle open on a file that another client deletes answers
    `STALE` until it is closed;
  - the earlier tests now open and close their handles; a new server has
    no handle open; formatting makes an open handle stale;
  - power cuts: the model now checks the number (entry and generation) of
    every object with `STAT`. Open handles do not survive the server, so
    the check of milestone 38 on handles of deleted objects is replaced by
    this one: an object created in a reused entry must have the next
    generation. 467 cuts
    per boot: 320 left the state before the operation and 147 the state
    after.
- **Measurements** (`-icount`, 4 harts, median of 5 runs; Linux 6.12 in the
  same QEMU, files in the initramfs):

  | Operation | Fabianus | Linux |
  |---|---|---|
  | Open and close, path of one name | 6667 ns (`LOOKUP` + `CLOSE`) | 7873 ns (`open` + `close`) |
  | Open and close, path of 4 names | 8503 ns (`LOOKUP` + `CLOSE`) | 8804 ns (`open` + `close`) |
  | Use a handle without the disk | 2785 ns (`STAT`) | 1661 ns (`fstat`) |

  - Opening now keeps state, as in Linux, so it costs two round trips to
    the server (`LOOKUP` and `CLOSE`) instead of one: one name went from
    3891 to 6667 ns, 4 names from 5674 to 8503 ns. Both are still a little
    cheaper than Linux's `open` + `close` (15% and 3%).
  - `STAT` is one round trip plus finding the client's row: 2785 ns, 1.7
    times Linux's `fstat`, which does not leave the process. In milestone
    38 the same round trip with a stale handle cost 2700 ns.
  - Operations that touch the disk did not get slower: reading 4 KiB 8327
    instructions (8781 in milestone 38), rewriting 4 KiB 14011 (14161),
    renaming across directories 13266 (13585). Creating and deleting now
    also closes the handle: 21247 instructions (19414 without the close).

- **Verification:**
  - full proof from scratch with nothing pending: 2918 checks
    (2779 in milestone 38);
  - 147 self-tests (two new) with 1 and 4 harts, in Debug and optimized
    builds, and with `-icount`;
  - real kills: 400 QEMU kills at random moments (18,940 complete rounds
    of the workload before them): all 400 disks were in a state of the
    workload, and all 22 states appeared. The check now compares the number
    of every object with `STAT`;
  - stress: 4 QEMU at once, 12 rounds with 1 hart and 12 with 4 harts:
    48 of 48 with 4 harts, 46 of 48 with 1 hart, and 47 of 48 when repeated.
    All three failures were the CPU share test (3 to 1 asked, ratio between
    2 and 4 required), with ratios of 1.83 to 1.92: it measures with the
    host's clock, and the host was running other heavy programs. With them
    closed, alternating rounds of the milestone 38 and 39 kernels passed 48
    of 48 each, with the same ratios (median 2.96 and 2.97, lowest 2.48 and
    2.33). The scheduler did not change in this milestone.
- **Mutations:**
  - runtime: 57 of 57 caught. New: the kernel not delivering the
    badge, or reading it from another slot; deriving that loses the badge;
    the server serving requests without a badge, or mixing up similar
    badges; creating without checking `Room`; `DETACH` that closes nothing;
    `Resolve`, `Close` and `Detach` using another client's row; `Open`
    taking another client's row or not giving the lowest free handle;
    closing that does not close; `Resolve` without checking that the handle
    is open; `Room` always saying yes; and `STAT` without checking the
    generation. The 41 of milestones 35-38 again.
  - SPARK: 13 of 13 new ones rejected by the proof: `Derive`,
    `Transfer` and `Grant_Badged` losing the badge, `Badge_Of` reading
    another slot, and the 9 mutations of `Fs_Handles` and `Stat` listed
    above. The 39 of milestones 35-38 were not run again: their contracts
    did not change, and the only addition to `Fs_Core` is `Stat`.
  - regression: the 9 of milestone 34 (disk driver, DMA, PMP) caught again.
- **Limits:**
  - A client that dies without `DETACH` keeps its row until the server
    stops: the kernel does not tell the server. With 4 rows, a fifth client
    waits for one to be released.
  - Badges are given by the kernel when it creates a process; no process
    can mint badged capabilities for others yet.
  - Two capabilities with the same badge are the same client for the
    server, wherever they are.
  - Handle numbers are reused after `CLOSE`, as Linux reuses descriptors.

## Milestone 38 — Handles that never point to the wrong file

- **Goal:** until now, a client named a file by its table entry. Another
  client could delete that file and create a new one in the same entry, and
  the first client's next write would land in the new file. Now every file
  and directory is named by a handle that stops working, for good, when what
  it named is deleted.
- **Design:** each table entry gains a 32-bit generation. Deleting an entry
  raises its generation in the same 64-byte write that frees it, so the
  power-cut argument of milestone 36 still holds. Creating reuses a free
  entry with the generation it already has. A handle is the entry and the
  generation in one word (`gen << 8 | entry`). Every operation that takes a
  handle answers the new error `STALE` if the entry is no longer in use with
  that generation. Renaming keeps the generation, so a handle survives a
  rename, as a Linux file descriptor does. To make room, names shrink from
  24 to 20 bytes (format version 3).
  - **Retirement:** an entry whose generation reaches 2^32 - 1 is never used
    again, so a generation never wraps around.
  - **Formatting** a disk that already held a file system raises every
    generation by one: no handle from before the format works after it.
- **Proved in SPARK (`Fs_Core`):**
  - `Step_Ok(Old, New)`: no generation goes down, and an entry in use can
    only stop being in use, or change kind, if its generation goes up. Every
    operation that changes the table has it in its postcondition.
  - `Lemma_Same_Object`: in any history of tables where each step is
    `Step_Ok`, a handle that is valid at the first and at the last table was
    valid at every table in between, with the same kind. So it names the same
    object, which was never deleted in between. A handle of a deleted object
    can never become valid again.
  - Every operation on a handle succeeds only if the handle is valid
    (`Opened`). `Delete` raises the generation by exactly one, `Rename` and
    `Commit_Write` keep it, `Create` never uses a retired entry, `Mount`
    rejects an entry in use with the last generation, and `Format` raises
    every generation (or keeps a retired one retired).
- **Server:** `LOOKUP`, `CREATE` and `LIST` answer handles; `READ`, `WRITE`,
  `DELETE`, `RENAME` and `LIST` take them. The root is the handle
  `FB_FS_ROOT`.
- **Tests:**
  - the kernel's random sequence of 800 operations now uses a wrong
    generation one time in sixteen; each such request is refused with
    `STALE` and leaves the table unchanged. After every step it checks `Step_Ok` by hand between the
    table before and after, and that none of the last 32 deleted handles
    works again;
  - a new kernel test: an entry is reused without the old handle working,
    rename keeps the handle, an entry reaches the last generation and is
    never reused (the table fills up without it), `Mount` rejects an entry in
    use with the last generation (27 kinds of bad table), and formatting
    raises every generation or starts them at 0;
  - through the server: a deleted file whose entry was reused by another
    file answers `STALE` to read, write, delete, rename and list, and does
    not read the other file's data; forged handles (next generation, high
    bits) are refused; a deleted directory's handle cannot list; a handle
    survives a rename into another directory; formatting a mounted disk
    makes the old handle of "hello" stale;
  - **power cuts:** the model behind the test now also knows which entry
    each object takes and every entry's generation. After every cut, the
    disk must give each object exactly the handle the model predicts, and
    the handles of deleted objects must answer `STALE`, even where another
    object took their entry. This checks that the raised generation reaches
    the disk together with the delete. 467 cuts per boot: 320 left the state
    before the operation and 147 the state after it.
- **Measurements** (`-icount`, 4 harts, median of 5 runs; Linux 6.12 in the
  same QEMU, files in the initramfs):

  | Operation | Fabianus | Linux |
  |---|---|---|
  | Get a handle, path of one name | 3891 ns (`LOOKUP`) | 7873 ns (`open` + `close`) |
  | Get a handle, path of 4 names | 5674 ns (`LOOKUP`) | 8804 ns (`open` + `close`) |
  | Use a handle without the disk | 2700 ns (a stale handle, refused) | 1661 ns (`fstat`) |
  | Look up a path of 4 names | 5674 ns | 5915 ns (`stat`) |

  - Using a handle costs one round trip to the server plus the generation
    check; Linux's `fstat` is one system call into the same process's
    descriptor table, 1.6 times faster.
  - Getting a handle is cheaper than in Linux, which allocates and frees a
    descriptor on `open` and `close`; Fabianus gives out a number and keeps
    no state per handle.
  - Looking up 4 names went from 5985 to 5674 ns. Names are now 20 bytes
    instead of 24, so each comparison is shorter; this was not profiled.
  - Operations that touch the disk cost slightly more than in milestone 37:
    reading 4 KiB 8781 instructions (+4.4%), rewriting 4 KiB 14161 (+1.0%),
    creating and deleting 19414 (+4.6%), renaming across directories 13585
    (+1.9%).
- **Verification:**
  - full proof from scratch with nothing pending: 2779 checks (2694
    in milestone 37);
  - 145 self-tests (one new) with 1 and 4 harts, in Debug and optimized
    builds, and with `-icount`;
  - real kills: 400 QEMU kills at random moments (53,412 complete rounds
    of the workload before them): all 400 disks were in a state of the
    workload, and all 22 states appeared. The check now also compares every
    handle with the model;
  - stress: 4 QEMU at once, 12 rounds with 1 hart and 12 with 4 harts: 96
    of 96 boots passed.
- **Mutations:**
  - runtime: 41 of 41 caught. New: deleting without raising the generation,
    reading, planning a write, deleting, renaming or listing without
    checking the generation, creating in a retired entry or with generation
    0, renaming that changes the generation, `Mount` accepting the last
    generation in use, formatting without keeping the generations, the
    server giving handles without the generation, and deleting with the
    table's generation instead of the handle's. The 28 of milestones 35-37
    again.
  - SPARK: 39 of 39 rejected by the proof. New: deleting without raising
    the generation; `Block_Of`, `Plan_Write`, `Delete`, `Rename` and
    `Next_In` without checking the generation; creating in a retired entry
    or with generation 0; renaming that changes the generation; `Mount`
    accepting the last generation in use; `Step_Ok` without requiring the
    entry to stay in use; `Format` without raising the generations; and
    `Delete` that keeps the entry. The 26 of milestones 35-37 again, against
    the new specification.
  - regression: the 9 of milestone 34 (disk driver, DMA, PMP) caught again.
- **Limits:**
  - A handle is not a capability: a client that knows an entry and its
    generation can build a handle without having looked the file up. Unlike
    a Linux descriptor, handles are not per process, and nothing is closed.
  - Formatting a disk whose superblock is not valid starts every generation
    at 0, so a handle given out by an earlier file system on that disk could
    match again.
  - Names are 20 bytes at most (24 before).
  - Entries are still 64 in all, and lookup scans the table linearly.

## Milestone 37 — Directories, and rename across them

- **Goal:** files live in a tree of directories, reached by paths such as
  `/docs/notes/a`. Entries can be renamed and moved from one directory to
  another. Every operation stays atomic under a power cut, and the tree can
  never contain a cycle.
- **Design:** each table entry now records its kind (file or directory) and
  the directory that contains it (another entry, or the root, which has no
  entry). A directory has no blocks: its children are the entries that name
  it as their parent. So creating, deleting and renaming, even from one
  directory to another, still change a single 64-byte entry inside a single
  sector, and the power-cut argument of milestone 36 carries over unchanged.
  The entry layout changed (format version 2).
- **Proved in SPARK (`Fs_Core`):**
  - **No cycles.** The server keeps, next to the block map, the depth of
    every entry: 1 under the root, and one more than its directory below
    it. Like the block map, it is not on disk: `Mount` computes it from the
    table and rejects the disk as corrupted if it cannot (a cycle).
    `Lemma_No_Cycle` proves that climbing from directory to directory never
    returns to the starting entry: the depth goes down by exactly one at
    each step, and a natural number cannot go down forever.
  - **Rename** changes only the directory and the name of one entry, and
    recomputes every depth from scratch (`Rank_All`). If they cannot be
    computed, because a directory would end up inside itself or inside one
    of its descendants, the entry is restored and the request is refused.
  - **Names are unique per directory**, a directory only holds entries while
    it exists and is a directory, a directory is only deleted when empty, and
    files and directories cannot be confused (no blocks for a directory, no
    children for a file).
  - **Names** are 1 to 24 bytes, without `/` and not `.` or `..`, padded with
    zeros so that each name has one spelling. `Mount` rejects anything else.
- **Server:** paths travel at the start of a page of the client's region.
  The server copies them, splits them into names and resolves them one
  name at a time with the proved `Lookup`. New operation `RENAME`; `LIST`
  now lists one directory; new errors for "not a directory", "directory not
  empty" and "is a directory".
- **Tests:**
  - the random sequence of the kernel self-test now creates directories and
    renames (800 operations). After each step it remounts the table and
    checks that the depths the core keeps are the ones it deduces from the
    table, and, by hand, that every entry hangs from the root;
  - `Mount` rejects 26 kinds of bad tables (14 before), among them a file
    used as a directory, a missing directory, a directory inside itself, two
    directories inside each other, a cycle away from the root, and names
    with `/`, `.`, `..` or bytes after their end;
  - in the core: a directory never ends up inside itself, a refused rename
    leaves the table byte for byte unchanged, and a successful one changes
    one entry;
  - through the server: paths with repeated slashes, errors for every bad
    path, listing a directory, moving a file with its data, moving a
    directory with everything under it, a chain of 30 nested directories;
  - **power cuts:** the workload grows from 16 to 21 operations. It now
    creates directories, moves a file into another directory under a new
    name, moves a directory that holds files to the root, and deletes an
    empty directory. The model behind the test checks each directory's
    exact contents. 467 cuts per boot: 320 left the state before the
    operation and 147 the state after it.
- **Measurements** (`-icount`, 4 harts, median of 5 runs; Linux 6.12 in the
  same QEMU, files in the initramfs):

  | Operation | Fabianus | Linux |
  |---|---|---|
  | Look up one name | 3967 ns | 4917 ns (`stat`) |
  | Look up a path of 4 names | 5985 ns | 5777 ns (`stat`) |
  | Rename across directories | 13337 instructions, with a table write to disk | 15374 ns, in memory only |

  - Looking up one name costs 1075 ns more than in milestone 35 (2892 ns),
    which carried the name in the message registers; now the path is in
    shared memory. Splitting the path by hand instead of with iterators
    saved 130 ns over 4 names; most of the cost is elsewhere and was not
    profiled.
  - Linux resolves a longer path faster: each extra name costs Fabianus
    about 670 ns, against about 290 ns for Linux's name cache.
  - Creating and deleting a file costs 18555 instructions, 9% more than in
    milestone 36 (17009): creating now goes through a path. Reading (8412)
    and rewriting (14014) 4 KiB of a file cost 2% and 0.2% more.
- **Verification:**
  - full proof from scratch with nothing pending: 2694 checks (2485 in
    milestone 36);
  - 144 self-tests (one new) with 1 and 4 harts, in Debug and optimized
    builds, and with `-icount`; a boot takes about 20 s alone with 1 hart
    (17 s in milestone 36), mostly from the larger power-cut test.
- **Real kills:** 400 QEMU kills at random moments of the looping
  workload (16,757 complete rounds before the kills): all 400 disks were in
  a state of the workload, and all 22 states appeared.
- **Stress:** 4 QEMU at once, 12 rounds with 1 hart and 12 with 4 harts:
  96 of 96 boots passed.
- **Mutations:**
  - runtime: 28 of 28 caught. New: rename without writing the table (caught
    by the power-cut test), creating only files, resolving a path without
    going down, the server accepting `.` and `..`, names allowed to contain
    `/`, listing or looking up without looking at the directory, rename
    without recomputing depths, deleting a directory that is not empty, and
    `Mount` without depths, without checking directories, or comparing
    names across directories. The 16 of milestones 35-36 again.
  - SPARK: 26 of 26 rejected by the prover. New: rename without
    recomputing depths, without checking the target directory or without
    restoring the entry when it fails; deleting a directory that is not
    empty; creating without checking the name or the directory, or with the
    depth of the directory itself; `Mount` without checking directories or
    depths; lookup without looking at the directory; `Rank_All` without
    requiring the depth of the parent; `Names_Unique` and `Depth_Ok`
    weakened. The 13 of milestones 35-36 again.
  - regression: the 9 of milestone 34 (disk driver, DMA, PMP) caught again.
- **Limits:**
  - **Rename does not replace** an existing entry (it answers "exists", like
    `renameat2` with `RENAME_NOREPLACE`). Replacing would change two entries,
    which can lie in different sectors.
  - Entries are still 64 in all (files and directories together), and
    lookup scans the table linearly.
  - Operations other than lookup and rename still take an entry number,
    not a path, so another client can delete and reuse an entry between a
    lookup and a write.
  - No `.` or `..` in paths: every path starts at the root.

## Milestone 36 — Every file system operation survives a power cut

- **Goal:** after a power cut at any moment, the disk holds either the state
  before the interrupted operation or the state after it. It is never
  corrupted, never shows half a file, and never shows data of a deleted
  file. Milestone 35 argued this for its write order; this milestone
  changes what was needed, proves the part that can be proved, and tests the
  rest by cutting the power thousands of times.
- **Why each operation is atomic:**
  - **Copy on write.** Rewriting a block of a file now writes the new data
    into a free block, and only then points the table at it. The old block
    becomes free. Before, a rewrite went to the same block, and a cut in
    the middle left a block that was half old and half new.
  - **Order.** Data reaches the disk before the table that names it, and
    the table before the superblock when formatting.
  - **One sector.** Every operation changes a single 64-byte table entry,
    and an entry never crosses a 512-byte sector. The disk writes a sector
    whole or not at all, so the table on disk is the old one or the new
    one, whichever part of the 4 KiB table write was cut.
- **Proved in SPARK (`Fs_Core`):**
  - **`Plan_Write` always picks a free block, and no file in the table
    names it** (`Not_In_Table`, defined from the table alone). Writing the
    data therefore changes no file that a mount of the old table would see.
  - **`Commit_Write`** changes only the entry of the file, and in it only
    the length and the block of that position. The old block becomes free
    and the table stays valid (`Lemma_Free_Unnamed`).
  - **`Mount`** now tells three cases apart: a valid file system, a disk
    without one (no valid superblock), and a corrupted one (a valid
    superblock with an invalid table). A cut may leave the second, never
    the third.
- **Server:** if a table write fails, the table in memory no longer matches
  the disk. The server then answers every request with an I/O error until
  another server mounts the disk. In milestone 35 it went on, and a later
  write could reuse a block that the disk still gave to a deleted file.
- **Driver:** a fault injection operation, like dm-flakey in Linux. `CUT`
  lets a given number of sectors through and then "cuts the power". The
  write that crosses the limit really reaches the disk, with only its first
  sectors (or, in a second pass, only its last ones). From then on every
  request fails without touching the disk, until `POWER`.
- **Crash test** (`tests/fs_crash.rs`, on every boot): a fixed workload of
  16 operations runs from a disk with garbage in its superblock and table:
  format, create, write, extend, rewrite, delete, and a new file that
  reuses the entry and a block of a deleted one. The power is cut after
  0, 1, 2... sectors, at every one of the 208 sectors it writes (26 writes of 8 sectors),
  tearing the write in two ways. After each cut a new server mounts the
  disk and a client checks that it is in the state before or after the
  interrupted operation: the files, their lengths, the data of every block,
  the free blocks, and nothing more.
  - 392 cuts per boot: 280 left the state before the operation and 112
    the state after it.
  - Also a passing error: the table write of a delete fails and the power
    comes back. The server must stop serving, and a new server must find
    the file with its data.
- **Real kills** (`-Dfskill=run` and `-Dfskill=check`): QEMU runs the same
  workload in a loop on a disk image without snapshot and is killed from
  the host at a random moment. QEMU then boots again on that image and
  checks that the disk is in one of the states of the workload. A host
  kill cuts between whole requests, not inside them: it complements the
  sector-level test above.
  - 1000 kills: all 1000 disks were in a state of the workload, and all 17
    states (from "unformatted" to the end) appeared.
  - An earlier batch of 500 had 1 failure: the second kill, right after
    the previous batch was stopped while its checking QEMU still had the
    same image open. The image was not kept, so the cause is not known.
    The script now keeps the image of any failure; it did not happen again
    in the 1000 kills above.
- **Measurements** (`-icount`, 4 harts, median of 5 runs):
  - rewriting 4 KiB of a file with copy on write: 13986 instructions
    (milestone 35, in place: 13892, so +0.7%). Both write the data block
    and the table; copy on write only adds the search for a free block;
  - the other file system figures are unchanged (lookup 2892 and 4026 ns,
    read 8246, create and delete 17009 instructions);
  - the crash test takes part of a boot of about 15 s (1 hart) or 17 s
    (4 harts) with 392 cuts, each with two servers and two clients.
- **Verification:**
  - full proof from scratch with nothing pending: 2485 checks (2461 in
    milestone 35);
  - 143 self-tests with 1 and 4 harts, in Debug and optimized builds, and
    with `-icount`;
  - stress with 4 QEMU instances at once: 128 of 128 with 1 hart and 191 of 192 with 4 harts. The failure is the known cross-hart inheritance test under load (about 1 in 384 since milestones 31-32), not the file system.
- **Mutations:**
  - SPARK: 13 of 13 rejected. New: `Plan_Write` rewriting in place,
    `Write_Allowed` without requiring a free block (caught by
    `Not_In_Table`, which only looks at the table), `Commit_Write` without
    freeing the old block, and `Mount` taking a bad table for an
    unformatted disk. The 9 of milestone 35 again.
  - Runtime: 16 of 16 caught, including the **two survivors of milestone
    35** (the table before the data, the superblock before the table): the
    crash test catches both. Also rewriting in place (caught by the crash
    test alone when the other checks are switched off), the server going on
    after a failed table write, a driver cut that does not cut, a cut write
    reported as good, and a bad table taken for an unformatted disk.
  - Milestone 34 again: 9 of 9.
- **Limits:**
  - **Rewriting needs a free block:** with the disk full, rewriting a block
    answers "full", as in other copy-on-write file systems.
  - **Sector atomicity is assumed:** the test cuts between sectors, not
    inside one. Real disks guarantee atomic writes only of their own sector
    size.
  - **No cache flush:** the driver does not negotiate `VIRTIO_BLK_F_FLUSH`.
    QEMU then treats the disk as write-through, so the order of completed
    writes is the order on the disk. A real disk with a volatile write cache
    needs flushes between data and table.
  - **No Linux figure:** comparing the write cost with ext4 needs an ext4
    image, and neither `mke2fs` nor ext4 (a module in the Debian kernel) is
    available in the comparison setup yet.
  - The workload is fixed, with four files; the random sequences of
    milestone 35 are not cut.

## Milestone 35 — A minimal file system, with its core proved in SPARK

- **Goal:** files on the disk. A file system server runs as a user process
  between clients and the disk driver. Every decision about the on-disk
  format is taken by a SPARK package that is proved and linked into that
  same server, so the code that runs is the code that was proved.
- **Format** (the second MiB of the disk, 256 blocks of 4 KiB):
  - block 0: superblock (magic number, version, block and file counts);
  - block 1: a table of 64 entries of 64 bytes. Each entry has a name of up
    to 24 bytes, a length in bytes and up to 16 blocks (64 KiB per file);
  - blocks 2 to 255: data.
  - There is no block bitmap on disk. The in-memory map of who owns each
    block is derived from the table when mounting, so the two can never
    disagree.
- **Proved in SPARK (`Fs_Core`, 221 checks):**
  - **`Lemma_Disjoint`:** with a valid table, no block belongs to two files,
    none appears twice in the same file, and none is a metadata block. No
    two files have the same name.
  - **`Mount`** accepts a superblock and table read from disk only if they
    are valid, and builds the map. Anything else is rejected: the disk can
    hold any bit pattern.
  - **`Create`, `Commit_Write` and `Delete`** keep the table valid, and say
    exactly what they change. `Lookup`, `Block_Of`, `Plan_Write` and
    `Next_Used` are proved to answer correctly.
  - Every argument that comes from a client is checked inside the proved
    code and answered with a status.
  - The functions that describe one entry take only that entry. With the
    whole table as argument, the provers could not see that changing one
    entry leaves the others alone, and the first proof attempt timed out.
- **Server (`servers/fs/main.rs`, Rust, `no_std`, no global data):**
  - It links the SPARK library directly. The table and the superblock live
    in a region it shares only with the disk driver; the block map lives on
    its stack.
  - **Write order:** data goes to the disk before the table that names it,
    and the empty table before the superblock when formatting. The table on
    disk never names a block that was not written, and every new block is
    written whole by its client, so a file never shows data left by a
    deleted one.
  - Protocol (`FB_FS_*`): format, create, lookup, read, write (one block per
    call), delete, list, free blocks and stop. File data moves by DMA
    straight between the disk and the client's region: the driver now
    accepts a second data region (slot 5), numbered after the first.
  - An unformatted or corrupted disk is reported as such; only format is
    then accepted.
- **Kernel:** `memcmp` in `mem.S` (GNAT uses it to compare names). A small
  shared Rust library for user programs (`lib/fb_user`). The test disk grows
  to 2 MiB: the first MiB keeps the milestone 34 pattern.
- **Measurements** (`-icount`, 4 harts, driver, server and client on the
  same hart; median of 5 runs):

  | Operation | Fabianus | Linux 6.12 |
  |---|---|---|
  | Look up a name, no disk (first entry) | 2892 ns | 4910 ns (`stat`, directory of 2) |
  | Look up a name, no disk (entry 64 of 64) | 4026 ns | 4927 ns (`stat`, directory of 64) |
  | Read 4 KiB of a file | 8191 instructions | — |
  | Rewrite 4 KiB of a file (data and table) | 13785 instructions | — |
  | Create and delete a file (two table writes) | 16913 instructions | — |

  - Fabianus looks up a name with a linear scan of 64 entries, through an
    IPC call to the server: about 18 ns more per entry. Linux resolves the
    path in its hashed name cache, so its cost does not depend on the size
    of the directory. With 64 files the scan is still cheaper than `stat`.
    With thousands of files it would not be.
  - A read through the file system costs about 3,000 instructions more than
    a raw disk read in the same run (5194): one more IPC hop and the proved
    block lookup.
  - There is no Linux figure for operations that wait for the disk:
    `instret` does not advance from user mode in this setup (milestone 34).
- **New tests** (5):
  - format and mount an empty file system;
  - 400 random create, write and delete operations of the SPARK core,
    followed by filling the disk. After every step the table is mounted from
    scratch: the map kept step by step is the one derived from the table,
    no block repeats (checked by hand, without the core) and the free count
    matches;
  - mounting rejects 14 kinds of invalid table or superblock (a block in two
    files or twice in one, metadata or out-of-range blocks, impossible
    lengths, a block after the last one, an unknown used mark, repeated or
    empty names, another magic number, version or size) and accepts garbage
    in free entries;
  - committing a write rejects blocks owned by others, metadata blocks,
    changed blocks and holes;
  - end to end, with the Rust server and driver: on the unformatted disk,
    format, create, write and read back, limits, rewrite, a file of 16
    blocks, list, delete, fill the table (64 files) and the disk (250
    blocks). Then three more servers, one after another and with nothing in
    memory, mount the same disk. The second finds the data and the empty
    file created last, and deletes it; the third finds it gone and, as its
    last operation, extends a file; the fourth sees the new length. Each
    pass ends on an operation whose table write nothing else would redo, so
    a server that skipped it is caught. At the end everything stops, the
    disk is reset and every frame comes back.
- **Verification:**
  - full proof from scratch with nothing pending: 2461 checks (2240 in
    milestone 34);
  - 142 self-tests with 1 and 4 harts, in Debug and optimized builds;
  - stress with 4 QEMU instances at once: 128 of 128 with 1 hart and 192 of
    192 with 4 harts;
  - the other measures are unchanged (call and reply on 1 hart 1989 ns,
    raw 4 KiB disk read 5194 instructions).
- **Mutations:**
  - SPARK: 9 of 9 rejected (mounting without the ownership check, without
    validating entries or without comparing names; `Plan_Write` without
    looking for a free block; `Commit_Write` without checking the plan;
    `Delete` without freeing blocks; `Create` without looking up the name;
    `Block_Of` without capping the bytes; and `Count_Of` rounding down,
    which changes specification and code together and is caught by the
    lemma that says what the count means).
  - Runtime: 8 of 10 (reading without checking the client's page, writing,
    creating or deleting without writing the table, treating any disk as
    mounted, listing without the name, the driver without its second region,
    and `memcmp` always equal). The first round left "write without writing
    the table" alive: a later operation wrote the table and hid it. The test
    now ends each pass on the operation it checks.
  - **Survivors:** writing the table before the data, and the superblock
    before the table. They only matter if the power fails in between, and
    no test does that (see limits).
  - Milestone 34 again, with the driver's second region: 9 of 9.
- **Limits:**
  - **No directories,** 64 files of at most 64 KiB, and the file system uses
    a fixed 1 MiB of the disk.
  - **No cache:** every read goes to the disk.
  - **One client** and one request at a time.
  - **Crashes:** the write order keeps the table on disk consistent if
    sector writes are atomic, but it is argued, not tested: no test cuts the
    power in the middle of a write. If writing the table fails after a
    commit, memory and disk disagree until the next table write.
  - A file id is the index of its entry, and can be reused after a delete.

## Milestone 34 — A disk driver in Rust, with DMA into shared memory

- **Goal:** the first storage device. A virtio-blk disk driven by a user
  process written in Rust, which moves data by DMA straight into memory it
  shares with its clients: no copies through the kernel.
- **Devices in SPARK (`User_Space`):**
  - "The device" (the UART page) becomes a set of device pages, each held by
    at most one space: the UART and the first virtio slot (the disk).
    `Map_Device` takes the device, and the isolation theorem
    (`Lemma_Isolation`, `Lemma_Private`) covers both.
  - `Destroy` releases every device of the space.
  - **`Region_Frame_For`:** the physical address of a region page, only for a
    space joined to that region. It is all a driver needs to program DMA on
    the memory it shares, and the kernel never gives it any other address.
  - 664 checks in `User_Space` (623 in milestone 33).
- **Kernel:**
  - `device.zig` handles several devices, each with its interrupt line and
    endpoint. When the owner of the disk dies, the kernel resets the disk
    (virtio Status = 0) **before** freeing its memory: a DMA still in flight
    can never land on frames that already belong to someone else.
  - The PMP entry of the UART now covers 8 KiB (UART and the first virtio
    slot); the next slot stays outside, and a test checks it.
  - New system call `FB_SYS_DMA_ADDRESS`: it needs the disk capability with
    Send, holding the disk's registers, and being joined to the region.
- **Driver (`drivers/disk/main.rs`, Rust, `no_std`, no global data):**
  - modern virtio-mmio (version 2): feature negotiation (only `VERSION_1`),
    one queue of 8 descriptors in a private region page;
  - every request is three descriptors: header, the client's page and the
    status byte. The disk reads or writes 4 KiB directly in the region it
    shares with the client;
  - protocol (`FB_DISK_*`): the client calls with the operation, the first
    sector and a page of the shared region; the driver checks the range and
    the page, defers the call, waits for the disk's interrupt and replies.
    Deferring is required: a server that owes a reply cannot receive
    anything else (proved in `Ipc_Core`), and the interrupt arrives as a
    message.
- **Test disk:** `tools/mkdisk.zig` generates a 1 MiB image where word i of
  sector s is s·2³² + i, so any read can be checked without a copy. QEMU
  opens it with `snapshot=on`: writes are lost on power-off and every boot
  sees the same disk. `zig build run` adds it.
- **Measurements** (`-icount`, 4 harts), instructions of the whole machine
  per 4 KiB request (client, kernel and driver):

  | Request | Driver on the same hart |
  |---|---|
  | Read 4 KiB | 5228 (median; 5191 to 5653) |
  | Write 4 KiB | 5204 (median; 5196 to 5255) |

  - **Latency cannot be measured reliably in QEMU:** while every hart waits
    for the disk, the virtual clock jumps from deadline to deadline, and the
    disk's real time on the host decides how many jumps there are. Measured
    by the clock, a read went from 20.7 to 66.6 µs between runs.
  - **With the driver on another hart** the count also includes the timer
    work done during those jumps: 160,000 to 440,000 instructions per
    request, depending on the run. Under a full trace, where QEMU is so slow
    that the disk answers "at once", the same request costs 6,438.
  - **Against Linux:** the Debian kernel loads `virtio_mmio` and
    `virtio_blk` (both modules in Debian) and reads `/dev/vda` with
    `O_DIRECT`, but in this QEMU `instret` read from user mode does not
    advance, so there is no comparable figure. The measurement program
    detects it and says so.
- **New tests** (3):
  - a client reads and writes the disk through the Rust driver on another
    hart: it checks the image pattern, writes a page and reads it back into
    another, and the driver rejects a page that does not fit at the end of
    the disk and one the region does not have. When the driver stops, the
    disk is reset, the regions are freed and every frame comes back;
  - if the driver dies with the disk running, the kernel resets the disk
    before freeing its memory;
  - only whoever holds the disk's registers (Send) and has joined the region
    learns a physical address: not without the capability, not with the
    UART's, not with Recv only, not without mapping the registers, not
    without joining.
- **Found on the way:** the disk tests waited with interrupts disabled, like
  most kernel tests. With driver and client blocked, nobody on hart 0 took
  the disk's interrupt. They now wait with interrupts enabled, as the UART
  tests do.
- **Verification:**
  - full proof from scratch with nothing pending: 2240 checks (2199 in
    milestone 33);
  - 137 self-tests in 8 of 8 boots in a row with 1 hart and with 4, in 2 of
    2 with 4 harts under `-icount`, and in Debug with 1 and with 4 harts;
  - stress with 4 QEMU instances at once: 128 of 128 with 1 hart and 192 of
    192 with 4 harts;
  - the other measures are unchanged from milestone 33 (call and reply on 1
    hart 1956, across harts 4841 ns).
- **Mutations:**
  - SPARK: 6 of 6 rejected (mapping a device that already has an owner, two
    devices on the same page, `Translate` excluding only the UART,
    `Destroy` without releasing devices, `Region_Frame_For` without being
    joined, and without checking the frame's range). The first round left
    one alive: `Is_Device_Ppn` was a separate copy of the device pages, and
    changing it moved the specification together with the code. It is now
    defined from the device table, and the equivalent mutation of
    `Translate` is rejected.
  - Runtime: 9 of 9 (resetting the disk on release, the three DMA checks,
    no interrupt line enabled, the driver not letting the disk write when
    reading, not deferring, not checking the range, and the PMP without the
    disk's slot).
  - Earlier milestones: the same survivors as in milestone 33 (milestone 33:
    9 of 10; 32: 21 of 23; 27: 7 of 9; 22 to 26: the usual ones, and two do
    not compile).
- **Limits:**
  - **No IOMMU:** a DMA driver could tell the disk to write anywhere. The
    kernel only hands it the addresses of its own regions, but it cannot
    stop it from making them up: the disk driver is trusted for that, as in
    any system without an IOMMU.
  - One request at a time and one queue: no request pipelining yet.
  - If the driver dies, the kernel leaves the disk safe, but nobody starts a
    new driver.
  - Only QEMU's virtio-blk, in the first slot. Latency is not measurable in
    this setup.
- **Licensing:** the project is now explicitly GPL-3.0-or-later. Every
  source file starts with an SPDX line, `alire.toml` declares the license,
  and the README states it in full. The proof (2240 checks) and the 137
  self-tests with 1 and 4 harts were rerun after the change.

## Milestone 33 — Shared memory between processes

- **Goal:** the first step towards a usable system. Disk and network drivers
  need to hand over whole buffers, and until now two processes could only
  exchange 32 bytes per message. The proved isolation between address spaces
  had to stay a theorem, now with an exception that is itself proved.
- **Design:**
  - A **region** is a list of frames whose owner is the region, not a space.
    The owner of a frame is now nobody, a space (1 to 4) or a region (5 to
    8), and the per-owner frame lists proved in milestone 18 cover regions
    with the same definition (`Lists_Ok` over every owner).
  - A space can only map a region's pages after **joining** it
    (`Region_Attach`), and it only leaves when it is destroyed. So a page is
    never taken away from a live process, and no other hart ever has to be
    told to forget a translation.
  - Who may join is decided by a **capability** of the new kind `Region`,
    passed over IPC like any other (with Grant). Recv allows mapping it for
    reading; Send, also for writing. Never for execution.
  - **Lifetime:** the kernel creates a region with its pages zeroed and holds
    it until it grants it. From then on it lives while some space is joined
    to it or some capability names it, and the kernel frees it after the
    last process that reached it is destroyed.
- **SPARK, `User_Space`:**
  - The invariant now says that every leaf points to a frame of its own
    space, to a frame of a region the space has joined, or to the device if
    it holds it. A region without frames does not exist and nobody is joined
    to it (`Regions_Ok`).
  - **`Lemma_Isolation`, generalised:** two distinct spaces only reach the
    same frame if it belongs to a region both have joined (`Shared_By`).
  - **`Lemma_Private`:** a frame of a space's own is never reachable from
    another space.
  - New operations, proved: `Region_Create` (all or nothing: if a frame is
    missing it keeps none), `Region_Frame`, `Region_Attach`, `Region_Map`
    (read-only or read-write leaves, never executable, and only for a joined
    space), `Region_In_Use` and `Region_Free` (only with no space joined).
    `Destroy` also leaves every region.
  - The device and the region links travel together in the ownership lemmas
    (`Access_Rights`), with two new frame lemmas: more links never break
    what a space may use, and other spaces' links do not affect it.
- **SPARK, `Cap_Core`:** the kind `Region` and `Refers` (whether some
  capability names an object), which the kernel needs before freeing a
  region. The theorem that authority never grows (`Covered`) is unchanged
  and still proved.
- **Kernel:**
  - `region.zig`: creating (zeroing the pages), the system call
    `FB_SYS_REGION_MAP` (maps every page of the region from an address) and
    freeing what nobody reaches.
  - **Bug fixed, older than this milestone:** an order to die was only
    honoured on an interrupt from user mode or when waking from a wait. A
    process told to die before entering an endless wait (sleeping forever,
    receiving with no sender) never died. A new test reproduced it every
    time. Now every system call checks the order first, and `requestKill`
    takes the global lock, so either the call sees it or the process is
    already waiting and the wait is cancelled.
  - The order is kept in a free word just above each thread's trap frame,
    so checking it costs one load and one branch. The first version, reading
    it from the kill table through the current thread, added 11
    instructions to every system call.
- **Measurements** (`-icount`, 4 harts; Linux 6.12, the official Debian 13
  kernel, on the same QEMU):

  | Measure | Fabianus | Linux |
  |---|---|---|
  | 4 KiB to a process on another hart and a sum back, shared memory | 11.1 µs | 29.7 µs (futex) |
  | The same, copying | 623.6 µs (128 calls of 32 bytes) | 32.6 µs (pipe) |
  | Create a 64 KiB region, map it and write its 16 pages | 13.8 + 4.0 = 17.8 µs | 92.5 µs (`mmap` + faults) |

  Medians of 5 runs.
  - With shared memory, passing 4 KiB costs 2.7 times less than in Linux
    and 56 times less than copying them over Fabianus's own IPC.
  - Copying is where Fabianus loses, by far: its IPC carries 32 bytes per
    message and has no bulk copy. Shared memory is the intended way to move
    data.
  - In Fabianus, creating a region (reserving and zeroing 16 pages, in the
    kernel) is measured apart from mapping it; in Linux both happen inside
    the page faults of the first write.
  - **Cost elsewhere** (1 hart, instructions): system call 208 → 212, call
    and reply 1947 → 1956, IPC 3463 → 3479; with 4 harts, same hart 1980 →
    1989 ns and across harts 4857 → 4909 ns. It is the kill-order check on
    every system call. The IPC measure without the measuring thread reads
    2973 in the full benchmark (2880 before), but run on its own it goes
    from 2857 to 2873: the rest comes from the state earlier measures leave
    behind (as in milestone 30).
- **New tests** (7):
  - two processes on different harts share a two-page region: the reader
    sees exactly what the writer wrote, and when both end the region is freed
    and every frame comes back;
  - with a capability without Send the region is mapped read-only, and
    writing to it is a page fault; with Send the same program writes;
  - mapping needs a region capability with Recv (not an empty slot, not
    another kind, not only Send) and never overwrites a mapped page;
  - a region capability travels over IPC, and the receiver maps the same
    memory and sees what the sender wrote;
  - a region lives while some capability names it, even if nobody has it
    mapped, and the kernel holds a new region until it grants it, even if
    another process dies meanwhile;
  - a new region starts zeroed even if its frames held data;
  - a process told to die before blocking dies anyway.
- **Verification:**
  - full proof from scratch with nothing pending: 2199 checks (1976 in
    milestone 32); `User_Space` alone has 623;
  - 134 self-tests in 8 of 8 boots in a row with 1 hart and with 4, in 2 of
    2 with 4 harts under `-icount`, and in Debug with 1 and with 4 harts;
  - stress with 4 QEMU instances at once: 128 of 128 with 1 hart and 192 of
    192 with 4 harts.
- **Mutations:**
  - SPARK: 10 of 10 rejected (mapping without joining, freeing with spaces
    joined, destroying without leaving, joining a region that does not
    exist, ignoring the link in `Uses`, creating with a frame that already
    had an owner, always writable, executable, freeing without returning the
    frames, `Refers` without looking at the object).
  - Runtime: 9 of 10. The survivor is "kill without the global lock": it
    closes a window of a few instructions between the check on entering a
    call and blocking, on another hart, which no test hits deterministically
    (like the milestone 27 races). The argument that the lock closes it is
    by hand.
  - Milestone 32: 21 of 23, the same two latency survivors. Milestone 27: 7
    of 9 (the two races only Debug detects). Milestones 22 to 26: the usual
    survivors; two do not compile.
- **Limits:**
  - A space cannot unmap a region while it lives; it leaves it when it is
    destroyed. Unmapping from a live process will need telling other harts
    to forget the translation (TLB shootdown).
  - Only the kernel creates regions. A process cannot ask for one yet:
    creating authority from a system call needs extending the `Covered`
    theorem to new objects.
  - At most 4 regions of 16 pages (64 KiB) each, like the other fixed
    limits of the system (4 spaces, 8 threads).
  - Zeroing a new region is kernel code, tested but not proved.
  - That joining requires the capability is checked by `region.zig`, not by
    SPARK: `User_Space` proves what joining allows, and `Cap_Core` who holds
    the capability.
  - The worst case of the cross-hart inversion is still the 439 µs of
    milestone 32.
  - Measurements are from QEMU with `-icount`, not real hardware.

## Milestone 32 — Call and inherit in one pass

- **Goal:** recover the cross-hart cost that milestone 31 added (+6.5%)
  without losing what it proved, and prove the inheritance rule at the moment
  of the call and of the reply, which until now only Debug watched.
- **Where the cost was** (per-function profile of the cross-hart round trip,
  5218 instructions in milestone 31): about 1700 instructions went into
  inheritance and into waking the other side:
  - the floor was recomputed twice per round trip, each time with the locks
    of all 4 harts;
  - the other side was woken separately, with one more lock;
  - when the server's hart was idle, the call sent it two notifications.
- **SPARK, `Inherit_Gate`:**
  - **`Call_Wake`** (call and inherit): the server, blocked waiting for
    requests, has just received a call. In one pass its floor becomes exactly
    the highest level among its clients (`Is_Needed`) and it wakes in its
    hart's model. It proves:
    - the rule for the server (`Inherits`);
    - that the rule is **preserved for every other thread** (`Kept`: whoever
      satisfied it before still does);
    - that only the server's hart model changes, and which hart to notify;
    - that it does not fail without a reason.
  - **`Reply_Wake`** (reply and inherit): the server has just answered a
    client on another hart. In one pass the client wakes and the server's
    floor is recomputed from the clients it still has. Same guarantees,
    including `Kept`.
  - **Only the locks that are needed:** both operations receive the set of
    hart locks held (`Held`) and check by themselves that it covers the
    server's hart, every client's hart and the hart of the thread they wake
    (`Covers`). If it does not, they change nothing and return
    `Status_Unheld`; the kernel retries with all harts. This is the case of a
    deferred client living on a third hart.
  - `Lemma_Keep_All`: if only the server's level changes and the server waits
    for nobody, nobody else stops satisfying the rule.
  - `Scan`: the client loop shared by `Refresh`, `Call_Wake` and
    `Reply_Wake`.
- **SPARK, other packages:**
  - `Scheduler_Core.Quiet`: waking a thread takes no context away from
    anyone (it has not lent its own and, if it uses a borrowed one, it is
    already the last in that chain). `Wake` proves that in that case no
    context and no level changes.
  - `Sched_Gate.Wake_Boost`: sets the floor and wakes in a single operation
    on the model. It only acts if `Quiet` holds (otherwise
    `Status_Wrong_State` with nothing changed), so it proves that no other
    thread's level changes.
  - `Sched_Gate.Wake_Remote` proves that, if `Quiet`, no level changes.
  - `Sched_Gate.Home_Of` states which hart it returns.
  - `Ipc_Core.Waits_For`, `Sched_Gate.Home_Of`, `Priority_Of` and `Floor_Of`
    are inlined.
- **Kernel:**
  - `thread.wakeInheriting` and `thread.replyWaking` take only the locks of
    the two harts involved and retry with all of them if SPARK asks for it
    (`thread.unheldRetries` counts the retries).
  - `ipc.call` across harts uses `Call_Wake` and waits; `reply`, `reply_to`
    and `reply_recv` go through `ipc.release`, which uses `Reply_Wake` when
    the client is on another hart and the server inherits.
  - When the server blocks right after replying (`reply_recv`), it does not
    check whether its own hart should yield: it is about to choose anyway.
  - The same-hart paths are unchanged.
- **Measurements** (`-icount`):

  | Measure | Milestone 31 | Milestone 32 |
  |---|---|---|
  | Across harts, round trip | 5221 ns | 4857 ns (−7.0%) |
  | Across harts, waking the other side | 2633 ns | 2298 ns |
  | Same hart (4 harts), round trip | 1980 ns | 1980 ns |
  | Call and reply, 1 hart | 1947 | 1947 |
  | Call with one hop, 1 hart | 4446 | 4446 |
  | IPC / context switch / `yield`, 1 hart | 3463 / 413 / 583 | 3463 / 413 / 583 |

  - The cross-hart round trip is now below milestone 30 (4902 ns), before
    the rule was proved.
  - **Tried and discarded:** a first version returned the client set from
    `Ipc_Core` as an array (`Clients_Of`) and gained only 1.3%: building and
    unpacking the array cost more than the calls it replaced. Inlining
    `Waits_For` was cheaper.
  - Cross-hart inversion (the server starts running): minimum 9264 → 8529
    ns, median 10299 → 9452 ns. The worst of the 1280 calls went from 253 to
    439 µs, the same in the three runs (see the limits).
  - Stale inheritance: 2.7 µs median, unchanged.
- **New tests:**
  - **Retrying with all locks** (3 or more harts):
    - a server on hart 1 defers an urgent client from hart 2 and then
      receives a call from hart 0. The two locks are not enough, so the call
      is retried with all harts and the server keeps the deferred client's
      urgency;
    - the same when replying: the server answers a client from hart 0 while
      a deferred one from hart 2 remains, and drops to its urgency;
    - without deferred clients on other harts, calling and replying never
      ask for all locks (checked in two existing tests).
  - **Paths that lost coverage** (2 or more harts). Until milestone 31 they
    were only exercised indirectly through the cross-hart ones; mutation
    testing showed the gaps once those moved to `Call_Wake` and
    `Reply_Wake`:
    - a server that inherits a floor through a forwarder on its own hart
      (the forwarder inherits it from a client on another hart) drops it
      when it replies, both with `reply` and with `reply_recv`;
    - a server that takes from its queue a client of its own hart that
      inherits gets that client's floor;
    - the cross-hart call test adds a round with the client at the lowest
      priority: the server inherits nothing and replies through the path
      without inheritance.
- **Removed:** `ipc.readopt`, replaced by `ipc.release`.
- **Race fixed in a milestone 24 test:** stress found one failure ("invalid
  scheduling parameters") in `testLowOnIdleHart`. The test created a thread
  that spins for 30 ms of real time and then set its priority. The most
  likely cause: with the host saturated, the creating hart took longer than
  that, the thread had already finished, and SPARK refused to set parameters
  on a free slot. It is not confirmed (the panic does not dump the state).
  The thread now starts counting only once its priority is set.
- **Verification:**
  - full proof from scratch with nothing pending: 1976 checks (1850 in
    milestone 31);
  - 127 self-tests in 8 of 8 boots in a row with 1 hart and with 4, in 2 of
    2 with 4 harts under `-icount`, and in Debug with 1 and with 4 harts;
  - stress with 4 QEMU instances at once:
    - with 1 hart, 128 of 128, twice;
    - with 4 harts, 765 of 768 over four runs. One failure was the milestone
      24 test race described above. The other two are the cross-hart
      inheritance test at about 100 ms, the pattern seen since milestone 26;
    - in an alternating comparison on the same host, milestone 31's binary
      and milestone 32's both passed 192 of 192. Counting every run, that
      failure appears about once in 384 boots in both milestones.
- **Mutations:**
  - SPARK: 9 of 9 rejected (the server's hart unchecked, a client outside
    `Held` not marked, the old floor, a server that waits for someone, a
    floor that is not lowered, waking the client without its floor,
    `Wake_Boost` without `Quiet`, a weaker `Quiet`, `Scan` keeping the last
    client instead of the highest).
  - Runtime: 21 of 23, including those ported from milestones 23, 25, 29,
    30 and 31. The first round left 5 alive and 3 whose patterns did not
    compile:
    - one survived because it mutated dead code (`ipc.readopt`, removed);
    - three are detected by the new same-hart tests, and the cross-hart
      shortcut from milestone 23 by the low-priority round;
    - two still survive, the known weakness since milestone 25: not
      yielding on the own hart after the floor drops (one of them is the new
      "never notify the own hart when replying"). The next tick corrects the
      choice, and no test measures that latency in a stable way.
  - Milestone 27: 7 of 9 (the two races only Debug detects). Milestones 22
    to 26: the usual survivors (two memory-ordering ones, idle at normal
    priority, the redundant cross-hart loan guard); two do not compile.
- **Limits:**
  - The worst case of the cross-hart inversion went from 253 to 439 µs
    (one call out of 1280, identical in three runs) while the minimum and
    the median improved. It looks like the alignment with QEMU's turns under
    `-icount` seen in earlier milestones, but I have not isolated it.
  - `Quiet` is checked at run time in `Wake_Boost`. That a server waiting in
    `recv`, or a client waiting for a reply from another hart, always
    satisfies it is an argument about the kernel, not a proof; if it ever
    failed, the kernel would stop with a clear message.
  - That `Held` matches the locks really taken is still Zig code: SPARK
    checks the set it is given, not the locks.
  - The rule is proved to be preserved by calls and replies across harts.
    On the same hart it still travels with the lent context and is checked
    by Debug.
  - Measurements are from QEMU with `-icount`, not real hardware.

## Milestone 31 — The inheritance rule, proved

- **Goal:** the rule "no server runs with less urgency than a client waiting
  for its reply" should no longer depend on unproved kernel code. Up to
  milestone 30 the floor was computed in Zig, which kept a copy (`floor_of`,
  `boosted`) that nothing checked.
- **SPARK, new package `Inherit_Gate`** (reads `Ipc_Core.Awaited` and the
  models of all harts):
  - **`Refresh`** recomputes a server's floor from all its clients, on any
    hart. It proves:
    - that the floor ends up at exactly the highest level among the clients,
      or 0 if there are none (`Is_Needed`);
    - that with it the server satisfies the rule (`Inherits`);
    - that no other thread's level changes;
    - that it does not fail if the thread exists.
  - **`Refresh_Chain`** walks the wait chain top-down and proves that the
    rule holds on every link. It relies on:
    - a frame lemma: if only the current link's level changes, the rule for
      the links above stays the same;
    - chain lemmas: `Lemma_Shift`, `Lemma_Distinct` (with no cycles, no live
      link repeats) and `Lemma_Stays_Zero`.
  - **`Holds`** tells whether the rule holds for every server. It proves that
    its result is exactly `for all S => Inherits (S)`. The Debug check on
    every system call (`ipc.checkInheritance`) uses this function, so it is
    no longer a separately written copy.
- **Strengthened contracts:**
  - `Ipc_Core.Waits_For` now states its result for every valid thread.
  - `Ipc_Core.Lemma_Acyclic`: the invariant implies there are no cycles.
  - `Sched_Gate.Boost` proves that the other threads' levels do not change
    and that `Is_Started` is preserved.
  - New `Floor_Of` (a thread's floor, never above its level) and `Has_Floor`
    (the minimal query for the fast path).
  - `Shared_View` ties its `Homes` to `Home_View`.
- **Kernel:**
  - `floor_of` and `boosted` are gone: the kernel keeps no copy of the floor.
    Whether a thread inherits is read from the model (`thread.hasFloorHere`;
    on the fast path the thread belongs to the current hart and the global
    lock is already held).
  - `ipc.refreshChain` lets the last link choose again among its deferred
    clients and then calls `Refresh_Chain`.
  - **Locks:** `kernel_lock.enterHarts` takes, with the global lock held,
    several hart locks in ascending order, to read several models at once.
    It creates no wait cycles: only one hart holds the global lock, and
    whoever holds a hart lock without the global one waits for no other
    lock. In Debug, `mayTouch` knows which harts are held.
  - `thread.boost` is removed; the notifications after changing floors are
    sent by `notifyHarts`.
- **Measurements** (`-icount`):

  | Measure, 1 hart (instructions) | Milestone 30 | Milestone 31 |
  |---|---|---|
  | Call and reply | 1903 | 1947 (+2.3%) |
  | Call with one intermediate hop | 4365 | 4446 (+1.9%) |
  | IPC round trip | 3462 | 3463 |
  | IPC without the measuring thread | 2882 | 2880 |
  | Context switch / `yield` | 413 / 582 | 413 / 583 |

  - **With 4 harts:**
    - same hart: 1936 → 1980 ns (+2.3%);
    - across harts: 4902 → 5221 ns (+6.5%);
    - stale inheritance: 2.8 µs median, unchanged.
  - **Where the cost comes from:**
    - On the same hart, reading the floor from the model instead of a kernel
      `bool`. The first version read it with a lock and full validation and
      cost 2057 instructions (+8%). `Has_Floor` without a lock brought it
      down to 1947.
    - Across harts, the two recomputations per round trip go through SPARK
      with the locks of all 4 harts.
  - **Tried and discarded:** taking only the locks of the harts involved
    gives 5372 ns. Working out which ones they are costs more than taking
    them all.
- **Tests** (122): the inheritance tests now check the SPARK rule
  (`ipc.ruleHolds`) in Release too, at five points: chain set up, client
  death, borrowed context, a deferred client changing, and death of the head
  of a chain.
- **Verification:**
  - **SPARK:** 1850 checks proved from scratch, none pending (1653 in
    milestone 30).
  - **Boots:** 8 of 8 in a row with 1 and with 4 harts, 2 of 2 with
    `-icount`, and Debug with 1 and with 4 harts. In Debug the rule is
    checked with `Holds` on every system call.
  - **Stress, run alone:**
    - with 1 hart, 128 of 128;
    - with 4 harts, 191 of 192 over two batches. The failure was the
      cross-hart inheritance test: the call took 99.7 ms instead of ~1 ms.
      It is the same pattern as in milestones 26 and 27 (124 ms), attributed
      then to host overload. This time it was not re-checked against the
      previous ELF.
- **Mutations:**
  - **SPARK, 7 of 7 detected:**
    - `Refresh` keeping the last client;
    - `Refresh` counting clients of other servers;
    - `Refresh` that never lowers the floor;
    - a chain that does not advance;
    - `Holds` with one level of slack;
    - `Floor_Of` returning the level;
    - `Has_Floor` not looking at the floor.
  - **Runtime, 12 of 14**, including those ported from milestones 25, 29
    and 30.
    - Detected: floor only across harts, `readopt` and `replyRecv` not
      recomputing the floor, chain not choosing again and not recomputing,
      no inheritance on call or when accepting from the queue, level without
      floor, no recomputation on kill, `setParams` not recomputing, fake
      slice, and counting donations without checking.
    - **"No notification to another hart" and "no yield on this hart"
      survive.** They are the same weakness as "inherit without notifying",
      which has survived since milestone 25. Without the notification the
      next tick corrects the choice, and no test measures that latency
      reliably.
  - **Milestone 27:** 7 of 9 in Release. The two usual races survive; only
    Debug detects them.
  - **Milestones 22-26:** 35 mutations.
    - The usual ones survive: acquire and release without ordering, idle at
      normal priority, and lending across harts allowed.
    - Two do not compile with the recovered patterns: "lock without turns"
      and "only the first noted notification".
- **Incident:** `provefull.sh`, run without an argument, used the scratchpad
  as its work directory and wiped it. The project code was not touched.
  - The measurement and mutation scripts were lost, as were the copies of
    earlier milestones' trees.
  - The scripts were recovered from the session log or rewritten. They now
    require a directory name and work only inside `work/`.
  - Mutations targeting code that has been replaced (`boosted`, `floor_of`,
    `thread.boost`) were ported to `mutate31.py`.
- **Limits:**
  - **When to recompute:** each recomputation is proved to leave the rule
    satisfied, but not that the kernel recomputes at every moment it is
    needed. That is still covered by the Debug check, now with the same
    definition that is proved.
  - **Concurrency:** that `enterHarts` is enough to read several models is
    an argument about the locks, as in milestone 27, not a proof.
  - **Cost:** +2.3% on the call with 1 hart and +6.5% across harts.
  - **Measurements:** these come from QEMU with `-icount`, not real hardware.

## Milestone 30 — Recovering the 1-hart cost without losing what is proved

- **Goal:** milestone 29 cost up to 3.6% with 1 hart (the `max` in
  `Level_Of` on every decision). Recover it without losing any proved
  guarantee.
- **SPARK, the stored level:**
  - `Scheduler_Core` stores each thread's level in `Levels`, and `Valid`
    includes the invariant `Levels_Ok`: for every thread,
    `Levels (T) = max (Priorities (Ctx T), Floors (T))`. So
    `Level_Of (T) = Levels (T)` is a read, with no `max`.
  - Only two procedures write `Levels`: `Move_Level` (one thread) and
    `Recompute_Members` (all). Their postconditions state that the whole
    model stays the same except `Members` and `Levels`, and that `Levels_Ok`
    holds. Every other operation inherits it from `Valid`.
- **Fused hand-off:**
  - `Sched_Gate.Hand_Off_Grant` (`fb_sched_hand_off_grant`) hands off and at
    the same time returns what is left of `peer`'s context (`Granted`) and
    whether there was a donation (`Donated`, i.e. whether `peer`'s context is
    the one that was paying before).
  - Both outputs are in the postcondition. It replaces one call to
    `fb_sched_remaining` and two to `fb_sched_context` per hand-off.
- **Measurements** (`-icount`, instructions per operation):

  | Measure, 1 hart | Milestone 28 | Milestone 29 | Milestone 30 |
  |---|---|---|---|
  | Call and reply | 1929 | 1977 | **1903** |
  | Call with one intermediate hop | 4344 | 4408 | 4365 |
  | IPC round trip (with the measuring thread) | 3464 | 3482 | 3462 |
  | IPC without the measuring thread (new) | — | — | 2882 |

  - The milestone 29 column was re-measured in the same session. The numbers
    depend on the history of the adaptive quantum: the call with one hop
    gave 4498 in the milestone 29 entry.
  - **Broken down:** the fused hand-off alone brings the call to 1931; the
    stored level brings it to 1903. A variant without the floor in
    `Level_Of` gives 1883, so about 20 instructions remain from milestone 29.
  - **Correction to milestone 27:** its +6.6% on IPC was not IPC. The
    measurement includes the polling main thread, and its switch from the
    global lock to the hart lock (`kernel_lock.resumeChanging`) accounts for
    the difference. Pure IPC went down in milestone 27 (milestone 26: 3003;
    milestones 27 and 30: 2882-2884). That is why the "without the measuring
    thread" measurement was added. It runs last because it resets thread 0's
    budget: placed earlier, it changed the chained-call figure.
  - **With 4 harts:**
    - same hart: 2010 → 1936 ns (-3.7%);
    - across harts: 4960 → 4902 ns (-1.2%);
    - stale inheritance: 2.8 µs median, unchanged.
  - Context switch (413) and `yield` (582), unchanged.
- **New tests** (122 in total):
  - **Exact slice:** the direct hand-off test now also checks that the slice
    granted is exactly what was left of the context. The thread runs with
    interrupts off, so no tick can repair it before it is checked.
  - **Donation that does not apply:** a thread receives a donation and
    blocks with it. Another thread that cannot lend it anything more urgent
    wakes it. It keeps the first context and the donation counter does not
    go up.
  - They were needed: the two runtime mutations of milestone 30 survived. A
    slice of 1 corrected itself on the next tick, and no test asked for a
    donation that did not apply.
- **Verification:**
  - **SPARK:** 1653 checks proved from scratch, none pending
    (`Scheduler_Core`, 353).
  - **Boots:** 122 self-tests, 8 of 8 in a row with 1 and with 4 harts, 2 of
    2 with `-icount`, and Debug with 4 harts.
  - **Stress, run alone:** 128 of 128 with 1 hart and 96 of 96 with 4.
- **Mutations:**
  - **SPARK, milestone 30, 6 of 6 detected:**
    - `Move_Level` without storing the level;
    - `Recompute_Members` without storing the level;
    - `Granted` from the thread's own context;
    - `Donated` without comparing;
    - payer read after the hand-off;
    - `Valid` without the levels invariant.
  - **Runtime, milestone 30, 2 of 2** with the new tests: slice with a fake
    remainder and counting donations without checking.
  - **Milestone 29, again** (`Scheduler_Core` changed): 6 of 6 in SPARK and
    8 of 8 at runtime.
  - **Milestone 27:** 8 of 10 in Release. The two races survive, as always;
    only Debug detects them.
  - **Milestones 22-26:** the same survivors as in milestone 29, no new ones:
    - acquire without ordering and release without ordering;
    - idle at normal priority;
    - lending across harts allowed;
    - inherit without notifying;
    - the trap not taking the lock (Debug detects it);
    - "lock without turns", which does not compile unless ported by hand.
- **Limits:**
  - **The kernel's cached floor** (`floor_of`): the milestone 28 mutation
    targeting it is still alive. What is proved is the model's floor.
  - **What remains of the cost:** the ~20 instructions left with 1 hart come
    from maintaining `Levels` in `Move_Level`. It is the price of a proved
    invariant.
  - **Measurements:** these come from QEMU with `-icount`, not real hardware,
    and are sensitive to the order of the measurements.

## Milestone 29 — What is inherited belongs to the thread, not the context

- **Contract:** a server never runs with less urgency than a client waiting
  for its reply, in progress or deferred. In Debug it is checked on entry to
  every system call (`ipc.checkInheritance`).
- **The two gaps left by milestone 28:**
  - **Borrowed context:** `Boost` raised the priority of the server's own
    context. If the server was running with the context of a client on its
    hart (for example, because it had deferred it), the urgency of a client
    from another hart did not reach it.
  - **Deferred client gaining urgency:** the server did not choose a context
    again until its next IPC operation.
- **What the analysis showed:** a blocked client accepts no new clients, so
  through IPC its urgency never rises while it waits. It only changes in
  three ways: on kill, on cancel, or through the kernel's `setParams`. A case
  that was not on the list also turned up. In a chain A → B → C on the same
  hart, if A dies, A recovers its context from B and from C. Each goes back
  to its own, and if B's priority is higher than C's, C serves B with less
  urgency than B has.
- **SPARK, the floor belongs to the thread:**
  - `Scheduler_Core` has `Floors`, indexed by thread, and
    `Level_Of (T) = max (Priorities (Ctx T), Floors (T))`. So a thread runs at
    least at its floor, whatever context it uses.
  - `Set_Floor` (replaces `Set_Priority`) changes only that floor and that
    thread's level set. It proves this through equality of the whole model
    except `Floors` and `Members`.
  - Every other operation proves `Floors` unchanged: charging, picking,
    handing off, adopting, releasing, waking, blocking and setting
    parameters. So no context change undoes what is inherited.
  - `Start` and `Finish` set the floor to 0. `Create` proves that a reused
    slot starts with no floor and the default priority.
  - **`Sched_Gate`:** `Boost` changes only the floor, and its postcondition
    states that the effective priority becomes `max (that of the context
    actually in use, Level)`. `Priority_Of` returns `Level_Of`. `Base` and
    `Floor` leave the shared state, which keeps only `Homes` and `Used`.
- **Kernel:**
  - **The floor counts all waiting clients, from any hart.** On the
    same-hart fast path it is not computed, since the borrowed context is
    enough there. It is recomputed when the client is from another hart or
    inherits itself (`needsFloor`).
  - **`refreshChain` replaces `propagate`.** After cancelling a wait (on
    kill) or changing the parameters of a waiting thread, it walks once,
    top-down, the chain starting at its server. It recomputes each floor with
    the client's already updated level, and the last link chooses again among
    its deferred clients. It does not stop when a floor is unchanged, because
    the level may have changed when a context was lost.
  - **Why that chain is enough:** only the levels of the affected thread and
    of those using its context change, and those are exactly the ones further
    down.
  - **Why `propagate` was removed:** it only had a chain below on kill, and
    the rebuild already ran there. The mutations showed it: with it in place,
    "propagate only across harts" and "a single pass" survived.
- **Measurements** (`-icount`, against milestone 28):
  - **With 1 hart** (instructions per operation):
    - call and reply: 1929 → 1977 (+2.5%);
    - IPC: 3464 → 3482 (+0.5%);
    - call with one intermediate hop: 4343 → 4498 (+3.6%);
    - context switch: 413, unchanged.
  - **Cost attribution with 1 hart:** with only `Level_Of` returned to its
    old form, the figures go back to 1930, 3466 and 4343. The whole cost is
    the proved model's `max` on every scheduler decision. Marking
    `updateBoost` as `noinline` changes nothing.
  - **With 4 harts:**
    - round trip across harts: 5317 → 4960 ns (-6.7%), because the chain is
      no longer walked when raising and lowering the floor;
    - same hart: 1962 → 2010 ns (+2.4%, the same `max`);
    - stale inheritance (the milestone 28 measurement): 3.1 → 2.8 µs median
      (min 2.7, max 10.8, four identical runs).
  - **The 259 µs spike, investigated:** with `recomputeAll`, the first design
    that redid every thread over several passes, the median was 4.7 µs with
    spikes of 259 µs. Bounding it to the chain brought the median down to
    2.8 µs. With instrumentation the spike appeared in 3 of 20 repetitions
    with some probes and in none with others. What was seen:
    - hart 0 was idle;
    - hart 2 received a single notification and no tick;
    - in the normal case, the notification is handled at 2.2 µs and the
      thread runs at 2.8 µs.

    It is QEMU's turn-taking with `-icount` and several harts: the milestone
    28 inversion measurement already had its "worst" at 254 µs. The final,
    uninstrumented binary does not show it in 20 repetitions.
- **New tests** (121 in total):
  - **Borrowed context** (≥ 2 harts): the server defers a client from its
    hart and keeps its context. Then an urgent client from another hart calls
    it. It runs with that urgency without dropping the borrowed context, and
    the lender's priority does not change.
  - **Deferred client gaining urgency:** the server switches to its context
    as soon as the kernel raises its priority.
  - **Head of a same-hart chain A → B → C dies:** C is left with B's
    urgency, and with no clients it returns to its own.
  - **Answering a client from another hart with `reply`** (≥ 2 harts): the
    server goes back to the urgency of its remaining deferred client and keeps
    its context. It was needed: once death went through `refreshChain`,
    nothing tested any more that `reply` drops what was inherited, and the
    mutation "25: the server does not return to its priority" started to
    survive.
- **Verification:**
  - **SPARK:** 1630 checks proved from scratch, none pending (1631 in
    milestone 28: `Set_Priority` goes, `Set_Floor` and the frames come in).
    The first pass left 4 pending because the `Floors` frame was missing in
    the helpers `Reclaim` and `Return_To`. `Hand_Off` needed intermediate
    assertions.
  - **Boots:** 121 self-tests, 8 of 8 in a row with 1 and with 4 harts, 2 of
    2 with `-icount`, and Debug with 1 and with 4 harts. In Debug the contract
    check never fired on any system call.
  - **Stress, run alone:** 128 of 128 with 1 hart and 96 of 96 with 4.
- **Mutations:**
  - **SPARK, 6 of 6 detected:** level without floor, `Start` and `Finish`
    not forgetting the floor, `Boost` ignoring the level, `Set_Floor` without
    moving the level, and `Priority_Of` without the floor.
  - **Runtime, milestone 29, 8 of 8:**
    - level without floor;
    - no recomputation on kill;
    - not choosing a context again;
    - floor only from clients on another hart;
    - not inheriting what the client inherits;
    - `setParams` not recomputing;
    - stopping when the floor is unchanged;
    - recomputing only the first link.
  - **Milestone 27, 10 of 10:** the two races, as before, only in Debug.
  - **Milestone 28:** of its four runtime mutations, three targeted
    `propagate`, which no longer exists. The remaining one, "not forgetting
    what was inherited on death" (in the kernel's `floor_of` cache), still
    survives. The SPARK model's floor is proved to return to 0.
  - **Milestones 22-26, 34 of 40:**
    - **The usual 5 survive:** acquire without ordering, release without
      ordering, idle at normal priority, lending across harts allowed, and
      inherit without notifying.
    - "The trap does not take the lock" survives in Release and Debug detects
      it.
    - **"Lock without turns"** (ported by hand) survives 4 of 4 with the
      machine idle, and also 3 of 3 applied to milestone 28's code: detecting
      it depends on host load, not on this milestone.
- **Limits:**
  - **Queued clients:** a client still in a queue waits for nobody
    (`Awaited` is 0 until it is received), so it passes nothing on to anyone.
    That is the usual rule.
  - **Debug check, not a proof:** the global contract is checked at run time.
    The per-model part (the floor survives any context change) is proved in
    SPARK. What is not proved is that the kernel recomputes the floor every
    time it is needed.
  - **Inheritance without budget:** what is inherited as a floor is urgency
    only. The server spends it with its own context, without charging the
    client.
  - **Measurements:** these come from QEMU with `-icount`, not real hardware.

## Milestone 28 — Transitive priority inheritance across harts

- **Problem:** with milestone 25, a server on another hart inherits its
  client's effective priority when accepting the call. Since that priority
  already includes what the client inherits, inheritance was already
  transitive at call time. But changes did not travel along a chain already
  set up. If A (top) → B → C and A died, B returned to its priority, but C
  kept A's urgency until it replied. A normal thread on C's hart waited all
  that time.
- **What can change in a chain:** all its threads but the last are blocked
  waiting for a reply, and a blocked thread accepts no new clients. So in an
  established chain urgency can only go down: a client dies or is cancelled.
- **Design:** `ipc.updateBoost` remembers what each server inherits
  (`floor_of`). If it changes, it follows the chain of who waits for whom
  (`propagate`):
  - on a cross-hart edge, it recomputes what is inherited, and stops if it is
    unchanged;
  - on a same-hart edge it keeps going, because the priority already travels
    through the borrowed context.
- **SPARK (`Ipc_Core`):** the invariant now includes that reply waits form no
  cycles (`Acyclic`). `Waits_For` exports the theorem.
  - **Definitions:** `Step` gives the thread being waited for; `Iter`, the one
    reached in K steps, unrolled up to Max_Threads so that the initial
    condition is proved without induction.
  - **Proof:** a new link always goes to a server that waits for nobody
    (`Link` now requires it, and its two callers already satisfied it). The
    lemmas `Lemma_Add` and `Lemma_Remove`, by induction on K, prove that
    linking this way and removing links preserve `Acyclic`.
  - **Consequence:** the chain repeats no thread, so it has at most
    Max_Threads − 2 links. `propagate` always terminates. If it ever took
    Max_Threads steps it would panic, which the proof rules out.
- **Measurements** (4 harts, `-icount`, 5 repetitions). The chain is A (hart
  0, top) → B (hart 1) → C (hart 2, spinning 2^21 iterations before
  replying), with a normal thread waiting on C's hart. A is killed and the
  time until that thread runs is measured:
  - **with propagation:** 3.1 µs in all five;
  - **without it** (milestone 27 behaviour, same build with propagation
    removed): 3.98 to 4.19 ms, about 1300 times more;
  - **cost:** the round trip across harts goes from 5214 to 5317 ns (+2%),
    because it recomputes what is inherited on the way up and down.
  - **Adjustments to the measurement setup:**
    - hart 0 waits with `wfi`; when spinning, with `-icount` the notification
      to the other hart waited until the end of QEMU's turn;
    - the normal thread gets its priority explicitly;
    - A is killed only once C is already running on its hart. Without this,
      the measurement came out bimodal (3 µs or 467 µs) depending on where
      the hart was.
- **Cost with 1 hart:** none measurable. Call and reply stays at 1929
  instructions and IPC goes from 3458 to 3464.
- **New tests** (117 in total): the chain A → B → C across harts, and with 3
  or more harts A → B → D → C, where D is on B's hart and works with its
  borrowed context. C inherits A's urgency along the whole chain, and when A
  is killed everyone returns to their priority without waiting for C to
  reply.
- **New Debug check:** every system call runs with the global lock, like the
  milestone 27 rights check.
- **Verification:**
  - **SPARK:** 1631 checks proved from scratch, none pending (1576 in
    milestone 27).
  - **Boots:** 117 self-tests, 8 of 8 in a row with 1 and with 4 harts, 2 of
    2 with `-icount`, and Debug with 1 and with 4 harts.
  - **Stress, run alone:** 128 of 128 with 1 hart and 96 of 96 with 4.
- **Mutations:**
  - **SPARK, 4 of 4 detected:** receiving while waiting for a reply, removing
    the wait without the lemma, linking without the lemma, and cancelling
    while leaving the wait.
  - **Runtime, milestone 28, 3 of 4:** "no propagation", "stop at a same-hart
    edge" (thanks to the B → D stretch) and "the chain does not advance"
    (panic on a cycle) are detected. "Not forgetting what was inherited on
    death" survives: it would only show if a reused slot inherited exactly
    the same level as its previous occupant, and no test triggers that case.
  - **Milestone 27, 10 of 10**, with the two races detected in Debug.
  - **Milestones 22-26, 35 of 40.** The 5 survivors are the same as in
    milestones 26 and 27. "The trap does not take the lock" survived one pass
    in Release, because it is a race. It was detected on repeat, and in Debug
    the new check always detects it.
- **Limits:**
  - **Borrowed context on the same hart:** if a server runs with the context
    of a client on its own hart, `Boost` raises the priority of its own
    context, not the borrowed one (inherited from milestone 25). Unchanged.
  - **Deferred replies on the same hart:** if a deferred client's urgency
    rises, the server does not choose a context again until its next IPC
    operation.
  - **Reading the model:** priorities are read from the models with each
    hart's lock, one after another. The whole chain is recomputed with the
    global lock held, so whatever changes does so with IPC stopped.
  - **Measurements:** these come from QEMU with `-icount`, not real hardware.

## Milestone 27 — One lock per hart

- **Goal:** remove the tails that milestone 26 exposed. With a single lock for
  the whole kernel, whenever QEMU took the turn away from the hart holding it,
  the others spun until it came back, even for the tick or to yield the CPU.
- **Design, two levels:**
  - **Global (G):** IPC, processes, memory, sleepers, and the shared part of
    the scheduler: each thread's hart, its base and inherited priorities, and
    which slots are in use.
  - **One per hart (L[h]):** h's SPARK scheduler model and its local state
    (current thread, slice, charging).
  - **Access rule:** a hart touches its own model with G **or** L[h]; another
    hart, with G **and** L[h]. System calls, which already hold G, pay for no
    extra lock. The tick, yielding the CPU, notifications and thread switches
    only use L[h].
  - **Order:** G before L, and never two Ls at once. Two run-time panics
    enforce it.
  - **Thread switch:** the locks pass to the incoming thread, with the depths
    it keeps on its stack (`kernel_lock.resumeThread`). If it needs G and the
    hart does not have it, it releases L, takes G and, if needed, takes L
    again. The normal case (same locks) goes through an inline fast path.
  - **Sleepers:** the tick reads an atomic copy of the nearest deadline and
    only takes G if someone is already due.
- **Foundation:**
  - **No deadlocks:** with the order G < L[h] and never two Ls at once, the
    wait graph has no cycles.
  - **Bounded wait on a hart lock:** inside L[h] nobody ever waits for another
    lock. So with ticket locks the wait for L[h] is bounded by N−1 L[h]
    sections, which are short. It no longer depends on how long a G section
    lasts (IPC, destroying an address space). Exception: the tick takes G if
    a sleeper is already due.
  - **Mutual exclusion across harts:** two accesses from different harts to
    the same model never overlap. The one from another hart holds G, which
    excludes the owner when it works with G, and L[h], which excludes it when
    it works with L[h].
- **SPARK:** the scheduler gate no longer has the `Current` variable or
  `Set_Hart`, which were state shared across harts. Every operation receives
  the hart.
  - The postconditions prove that each operation changes only that hart's
    model (`Only_Hart`) and does not touch the shared state (`Shared_View`),
    except what Create, Exit_Thread, Set_Params and Boost are meant to touch.
  - Create looks for a free slot in a `Used` table, protected by G, instead of
    reading the other harts' models. The `Homes_Ok` invariant adds that an
    existing thread is recorded as used.
  - That each body only **reads** its own hart's model is checked by reading
    the code; it is not proved.
- **Results with 4 harts** (same benchmark as milestone 26; virtual-clock ns,
  min / median / max over 5 repetitions):

| Operation | Milestone 26 | Milestone 27 |
|---|---|---|
| Round trip, same hart | 2004 / 2005 / 8940 | 1962 / 1962 / 1962 |
| — worst single operation | 28.4 ms | 3.5 µs |
| Round trip, across harts | 5542 / 5815 / 13088 | 5302 / 5302 / 5363 |
| — worst single operation | 8.1 ms | 3.6 µs |
| Wake the other hart (median) | 3287 | 2705 |
| Inversion across harts: server runs (median) | 10783 | 10756 |

  - **Waits longer than 100000 instructions:** in milestone 26's slow
    repetitions there were 5 to 12 on the single lock. Now there are 0 to 1
    per repetition, between G and the hart locks.
  - Against Linux (milestone 26: 12622 and 24927 with futex), the advantage in
    the medians holds, and the repetitions are now as regular as Linux's.
- **Cost with 1 hart** (instructions per operation, milestone 26 → 27):
  - system call: 205 → 208;
  - call and reply: 1872 → 1929 (+3%);
  - call with one intermediate hop: 4451 → 4339;
  - IPC round trip: 3244 → 3458 (+6.6%);
  - context switch: 375 → 413;
  - maximum latency: 1.4 → 1.6 µs.

  The per-function profile attributes the rest to the generic lock section
  (checking G before taking L) and to saving and restoring the depths on a
  thread switch. Two earlier versions cost more:
  - taking L even with G: call and reply 2016;
  - without the thread-switch fast path: context switch 443, with
    `resumeThread` alone adding about 40 instructions per switch.
- **Rights check in Debug** (lockdep-style): every SPARK call on a hart's
  model checks that the caller has the right to it, and those that change
  shared state, that G is held. So a race the tests never manage to trigger
  is still detected. It costs nothing in Release.
- **Strengthened specification:** one mutation survived the proof.
  `Wake_Remote` could return `Wrong_State` for no reason, because the
  postcondition did not say when it had to succeed. Now it is proved that a
  thread blocked on its hart always wakes. Likewise for `Boost`: an existing
  thread always inherits.
- **New tests** (116 in total):
  - with G held by one hart, another hart keeps handling its tick and
    switching threads;
  - G travels with the thread: a thread that blocks holding it twice releases
    it when switching to one that does not hold it, and on return really
    holds it again, with its depth;
  - the gate rejects a non-existent hart in every operation;
  - the deadline copy is cleared when a sleeper is killed.
- **Verification:**
  - **SPARK:** 1576 checks proved from scratch, none pending (1520 in
    milestone 26).
  - **Boots:** 116 self-tests, 8 of 8 in a row with 1 and with 4 harts, 2 of
    2 with `-icount`, and Debug with 1 and with 4 harts.
  - **Stress, run alone** (4 QEMU instances at once):
    - milestone 27: 128 of 128 with 1 hart and 96 of 96 with 4;
    - milestone 26 under the same conditions: 128 of 128 and 95 of 96.
  - **Stress alongside mutations and proof:** 4 of 128 and 8 of 96 failed,
    always in tests that depend on real time (budgets, inversion). Repeated
    alone, they disappear: it is host overload.
- **Mutations:**
  - **SPARK:** 5 of 5 detected: exiting without freeing the slot, creating
    without marking it, picking in hart 0's model, and waking and inheriting
    on hart 0. The last two only after strengthening the specification.
  - **Runtime, milestone 27:** 10 of 10.
    - 8 in Release: by panic (the tick taking the global lock, the own model
      with no lock, not copying the deadline, the new thread inheriting the
      locks) or by hang (not releasing or not re-taking the global lock,
      taking the global lock while holding the hart lock, the fast path not
      checking the hart lock).
    - The 2 races (waking and creating on another hart without its lock)
      survive in Release; in Debug the rights check detects them.
  - **Milestones 22-26 on the new code:** 35 of 40 (30 as they were and 10
    ported). The 5 survivors already survived in milestone 26: two memory
    ordering ones that QEMU does not make visible, idle at normal priority,
    lending across harts allowed, and inherit without notifying.
- **Limits:**
  - That each SPARK body only **reads** its own hart's model is not proved,
    only reviewed. What is proved is that it only writes to it.
  - The tick takes G when a sleeper is already due; there it depends on G
    sections again.
  - Cross-hart IPC still goes through G. The wait for G by a thread resuming
    after a notification is now the only tail, and in the benchmark it stays
    at 0-1 long waits per repetition.
  - With 1 hart it costs 3% on call and reply, 6.6% on IPC and about 40
    instructions per context switch.
  - The figures come from QEMU with `-icount` (harts in turns), not real
    hardware.

## Milestone 26 — Comparison with Linux on 4 harts

- **Setup:** the same operations in Fabianus (`benchmark.runSmp`) and in
  Linux 6.12 (`tools/compare/linux_smp.c`, with `run_linux.sh <dir> smp`).
  Both run on the same QEMU with 4 harts and `-icount shift=0,sleep=off`,
  with processes in separate address spaces pinned to their hart, and measure
  with `rdtime` from user space. Each measurement is repeated 5 times and the
  minimum and median are reported.
- **What the clock measures:** with `-icount`, QEMU runs the harts in turns
  over a single counter. The virtual clock and `instret` count the
  instructions of the whole machine, at 1 ns per instruction. The calibration
  confirms it: a loop of 2000001 instructions gives 2000000 ns with the other
  harts idle, and 2517600 with another hart spinning. That is why per-hart
  counters are not summed (nor per-CPU `perf` on Linux, which would read the
  same counter).
- **Results** (virtual-clock ns, i.e. whole-machine instructions; median of
  5 repetitions):

| Operation | Fabianus | Linux |
|---|---|---|
| Round trip, same hart | 2005 (call) | 12622 (futex), 14273 (pipe) |
| Round trip, across harts | 5815 (call) | 24927 (futex), 25869 (pipe) |
| Wake the other hart | 3287 | 12537 (futex) |
| Inversion across harts: server starts running | 10783 (inheritance, milestone 25) | 59514 (futex PI) |

- **Kernel improvement: the cross-hart notification goes out when the lock is
  released.**
  - **The problem:** with the kernel lock held, the notified hart woke up only
    to spin on the lock still held by the notifier.
  - **The fix:** the notification is now noted on the hart (next to the lock
    depth) and sent when that depth drops to 0.
  - **Effect:** the cross-hart round trip went from about 196000 ns to about
    5500.
  - **Cost on one hart, against the same build without it:** system call
    203 → 205 instructions, context switch 373 → 375, call 1868 → 1872.
- **The cross-hart inversion is milestone 25's case.** A top-priority client
  calls a lowest-priority server on another hart, where a high-priority
  process is spinning. On Linux the equivalent uses futex PI: H
  (`SCHED_FIFO` 90) requests a lock held by L (`SCHED_FIFO` 10), while M
  (`SCHED_FIFO` 50) spins on L's CPU.
- **What is not compared:**
  - **the whole call with a hart spinning** (about 140 µs in Fabianus and
    about 296 µs in Linux): after the server replies, QEMU lets the spinning
    hart finish its turn before returning to the client;
  - **single-hart measurements** stay in the `-Dsmp=1` build: with more harts,
    the secondaries spin waiting to start, and under `-icount` that advances
    the clock.
- **Fabianus' tails come from the single lock.** Linux gives nearly identical
  repetitions (futex across CPUs: 24770 to 25703); Fabianus does not (5542 to
  13088). The slow repetitions are the ones with waits longer than 100000
  instructions on the kernel lock (5 to 12), and the clean ones have none:
  the hart holding the lock loses its QEMU turn and the other spins until the
  next turn. It is the lock-holder preemption problem of virtual machines.
  Linux suffers it less because its locks are per CPU.
- **Correction to milestone 15:** the Linux probe was not running with
  `SCHED_FIFO`. musl's `sched_setscheduler` always returns `ENOSYS`, and
  `linux_bench.c` did not check the result; it now uses the system call
  directly and checks the policy. Linux with real `SCHED_FIFO` 99 has a worst
  case of 15.5 µs unloaded and 9.9 µs with 3 busy processes, not "up to about
  4 ms". Fabianus stays at 1 µs. The figure of about 4 ms corresponds to equal
  priority (EEVDF), and that one stands (3.98 ms).
- **New tests:**
  - a notification with the lock held does not go out until it is released,
    and then it does;
  - two notifications noted for different harts both go out;
  - without the lock, the notification goes out immediately.
- **Verification:**
  - full proof with no pending checks (1520; no SPARK code changed);
  - 114 self-tests in 8 of 8 boots in a row with 1 hart and with 4, in 2 of 2
    with 4 harts under `-icount`, and in Debug;
  - with 4 QEMU instances in parallel:
    - 128 of 128 boots with 1 hart;
    - 95 of 96 with 4 harts. The failure was milestone 25's inheritance test:
      the call took 124 ms (normally 1 ms);
    - milestone 25's ELF under the same conditions gives the same
      distribution: median 916 µs against 1000, and maximum 15 ms against 17;
    - it is the tail of host overload, as in milestone 24.
- **Mutations:**
  - 5 of 6 for the deferred notification. Two of them ("only the first noted
    notification" and "noting without the lock") were only detected after
    extending the test;
  - "send just before releasing" survives, and is equivalent in practice: the
    measurement gives exactly the same figures, because the window is a few
    instructions. What mattered was not notifying from inside the critical
    section;
  - those of milestones 13 to 25 are still detected, except the known
    survivors. "Kernel lock without turns (icount)", which used to survive,
    is now detected.
- **Limits:**
  - everything is measured in QEMU with harts in turns, not in parallel. The
    figures are whole-machine instructions, not latency on real hardware;
  - the single kernel lock is what most separates Fabianus from Linux in the
    tails.

## Milestone 25 — Priority inheritance across harts

- **The problem:** a top-priority client on one hart called a lowest-priority
  server on another, where a high-priority thread was spinning. The server did
  not run until that thread finished: unprotected priority inversion, the last
  real-time gap that SMP left open.
- **The solution:** priority inheritance. The server runs, in its hart's
  model, at least at the priority of the most urgent client from another hart
  waiting for its reply (in progress or deferred). Budget is not lent across
  harts, because each hart keeps its own accounting: urgency is inherited,
  not CPU time.
- **Proved in SPARK:**
  - `Set_Priority` changes only a context's priority; the budget, what is left
    of it and the debt do not change. Raising priority does not give more
    time;
  - `Boost` inherits in the server's hart model from any hart, without
    touching the other models, and says which hart to notify (the
    `Wake_Remote` rule);
  - `Set_Params` changes the base priority and respects what is inherited.
- **When it is inherited and when it is undone:**
  - it is inherited when calling a waiting server, and when receiving a call
    from another hart out of the queue;
  - it is recomputed on reply (`reply`, `reply_recv`, `reply_to`) and when a
    waiting client dies.
- **Measurements:**
  - with a high-priority thread spinning on the server's hart, the call
    replies in about 800 µs; without inheritance, about 98 ms (the time that
    thread takes to finish);
  - the local call goes from 1847 to 1868 instructions (+21): it only checks
    whether client and server are on the same hart.
- **New tests:**
  - the server on another hart inherits, replies without waiting for the
    spinning thread, and returns to its priority;
  - receiving from the queue makes it inherit, and what is inherited is
    undone if the client dies.
- **Verification:**
  - full proof with no pending checks (1520);
  - 113 self-tests in 8 of 8 boots in a row with 1 hart and with 4, in 2 of 2
    with 4 harts under `-icount`, and in Debug;
  - under load, 0 failures in 32 boots with 4 harts and in 128 with 1.
- **Mutations:**
  - those of milestones 13 to 24 are still detected, except the known
    survivors;
  - 4 of 5 runtime and 3 of 3 SPARK. Two of the runtime ones (receiving from
    the queue and undoing when the client dies) were only detected after
    adding the second test;
  - "inherit without notifying" survives, and is equivalent with the current
    uses: on a call the server inherits while blocked, and the notification
    comes from the wake-up that follows; when receiving from the queue, the
    server is the current thread.
- **Limits:**
  - inheritance is one hop: if the server in turn calls another hart, the
    inherited priority travels in that new call, but is not updated if it
    changes later;
  - a server running with the context lent by a client on its own hart keeps
    that context, and what is inherited applies to its own priority.

## Milestone 24 — SMP, stage 3: inter-hart interrupts, ticket lock and tickless idle

- **Inter-hart interrupts (IPI), without SBI and with minimal privilege:**
  - the kernel writes the target hart's `msip` word in the CLINT;
  - PMP only allows it those 16 bytes, never `mtimecmp`;
  - on the target, a 16-instruction machine-mode handler clears `msip` and
    raises the supervisor software interrupt;
  - the kernel handles it with the lock held and reschedules.
- **Proved in SPARK:**
  - `Wake_Remote` wakes the thread in its hart's model. The notification
    always goes to that hart, and only if the woken thread outranks the one
    running there or thread 0, which may be asleep, is running there. No
    other model changes;
  - `Alone` tells whether nobody else is ready on the hart.
- **Tickless idle:** a secondary hart whose idle thread is the only one ready
  sleeps until it is notified or a sleeping thread wakes, like Linux's NO_HZ.
  Before, it entered the kernel every 1 ms just to check there was nothing to
  do. Creating a thread on another hart also notifies it.
- **Killing on another hart** notifies that hart: the process dies in about
  400 µs instead of waiting for the tick.
- **Ticket lock for the kernel lock:**
  - harts enter in arrival order: with N harts, a waiter lets at most N − 1
    critical sections through;
  - with the `amoswap` one, QEMU under `-icount` (turn-based time sharing)
    left one hart unable to enter and the cross-hart call test hung. It was a
    bug in milestones 22 and 23;
  - cost: with tickets, stress with 4 harts failed 9 of 64 times. The virtual
    CPUs outnumbered the real cores and the idle harts requested the lock
    1000 times per second. Tickless idle brought it to 0 of 64.
- **Measurements:**

  | operation | milestone 23 | milestone 24 |
  |---|---|---|
  | notification round trip (to itself) | — | 494 instructions |
  | free lock, take and release | 6 (`amoswap`) | 11 (tickets) |
  | context switch | 362 | 373 |
  | system call | 198 | 203 |
  | call and reply | 1827 | 1847 |
  | 65 cross-hart calls (real time, including process creation) | ~120 ms | ~10 ms |
  | killing a process spinning on another hart | until the tick (10 ms) | ~400 µs |
  | timer interrupts of an idle hart in 100 ms | ~110 | ≤ 2 |

- **New tests:**
  - cross-hart calls use notifications, and some notification makes the woken
    thread run;
  - the supervisor can only touch the `msip` words;
  - killing on another hart sends a notification and it arrives;
  - with one hart holding the lock almost all the time, the others still get
    in;
  - a hart with no work sleeps without a tick;
  - two busy threads on another hart take turns;
  - a lowest-priority thread on another hart finishes even though it shares
    its turn with the idle thread.
- **Verification:**
  - full proof with no pending checks (1479);
  - 111 self-tests in 8 of 8 boots in a row with 1 hart and with 4, in 2 of 2
    with 4 harts under `-icount`, and in Debug;
  - under load, 0 failures in 32 boots with 4 harts and in 128 with 1;
  - stress found a race in the kill-on-another-hart test (the tick could kill
    before the notification arrived), now fixed.
- **Mutations:**
  - notifications, tickets and idle: 15 of 17 detected. Two survive:
    - idle at normal priority, which only adds latency because the idle hart
      is notified anyway;
    - the kernel lock without turns under `-icount`: with tickless idle there
      is hardly any contention left, and the tickets' advantage remains as a
      bound proved by hand;
  - SPARK: 5 of 5;
  - those of milestones 13 to 23 are still detected, except the known
    survivors;
  - "the secondary does not start its timer" (milestone 23) survived until the
    turn-taking test was hardened.
- **Limits:**
  - QEMU is no good for measuring fine-grained latency across harts: in real
    time there is host noise, and under `-icount` the turn-based sharing (a
    sleeping hart is only revisited once per round);
  - a lowest-priority thread on a secondary shares its turn with the idle
    thread.

## Milestone 23 — SMP, stage 2: one scheduler per hart

- **Per-hart model (SPARK):** the gate keeps one scheduler model per hart and
  the hart each thread belongs to. It is proved that a thread exists only in
  its hart's model (`Homes_Ok`): creating looks for a free slot across all
  models, and choosing an out-of-range hart is impossible.
- **Global kernel lock:** recursive per hart. Traps and every critical section
  take it. Each thread saves its depth on a thread switch, and a new thread
  releases it when it starts.
- **Hart identity:** the hart number lives in `tp`. Trap entry recovers it
  from the top of the thread's trap stack, because user code can change `tp`.
- **Affinity:** every thread and every process belongs to a hart and only
  runs there. The secondaries no longer just wait: they run their threads.
- **Across harts:**
  - waking a thread on another hart makes it ready in its model;
  - there is no direct hand-off or lending across harts (a test guarantees
    it);
  - the woken thread waits for its hart's next tick. 65 cross-hart calls take
    about 125 ms, against about 6 ms on the same hart. Inter-hart interrupts
    (IPI) will fix this.
- **Cost of SMP** (instructions, same harness as milestone 22):

  | operation | milestone 22 | milestone 23 |
  |---|---|---|
  | context switch | 272 | 362 |
  | system call | 141 | 198 |
  | call and reply | 1435 | 1827 |
  | IPC round trip | 2499 | 3180 |

  The first version cost 448 on the context switch. It was brought down with
  an instruction-by-instruction QEMU profile:
  - `tp` is read once and clamped to the hart range, without bounds checks on
    every access;
  - each hart's state lives in one structure with a single base, in its own
    cache line.

  What remains is the price of mutual exclusion: taking and releasing the
  lock, and about 10 instructions per SPARK call to pick the hart's model.
- **New tests:**
  - one thread per hart competes for a lock and each runs on its hart;
  - a process runs on another hart;
  - calls and replies between processes on different harts;
  - the kernel does not trust the user's `tp`.
- **Verification:**
  - full proof with no pending checks;
  - 105 self-tests in 8 of 8 boots in a row with 1 hart and with 4 harts, and
    also in Debug;
  - under load, 0 failures in 32 boots with 4 harts;
  - with 1 hart, 1 failure in 384 boots ("the deferred work lost the client's
    priority"). It has not been reproduced; the test now prints the client's
    state and budget if it fails again.
- **Mutations:**
  - SMP: 15 of 16 detected. Removing the guard that prevents lending across
    harts survives, because it is redundant: the SPARK gate rejects that loan
    through `Homes_Ok`;
  - SPARK: 3 of 3;
  - those of milestones 13 to 22 are still detected, except the two known
    memory-ordering ones from milestone 22.

## Milestone 22 — SMP, stage 1: hart start-up and a lock

- **Start-up:** every hart (up to 4) sets up its own machine mode: PMP,
  delegation, the Sstc timer and the counters. The secondaries wait for hart
  0's signal, take their stack (with a guard page) and drop to supervisor
  mode with the kernel's page tables.
- **Waiting:** the secondary harts sleep with `wfi` and their own timer,
  without spinning. Spinning saturated the computer and distorted the
  scheduling tests.
- **Spinlock** with `amoswap.w.aq` and `amoswap.w.rl`: 6 instructions to take
  and release without contention. It is the basis of the global kernel lock
  (plan A, seL4-style partitioning).
- **Tests:**
  - all configured harts start;
  - mutual exclusion with 4 harts competing, 80000 exact increments and never
    two inside at once.
- **Verification:**
  - 101 self-tests in 8 of 8 boots in a row, with 1 hart and with 4 harts;
  - under load, 0 failures in 128 boots with 1 hart and in 32 with 4 harts;
  - SMP mutations: 4 of 6 detected. The two memory-ordering ones survive
    (removing `.aq` or `.rl`), because QEMU on an x86 host gives a stronger
    ordering than RISC-V's minimum.
- **Pending for the next stages:**
  - a scheduler per hart;
  - inter-hart interrupts (IPI);
  - cross-hart calls.

## Tooling — Parallel proof

- **What changes:** the proof gate uses every core (`-j0`) with 60 s per
  check (`--timeout=60`).
- **Full proof from scratch:** from 2864 s (48 min) to 461 s (under 8 min),
  with the same 1448 checks.
- **Why the 60 s are needed:** with the default limit, `-j0` and `-j6` left
  some borderline `user_space` checks unproved, and `--timeout=30` cut
  `frame_bitmap`'s time short (level 4).

## Milestone 21 — Chained loans

- **What changes:** if server B works with client A's context and calls C, C
  now also works with A's context, with the original client's priority and
  budget. Before, C used its own and priority inversion came back.
- **Depth along the chain:** every user of a borrowed context has one
  (`Depth`); the deepest one uses the context and the others are blocked.
- **The `Links_Ok` invariant, rewritten** for chains. Acyclicity follows from
  it: the owner of a context never uses someone else's.
- **Replying:** the context goes back to the previous link in the chain
  (`Return_To`).
- **Waking or killing someone in the middle of a chain:** those below lose the
  loan, a safe degradation (`Reclaim`).
- **Maximum depth:** 7.
- **Proved:** the scheduler and its gate (450 checks).
- **New tests:**
  - chain client (top priority) → forwarder → server (lowest priority),
    without priority inversion;
  - death of the middle link, with no foreign contexts left dangling.
- **Measurements:**
  - direct call: 1436 instructions (1408 in milestone 20);
  - call with one intermediate hop: 4249 instructions.
- **Key mutation:** with the old rule ("only a thread using its own context
  lends"), the chain test detects the inversion.
- **Verification:**
  - 1448 checks proved;
  - 7 of 7 SPARK mutations rejected and 21 of 21 runtime mutations detected;
  - 99 self-tests in 8 of 8 boots in a row and 0 failures in 128 boots with
    4 QEMU instances in parallel.

## Milestone 20 — Adaptive quantum

- **Quantum:** 8 times the measured cost of preemptions, between 1 and 10 ms.
  Below 1.6 µs the cost is treated as noise and the quantum stays at 1 ms.
- **Liveness bug fixed:** a thread with a budget smaller than the cost of a
  thread switch got turns but made no progress. It now gets a minimum slice of
  two switches, and the excess is charged as debt.
- **Proved:** `Quantum_Core` (average, quantum and slice).
- **Effective CPU 50 times slower (`-icount shift=9`):** all 97 self-tests
  pass; before, they failed and one measurement hung.
- **Cost:** context switch from 258 to 272 instructions.
- **Total:** 1414 checks proved.

## Milestone 19 — Intermittent failure solved

- **What failed:** "a process did not finish in time", in 1-3% of boots under
  load.
- **Cause:** a race in the test, not in the kernel. It was located with a
  state dump on panic.
- **Fix:** the test is now deterministic.
- **Result:** 0 failures in 128 boots with 4 QEMU instances in parallel.
- **New bug-hunting method:** `-icount` at several scales and phase offsets,
  plus parallel stress.

## Milestone 18 — Destroying costs what the process owns

- **What changes:** each address space keeps the list of its frames
  (`Lists_Ok`, a proved bijection), and destroying walks only that list.
- **Frames scattered across memory:** 14585 instructions, against 130838 with
  milestone 17's range.
- **Total:** 1394 checks proved.

## Milestone 17 — Creating processes 16 times cheaper

- **What changes:**
  - destroying no longer walks the whole RAM;
  - only the page tables in use are cleared;
  - `memset` is unrolled.
- **Create, run and destroy a process:** from 195318 to 12474 instructions.
  Linux with `posix_spawn`: 233981.
- **Total:** 1378 checks proved.

## Milestone 16 — 1 ms turns and prioritised wake-up

- **What changes:**
  - a 1 ms quantum within each level;
  - a thread waking from sleep is the next in its level (`Promote`).
- **Latency at equal priority:** from 29.7 ms to 1 µs. Linux with EEVDF:
  about 4 ms.
- **Maximum wait between turns:** 2.6 ms. EEVDF: 8.3 ms.

## Milestone 15 — Sleeping, and latency against Linux

- **What it adds:**
  - `FB_SYS_SLEEP_UNTIL`, with `Sleep_Core` proved: nobody wakes before their
    deadline;
  - the lemma `Lemma_Top_Runs`.
- **Worst-case latency at top priority:** 1 µs in Fabianus. Linux with
  `SCHED_FIFO`: up to about 4 ms. *Corrected in milestone 26:* that Linux
  probe was not running with `SCHED_FIFO` (musl does not implement
  `sched_setscheduler`). With real `SCHED_FIFO` 99, Linux's worst case is
  9.9 µs under load and 15.5 µs without it.

## Milestone 14 — First comparison with Linux

- **Setup:** Linux 6.12 (Debian 13's kernel) on the same QEMU, with the same
  way of counting instructions (`tools/compare/run_linux.sh`).
- **Instructions per operation, Fabianus against Linux:**

| Operation | Fabianus | Linux |
|---|---|---|
| System call | 141 | 426 |
| Yield with a process switch | 343 | 3012 |
| Round trip between processes | 1394 | 12292 (futex) |

## Milestone 13 — Deferring without losing the loan

- **What changes:** a server that defers a reply keeps the context of the most
  urgent client it has pending (`Adopt` and `Release`).
- **Inversion with a deferred reply:** from 20000 units to 0.

## Milestone 12 — Deferred replies

- **New calls:** `FB_SYS_DEFER` and `FB_SYS_REPLY_TO`.
- **UART driver in Rust:** moves to call/reply, with deferred reads.

## Milestone 11 — Context donation

- **What changes:** in a call, the client lends the server its priority and
  budget until the reply.
- **Scheduling capability:** `FB_SYS_SCHED_SET` lets a process set its own
  priority and budget.

## Milestone 10 — A proved scheduler

- **Design:** strict priority on 4 levels, real-time budgets and overrun debt.
- **Proved in SPARK:** no ready thread starves (ranking function
  `Wait_Bound`).

## Milestones 1-9 — Kernel foundations

- **Boot and memory:**
  - firmware-less boot on QEMU `virt`, and traps;
  - a frame allocator proved in SPARK;
  - Sv39 paging and PMP.
- **Processes and authority:**
  - user-mode processes with isolated address spaces;
  - capabilities for the console, endpoints and devices.
- **Communication and driver:**
  - synchronous IPC (send/recv, call/reply, reply_recv) with direct CPU
    hand-off;
  - a UART driver in Rust with PLIC interrupts.
