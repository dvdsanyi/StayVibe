#!/bin/zsh
# One-time maintainer setup: creates the Sparkle EdDSA key pair that signs updates.
#   - the private key goes only into the GitHub repository secret SPARKLE_PRIVATE_KEY, for CI
#   - the public key goes into Resources/Info.plist
# The key is made in a temporary folder that is deleted afterwards: nothing stays on this Mac.
set -euo pipefail
cd "${0:A:h}/.."
REPO=dvdsanyi/StayVibe

gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first."; exit 1; }
if [[ $(plutil -extract SUPublicEDKey raw Resources/Info.plist) != __* ]]; then
    echo "Resources/Info.plist already has a Sparkle key. A new one would stop existing installs from updating; aborting."
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT
openssl genpkey -algorithm ed25519 -out $TMP/key.pem
# Sparkle's key format: base64 of the raw 32-byte private seed / public key.
openssl pkey -in $TMP/key.pem -outform DER | tail -c 32 | base64 | gh secret set SPARKLE_PRIVATE_KEY --repo $REPO
plutil -replace SUPublicEDKey -string "$(openssl pkey -in $TMP/key.pem -pubout -outform DER | tail -c 32 | base64)" Resources/Info.plist

echo "Done: SPARKLE_PRIVATE_KEY set on $REPO, public key written to Resources/Info.plist (commit it)."
