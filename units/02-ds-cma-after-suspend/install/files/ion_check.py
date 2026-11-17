#!/usr/bin/env python3
"""Check whether the ION CMA heap can hand out the buffer advanced_drastic's SDL needs.

After some suspends the H700 kernel refuses that allocation (EPERM, dmesg "platform cma:
Fail to allocate buffer") although CmaFree is high, and DraStic then fails every game with
"could not find entry in file". Same request as SDL: ION_IOC_ALLOC (legacy 32-byte ABI),
len 0x177000, heap mask 0x10, flags 2; the buffer is freed at once.
Prints one JSON line; exit 0 when the allocation works, 1 when it is refused.
"""
import errno
import fcntl
import json
import os
import struct

ION_IOC_ALLOC = 0xc0204900
ION_IOC_FREE = 0xc0044901
LENGTH, HEAP_MASK, FLAGS = 0x177000, 0x10, 2


def cma_free_kb():
    for line in open('/proc/meminfo'):
        if line.startswith('CmaFree:'):
            return int(line.split()[1])
    return None


def check():
    fd = os.open('/dev/ion', os.O_RDWR)
    try:
        request = bytearray(struct.pack('<QQIIII', LENGTH, 0, HEAP_MASK, FLAGS, 0, 0))
        try:
            fcntl.ioctl(fd, ION_IOC_ALLOC, request, True)
        except OSError as exc:
            return {'ok': False, 'errno': errno.errorcode.get(exc.errno, exc.errno)}
        handle = struct.unpack_from('<I', request, 24)[0]
        fcntl.ioctl(fd, ION_IOC_FREE, bytearray(struct.pack('<I', handle)), True)
        return {'ok': True}
    finally:
        os.close(fd)


if __name__ == '__main__':
    result = check()
    result['cma_free_kb'] = cma_free_kb()
    print(json.dumps(result))
    raise SystemExit(0 if result['ok'] else 1)
