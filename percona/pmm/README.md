# PMM v3 (Percona Monitoring and Management)

## Alerting

PMM v3 uses "Percona Alerting" which is built on Grafana Unified Alerting.

### Deploy Alerts

```bash
# 1. Update credentials (edit the Secret in deploy-alerts.yaml)
#    Change password from 'admin' to your actual PMM admin password

# 2. Deploy alerts
kubectl apply -f deploy-alerts.yaml

# 3. Check deployment status
kubectl logs -n pmm job/pmm-deploy-alerts -f

# 4. View alerts in PMM UI
#    Navigate to: Alerting -> Alert rules -> MySQL Alerts folder
```

### What Gets Created

| Alert | Threshold | Severity | Duration |
|-------|-----------|----------|----------|
| MySQL Disk Usage Warning | >75% | warning | 5m |
| MySQL Disk Usage Critical | >90% | critical | 2m |
| MySQL Connections High | >80% of max | warning | 5m |
| MySQL Replication Lag | >30s | warning | 5m |
| PXC Cluster Size Warning | <3 nodes | warning | 2m |

### Configure PagerDuty

After alerts are deployed, configure PagerDuty through PMM UI:

1. Go to **Alerting** -> **Contact points**
2. Click **Add contact point**
3. Name: `pagerduty-critical`
4. Integration: **PagerDuty**
5. Enter your Integration Key
6. Save

Then set up routing:

1. Go to **Alerting** -> **Notification policies**
2. Edit the default policy or add a new one
3. Route `severity=critical` to `pagerduty-critical`

### Modify Alerts

To change thresholds or add new alerts:

```bash
# 1. Edit the create_alert calls in deploy-alerts.yaml
# 2. Delete the old job and re-apply
kubectl delete job -n pmm pmm-deploy-alerts
kubectl apply -f deploy-alerts.yaml
```

### How It Works

PMM v3's Percona Alerting uses Grafana's HTTP API:
- `POST /graph/api/folders` - Create alert folders
- `POST /graph/api/ruler/grafana/api/v1/rules/{folder}` - Create alert rules
- Alert rules appear in PMM's Alerting UI immediately

The Kubernetes Job:
1. Waits for PMM to be ready
2. Creates a "MySQL Alerts" folder
3. Creates each alert rule via API
4. Completes (auto-deleted after 10 minutes)

### Files

```
percona/pmm/
├── deploy-alerts.yaml    # Alert definitions + deployment Job
├── fleet.yaml            # Fleet/GitOps deployment config
├── README.md
└── values/
    ├── pmm-base.yaml     # Base Helm values
    ├── pmm-dev.yaml      # Dev overrides
    ├── pmm-staging.yaml  # Staging overrides
    └── pmm-prod.yaml     # Production overrides
```

## PMM Deployment

### Via Fleet (GitOps)

```bash
git add percona/pmm/
git commit -m "Deploy PMM"
git push
```

Fleet targets based on cluster labels:
- `environment: development` -> pmm-dev.yaml
- `environment: staging` -> pmm-staging.yaml
- `environment: production` -> pmm-prod.yaml

### Manual Helm Install

```bash
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install pmm percona/pmm -n pmm --create-namespace -f values/pmm-base.yaml
```

## Troubleshooting

### Alerts not appearing

```bash
# Check job logs
kubectl logs -n pmm job/pmm-deploy-alerts

# Verify PMM API is accessible
kubectl exec -it -n pmm deploy/pmm -- curl -s http://localhost/v1/version

# Check if alerts exist
kubectl exec -it -n pmm deploy/pmm -- \
  curl -u admin:PASSWORD http://localhost/graph/api/ruler/grafana/api/v1/rules
```

### Re-run alert deployment

```bash
kubectl delete job -n pmm pmm-deploy-alerts
kubectl apply -f deploy-alerts.yaml
```
