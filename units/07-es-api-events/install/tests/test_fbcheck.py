#!/usr/bin/env python3
"""Off-device test of files/fbcheck.py with generated PNGs (every filter type, RGB and RGBA)."""
import os
import struct
import subprocess
import sys
import tempfile
import zlib

FBCHECK = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'files', 'fbcheck.py')


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else b if pb <= pc else c


def encode(rows, bpp, kind):
    out, previous = b'', bytes(len(rows[0]))
    for row in rows:
        f = bytearray()
        for i, x in enumerate(row):
            a = row[i - bpp] if i >= bpp else 0
            b = previous[i]
            c = previous[i - bpp] if i >= bpp else 0
            f.append((x - (0, a, b, (a + b) >> 1, paeth(a, b, c))[kind]) & 0xFF)
        out += bytes([kind]) + bytes(f)
        previous = row
    return out


def png(path, width, height, colour, rows, kind, interlace=0):
    bpp = {2: 3, 6: 4}[colour]
    chunk = lambda k, d: struct.pack('>I', len(d)) + k + d + struct.pack('>I', zlib.crc32(k + d))
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, colour, 0, 0, interlace))
                + chunk(b'IDAT', zlib.compress(encode(rows, bpp, kind))) + chunk(b'IEND', b''))


def frame(width, height, bpp, alpha, dot):
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            pixel = [0, 0, 0] if (x, y) != dot else [200, 220, 255]
            row += bytes(pixel + ([alpha] if bpp == 4 else []))
        rows.append(bytes(row))
    return rows


def run(path):
    return subprocess.run([sys.executable, '-I', FBCHECK, path], capture_output=True).returncode


failures = 0
with tempfile.TemporaryDirectory() as tmp:
    path = os.path.join(tmp, 'f.png')
    for colour, bpp in ((2, 3), (6, 4)):
        for kind in range(5):
            png(path, 40, 30, colour, frame(40, 30, bpp, 255, None), kind)
            black = run(path)
            png(path, 40, 30, colour, frame(40, 30, bpp, 255, (37, 29)), kind)
            dot = run(path)
            ok = black == 1 and dot == 0
            failures += not ok
            print('%s colour type %d, filter %d: black -> %d, one bright pixel -> %d' % ('ok  ' if ok else 'FAIL', colour, kind, black, dot))
    png(path, 40, 30, 2, frame(40, 30, 3, 255, None), 0, interlace=1)
    ok = run(path) == 2
    failures += not ok
    print('%s interlaced PNG -> 2 (cannot tell)' % ('ok  ' if ok else 'FAIL'))
    with open(path, 'wb') as f:
        f.write(b'not a png')
    ok = run(path) == 2
    failures += not ok
    print('%s not a PNG -> 2' % ('ok  ' if ok else 'FAIL'))
print('%d failed' % failures)
sys.exit(1 if failures else 0)
