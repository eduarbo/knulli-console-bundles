#!/usr/bin/env python3
"""Describe the pinned Canica kit installer for the console (runs none of its code).

usage: canica_manifest.py --pin canica/kit.env --payload FILE --dist DIR --extract DIR

The pin on main says which installer the console installs next: its URL, size and sha256,
the kit ZIP inside it and that kit's inventory digest. FILE is that download. It is checked
against every pinned value, opened as data, and unpacked into EXTRACT (installer/ and kit/)
so the privacy scan reads what the archive holds. DIST gets what is signed and published:
  manifest.json       kind canica-kit: model, firmware, serial, the payload's sha256 and size
  canica-<serial>.sh  the installer, byte for byte
"""
import argparse
import hashlib
import io
import json
import os
import re
import shutil
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bundle import read_env  # noqa: E402

SHA256 = re.compile(r'^[0-9a-f]{64}$')
LABEL = re.compile(r'^[A-Za-z0-9][A-Za-z0-9 .]{0,23}$')
VERSION = re.compile(r'^[0-9a-z][0-9a-z.+-]{0,39}$')
SOURCE = 'https://github.com/eduarbo/canica/releases/download/'
MEMBERS = ('__main__.py', 'resume-emulatorlauncher')


def unpack(archive, dest):
    """Regular files only, inside dest; returns the names."""
    names = []
    for info in archive.infolist():
        parts = info.filename.split('/')
        if info.filename.startswith('/') or any(p in ('', '.', '..') for p in parts[:-1]) or parts[-1] in ('.', '..'):
            sys.exit('archive path refused: %r' % info.filename)
        if info.is_dir():
            continue
        if (info.external_attr >> 28) not in (0, 8):
            sys.exit('not a regular file in the archive: %r' % info.filename)
        target = os.path.join(dest, *parts)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, 'wb') as f:
            f.write(archive.read(info))
        names.append(info.filename)
    return names


def main():
    ap = argparse.ArgumentParser()
    for name in ('pin', 'payload', 'dist', 'extract'):
        ap.add_argument('--' + name, required=True)
    a = ap.parse_args()
    pin = read_env(a.pin)
    serial = int(pin['SERIAL'])
    if not (LABEL.match(pin['LABEL']) and VERSION.match(pin['VERSION']) and serial > 0):
        sys.exit('bad VERSION, LABEL or SERIAL in the pin')
    if not pin['URL'].startswith(SOURCE):
        sys.exit('the pinned URL is not a release asset of the kit repository')
    for key in ('SHA256', 'KIT_SHA256', 'INVENTORY_SHA256'):
        if not SHA256.match(pin[key]):
            sys.exit('bad %s in the pin' % key)
    data = open(a.payload, 'rb').read()
    if len(data) != int(pin['SIZE']) or hashlib.sha256(data).hexdigest() != pin['SHA256']:
        sys.exit('the download is not the pinned installer (size %d, sha256 %s)' % (len(data), hashlib.sha256(data).hexdigest()))
    for d in (a.dist, a.extract):
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
    with zipfile.ZipFile(io.BytesIO(data)) as app:
        if sorted(app.namelist()) != sorted(MEMBERS + (pin['KIT'],)):
            sys.exit('unexpected installer members: %s' % app.namelist())
        kit = app.read(pin['KIT'])
        unpack(app, os.path.join(a.extract, 'installer'))
    os.remove(os.path.join(a.extract, 'installer', pin['KIT']))
    if hashlib.sha256(kit).hexdigest() != pin['KIT_SHA256']:
        sys.exit('the kit inside the installer is not the pinned one')
    with zipfile.ZipFile(io.BytesIO(kit)) as archive:
        inventory = hashlib.sha256(archive.read('share/system/canica/SHA256SUMS')).hexdigest()
        files = unpack(archive, os.path.join(a.extract, 'kit'))
    if inventory != pin['INVENTORY_SHA256']:
        sys.exit('the kit inventory is not the pinned one')
    name = 'canica-%d.sh' % serial
    with open(os.path.join(a.dist, name), 'wb') as f:
        f.write(data)
    manifest = dict(
        format=1,
        kind='canica-kit',
        model=pin['MODEL'],
        firmware=pin['FIRMWARE'],
        version=pin['VERSION'],
        label=pin['LABEL'],
        serial=serial,
        # consoles refuse any kit older than this one
        min_serial=serial,
        inventory_sha256=inventory,
        payload=dict(name=name, sha256=pin['SHA256'], size=len(data)),
        kit=dict(name=pin['KIT'], sha256=pin['KIT_SHA256'], files=len(files)),
        source=pin['URL'],
        created=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        pipeline=dict(repo=os.environ.get('GITHUB_REPOSITORY', 'local'), commit=os.environ.get('GITHUB_SHA', ''),
                      run=('%s/%s/actions/runs/%s' % (os.environ.get('GITHUB_SERVER_URL', ''),
                                                      os.environ.get('GITHUB_REPOSITORY', ''),
                                                      os.environ['GITHUB_RUN_ID'])
                           if os.environ.get('GITHUB_RUN_ID') else '')),
    )
    with open(os.path.join(a.dist, 'manifest.json'), 'w') as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
        f.write('\n')
    print('kit %s (%s), serial %d: %s, %d bytes, %d kit files' % (pin['LABEL'], pin['VERSION'], serial, name, len(data), len(files)))


if __name__ == '__main__':
    main()
