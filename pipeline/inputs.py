#!/usr/bin/env python3
"""The inputs a bundle for an upstream tag is built from, read with git ls-remote only.

rebase.py records them (rebase.env INPUTS=..., then the release notes "inputs:" line);
detect.py compares them with the live ones: an incomplete bundle is rebuilt only when one
changed (a fork branch, an override or resolution branch, a carried series tag, the pipeline
commit), so an unresolved conflict does not fail a run every 6 hours.
usage: inputs.py TAG     prints the inputs line
"""
import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from repin import read_env  # noqa: E402


class GitError(Exception):
    pass


def ls_remote(url, *patterns):
    r = subprocess.run(['git', 'ls-remote', url, *patterns], capture_output=True, text=True)
    if r.returncode not in (0, 2):
        raise GitError('git ls-remote %s: %s' % (url, r.stderr.strip()))
    return dict(reversed(line.split('\t')) for line in r.stdout.splitlines() if '\t' in line)


def compute(tag, cfg=None):
    cfg = cfg or read_env(os.environ.get('PIPELINE_CONFIG', os.path.join(HERE, 'config.env')))
    over = 'refs/heads/knulli-%s-fixes' % tag
    k = ls_remote(cfg['KNULLI_FORK'], 'refs/heads/' + cfg['KNULLI_SERIES_REF'], over)
    e = ls_remote(cfg['ES_FORK'], 'refs/heads/' + cfg['ES_SERIES_REF'], over)
    b = ls_remote(cfg['BUNDLES_GIT'], 'refs/heads/claude/resolution-%s' % tag, 'refs/tags/series/*')
    series = sorted('%s %s' % (r, s) for r, s in b.items() if r.startswith('refs/tags/series/')
                    and r != 'refs/tags/series/%s' % tag and not r.endswith('^{}'))
    return dict(
        knulli_series=k.get('refs/heads/' + cfg['KNULLI_SERIES_REF'], ''),
        knulli_override=k.get(over, ''),
        es_series=e.get('refs/heads/' + cfg['ES_SERIES_REF'], ''),
        es_override=e.get(over, ''),
        resolution=b.get('refs/heads/claude/resolution-%s' % tag, ''),
        series_tags=hashlib.sha256('\n'.join(series).encode()).hexdigest()[:16],
        pipeline=os.environ.get('GITHUB_SHA', 'local')[:12],
    )


def line(inputs):
    return ' '.join('%s=%s' % (k, v or '-') for k, v in sorted(inputs.items()))


def parse(text):
    return {k: ('' if v == '-' else v) for k, v in (p.split('=', 1) for p in text.split() if '=' in p)}


if __name__ == '__main__':
    print(line(compute(sys.argv[1])))
