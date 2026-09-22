#!/bin/bash
# Creates the self-signed code-signing certificate this project signs releases
# with, imports it for local builds, and writes the files GitHub Actions needs.
#
# Why a certificate at all, when Gatekeeper rejects a self-signed one anyway:
# it is not there to satisfy Gatekeeper. Keychain "Always Allow" grants bind to
# the app's designated requirement, and how the app was signed decides what
# that requirement contains.
#
#   ad-hoc      designated => cdhash H"08b996…"        <- changes every build
#   certificate designated => identifier "…" and certificate leaf = H"…"
#
# So an ad-hoc release makes every user re-approve keychain access on every
# update. Any certificate fixes that, trusted or not.
#
# The certificate is long-lived on purpose. When it expires, signing fails and
# its replacement has a different requirement — which costs every user their
# keychain grants a second time.
#
# NOTHING this writes belongs in the repository. The private key goes to GitHub
# Actions secrets; the output directory is gitignored.
set -euo pipefail

cd "$(dirname "$0")/.."

NAME="${1:-Unified Usage Monitor (self-signed)}"
YEARS="${YEARS:-20}"
OUT="signing"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "✗ a certificate named '$NAME' is already in your keychain."
    echo "  Delete it in Keychain Access first, or pass a different name:"
    echo "      ./tools/make-signing-cert.sh 'Some Other Name'"
    echo
    echo "  Replacing a certificate changes the app's designated requirement,"
    echo "  so everyone using it has to allow keychain access again. Only do it"
    echo "  on purpose."
    exit 1
fi

mkdir -p "$OUT"
chmod 700 "$OUT"
CONFIG="$OUT/openssl.cnf"

# codesign wants a certificate that says it is for code signing. Without the
# critical codeSigning extended key usage it is refused as an identity.
cat > "$CONFIG" <<EOF
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no

[dn]
CN = $NAME

[codesign]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "▸ generating a ${YEARS}-year code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 \
    -days $((YEARS * 365)) -nodes \
    -keyout "$OUT/key.pem" -out "$OUT/cert.pem" \
    -config "$CONFIG" 2>/dev/null

# A random password, because the p12 is only ever read by `security import` and
# by the runner. It is written next to the p12, never printed.
# No pipeline: `head` closing one would SIGPIPE its producer, and `pipefail`
# turns that into an abort.
PASSWORD="$(openssl rand -hex 24)"
printf '%s' "$PASSWORD" > "$OUT/password.txt"

echo "▸ packaging as PKCS#12"
openssl pkcs12 -export \
    -inkey "$OUT/key.pem" -in "$OUT/cert.pem" \
    -name "$NAME" -out "$OUT/cert.p12" \
    -passout "pass:$PASSWORD" 2>/dev/null

base64 -i "$OUT/cert.p12" -o "$OUT/cert.p12.base64"

echo "▸ importing into your login keychain (for local builds)"
# -T lets codesign use the key. macOS may still ask once the first time it
# does; choose "Always Allow".
security import "$OUT/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

printf '%s\n' "$NAME" > .signing-identity

rm -f "$OUT/key.pem" "$CONFIG"
chmod 600 "$OUT"/*

FINGERPRINT="$(openssl x509 -in "$OUT/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2)"

cat <<EOF

✓ done. '$NAME' is now the signing identity for local builds
  (written to .signing-identity, which is gitignored).

  expires:     $(openssl x509 -in "$OUT/cert.pem" -noout -enddate | cut -d= -f2)
  SHA-1:       $FINGERPRINT

To sign CI releases with the same identity, add three repository secrets at
Settings → Secrets and variables → Actions → New repository secret:

  MACOS_CERT_P12_BASE64   contents of $OUT/cert.p12.base64
  MACOS_CERT_PASSWORD     contents of $OUT/password.txt
  MACOS_SIGN_IDENTITY     $NAME

Copy them straight into the browser, e.g.

  pbcopy < $OUT/cert.p12.base64
  pbcopy < $OUT/password.txt

Then keep $OUT/ somewhere safe and offline — a password manager is ideal. If
you lose the key you cannot reissue this identity, and its replacement costs
every user their keychain grants.

$OUT/ is gitignored. Never commit it.
EOF
