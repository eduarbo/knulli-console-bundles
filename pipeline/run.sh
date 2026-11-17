#!/bin/bash
# Build the console bundle for one Knulli release, end to end (CI build job, or locally).
#   run.sh --tag TAG --image IMG.gz --image-sha256 SHA --units DIR --work DIR --dist DIR
#          [--sign-key PEM --pubkeys DIR] [--serial N]
# Steps: verify the image, extract the sysroot and stock files, carry the fix series onto TAG
# (rebase.py: override, carried series, routine resolution; gate.py on every result), build
# ES and ConnMan, run 07's API/UI tests headless, re-pin the units, run their tests,
# assemble, check (template + pin map, privacy) and, with a key, sign the bundle.
# Exit 0: bundle complete; 3: bundle made, some units excluded (report.md); 2: conflict with
# ON_CONFLICT=stop (no bundle); INFRA_EXIT (90): infrastructure failure (apt, network,
# docker), nothing published; other: error.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.env disable=SC1090
. "${PIPELINE_CONFIG:-$HERE/config.env}"
SIGN_KEY="" PUBKEYS="" SERIAL=""
while [ $# -gt 0 ]; do
	case "$1" in
		--tag) TAG=$2 ;; --image) IMG=$2 ;; --image-sha256) IMG_SHA=$2 ;; --units) UNITS_DIR=$2 ;;
		--work) WORK=$2 ;; --dist) DIST=$2 ;; --sign-key) SIGN_KEY=$2 ;; --pubkeys) PUBKEYS=$2 ;;
		--serial) SERIAL=$2 ;;
		*) echo "unknown option $1"; exit 1 ;;
	esac
	shift 2
done
: "${TAG:?} ${IMG:?} ${IMG_SHA:?} ${UNITS_DIR:?} ${WORK:?} ${DIST:?}"
mkdir -p "$WORK" "$DIST"
WORK=$(cd "$WORK" && pwd) DIST=$(cd "$DIST" && pwd) UNITS_DIR=$(cd "$UNITS_DIR" && pwd)
sum() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d ' ' -f 1; }
step() { echo; echo "=== $(date -u +%H:%M:%S) $*"; }
infra_check() { # status file: an infrastructure failure stops the run
	if [ "$(cat "$1" 2>/dev/null)" = "$INFRA_EXIT" ]; then
		echo "infrastructure failure in $(basename "$1" .status): nothing published"
		exit "$INFRA_EXIT"
	fi
}

step "image $IMG"
[ "$(sum "$IMG")" = "$IMG_SHA" ] || { echo "image sha256 is not $IMG_SHA"; exit 1; }

step "extract sysroot and stock files"
bash "$HERE/extract.sh" "$IMG" "$WORK"

step "carry the fix series onto $TAG"
set +e
python3 -I "$HERE/rebase.py" "$TAG" "$WORK/rebase"
rc=$?
set -e
[ "$rc" = "$INFRA_EXIT" ] && exit "$INFRA_EXIT"
if [ "$rc" != 0 ]; then
	{
		echo "Console fixes for Knulli $TAG: NOT BUILT (ON_CONFLICT=$ON_CONFLICT, rebase exit $rc)."
		echo
		for f in "$WORK"/rebase/conflict-*.txt; do [ -f "$f" ] && { echo '```'; cat "$f"; echo '```'; }; done
	} > "$DIST/report.md"
	cat "$DIST/report.md"
	exit 2
fi
. "$WORK/rebase/rebase.env"

set +e
mkdir -p "$WORK/es-build" "$WORK/connman-build" "$WORK/es-functional"
rm -f "$WORK/es-functional/es-functional.status"
if [ "$ES_STATUS" = ok ]; then
	step "build EmulationStation (series tree $ES_TREE onto $ES_ONTO)"
	SOURCE_DATE_EPOCH=$TAG_TIME bash "$HERE/build_es.sh" "$WORK/sysroot" "$WORK/rebase/es" "$WORK/es-build"
	echo $? > "$WORK/es-build/es.status"
	infra_check "$WORK/es-build/es.status"
	step "unit 07 API and UI tests, headless"
	if [ -d "$UNITS_DIR/07-es-api-events/tests" ]; then
		bash "$HERE/test_es_functional.sh" "$WORK/rebase/es" "$UNITS_DIR/07-es-api-events/tests" "$WORK/es-functional"
		infra_check "$WORK/es-functional/es-functional.status"
	else
		echo "no 07-es-api-events/tests in the units folder" | tee "$WORK/es-functional/es-functional.log"
		echo 1 > "$WORK/es-functional/es-functional.status"
	fi
else
	echo "series conflict" > "$WORK/es-build/es.status"
fi
if [ "${KNULLI_LINUX_10_STATUS:-}" = ok ]; then
	step "build ConnMan"
	bash "$HERE/build_connman.sh" "$WORK/sysroot" "$WORK/rebase/knulli-linux" "bundle-$TAG-knulli-linux-10" \
		"$BUILDROOT_COMMIT" "$WORK/connman-build"
	echo $? > "$WORK/connman-build/connman.status"
	infra_check "$WORK/connman-build/connman.status"
else
	echo "series conflict" > "$WORK/connman-build/connman.status"
fi
set -e

step "re-pin the units"
python3 -I "$HERE/repin.py" --units "$UNITS_DIR" --work "$WORK" --out "$WORK/units"

step "unit tests on the re-pinned copies"
UNIT_TEST_TMP=$WORK python3 -I "$HERE/test_units.py" --units "$WORK/units" --work "$WORK"

step "bundle"
rm -rf "$DIST" && mkdir -p "$DIST"
python3 -I "$HERE/bundle.py" --work "$WORK" --units "$WORK/units" --dist "$DIST" \
	--image "$(basename "$IMG")" --image-sha256 "$IMG_SHA" ${SERIAL:+--serial "$SERIAL"}

step "check: every file is its template + kill switch + pin map, or declared derived"
python3 -I "$HERE/check_bundle.py" --dist "$DIST" --units "$UNITS_DIR"
step "privacy scan"
python3 -I "$HERE/privacy_scan.py" "$DIST"
if [ -n "$SIGN_KEY" ]; then
	bash "$HERE/sign.sh" "$DIST/manifest.json" "$SIGN_KEY" "$PUBKEYS"
fi
cat "$DIST/report.md"
if python3 -I -c 'import json,sys; sys.exit(not json.load(open(sys.argv[1]))["complete"])' "$DIST/manifest.json"; then
	exit 0
fi
exit 3
