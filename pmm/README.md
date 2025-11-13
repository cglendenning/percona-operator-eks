# Percona Monitoring and Management (PMM) Server v3

This directory contains installation and uninstallation scripts for deploying PMM Server version 3 on Kubernetes.

## Overview

PMM (Percona Monitoring and Management) is an open-source database monitoring, management, and observability solution for MySQL, PostgreSQL, MongoDB, and MariaDB. This installation deploys **PMM Server v3**, the latest version with enhanced features and service account token-based authentication.

## Directory Structure

```
pmm/
├── eks/
│   ├── install.sh      # Install PMM Server on EKS
│   └── uninstall.sh    # Uninstall PMM Server from EKS
├── on-prem/
│   ├── install.sh      # Install PMM Server on on-premise Kubernetes
│   └── uninstall.sh    # Uninstall PMM Server from on-premise Kubernetes
└── README.md           # This file
```

## PMM v3 vs PMM v2

### Key Differences

| Feature | PMM v2 | PMM v3 |
|---------|--------|--------|
| **Authentication** | API Keys | Service Account Tokens |
| **Architecture** | Monolithic | Microservices-based |
| **Performance** | Good | Improved (lighter weight) |
| **Kubernetes Native** | Partial | Fully optimized |

### Why PMM v3?

- **Service Account Tokens**: More secure Kubernetes-native authentication
- **Better Resource Efficiency**: Optimized for containerized environments
- **Enhanced Monitoring**: Improved metrics collection and visualization
- **Future-Proof**: Active development and feature additions

## Installation

### Prerequisites

**For EKS:**
- `kubectl` configured for EKS cluster
- `aws` CLI installed
- Sufficient cluster resources (1 CPU, 2Gi memory minimum)
- EBS CSI driver installed

**For On-Premise:**
- `kubectl` configured for your Kubernetes cluster
- StorageClass available for persistent volumes
- Sufficient cluster resources (1 CPU, 2Gi memory minimum)

### EKS Installation

```bash
cd pmm/eks
./install.sh
```

**What it installs:**
- Namespace: `pmm`
- PMM Server v3 StatefulSet
- Persistent storage: 100Gi on `gp2` storage class (AWS EBS)
- Service: LoadBalancer (exposes PMM via AWS ELB)
- Service account with token for authentication

**Access PMM:**
The script will display the LoadBalancer URL after installation:
```
https://<load-balancer-url>
```

### On-Premise Installation

```bash
cd pmm/on-prem
./install.sh
```

**Interactive prompts:**
- StorageClass selection (from available storage classes)
- Storage size (default: 100Gi)

**What it installs:**
- Namespace: `pmm`
- PMM Server v3 StatefulSet
- Persistent storage on selected storage class
- Service: NodePort (exposes PMM via node IPs)
- Service account with token for authentication

**Access PMM:**
The script will display NodePort access information:
```
https://<node-ip>:<https-nodeport>
```

## Configuration

### Default Credentials

**First Login:**
- Username: `admin`
- Password: `admin`

**⚠️ IMPORTANT:** Change the default password immediately after first login!

### Service Account Token

PMM v3 uses **service account tokens** for client authentication (not API keys like PMM v2).

**Retrieve your token:**
```bash
kubectl get secret pmm-server-token -n pmm -o jsonpath='{.data.token}' | base64 -d && echo
```

**Save this token!** You'll need it when configuring PMM clients on your database clusters.

### Resource Configuration

**Default Resources:**
- CPU Request: 1000m (1 core)
- Memory Request: 2Gi
- CPU Limit: 2000m (2 cores)
- Memory Limit: 4Gi

**Storage:**
- Default: 100Gi
- Adjustable during on-prem installation

**For production:** Consider increasing resources based on the number of monitored nodes:
- Small (1-10 nodes): 1 CPU, 2Gi memory
- Medium (10-50 nodes): 2 CPU, 4Gi memory
- Large (50+ nodes): 4 CPU, 8Gi memory

## Connecting PXC Clusters to PMM

### For PMM v3 (Service Account Token)

1. Get your PMM service account token:
   ```bash
   kubectl get secret pmm-server-token -n pmm -o jsonpath='{.data.token}' | base64 -d && echo
   ```

2. Add the token to your PXC cluster secret:
   ```bash
   PMM_TOKEN='<your-token-from-step-1>'
   kubectl patch secret pxc-cluster-pxc-db-secrets -n <namespace> --type=merge \
     -p "{\"data\":{\"pmmserverkey\":\"$(echo -n $PMM_TOKEN | base64)\"}}"
   ```

3. If needed, delete internal secret to trigger resync:
   ```bash
   kubectl delete secret internal-pxc-cluster-pxc-db -n <namespace>
   ```

4. Restart PXC pods:
   ```bash
   kubectl delete pod -l app.kubernetes.io/component=pxc -n <namespace>
   ```

### Verify Connection

Check the PMM web interface:
1. Log in to PMM
2. Navigate to "Inventory" → "Services"
3. Your PXC cluster should appear within a few minutes

## Uninstallation

### EKS Uninstallation

```bash
cd pmm/eks
./uninstall.sh
```

### On-Premise Uninstallation

```bash
cd pmm/on-prem
./uninstall.sh
```

**⚠️ WARNING:** Uninstallation will:
- Delete all PMM Server resources
- Remove all collected monitoring data
- Delete persistent storage (cannot be recovered)

The script will prompt for confirmation before proceeding.

## Troubleshooting

### PMM Server Not Starting

**Check pod status:**
```bash
kubectl get pods -n pmm
kubectl describe pod <pmm-server-pod> -n pmm
```

**Check logs:**
```bash
kubectl logs -n pmm -l app=pmm-server -f
```

**Common issues:**
- Insufficient resources: Increase CPU/memory in the StatefulSet
- Storage provisioning failed: Verify StorageClass is available
- Image pull errors: Check network connectivity

### Cannot Access PMM Web Interface

**EKS (LoadBalancer):**
```bash
# Get LoadBalancer URL
kubectl get svc monitoring-service -n pmm

# Check if LoadBalancer is provisioned
kubectl describe svc monitoring-service -n pmm
```

**On-Premise (NodePort):**
```bash
# Get NodePort
kubectl get svc monitoring-service -n pmm

# Get node IPs
kubectl get nodes -o wide
```

### PXC Clients Not Connecting

**Check secret configuration:**
```bash
# Verify pmmserverkey exists
kubectl get secret pxc-cluster-pxc-db-secrets -n <namespace> -o jsonpath='{.data.pmmserverkey}' | base64 -d

# Check internal secret sync
kubectl get secret internal-pxc-cluster-pxc-db -n <namespace> -o jsonpath='{.data.pmmserverkey}' | base64 -d
```

**Run PMM client diagnostics:**
```bash
./percona/scripts/pmm-client-diagnostics.sh -n <namespace> -c <cluster-name>
```

### Service Account Token Issues

**Regenerate token:**
```bash
# Delete existing token secret
kubectl delete secret pmm-server-token -n pmm

# Recreate it
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: pmm-server-token
  namespace: pmm
  annotations:
    kubernetes.io/service-account.name: pmm-server
type: kubernetes.io/service-account-token
EOF

# Wait for token to be generated (a few seconds)
kubectl get secret pmm-server-token -n pmm -o jsonpath='{.data.token}' | base64 -d && echo
```

## Useful Commands

**Check PMM Server status:**
```bash
kubectl get pods -n pmm
kubectl get svc -n pmm
kubectl get pvc -n pmm
```

**View PMM Server logs:**
```bash
kubectl logs -n pmm -l app=pmm-server -f
```

**Get service account token:**
```bash
kubectl get secret pmm-server-token -n pmm -o jsonpath='{.data.token}' | base64 -d && echo
```

**Access PMM Server pod:**
```bash
kubectl exec -it <pmm-server-pod> -n pmm -- bash
```

**Check resource usage:**
```bash
kubectl top pod -n pmm
```

## Upgrading PMM Server

To upgrade to a newer version of PMM:

1. Update the `PMM_VERSION` in the install script
2. Delete the existing StatefulSet (keeps data):
   ```bash
   kubectl delete statefulset pmm-server -n pmm
   ```
3. Re-run the install script
4. The new version will use the existing PersistentVolume (data preserved)

**Note:** Always check PMM release notes for breaking changes before upgrading.

## Security Considerations

1. **Change Default Password**: Immediately after installation
2. **Use HTTPS**: Always access PMM via HTTPS
3. **Network Policies**: Consider implementing network policies to restrict access
4. **RBAC**: The service account has minimal permissions (only for token generation)
5. **Regular Updates**: Keep PMM Server updated for security patches

## Architecture

```
┌─────────────────────────────────────────┐
│         PMM Server v3 (pmm namespace)   │
│  ┌────────────────────────────────────┐ │
│  │  StatefulSet: pmm-server           │ │
│  │  - Container: percona/pmm-server:3 │ │
│  │  - Port 80 (HTTP), 443 (HTTPS)     │ │
│  │  - Mounts: /srv (persistent)       │ │
│  └────────────────────────────────────┘ │
│  ┌────────────────────────────────────┐ │
│  │  PVC: pmm-server-data              │ │
│  │  - 100Gi (default)                 │ │
│  │  - StorageClass: gp3 / custom      │ │
│  └────────────────────────────────────┘ │
│  ┌────────────────────────────────────┐ │
│  │  Service: monitoring-service       │ │
│  │  - LoadBalancer (EKS)              │ │
│  │  - NodePort (On-Prem)              │ │
│  └────────────────────────────────────┘ │
│  ┌────────────────────────────────────┐ │
│  │  Secret: pmm-server-token          │ │
│  │  - Service Account Token (PMM v3)  │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
           │
           │ Monitors (PMM Clients)
           ▼
┌─────────────────────────────────────────┐
│  PXC Clusters (various namespaces)      │
│  - PMM client sidecars                  │
│  - Authenticate with service token      │
│  - Send metrics to PMM Server           │
└─────────────────────────────────────────┘
```

## Additional Resources

- [PMM Documentation](https://docs.percona.com/percona-monitoring-and-management/)
- [PMM GitHub Repository](https://github.com/percona/pmm)
- [Percona Forums](https://forums.percona.com/)
- [PMM Release Notes](https://docs.percona.com/percona-monitoring-and-management/release-notes/)

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review PMM logs: `kubectl logs -n pmm -l app=pmm-server`
3. Run diagnostics: `./percona/scripts/pmm-client-diagnostics.sh`
4. Consult [Percona Documentation](https://docs.percona.com/percona-monitoring-and-management/)
5. Ask on [Percona Forums](https://forums.percona.com/)

