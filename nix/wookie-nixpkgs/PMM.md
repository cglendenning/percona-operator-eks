# PMM Integration

PMM (Percona Monitoring and Management) v3 is integrated into wookie-nixpkgs with Vault and External Secrets Operator for secure service account token management.

## Architecture

```
PMM Server → Creates Service Account "wookie" → Token
                                                    ↓
Vault ← Stores token at secret/pmm/wookie ← setup script
  ↓
External Secrets Operator → Syncs to K8s Secret
                             "pmm-token" in pmm namespace
                             key: pmmservertoken
```

## Quick Start

```bash
cd nix/wookie-nixpkgs

# Stand up PMM stack
nix run .#pmm-up

# Check status
nix run .#pmm-status

# Tear down
nix run .#pmm-down
```

## What Gets Deployed

1. **PMM Server v3** in `pmm` namespace
   - Deployment with readiness/liveness probes
   - LoadBalancer service on ports 80/443
   - Admin credentials: admin/admin

2. **Vault** in `vault` namespace (dev mode)
   - In-memory storage
   - Auto-unsealed
   - Root token: `root`

3. **External Secrets Operator** in `external-secrets` namespace
   - Installed via Helm
   - CRDs included

4. **SecretStore** and **ExternalSecret** in `pmm` namespace
   - SecretStore connects to Vault
   - ExternalSecret syncs token from `secret/pmm/wookie` to K8s secret `pmm-token`

## Access

### PMM Web UI
```bash
# Access at http://localhost:8080
# Credentials: admin/admin
```

### Vault
```bash
# Port forward
kubectl port-forward -n vault svc/vault 8200:8200

# Access at http://localhost:8200
# Root token: root
```

### Verify Token Sync

```bash
# Check token in Vault
kubectl exec -n vault $(kubectl get pod -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}') -- \
  vault kv get secret/pmm/wookie

# Check synced K8s secret
kubectl get secret pmm-token -n pmm -o jsonpath='{.data.pmmservertoken}' | base64 -d
echo

# Check External Secret status
kubectl get externalsecret pmm-token -n pmm -o yaml
```

## Module Structure

```
modules/
  projects/
    pmm/
      default.nix          # PMM module with Vault & ESO
  profiles/
    local-pmm.nix          # PMM configuration profile
```

### Configuration

The PMM module follows the same patterns as the Wookie/Istio modules:

- **Nix-centric**: All resources defined as Nix expressions using `yaml.generate`
- **No heredocs**: Inline YAML avoided in favor of structured Nix attributes
- **Batch-based**: Resources organized into namespaces/operators/services batches
- **Modular**: Separate enable flags for PMM, Vault, and External Secrets

Example configuration:

```nix
projects.pmm = {
  enable = true;
  
  pmm = {
    enable = true;
    version = "3.0.0";
    namespace = "pmm";
    adminPassword = "admin";
  };
  
  vault = {
    enable = true;
    namespace = "vault";
    devMode = true;
    rootToken = "root";
  };
  
  externalSecrets = {
    enable = true;
    namespace = "external-secrets";
  };
};
```

## Service Account Token Flow

1. PMM deployment starts
2. `pmm-up` waits for PMM API to be ready
3. Setup script (`setup-pmm-token`) runs:
   - Creates service account "wookie" via PMM API
   - Generates service account token
   - Stores token in Vault at `secret/pmm/wookie`
4. External Secrets Operator syncs token to K8s secret
5. Applications can mount the `pmm-token` secret

## Production Considerations

This example uses dev-mode Vault for simplicity. For production:

- Use Vault in HA mode with proper unsealing
- Enable Vault auth methods (Kubernetes, AppRole)
- Use persistent storage for PMM and Vault
- Implement proper RBAC
- Rotate service account tokens regularly
- Use PMM with persistent volumes

## Troubleshooting

### PMM not starting
```bash
kubectl logs -n pmm deployment/pmm-server
kubectl describe pod -n pmm -l app=pmm-server
```

### Vault connection issues
```bash
kubectl exec -n vault $(kubectl get pod -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}') -- vault status
kubectl logs -n vault -l app.kubernetes.io/name=vault
```

### External Secret not syncing
```bash
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets
kubectl describe secretstore vault-backend -n pmm
kubectl describe externalsecret pmm-token -n pmm
```

### Re-run token setup
```bash
# Delete and recreate
kubectl delete secret pmm-token -n pmm
kubectl delete externalsecret pmm-token -n pmm

# Re-deploy
nix run .#pmm-up
```

## Integration with Other Projects

The PMM module can be combined with other wookie-nixpkgs modules:

```nix
[
  ../projects/pmm
  ../projects/wookie
  {
    projects.pmm.enable = true;
    projects.wookie.enable = true;
    # Both PMM and Wookie will deploy to the same cluster
  }
]
```

## References

- [PMM Documentation](https://docs.percona.com/percona-monitoring-and-management/)
- [Vault Documentation](https://developer.hashicorp.com/vault/docs)
- [External Secrets Operator](https://external-secrets.io/)
