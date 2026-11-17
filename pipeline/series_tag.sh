#!/bin/bash
# Push the resolved series of a complete bundle as tag series/<upstream tag> of the bundles
# repository: an orphan commit with only the per-group patch files and meta.env (TAG,
# TAG_COMMIT, ES_PIN, SERIAL); no upstream history, no .github. Read back by rebase.py.
#   series_tag.sh DIST_DIR REMOTE_URL
set -euo pipefail
DIST=$1 REMOTE=$2
read -r SERIAL UPTAG COMPLETE < <(python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m["serial"], m["firmware"]["tag"], "yes" if m["complete"] else "no")' "$DIST/manifest.json")
[ "$COMPLETE" = yes ] || { echo "bundle $SERIAL is incomplete: no series tag"; exit 1; }
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
tar -xzf "$DIST/series-$SERIAL.tar.gz" -C "$S" series rebase.env
mkdir -p "$S/repo"
for g in "$S"/series/*; do
	case "${g##*/}" in knulli-linux-other) ;; *) cp -R "$g" "$S/repo/" ;; esac
done
( . "$S/rebase.env"; printf 'TAG=%s\nTAG_COMMIT=%s\nES_PIN=%s\nSERIAL=%s\n' "$TAG" "$TAG_COMMIT" "$ES_PIN" "$SERIAL" ) > "$S/repo/meta.env"
find "$S/repo" -type f ! -name '*.patch' ! -name meta.env | grep . && { echo "unexpected files in the series"; exit 1; }
export GIT_AUTHOR_NAME="Knulli bundle pipeline" GIT_AUTHOR_EMAIL="noreply@users.noreply.github.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
git -C "$S/repo" init -q -b series
git -C "$S/repo" add -A .
git -C "$S/repo" commit -q -m "Resolved fix series of Knulli $UPTAG (bundle $SERIAL)"
git -C "$S/repo" push -q --force "$REMOTE" "HEAD:refs/tags/series/$UPTAG"
echo "pushed series/$UPTAG ($(cd "$S/repo" && find . -name '*.patch' | wc -l | tr -d ' ') patches)"
