#!/usr/bin/env bash
set -euo pipefail

echo "=== Generating shared Istio root CA certificates ==="

CERT_DIR="./certs"
mkdir -p $CERT_DIR

# Generate root CA
echo "Generating root CA..."
openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:4096 \
  -subj "/O=Istio/CN=Root CA" \
  -keyout $CERT_DIR/root-key.pem \
  -out $CERT_DIR/root-cert.pem

# Generate intermediate CA for cluster-a
echo "Generating intermediate CA for cluster-a..."
openssl req -newkey rsa:4096 -nodes \
  -subj "/O=Istio/CN=Intermediate CA/L=cluster-a" \
  -keyout $CERT_DIR/ca-key-cluster-a.pem \
  -out $CERT_DIR/ca-cert-cluster-a.csr

openssl x509 -req -days 365 -CA $CERT_DIR/root-cert.pem -CAkey $CERT_DIR/root-key.pem \
  -set_serial 0 -in $CERT_DIR/ca-cert-cluster-a.csr -out $CERT_DIR/ca-cert-cluster-a.pem

cat $CERT_DIR/ca-cert-cluster-a.pem $CERT_DIR/root-cert.pem > $CERT_DIR/cert-chain-cluster-a.pem

# Generate intermediate CA for cluster-b
echo "Generating intermediate CA for cluster-b..."
openssl req -newkey rsa:4096 -nodes \
  -subj "/O=Istio/CN=Intermediate CA/L=cluster-b" \
  -keyout $CERT_DIR/ca-key-cluster-b.pem \
  -out $CERT_DIR/ca-cert-cluster-b.csr

openssl x509 -req -days 365 -CA $CERT_DIR/root-cert.pem -CAkey $CERT_DIR/root-key.pem \
  -set_serial 1 -in $CERT_DIR/ca-cert-cluster-b.csr -out $CERT_DIR/ca-cert-cluster-b.pem

cat $CERT_DIR/ca-cert-cluster-b.pem $CERT_DIR/root-cert.pem > $CERT_DIR/cert-chain-cluster-b.pem

echo ""
echo "Certificates generated in $CERT_DIR/"
echo ""
echo "Creating cacerts secrets in both clusters..."

# Create secret in cluster-a
kubectl create namespace istio-system --context k3d-cluster-a 2>/dev/null || true
kubectl create secret generic cacerts -n istio-system --context k3d-cluster-a \
  --from-file=$CERT_DIR/ca-cert-cluster-a.pem \
  --from-file=$CERT_DIR/ca-key-cluster-a.pem \
  --from-file=$CERT_DIR/root-cert.pem \
  --from-file=$CERT_DIR/cert-chain-cluster-a.pem \
  --dry-run=client -o yaml | kubectl apply --context k3d-cluster-a -f -

# Create secret in cluster-b
kubectl create namespace istio-system --context k3d-cluster-b 2>/dev/null || true
kubectl create secret generic cacerts -n istio-system --context k3d-cluster-b \
  --from-file=$CERT_DIR/ca-cert-cluster-b.pem \
  --from-file=$CERT_DIR/ca-key-cluster-b.pem \
  --from-file=$CERT_DIR/root-cert.pem \
  --from-file=$CERT_DIR/cert-chain-cluster-b.pem \
  --dry-run=client -o yaml | kubectl apply --context k3d-cluster-b -f -

echo ""
echo "Shared root CA configured for both clusters!"
echo "Both clusters can now establish mTLS trust."
