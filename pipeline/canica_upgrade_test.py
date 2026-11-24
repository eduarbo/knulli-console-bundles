#!/usr/bin/env python3
"""Release gate for a Canica kit installer: it installs on an empty card folder and over
each earlier installer given, with every file matching its inventory. Runs the installers'
own code, so it belongs in a job without secrets.

usage: canica_upgrade_test.py NEW_INSTALLER [EARLIER_INSTALLER ...]
"""
import hashlib
import os
import runpy
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path
from unittest.mock import patch


class Console:
    """The services record and checks of a console, without a console."""

    def __init__(self, root):
        self.path = root / 'system/services-fixture'
        self.path.write_text('samba')

    def check(self):
        pass

    def services(self):
        return self.path.read_text().split()

    def enable(self, on):
        self.path.write_text('samba canica' if on else 'samba')


def kit(installer):
    with zipfile.ZipFile(installer) as app:
        name, = [n for n in app.namelist() if n.endswith('.zip')]
        return zipfile.ZipFile(__import__('io').BytesIO(app.read(name)))


def unsealed(root, installer):
    """Inventory lines and kit members that are not on the card as packaged."""
    with kit(installer) as z:
        inventory = z.read('share/system/canica/SHA256SUMS').decode().splitlines()
        members = [n[6:] for n in z.namelist() if n.startswith('share/') and not n.endswith('/')]
    bad = [line[66:] for line in inventory
           if not (root / line[66:]).is_file() or hashlib.sha256((root / line[66:]).read_bytes()).hexdigest() != line[:64]]
    return bad + [m for m in members if not (root / m).is_file()]


def card(installer):
    work = Path(tempfile.mkdtemp()).resolve()
    root = work / 'userdata'
    (root / 'system').mkdir(parents=True)
    tool = work / 'tools/Instalar Canica.sh'
    tool.parent.mkdir()
    shutil.copy(installer, tool)
    return work, root, tool, Console(root)


def run(installer, tool, root, console):
    shutil.copy(installer, tool)
    return runpy.run_path(str(installer))['install'](tool, root, console)


def main():
    new, earlier = Path(sys.argv[1]), [Path(p) for p in sys.argv[2:]]
    problems = []
    with patch.object(os, 'sync', create=True):
        work, root, tool, console = card(new)
        run(new, tool, root, console)
        left = unsealed(root, new)
        guide = root / 'themes/es-theme-canica/README.md'
        stamp = guide.stat().st_mtime_ns
        run(new, tool, root, console)
        print('empty card: %s; second run %s' % ('sealed' if not left else 'NOT sealed %s' % left[:3],
                                                 'wrote nothing' if guide.stat().st_mtime_ns == stamp else 'REWROTE files'))
        if left or guide.stat().st_mtime_ns != stamp or 'canica' not in console.services():
            problems.append('empty card')
        guide.write_text('mine')
        try:
            run(new, tool, root, console)
            problems.append('an edited file was replaced')
        except ValueError as e:
            print('edited guide kept: %s' % e)
        shutil.rmtree(work)
        for old in earlier:
            work, root, tool, console = card(old)
            run(old, tool, root, console)
            before = unsealed(root, old)
            try:
                run(new, tool, root, console)
                left = unsealed(root, new)
            except ValueError as e:
                left = [str(e)]
            print('over %s: %s' % (old.name, 'sealed' if not (before or left) else 'NOT sealed %s' % (before + left)[:3]))
            if before or left:
                problems.append('upgrade from %s' % old.name)
            shutil.rmtree(work)
    print('upgrade test: %d problems' % len(problems))
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
