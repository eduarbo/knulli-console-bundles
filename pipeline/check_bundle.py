#!/usr/bin/env python3
"""Publish-side check (runs no build code): every file of the bundle is either declared
derived (built binaries, fork/merge outputs, fixtures of the new stock files, SHA256SUMS,
the readback script) or exactly its reviewed template with the kill switch injected in the
declared entry points and the declared pin map applied. SHA256SUMS must match the files.

usage: check_bundle.py --dist DIST --units UNITS_DIR [--acceptance DIR]
UNITS_DIR holds the reviewed templates (<id>/install/...).
"""
import argparse
import hashlib
import json
import os
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from repin import inject_kill_switch, map_text  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dist', required=True)
    ap.add_argument('--units', required=True)
    from repin import ACCEPTANCE
    ap.add_argument('--acceptance', default=ACCEPTANCE)
    a = ap.parse_args()
    m = json.load(open(os.path.join(a.dist, 'manifest.json')))
    files = {}
    with tarfile.open(os.path.join(a.dist, m['tarball']['name']), 'r:gz') as tar:
        for t in tar:
            if t.isfile():
                files[t.name] = tar.extractfile(t).read()
            elif not t.isdir():
                sys.exit('not a file or folder in the tarball: %s' % t.name)
    problems = []
    for u in m['units']:
        if u['status'] != 'included':
            continue
        uid, tmpl = u['id'], os.path.join(a.units, u['id'], 'install')
        mapping = {old: new for old, new in u.get('repinned', [])}
        entry = {e['path']: e['kill_switch'] for e in u.get('entry_points', [])}
        derived = set(u.get('derived', []))
        bundle = {k[len('units/%s/' % uid):]: v for k, v in files.items() if k.startswith('units/%s/' % uid)}
        if set(bundle) != set(u['files']):
            problems.append('%s: tarball and manifest list different files' % uid)
        for rel, data in sorted(bundle.items()):
            if hashlib.sha256(data).hexdigest() != u['files'][rel]['sha256']:
                problems.append('%s/%s: sha256 differs from the manifest' % (uid, rel))
            if rel == 'autoupdate-verify.sh':
                if data != open(os.path.join(a.acceptance, uid + '.sh'), 'rb').read():
                    problems.append('%s: readback script is not the reviewed one' % uid)
                continue
            if rel in derived:
                continue
            p = os.path.join(tmpl, rel)
            if not os.path.isfile(p):
                problems.append('%s/%s: not in the template and not declared derived' % (uid, rel))
                continue
            raw = open(p, 'rb').read()
            if b'\0' in raw[:65536]:
                expected = raw
            else:
                text = raw.decode('utf-8', 'surrogateescape')
                if rel in entry:
                    text = inject_kill_switch(text, entry[rel])
                expected = map_text(text, mapping).encode('utf-8', 'surrogateescape')
            if expected != data:
                problems.append('%s/%s: differs from template + kill switch + pin map' % (uid, rel))
        for d, _, names in os.walk(tmpl):
            for n in names:
                rel = os.path.relpath(os.path.join(d, n), tmpl)
                if rel not in bundle and not n.endswith(('.pyc', '.DS_Store')) and '__pycache__' not in rel:
                    problems.append('%s/%s: template file missing from the bundle' % (uid, rel))
        if 'SHA256SUMS' in bundle:
            for line in bundle['SHA256SUMS'].decode().splitlines():
                digest, name = line.split('  ', 1)
                if hashlib.sha256(bundle.get(name, b'')).hexdigest() != digest:
                    problems.append('%s: SHA256SUMS wrong for %s' % (uid, name))
    for p in problems:
        print(p)
    print('bundle check: %d problems in %d units' % (len(problems), sum(u['status'] == 'included' for u in m['units'])))
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
