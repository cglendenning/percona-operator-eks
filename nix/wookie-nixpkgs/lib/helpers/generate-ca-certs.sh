#!/usr/bin/env bash
#
# Generate shared Certificate Authority for Istio multi-cluster mTLS
# Based on: https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/
#
set -euo pipefail

CERTS_DIR="${1:-./certs}"
mkdir -p "$CERTS_DIR"

echo "=== Generating Istio Certificate Authority ==="
echo ""
echo "Output directory: $CERTS_DIR"
echo ""

# Generate root CA private key
echo "Step 1: Generating root CA private key..."
openssl genrsa -out "$CERTS_DIR/root-key.pem" 4096

# Generate root CA certificate
echo "Step 2: Generating root CA certificate..."
openssl req -x509 -new -nodes \
  -key "$CERTS_DIR/root-key.pem" \
  -sha256 \
  -days 3650 \
  -out "$CERTS_DIR/root-cert.pem" \
  -subj "/O=Istio/CN=Root CA"

# Generate intermediate CA private key for each cluster
echo "Step 3: Generating intermediate CA keys and certificates..."

for cluster in cluster-a cluster-b; do
  echo "  Processing $cluster..."
  
  # Generate intermediate CA private key
  openssl genrsa -out "$CERTS_DIR/${cluster}-ca-key.pem" 4096
  
  # Generate CSR for intermediate CA
  openssl req -new -sha256 \
    -key "$CERTS_DIR/${cluster}-ca-key.pem" \
    -out "$CERTS_DIR/${cluster}-ca-cert.csr" \
    -subj "/O=Istio/CN=Intermediate CA for ${cluster}"
  
  # Sign intermediate CA with root CA
  openssl x509 -req \
    -in "$CERTS_DIR/${cluster}-ca-cert.csr" \
    -CA "$CERTS_DIR/root-cert.pem" \
    -CAkey "$CERTS_DIR/root-key.pem" \
    -CAcreateserial \
    -out "$CERTS_DIR/${cluster}-ca-cert.pem" \
    -days 3650 \
    -sha256 \
    -extensions v3_ca \
    -extfile <(cat <<EOF
[v3_ca]
basicConstraints = critical,CA:true
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign
EOF
)
  
  # Create certificate chain (intermediate + root)
  cat "$CERTS_DIR/${cluster}-ca-cert.pem" "$CERTS_DIR/root-cert.pem" > "$CERTS_DIR/${cluster}-cert-chain.pem"
done

echo ""
echo "=== Certificate Generation Complete ==="
echo ""
echo "Generated files:"
ls -lh "$CERTS_DIR"
echo ""
echo "Root CA fingerprint:"
openssl x509 -in "$CERTS_DIR/root-cert.pem" -noout -fingerprint -sha256
echo ""
echo "These certificates enable mTLS trust between clusters."
echo "The cacerts secret will be created with:"
echo "  - ca-cert.pem (intermediate CA cert)"
echo "  - ca-key.pem (intermediate CA private key)"
echo "  - root-cert.pem (root CA cert)"
echo "  - cert-chain.pem (intermediate + root)"
