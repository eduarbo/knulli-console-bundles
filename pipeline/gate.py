#!/usr/bin/env python3
"""Gate for a carried fix series: what a replay, an owner override or a routine resolution
produced on a new tag must be the original fix on top of the new upstream, nothing else.

For one group, with
  B = the series base (20260511, or the tag of the carried series), T = the new tag,
  H = the result on T, S = the series (B..series head) restricted to the group's paths:
1. paths: every path H changes against T is one the original (whole) series changes; a
   replay, carried series or resolution may only change the group's own paths (an override
   or the unchanged fork branch carries every group: only the group's paths are checked);
2. upstream kept: in every touched file, H does not remove a line upstream added between B
   and T, nor add back a line upstream removed there, unless the series itself did so;
3. new lines: lines H adds against T that the series does not add are reported. A replay
   (git merge-tree without conflict) or a carried series may add none. A routine resolution
   may only add them with both in-routine reviews passing on exactly these patch files. An
   owner override (a branch in the owner's fork) may add them; they are reported.
Line comparison is by exact content (blank lines ignored), counted as multisets, so a
repeated line ("fi", "done") is only excused as many times as the series accounts for it. An
upstream line that the result replaces by a line holding all of its words (both changes
merged on one line) counts as kept; that line is new, so it needs the reviews.
"""
import collections
import hashlib
import json
import subprocess


def git(repo, *args, check=True):
    r = subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True,
                       errors='surrogateescape')
    if check and r.returncode != 0:
        raise RuntimeError('git %s: %s' % (' '.join(args), r.stderr.strip()))
    return r.stdout


def changed_paths(repo, a, b, paths=()):
    out = git(repo, 'diff', '--no-renames', '--name-only', a, b, '--', *paths)
    return set(out.split('\n')) - {''}


def line_changes(repo, a, b, path):
    """(added, removed) line multisets of path from a to b."""
    out = git(repo, 'diff', '--no-renames', '--no-color', '-U0', a, b, '--', path)
    added, removed = collections.Counter(), collections.Counter()
    for line in out.split('\n'):
        if line.startswith(('+++', '---')):
            continue
        if line.startswith('+') and line[1:].strip():
            added[line[1:]] += 1
        elif line.startswith('-') and line[1:].strip():
            removed[line[1:]] += 1
    return added, removed


def patches_digest(patches):
    """sha256 over the patch files in order (name and content), as the reviews record it."""
    h = hashlib.sha256()
    for name, data in patches:
        h.update(name.encode() + b'\0' + hashlib.sha256(data).hexdigest().encode() + b'\n')
    return h.hexdigest()


def check(repo, base, tag, head, series_base, series_head, group_paths, original_paths,
          source, reviews=None, patches=None):
    """Gate result dict: status pass|reject, reasons, new_lines, details."""
    res = dict(source=source, status='pass', reasons=[], new_lines=[], violations=[])
    in_group = (lambda p: not group_paths or
                any(p == g or p.startswith(g.rstrip('/') + '/') for g in group_paths))
    touched_all = changed_paths(repo, tag, head)
    outside = sorted(p for p in touched_all if p not in original_paths)
    if outside:
        res['reasons'].append('changes paths the original series does not: %s' % ', '.join(outside))
    if source in ('replay', 'carry', 'resolution'):
        foreign = sorted(p for p in touched_all if not in_group(p))
        if foreign:
            res['reasons'].append('changes paths outside the group: %s' % ', '.join(foreign))
    touched = {p for p in touched_all if in_group(p)}
    for path in sorted(touched):
        up_add, up_del = line_changes(repo, base, tag, path)
        r_add, r_del = line_changes(repo, tag, head, path)
        s_add, s_del = line_changes(repo, series_base, series_head, path)
        dropped = (r_del & up_add) - s_del
        # An upstream line merged with the fix on the same line is kept: some line the
        # result adds holds all of its words (that new line still counts as new below)
        for line in list(dropped):
            words = collections.Counter(line.split())
            if any(not (words - collections.Counter(a.split())) for a in r_add):
                del dropped[line]
        readded = (r_add & up_del) - s_add
        for line in sorted(dropped.elements()):
            res['violations'].append('%s: removes upstream line %r' % (path, line))
        for line in sorted(readded.elements()):
            res['violations'].append('%s: re-adds line upstream removed %r' % (path, line))
        for line in sorted((r_add - s_add).elements()):
            res['new_lines'].append('%s: %s' % (path, line))
    if res['violations']:
        res['reasons'].append('drops upstream changes (%d lines)' % len(res['violations']))
    if res['new_lines']:
        if source == 'override':
            res['note'] = 'owner override adds %d lines the series does not' % len(res['new_lines'])
        elif source == 'resolution':
            digest = patches_digest(patches or [])
            res['patches_sha256'] = digest
            passed = {r.get('lens') for r in (reviews or [])
                      if r.get('verdict') == 'pass' and r.get('patches_sha256') == digest}
            if not {'constructive', 'adversarial'} <= passed:
                res['reasons'].append('resolution adds %d new lines without both reviews passing on these '
                                      'exact patches' % len(res['new_lines']))
            else:
                res['note'] = 'new lines reviewed (constructive and adversarial pass)'
        else:
            res['reasons'].append('%s adds %d lines the series does not' % (source, len(res['new_lines'])))
    if res['reasons']:
        res['status'] = 'reject'
    return res


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser()
    for a in ('repo', 'base', 'tag', 'head', 'series-base', 'series-head', 'source'):
        ap.add_argument('--' + a, required=True)
    ap.add_argument('--paths', required=True)
    a = ap.parse_args()
    paths = [p for p in a.paths.split(',') if p]
    print(json.dumps(check(a.repo, a.base, a.tag, a.head, a.series_base, a.series_head, paths,
                           changed_paths(a.repo, a.series_base, a.series_head, paths), a.source), indent=1))
