#!/usr/bin/env python3
"""The Canica channel's public keys, checked as data (no kit code runs).

usage:
  canica_keys.py same CHANNEL_DIR KIT_KEYS_DIR   the kit seals exactly the channel's keys: the same
                                                 files, byte for byte, two Ed25519 public keys
  canica_keys.py extract INSTALLER OUT_DIR       the keys a published installer's kit seals
                                                 (OUT_DIR stays empty for a kit without keys)
"""
import base64
import io
import os
import sys
import zipfile

ED25519_SPKI = bytes.fromhex("302a300506032b6570032100")
PREFIX = 'share/system/canica/keys/'


def ed25519_public(data):
    lines = [line.strip() for line in data.decode('ascii').strip().splitlines()]
    if len(lines) < 3 or lines[0] != '-----BEGIN PUBLIC KEY-----' or lines[-1] != '-----END PUBLIC KEY-----':
        return False
    der = base64.b64decode(''.join(lines[1:-1]), validate=True)
    return len(der) == 44 and der.startswith(ED25519_SPKI)


def keys(folder):
    found = {}
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if name.endswith('.pub'):
            with open(os.path.join(folder, name), 'rb') as f:
                found[name] = f.read()
    return found


def same(channel, kit):
    a, b = keys(channel), keys(kit)
    if len(a) != 2 or not all(ed25519_public(data) for data in a.values()):
        sys.exit('%s must hold exactly two Ed25519 public keys' % channel)
    if a != b:
        sys.exit('the kit does not seal exactly the channel keys: %s vs %s' % (sorted(b), sorted(a)))
    print('kit seals the channel keys: %s' % ', '.join(sorted(a)))


def extract(installer, out):
    os.makedirs(out, exist_ok=True)
    with zipfile.ZipFile(installer) as app:
        kits = [n for n in app.namelist() if n.endswith('.zip')]
        if len(kits) != 1:
            sys.exit('the installer does not hold one kit')
        with zipfile.ZipFile(io.BytesIO(app.read(kits[0]))) as kit:
            for name in kit.namelist():
                rest = name[len(PREFIX):]
                if name.startswith(PREFIX) and rest.endswith('.pub') and '/' not in rest and rest not in ('', '.pub'):
                    with open(os.path.join(out, rest), 'wb') as f:
                        f.write(kit.read(name))
    print('%d keys sealed in %s' % (len(keys(out)), os.path.basename(installer)))


def main():
    if len(sys.argv) == 4 and sys.argv[1] == 'same':
        same(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == 'extract':
        extract(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
