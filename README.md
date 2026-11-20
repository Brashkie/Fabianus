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

Milestone 31 of an ongoing series. The kernel runs on QEMU `virt`
(rv64imac), up to 4 harts, without any firmware (`-bios none`).

- **Memory:** physical frame allocator proven in SPARK, Sv39 paging, PMP.
- **Processes:** user-mode processes in isolated address spaces;
  destroying a process costs in proportion to what it owns.
- **Authority:** capabilities for console, IPC endpoints and devices.
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
    SPARK and checked on every system call in Debug builds.
- **Sleeping:** `sleep_until`, with a proof that no thread wakes before its
  deadline.
- **Drivers:** a UART driver written in Rust, running as a user process.

Every milestone is documented in [CHANGELOG.md](CHANGELOG.md), with its
design, measurements, verification results, mutation testing and known
limits.

## Measurements against Linux

Same QEMU machine, `-icount shift=0,sleep=off`. Times are virtual-clock
nanoseconds, which count instructions across the whole machine. The figures
are the median of 5 runs, measured at milestone 26 against Linux 6.12 with
4 harts.

| Operation | Fabianus | Linux |
|---|---|---|
| Round trip, same hart | 2005 (call) | 12622 (futex) |
| Round trip, across harts | 5815 (call) | 24927 (futex) |
| Wake the other hart | 3287 | 12537 (futex) |
| Inversion across harts: server starts running | 10783 (inheritance) | 59514 (futex PI) |

These are emulator measurements, not real hardware.

## Languages

| Language | Role |
|---|---|
| Zig | Kernel core |
| Ada/SPARK | Formally verified components (scheduler, IPC, capabilities, memory, inheritance) |
| Assembly | Boot, traps, context switch |
| Rust | UART driver (user process) |
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
  tools/          ABI generator and Linux comparison tools
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
zig build run                     # build (proofs first) and boot in QEMU, 1 hart
zig build run -Dsmp=4             # 4 harts
zig build run -Drelease           # optimized build
zig build run -Drelease -Dbench=true   # benchmark instead of self-tests, with -icount
```

Useful options: `-Dqemu=<path>`, `-Dalr=<path>`, `-Drustc=<path>`.

A successful boot runs every self-test and ends with `boot: ok`.

## License

GNU General Public License. See [LICENSE](LICENSE).
