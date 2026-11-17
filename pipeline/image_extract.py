#!/usr/bin/env python3
"""Stream one file out of the FAT partition of a Knulli .img.gz, without writing the image.

usage: image_extract.py IMG.gz DIR/NAME OUT
       image_extract.py IMG.gz --partition-sha NAME    sha256 of a GPT partition (by name)

The partition is found from the GPT (or MBR) at the start of the image: the first FAT32
partition that holds DIR/NAME. Two forward passes over the gzip stream per partition tried:
1) FAT + directories, 2) the file's clusters. Generalises unit 07's fat_extract.py, which
had the scarab offset (sector 147456) fixed.
"""
import gzip
import struct
import sys

GPT_BASIC_DATA = bytes.fromhex('a2a0d0ebe5b9334487c068b6b72699c7')  # ebd0a0a2-b9e5-4433-87c0-68b6b72699c7
MBR_FAT_TYPES = {0x0b, 0x0c, 0x0e}


def partitions(img):
    with gzip.open(img, 'rb') as f:
        head = f.read(1 << 20)
    if head[510:512] != b'\x55\xaa':
        sys.exit('no partition table')
    if head[512:520] == b'EFI PART':
        ent_lba, count, size = struct.unpack_from('<QII', head, 512 + 72)
        for i in range(count):
            e = head[ent_lba * 512 + i * size:ent_lba * 512 + (i + 1) * size]
            if len(e) < 48 or e[:16] == b'\0' * 16:
                continue
            first = struct.unpack_from('<Q', e, 32)[0]
            # basic-data first, then anything else (some images use the Linux type for FAT)
            yield (0 if e[:16] == GPT_BASIC_DATA else 1), first
        return
    for i in range(4):
        e = head[446 + 16 * i:462 + 16 * i]
        if e[4] in MBR_FAT_TYPES:
            yield 0, struct.unpack_from('<I', e, 8)[0]


def extract(img, start_sector, want, out):
    start = start_sector * 512

    def open_at(offset):
        f = gzip.open(img, 'rb')
        f.seek(offset)
        return f

    f = open_at(start)
    bs = f.read(512)
    if bs[82:90] != b'FAT32   ':
        return False
    bps, spc, rsv, nfats = struct.unpack_from('<HBHB', bs, 11)
    fatsz, rootclus = struct.unpack_from('<I', bs, 36)[0], struct.unpack_from('<I', bs, 44)[0]
    f.read((rsv - 1) * bps)
    fat = f.read(fatsz * bps)
    f.read((nfats - 1) * fatsz * bps)
    clus = bps * spc
    data0 = start + (rsv + nfats * fatsz) * bps
    state = {'f': f, 'pos': data0}

    def chain(c):
        seen = []
        while 2 <= c < 0x0FFFFFF8:
            seen.append(c)
            if len(seen) > len(fat) // 4:
                sys.exit('FAT chain loop')
            c = struct.unpack_from('<I', fat, c * 4)[0] & 0x0FFFFFFF
        return seen

    def read_clusters(cl):
        got = {}
        for c in sorted(cl):
            off = data0 + (c - 2) * clus
            if off < state['pos']:
                state['f'], state['pos'] = open_at(off), off
            if off > state['pos']:
                state['f'].read(off - state['pos'])
                state['pos'] = off
            got[c] = state['f'].read(clus)
            state['pos'] += clus
        return b''.join(got[c] for c in cl)

    def entries(data):
        for i in range(0, len(data), 32):
            e = data[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] == 0x0F:
                continue
            ext = e[8:11].decode('latin1').rstrip()
            name = e[0:8].decode('latin1').rstrip() + ('.' + ext if ext else '')
            hi, lo = struct.unpack_from('<H', e, 20)[0], struct.unpack_from('<H', e, 26)[0]
            yield name, e[11], (hi << 16) | lo, struct.unpack_from('<I', e, 28)[0]

    c, size = rootclus, 0
    for i, part in enumerate(want):
        found = None
        for name, attr, first, sz in entries(read_clusters(chain(c))):
            if name == part:
                found = (attr, first, sz)
        if not found:
            return False
        attr, c, size = found
        if i < len(want) - 1 and not attr & 0x10:
            return False
    cl = chain(c)
    print('partition at sector %d: %s, %d bytes, %d clusters' % (start_sector, '/'.join(want), size, len(cl)))
    index = {c: n for n, c in enumerate(cl)}
    pos = data0 + (min(cl) - 2) * clus
    f = open_at(pos)
    with open(out, 'wb') as o:
        o.truncate(size)
        for c in sorted(cl):
            off = data0 + (c - 2) * clus
            if off > pos:
                f.read(off - pos)
                pos = off
            block = f.read(clus)
            pos += clus
            o.seek(index[c] * clus)
            o.write(block[:max(0, min(clus, size - index[c] * clus))])
    return True


def partition_sha(img, name):
    import hashlib
    with gzip.open(img, 'rb') as f:
        head = f.read(1 << 20)
    if head[512:520] != b'EFI PART':
        sys.exit('no GPT')
    ent_lba, count, size = struct.unpack_from('<QII', head, 512 + 72)
    for i in range(count):
        e = head[ent_lba * 512 + i * size:ent_lba * 512 + (i + 1) * size]
        if len(e) < 128 or e[:16] == b'\0' * 16:
            continue
        if e[56:128].decode('utf-16le').rstrip('\0') != name:
            continue
        first, last = struct.unpack_from('<QQ', e, 32)
        h, left = hashlib.sha256(), (last - first + 1) * 512
        with gzip.open(img, 'rb') as f:
            f.seek(first * 512)
            while left:
                block = f.read(min(left, 1 << 20))
                if not block:
                    sys.exit('image ends inside partition %s' % name)
                h.update(block)
                left -= len(block)
        print(h.hexdigest())
        return
    sys.exit('no GPT partition named %s' % name)


def main():
    if len(sys.argv) == 4 and sys.argv[2] == '--partition-sha':
        return partition_sha(sys.argv[1], sys.argv[3])
    img, want, out = sys.argv[1], sys.argv[2].upper().split('/'), sys.argv[3]
    for _, first in sorted(partitions(img)):
        if extract(img, first, want, out):
            return
    sys.exit('%s not found in any FAT32 partition' % '/'.join(want))


if __name__ == '__main__':
    main()
