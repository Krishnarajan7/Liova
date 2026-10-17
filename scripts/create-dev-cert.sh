#!/bin/bash
# Creates a self-signed "Liova Development" code-signing certificate in your login keychain.
#
# Why: without an Apple Developer account, builds are ad-hoc signed and get a new identity on
# every rebuild, so macOS forgets privacy permissions such as Accessibility. Signing every build
# with this stable local certificate keeps them. `make` uses it automatically once it exists.
#
# The certificate is only trusted on this Mac and only for code signing. Remove it any time in
# Keychain Access (search "Liova Development"). macOS will ask for your password once to trust it.
set -euo pipefail

NAME="Liova Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists and is valid for code signing. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="$(uuidgen)"

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/cert.p12" -passout "pass:$PASS" 2>/dev/null

security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Imported \"$NAME\". macOS will now ask for your password to trust it for code signing…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Done. Rebuild with 'make run'; grant Accessibility once more, and it will stick."
else
    echo "The certificate was imported but isn't valid for code signing yet." >&2
    exit 1
fi
