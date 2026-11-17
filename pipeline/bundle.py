#!/usr/bin/env python3
"""Assemble the console bundle: a reproducible tarball of the included units and the
manifest that the console verifies (after fix_updater checks its signature).

usage: bundle.py --work DIR --units DIR --dist DIR --image NAME --image-sha256 SHA [--serial N]

dist/manifest.json          what the signature covers: firmware, sources, units, every file
dist/bundle-<serial>.tar.gz units/<id>/... of the included units (sorted, mtime fixed, root)
dist/series-<serial>.tar.gz the rebased patch series and build logs (audit only)
dist/report.md              the run's outcome for people (also the release notes)
"""
import argparse
import gzip
import hashlib
import io
import json
import os
import re
import tarfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FINGERPRINT = ('usr/share/knulli/knulli.version', 'etc/init.d/S31emulationstation',
               'usr/bin/emulationstation-standalone')


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def read_env(path):
    import shlex
    env = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip('\n')
            if '=' in line and not line.lstrip().startswith('#'):
                k, v = line.split('=', 1)
                env[k] = ' '.join(shlex.split(v)) if v else ''
    return env


def slug(version):
    """Release tag part from the knulli.version string; the console computes the same."""
    return re.sub(r'[^a-z0-9]+', '-', version.lower()).strip('-')


def deterministic_tar(out, entries, mtime):
    """Gzip tar of (source path, archive name) entries with fixed metadata: root-owned, one
    mtime, mode 0755 for directories and owner-executable files, 0644 otherwise."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.GNU_FORMAT) as tar:
        for path, arcname in entries:
            info = tar.gettarinfo(path, arcname=arcname)
            if not (info.isfile() or info.isdir()):
                raise SystemExit('not a regular file or directory: %s' % path)
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            info.mtime = mtime
            info.mode = 0o755 if info.isdir() or os.stat(path).st_mode & 0o100 else 0o644
            if info.isfile():
                with open(path, 'rb') as f:
                    tar.addfile(info, f)
            else:
                tar.addfile(info)
    with open(out, 'wb') as f:
        with gzip.GzipFile(filename='', mode='wb', fileobj=f, mtime=0, compresslevel=9) as gz:
            gz.write(buf.getvalue())


def tree(root):
    """(path, relative name) for root's directories and files, sorted; no symlinks."""
    found = []
    for d, dirs, files in os.walk(root):
        dirs.sort()
        rel = os.path.relpath(d, root)
        if rel != '.':
            found.append((d, rel))
        for name in sorted(files):
            p = os.path.join(d, name)
            if os.path.islink(p):
                raise SystemExit('symlink: %s' % p)
            found.append((p, os.path.relpath(p, root)))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--work', required=True)
    ap.add_argument('--units', required=True, help='repin.py output (units.json and <id>/)')
    ap.add_argument('--dist', required=True)
    ap.add_argument('--image', required=True)
    ap.add_argument('--image-sha256', required=True)
    ap.add_argument('--serial', type=int, default=int(time.strftime('%Y%m%d%H%M%S', time.gmtime())))
    ap.add_argument('--min-serial', type=int, default=None,
                    help='oldest bundle serial consoles may still install for this firmware (default: this one)')
    args = ap.parse_args()
    os.makedirs(args.dist, exist_ok=True)
    stock = read_env(os.path.join(args.work, 'stock.env'))
    rebase = read_env(os.path.join(args.work, 'rebase', 'rebase.env'))
    cfg = read_env(os.path.join(HERE, 'config.env'))
    sysroot = os.path.join(args.work, 'sysroot')
    with open(os.path.join(sysroot, 'usr/share/knulli/knulli.version')) as f:
        version = f.read().rstrip('\n')
    units = json.load(open(os.path.join(args.units, 'units.json')))
    mtime = int(rebase['TAG_TIME'])

    entries = [(args.units, 'units')]
    for u in units:
        if u['status'] != 'included':
            continue
        root = os.path.join(args.units, u['id'])
        u['files'] = {rel: dict(sha256=sha(p), mode='0755' if os.stat(p).st_mode & 0o100 else '0644')
                      for p, rel in tree(root) if os.path.isfile(p)}
        entries += [(root, 'units/' + u['id'])] + [(p, 'units/%s/%s' % (u['id'], rel)) for p, rel in tree(root)]
    tarname = 'bundle-%d.tar.gz' % args.serial
    deterministic_tar(os.path.join(args.dist, tarname), entries, mtime)

    def lines(name, kind):
        try:
            return open(os.path.join(args.work, 'rebase', '%s.%s' % (name, kind))).read().splitlines()
        except OSError:
            return []

    def group(name):
        key = name.upper().replace('-', '_')
        g = dict(status=rebase.get(key + '_STATUS', 'absent'), mode=rebase.get(key + '_MODE', ''),
                 applied=lines(name, 'applied'), dropped_as_upstream=lines(name, 'dropped'))
        if g['status'] == 'ok':
            g.update(head=rebase[key + '_HEAD'], tree=rebase[key + '_TREE'])
        return g

    knulli_groups = [g.split(':', 1)[0] for g in rebase['KNULLI_GROUPS'].split()] + ['other']
    inputs_line = rebase.get('INPUTS', '')
    sources = dict(
        knulli_linux=dict(fork=cfg['KNULLI_FORK'], onto=rebase['KNULLI_LINUX_ONTO'],
                          groups={g: group('knulli-linux-' + g) for g in knulli_groups}),
        es=dict(group('es'), fork=cfg['ES_FORK'], onto=rebase['ES_ONTO']),
        es_pin=rebase['ES_PIN'], buildroot=rebase['BUILDROOT_COMMIT'])

    manifest = dict(
        format=1,
        kind='knulli-console-fixes',
        serial=args.serial,
        # consoles refuse any bundle for this firmware older than this (revokes older ones)
        min_serial=args.serial if args.min_serial is None else args.min_serial,
        complete=all(u['status'] == 'included' for u in units),
        inputs=inputs_line,
        created=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        model=cfg['DEVICE_MODEL'],
        firmware=dict(
            version=version, slug=slug(version), tag=rebase['TAG'], tag_commit=rebase['TAG_COMMIT'],
            image=args.image, image_sha256=args.image_sha256, kernel=stock['KERNEL'],
            connman=stock['CONNMAN_VERSION'],
            fingerprint={'/' + p: sha(os.path.join(sysroot, p)) for p in FINGERPRINT}),
        sources=sources,
        pipeline=dict(repo=os.environ.get('GITHUB_REPOSITORY', 'local'), commit=os.environ.get('GITHUB_SHA', ''),
                      run=('%s/%s/actions/runs/%s' % (os.environ.get('GITHUB_SERVER_URL', ''),
                                                      os.environ.get('GITHUB_REPOSITORY', ''),
                                                      os.environ['GITHUB_RUN_ID'])
                           if os.environ.get('GITHUB_RUN_ID') else '')),
        tarball=dict(name=tarname, sha256=sha(os.path.join(args.dist, tarname)),
                     size=os.path.getsize(os.path.join(args.dist, tarname))),
        units=units,
    )
    with open(os.path.join(args.dist, 'manifest.json'), 'w') as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
        f.write('\n')

    # Audit tarball: rebased series, build checks and logs, the extracted stock facts
    audit = [(os.path.join(args.work, 'rebase', 'series'), 'series')]
    audit += [(p, 'series/' + rel) for p, rel in tree(os.path.join(args.work, 'rebase', 'series'))]
    for d in ('es-build', 'connman-build'):
        p = os.path.join(args.work, d)
        if os.path.isdir(p):
            audit.append((p, d))
            audit += [(os.path.join(p, n), '%s/%s' % (d, n)) for n in sorted(os.listdir(p))
                      if n.endswith(('.txt', '.log', '.status'))]
    audit += [(os.path.join(args.work, 'stock.env'), 'stock.env'),
              (os.path.join(args.work, 'rebase', 'rebase.env'), 'rebase.env'),
              (os.path.join(args.units, 'units.json'), 'units.json')]
    deterministic_tar(os.path.join(args.dist, 'series-%d.tar.gz' % args.serial), audit, mtime)

    included = [u for u in units if u['status'] == 'included']
    lines_ = [
        'Console fixes for Knulli %s (`%s`) on the %s.' % (rebase['TAG'], version, cfg['DEVICE_MODEL']),
        '',
        '| unit | status |', '|---|---|',
    ] + ['| %s | %s |' % (u['id'], 'included' if u['status'] == 'included' else 'excluded: ' + u['reason'])
         for u in units] + [
        '',
    ] + ['knulli-linux group %s: %s, %s, %d applied, %d dropped as upstream%s.' % (
        g, v['status'], v['mode'], len(v['applied']), len(v['dropped_as_upstream']),
        ('; head `%s`' % v['head']) if v.get('head') else '')
        for g, v in sources['knulli_linux']['groups'].items()] + [
        'ES series: %s, %s onto `%s`, %d applied, %d dropped%s.' % (
            sources['es']['status'], sources['es']['mode'], sources['es']['onto'], len(sources['es']['applied']),
            len(sources['es']['dropped_as_upstream']),
            ('; tree `%s`' % sources['es']['tree']) if sources['es'].get('tree') else ''),
        '',
    ]
    for name in sorted(os.listdir(os.path.join(args.work, 'rebase'))):
        if name.startswith('conflict-') and name.endswith('.txt'):
            lines_ += ['Conflict report `%s`:' % name, '', '```',
                       open(os.path.join(args.work, 'rebase', name)).read().strip(), '```', '']
    lines_ += [
        'Machine lines (read by the pipeline, do not edit):',
        '',
        '    upstream-tag: %s' % rebase['TAG'],
        '    image-sha256: %s' % args.image_sha256,
        '    firmware: %s' % version,
        '    serial: %d' % args.serial,
        '    complete: %s' % ('yes' if manifest['complete'] else 'no'),
        '    inputs: %s' % inputs_line,
        '    units: %s' % ' '.join('%s=%s' % (u['id'], 'included' if u['status'] == 'included' else
                                             'excluded/' + u.get('class', '?')) for u in units),
        '    manifest-sha256: %s' % sha(os.path.join(args.dist, 'manifest.json')),
        '',
    ]
    with open(os.path.join(args.dist, 'report.md'), 'w') as f:
        f.write('\n'.join(lines_))
    print('bundle %s: %d/%d units, %s' % (tarname, len(included), len(units), slug(version)))


if __name__ == '__main__':
    main()
