#!/bin/sh
# Check a manifest signature against trusted Ed25519 public keys (same test as the console).
#   verify.sh MANIFEST SIG PUBKEY_DIR   exit 0 and the key name when one key verifies it
set -u
MANIFEST=$1 SIG=$2 PUBS=$3
OPENSSL=${OPENSSL:-openssl}
for pub in "$PUBS"/*.pub; do
	[ -f "$pub" ] || continue
	if "$OPENSSL" pkeyutl -verify -pubin -inkey "$pub" -rawin -in "$MANIFEST" -sigfile "$SIG" > /dev/null 2>&1; then
		echo "signature ok: $(basename "$pub")"
		exit 0
	fi
done
echo "signature does not verify with any key in $PUBS"
exit 1
