#!/usr/bin/env python3
"""Decide which Knulli releases need a console bundle (read-only GitHub API and git calls).

usage: detect.py --ours OWNER/REPO [--force TAG] [--max N] [--include-prereleases]
Prints one JSON object: {"todo": [{tag, asset, url, sha256, size, why}], "errors": [...],
"warnings": [...]}; exit 1 when there are errors (the run must fail loudly), after printing.

A release of UPSTREAM_REPO is built when OUR repo has no bundle release for its image
(release notes: "upstream-tag:", "image-sha256:"), or its bundle is incomplete and one of its
inputs changed since (inputs.py: fork branches, override and resolution branches, carried
series tags, pipeline commit). An incomplete bundle whose inputs are unchanged is skipped,
so an unresolved conflict reports once, not every 6 hours. Errors: the newest stable release
has no single board image with a GitHub digest; Knulli's update endpoint offers a version
with no bundle and none being built. GITHUB_TOKEN, when set, goes to api.github.com only
(rate limit), never to another host.
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import inputs  # noqa: E402
from repin import read_env  # noqa: E402


def api(url):
    out = []
    while url:
        if urllib.parse.urlsplit(url).hostname != 'api.github.com' or not url.startswith('https://'):
            raise SystemExit('refusing to call %s' % url)
        headers = {'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28',
                   'User-Agent': 'knulli-bundle-pipeline'}
        if os.environ.get('GITHUB_TOKEN'):
            headers['Authorization'] = 'Bearer ' + os.environ['GITHUB_TOKEN']
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
            out += json.load(r)
            m = re.search(r'<([^>]+)>; rel="next"', r.headers.get('Link', ''))
            url = m.group(1) if m else None
    return out


def endpoint_version(cfg, utype):
    url = '%s/%s/%s/last/knulli.version' % (cfg['UPDATE_URL'].rstrip('/'), cfg['UPDATE_BOARD'], utype)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'knulli-bundle-pipeline'}),
                                    timeout=30) as r:
            text = r.read(256).decode(errors='replace').strip()
            return (text if text and len(text) < 50 else None), url
    except (urllib.error.URLError, OSError):
        return None, url


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ours', required=True)
    ap.add_argument('--force')
    ap.add_argument('--max', type=int, default=1)
    ap.add_argument('--include-prereleases', action='store_true')
    args = ap.parse_args()
    cfg = read_env(os.environ.get('PIPELINE_CONFIG', os.path.join(HERE, 'config.env')))
    errors, warnings = [], []
    built, firmwares = {}, set()
    for r in api('https://api.github.com/repos/%s/releases?per_page=100' % args.ours):
        body = r.get('body') or ''
        field = lambda k: (re.search(r'^\s*%s: (.*)$' % k, body, re.M) or [None, None])[1]
        if not r['tag_name'].startswith('bundle-') or r['draft'] or not field('upstream-tag'):
            continue
        if field('firmware'):
            firmwares.add(field('firmware').strip())
        key = (field('upstream-tag').strip(), (field('image-sha256') or '').strip())
        serial = int(field('serial') or 0)
        if key not in built or serial > built[key]['serial']:
            built[key] = dict(serial=serial, complete=(field('complete') or '').strip() == 'yes',
                              inputs=inputs.parse(field('inputs') or ''))
    upstream = [r for r in api('https://api.github.com/repos/%s/releases?per_page=100' % cfg['UPSTREAM_REPO'])
                if not r['draft']]
    stable = sorted((r for r in upstream if not r['prerelease']), key=lambda r: r['published_at'], reverse=True)
    todo = []
    for r in upstream:
        if r['prerelease'] and not args.include_prereleases:
            continue
        if args.force and r['tag_name'] != args.force:
            continue
        newest = stable and r is stable[0]
        if not re.fullmatch(r'[0-9A-Za-z._-]+', r['tag_name']):
            (errors if newest else warnings).append('%s: tag name refused' % r['tag_name'])
            continue
        assets = [a for a in r['assets'] if re.match(cfg['ASSET_REGEX'], a['name'])]
        if len(assets) != 1 or not (assets[0].get('digest') or '').startswith('sha256:'):
            msg = '%s: %d board images matching %s, or no GitHub digest' % (r['tag_name'], len(assets), cfg['ASSET_REGEX'])
            (errors if newest else warnings).append(msg)
            continue
        a = assets[0]
        digest = a['digest'].split(':', 1)[1]
        prev = built.get((r['tag_name'], digest))
        why = 'forced' if args.force else None
        if not why and prev is None:
            why = 'no bundle for this image'
        elif not why and not prev['complete']:
            try:
                live = inputs.compute(r['tag_name'], cfg)
            except inputs.GitError as e:
                errors.append(str(e))
                continue
            changed = sorted(k for k in live if live[k] != prev['inputs'].get(k, ''))
            if changed:
                why = 'incomplete bundle, inputs changed: %s' % ', '.join(changed)
            else:
                warnings.append('%s: incomplete bundle %d, inputs unchanged: not rebuilt' % (r['tag_name'], prev['serial']))
        if why:
            todo.append(dict(tag=r['tag_name'], asset=a['name'], url=a['browser_download_url'], sha256=digest,
                             size=a['size'], published=r['published_at'], why=why))
    todo.sort(key=lambda t: t['published'], reverse=True)
    for utype in cfg.get('UPDATE_TYPES', 'stable').split():
        v, url = endpoint_version(cfg, utype)
        if v is None:
            warnings.append('update endpoint %s gives no version' % url)
        elif v not in firmwares and not todo:
            errors.append('update endpoint %s offers %r: no bundle for it and nothing to build' % (url, v))
    print(json.dumps(dict(todo=todo[:args.max], errors=errors, warnings=warnings)))
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
