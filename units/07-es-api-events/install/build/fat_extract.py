#!/usr/bin/env python3
"""Stream one file out of a FAT32 partition inside a .img.gz without writing the image.

usage: fat_extract.py IMG.gz PART_START_SECTOR DIR/NAME OUT
Two sequential passes over the gzip stream: 1) FAT + directories, 2) the file's clusters.
"""
import gzip, struct, sys

img, start, want, out = sys.argv[1], int(sys.argv[2]) * 512, sys.argv[3].upper().split('/'), sys.argv[4]

def open_at(offset):
    f = gzip.open(img, 'rb')
    f.seek(offset)
    return f

f = open_at(start)
bs = f.read(512)
bps, spc, rsv, nfats = struct.unpack_from('<HBHB', bs, 11)
fatsz, rootclus = struct.unpack_from('<I', bs, 36)[0], struct.unpack_from('<I', bs, 44)[0]
assert bs[82:90] == b'FAT32   ', bs[82:90]
f.read((rsv - 1) * bps)
fat = f.read(fatsz * bps)
f.read((nfats - 1) * fatsz * bps)
clus = bps * spc
data0 = start + (rsv + nfats * fatsz) * bps
pos = data0  # stream position of f

def chain(c):
    out = []
    while 2 <= c < 0x0FFFFFF8:
        out.append(c)
        c = struct.unpack_from('<I', fat, c * 4)[0] & 0x0FFFFFFF
    return out

def read_clusters(cl):
    """Read clusters in ascending order (forward-only stream); return them in chain order."""
    global f, pos
    got = {}
    for c in sorted(cl):
        off = data0 + (c - 2) * clus
        if off < pos:
            f, pos = open_at(off), off
        if off > pos:
            f.read(off - pos); pos = off
        got[c] = f.read(clus); pos += clus
    return b''.join(got[c] for c in cl)

def entries(data):
    for i in range(0, len(data), 32):
        e = data[i:i + 32]
        if e[0] == 0:
            break
        if e[0] == 0xE5 or e[11] == 0x0F:
            continue
        name = e[0:8].decode('latin1').rstrip() + ('.' + e[8:11].decode('latin1').rstrip() if e[8:11].strip() else '')
        hi, lo = struct.unpack_from('<H', e, 20)[0], struct.unpack_from('<H', e, 26)[0]
        yield name, e[11], (hi << 16) | lo, struct.unpack_from('<I', e, 28)[0]

c = rootclus
for i, part in enumerate(want):
    found = None
    for name, attr, first, size in entries(read_clusters(chain(c))):
        if name == part:
            found = (attr, first, size)
    assert found, 'not found: %s' % part
    attr, c, size = found
    if i < len(want) - 1:
        assert attr & 0x10, part
cl = chain(c)
print('file %s: %d bytes, %d clusters of %d, first %d, contiguous=%s' % ('/'.join(want), size, len(cl), clus, cl[0], cl == list(range(cl[0], cl[0] + len(cl)))))
# pass 2: write clusters at their file offsets while streaming forward
index = {c: n for n, c in enumerate(cl)}
f, pos = open_at(data0 + (min(cl) - 2) * clus), data0 + (min(cl) - 2) * clus
with open(out, 'wb') as o:
    o.truncate(size)
    for c in sorted(cl):
        off = data0 + (c - 2) * clus
        if off > pos:
            f.read(off - pos); pos = off
        block = f.read(clus); pos += clus
        o.seek(index[c] * clus)
        o.write(block[:max(0, min(clus, size - index[c] * clus))])
print('wrote', out)
