#!/bin/bash
set -e

# Creates a stable self-signed code-signing identity, once.
#
# Why this exists: macOS keys the Accessibility permission to an app's code
# signature. Ad-hoc signing (`codesign --sign -`) produces a designated
# requirement pinned to the binary's cdhash, which changes on every build — so
# every rebuild silently drops the grant and the app stops seeing keystrokes.
# Signing with a real identity produces a requirement pinned to the certificate
# instead, which does not change, so the grant survives rebuilds.
#
# The identity is self-signed and local: it keeps a permission stable on one
# machine. It is not for distribution.

IDENTITY="TypeAhead Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# The p12 needs *some* password. Apple's importer rejects OpenSSL 3's
# empty-password PKCS#12 MAC outright ("MAC verification failed"), so a throwaway
# one is used and then discarded with the temp directory.
P12_PASSWORD="typeahead-local"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Deliberately NOT `security find-identity -p codesigning`: a self-signed
# certificate is not *trusted*, so find-identity reports "0 valid identities"
# even when the identity is present and codesign can use it perfectly well.
# Checking for the certificate itself is the question we actually mean to ask.
if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✅ '$IDENTITY' already exists — nothing to do."
    exit 0
fi

echo "🔑 Generating a self-signed code-signing certificate..."

cat > "$WORKDIR/openssl.cnf" << 'CONF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no

[ dn ]
CN = TypeAhead Self-Signed

[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORKDIR/key.pem" \
    -out "$WORKDIR/cert.pem" \
    -days 3650 \
    -config "$WORKDIR/openssl.cnf" 2>/dev/null

# `-legacy` matters. OpenSSL 3 defaults to AES-256-CBC + PBKDF2 for PKCS#12,
# which Apple's Security framework will not import — it fails with a misleading
# "MAC verification failed during PKCS12 import (wrong password?)" even when the
# password is correct. The legacy algorithms are the ones the importer accepts.
LEGACY_FLAG=""
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
    LEGACY_FLAG="-legacy"
fi

openssl pkcs12 -export $LEGACY_FLAG \
    -inkey "$WORKDIR/key.pem" \
    -in "$WORKDIR/cert.pem" \
    -out "$WORKDIR/identity.p12" \
    -name "$IDENTITY" \
    -passout "pass:$P12_PASSWORD" 2>/dev/null

echo "🔐 Importing into the login keychain..."
# -T /usr/bin/codesign lets codesign use the private key without a GUI prompt
# on every build.
security import "$WORKDIR/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

# Belt and braces against the "codesign wants to access your keychain" dialog.
# Harmless if it fails; the -T flags above usually suffice.
security set-key-partition-list -S apple-tool:,apple: -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo ""
if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✅ '$IDENTITY' created."
    echo "   ./build.sh picks it up automatically."
    echo ""
    echo "   Note: 'security find-identity -v -p codesigning' will still say"
    echo "   '0 valid identities found'. That is expected — it lists only trusted"
    echo "   certificates, and this one is self-signed. codesign uses it fine."
    echo ""
    echo "   You still need to grant Accessibility once, but the grant will now"
    echo "   survive rebuilds instead of resetting every time."
else
    echo "❌ Import reported success but the certificate is not in the keychain."
    echo "   Run the steps by hand to see the error:"
    echo "     openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 3650 -subj '/CN=$IDENTITY'"
    exit 1
fi
