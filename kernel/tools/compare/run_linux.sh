#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Mide Linux con las mismas operaciones que el benchmark de Fabianus, en el
# mismo QEMU y con -icount, para comparar instrucciones por operación.
#
# Linux no forma parte de Fabianus: es solo el punto de comparación. Se usa el
# kernel oficial de Debian 13 para riscv64, fijado por versión y SHA-256.
#
# Uso: run_linux.sh <carpeta de trabajo> [smp]
#   con smp, la medida con 4 harts (linux_smp.c) en lugar de la de uno
#   (variables opcionales: QEMU, ZIG)
set -euo pipefail

WORK="${1:?carpeta de trabajo}"
MODE="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
QEMU="${QEMU:-/c/Program Files/qemu/qemu-system-riscv64.exe}"
ZIG="${ZIG:-zig}"

PACKAGE="linux-image-6.12.115+deb13.1-riscv64_6.12.115-2_riscv64.deb"
URL="https://deb.debian.org/debian/pool/main/l/linux/$PACKAGE"
PACKAGE_SHA256="884a04ae9b6486e34d5227d94fd3c01b536e02691cb5d5b2055fcb59b84c6063"
IMAGE_SHA256="5705b30a517585597b44b620a7f323e2711042cc805c922d9f5f69a5375c56cc"

mkdir -p "$WORK"
cd "$WORK"

if [ ! -f Image ]; then
    [ -f linux.deb ] || curl -sfo linux.deb "$URL"
    echo "$PACKAGE_SHA256  linux.deb" | sha256sum -c -
    python -I - <<'EOF'
import io, tarfile
data = open('linux.deb', 'rb').read()
offset = 8
while offset < len(data):
    header = data[offset:offset + 60]
    name = header[:16].decode().strip().rstrip('/')
    size = int(header[48:58].decode())
    if name.startswith('data.tar'):
        archive = tarfile.open(fileobj=io.BytesIO(data[offset + 60:offset + 60 + size]))
        for member in archive.getmembers():
            if member.name.startswith('./boot/vmlinux-'):
                open('Image', 'wb').write(archive.extractfile(member).read())
    offset += 60 + size + (size & 1)
EOF
fi
echo "$IMAGE_SHA256  Image" | sha256sum -c -

SOURCE=linux_bench.c
HARTS=1
LOG=linux.log
EXTRAS=()
DISK=()
if [ "$MODE" = smp ]; then
    SOURCE=linux_smp.c
    HARTS=4
    LOG=linux_smp.log
    # El disco virtio de la comparación (Hito 34): los módulos del mismo paquete
    # (en Debian virtio_mmio y virtio_blk no van dentro del kernel) y la misma
    # imagen que usa Fabianus (la palabra i del sector s vale s * 2^32 + i).
    python -I - <<'EOF'
import io, lzma, struct, tarfile
data = open('linux.deb', 'rb').read()
offset = 8
while offset < len(data):
    header = data[offset:offset + 60]
    name = header[:16].decode().strip().rstrip('/')
    size = int(header[48:58].decode())
    if name.startswith('data.tar'):
        archive = tarfile.open(fileobj=io.BytesIO(data[offset + 60:offset + 60 + size]))
        for member in archive.getmembers():
            for module in ('virtio_mmio', 'virtio_blk'):
                if member.name.endswith('/' + module + '.ko.xz'):
                    open(module + '.ko', 'wb').write(lzma.decompress(archive.extractfile(member).read()))
    offset += 60 + size + (size & 1)
with open('disk.img', 'wb') as disk:
    for sector in range(2048):
        disk.write(b''.join(struct.pack('<Q', (sector << 32) | word) for word in range(64)))
EOF
    EXTRAS=(virtio_mmio.ko virtio_blk.ko)
    DISK=(-global virtio-mmio.force-legacy=false -drive "if=none,format=raw,id=disk0,snapshot=on,file=disk.img"
          -device virtio-blk-device,drive=disk0,bus=virtio-mmio-bus.0)
fi
"$ZIG" cc -target riscv64-linux-musl -static -O2 -s -Wall "$HERE/$SOURCE" -o init
"$ZIG" cc -target riscv64-linux-musl -static -O2 -s "$HERE/hello.c" -o hello
python "$HERE/mkinitramfs.py" init hello initramfs.cpio "${EXTRAS[@]}"

# sleep=off: con la CPU inactiva el reloj virtual salta al siguiente evento en
# lugar de seguir al reloj del anfitrión, así que la latencia no depende de él.
timeout 2400 "$QEMU" -machine virt -cpu rv64 -smp "$HARTS" -m 512M -nographic -icount shift=0,sleep=off \
    "${DISK[@]}" -kernel Image -initrd initramfs.cpio -append "console=ttyS0 quiet" > "$LOG" 2>&1 || true
grep -a "instrucciones\|calibracion\|benchmark\|latencia\|vuelta\|turnos\|inversion\|fallo\|no se pudo\|KiB\|cuadro\|disco" "$LOG"
