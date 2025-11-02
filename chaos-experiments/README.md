# Chaos Experiments with Resiliency Tests

This directory contains LitmusChaos experiment definitions that automatically trigger resiliency tests after chaos events complete.

## Structure

Each chaos experiment YAML includes:
1. **ChaosEngine**: Defines the chaos experiment
2. **Resiliency Test Job**: Automatically triggered after chaos completes

## Usage

### Run a chaos experiment with resiliency testing:

```bash
kubectl apply -f chaos-experiments/pod-delete-pxc-with-resiliency.yaml
```

### Monitor the chaos experiment:

```bash
# Watch chaos engine
kubectl get chaosengines -n percona

# Watch chaos results
kubectl get chaosresults -n percona

# Watch resiliency test job
kubectl get jobs -n percona -l chaos-type=pod-delete
```

### View resiliency test logs:

```bash
kubectl logs -n percona job/resiliency-test-pxc-pod-delete
```

## Configuration

Resiliency test behavior can be configured via environment variables:

- `RESILIENCY_MTTR_TIMEOUT_SECONDS`: Maximum time to wait for recovery (default: 120)
- `RESILIENCY_POLL_INTERVAL_SECONDS`: Time between polling checks (default: 15)
- `RESILIENCY_TEST_TYPE`: Type of recovery test (pod_recovery, statefulset_recovery, service_recovery, cluster_recovery)

## Test Types

### `pod_recovery`
Waits for a specific pod to return to Running state.

### `statefulset_recovery`
Waits for StatefulSet to have all expected replicas ready.

### `service_recovery`
Waits for service to have endpoints.

### `cluster_recovery`
Waits for Percona cluster status to be 'ready'.

