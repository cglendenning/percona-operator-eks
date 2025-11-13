# PMM v3 Secret Configuration Fix

## Problem Summary

When connecting a PMM v3 client to a PMM v3 server with the Percona XtraDB Cluster Operator, you may encounter this error:

```
pmmserverkey and pmmservercert secret keys or pmmservertoken secret key should be set for pmm v3
```

**Reference:** [node.go#L423](https://github.com/percona/percona-xtradb-cluster-operator/blob/main/pkg/pxc/app/statefulset/node.go#L423)

## Root Cause

The operator checks for PMM v3 authentication at [node.go#L386](https://github.com/percona/percona-xtradb-cluster-operator/blob/main/pkg/pxc/app/statefulset/node.go#L386):

```go
if secret.Data[users.PMMServerToken] != nil && len(secret.Data[users.PMMServerToken]) > 0
```

Where `users.PMMServerToken` is defined as the constant `"pmmservertoken"` in [users.go#L23](https://github.com/percona/percona-xtradb-cluster-operator/blob/main/pkg/pxc/users/users.go#L23):

```go
const (
    PMMServer      = "pmmserver"
    PMMServerKey   = "pmmserverkey"
    PMMServerToken = "pmmservertoken"  // <-- This is what the operator checks
)
```

### Key Points:

1. **The secret name matters:** The operator looks for the secret specified in your CR's `spec.secretsName` field (typically `<cluster-name>-pxc-db-secrets`)

2. **The key name is critical:** For PMM v3, the secret **MUST** contain a key named `pmmservertoken` (NOT `pmmserverkey`, NOT `pmmserver`)

3. **This is NOT just any secret:** You cannot create a random secret with the `pmmservertoken` key. It must be:
   - Named according to your CR's `spec.secretsName` field
   - In the same namespace as your cluster
   - Contain the `pmmservertoken` key with your PMM v3 service account token (base64-encoded)

## Solution

### Option 1: Use the Updated Diagnostics Script (Automated)

The `pmm-client-diagnostics.sh` script has been updated to automatically detect and fix this issue:

```bash
cd /Users/craig/percona_operator/percona/scripts
./pmm-client-diagnostics.sh -n <your-namespace> -c <cluster-name>
```

The script will:
1. Detect if the `pmmserver` key is missing
2. Offer to add it automatically
3. Prompt you for your PMM v3 API token
4. Add the key to the correct secret
5. Sync internal secrets
6. Guide you through pod restart

### Option 2: Manual Fix

1. **Get your PMM v3 service account token:**
   - Log into PMM v3 web UI
   - Navigate to Configuration → Service Accounts
   - Create a new service account or use an existing one
   - Copy the service account token

2. **Add the token to your cluster secret:**
   ```bash
   # Set your variables
   NAMESPACE="your-namespace"
   CLUSTER_NAME="pxc-cluster"
   PMM_TOKEN="your-pmm-v3-service-account-token-here"
   
   # Add the pmmservertoken key to the secret
   kubectl patch secret ${CLUSTER_NAME}-pxc-db-secrets \
     -n $NAMESPACE \
     --type=merge \
     -p "{\"data\":{\"pmmservertoken\":\"$(echo -n $PMM_TOKEN | base64)\"}}"
   ```

3. **Delete the internal secret to trigger resync:**
   ```bash
   kubectl delete secret internal-${CLUSTER_NAME}-pxc-db -n $NAMESPACE
   ```

4. **Restart PXC pods to apply changes:**
   ```bash
   kubectl delete pod -l app.kubernetes.io/component=pxc -n $NAMESPACE
   ```

5. **Monitor the operator logs:**
   ```bash
   kubectl logs -n $NAMESPACE \
     -l app.kubernetes.io/name=percona-xtradb-cluster-operator \
     --tail=50 -f
   ```

## Verification

After applying the fix, verify the secret contains the correct key:

```bash
# Check that pmmservertoken key exists
kubectl get secret ${CLUSTER_NAME}-pxc-db-secrets -n $NAMESPACE \
  -o jsonpath='{.data.pmmservertoken}' | base64 -d | wc -c

# Should output the length of your API token (non-zero)
```

Verify the operator check passes:

```bash
# Check operator logs for PMM initialization
kubectl logs -n $NAMESPACE \
  -l app.kubernetes.io/name=percona-xtradb-cluster-operator \
  --tail=100 | grep -i pmm
```

## What Changed in pmm-client-diagnostics.sh

### 1. **Priority Changed for Secret Keys**
- **Before:** Checked `pmmserverkey` first (PMM v2 style)
- **After:** Checks `pmmservertoken` first (PMM v3 requirement)

### 2. **New Repair Function: `fix_pmm_secret()`**
- Automatically adds the `pmmservertoken` key to the cluster secret
- Prompts for PMM v3 API token
- Verifies the key was added correctly
- Syncs internal secrets automatically
- Provides step-by-step guidance

### 3. **Enhanced Detection**
- Detects if `pmmserverkey` exists but `pmmservertoken` is missing
- Warns about the PMM v3 requirement
- References the exact operator code location

### 4. **Better Error Messages**
- Clear explanation of what `users.PMMServerToken` means (`"pmmservertoken"`)
- Links to the operator source code (users.go#L23 and node.go#L386)
- Distinguishes between PMM v2 and PMM v3 requirements

## Code Reference

The operator code at [node.go#L386-423](https://github.com/percona/percona-xtradb-cluster-operator/blob/main/pkg/pxc/app/statefulset/node.go#L386-L423) shows:

```go
// For PMM v3, check for token-based authentication
if secret.Data[users.PMMServerToken] != nil && len(secret.Data[users.PMMServerToken]) > 0 {
    // PMM v3 with token authentication
    pmmC.Env = append(pmmC.Env, corev1.EnvVar{
        Name:  "PMM_SERVER_API_KEY",
        Value: string(secret.Data[users.PMMServerToken]),
    })
    // ... more code ...
} else {
    // Error at line 423
    return nil, errors.New("pmmserverkey and pmmservercert secret keys or pmmservertoken secret key should be set for pmm v3")
}
```

Where `users.PMMServerToken` is defined in the `pkg/pxc/users` package at [users.go#L23](https://github.com/percona/percona-xtradb-cluster-operator/blob/main/pkg/pxc/users/users.go#L23) as:

```go
const (
    PMMServer      = "pmmserver"
    PMMServerKey   = "pmmserverkey"
    PMMServerToken = "pmmservertoken"  // <-- This is the correct value
)
```

## Summary

**For PMM v3, the operator requires:**
- Secret key name: `pmmservertoken` (defined as `users.PMMServerToken`)
- Secret name: `<cluster-name>-pxc-db-secrets` (or whatever is in `spec.secretsName`)
- Value: Base64-encoded PMM v3 service account token

**The updated diagnostics script handles this automatically.**

