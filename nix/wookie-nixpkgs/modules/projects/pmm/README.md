# PMM - Manual Alert Setup

How to create the Grafana MySQL-down alert rule by hand on a k3d cluster.

## Prerequisites

- `kubectl` configured and pointing at the right cluster
- `curl` available
- The PMM pod is running

---

## 1. Find your namespace and service

```bash
# Find the namespace your PMM pod is in
kubectl get pods -A | grep pmm

# Find the service name and ports (replace <namespace>)
kubectl get svc -n <namespace>
```

You're looking for the service that exposes port 80 or 443.

---

## 2. Port-forward to Grafana

PMM's Grafana is embedded and reachable at `/graph` on the PMM HTTP port.

```bash
# HTTP (port 80) - preferred
kubectl port-forward svc/<service-name> 18080:80 -n <namespace> --context <context>

# HTTPS (port 443) - if 80 isn't available
kubectl port-forward svc/<service-name> 18080:443 -n <namespace> --context <context>
```

Leave this running in a separate terminal. Verify it works:

```bash
# HTTP
curl -su admin:admin http://localhost:18080/v1/readyz

# HTTPS
curl -sku admin:admin https://localhost:18080/v1/readyz
```

You should get `{"status":"ok"}` or similar. If you get 401, your password is not `admin` — use the real password.

---

## 3. Find the Prometheus datasource UID

Grafana alert rules need the UID of the Prometheus/VictoriaMetrics datasource.

```bash
# HTTP
curl -s -u admin:<password> http://localhost:18080/graph/api/datasources \
  | grep -o '"uid":"[^"]*"' | head -5

# HTTPS
curl -sk -u admin:<password> https://localhost:18080/graph/api/datasources \
  | grep -o '"uid":"[^"]*"' | head -5
```

If you have `jq`:

```bash
curl -s -u admin:<password> http://localhost:18080/graph/api/datasources \
  | jq '.[] | select(.type=="prometheus") | {name, uid, type}'
```

Copy the `uid` value — you need it in the next step.

---

## 4. Create the alert rule

Replace `<DATASOURCE_UID>` with the value from step 3, and `<password>` with your PMM admin password.

```bash
curl -s -X POST \
  -u admin:<password> \
  -H "Content-Type: application/json" \
  -H "X-Disable-Provenance: true" \
  http://localhost:18080/graph/api/v1/provisioning/alert-rules \
  -d '{
    "title": "MySQL down (Grafana)",
    "ruleGroup": "wookie-pmm",
    "folderUID": "general",
    "orgID": 1,
    "noDataState": "NoData",
    "execErrState": "Error",
    "for": "1m",
    "condition": "A",
    "labels": {
      "severity": "critical",
      "source": "wookie-nix-grafana-wsl"
    },
    "annotations": {
      "summary": "MySQL service is down"
    },
    "data": [
      {
        "refId": "A",
        "queryType": "",
        "relativeTimeRange": { "from": 300, "to": 0 },
        "datasourceUid": "<DATASOURCE_UID>",
        "model": {
          "refId": "A",
          "expr": "mysql_up == 0",
          "intervalMs": 1000,
          "maxDataPoints": 43200
        }
      }
    ]
  }'
```

For HTTPS, add `-k` after `curl`.

A successful response contains a JSON object with a `uid` field and no `message` field.

---

## 5. Verify

```bash
curl -s -u admin:<password> http://localhost:18080/graph/api/v1/provisioning/alert-rules \
  | grep -o '"title":"[^"]*"'
```

You should see `"title":"MySQL down (Grafana)"` in the output.

To view it in the UI: open `http://localhost:18080/graph` in your browser, go to **Alerting → Alert rules**.

---

## Troubleshooting

**Port-forward exits immediately**
The service exists but no pod is ready to back it. Check:
```bash
kubectl get pods -n <namespace>
kubectl describe svc <service-name> -n <namespace>  # check Endpoints
```

**401 Unauthorized**
Wrong password. Check:
```bash
kubectl get secret -n <namespace> | grep pmm
```

**`folderUID: general` returns 404**
Some Grafana versions don't have a `general` folder. Create one first:
```bash
curl -s -X POST -u admin:<password> \
  -H "Content-Type: application/json" \
  http://localhost:18080/graph/api/folders \
  -d '{"title":"General","uid":"general"}'
```

**Datasource not found / empty UID**
VictoriaMetrics (PMM's internal metrics store) may be registered as type `prometheus`. If the datasource list is empty, PMM may still be initializing — wait a minute and retry.
