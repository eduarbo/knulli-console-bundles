#!/bin/bash
# Sign the bundle manifest with the Ed25519 bundle key and check it against the published
# public keys before anything is uploaded.
#   sign.sh MANIFEST KEY_FILE PUBKEY_DIR     -> MANIFEST.sig (raw 64-byte Ed25519 signature)
# KEY_FILE holds the PEM private key (CI writes the bundle-signing secret to a 0600 file in
# RUNNER_TEMP and deletes it after). PUBKEY_DIR/*.pub are the keys the console trusts.
set -euo pipefail
MANIFEST=$1 KEY=$2 PUBS=$3
OPENSSL=${OPENSSL:-openssl}
"$OPENSSL" version | grep -Eq '^OpenSSL [3-9]\.' || { echo "sign.sh needs OpenSSL 3 or later (Ed25519 -rawin)"; exit 1; }
"$OPENSSL" pkey -in "$KEY" -noout -text 2>/dev/null | grep -q 'ED25519 Private-Key' || { echo "not an Ed25519 private key"; exit 1; }
"$OPENSSL" pkeyutl -sign -rawin -inkey "$KEY" -in "$MANIFEST" -out "$MANIFEST.sig"
[ "$(wc -c < "$MANIFEST.sig" | tr -d ' ')" = 64 ] || { echo "unexpected signature size"; exit 1; }
"$(dirname "$0")/verify.sh" "$MANIFEST" "$MANIFEST.sig" "$PUBS"
