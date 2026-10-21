#!/bin/bash
# Creates Liova's release signing certificate, once, for the GitHub release workflow.
#
# Every release is signed with it, and Liova installs an update by itself only when the
# update is signed with the same certificate as the running copy. So:
#   - Make it once. A new certificate means users must reinstall by hand once, because
#     their copy only trusts updates signed with the old one.
#   - Whoever has the .p12 and its password can ship an update to every user. Keep the
#     backup offline (a password manager), never in the repository.
#
# It writes a .p12 and its password into a folder you choose (default ~/Desktop/liova-release-cert),
# prints the commands that store them as the LIOVA_SIGNING_P12 / LIOVA_SIGNING_PASSWORD
# secrets, and changes nothing else on this Mac.
#
#   scripts/release/create-release-cert.sh [output-folder]
set -euo pipefail

NAME="Liova Release"
OUT="${1:-$HOME/Desktop/liova-release-cert}"
# Signatures carry no secure timestamp, so they're only valid while the certificate is.
DAYS=7300

if [ -e "$OUT/liova-release.p12" ]; then
    echo "$OUT/liova-release.p12 already exists. Keep using it; making a new one breaks updates." >&2
    exit 1
fi
mkdir -p "$OUT"
chmod 700 "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

PASS="$(/usr/bin/openssl rand -base64 24)"
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days "$DAYS" -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$OUT/liova-release.p12" -passout "pass:$PASS" 2>/dev/null
printf '%s' "$PASS" > "$OUT/password.txt"
cp "$WORK/cert.pem" "$OUT/liova-release-cert.pem"
chmod 600 "$OUT"/*

echo "Created $OUT/liova-release.p12 (valid $DAYS days) and its password."
echo
echo "Store both as GitHub secrets (needs the gh CLI, signed in):"
echo "  base64 -i \"$OUT/liova-release.p12\" | gh secret set LIOVA_SIGNING_P12 --repo Krishnarajan7/Liova"
echo "  gh secret set LIOVA_SIGNING_PASSWORD --repo Krishnarajan7/Liova < \"$OUT/password.txt\""
echo
echo "Then back up the folder somewhere offline and delete it from this Mac."
