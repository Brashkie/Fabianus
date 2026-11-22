# SPDX-License-Identifier: GPL-3.0-or-later
"""Crea un initramfs mínimo (cpio newc) con /init, /hello y /dev/console, y
los archivos extra que se le den (en la raíz, con su nombre).

Uso: mkinitramfs.py <init> <hello> <salida.cpio> [extra ...]
"""
import os
import sys


def entry(ino, name, mode, data=b'', rdev=(0, 0)):
    name_bytes = name.encode() + b'\0'
    fields = [ino, mode, 0, 0, 1, 0, len(data), 0, 0, rdev[0], rdev[1], len(name_bytes), 0]
    header = b'070701' + b''.join(b'%08X' % f for f in fields)
    out = header + name_bytes
    out += b'\0' * (-len(out) % 4)
    out += data
    out += b'\0' * (-len(out) % 4)
    return out


def main():
    init, hello, output = sys.argv[1:4]
    extras = [entry(10 + i, os.path.basename(path), 0o100644, open(path, 'rb').read())
              for i, path in enumerate(sys.argv[4:])]
    archive = b''.join([
        entry(1, 'dev', 0o040755),
        entry(2, 'dev/console', 0o020600, rdev=(5, 1)),
        entry(3, 'proc', 0o040555),
        entry(4, 'init', 0o100755, open(init, 'rb').read()),
        entry(5, 'hello', 0o100755, open(hello, 'rb').read()),
    ] + extras + [
        entry(0, 'TRAILER!!!', 0),
    ])
    archive += b'\0' * (-len(archive) % 512)
    open(output, 'wb').write(archive)


main()
