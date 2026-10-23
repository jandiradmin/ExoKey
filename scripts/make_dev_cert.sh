#!/bin/bash
# Creates a self-signed code signing identity "ExoKey Dev" in the login keychain.
# A stable signature keeps Accessibility/Input Monitoring permissions between rebuilds.
set -euo pipefail
NAME="ExoKey Dev"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "exists"; exit 0; fi
TMP=$(mktemp -d)
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:exokey -name "$NAME"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P exokey -A
rm -rf "$TMP"
security find-identity -p codesigning | grep "$NAME"
