#!/usr/bin/env python3
"""Keep the ION CMA buffers advanced_drastic's SDL needs from boot and hand them over.

SDL (h700 sdl2_drastic patches) asks the ION CMA heap for its window buffers:
ION_IOC_ALLOC, len 0x177000, heap mask 0x10, flags 2. On kernel 4.9 that is
cma_alloc() of 375 pages at a 1 MiB boundary (CONFIG_CMA_ALIGNMENT=8). It fails
(ION returns EPERM, dmesg "Fail to allocate buffer") when no 1 MiB-aligned run in
the 64 MiB area can be had, although CmaFree is large: every candidate run holds a
page that alloc_contig_range() cannot migrate, or a small allocation of another
driver. A buffer held since boot cannot be touched by either. The DS guard
releases the buffers right before SDL allocates and takes them back after the game.

  cma-reserve.py hold      start the holder unless it runs; wait until it holds
  cma-reserve.py release   stop the holder; return once its buffers are freed
  cma-reserve.py status    one JSON line; exit 0 while the buffers are held
  cma-reserve.py _holder   internal: allocate, record, wait for SIGTERM

Every command prints one JSON line. The holder frees on SIGTERM; if it is killed
the kernel frees the buffers when /dev/ion closes, so nothing can leak past it.
"""
import errno
import fcntl
import json
import os
import signal
import struct
import subprocess
import sys
import time

ION = '/dev/ion'
ION_IOC_ALLOC = 0xc0204900   # legacy 32-byte ion_allocation_data (kernel 4.9)
ION_IOC_FREE = 0xc0044901
LENGTH, HEAP_MASK, FLAGS = 0x177000, 0x10, 2
COUNT = int(os.environ.get('CMA_RESERVE_COUNT', '3'))   # SDL allocates three surfaces
RUN = os.environ.get('CMA_RESERVE_RUN', '/var/run')
STATE = os.path.join(RUN, 'cma-reserve.json')
LOCK = os.path.join(RUN, 'cma-reserve.lock')
LOG = os.environ.get('CMA_RESERVE_LOG', '/var/log/cma-reserve.log')
ME = os.path.realpath(__file__)


def cma_free_kb():
    try:
        with open('/proc/meminfo') as meminfo:
            for line in meminfo:
                if line.startswith('CmaFree:'):
                    return int(line.split()[1])
    except OSError:
        pass
    return None


def log(text):
    try:
        with open(LOG, 'a') as out:
            out.write(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()) + ' ' + text + '\n')
    except OSError:
        pass


def read_state():
    try:
        with open(STATE) as source:
            return json.load(source)
    except (OSError, ValueError):
        return None


def holder_alive(state):
    """The recorded holder still runs and is this script's holder."""
    if not state or not isinstance(state.get('pid'), int):
        return False
    try:
        with open('/proc/%d/cmdline' % state['pid'], 'rb') as source:
            argv = source.read().split(b'\0')
    except OSError:
        return False
    return b'_holder' in argv and any(arg.endswith(b'cma-reserve.py') for arg in argv)


def locked():
    handle = open(LOCK, 'w')
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def allocate(fd):
    request = bytearray(struct.pack('<QQIIII', LENGTH, 0, HEAP_MASK, FLAGS, 0, 0))
    fcntl.ioctl(fd, ION_IOC_ALLOC, request, True)
    return struct.unpack_from('<I', request, 24)[0]


def run_holder():
    fd = os.open(ION, os.O_RDWR | os.O_CLOEXEC)
    handles, error = [], None
    for attempt in range(5):
        while len(handles) < COUNT:
            try:
                handles.append(allocate(fd))
            except OSError as exc:
                error = errno.errorcode.get(exc.errno, str(exc.errno))
                break
        if len(handles) == COUNT:
            break
        time.sleep(1)
    stopping = []
    signal.signal(signal.SIGTERM, lambda _s, _f: stopping.append(1))
    signal.signal(signal.SIGINT, lambda _s, _f: stopping.append(1))
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    state = {'pid': os.getpid(), 'held': len(handles), 'wanted': COUNT, 'bytes': len(handles) * LENGTH,
             'since': int(time.time()), 'cma_free_kb': cma_free_kb()}
    if error and len(handles) < COUNT:
        state['error'] = error
    tmp = STATE + '.tmp'
    with open(tmp, 'w') as out:
        json.dump(state, out)
    os.replace(tmp, STATE)
    log('holder %d holds %d/%d buffers%s' % (os.getpid(), len(handles), COUNT,
                                               ' (' + error + ')' if 'error' in state else ''))
    while not stopping:
        signal.pause()
    for handle in handles:
        try:
            fcntl.ioctl(fd, ION_IOC_FREE, bytearray(struct.pack('<I', handle)), True)
        except OSError:
            pass
    os.close(fd)
    log('holder %d freed %d buffers' % (os.getpid(), len(handles)))
    return 0


def cmd_release():
    with locked():
        state = read_state()
        started = time.monotonic()
        result = {'action': 'release', 'held_before': state.get('held', 0) if holder_alive(state) else 0}
        if holder_alive(state):
            pid = state['pid']
            os.kill(pid, signal.SIGTERM)
            while time.monotonic() - started < 3 and os.path.exists('/proc/%d' % pid):
                time.sleep(0.02)
            if os.path.exists('/proc/%d' % pid):
                os.kill(pid, signal.SIGKILL)   # closing /dev/ion frees the buffers too
                while time.monotonic() - started < 5 and os.path.exists('/proc/%d' % pid):
                    time.sleep(0.02)
                result['killed'] = True
            result['released'] = not os.path.exists('/proc/%d' % pid)
        else:
            result['released'] = False
        try:
            os.unlink(STATE)
        except OSError:
            pass
        result['ms'] = int((time.monotonic() - started) * 1000)
        result['cma_free_kb'] = cma_free_kb()
    log('release: ' + json.dumps(result))
    return result, 0


def cmd_hold():
    with locked():
        state = read_state()
        if holder_alive(state) and state.get('held') == COUNT:
            return dict(state, action='hold', already=True), 0
        if holder_alive(state):   # partial: try again from scratch
            os.kill(state['pid'], signal.SIGTERM)
            for _ in range(150):
                if not os.path.exists('/proc/%d' % state['pid']):
                    break
                time.sleep(0.02)
        try:
            os.unlink(STATE)
        except OSError:
            pass
        proc = subprocess.Popen([sys.executable, ME, '_holder'], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True, close_fds=True)
        for _ in range(400):   # 8 s: up to five allocation rounds of 1 s
            state = read_state()
            if state and state.get('pid') == proc.pid:
                break
            if proc.poll() is not None:
                break
            time.sleep(0.02)
        state = read_state()
        if not state or state.get('pid') != proc.pid:
            return {'action': 'hold', 'held': 0, 'error': 'holder did not start'}, 1
        return dict(state, action='hold'), 0 if state.get('held') == COUNT else 1


def cmd_status():
    state = read_state()
    alive = holder_alive(state)
    result = dict(state or {}, action='status', running=alive, cma_free_kb=cma_free_kb())
    return result, 0 if alive and state.get('held') == COUNT else 1


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[0])
        return 2
    if argv[1] == '_holder':
        return run_holder()
    commands = {'hold': cmd_hold, 'release': cmd_release, 'status': cmd_status}
    if argv[1] not in commands:
        print(json.dumps({'error': 'unknown command ' + argv[1]}))
        return 2
    try:
        result, code = commands[argv[1]]()
    except OSError as exc:
        result, code = {'action': argv[1], 'error': type(exc).__name__ + ': ' + str(exc)}, 1
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
