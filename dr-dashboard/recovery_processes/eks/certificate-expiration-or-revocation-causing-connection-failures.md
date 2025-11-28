# Certificate Expiration or Revocation Causing Connection Failures Recovery Process

## Primary Recovery Method

1. **Identify certificate issue**
   ```bash
   # Check certificate expiration
   kubectl exec -n <namespace> <pod-name> -- openssl s_client -connect <hostname>:3306 -showcerts 2>&1 | openssl x509 -noout -dates
   
   # Check AWS Certificate Manager
   aws acm list-certificates
   aws acm describe-certificate --certificate-arn <cert-arn>
   
   # Check certificate in Kubernetes secret
   kubectl get secret -n <namespace> <cert-secret> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
   
   # Check pod logs for SSL errors
   kubectl logs -n <namespace> <pod-name> | grep -i "certificate\|ssl\|tls"
   ```

2. **Renew/rotate certificates via AWS Certificate Manager or cert-manager**
   ```bash
   # If using AWS Certificate Manager:
   aws acm request-certificate \
     --domain-name <hostname> \
     --validation-method DNS
   
   # If using cert-manager:
   kubectl get certificate -n <namespace>
   kubectl describe certificate -n <namespace> <cert-name>
   
   # Manually create new certificate
   kubectl create secret tls <cert-secret> \
     --cert=<new-cert.pem> \
     --key=<new-key.pem> \
     -n <namespace>
   ```

3. **Update Kubernetes secrets**
   ```bash
   # Update secret with new certificate
   kubectl create secret tls <cert-secret> \
     --cert=<new-cert.pem> \
     --key=<new-key.pem> \
     -n <namespace> \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Verify secret updated
   kubectl get secret -n <namespace> <cert-secret> -o yaml
   ```

4. **Restart pods to load new certificates**
   ```bash
   # Restart database pods
   kubectl rollout restart statefulset/<pxc-sts> -n <namespace>
   
   # Restart application pods
   kubectl rollout restart deployment/<app-deployment> -n <namespace>
   
   # Wait for pods to be ready
   kubectl rollout status statefulset/<pxc-sts> -n <namespace>
   ```

5. **Verify service is restored**
   ```bash
   # Test SSL connection
   kubectl exec -n <namespace> <pod-name> -- openssl s_client -connect <hostname>:3306 -verify_return_error
   
   # Test application connectivity
   kubectl exec -n <namespace> <app-pod> -- curl -v https://<hostname>:3306
   
   # Check certificate validity
   kubectl exec -n <namespace> <pod-name> -- openssl s_client -connect <hostname>:3306 2>&1 | openssl x509 -noout -dates
   ```

## Alternate/Fallback Method

1. **Temporarily disable certificate validation (development only)**
   ```bash
   # WARNING: Only for emergency situations in development
   # Update application connection strings to skip certificate validation
   # This should be reverted immediately after certificate is fixed
   ```

2. **Restore from certificate backup**
   ```bash
   # Restore certificate from backup
   kubectl create secret tls <cert-secret> \
     --cert=<backup-cert.pem> \
     --key=<backup-key.pem> \
     -n <namespace>
   
   # Restart pods
   kubectl rollout restart statefulset/<pxc-sts> -n <namespace>
   ```

3. **Use alternate certificate authority**
   ```bash
   # If primary CA is unavailable, use backup CA
   # Update certificate issuer configuration
   # Generate new certificate from backup CA
   ```

## Recovery Targets

- **Restore Time Objective**: 45 minutes
- **Recovery Point Objective**: 0
- **Full Repair Time Objective**: 30-90 minutes

## Expected Data Loss

None
