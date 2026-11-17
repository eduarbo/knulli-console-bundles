#!/usr/bin/env python3
"""Refuse to publish anything private: scan folders and tarballs (every file, as bytes).

usage: privacy_scan.py PATH...     (folders, files or .tar.gz)
Built-in patterns: private IPv4 addresses, private keys, SSH public keys, API tokens. Extra
literal strings (one per line; the home Wi-Fi name, ...) come from the file named by
PRIVACY_DENYLIST_FILE and from PRIVACY_DENYLIST_B64 (base64 of such a file; a CI secret); they
are matched case-insensitively and never printed. Exit 1 on a hit, 2 when PRIVACY_REQUIRE=1 and
no extra list was given.
"""
import base64
import os
import re
import sys
import tarfile

BUILTIN = [
    (rb'(?<![0-9.])(10\.(?:[0-9]{1,3}\.){2}[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(?:1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})(?![0-9.])', 'private IPv4 address'),
    (rb'BEGIN [A-Z ]*PRIVATE KEY', 'private key'),
    (rb'ssh-(?:ed25519|rsa|dss) AAAA', 'SSH public key'),
    (rb'(?:rmm_[0-9a-f]{16}|ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|sk-ant-[A-Za-z0-9-]{10})', 'API token'),
]


def extra_strings():
    words = []
    path = os.environ.get('PRIVACY_DENYLIST_FILE')
    if path and os.path.exists(path):
        words += open(path, 'rb').read().splitlines()
    if os.environ.get('PRIVACY_DENYLIST_B64'):
        words += base64.b64decode(os.environ['PRIVACY_DENYLIST_B64']).splitlines()
    return [w.strip().lower() for w in words if len(w.strip()) >= 3 and not w.startswith(b'#')]


def files(path):
    if os.path.isdir(path):
        for d, _, names in os.walk(path):
            for n in names:
                p = os.path.join(d, n)
                if os.path.isfile(p) and not os.path.islink(p):
                    yield p, open(p, 'rb').read()
    elif path.endswith(('.tar.gz', '.tgz')):
        with tarfile.open(path, 'r:gz') as tar:
            for m in tar:
                if m.isfile():
                    yield '%s!%s' % (path, m.name), tar.extractfile(m).read()
    else:
        yield path, open(path, 'rb').read()


def main():
    extra = extra_strings()
    if os.environ.get('PRIVACY_REQUIRE') == '1' and not extra:
        print('no private deny-list given (PRIVACY_DENYLIST_FILE / PRIVACY_DENYLIST_B64)')
        sys.exit(2)
    hits = 0
    for path in sys.argv[1:]:
        for name, data in files(path):
            low = data.lower()
            for rx, what in BUILTIN:
                if re.search(rx, data):
                    print('%s: %s' % (name, what))
                    hits += 1
            for i, w in enumerate(extra):
                if w in low:
                    print('%s: deny-list entry %d' % (name, i + 1))
                    hits += 1
    print('privacy scan: %d hits (%d deny-list entries)' % (hits, len(extra)))
    sys.exit(1 if hits else 0)


if __name__ == '__main__':
    main()
