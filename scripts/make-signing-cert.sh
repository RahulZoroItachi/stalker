#!/bin/bash
# Create the "stalker-dev" code signing certificate.
#
# Why this exists: Swift's default is an ad-hoc signature, whose designated
# requirement is the code hash. TCC therefore pins every Accessibility and
# Automation grant to one exact build, and the next build is a different program
# to it while System Settings still reads as enabled. Signing with a certificate
# makes the requirement "identifier + leaf cert", which survives rebuilds.
#
# install.sh tells you to create this in Keychain Access > Certificate Assistant.
# That application no longer ships on macOS 26, so this script does the same job
# from the command line.
#
# Idempotent: if the identity already exists, it changes nothing.
set -euo pipefail

NAME="stalker-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "'$NAME' already exists, nothing to do:"
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "1. generating a self-signed code signing certificate"
cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = stalker-dev

[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF

# 20 years. This signs one local binary for one user; an expiry that lands mid-use
# would silently invalidate the TCC grants this exists to protect.
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null

openssl x509 -in "$TMP/cert.pem" -noout -subject -enddate

echo "2. importing it into your login keychain"
# -T grants codesign access to the private key, so signing does not prompt every
# time. Scoped to that one binary rather than -A, which would allow any program.
openssl pkcs12 -export -out "$TMP/$NAME.p12" -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" -name "$NAME" -passout pass:"$NAME" 2>/dev/null
security import "$TMP/$NAME.p12" -k "$KEYCHAIN" -P "$NAME" \
  -f pkcs12 -T /usr/bin/codesign

echo "3. checking whether codesign can see it"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "   yes, no trust change needed"
else
  echo "   not yet trusted for code signing; marking it trusted"
  echo "   (macOS will ask for your password)"
  # User trust domain only. Without -d this does not touch the system-wide store.
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
fi

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "done:"
  security find-identity -v -p codesigning | grep "$NAME"
  echo
  echo "next: ./scripts/install.sh"
else
  echo "FAILED: '$NAME' is still not a valid code signing identity." >&2
  echo "Inspect with: security find-identity -p codesigning" >&2
  exit 1
fi
