#!/usr/bin/env python3
"""Run every included unit's own off-device tests on its re-pinned copy; a unit whose tests
fail is excluded from the bundle (class tests; it stays off on the console). An
infrastructure failure (docker cannot start a container, apt cannot fetch) fails the whole
step with exit INFRA_EXIT instead: a flaky mirror must not silently drop a fix.

usage: test_units.py --units DIR --work DIR

The re-pinned units are laid out as <scratch>/<id>/install (the layout of the task repo, so a
unit's tests find a sibling unit, e.g. 17's run 02's guard tests). Recipes:
  01, 02, 03, 17   tests/run_linux.sh (ubuntu:24.04, no network); 03 also tests/test_saver.sh
  18, 20           every tests/test_*.sh in ubuntu:24.04 (test_install.sh with dash and bash)
  07               test_install.sh, test_launcher.sh, test_fbcheck.py in the pinned Debian image
  10               tests/run.sh in the pinned Debian image with the firmware's stock connmand. The
                   v2 build it falls back to is a file of the owner's card (it names the home
                   network) and is never published, so the copy pins a stand-in file instead.
Logs: WORK/unit-tests/<id>.log
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from repin import read_env  # noqa: E402

CFG = read_env(os.path.join(HERE, 'config.env'))
INFRA = int(CFG.get('INFRA_EXIT', '90'))
V2_SHA = 'cda54485fe1de38838791b59589fa30d33b954c8e64b7800b28c14b6b3812697'
APT = ('. /pipe/apt.sh; ')


def debian(unit, script, extra=()):
    return ['docker', 'run', '--rm', '--platform', 'linux/arm64', '-e', 'DEBIAN_SNAPSHOT=' + CFG.get('DEBIAN_SNAPSHOT', ''),
            '-e', 'INFRA_EXIT=%d' % INFRA, '-v', '%s:/u' % unit, '-v', '%s:/pipe:ro' % HERE, *extra,
            CFG['DEBIAN_IMAGE'], 'bash', '-euc', APT + script]


GENERIC = ('for t in tests/test_*.sh; do case "$t" in */test_install.sh) for sh in /bin/dash /bin/bash; do '
           'printf "%s %s: " "$t" "$sh"; SH=$sh bash "$t" > /tmp/out 2>&1 || status=1; grep -v "^PASS" /tmp/out; done ;; '
           '*) printf "%s: " "$t"; bash "$t" > /tmp/out 2>&1 || status=1; grep -v "^PASS" /tmp/out ;; esac; done')


def commands(uid, unit, work):
    if uid in ('01-suspend-auto-poweroff', '02-ds-cma-after-suspend', '17-ds-cma-reserve'):
        return [['sh', 'tests/run_linux.sh']]
    if uid == '03-powersaver-es-api':
        return [['sh', 'tests/run_linux.sh'], ['bash', 'tests/test_saver.sh']]
    if uid in ('18-per-game-performance', '20-suspend-radio-off'):
        return [['docker', 'run', '--rm', '--network', 'none', '-v', '%s:/unit:ro' % unit, 'ubuntu:24.04', 'bash', '-c',
                 'cd /unit; status=0; ' + GENERIC + '; exit $status']]
    if uid == '07-es-api-events':
        return [debian(unit, 'apt_install curl python3 procps; '
                             'cd /u; bash tests/test_install.sh; bash tests/test_launcher.sh; python3 tests/test_fbcheck.py')]
    if uid == '10-wifi-pmf-8821cs':
        stand_in = os.path.join(unit, 'tests', 'v2-stand-in')
        with open(stand_in, 'wb') as f:
            f.write(b'#!/bin/sh\necho 1.42-v2-stand-in\n')
        os.chmod(stand_in, 0o755)
        new = hashlib.sha256(open(stand_in, 'rb').read()).hexdigest()
        for d, _, files in os.walk(unit):
            for name in files:
                p = os.path.join(d, name)
                data = open(p, 'rb').read()
                if V2_SHA.encode() in data:
                    open(p, 'wb').write(data.replace(V2_SHA.encode(), new.encode()))
        stock = os.path.join(work, 'sysroot', 'usr', 'sbin')
        return [debian(unit, 'apt_install libglib2.0-0 libdbus-1-3 libxtables12 procps; cd /u; '
                             'STOCK_BIN=/stock/connmand V2_BIN=/u/tests/v2-stand-in bash tests/run.sh',
                       extra=('-v', '%s:/stock:ro' % stock))]
    raise SystemExit('no test recipe for %s' % uid)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--units', required=True)
    ap.add_argument('--work', required=True)
    args = ap.parse_args()
    logs = os.path.join(args.work, 'unit-tests')
    os.makedirs(logs, exist_ok=True)
    path = os.path.join(args.units, 'units.json')
    units = json.load(open(path))
    scratch = tempfile.mkdtemp(prefix='unit-test-', dir=os.environ.get('UNIT_TEST_TMP'))
    for u in units:
        if u['status'] == 'included':
            shutil.copytree(os.path.join(args.units, u['id']), os.path.join(scratch, u['id'], 'install'))
    infra = []
    for u in units:
        if u['status'] != 'included':
            continue
        unit = os.path.join(scratch, u['id'], 'install')
        ok, tail = True, ''
        with open(os.path.join(logs, u['id'] + '.log'), 'w') as log:
            for cmd in commands(u['id'], unit, args.work):
                log.write('$ %s\n' % ' '.join(cmd))
                log.flush()
                r = subprocess.run(cmd, cwd=unit, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                out = r.stdout.decode(errors='replace')
                log.write(out)
                # docker: 125 = could not run the container (pull, daemon); INFRA = apt.sh
                if r.returncode in (125, INFRA) or 'Unable to find image' in out and r.returncode:
                    infra.append('%s: %s' % (u['id'], ' '.join(out.strip().splitlines()[-2:])[:200]))
                    break
                if r.returncode != 0:
                    ok = False
                    tail = ' '.join(out.strip().splitlines()[-2:])[:200]
        summary = [l for l in open(os.path.join(logs, u['id'] + '.log')).read().splitlines()
                   if 'passed' in l or 'failed' in l.lower() and not l.startswith('ok')]
        print('%-26s %s  %s' % (u['id'], 'tests ok' if ok else 'TESTS FAILED', ' | '.join(summary[-4:])))
        if not ok:
            shutil.rmtree(os.path.join(args.units, u['id']), ignore_errors=True)
            u.update(status='excluded', reason='off-device tests failed after re-pinning: ' + tail, **{'class': 'tests'})
            for k in ('digest', 'changed_files', 'repinned', 'derived'):
                u.pop(k, None)
        else:
            u['tests'] = 'passed'
    shutil.rmtree(scratch, ignore_errors=True)
    if infra:
        print('infrastructure failure, no unit excluded: ' + '; '.join(infra))
        sys.exit(INFRA)
    # a unit that requires a unit whose tests failed goes too
    status = {u['id']: u['status'] for u in units}
    for u in units:
        missing = [r for r in u.get('requires', []) if status.get(r) != 'included']
        if u['status'] == 'included' and missing:
            shutil.rmtree(os.path.join(args.units, u['id']), ignore_errors=True)
            u.update(status='excluded', reason='requires %s, which is left out' % ', '.join(missing), **{'class': 'tests'})
            for k in ('digest', 'changed_files', 'repinned', 'derived'):
                u.pop(k, None)
    with open(path, 'w') as f:
        json.dump(units, f, indent=1)


if __name__ == '__main__':
    main()
