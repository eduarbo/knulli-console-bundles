#!/usr/bin/env python3
"""Tell whether a PNG screenshot (fbgrab of /dev/fb0) shows anything.

usage: fbcheck.py FILE.png
exit 0: some pixel is brighter than BLACK in any of R, G, B (something is on screen)
exit 1: every pixel is black (alpha ignored)
exit 2: not a PNG this script can read (8-bit grey/RGB/grey+alpha/RGBA, not interlaced)
Standard library only (the console has Python 3, no PIL).
"""
import struct
import sys
import zlib

BLACK = 16  # channel values up to this count as black
CHANNELS = {0: 1, 2: 3, 4: 2, 6: 4}  # PNG colour type -> samples per pixel
COLOUR = {0: (0,), 2: (0, 1, 2), 4: (0,), 6: (0, 1, 2)}  # samples that carry colour


def read_png(path):
    with open(path, 'rb') as f:
        data = f.read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a PNG')
    pos, header, idat = 8, None, []
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat.append(body)
        elif kind == b'IEND':
            break
        pos += 12 + length
    if header is None:
        raise ValueError('no IHDR')
    width, height, depth, colour, _, _, interlace = header
    if depth != 8 or colour not in CHANNELS or interlace:
        raise ValueError('unsupported PNG: depth %d, colour type %d, interlace %d' % (depth, colour, interlace))
    return width, height, colour, zlib.decompress(b''.join(idat))


def unfilter(width, height, bpp, raw):
    """Yield each image row as bytes (PNG filters 0-4)."""
    stride = width * bpp
    previous = bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        if kind == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif kind == 2:
            for i in range(stride):
                row[i] = (row[i] + previous[i]) & 0xFF
        elif kind == 3:
            for i in range(stride):
                left = row[i - bpp] if i >= bpp else 0
                row[i] = (row[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                a = row[i - bpp] if i >= bpp else 0
                b = previous[i]
                c = previous[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        elif kind != 0:
            raise ValueError('bad filter %d' % kind)
        yield bytes(row)
        previous = row


def shows_something(path):
    width, height, colour, raw = read_png(path)
    bpp = CHANNELS[colour]
    for row in unfilter(width, height, bpp, raw):
        for sample in COLOUR[colour]:
            if max(row[sample::bpp], default=0) > BLACK:
                return True
    return False


if __name__ == '__main__':
    try:
        sys.exit(0 if shows_something(sys.argv[1]) else 1)
    except (OSError, ValueError, zlib.error) as error:
        print('fbcheck: %s' % error, file=sys.stderr)
        sys.exit(2)
