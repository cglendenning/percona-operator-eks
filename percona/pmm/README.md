# PMM Alert Rules and Notifications

Git-managed alert rules and notification channels for Percona Monitoring and Management.

## Files

- **`pmm-alerts.yaml`** - Alert rule definitions (edit to add/modify alerts)
- **`pmm-notifications.yaml`** - PagerDuty and notification routing configuration
- **`fleet.yaml`** - Example Fleet configuration for deployment
- **`alert-rules/`** - Raw alert rule templates (for reference)

## Structure

```
percona/pmm/
├── fleet.yaml                    # Fleet deployment config
├── pmm-alerts.yaml              # Alert rule ConfigMap
├── pmm-notifications.yaml       # PagerDuty/notification ConfigMap
├── values/
│   ├── pmm-base.yaml           # Base config (all environments)
│   ├── pmm-dev.yaml            # Dev overrides
│   ├── pmm-staging.yaml        # Staging overrides
│   └── pmm-prod.yaml           # Prod overrides
└── alert-rules/                 # Raw templates (reference only)
```

## Quick Start

### 1. Configure PagerDuty Integration

Edit `pmm-notifications.yaml` and replace the placeholder:

```yaml
routing_key: 'YOUR_PAGERDUTY_INTEGRATION_KEY_HERE'
```

Get your integration key from PagerDuty:
1. Go to PagerDuty → Services → Select your service
2. Click Integrations → Add Integration
3. Choose "Prometheus" or "Events API V2"
4. Copy the Integration Key

### 2. Customize Environment Values

Edit files in `values/` directory:
- `pmm-base.yaml` - Shared configuration
- `pmm-dev.yaml` - Development overrides
- `pmm-staging.yaml` - Staging overrides  
- `pmm-prod.yaml` - Production overrides

Update ingress hostnames, resource limits, storage sizes, etc.

### 3. Deploy with Fleet

The `fleet.yaml` is ready to use. Just commit and push:

```bash
git add percona/pmm/
git commit -m "Add PMM with custom alerts"
git push
```

Fleet will automatically:
1. Create alert ConfigMaps
2. Deploy PMM Helm chart with environment-specific values
3. Mount alert rules into PMM
4. Configure PagerDuty notifications

### 4. Verify Deployment

```bash
# Check ConfigMaps created
kubectl get cm -n pmm pmm-alert-rules pmm-alertmanager-config

# Check PMM deployed
kubectl get pods -n pmm

# Check alerts loaded
kubectl logs -n pmm deploy/pmm-server | grep provisioning
```

## Adding New Alerts

Edit `pmm-alerts.yaml` and add to the `data.mysql-alerts.yaml` section:

```yaml
data:
  mysql-alerts.yaml: |
    groups:
      - name: mysql_disk_usage
        rules:
          # ... existing rules ...
          
          # Add your new rule here
          - alert: MySQLConnectionPoolHigh
            expr: |
              (mysql_global_status_threads_connected / mysql_global_variables_max_connections) * 100 > 80
            for: 5m
            labels:
              severity: warning
              component: mysql
            annotations:
              summary: "MySQL connection pool at {{ $value }}% on {{ $labels.instance }}"
```

Commit and push:
```bash
git add percona/pmm/pmm-alerts.yaml
git commit -m "Add MySQL connection pool alert"
git push
```

Your CI/CD pipeline will trigger Fleet to deploy the changes.

## Current Alerts

### MySQL Disk Usage High (Warning)
- **Threshold**: 75% disk usage
- **Duration**: 5 minutes
- **Severity**: warning
- **Action**: Review disk usage, plan cleanup or expansion

### MySQL Disk Usage Critical
- **Threshold**: 90% disk usage  
- **Duration**: 2 minutes
- **Severity**: critical
- **Action**: Immediate intervention required

## Notification Routing

Configured in `pmm-notifications.yaml`:

- **Critical alerts** → PagerDuty immediately (10s wait, 5m repeat)
- **Warning alerts** → PagerDuty with delay (5m wait, 1h repeat)
- **Inhibition**: Warnings suppressed if critical alert already firing

## Verification

### Check ConfigMaps Applied
```bash
kubectl get configmap pmm-alert-rules -n pmm
kubectl get configmap pmm-alertmanager-config -n pmm
```

### View Alert Rules in PMM
1. Navigate to PMM: `http://pmm-server/`
2. Go to **Alerting** → **Alert rules**
3. Search for "MySQL"

### Test PagerDuty Integration
Manually trigger a test alert:
```bash
kubectl exec -n pmm deploy/pmm-server -- \
  curl -X POST http://localhost:9093/api/v1/alerts \
  -d '[{"labels":{"alertname":"TestAlert","severity":"critical"},"annotations":{"summary":"Test PagerDuty integration"}}]'
```

Check PagerDuty for incident creation.

### View Alertmanager Status
```bash
# Check active alerts
kubectl exec -n pmm deploy/pmm-server -- \
  curl http://localhost:9093/api/v1/alerts

# Check notification status
kubectl exec -n pmm deploy/pmm-server -- \
  curl http://localhost:9093/api/v1/status
```

## Deployment Flow

```
1. Edit pmm-alerts.yaml or pmm-notifications.yaml (or values/*.yaml)
2. Commit to git
3. Push to repository
4. CI/CD pipeline triggers
5. Fleet applies to clusters based on targetCustomization labels
6. PMM Helm chart deployed/upgraded with ConfigMaps
7. PMM automatically loads alert rules and notification config
8. New alerts/routing active
```

## Environment Targeting

Fleet uses cluster labels to target environments:

- **Dev**: `environment: development`
- **Staging**: `environment: staging`
- **Prod**: `environment: production`

Each environment gets:
- Base values from `values/pmm-base.yaml`
- Environment-specific overrides from `values/pmm-{env}.yaml`
- Same alerts (from `pmm-alerts.yaml`)
- Same notifications (from `pmm-notifications.yaml`)

To use different PagerDuty keys per environment, add environment-specific 
ConfigMaps or use secrets with different keys.

## Customization

### Change Alert Thresholds

In `pmm-alerts.yaml`:
```yaml
expr: |
  ... > 75  # Change to your threshold
for: 5m     # Change duration
```

### Add New Notification Channel

In `pmm-notifications.yaml`, add to `receivers`:
```yaml
- name: 'slack-notifications'
  slack_configs:
    - api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
      channel: '#alerts'
      title: '{{ .GroupLabels.alertname }}'
```

Then add routing:
```yaml
routes:
  - match:
      severity: warning
    receiver: slack-notifications
```

### Adjust PagerDuty Severity Mapping

```yaml
pagerduty_configs:
  - routing_key: 'YOUR_KEY'
    severity: '{{ if eq .GroupLabels.severity "critical" }}error{{ else }}warning{{ end }}'
```

## Troubleshooting

### Alerts Not Showing
```bash
# Check ConfigMap content
kubectl get configmap pmm-alert-rules -n pmm -o yaml

# Check if mounted in pod
kubectl describe pod -n pmm -l app=pmm | grep -A10 Volumes
```

### PagerDuty Not Receiving Alerts
```bash
# Check Alertmanager logs
kubectl logs -n pmm deploy/pmm-server -c alertmanager

# Verify integration key is correct
kubectl get configmap pmm-alertmanager-config -n pmm -o yaml | grep routing_key
```

### Alert Rules Not Loading
```bash
# Check Grafana provisioning logs
kubectl logs -n pmm deploy/pmm-server -c pmm-server | grep provisioning

# Restart to force reload
kubectl rollout restart deployment pmm-server -n pmm
```

## Best Practices

- Keep thresholds realistic (avoid alert fatigue)
- Test in dev environment first
- Document why each threshold was chosen
- Use inhibition rules to prevent notification spam
- Regularly review and adjust based on actual incidents
- Version control everything (alerts + notifications)
