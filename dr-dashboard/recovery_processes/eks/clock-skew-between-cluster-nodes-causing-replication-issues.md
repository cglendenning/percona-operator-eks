# Clock Skew Between Cluster Nodes Causing Replication Issues Recovery Process

> **<span style="color:red">WARNING: PLACEHOLDER DOCUMENT</span>**
>
> **This recovery process is a PLACEHOLDER and has NOT been fully tested in production.**
> Validate all steps in a non-production environment before executing during an actual incident.


## Set Environment Variables

Copy and paste the following block to configure your environment. You will be prompted for each value:

```bash
# Interactive variable setup - paste this block and answer each prompt
read -p "Enter Kubernetes namespace [percona]: " NAMESPACE; NAMESPACE=${NAMESPACE:-percona}
read -p "Enter pod name (e.g., cluster1-pxc-0): " POD_NAME
```





## Primary Recovery Method

1. **Identify clock skew**
   ```bash
   # Check system time on all nodes
   kubectl exec -n ${NAMESPACE} <pod-1> -- date
   kubectl exec -n ${NAMESPACE} <pod-2> -- date
   kubectl exec -n ${NAMESPACE} <pod-3> -- date
   
   # Check NTP synchronization status
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- ntpq -p
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- chrony sources
   
   # Check EC2 instance time
   aws ec2 describe-instances --instance-ids <instance-id> --query 'Reservations[0].Instances[0].LaunchTime'
   
   # Check replication lag
   kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   ```

2. **Synchronize NTP**
   ```bash
   # Check NTP service status
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- systemctl status chronyd
   
   # Restart NTP service
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- systemctl restart chronyd
   
   # Force NTP sync
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- chrony makestep
   ```

3. **Correct system time on affected nodes**
   ```bash
   # If NTP is unavailable, manually set time (temporary)
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- date -s "<correct-time>"
   
   # Verify time is synchronized
   kubectl exec -n ${NAMESPACE} <pod-1> -- date
   kubectl exec -n ${NAMESPACE} <pod-2> -- date
   kubectl exec -n ${NAMESPACE} <pod-3> -- date
   ```

4. **Verify time synchronization**
   ```bash
   # Check NTP sync status
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- chrony sources
   
   # Check time difference between nodes
   for pod in $(kubectl get pods -n ${NAMESPACE} -l app=pxc -o name); do
     echo "$pod: $(kubectl exec -n ${NAMESPACE} $pod -- date +%s)"
   done
   ```

5. **Restart affected pods if needed**
   ```bash
   # If time drift was severe, restart pods
   kubectl delete pod -n ${NAMESPACE} ${POD_NAME}
   
   # Wait for pod to restart
   kubectl wait --for=condition=ready pod -n ${NAMESPACE} ${POD_NAME} --timeout=300s
   ```

6. **Rebuild replication if time drift is severe**
   ```bash
   # If replication is broken due to time drift
   # Stop replication
   kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -e "STOP SLAVE;"
   
   # Reset replication
   kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -e "RESET SLAVE ALL;"
   
   # Rebuild replication from S3 backup
   # Follow replication setup procedures
   ```

7. **Verify service is restored**
   ```bash
   # Check replication status
   kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -e "SHOW SLAVE STATUS\G"
   
   # Check replication lag
   kubectl exec -n ${NAMESPACE} <replica-pod> -- mysql -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master
   
   # Verify time synchronization
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- chrony sources
   ```

## Alternate/Fallback Method

1. **Manually set system time if NTP unavailable**
   ```bash
   # Get correct time from reference server
   REFERENCE_TIME=$(kubectl exec -n ${NAMESPACE} <reference-pod> -- date +%s)
   
   # Set time on affected nodes
   kubectl exec -n ${NAMESPACE} ${POD_NAME} -- date -s "@$REFERENCE_TIME"
   ```

2. **Restart affected pods**
   ```bash
   # Restart pods to ensure time is correct
   kubectl rollout restart statefulset/<pxc-sts> -n ${NAMESPACE}
   ```

## Recovery Targets

- **Restore Time Objective**: 60 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 30-120 minutes

## Expected Data Loss

None if corrected quickly; potential data inconsistency if time drift is severe
