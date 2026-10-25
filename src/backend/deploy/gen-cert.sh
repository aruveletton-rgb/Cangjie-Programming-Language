#!/usr/bin/env bash
# Generate a self-signed certificate for an IP-based HTTPS entry.
#
# The cloud demo is reached by IP (no ICP filing in this thread), so the certificate
# carries an IP SAN rather than a DNS SAN. Browsers will still warn because the
# certificate is not publicly trusted; that is expected and documented.
#
# Usage: ./gen-cert.sh <public-ip-or-host> [output-dir]
#   ./gen-cert.sh 123.45.67.89
#   ./gen-cert.sh 127.0.0.1 ./temp/backend/tls
set -euo pipefail

TARGET="${1:-}"
OUT="${2:-.}"

if [ -z "$TARGET" ]; then
  echo "usage: $0 <public-ip-or-host> [output-dir]" >&2
  exit 2
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl not found. On bare Windows install OpenSSL or use New-SelfSignedCertificate." >&2
  exit 2
fi

mkdir -p "$OUT"

# If the target is a bare IP, use IP SAN; otherwise DNS SAN.
case "$TARGET" in
  *[!0-9.]*) SAN="DNS:$TARGET,DNS:localhost,IP:127.0.0.1" ;;
  *)         SAN="IP:$TARGET,DNS:localhost" ;;
esac

openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout "$OUT/tls.key" -out "$OUT/tls.crt" \
  -subj "/CN=$TARGET/O=PAEP-DEMO/OU=course-project" \
  -addext "subjectAltName=$SAN" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" 2>/dev/null

chmod 600 "$OUT/tls.key" 2>/dev/null || true

echo "certificate: $OUT/tls.crt"
echo "private key: $OUT/tls.key"
echo "subject:     $(openssl x509 -in "$OUT/tls.crt" -noout -subject)"
echo "SAN:         $(openssl x509 -in "$OUT/tls.crt" -noout -ext subjectAltName | tail -n 1 | tr -d ' ')"
echo "expires:     $(openssl x509 -in "$OUT/tls.crt" -noout -enddate)"
