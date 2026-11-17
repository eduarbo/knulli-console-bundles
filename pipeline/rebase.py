#!/usr/bin/env python3
"""Carry the owner's fix series onto a new Knulli release, without a work tree.

usage: rebase.py TAG WORK_DIR        (config: pipeline/config.env or $PIPELINE_CONFIG)

Per group of KNULLI_GROUPS (the fork commits a bundle unit derives from, by path) and for
the ES series (onto the ES commit TAG pins), the first source that exists wins:
  override    branch knulli-<TAG>-fixes of the fork (the owner's resolution), as is;
  unchanged   TAG is the series base: the fork branch as is;
  replay      the series replayed with git merge-tree: the series of the newest tag
              series/<T> of BUNDLES_GIT (the resolved series of the last complete bundle, T
              an ancestor of TAG), else the fork's SERIES_BASE..SERIES_REF;
  resolution  when the replay conflicts: the patch files of branch claude/resolution-<TAG>
              of BUNDLES_GIT (resolutions/<TAG>/<group>/*.patch), applied onto TAG. The
              branch is data: only files under resolutions/<TAG>/ are read, nothing in it is
              run, and groups in NO_RESOLUTION_GROUPS (ConnMan) are never taken from it.
Every result then goes through gate.py (paths, upstream kept, new lines). A conflict or a
gate rejection makes the group "conflict" / "gate": ON_CONFLICT=stop exits 2, isolate goes
on (repin.py leaves that group's units out). The rest of the fork series is replayed for
the report only (group "other"). Network or git transport failures exit INFRA_EXIT.
Writes WORK_DIR/rebase.env, gate-<group>.json, conflict-<group>.txt, series/<group>/*.patch
and checks the ES result out in WORK_DIR/es (with submodules) for the build.
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gate  # noqa: E402
import inputs  # noqa: E402
from repin import read_env  # noqa: E402

CFG = read_env(os.environ.get('PIPELINE_CONFIG', os.path.join(HERE, 'config.env')))
INFRA = int(CFG.get('INFRA_EXIT', '90'))
TAG = sys.argv[1]
WORK = os.path.abspath(sys.argv[2])
ENV = []
COMMITTER = dict(GIT_COMMITTER_NAME='Knulli bundle pipeline', GIT_COMMITTER_EMAIL='noreply@users.noreply.github.com')


class Conflict(Exception):
    pass


def infra(msg):
    print('infrastructure failure: ' + msg, file=sys.stderr)
    sys.exit(INFRA)


def run(cmd, cwd=None, env=None, check=True, data=None, network=False):
    e = dict(os.environ, **(env or {}))
    r = subprocess.run(cmd, cwd=cwd, env=e, input=data, capture_output=True)
    if check and r.returncode != 0:
        msg = '%s: %s' % (' '.join(cmd), r.stderr.decode(errors='replace').strip()[-600:])
        if network:
            infra(msg)
        raise RuntimeError(msg)
    return r


def git(repo, *args, check=True, env=None, data=None, network=False):
    return run(['git', '-c', 'advice.detachedHead=false', '-c', 'protocol.version=2', '-C', repo, *args],
               check=check, env=env, data=data, network=network)


def out(repo, *args, **kw):
    return git(repo, *args, **kw).stdout.decode(errors='surrogateescape').strip()


def emit(key, value):
    ENV.append('%s=%s' % (key, shlex.quote(str(value))))


def ls_remote(url, *patterns):
    r = run(['git', 'ls-remote', url, *patterns], check=False)
    if r.returncode not in (0, 2):
        infra('git ls-remote %s: %s' % (url, r.stderr.decode(errors='replace').strip()))
    refs = {}
    for line in r.stdout.decode().splitlines():
        sha, ref = line.split('\t')
        refs[ref] = sha
    return refs


def clone(path, fork, ref, upstream):
    """Treeless clone of the series branch; upstream is a second promisor (trees of new
    upstream commits come from it on demand); bundles is a plain remote (data, complete)."""
    if not os.path.isdir(os.path.join(path, '.git')):
        run(['git', 'clone', '-q', '--filter=tree:0', '--no-checkout', '--single-branch', '-b', ref, fork, path],
            network=True)
    if git(path, 'remote', 'get-url', 'upstream', check=False).returncode:
        git(path, 'remote', 'add', 'upstream', upstream)
    git(path, 'config', 'remote.upstream.promisor', 'true')
    git(path, 'config', 'remote.upstream.partialclonefilter', 'tree:0')
    if git(path, 'remote', 'get-url', 'bundles', check=False).returncode:
        git(path, 'remote', 'add', 'bundles', CFG['BUNDLES_GIT'])
    git(path, 'fetch', '-q', 'origin', '+refs/heads/%s:refs/remotes/origin/%s' % (ref, ref), network=True)


def rev(repo, r):
    return out(repo, 'rev-parse', r + '^{commit}')


def commit_info(repo, c):
    fmt = out(repo, 'log', '-1', '--format=%an%x00%ae%x00%aD%x00%B', c)
    an, ae, ad, msg = fmt.split('\0', 3)
    return dict(GIT_AUTHOR_NAME=an, GIT_AUTHOR_EMAIL=ae, GIT_AUTHOR_DATE=ad), msg


def replay(repo, name, onto, base, commits):
    """Replay commits onto onto: (head, applied, dropped); Conflict with a report."""
    head, applied, dropped = rev(repo, onto), [], []
    for c in commits:
        subject = out(repo, 'log', '-1', '--format=%s', c)
        if git(repo, 'rev-parse', '-q', '--verify', c + '^2', check=False).returncode == 0:
            raise Conflict('merge commit in the series: %s %s' % (c, subject))
        r = git(repo, 'merge-tree', '--write-tree', '--merge-base=%s^' % c, head, c, check=False)
        text = r.stdout.decode(errors='replace')
        if r.returncode != 0:
            paths = sorted({l.split('\t', 1)[1] for l in text.split('\n')
                            if re.match(r'^[0-7]+ [0-9a-f]+ [123]\t', l)})
            report = ['group:   %s' % name, 'onto:    %s (%s)' % (onto, rev(repo, onto)),
                      'commit:  %s %s' % (c, subject), 'applied before it in this group: %d' % len(applied), '',
                      'git merge-tree output (conflicted paths and messages):'] + text.split('\n')[1:] + [
                      '', 'upstream commits touching those paths since %s:' % base]
            for p in paths:
                log = out(repo, 'log', '--format=  %h %ad %s  [' + p + ']', '--date=short',
                          '%s..%s' % (base, onto), '--', p, check=False)
                report += log.split('\n')[:5] if log else []
            report += ['', 'Resolution: the daily routine (claude/resolution-%s) or the owner (branch '
                       'knulli-%s-fixes in the fork); the next run takes it.' % (TAG, TAG)]
            raise Conflict('\n'.join(report))
        tree = text.split('\n')[0]
        if tree == out(repo, 'rev-parse', head + '^{tree}'):
            dropped.append('%s %s' % (c, subject))
            continue
        env, msg = commit_info(repo, c)
        env.update(COMMITTER)
        head = out(repo, 'commit-tree', tree, '-p', head, env=env, data=msg.encode())
        applied.append('%s %s' % (c, subject))
    return head, applied, dropped


def apply_patches(repo, onto, patches):
    """Apply patch files in order onto onto, one commit each, without a work tree."""
    head = rev(repo, onto)
    with tempfile.TemporaryDirectory() as tmp:
        idx = dict(GIT_INDEX_FILE=os.path.join(tmp, 'index'))
        for name, data in patches:
            p = os.path.join(tmp, 'p')
            with open(p, 'wb') as f:
                f.write(data)
            git(repo, 'read-tree', head, env=idx)
            r = git(repo, 'apply', '--cached', '--whitespace=nowarn', p, env=idx, check=False)
            if r.returncode != 0:
                raise Conflict('patch %s does not apply onto %s: %s' % (name, onto,
                                                                      r.stderr.decode(errors='replace').strip()))
            tree = out(repo, 'write-tree', env=idx)
            info = run(['git', 'mailinfo', os.path.join(tmp, 'msg'), os.path.join(tmp, 'diff')], data=data).stdout.decode()
            meta = dict(l.split(': ', 1) for l in info.splitlines() if ': ' in l)
            body = open(os.path.join(tmp, 'msg')).read()
            env = dict(COMMITTER, GIT_AUTHOR_NAME=meta.get('Author', 'unknown'),
                       GIT_AUTHOR_EMAIL=meta.get('Email', 'unknown@invalid'),
                       GIT_AUTHOR_DATE=meta.get('Date', CFG.get('SOURCE_DATE', '1970-01-01T00:00:00Z')))
            msg = (meta.get('Subject', name) + '\n\n' + body).strip() + '\n'
            head = out(repo, 'commit-tree', tree, '-p', head, env=env, data=msg.encode())
    return head


def tree_patches(repo, ref, folder):
    files = out(repo, 'ls-tree', '--name-only', '%s:%s' % (ref, folder), check=False)
    names = sorted(n for n in files.split('\n') if n.endswith('.patch'))
    return [(n, git(repo, 'show', '%s:%s/%s' % (ref, folder, n)).stdout) for n in names]


def find_carry(repo, tag_commit):
    """Newest series/<T> tag of the bundles repo whose T is an ancestor of the new tag."""
    best = None
    for ref, sha in ls_remote(CFG['BUNDLES_GIT'], 'refs/tags/series/*').items():
        t = ref[len('refs/tags/series/'):]
        if t == TAG or ref.endswith('^{}'):
            continue
        git(repo, 'fetch', '-q', '--no-tags', 'bundles', '+%s:refs/carry/%s' % (ref, t), network=True)
        meta = dict(l.split('=', 1) for l in out(repo, 'show', 'refs/carry/%s:meta.env' % t).split('\n') if '=' in l)
        tc = meta.get('TAG_COMMIT', '')
        if git(repo, 'cat-file', '-e', tc + '^{commit}', check=False).returncode:
            git(repo, 'fetch', '-q', '--no-tags', 'upstream', tc, check=False)
        if git(repo, 'merge-base', '--is-ancestor', tc, tag_commit, check=False).returncode == 0:
            when = int(out(repo, 'log', '-1', '--format=%ct', tc))
            if best is None or when > best[0]:
                best = (when, t, tc, meta, sha)
    return best


def find_resolution(repos):
    if os.environ.get('IGNORE_RESOLUTION') == '1':   # the conflict routine: plain replay only
        return None
    refs = ls_remote(CFG['BUNDLES_GIT'], 'refs/heads/claude/resolution-%s' % TAG)
    ref = 'refs/heads/claude/resolution-%s' % TAG
    if ref not in refs:
        return None
    for repo in repos:
        git(repo, 'fetch', '-q', '--no-tags', 'bundles', '+%s:refs/resolution/%s' % (ref, TAG), network=True)
    names = out(repos[0], 'ls-tree', '-r', '--name-only', 'refs/resolution/%s' % TAG).split('\n')
    bad = [n for n in names if n and not n.startswith('resolutions/%s/' % TAG)]
    if bad:
        print('resolution branch ignored: files outside resolutions/%s/: %s' % (TAG, ', '.join(bad[:5])))
        return None
    return refs[ref]


def group(repo, name, fork, onto, original, carried, paths, resolution, report_only=False):
    """Carry one group; returns (status, head). original/carried: (base, head, commits)."""
    key = name.upper().replace('-', '_')
    override = 'knulli-%s-fixes' % TAG
    o_base, o_head, o_commits = original
    s_base, s_head, s_commits = carried or original
    source, applied, dropped, head, conflict = None, [], [], None, None
    refs = ls_remote(fork, 'refs/heads/' + override)
    if refs:
        emit('INPUT_OVERRIDE_' + key, refs['refs/heads/' + override])
        git(repo, 'fetch', '-q', 'origin', '+refs/heads/%s:refs/remotes/origin/%s' % (override, override), network=True)
        head, source = rev(repo, 'origin/' + override), 'override'
        if git(repo, 'merge-base', '--is-ancestor', onto, head, check=False).returncode:
            conflict, head = '%s does not contain %s' % (override, onto), None
        applied = out(repo, 'log', '--reverse', '--format=%H %s', '%s..%s' % (onto, head)).split('\n') if head else []
    elif rev(repo, onto) == rev(repo, s_base):
        head, source = s_head, 'unchanged'
        applied = ['%s %s' % (c, out(repo, 'log', '-1', '--format=%s', c)) for c in s_commits]
    else:
        source = 'carry' if carried else 'replay'
        try:
            head, applied, dropped = replay(repo, name, onto, s_base, s_commits)
        except Conflict as e:
            conflict = str(e)
            gname = name.replace('knulli-linux-', '')
            if resolution and not report_only and gname not in CFG.get('NO_RESOLUTION_GROUPS', '').split():
                patches = tree_patches(repo, 'refs/resolution/%s' % TAG, 'resolutions/%s/%s' % (TAG, name))
                if patches:
                    try:
                        head, source = apply_patches(repo, onto, patches), 'resolution'
                        applied = ['%s (resolution)' % n for n, _ in patches]
                        conflict = None
                    except Conflict as e2:
                        conflict += '\n\nresolution patches: %s' % e2
    status = 'conflict' if conflict else 'ok'
    if conflict:
        with open(os.path.join(WORK, 'conflict-%s.txt' % name), 'w') as f:
            f.write(conflict + '\n')
    gres = None
    if head and not report_only:
        reviews, patches = [], None
        if source == 'resolution':
            folder = 'resolutions/%s/%s' % (TAG, name)
            patches = tree_patches(repo, 'refs/resolution/%s' % TAG, folder)
            raw = git(repo, 'show', 'refs/resolution/%s:%s/REVIEW.json' % (TAG, folder), check=False)
            try:
                reviews = json.loads(raw.stdout) if raw.returncode == 0 else []
            except ValueError:
                reviews = []
        original_paths = gate.changed_paths(repo, o_base, o_head)
        gres = gate.check(repo, s_base, onto, head, s_base, s_head, paths, original_paths, source,
                          reviews=reviews, patches=patches)
        with open(os.path.join(WORK, 'gate-%s.json' % name), 'w') as f:
            json.dump(gres, f, indent=1)
        if gres['status'] != 'pass':
            status = 'gate'
            with open(os.path.join(WORK, 'conflict-%s.txt' % name), 'w') as f:
                f.write('group:   %s\nsource:  %s\ngate rejected: %s\n\n%s\n' % (
                    name, source, '; '.join(gres['reasons']),
                    '\n'.join(gres['violations'][:20] + ['new: ' + l for l in gres['new_lines'][:20]])))
    for k, v in (('STATUS', status), ('SOURCE', source or ''), ('APPLIED', len(applied)), ('DROPPED', len(dropped))):
        emit('%s_%s' % (key, k), v)
    with open(os.path.join(WORK, name + '.applied'), 'w') as f:
        f.write(''.join(a + '\n' for a in applied if a))
    with open(os.path.join(WORK, name + '.dropped'), 'w') as f:
        f.write(''.join(d + '\n' for d in dropped))
    if status != 'ok':
        return status, None
    git(repo, 'update-ref', 'refs/heads/bundle-%s-%s' % (TAG, name), head)
    folder = os.path.join(WORK, 'series', name)
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    # The group's own commits as patch files, limited to its paths (the carried series)
    limit = ['--', *paths] if paths else []
    for i, c in enumerate(out(repo, 'rev-list', '--reverse', '%s..%s' % (onto, head), *limit).split(), 1):
        git(repo, 'format-patch', '-q', '--no-signature', '--zero-commit', '--start-number', str(i), '-o', folder,
            '-1', c, *limit)
    emit(key + '_HEAD', head)
    emit(key + '_TREE', out(repo, 'rev-parse', head + '^{tree}'))
    if gres:
        emit(key + '_NEW_LINES', len(gres['new_lines']))
    return status, head


def series_commits(repo, base, ref, paths=None, exclude=None):
    all_c = out(repo, 'rev-list', '--reverse', '--topo-order', '%s..%s' % (base, ref)).split()
    if paths is None and exclude is None:
        return all_c
    if exclude is not None:
        touched = set(out(repo, 'rev-list', '%s..%s' % (base, ref), '--', *exclude).split())
        return [c for c in all_c if c not in touched]
    touched = set(out(repo, 'rev-list', '%s..%s' % (base, ref), '--', *paths).split())
    return [c for c in all_c if c in touched]


def reconstruct(repo, base, patches):
    """Commits from carried patch files applied onto base: (base, head, commits)."""
    commits, head = [], rev(repo, base)
    for p in patches:
        head = apply_patches(repo, head, [p])
        commits.append(head)
    return rev(repo, base), head, commits


def main():
    os.makedirs(WORK, exist_ok=True)
    for f in os.listdir(WORK):
        if f.startswith(('conflict-', 'gate-')):
            os.remove(os.path.join(WORK, f))
    failed = []
    stop = CFG.get('ON_CONFLICT', 'stop') == 'stop'

    def needed(name, status):
        failed.append(name)
        if stop:
            print('%s in %s (ON_CONFLICT=stop):' % (status, name))
            print(open(os.path.join(WORK, 'conflict-%s.txt' % name)).read())
            write_env()
            sys.exit(2)

    # --- knulli-linux ---
    K = os.path.join(WORK, 'knulli-linux')
    clone(K, CFG['KNULLI_FORK'], CFG['KNULLI_SERIES_REF'], CFG['KNULLI_UPSTREAM'])
    up_ref = os.environ.get('UPSTREAM_REF') or 'refs/tags/' + TAG   # tests: a branch as a stand-in tag
    git(K, 'fetch', '-q', '--no-tags', 'upstream', '+%s:refs/tags/%s' % (up_ref, TAG), network=True)
    base = CFG['KNULLI_SERIES_BASE']
    if git(K, 'rev-parse', '-q', '--verify', base + '^{commit}', check=False).returncode:
        git(K, 'fetch', '-q', '--no-tags', 'upstream', '+refs/tags/%s:refs/tags/%s' % (base, base), network=True)
    tag_commit = rev(K, TAG)
    tag_time = out(K, 'log', '-1', '--format=%ct', tag_commit)
    COMMITTER['GIT_COMMITTER_DATE'] = '%s +0000' % tag_time
    emit('TAG', TAG)
    emit('TAG_COMMIT', tag_commit)
    emit('TAG_TIME', tag_time)
    emit('KNULLI_LINUX_ONTO', tag_commit)
    emit('KNULLI_GROUPS', CFG['KNULLI_GROUPS'])
    try:
        emit('INPUTS', inputs.line(inputs.compute(TAG, CFG)))
    except inputs.GitError as e:
        infra(str(e))
    emit('INPUT_KNULLI_SERIES', rev(K, 'origin/' + CFG['KNULLI_SERIES_REF']))
    carry = find_carry(K, tag_commit)
    emit('CARRY_TAG', carry[1] if carry else '')
    emit('INPUT_CARRY', carry[4] if carry else '')
    resolution_sha = None
    E = os.path.join(WORK, 'es')
    clone(E, CFG['ES_FORK'], CFG['ES_SERIES_REF'], CFG['ES_UPSTREAM'])
    resolution_sha = find_resolution([K, E])
    emit('INPUT_RESOLUTION', resolution_sha or '')
    ref = 'origin/' + CFG['KNULLI_SERIES_REF']
    all_paths = []
    for g in CFG['KNULLI_GROUPS'].split():
        gname, paths = g.split(':', 1)[0], g.split(':', 1)[1].split(',')
        all_paths += paths
        name = 'knulli-linux-' + gname
        original = (rev(K, base), rev(K, ref), series_commits(K, base, ref, paths))
        carried = None
        if carry:
            carried = reconstruct(K, carry[2], tree_patches(K, 'refs/carry/' + carry[1], name))
        status, _ = group(K, name, CFG['KNULLI_FORK'], TAG, original, carried, paths, resolution_sha)
        if status != 'ok':
            needed(name, status)
    original = (rev(K, base), rev(K, ref), series_commits(K, base, ref, exclude=all_paths))
    group(K, 'knulli-linux-other', CFG['KNULLI_FORK'], TAG, original, None, [], None, report_only=True)
    mk = out(K, 'show', '%s:%s' % (TAG, CFG['ES_PIN_FILE']))
    m = re.search(r'^%s *= *([0-9a-f]{40})\s*$' % re.escape(CFG['ES_PIN_VAR']), mk, re.M)
    if not m:
        print('no ES pin in %s:%s' % (TAG, CFG['ES_PIN_FILE']))
        sys.exit(1)
    es_pin = m.group(1)
    emit('ES_PIN', es_pin)
    emit('ES_ONTO', es_pin)
    br = out(K, 'ls-tree', TAG, 'buildroot').split()
    emit('BUILDROOT_COMMIT', br[2] if len(br) > 2 else '')

    # --- EmulationStation ---
    if git(E, 'cat-file', '-e', es_pin + '^{commit}', check=False).returncode:
        git(E, 'fetch', '-q', '--no-tags', 'upstream', es_pin, network=True)
    emit('INPUT_ES_SERIES', rev(E, 'origin/' + CFG['ES_SERIES_REF']))
    e_base, e_ref = CFG['ES_SERIES_BASE'], 'origin/' + CFG['ES_SERIES_REF']
    original = (rev(E, e_base), rev(E, e_ref), series_commits(E, e_base, e_ref))
    carried = None
    if carry:
        git(E, 'fetch', '-q', '--no-tags', 'bundles', '+refs/tags/series/%s:refs/carry/%s' % (carry[1], carry[1]),
            network=True)
        pin = carry[3].get('ES_PIN', '')
        if git(E, 'cat-file', '-e', pin + '^{commit}', check=False).returncode:
            git(E, 'fetch', '-q', '--no-tags', 'upstream', pin, network=True)
        carried = reconstruct(E, pin, tree_patches(E, 'refs/carry/' + carry[1], 'es'))
    status, head = group(E, 'es', CFG['ES_FORK'], es_pin, original, carried, [], resolution_sha)
    if status == 'ok':
        git(E, 'checkout', '-q', '--force', '--detach', head)
        r = git(E, 'submodule', 'update', '-q', '--init', '--recursive', '--depth', '1', check=False)
        if r.returncode:
            git(E, 'submodule', 'update', '-q', '--init', '--recursive', network=True)
    else:
        needed('es', status)
    write_env()
    print('\n'.join(ENV))
    if failed:
        print('isolated (ON_CONFLICT=isolate): ' + ' '.join(failed))


def write_env():
    with open(os.path.join(WORK, 'rebase.env'), 'w') as f:
        f.write('\n'.join(ENV) + '\n')


if __name__ == '__main__':
    main()
