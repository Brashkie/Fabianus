# Fabianus

A RISC-V kernel written from scratch, with formally verified core components
in SPARK/Ada, multicore support, and capability-based IPC.

Fabianus aims to be an evolution of the ideas behind Linux, built around
three requirements for every important design decision:

1. **Mathematical foundation:** correctness and complexity arguments.
2. **Verification:** a clear statement of what is *proved* (GNATprove, as a
   mandatory gate before compiling) and what is only *tested*.
3. **Experimental evidence:** measured performance, compared against Linux on
   the same emulated machine.

All kernel code is original. Linux is used only as a point of comparison.

## Status

Milestone 34 of an ongoing series. The kernel runs on QEMU `virt`
(rv64imac), up to 4 harts, without any firmware (`-bios none`).

- **Memory:** physical frame allocator proven in SPARK, Sv39 paging, PMP.
- **Processes:** user-mode processes in isolated address spaces;
  destroying a process costs in proportion to what it owns. A process can be
  killed at any moment, even while it waits forever for a message.
- **Shared memory:** regions that several processes can map, read-only or
  read-write. Isolation is proved in SPARK: two address spaces only reach
  the same frame if it belongs to a region both have joined.
- **Authority:** capabilities for console, IPC endpoints, devices and shared
  regions. Each device page (UART, disk) belongs to at most one process at a
  time, proved in SPARK.
- **IPC:** synchronous send/recv, call/reply, reply_recv and deferred replies,
  with direct CPU hand-off between client and server.
- **Scheduler** (proved in SPARK):
  - strict priority on 4 levels with real-time budgets and overrun debt;
  - no ready thread starves;
  - an adaptive quantum;
  - context donation along call chains.
- **Multicore:**
  - one scheduler model per hart;
  - a global lock plus one lock per hart, and inter-hart interrupts;
  - priority inheritance across harts. The inheritance rule ("no server runs
    with less urgency than a client waiting for its reply") is proved in
    SPARK and checked on every system call in Debug builds. Cross-hart calls
    and replies wake the other side and update inheritance in a single proved
    operation that preserves the rule for every thread.
- **Sleeping:** `sleep_until`, with a proof that no thread wakes before its
  deadline.
- **Drivers** (Rust, as user processes):
  - a UART driver;
  - a virtio-blk disk driver that moves data by DMA straight into memory it
    shares with its clients. The kernel only gives it the physical address
    of pages of regions it has joined (proved in SPARK), and resets the disk
    if the driver dies, before freeing its memory.

- **Storage:** a virtio-blk disk. Clients call the driver with an operation,
  a sector and a page of the region they share with it; the data never
  passes through the kernel.

## Verification

- **Proofs:** GNATprove proves 2240 checks over the whole SPARK code base,
  with nothing left unproved. The proof runs before every build, and a
  failure stops it.
- **Self-tests:** 137 tests run on every boot, with 1 and with 4 harts, in
  Debug and in optimized builds, and under stress with several QEMU
  instances at once.
- **Mutation testing:** every milestone breaks its own code and
  specification on purpose and checks that the proofs or the tests reject
  each mutation. Survivors are listed in the changelog.

Every milestone is documented in [CHANGELOG.md](CHANGELOG.md), with its
design, measurements, verification results, mutation testing and known
limits.

## Measurements against Linux

Same QEMU machine, `-icount shift=0,sleep=off`. Times are virtual-clock
nanoseconds, which count instructions across the whole machine. The figures
are the median of 5 runs, measured at milestone 33 against Linux 6.12 with
4 harts.

| Operation | Fabianus | Linux |
|---|---|---|
| Round trip, same hart | 1989 (call) | 12660 (futex) |
| Round trip, across harts | 4970 (call) | 25283 (futex) |
| Wake the other hart | 2348 | 12534 (futex) |
| Inversion across harts: server starts running | 9335 (inheritance) | 54744 (futex PI) |
| 4 KiB to another hart and a sum back | 11134 (shared region) | 29709 (shared memory and futex) |
| The same, copying | 623556 (IPC, 32 bytes per call) | 32634 (pipe) |
| Create and map 64 KiB, writing its 16 pages | 17800 | 92500 (`mmap` and page faults) |

Fabianus moves bulk data through shared regions; its IPC carries 32 bytes
per message and has no bulk copy, which is why copying is slow.

A 4 KiB disk read or write costs about 5,200 instructions of the whole
machine (client, kernel and driver; milestone 34). Disk latency cannot be
measured reliably in QEMU, and in this setup Linux does not let user mode
read the instruction counter, so there is no Linux figure for the disk.

These are emulator measurements, not real hardware.

## Languages

| Language | Role |
|---|---|
| Zig | Kernel core |
| Ada/SPARK | Formally verified components (scheduler, IPC, capabilities, memory, inheritance) |
| Assembly | Boot, traps, context switch |
| Rust | UART and disk drivers (user processes) |
| C | Common ABI header and Linux comparison programs |
| D, VHDL | Planned |

## Layout

```
kernel/
  arch/riscv64/   boot, traps, context switch, user programs for tests
  abi/            fabianus.h, the ABI shared by all languages
  src/            kernel core (Zig) and self-tests
  spark/src/      SPARK packages and their proofs
  drivers/uart/   UART driver (Rust)
  drivers/disk/   virtio-blk disk driver (Rust)
  tools/          ABI generator, test disk generator (mkdisk) and Linux
                  comparison tools
CHANGELOG.md      milestone-by-milestone record
```

## Building and running

Requirements:

- Zig 0.14.1
- Alire, with GNAT and GNATprove (for the SPARK library and its proofs)
- `rustc` with the `riscv64imac-unknown-none-elf` target
- `qemu-system-riscv64`

From `kernel/`:

```
zig build run                     # build (proofs first) and boot in QEMU, 1 hart,
                                  # with a generated 1 MiB test disk (snapshot=on)
zig build run -Dsmp=4             # 4 harts
zig build run -Drelease           # optimized build
zig build run -Drelease -Dbench=true   # benchmark instead of self-tests, with -icount
```

Useful options: `-Dqemu=<path>`, `-Dalr=<path>`, `-Drustc=<path>`.

A successful boot runs every self-test and ends with `boot: ok`.

## License

Fabianus is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version (`GPL-3.0-or-later`). See [LICENSE](LICENSE).

Every source file carries the line
`SPDX-License-Identifier: GPL-3.0-or-later`, so the license travels with it.

It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE. See the GNU General Public License for more details.
