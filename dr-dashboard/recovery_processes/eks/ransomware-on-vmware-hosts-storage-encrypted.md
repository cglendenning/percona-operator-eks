# Ransomware on VMware Hosts (Storage Encrypted) Recovery Process

## Scenario
Ransomware on VMware hosts (storage encrypted)

## Detection Signals
- Crypto activity detected by EDR
- Sudden file access errors across multiple systems
- Files renamed with unusual extensions (.encrypted, .locked, etc.)
- Ransom notes appearing on systems
- VMware vCenter alerts
- Unusual network traffic to external IPs
- Mass file modifications detected

## Primary Recovery Method
Isolate; rebuild hosts; restore K8s and PXC from clean backups in secondary DC

### Steps

⚠️ **CRITICAL**: Do NOT pay ransom! Follow incident response procedures!

1. **ISOLATE IMMEDIATELY**
   ```bash
   # Disconnect affected systems from network
   # On vCenter:
   - Shut down affected VMs (do NOT delete)
   - Disconnect network adapters
   - Take snapshots (may help forensics)
   
   # Block affected IP ranges at firewall
   # Isolate management network
   # Disable VPN access
   ```

2. **Activate incident response team**
   - Security team
   - Legal counsel
   - PR/Communications
   - Senior leadership
   - Law enforcement (if required)
   - Cyber insurance provider

3. **Assess scope of infection**
   ```bash
   # Check which systems are affected
   # Review EDR alerts
   # Check backup systems (are they encrypted too?)
   # Identify patient zero
   # Determine infection timeline
   ```

4. **Verify backups are clean**
   ```bash
   # Test backups from before infection
   # Ensure backups were immutable or offline
   # Check backup integrity
   aws s3 ls s3://<backup-bucket>/backups/ --recursive | grep "<date-before-infection>"
   
   # Download and verify a test backup
   aws s3 cp s3://<backup-bucket>/backups/<clean-backup>/ /tmp/verify/ --recursive
   xtrabackup --prepare --target-dir=/tmp/verify
   ```

5. **Failover to secondary DC immediately**
   ```bash
   # If secondary DC is clean and replicating
   # Promote secondary to primary (see Primary DC outage runbook)
   
   # Update DNS to point to secondary DC
   # Notify applications of new database endpoint
   # Verify secondary DC has no signs of infection
   ```

6. **Rebuild primary DC from scratch**
   
   **Phase 1: Clean slate**
   - Wipe all affected systems
   - Rebuild VMware hosts from clean images
   - Update all firmware and software
   - Apply security patches
   - Harden configurations

   **Phase 2: Rebuild infrastructure**
   ```bash
   # Rebuild Kubernetes cluster from scratch
   # Use Infrastructure as Code (Terraform, etc.)
   terraform destroy -target=<infected-resources>
   terraform apply
   
   # Deploy from clean images only
   # Verify all container images with checksums
   ```

   **Phase 3: Restore database**
   ```bash
   # Restore from clean, pre-infection backup
   aws s3 sync s3://<backup-bucket>/backups/<clean-backup>/ /restore/ --delete
   
   # Prepare and restore
   xtrabackup --prepare --target-dir=/restore
   xtrabackup --copy-back --target-dir=/restore --datadir=/var/lib/mysql
   
   # Verify no malware in restored data
   # Scan all files before starting database
   ```

7. **Security hardening**
   - Change ALL passwords and credentials
   - Rotate ALL certificates and keys
   - Enable MFA on all accounts
   - Review and restrict network access
   - Implement zero-trust architecture
   - Deploy enhanced EDR/XDR

8. **Forensics and analysis**
   - Preserve evidence for investigation
   - Identify attack vector
   - Determine what data was exfiltrated
   - Check for backdoors
   - Review logs for indicators of compromise

## Alternate/Fallback Method
Failover to Secondary DC replica; rebuild primary later

### Steps

1. **Immediately fail to secondary DC**
   - See "Primary DC power/cooling outage" runbook
   - Promote secondary to primary
   - Verify secondary is clean

2. **Operate from secondary DC**
   - Full production operations
   - Monitor for any signs of infection spreading
   - Enhanced security monitoring

3. **Rebuild primary DC offline**
   - Take time to do it right
   - Full security audit
   - Penetration testing
   - Security training for team

## Recovery Targets
- **RTO**: 2-8 hours (service via secondary)
- **RPO**: 30-120 seconds (replication lag)
- **MTTR**: 1-3 days (full infra rebuild)

## Expected Data Loss
Seconds → minutes (at failover)

## Affected Components
- VMware hosts
- Storage systems
- Kubernetes nodes
- Database
- All infrastructure in primary DC

## Assumptions & Prerequisites
- Immutable backups exist
- Off-site copies available
- Secondary DC unaffected
- Tested DC failover runbooks
- Cyber insurance in place
- Incident response plan documented

## Verification Steps

1. **Verify systems are clean**
   - Run full antivirus/EDR scans
   - Check for persistence mechanisms
   - Review startup scripts and cron jobs
   - Verify no unauthorized users/processes

2. **Test restored database**
   ```bash
   # Verify database integrity
   mysqlcheck -uroot -p<pass> --all-databases --check
   
   # Check for suspicious stored procedures or triggers
   mysql -uroot -p<pass> -e "SELECT * FROM information_schema.ROUTINES;"
   
   # Test critical queries
   mysql -uroot -p<pass> -e "SELECT COUNT(*) FROM <critical_table>;"
   ```

3. **Security validation**
   - Penetration testing
   - Vulnerability scanning
   - Security audit
   - Review access logs

4. **Monitor for reinfection**
   - Enhanced logging
   - Continuous EDR monitoring
   - Network traffic analysis
   - User behavior analytics

## Rollback Procedure
N/A - Cannot rollback from ransomware. Must rebuild clean.

## Post-Recovery Actions

1. **Complete security audit**
   - How did attackers get in?
   - What was the attack timeline?
   - What data was exfiltrated?
   - Were any backdoors planted?

2. **Implement security improvements**
   - Immutable backups
   - Air-gapped backup copies
   - Zero-trust network architecture
   - Enhanced EDR/XDR
   - Security Information and Event Management (SIEM)

3. **Update incident response plan**
   - Document what worked/didn't work
   - Update runbooks
   - Schedule regular incident response drills
   - Train team on ransomware response

4. **Legal and compliance**
   - Notify affected parties (if data breach)
   - Report to regulators (if required)
   - Work with law enforcement
   - Review insurance claims

5. **User security training**
   - Phishing awareness
   - Password hygiene
   - MFA enforcement
   - Suspicious activity reporting

6. **Technical hardening**
   - Implement application whitelisting
   - Disable unnecessary services
   - Segment networks
   - Implement least privilege access
   - Enable audit logging everywhere

7. **Regular testing**
   - Quarterly incident response drills
   - Penetration testing
   - Backup restore testing
   - Security awareness training

## Prevention for Future

- **Immutable backups** - Cannot be encrypted by ransomware
- **Offline backups** - Air-gapped from network
- **Multi-factor authentication** - On all accounts
- **Least privilege** - Minimal permissions
- **Network segmentation** - Limit lateral movement
- **EDR/XDR** - Advanced threat detection
- **Security training** - Regular user training
- **Patch management** - Keep systems updated
- **Incident response plan** - Tested and ready

## Related Scenarios
- Primary DC power/cooling outage
- Credential compromise
- Kubernetes control plane outage
- S3 backup target unavailable
