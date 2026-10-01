#!/bin/bash
# Creates a local self-signed code-signing identity named "Overlyric Dev" in the login keychain (once).
# No admin password needed. codesign accepts it (the cert is untrusted, which only matters to Gatekeeper
# for downloaded apps, not for a locally built one). Verify: codesign -d -r- build/Overlyric.app
set -euo pipefail
if security find-certificate -c "Overlyric Dev" >/dev/null 2>&1; then echo "identity already exists"; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Overlyric Dev
O = Overlyric
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -config "$T/cert.cnf" -sha256 2>/dev/null
openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout pass:overlyric -name "Overlyric Dev" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout pass:overlyric -name "Overlyric Dev"
security import "$T/id.p12" -k ~/Library/Keychains/login.keychain-db -P overlyric -T /usr/bin/codesign -T /usr/bin/security
echo "✓ created 'Overlyric Dev'"
