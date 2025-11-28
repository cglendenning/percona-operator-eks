# Clock Skew Between Cluster Nodes Causing Replication Issues Recovery Process

## Primary Recovery Method

1. **Identify clock skew**
   ```bash
   # Check system time on all nodes
   kubectl exec -n <namespace> <pod-1> -- date
   kubectl exec -n <namespace> <pod-2> -- date
   kubectl exec -n <namespace> <pod-3> -- date
   
   # Check NTP synchronization status
   kubectl exec -n <namespace> <pod-name> -- ntpq -p
   kubectl exec -n <namespace> <pod-name> -- chrony sources
   
   # Check replication lag
   kubectl exec -n <namespace> <replica-pod> -- mysql -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   ```

2. **Synchronize NTP**
   ```bash
   # Check NTP service status
   kubectl exec -n <namespace> <pod-name> -- systemctl status ntpd
   kubectl exec -n <namespace> <pod-name> -- systemctl status chronyd
   
   # Restart NTP service
   kubectl exec -n <namespace> <pod-name> -- systemctl restart ntpd
   kubectl exec -n <namespace> <pod-name> -- systemctl restart chronyd
   
   # Force NTP sync
   kubectl exec -n <namespace> <pod-name> -- ntpdate -s <ntp-server>
   kubectl exec -n <namespace> <pod-name> -- chrony makestep
   ```

3. **Correct system time on affected nodes**
   ```bash
   # If NTP is unavailable, manually set time (temporary)
   kubectl exec -n <namespace> <pod-name> -- date -s "<correct-time>"
   
   # Verify time is synchronized
   kubectl exec -n <namespace> <pod-1> -- date
   kubectl exec -n <namespace> <pod-2> -- date
   kubectl exec -n <namespace> <pod-3> -- date
   ```

4. **Verify time synchronization**
   ```bash
   # Check NTP sync status
   kubectl exec -n <namespace> <pod-name> -- ntpq -p
   
   # Check time difference between nodes
   for pod in $(kubectl get pods -n <namespace> -l app=pxc -o name); do
     echo "$pod: $(kubectl exec -n <namespace> $pod -- date +%s)"
   done
   ```

5. **Restart affected pods if needed**
   ```bash
   # If time drift was severe, restart pods
   kubectl delete pod -n <namespace> <pod-name>
   
   # Wait for pod to restart
   kubectl wait --for=condition=ready pod -n <namespace> <pod-name> --timeout=300s
   ```

6. **Rebuild replication if time drift is severe**
   ```bash
   # If replication is broken due to time drift
   # Stop replication
   kubectl exec -n <namespace> <replica-pod> -- mysql -e "STOP SLAVE;"
   
   # Reset replication
   kubectl exec -n <namespace> <replica-pod> -- mysql -e "RESET SLAVE ALL;"
   
   # Rebuild replication from backup
   # Follow replication setup procedures
   ```

7. **Verify service is restored**
   ```bash
   # Check replication status
   kubectl exec -n <namespace> <replica-pod> -- mysql -e "SHOW SLAVE STATUS\G"
   
   # Check replication lag
   kubectl exec -n <namespace> <replica-pod> -- mysql -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   
   # Verify time synchronization
   kubectl exec -n <namespace> <pod-name> -- ntpq -p
   ```

## Alternate/Fallback Method

1. **Manually set system time if NTP unavailable**
   ```bash
   # Get correct time from reference server
   REFERENCE_TIME=$(kubectl exec -n <namespace> <reference-pod> -- date +%s)
   
   # Set time on affected nodes
   kubectl exec -n <namespace> <pod-name> -- date -s "@$REFERENCE_TIME"
   ```

2. **Restart affected pods**
   ```bash
   # Restart pods to ensure time is correct
   kubectl rollout restart statefulset/<pxc-sts> -n <namespace>
   ```

## Recovery Targets

- **Restore Time Objective**: 60 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 30-120 minutes

## Expected Data Loss

None if corrected quickly; potential data inconsistency if time drift is severe
