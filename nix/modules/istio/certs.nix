# Istio certificate generation for multi-cluster mTLS
{ pkgs }:

let
  # Generate shared root CA and intermediate CAs for multi-cluster setup
  mkCACerts = {
    rootCAName ? "Istio Root CA",
    intermediateName,
    validityDays ? 3650,
  }:
    pkgs.runCommand "istio-ca-certs-${intermediateName}" {
      buildInputs = [ pkgs.openssl ];
    } ''
      mkdir -p $out
      
      # Generate root CA (shared across all clusters)
      if [ ! -f "$out/root-key.pem" ]; then
        # Root CA private key
        openssl genrsa -out "$out/root-key.pem" 4096
        
        # Root CA certificate
        openssl req -x509 -new -nodes \
          -key "$out/root-key.pem" \
          -sha256 -days ${toString validityDays} \
          -out "$out/root-cert.pem" \
          -subj "/CN=${rootCAName}"
      fi
      
      # Generate intermediate CA for this cluster
      openssl genrsa -out "$out/ca-key.pem" 4096
      
      # Create intermediate CSR
      openssl req -new -sha256 \
        -key "$out/ca-key.pem" \
        -subj "/CN=Istio Intermediate CA ${intermediateName}" \
        -out "$out/intermediate.csr"
      
      # Create serial file
      echo "01" > "$out/root-cert.srl"
      
      # Sign intermediate with root CA
      cat > "$out/intermediate.cnf" << EOF
[v3_intermediate_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF
      
      openssl x509 -req \
        -in "$out/intermediate.csr" \
        -CA "$out/root-cert.pem" \
        -CAkey "$out/root-key.pem" \
        -CAserial "$out/root-cert.srl" \
        -out "$out/ca-cert.pem" \
        -days ${toString validityDays} \
        -sha256 \
        -extfile "$out/intermediate.cnf" \
        -extensions v3_intermediate_ca
      
      # Create cert chain (intermediate + root)
      cat "$out/ca-cert.pem" "$out/root-cert.pem" > "$out/cert-chain.pem"
      
      # Clean up intermediate files
      rm -f "$out/intermediate.csr" "$out/intermediate.cnf" "$out/root-cert.srl"
    '';

  # Create Kubernetes secret from CA certs
  mkCACertsSecret = {
    namespace ? "istio-system",
    certs,
  }:
    let
      yaml = pkgs.formats.yaml { };
      
      # Read cert files and base64 encode them
      secret = {
        apiVersion = "v1";
        kind = "Secret";
        metadata = {
          name = "cacerts";
          inherit namespace;
        };
        type = "Opaque";
        data = {
          "ca-cert.pem" = builtins.readFile "${certs}/ca-cert.pem";
          "ca-key.pem" = builtins.readFile "${certs}/ca-key.pem";
          "cert-chain.pem" = builtins.readFile "${certs}/cert-chain.pem";
          "root-cert.pem" = builtins.readFile "${certs}/root-cert.pem";
        };
      };
    in
    pkgs.runCommand "cacerts-secret" { } ''
      mkdir -p $out
      
      # Base64 encode all cert files
      echo 'apiVersion: v1' > $out/manifest.yaml
      echo 'kind: Secret' >> $out/manifest.yaml
      echo 'metadata:' >> $out/manifest.yaml
      echo '  name: cacerts' >> $out/manifest.yaml
      echo '  namespace: ${namespace}' >> $out/manifest.yaml
      echo 'type: Opaque' >> $out/manifest.yaml
      echo 'data:' >> $out/manifest.yaml
      echo "  ca-cert.pem: $(base64 -w 0 < ${certs}/ca-cert.pem)" >> $out/manifest.yaml
      echo "  ca-key.pem: $(base64 -w 0 < ${certs}/ca-key.pem)" >> $out/manifest.yaml
      echo "  cert-chain.pem: $(base64 -w 0 < ${certs}/cert-chain.pem)" >> $out/manifest.yaml
      echo "  root-cert.pem: $(base64 -w 0 < ${certs}/root-cert.pem)" >> $out/manifest.yaml
    '';

  # For multi-cluster: generate root CA once, then intermediate CAs for each cluster
  mkSharedRootCA = {
    rootCAName ? "Istio Root CA",
    validityDays ? 3650,
  }:
    pkgs.runCommand "istio-shared-root-ca" {
      buildInputs = [ pkgs.openssl ];
    } ''
      mkdir -p $out
      
      # Root CA private key
      openssl genrsa -out "$out/root-key.pem" 4096
      
      # Root CA certificate
      openssl req -x509 -new -nodes \
        -key "$out/root-key.pem" \
        -sha256 -days ${toString validityDays} \
        -out "$out/root-cert.pem" \
        -subj "/CN=${rootCAName}"
    '';

  mkIntermediateCA = {
    intermediateName,
    rootCA,
    validityDays ? 3650,
  }:
    pkgs.runCommand "istio-intermediate-ca-${intermediateName}" {
      buildInputs = [ pkgs.openssl ];
    } ''
      mkdir -p $out
      
      # Copy root cert for reference
      cp ${rootCA}/root-cert.pem $out/
      
      # Generate intermediate CA key
      openssl genrsa -out "$out/ca-key.pem" 4096
      
      # Create intermediate CSR
      openssl req -new -sha256 \
        -key "$out/ca-key.pem" \
        -subj "/CN=Istio Intermediate CA ${intermediateName}" \
        -out "$out/intermediate.csr"
      
      # Create serial file in writable output directory
      echo "01" > "$out/root-cert.srl"
      
      # Sign intermediate with root CA
      cat > "$out/intermediate.cnf" << EOF
[v3_intermediate_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF
      
      openssl x509 -req \
        -in "$out/intermediate.csr" \
        -CA ${rootCA}/root-cert.pem \
        -CAkey ${rootCA}/root-key.pem \
        -CAserial "$out/root-cert.srl" \
        -out "$out/ca-cert.pem" \
        -days ${toString validityDays} \
        -sha256 \
        -extfile "$out/intermediate.cnf" \
        -extensions v3_intermediate_ca
      
      # Create cert chain (intermediate + root)
      cat "$out/ca-cert.pem" "$out/root-cert.pem" > "$out/cert-chain.pem"
      
      # Clean up
      rm -f "$out/intermediate.csr" "$out/intermediate.cnf" "$out/root-cert.srl"
    '';
in
{
  inherit mkCACerts mkCACertsSecret mkSharedRootCA mkIntermediateCA;
}
