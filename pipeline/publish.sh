#!/bin/bash
# Publish a signed bundle as the release bundle-<firmware slug> of this repository (CI only;
# needs GH_TOKEN with contents: write). The console downloads
#   https://github.com/<repo>/releases/download/bundle-<slug>/manifest.json (+ .sig)
# and then the bundle-<serial>.tar.gz the manifest names.
#   publish.sh DIST_DIR PUBKEY_DIR
# Order matters for a console that downloads while this runs: the new tarball goes up first,
# then the signature and the manifest; older tarballs are deleted last. A console that reads
# a new manifest with an old signature (or the reverse) rejects it and retries later.
# A complete bundle also publishes its resolved series as tag series/<upstream tag>: an orphan
# commit holding only patch files and meta.env (no upstream history, no .github). The next
# release replays that series (rebase.py), and the conflict routine stops early on it.
set -euo pipefail
DIST=$1 PUBS=$2
HERE=$(cd "$(dirname "$0")" && pwd)
: "${GITHUB_REPOSITORY:?}" "${GH_TOKEN:?}"
"$HERE/verify.sh" "$DIST/manifest.json" "$DIST/manifest.json.sig" "$PUBS"
read -r SLUG SERIAL TARBALL TAR_SHA COMPLETE < <(python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m["firmware"]["slug"], m["serial"], m["tarball"]["name"], m["tarball"]["sha256"],
      "yes" if m["complete"] else "no")' "$DIST/manifest.json")
[ "$( (sha256sum "$DIST/$TARBALL" || shasum -a 256 "$DIST/$TARBALL") | cut -d ' ' -f 1)" = "$TAR_SHA" ]
TAG=bundle-$SLUG
TITLE="Console fixes for $(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print("Knulli %s (%s)" % (m["firmware"]["tag"], m["firmware"]["version"]))' "$DIST/manifest.json")"

if gh release view "$TAG" -R "$GITHUB_REPOSITORY" > /dev/null 2>&1; then
	old=$(gh release view "$TAG" -R "$GITHUB_REPOSITORY" --json assets -q '.assets[].name' | grep -E '^(bundle|series)-[0-9]+\.tar\.gz$' | grep -v -E "^(bundle|series)-$SERIAL\.tar\.gz$" || true)
	gh release upload "$TAG" -R "$GITHUB_REPOSITORY" --clobber "$DIST/$TARBALL" "$DIST/series-$SERIAL.tar.gz"
	gh release upload "$TAG" -R "$GITHUB_REPOSITORY" --clobber "$DIST/manifest.json.sig" "$DIST/manifest.json"
	gh release edit "$TAG" -R "$GITHUB_REPOSITORY" --title "$TITLE" --notes-file "$DIST/report.md"
	for a in $old; do gh release delete-asset "$TAG" "$a" -R "$GITHUB_REPOSITORY" --yes; done
else
	gh release create "$TAG" -R "$GITHUB_REPOSITORY" --target "${GITHUB_SHA:?}" --title "$TITLE" \
		--notes-file "$DIST/report.md" \
		"$DIST/$TARBALL" "$DIST/series-$SERIAL.tar.gz" "$DIST/manifest.json.sig" "$DIST/manifest.json"
fi
echo "published $TAG: $TARBALL"

if [ "$COMPLETE" = yes ]; then
	bash "$HERE/series_tag.sh" "$DIST" "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi
