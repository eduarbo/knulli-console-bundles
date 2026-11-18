#!/usr/bin/env python3
"""Re-pin the version-tied units for a new firmware.

usage: repin.py --units DIR --work DIR --out DIR

--units  folder with the reviewed units (<id>/install/...), pinned to the template firmware
--work   pipeline work folder: stock.env, sysroot/, rebase/ (rebase.env, knulli-linux repo),
         es-build/ (emulationstation, es.status), connman-build/ (connmand, connman.status)
--out    receives <id>/ (the unit's install tree, re-pinned) and units.json

Each unit is copied from its template and every pin is moved from the template firmware to
the new one with one exact string map per unit: the knulli.version string, the sha256 of
each stock file it checks and of each file it derives from them. Derived files:
  fork   the file from the rebased knulli-linux series (the template must equal the fork's
         file on the series branch, and the firmware's stock file the release's source)
  merge  the device copy's own change carried onto the new stock file (git merge-file,
         base = the template's stock fixture); a conflict excludes the unit
  build  binaries from build_es.sh / build_connman.sh
  inject the kill switch (KILL_SWITCH below) in each unit's services and hooks: a file
         fixes-off on the FAT boot partition keeps the fix off at the next start, offline
A unit that cannot be derived is excluded with the reason and a class (conflict, gate,
build, tests, firmware, patch, not-needed); it stays off on the console (fail closed).
"""
import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def read_env(path):
    """KEY=value lines as written by extract.sh / rebase.sh (values may be %q-quoted)."""
    env = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip('\n')
            if '=' in line and not line.lstrip().startswith('#'):
                k, v = line.split('=', 1)
                env[k] = ' '.join(shlex.split(v)) if v else ''
    return env


def stock_key(path):
    return 'SHA_' + re.sub(r'[/.\-]', '_', path.upper())


class Excluded(Exception):
    def __init__(self, reason, cls='firmware'):
        super().__init__(reason)
        self.cls = cls


KILL_SWITCH_COMMENT = '# Kill switch (unit 16): a file fixes-off on the FAT boot partition keeps every fix off.\n'
KILL_SWITCH = {
    'service': KILL_SWITCH_COMMENT +
    'if [ "${1:-}" = start ] && [ -e "${FIXES_OFF:-/boot/fixes-off}" ]; then echo "fixes-off: $0 not started"; exit 0; fi\n',
    'hook': KILL_SWITCH_COMMENT + 'if [ -e "${FIXES_OFF:-/boot/fixes-off}" ]; then exit 0; fi\n',
    # The Wi-Fi fix is the way back in: stock ConnMan cannot join the home network, so only
    # fixes-off-all stops it (fixes-off alone would also cut SSH and the next bundle)
    'lifeline': '# Kill switch (unit 16): only fixes-off-all on the FAT boot partition stops this fix.\n'
    'if [ "${1:-}" = start ] && [ -e "${FIXES_OFF_ALL:-/boot/fixes-off-all}" ]; then echo "fixes-off-all: $0 not started"; exit 0; fi\n',
}


def inject_kill_switch(text, kind):
    """The kill-switch line after the leading shebang/comment/blank lines (deterministic)."""
    lines = text.split('\n')
    i = 0
    while i < len(lines) and (lines[i].startswith('#') or not lines[i].strip()):
        i += 1
    return '\n'.join(lines[:i]) + ('\n' if i else '') + KILL_SWITCH[kind] + '\n'.join(lines[i:])


class Ctx:
    def __init__(self, args):
        self.units = args.units
        self.work = args.work
        self.out = args.out
        self.stock = read_env(os.path.join(args.work, 'stock.env'))
        self.rebase = read_env(os.path.join(args.work, 'rebase', 'rebase.env'))
        self.pins = read_env(os.path.join(HERE, 'pins.env'))
        self.sysroot = os.path.join(args.work, 'sysroot')
        self.repo = os.path.join(args.work, 'rebase', 'knulli-linux')
        self.tag = self.rebase['TAG']
        self.series_ref = 'origin/' + config()['KNULLI_SERIES_REF']
        self.final = {}     # uid -> {relpath: sha} of finished units (cross-unit pins)
        # exactly what the console compares: $(cat knulli.version), trailing newlines dropped
        with open(os.path.join(self.sysroot, 'usr/share/knulli/knulli.version')) as f:
            self.version = f.read().rstrip('\n')

    def head(self, group):
        """Rebased head of a knulli-linux group; Excluded when its commits did not apply."""
        status = self.rebase.get('KNULLI_LINUX_%s_STATUS' % group)
        if status != 'ok':
            raise Excluded('fix series %s on %s (group %s): %s' % (
                'rejected by the gate' if status == 'gate' else 'does not apply', self.tag, group,
                conflict_line(self.work, 'knulli-linux-' + group)), 'gate' if status == 'gate' else 'conflict')
        return 'bundle-%s-knulli-linux-%s' % (self.tag, group)

    def git_show(self, rev, path):
        r = subprocess.run(['git', '-C', self.repo, 'show', '%s:%s' % (rev, path)],
                           capture_output=True)
        return r.stdout if r.returncode == 0 else None

    def stock_file(self, path):
        p = os.path.join(self.sysroot, path)
        if not os.path.isfile(p):
            raise Excluded('the firmware has no /%s' % path)
        return p

    def require_pins(self, names, why):
        """Firmware files a unit was validated against must be unchanged."""
        changed = ['%s (%s)' % (n, self.stock.get(n, 'absent')[:12]) for n in names
                   if self.stock.get(n) != self.pins.get('PIN_' + n)]
        if changed:
            raise Excluded('%s changed since validation on scarab 2026/05/11: %s' % (why, ', '.join(changed)))


def config():
    return read_env(os.path.join(HERE, 'config.env'))


def conflict_line(work, name):
    try:
        with open(os.path.join(work, 'rebase', 'conflict-%s.txt' % name)) as f:
            text = f.read()
    except OSError:
        return 'no conflict report'
    m = re.search(r'^commit:  (\S+) (.*)$', text, re.M)
    files = re.findall(r'^CONFLICT \([^)]*\): .* in (\S+)$', text, re.M)
    if m:
        return '%s "%s" conflicts in %s' % (m.group(1)[:12], m.group(2), ', '.join(files) or '?')
    g = re.search(r'^gate rejected: (.*)$', text, re.M)
    return g.group(1)[:300] if g else text.strip()[:200]


def is_text(path):
    with open(path, 'rb') as f:
        return b'\0' not in f.read(65536)


def template_version(units):
    with open(os.path.join(units, '01-suspend-auto-poweroff', 'install', 'unit.sh')) as f:
        return re.search(r"^FIRMWARE='([^']+)'$", f.read(), re.M).group(1)


def pin_value(path, name):
    with open(path) as f:
        m = re.search(r'^%s=([0-9a-f]{64})\b' % re.escape(name), f.read(), re.M)
    if not m:
        raise SystemExit('template %s has no %s' % (path, name))
    return m.group(1)


def apply_map(root, mapping, skip=()):
    """Replace every old pin with its new value in the unit's text files."""
    changed = []
    for d, _, files in os.walk(root):
        for name in files:
            p = os.path.join(d, name)
            rel = os.path.relpath(p, root)
            if rel in skip or not is_text(p):
                continue
            with open(p, encoding='utf-8', errors='surrogateescape') as f:
                text = f.read()
            new = map_text(text, mapping)
            if new != text:
                st = os.stat(p)
                with open(p, 'w', encoding='utf-8', errors='surrogateescape') as f:
                    f.write(new)
                os.chmod(p, st.st_mode)
                changed.append(rel)
    return sorted(changed)


def map_text(text, mapping):
    for old, value in mapping.items():
        if old != value:
            text = text.replace(old, value)
    return text


def refresh_sha256sums(root):
    p = os.path.join(root, 'SHA256SUMS')
    if not os.path.exists(p):
        return
    lines = []
    with open(p) as f:
        for line in f:
            _, name = line.rstrip('\n').split('  ', 1)
            lines.append('%s  %s\n' % (sha(os.path.join(root, name)), name))
    with open(p, 'w') as f:
        f.writelines(lines)


def write_file(path, data, like=None):
    mode = os.stat(like or path).st_mode if os.path.exists(like or path) else 0o644
    with open(path, 'wb') as f:
        f.write(data)
    os.chmod(path, mode)


def derive_fork(ctx, group, dst, template_file, fork_path, stock_path):
    """dst <- fork file at the group's rebased head. Returns (old sha, new sha)."""
    head = ctx.head(group)
    old = sha(template_file)
    at_ref = ctx.git_show(ctx.series_ref, fork_path)
    if at_ref is None or sha_bytes(at_ref) != old:
        raise Excluded('template %s differs from the fork series file %s' % (os.path.basename(dst), fork_path), 'build')
    new = ctx.git_show(head, fork_path)
    if new is None:
        raise Excluded('%s is gone from the rebased series' % fork_path, 'not-needed')
    if stock_path:
        source = ctx.git_show(ctx.tag, fork_path)
        stock = open(ctx.stock_file(stock_path), 'rb').read()
        if source != stock:
            raise Excluded('firmware /%s is not %s of tag %s: the fork file is not stock plus the fix'
                           % (stock_path, fork_path, ctx.tag))
        if new == stock:
            raise Excluded('%s: the fix is upstream (rebased file equals stock)' % fork_path, 'not-needed')
    write_file(dst, new, like=template_file)
    return old, sha_bytes(new)


def derive_merge(ctx, dst, template_file, base_fixture, stock_path):
    """dst <- the device copy's change carried onto the new stock file."""
    old = sha(template_file)
    new_stock = ctx.stock_file(stock_path)
    r = subprocess.run(['git', 'merge-file', '-p', '--diff3', template_file, base_fixture, new_stock],
                       capture_output=True)
    if r.returncode != 0:
        raise Excluded('merge conflict carrying %s onto the new /%s (%d conflicts)'
                       % (os.path.basename(dst), stock_path, r.returncode), 'conflict')
    write_file(dst, r.stdout, like=template_file)
    return old, sha_bytes(r.stdout)


def copy_template(ctx, uid, mapping):
    """Copy the reviewed unit and inject the kill switch in its entry points."""
    src = os.path.join(ctx.units, uid, 'install')
    dst = os.path.join(ctx.out, uid)
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst, symlinks=False, ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.DS_Store'))
    for rel, kind in UNITS[uid].get('entry', ()):
        p = os.path.join(dst, rel)
        old = sha(p)
        write_file(p, inject_kill_switch(open(p, encoding='utf-8').read(), kind).encode(), like=p)
        mapping[old] = sha(p)
    return src, dst


def fixture(dst, name, stock_path, ctx, mapping):
    """Replace a test fixture of the template stock file with the new stock file."""
    p = os.path.join(dst, 'tests', 'fixtures', name)
    old = sha(p)
    new = ctx.stock_file(stock_path)
    shutil.copyfile(new, p)
    mapping[old] = sha(new)


def unit01(ctx, uid, m):
    src, dst = copy_template(ctx, uid, m)
    m[template_version(ctx.units)] = ctx.version
    m[pin_value(os.path.join(src, 'install.sh'), 'STOCK_SHA')] = ctx.stock[stock_key('usr/bin/knulli-suspend')]
    old, new = derive_fork(ctx, '01', os.path.join(dst, 'files', 'knulli-suspend'), os.path.join(src, 'files', 'knulli-suspend'),
                           'board/fsoverlay/usr/bin/knulli-suspend', 'usr/bin/knulli-suspend')
    m[old] = new
    fixture(dst, 'knulli-suspend.stock', 'usr/bin/knulli-suspend', ctx, m)
    return dst, ['tests/fixtures/knulli-suspend.stock'], ['files/knulli-suspend', 'tests/fixtures/knulli-suspend.stock']


DS_PINS = ['KERNEL', 'SHA_PART_BOOT', 'SHA_USR_SHARE_ADVANCED_DRASTIC_DRASTIC',
           'SHA_USR_SHARE_ADVANCED_DRASTIC_LIBS_LIBSDL2_2_0_SO_0', 'SHA_USR_SHARE_ADVANCED_DRASTIC_LAUNCH_SH']


def unit02(ctx, uid, m):
    ctx.require_pins(DS_PINS, 'kernel (ION/CMA), DraStic or its SDL')
    src, dst = copy_template(ctx, uid, m)
    m[template_version(ctx.units)] = ctx.version
    return dst, [], []


def unit17(ctx, uid, m):
    ctx.require_pins(DS_PINS, 'kernel (ION/CMA), DraStic or its SDL')
    if '02-ds-cma-after-suspend' not in ctx.final:
        raise Excluded('needs unit 02 in the same bundle (17 takes over its guard)', 'firmware')
    src, dst = copy_template(ctx, uid, m)
    m[template_version(ctx.units)] = ctx.version
    # 17 checks and restores unit 02's guard by sha: point it at this bundle's 02 guard
    guard02 = ctx.final['02-ds-cma-after-suspend']['files/ds-ion-guard.sh']
    m[pin_value(os.path.join(src, 'install.sh'), 'UNIT02_SHA')] = guard02
    shutil.copyfile(os.path.join(ctx.out, '02-ds-cma-after-suspend', 'files', 'ds-ion-guard.sh'),
                    os.path.join(dst, 'tests', 'fixtures', 'ds-ion-guard.sh.unit02'))
    return dst, ['tests/fixtures/ds-ion-guard.sh.unit02'], ['tests/fixtures/ds-ion-guard.sh.unit02']


def unit18(ctx, uid, m):
    src, dst = copy_template(ctx, uid, m)
    m[template_version(ctx.units)] = ctx.version
    return dst, [], []


def unit20(ctx, uid, m):
    src, dst = copy_template(ctx, uid, m)
    m[template_version(ctx.units)] = ctx.version
    return dst, [], []


def unit03(ctx, uid, m):
    src, dst = copy_template(ctx, uid, m)
    m[template_version(ctx.units)] = ctx.version
    m[pin_value(os.path.join(src, 'install.sh'), 'IDLE_STOCK')] = ctx.stock[stock_key('etc/idlewatcher/idle.d/01idle-hooks')]
    m[pin_value(os.path.join(src, 'install.sh'), 'ACTIVE_STOCK')] = ctx.stock[stock_key('etc/idlewatcher/active.d/01active-hooks')]
    old, new = derive_fork(ctx, '03', os.path.join(dst, 'files', 'knulli-aggressive-saver'),
                           os.path.join(src, 'files', 'knulli-aggressive-saver'),
                           'board/fsoverlay/usr/bin/knulli-aggressive-saver', None)
    m[old] = new
    for name, stock in (('01idle-hooks', 'etc/idlewatcher/idle.d/01idle-hooks'),
                        ('01active-hooks', 'etc/idlewatcher/active.d/01active-hooks')):
        old, new = derive_merge(ctx, os.path.join(dst, 'files', name), os.path.join(src, 'files', name),
                                os.path.join(src, 'tests', 'fixtures', name + '.stock'), stock)
        m[old] = new
        fixture(dst, name + '.stock', stock, ctx, m)
    fixture(dst, 'S31emulationstation.device', 'etc/init.d/S31emulationstation', ctx, m)
    fixtures = ['tests/fixtures/01idle-hooks.stock', 'tests/fixtures/01active-hooks.stock',
                'tests/fixtures/S31emulationstation.device']
    return dst, fixtures, fixtures + ['files/knulli-aggressive-saver', 'files/01idle-hooks', 'files/01active-hooks']


def manifest_fields(path):
    fields = {}
    with open(path) as f:
        for line in f:
            k, v = line.rstrip('\n').split('=', 1)
            fields[k] = v
    return fields


def unit07(ctx, uid, m):
    es = os.path.join(ctx.work, 'es-build')
    status = ctx.rebase.get('ES_STATUS')
    if status != 'ok' and ctx.rebase.get('ES_SOURCE') == 'package':
        raise Excluded("Knulli's ES package patches of %s do not apply onto the ES commit it pins (see "
                       "conflict-es.txt): the ES it ships cannot be rebuilt here" % ctx.tag, 'conflict')
    if status != 'ok':
        raise Excluded('ES fix series %s on the ES %s ships: %s' % (
            'rejected by the gate' if status == 'gate' else 'does not apply', ctx.tag, conflict_line(ctx.work, 'es')),
            'gate' if status == 'gate' else 'conflict')
    if open(os.path.join(es, 'es.status')).read().strip() != '0':
        raise Excluded('ES build or its firmware-load gate failed (see es-checks.txt)', 'build')
    func = os.path.join(ctx.work, 'es-functional', 'es-functional.status')
    if os.path.exists(func) and open(func).read().strip() != '0':
        raise Excluded('ES API/UI tests (headless) failed (see es-functional.log)', 'tests')
    if ctx.rebase.get('ES_APPLIED') == '0':
        raise Excluded('every ES fix is upstream already', 'not-needed')
    src = os.path.join(ctx.units, uid, 'install')
    tm = manifest_fields(os.path.join(src, 'payload', 'manifest'))
    if tm['VERSION'] != template_version(ctx.units):
        raise SystemExit('unit 07 template is pinned to %s' % tm['VERSION'])
    for k, f in (('LAUNCHER_SHA256', 'files/launcher.sh'), ('SERVICE_SHA256', 'files/service.sh')):
        if sha(os.path.join(src, f)) != tm[k]:
            raise SystemExit('unit 07 template manifest %s does not match %s' % (k, f))
    src, dst = copy_template(ctx, uid, m)
    shutil.copyfile(os.path.join(es, 'emulationstation'), os.path.join(dst, 'payload', 'emulationstation'))
    os.chmod(os.path.join(dst, 'payload', 'emulationstation'), 0o755)
    m[tm['VERSION']] = ctx.version
    m[tm['STOCK_SHA256']] = ctx.stock[stock_key('usr/bin/emulationstation')]
    m[tm['PATCHED_SHA256']] = sha(os.path.join(dst, 'payload', 'emulationstation'))
    fields = dict(tm)
    fields.update(VERSION=ctx.version, STOCK_SHA256=m[tm['STOCK_SHA256']], PATCHED_SHA256=m[tm['PATCHED_SHA256']],
                  LAUNCHER_SHA256=sha(os.path.join(dst, 'files', 'launcher.sh')),
                  SERVICE_SHA256=sha(os.path.join(dst, 'files', 'service.sh')),
                  ES_BASE=ctx.rebase['ES_ONTO'], ES_COMMIT=ctx.rebase['ES_HEAD'])
    with open(os.path.join(dst, 'payload', 'manifest'), 'w') as f:
        for k in ('MODEL', 'VERSION', 'STOCK_SHA256', 'PATCHED_SHA256', 'LAUNCHER_SHA256', 'SERVICE_SHA256',
                  'ES_BASE', 'ES_COMMIT'):
            f.write('%s=%s\n' % (k, fields[k]))
    return dst, ['payload/manifest'], ['payload/manifest', 'payload/emulationstation']


def unit10(ctx, uid, m):
    cb = os.path.join(ctx.work, 'connman-build')
    ctx.head('10')
    status = open(os.path.join(cb, 'connman.status')).read().strip()
    if status == '3':
        raise Excluded('not needed: %s' % open(os.path.join(cb, 'connman-checks.txt')).read().strip(), 'not-needed')
    if status != '0':
        raise Excluded('ConnMan build or its gates failed (see connman-checks.txt)', 'build')
    src = os.path.join(ctx.units, uid, 'install')
    reviewed = os.path.join(src, 'files', 'connman-1.42-generic-pmf.patch')
    used = os.path.join(cb, 'in', 'connman-pmf.patch')
    if open(reviewed, 'rb').read() != open(used, 'rb').read():
        raise Excluded('the series ConnMan patch is not byte-identical to the reviewed one (%s vs %s)'
                       % (sha(used)[:12], sha(reviewed)[:12]), 'patch')
    src, dst = copy_template(ctx, uid, m)
    m[pin_value(os.path.join(src, 'install.sh'), 'CANDIDATE')] = sha(os.path.join(cb, 'connmand'))
    m[pin_value(os.path.join(src, 'install.sh'), 'STOCK')] = ctx.stock[stock_key('usr/sbin/connmand')]
    shutil.copyfile(os.path.join(cb, 'connmand'), os.path.join(dst, 'files', 'connmand'))
    os.chmod(os.path.join(dst, 'files', 'connmand'), 0o755)
    tmpl_version = '1.42'
    version = ctx.stock['CONNMAN_VERSION']
    if version != tmpl_version:
        # install.sh checks the candidate's --version; build.sh names the tarball
        tar = [f for f in os.listdir(os.path.join(cb, 'in')) if f.endswith('.tar.xz')][0]
        m['= "%s" ]' % tmpl_version] = '= "%s" ]' % version
        m['connman-%s.tar.xz' % tmpl_version] = tar
        m['/build/connman-%s\n' % tmpl_version] = '/build/connman-%s\n' % version
        m[re.search(r'echo "([0-9a-f]{64})  /in/connman-',
                    open(os.path.join(src, 'build.sh')).read()).group(1)] = sha(os.path.join(cb, 'in', tar))
    return dst, [], ['files/connmand']


GUARD = '/userdata/system/scripts/ds-ion-guard.sh'
UNITS = {
    '01-suspend-auto-poweroff': dict(
        derive=unit01, title='apagado tras suspensión', device_dir='/userdata/system/upstream-install/01',
        install='sh install.sh', rollback='sh rollback.sh', install_timeout=300,
        entry=[('files/suspend_poweroff', 'service')]),
    '02-ds-cma-after-suspend': dict(
        derive=unit02, title='guardia DS', device_dir='/userdata/system/upstream-install/02',
        install='sh install.sh', rollback='sh rollback.sh', install_timeout=300,
        entry=[('files/ds_guard', 'service'), ('files/ds-ion-guard.sh', 'hook')], owns=[GUARD]),
    '03-powersaver-es-api': dict(
        derive=unit03, title='ahorro con retenciones', device_dir='/userdata/system/upstream-install/03',
        install='sh install.sh', rollback='sh rollback.sh', install_timeout=300,
        entry=[('files/es_api_hold', 'service')]),
    '07-es-api-events': dict(
        derive=unit07, title='ES parchado', device_dir='/userdata/system/es-patched-bundle',
        install='bash install.sh', rollback='bash rollback.sh', install_timeout=600,
        entry=[('files/service.sh', 'service')], requires_soft=['03-powersaver-es-api']),
    '10-wifi-pmf-8821cs': dict(
        derive=unit10, title='Wi-Fi PMF', device_dir='/userdata/system/upstream-install/10',
        install='bash install.sh', rollback='bash rollback.sh', install_timeout=600,
        entry=[('files/connman_pmf', 'lifeline')]),
    '17-ds-cma-reserve': dict(
        derive=unit17, title='reserva CMA para DS', device_dir='/userdata/system/upstream-install/17',
        install='sh install.sh', rollback='sh rollback.sh', install_timeout=300,
        entry=[('files/cma_reserve', 'service'), ('files/ds-ion-guard.sh', 'hook')],
        requires=['02-ds-cma-after-suspend'], takes_over={GUARD: '02-ds-cma-after-suspend'}),
    '18-per-game-performance': dict(
        derive=unit18, title='rendimiento por juego', device_dir='/userdata/system/upstream-install/18',
        install='sh install.sh', rollback='sh rollback.sh', install_timeout=300,
        entry=[('files/game-performance.sh', 'hook')]),
    '20-suspend-drain-watch': dict(
        derive=unit20, title='registro de suspensión y Wi-Fi tras reanudar', device_dir='/userdata/system/upstream-install/20',
        install='sh install.sh', rollback='sh rollback.sh', install_timeout=300,
        entry=[('files/suspend_log', 'service')]),
}


def unit_digest(root):
    h = hashlib.sha256()
    for d, _, files in sorted(os.walk(root)):
        for name in sorted(files):
            p = os.path.join(d, name)
            h.update(('%s\0%s\0%o\n' % (os.path.relpath(p, root), sha(p), os.stat(p).st_mode & 0o777)).encode())
    return h.hexdigest()


ACCEPTANCE = next((p for p in (os.path.join(HERE, '..', 'acceptance'),
                                os.path.join(HERE, '..', 'install', 'files', 'acceptance')) if os.path.isdir(p)), '')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--units', required=True)
    ap.add_argument('--work', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--acceptance', default=ACCEPTANCE)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    ctx = Ctx(args)
    order = config()['UNITS'].split()
    result = []
    for uid in order:
        spec = UNITS[uid]
        entry = dict(id=uid, title=spec['title'], device_dir=spec['device_dir'], install=spec['install'],
                     rollback=spec['rollback'], verify=spec['install'].split()[0] + ' autoupdate-verify.sh',
                     install_timeout=spec['install_timeout'], requires=spec.get('requires', []),
                     owns=spec.get('owns', []), takes_over=spec.get('takes_over', {}),
                     entry_points=[dict(path=p, kill_switch=k) for p, k in spec.get('entry', ())])
        if not os.path.isdir(os.path.join(args.units, uid, 'install')):
            entry.update(status='excluded', reason='no template in the units folder', **{'class': 'build'})
            result.append(entry)
            print('%-26s excluded: no template' % uid)
            continue
        mapping = {}
        try:
            dst, skip, derived = spec['derive'](ctx, uid, mapping)
            changed = apply_map(dst, mapping, skip=skip)
            refresh_sha256sums(dst)
            shutil.copyfile(os.path.join(args.acceptance, uid + '.sh'), os.path.join(dst, 'autoupdate-verify.sh'))
            os.chmod(os.path.join(dst, 'autoupdate-verify.sh'), 0o755)
            leftovers = [old for old, new in mapping.items() if old != new and re.fullmatch(r'[0-9a-f]{64}', old)
                         and subprocess.run(['grep', '-rlI', old, dst], capture_output=True).stdout]
            if leftovers:
                raise SystemExit('%s: old pins left after the map: %s' % (uid, leftovers))
            ctx.final[uid] = {os.path.relpath(os.path.join(d, n), dst): sha(os.path.join(d, n))
                              for d, _, fs in os.walk(dst) for n in fs}
            entry.update(status='included', repinned=sorted({k: v for k, v in mapping.items() if k != v}.items()),
                         changed_files=changed, derived=sorted(set(derived) | {'SHA256SUMS', 'autoupdate-verify.sh'}),
                         digest=unit_digest(dst))
        except Excluded as e:
            shutil.rmtree(os.path.join(args.out, uid), ignore_errors=True)
            entry.update(status='excluded', reason=str(e), **{'class': e.cls})
        print('%-26s %s%s' % (uid, entry['status'], (': ' + entry['reason']) if 'reason' in entry else ''))
        result.append(entry)
    # a unit that requires an excluded unit is excluded too
    status = {u['id']: u['status'] for u in result}
    for u in result:
        missing = [r for r in u['requires'] if status.get(r) != 'included']
        if u['status'] == 'included' and missing:
            shutil.rmtree(os.path.join(args.out, u['id']), ignore_errors=True)
            u.update(status='excluded', reason='requires %s, which is left out' % ', '.join(missing), **{'class': 'firmware'})
            for k in ('digest', 'changed_files', 'repinned', 'derived'):
                u.pop(k, None)
    with open(os.path.join(args.out, 'units.json'), 'w') as f:
        json.dump(result, f, indent=1)


if __name__ == '__main__':
    main()
