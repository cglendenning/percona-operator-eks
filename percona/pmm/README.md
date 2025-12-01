# PMM Custom Alert Rules

This directory contains custom alert rules for Percona Monitoring and Management (PMM).

## Alert Rules

### MySQL Disk Usage Alert

**File:** `alert-rules/mysql-disk-usage.yaml`

Monitors disk usage on MySQL hosts and fires alerts when usage exceeds thresholds:

- **Warning (75%)**: Fires after 5 minutes above threshold
- **Critical (90%)**: Fires after 2 minutes above threshold

**Monitored Mountpoints:**
- `/var/lib/mysql` (default MySQL data directory)
- `/data` (common alternative)
- `/mysql-data` (Kubernetes persistent volume mount)

**Metrics Used:**
- `node_filesystem_avail_bytes` - Available disk space
- `node_filesystem_size_bytes` - Total disk size

## Deployment

### Option 1: Using Fleet (Recommended)

Add the alert values file to your Fleet configuration:

```yaml
# fleet.yaml
helm:
  chart: percona/pmm
  valuesFiles:
    - percona/pmm/values-pmm-alerts.yaml
```

Then apply with Fleet:
```bash
fleet apply
```

### Option 2: Direct Helm Values

Add to your existing PMM Helm values:

```yaml
# values-pmm.yaml
alertRules:
  enabled: true
  configMap:
    name: pmm-custom-alert-rules

pmm:
  server:
    extraVolumes:
      - name: custom-alert-rules
        configMap:
          name: pmm-custom-alert-rules
    extraVolumeMounts:
      - name: custom-alert-rules
        mountPath: /etc/grafana/provisioning/alerting/custom
        readOnly: true
```

Deploy:
```bash
helm upgrade pmm percona/pmm -f values-pmm.yaml -n pmm
```

### Option 3: Manual ConfigMap Creation

Create ConfigMap directly from alert rule file:

```bash
kubectl create configmap pmm-custom-alert-rules \
  --from-file=mysql-disk-usage.yaml=alert-rules/mysql-disk-usage.yaml \
  -n pmm
```

Then patch PMM deployment to mount it:

```bash
kubectl patch deployment pmm-server -n pmm --patch '
spec:
  template:
    spec:
      volumes:
      - name: custom-alert-rules
        configMap:
          name: pmm-custom-alert-rules
      containers:
      - name: pmm-server
        volumeMounts:
        - name: custom-alert-rules
          mountPath: /etc/grafana/provisioning/alerting/custom
          readOnly: true
'
```

### Option 4: PMM API (Dynamic, Not Gitops)

Export and import via PMM API:

```bash
# Export existing rules
curl -H "Authorization: Bearer $PMM_API_KEY" \
  http://pmm-server:3000/api/v1/provisioning/alert-rules > current-rules.json

# Import new rules
curl -X POST -H "Authorization: Bearer $PMM_API_KEY" \
  -H "Content-Type: application/json" \
  -d @alert-rules/mysql-disk-usage.yaml \
  http://pmm-server:3000/api/v1/provisioning/alert-rules
```

## Verification

After deployment, verify the alert rule is loaded:

### 1. Check ConfigMap
```bash
kubectl get configmap pmm-custom-alert-rules -n pmm
kubectl describe configmap pmm-custom-alert-rules -n pmm
```

### 2. Check PMM Pod Logs
```bash
kubectl logs -n pmm -l app.kubernetes.io/name=pmm -c pmm-server | grep -i alert
```

### 3. Verify in PMM UI
1. Navigate to PMM web interface: `http://pmm-server/`
2. Go to **Alerting** → **Alert rules**
3. Search for "MySQLDiskUsage"
4. You should see both "MySQLDiskUsageHigh" and "MySQLDiskUsageCritical" rules

### 4. Test Alert Rule Query
In PMM, go to **Explore** and run:
```promql
(
  1 - (
    node_filesystem_avail_bytes{mountpoint=~"/var/lib/mysql|/data|/mysql-data"} 
    / 
    node_filesystem_size_bytes{mountpoint=~"/var/lib/mysql|/data|/mysql-data"}
  )
) * 100
```

This should show current disk usage percentage for all MySQL hosts.

## Customization

### Adjust Thresholds

Edit thresholds in `values-pmm-alerts.yaml`:

```yaml
expr: |
  ... > 75  # Change warning threshold
  ... > 90  # Change critical threshold
```

### Adjust Alert Duration

Change how long condition must be true before firing:

```yaml
for: 5m   # Warning fires after 5 minutes
for: 2m   # Critical fires after 2 minutes
```

### Add More Mountpoints

Add additional MySQL data directory patterns:

```yaml
mountpoint=~"/var/lib/mysql|/data|/mysql-data|/custom/mysql"
```

### Modify Alert Channels

Configure where alerts are sent in PMM:

1. Go to **Alerting** → **Contact points**
2. Add Slack, PagerDuty, email, etc.
3. Create notification policy to route MySQL disk alerts

## Troubleshooting

### Alert Not Showing in PMM
```bash
# Check if ConfigMap exists
kubectl get cm pmm-custom-alert-rules -n pmm

# Check if volume is mounted
kubectl describe pod -n pmm -l app.kubernetes.io/name=pmm | grep -A5 Volumes

# Check Grafana logs
kubectl logs -n pmm -l app.kubernetes.io/name=pmm -c pmm-server --tail=100 | grep provisioning
```

### Alert Not Firing
```bash
# Verify metric exists
kubectl exec -n pmm -it $(kubectl get pod -n pmm -l app.kubernetes.io/name=pmm -o name) -- \
  curl -s 'http://localhost:9090/api/v1/query?query=node_filesystem_avail_bytes' | jq

# Check alert evaluation
# In PMM UI: Alerting → Alert rules → Click on rule → View evaluation
```

### Restart PMM After Changes
```bash
kubectl rollout restart deployment pmm-server -n pmm
```

## Adding More Alert Rules

To add additional custom alerts:

1. Create new YAML file in `alert-rules/` directory
2. Add the rule to `values-pmm-alerts.yaml` under `alertRules.configMap.rules`
3. Update via Fleet or Helm
4. Verify in PMM UI

## Best Practices

- **Version control**: Keep alert rules in git
- **Test in dev first**: Deploy to dev environment before production
- **Document thresholds**: Explain why specific thresholds were chosen
- **Alert fatigue**: Don't set thresholds too low (creates noise)
- **Notification routing**: Use appropriate channels for severity levels
- **Regular review**: Revisit thresholds as infrastructure changes
