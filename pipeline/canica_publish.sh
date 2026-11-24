#!/bin/bash
# Publish a signed Canica kit as the release canica-<firmware slug> of this repository (CI
# only; needs GH_TOKEN with contents: write). The console downloads
#   https://github.com/<repo>/releases/download/canica-<slug>/manifest.json (+ .sig)
# and then the canica-<serial>.sh the manifest names.
#   canica_publish.sh DIST_DIR PUBKEY_DIR
# A kit whose serial is not above the published one is refused. The installer goes up first,
# then the signature and the manifest; older installers are deleted last. A console that
# reads a new manifest with an old signature (or the reverse) rejects it and retries later.
set -euo pipefail
DIST=$1 PUBS=$2
HERE=$(cd "$(dirname "$0")" && pwd)
: "${GITHUB_REPOSITORY:?}" "${GH_TOKEN:?}"
"$HERE/verify.sh" "$DIST/manifest.json" "$DIST/manifest.json.sig" "$PUBS"
read -r SLUG SERIAL PAYLOAD PAYLOAD_SHA LABEL < <(python3 -I -c '
import json, re, sys
m = json.load(open(sys.argv[1]))
slug = re.sub(r"[^a-z0-9]+", "-", m["firmware"].lower()).strip("-")
print(slug, m["serial"], m["payload"]["name"], m["payload"]["sha256"], m["label"].replace(" ", "_"))' "$DIST/manifest.json")
[ "$( (sha256sum "$DIST/$PAYLOAD" || shasum -a 256 "$DIST/$PAYLOAD") | cut -d ' ' -f 1)" = "$PAYLOAD_SHA" ]
TAG=canica-$SLUG
TITLE="Canica ${LABEL//_/ } for Knulli $(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["firmware"])' "$DIST/manifest.json")"
python3 -I - "$DIST/manifest.json" > "$DIST/notes.md" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print('Canica %s (`%s`) for the %s on Knulli `%s`. The console installs it by itself.' % (m['label'], m['version'], m['model'], m['firmware']))
print()
print('Machine lines (read by the pipeline, do not edit):')
print()
for key in ('serial', 'version'):
    print('    %s: %s' % (key, m[key]))
print('    installer-sha256: %s' % m['payload']['sha256'])
print('    source: %s' % m['source'])
PY

if gh release view "$TAG" -R "$GITHUB_REPOSITORY" > /dev/null 2>&1; then
	published=$(gh release view "$TAG" -R "$GITHUB_REPOSITORY" --json body -q .body | sed -n 's/^ *serial: \([0-9][0-9]*\)$/\1/p' | head -1)
	if [ -n "$published" ] && [ "$SERIAL" -le "$published" ]; then
		echo "serial $SERIAL is not above the published $published: nothing published"
		exit 1
	fi
	old=$(gh release view "$TAG" -R "$GITHUB_REPOSITORY" --json assets -q '.assets[].name' | grep -E '^canica-[0-9]+\.sh$' | grep -v -x "$PAYLOAD" || true)
	gh release upload "$TAG" -R "$GITHUB_REPOSITORY" --clobber "$DIST/$PAYLOAD"
	gh release upload "$TAG" -R "$GITHUB_REPOSITORY" --clobber "$DIST/manifest.json.sig" "$DIST/manifest.json"
	gh release edit "$TAG" -R "$GITHUB_REPOSITORY" --title "$TITLE" --notes-file "$DIST/notes.md"
	for a in $old; do gh release delete-asset "$TAG" "$a" -R "$GITHUB_REPOSITORY" --yes; done
else
	gh release create "$TAG" -R "$GITHUB_REPOSITORY" --target "${GITHUB_SHA:?}" --title "$TITLE" --latest=false \
		--notes-file "$DIST/notes.md" "$DIST/$PAYLOAD" "$DIST/manifest.json.sig" "$DIST/manifest.json"
fi
echo "published $TAG: $PAYLOAD"
