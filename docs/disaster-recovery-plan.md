# Data Platform Disaster Recovery Plan

---

| Field | Value |
|---|---|
| **Document Title** | Data Platform Disaster Recovery Plan |
| **Document ID** | DR-PLN-001 |
| **Version** | 1.0 |
| **Classification** | Internal — Restricted |
| **Owner** | Infrastructure & Platform Engineering |
| **Prepared By** | Craig Glendenning |
| **Review Cycle** | Annually or after any declared disaster event |
| **Applicable Frameworks** | CFIUS National Security Review; CAB Certificate Management Forum |
| **Last Reviewed** | 2026-06-02 |
| **Next Review Due** | 2027-06-02 |

---

## Approvals

| Role | Name | Signature | Date |
|---|---|---|---|
| Platform Engineering Lead | | | |
| Chief Information Security Officer | | | |
| Change Advisory Board Chair | | | |
| Data Protection Officer | | | |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Purpose, Scope, and Applicability](#2-purpose-scope-and-applicability)
3. [Definitions and Abbreviations](#3-definitions-and-abbreviations)
4. [System Overview and Architecture](#4-system-overview-and-architecture)
5. [Recovery Objectives Framework](#5-recovery-objectives-framework)
6. [Backup and Data Protection Strategy](#6-backup-and-data-protection-strategy)
7. [Certificate Management and Lifecycle](#7-certificate-management-and-lifecycle)
8. [Disaster Recovery Scenarios](#8-disaster-recovery-scenarios)
9. [DR Emergency Response Dashboard](#9-dr-emergency-response-dashboard)
10. [Automated Testing and Validation](#10-automated-testing-and-validation)
11. [Roles, Responsibilities, and Escalation](#11-roles-responsibilities-and-escalation)
12. [Plan Maintenance and Governance](#12-plan-maintenance-and-governance)
13. [Compliance Considerations](#13-compliance-considerations)
14. [Appendix A — Platform Capabilities Inventory](#appendix-a--platform-capabilities-inventory)
15. [Appendix B — Backup Schedule and Retention Matrix](#appendix-b--backup-schedule-and-retention-matrix)
16. [Appendix C — Scenario Risk Register](#appendix-c--scenario-risk-register)
17. [Appendix D — Certificate Inventory and Lifecycle Register](#appendix-d--certificate-inventory-and-lifecycle-register)

---

## 1. Executive Summary

This document constitutes the formal Disaster Recovery Plan (DRP) for the organization's data platform, which provides managed relational database services on both Amazon Web Services Elastic Kubernetes Service (EKS) and on-premises Kubernetes infrastructure. The platform is built on Percona XtraDB Cluster (PXC), a synchronous multi-primary MySQL-compatible database engine deployed and managed via the Percona Kubernetes Operator, and is supported by SeaweedFS-based S3-compatible object storage for backup retention.

The data platform is designed to meet rigorous availability and data-integrity requirements across two distinct deployment environments: a cloud-native EKS topology with multi-availability-zone anti-affinity, and an on-premises topology spanning primary and secondary data centers with asynchronous replication to DR sites. This document describes, in detail, the recovery architecture, backup strategy, point-in-time recovery capabilities, certificate management practices, the full catalog of identified disaster scenarios with their associated recovery time and recovery point objectives, the automated and manual testing regimes that validate those objectives, and the governance processes that keep this plan current.

This plan has been written to satisfy three distinct readership requirements:

- **Auditors and compliance reviewers**, including those operating under CFIUS national security review mandates, require assurance that data is protected at rest and in transit, that access to sensitive infrastructure is controlled and logged, that backup assets are protected and geographically distributed, and that the organization can demonstrate tested, operationally effective recovery procedures.
- **The Certificate Advisory Board (CAB)** requires a clear accounting of the certificate infrastructure underpinning the platform's service mesh, the processes by which certificates are issued, rotated, and revoked, and the documented DR procedure for certificate-related service outages.
- **Incident responders and on-call engineers** require actionable, step-by-step runbooks accessible under crisis conditions.

All three audiences will find their respective requirements addressed herein. The DR Emergency Response Dashboard—a lightweight web application deployed to each environment—provides incident responders with immediate access to every runbook in this document, sorted by business impact, without requiring access to version control or documentation systems that may themselves be unavailable during an incident.

Key risk posture summary:

- **Zero data loss** is achievable for the majority of failure scenarios due to synchronous Galera replication within the PXC cluster.
- **Point-in-time recovery** to within 60 seconds of any transaction is operational via continuous binary log uploads to MinIO-backed S3 storage.
- **Full datacenter loss** is recoverable within 30 minutes with up to 60 seconds of data loss, contingent on the health of the asynchronous DR replica.
- **Critical scenarios** (ransomware, accidental restore) have RTOs between 4–8 hours and documented runbooks.
- **Certificate failures** carry a 45-minute RTO with a tested rotation procedure managed under CAB governance.

---

## 2. Purpose, Scope, and Applicability

### 2.1 Purpose

This Disaster Recovery Plan establishes the formal policy, procedures, and technical controls that govern the organization's response to any event that materially impairs the availability, integrity, or confidentiality of the data platform. It defines recovery objectives, assigns responsibilities, documents tested recovery procedures, and provides the evidence base that regulators, auditors, and governance bodies require to assess the organization's operational resilience.

### 2.2 Scope

This plan applies to all components of the data platform, defined as the set of infrastructure, software, and operational processes that collectively provide managed relational database services. Specifically, this plan covers:

- **Percona XtraDB Cluster (PXC)** instances deployed in all environments, including primary production clusters, read replicas, and asynchronous DR replicas.
- **HAProxy and ProxySQL** load-balancing and connection-routing tiers.
- **MinIO object storage** used as the backup target for all database backup operations.
- **SeaweedFS Filer** instances providing POSIX-compatible file semantics over object storage, including asynchronous replication controllers at both DR sites.
- **Kubernetes control planes** (EKS and on-premises) on which the above workloads run.
- **Percona Kubernetes Operator** managing the lifecycle of all PXC cluster resources.
- **Istio service mesh** providing mutual TLS (mTLS) between all cluster services, including certificate infrastructure.
- **Percona Monitoring and Management (PMM)** providing observability, alerting, and the Kubernetes monitoring stack (Victoria Metrics, kube-state-metrics).
- **The DR Emergency Response Dashboard** web application.
- **Fleet/Rancher GitOps pipeline** used for declarative configuration management.

This plan does not cover application-layer software (i.e., services consuming the database), network infrastructure outside the Kubernetes cluster boundary, or general IT disaster recovery for non-data-platform systems.

### 2.3 Applicability

This document is applicable to:

- All engineering personnel with operational responsibility for the data platform.
- The Security Operations team and any third-party managed security service provider with access to platform infrastructure.
- The Change Advisory Board (CAB) with respect to certificate management changes.
- External auditors, regulators, and reviewers operating under CFIUS, SOC 2, ISO 27001, or equivalent frameworks who require evidence of operational resilience controls.

---

## 3. Definitions and Abbreviations

| Term | Definition |
|---|---|
| **CAB** | Change Advisory Board. The governance body that reviews and approves changes to production systems, including certificate rotation. |
| **CFIUS** | Committee on Foreign Investment in the United States. A federal interagency committee that reviews certain foreign investments for national security implications. |
| **DR** | Disaster Recovery. The set of policies, tools, and procedures to enable the recovery of technology infrastructure after a disaster. |
| **DRP** | Disaster Recovery Plan. This document. |
| **EKS** | Elastic Kubernetes Service. Amazon Web Services' managed Kubernetes offering. |
| **Galera** | The synchronous multi-primary replication library used by Percona XtraDB Cluster. |
| **GitOps** | An operational model using Git as the single source of truth for declarative infrastructure configuration, with automated reconciliation. |
| **HAProxy** | High Availability Proxy. The TCP/HTTP load balancer used to route client connections to PXC. |
| **IST** | Incremental State Transfer. The preferred PXC method for re-syncing a node with a short gap, using the joiner's local data. |
| **Istio** | An open-source service mesh providing mutual TLS, traffic management, and observability between cluster services. |
| **MinIO** | An S3-compatible object storage server deployed on-premises as the backup target. |
| **MTTR** | Mean Time To Recovery. The expected elapsed time from incident detection to full service restoration. |
| **mTLS** | Mutual TLS. A protocol in which both client and server authenticate each other using X.509 certificates. |
| **Nix** | A purely functional package manager and build system used for declarative, reproducible infrastructure configuration in this platform. |
| **PITR** | Point-in-Time Recovery. The ability to restore a database to its state at any arbitrary moment in the past, by replaying binary logs on top of a backup. |
| **PMM** | Percona Monitoring and Management. The observability platform used for database and Kubernetes metrics, alerting, and dashboards. |
| **ProxySQL** | An advanced MySQL proxy providing connection multiplexing and query routing. |
| **PVC** | PersistentVolumeClaim. A Kubernetes resource representing a request for durable storage. |
| **PXC** | Percona XtraDB Cluster. A fully open-source, enterprise-class MySQL cluster solution. |
| **RPO** | Recovery Point Objective. The maximum tolerable amount of data loss measured in time. An RPO of 60 seconds means the organization accepts losing at most 60 seconds of committed transactions. |
| **RTO** | Recovery Time Objective. The maximum tolerable duration of a service outage. An RTO of 30 minutes means service must be restored within 30 minutes of a declared disaster. |
| **SeaweedFS** | A distributed file system and object store providing POSIX and S3 APIs, used for blob storage and backup replication. |
| **SIEM** | Security Information and Event Management. A system that aggregates and correlates log data for security monitoring. |
| **SST** | State Snapshot Transfer. The PXC fallback for re-syncing a node when IST is not possible; involves transferring the full dataset from a donor node. |
| **SSO** | Single Sign-On. |
| **Victoria Metrics** | A high-performance time-series database and monitoring solution used as the metrics backend for PMM. |
| **wsrep** | Write-Set Replication. The Galera protocol underlying PXC synchronous replication. |

---

## 4. System Overview and Architecture

### 4.1 Platform Overview

The data platform provides relational database-as-a-service capabilities to consuming applications across two deployment environments. Both environments run identically structured Percona XtraDB Cluster topologies, managed via the Percona Kubernetes Operator, and both are connected to MinIO-backed backup infrastructure. The platform is designed to operate with no single point of failure at the database tier and to provide continuous data protection through a combination of synchronous in-cluster replication and asynchronous cross-site replication.

The declarative configuration for all platform components is maintained in a version-controlled Git repository and applied via the Rancher Fleet GitOps pipeline. All changes to infrastructure, including certificate rotations, pass through this pipeline and are subject to the organization's change management process.

### 4.2 Deployment Topology

The platform operates across two distinct deployment targets:

**Cloud (EKS) Topology**

The EKS deployment spans three AWS availability zones within a single AWS region. Each PXC node is scheduled to a distinct availability zone via Kubernetes topology spread constraints and required pod anti-affinity rules. Persistent volumes are provisioned using the `gp3` storage class (AWS EBS). HAProxy provides both a read-only round-robin endpoint and a single logical write endpoint. MinIO is co-deployed within the cluster to provide S3-compatible backup storage.

**On-Premises Topology**

The on-premises deployment runs on VMware-hosted Kubernetes nodes managed by Rancher. The primary data center hosts the active PXC cluster. Two asynchronous DR replicas are maintained: `dr-std` (standard DR site) and `dr-sec` (secondary DR site), providing geographic and regulatory separation. SeaweedFS Filer instances provide POSIX-compatible object storage per cluster, with asynchronous replication controllers maintaining state between primary and DR sites.

### 4.3 Multi-Cluster Service Mesh

All inter-service communication within and between clusters is protected by Istio mutual TLS (mTLS). In multi-cluster configurations, an East-West Gateway bridges cluster networks, enabling services in `cluster-a` (primary, `network1`) and `cluster-b` (DR, `network2`) to communicate securely across cluster boundaries without exposing plain-text traffic. The Istio control plane (`istiod`) manages certificate issuance and rotation for all service identities.

The DR cluster (`cluster-b`) is configured with:

- **Mesh ID**: `mesh1` (shared across all clusters in the mesh)
- **Cluster Name**: `cluster-b`
- **Network**: `network2`
- **East-West Gateway Ports**: 15021 (health), 15443 (TLS), 15012 (istiod), 15017 (webhook)

### 4.4 Monitoring and Observability

The platform is monitored by Percona Monitoring and Management (PMM) deployed in the `pmm` namespace. PMM ingests metrics from:

- **Percona PMM Client** agents on each PXC node, providing database-level metrics, query analytics, and replication lag monitoring.
- **Victoria Metrics Kubernetes stack** (`kube-state-metrics` with custom resource state configuration), scraping Kubernetes operator custom resources (PXC clusters, backups, restores) and remote-writing to PMM's VictoriaMetrics storage.
- **vmagent** collecting Kubernetes infrastructure metrics and forwarding them to PMM.

The `kube-state-metrics` custom resource state configuration exposes the following metric families to PMM:

| Metric Prefix | Resource Kind | Example Metrics |
|---|---|---|
| `kube_pxc_` | PerconaXtraDBCluster | `kube_pxc_status_state`, `kube_pxc_pitr_enabled` |
| `kube_pxc_backup_` | PerconaXtraDBClusterBackup | `kube_pxc_backup_status_state`, `kube_pxc_backup_status_completed` |
| `kube_pxc_restore_` | PerconaXtraDBClusterRestore | `kube_pxc_restore_status_state`, `kube_pxc_restore_status_completed` |
| `kube_psmdb_` | PerconaServerMongoDB | `kube_psmdb_status_state`, `kube_psmdb_pitr_enabled` |
| `kube_psmdb_backup_` | PerconaServerMongoDBBackup | `kube_psmdb_backup_status_state`, `kube_psmdb_backup_status_completed` |
| `kube_pg_backup_` | PerconaPGBackup | `kube_pg_backup_status_state` |

Each metric series carries a `k8s_cluster_id` external label identifying the originating Kubernetes cluster, enabling a single PMM instance to correlate backup and cluster state across all managed clusters.

Alerting rules provisioned in PMM include:

- MySQL instance down (critical severity)
- No MySQL instances monitored (indicates monitoring pipeline failure)
- PXC backup stale — no successful backup in 30 hours

---

## 5. Recovery Objectives Framework

### 5.1 Classification of Events

Disaster events are classified by business impact:

| Impact Level | Definition | Examples |
|---|---|---|
| **Low** | Degraded or unavailable non-critical function; no data loss; no customer-visible outage | Single pod failure with immediate self-healing |
| **Medium** | Partial service degradation or brief customer-visible impact; limited data loss risk | Worker node failure; replication lag |
| **High** | Significant service impairment or risk of data loss; material customer impact | Quorum loss; credential compromise; DDL blocks |
| **Critical** | Complete service loss or confirmed data loss; potential regulatory notification required | Primary DC down; ransomware; accidental restore |

### 5.2 Recovery Objective Targets by Impact Level

The following table summarizes the recovery objective targets adopted by this plan. Individual scenario-specific targets may be more aggressive than these baselines; see Section 8 for per-scenario detail.

| Impact Level | Target RTO | Target RPO | Backup Tier Required |
|---|---|---|---|
| Low | ≤ 10 minutes | 0 | In-cluster replication |
| Medium | ≤ 60 minutes | ≤ 5 minutes | PITR-capable |
| High | ≤ 4 hours | ≤ 15 minutes | Full backup + PITR |
| Critical | ≤ 8 hours | ≤ 120 seconds | Async replica or full backup |

### 5.3 Data Loss Tolerance

The platform's baseline commitment is **zero data loss** for any scenario in which the PXC cluster maintains quorum. Galera's synchronous certification protocol ensures that a transaction is not acknowledged to the client until it has been applied to a write-set on a quorum of nodes. Data loss scenarios are limited to:

1. **Partial quorum events**: up to a small number of unflushed transactions in-flight at the moment of failure.
2. **Async replica failover**: up to the replication lag at the moment of DC failure (typically ≤ 60 seconds under normal load).
3. **Logical data loss** (DROP/DELETE/TRUNCATE): bounded by the PITR RPO, which is 5 minutes given the 60-second binary log upload interval and the time required to identify the incident.

---

## 6. Backup and Data Protection Strategy

### 6.1 Backup Architecture

All database backups are performed by the Percona Backup for MySQL (PBM) subsystem, orchestrated by the Percona Kubernetes Operator. Backups are written to MinIO, an S3-compatible object storage server deployed at `http://minio.minio.svc.cluster.local:9000`. Backup credentials are managed as Kubernetes Secrets (`percona-backup-minio-credentials`) and are rotated through the Fleet GitOps pipeline.

The backup target is the `percona-backups` bucket within MinIO. Cross-DC MinIO replication is configured to ensure backup artifacts are available at the DR site independently of the primary DC.

### 6.2 Backup Schedule and Retention

The following scheduled backup jobs are configured on all PXC clusters:

| Backup Type | Schedule (Cron) | Retention | Notes |
|---|---|---|---|
| Binlog (PITR) | Continuous | 7 days | 60-second upload interval; required for sub-minute RPO |
| Daily full | `0 2 * * *` (02:00 daily) | 7 days | Physical backup via xtrabackup |
| Weekly full | `0 1 * * 0` (01:00 Sunday) | 8 weeks | Physical backup |
| Monthly full | `30 1 1 * *` (01:30, 1st of month) | 12 months | Physical backup; compliance retention |

The 12-month monthly backup retention satisfies most statutory data retention obligations. Adjust retention periods for specific regulatory requirements (e.g., GDPR right-to-erasure, HIPAA, SOX) in coordination with the Data Protection Officer.

### 6.3 Point-in-Time Recovery (PITR)

PITR is enabled on all production PXC clusters (`backup.pitr.enabled: true`). Binary logs are uploaded to MinIO at 60-second intervals. This means the effective RPO for PITR is approximately 60–120 seconds in the worst case (one upload cycle missed plus detection latency).

PITR restoration is performed using the `pxc-restore` tooling, which provides:

- An interactive CLI that lists all available backups in a source namespace with earliest and latest restorable timestamps.
- Automatic clone of cluster configuration to a target namespace (enabling side-by-side restore without impacting the production cluster).
- Dry-run validation mode to confirm restore parameters before execution.
- Integration with the SeaweedFS Filer HTTP API for binlog retrieval.
- A `pitr-timestamp-finder` utility that scans binary logs to locate the exact transaction timestamp immediately prior to a DROP, DELETE, or TRUNCATE event—critical for recovering from accidental data loss without over-restoring.

**Example PITR restore (Kubernetes CR):**

```yaml
apiVersion: pxc.percona.com/v1
kind: PerconaXtraDBClusterRestore
metadata:
  name: pxc-restore-pitr
spec:
  pxcCluster: pxc-cluster
  backupName: latest
  pitr:
    type: date
    date: "2026-05-15T14:30:00Z"
```

### 6.4 Backup Validation

Silent backup failures—where backup jobs report success but the artifact is corrupt or incomplete—represent a latent risk. The following controls mitigate this risk:

- **Scheduled restore drills**: The testing framework includes automated and manual restore exercises. Results are tracked and any failure triggers an immediate P1 incident.
- **Checksum verification**: Backup manifests include checksums verified at restore time.
- **PMM alerting**: The `PXC Backup Stale Critical` alert fires when no successful backup has been recorded in the `kube_pxc_backup_status_completed` metric within a 30-hour window, providing early warning of pipeline failures before the retention window is at risk.
- **Backup count monitoring**: Automated checks verify that the expected number of backup artifacts exist in MinIO, catching premature deletion by lifecycle policy errors.

### 6.5 Data at Rest and in Transit

- **Encryption at rest**: Backup artifacts in MinIO are encrypted. EBS volumes used by EKS PVCs are encrypted using AWS KMS. On-premises PVCs use encrypted storage volumes as configured by the infrastructure team.
- **Encryption in transit**: All traffic between PXC nodes uses SSL/TLS. All traffic between cluster services uses Istio mTLS. MinIO API traffic is over HTTPS within the cluster network.
- **Credential management**: All secrets (backup credentials, PMM tokens, database user credentials) are managed as Kubernetes Secrets, populated via the Fleet GitOps pipeline, and subject to the organization's secret rotation policy.

---

## 7. Certificate Management and Lifecycle

This section is addressed specifically to the Certificate Advisory Board (CAB) and to auditors requiring evidence of certificate lifecycle controls.

### 7.1 Certificate Infrastructure Overview

The platform uses two distinct certificate authorities:

**Istio Service Mesh CA**

The Istio control plane (`istiod`) operates as an intermediate certificate authority for the service mesh. It issues short-lived X.509 certificates (SVIDs) to every workload within the mesh, enabling mutual TLS between all services. These certificates are automatically rotated by Istio without service interruption.

The root certificate and intermediate CA are generated at cluster bootstrap using the `generate-ca-certs` script and stored in the `cacerts` Kubernetes Secret in the `istio-system` namespace. The certificate files are:

| File | Purpose |
|---|---|
| `ca-cert.pem` | Intermediate CA certificate (cluster-specific) |
| `root-cert.pem` | Shared root certificate across all clusters in the mesh |
| `cert-chain.pem` | Full certificate chain |
| `ca-key.pem` | CA private key (stored as Kubernetes Secret, not in Git) |

Root certificate fingerprints are verified with: `openssl x509 -in root-cert.pem -noout -fingerprint -sha256`

**Kubernetes Ingress / Application Certificates**

TLS certificates for ingress endpoints (e.g., PMM, the DR Dashboard) are managed via Traefik's certificate provisioning on on-premises environments and via AWS Certificate Manager (ACM) on EKS.

### 7.2 Certificate Inventory

The following table constitutes the Certificate Inventory Register. It should be reviewed and updated at each CAB certificate management forum. Full detail is in Appendix D.

| Certificate | Issuer | Scope | Rotation Method | Review Owner |
|---|---|---|---|---|
| Istio Root CA | Self-signed (bootstrap) | All mesh clusters | Manual (CAB approval required) | Platform Engineering |
| Cluster-B Intermediate CA | Istio Root CA | cluster-b mesh identity | Manual (CAB approval required) | Platform Engineering |
| Istio workload SVIDs | Cluster intermediate CA | Per-service identity | Automatic (istiod, ~24h TTL) | Istio (automated) |
| Ingress TLS (on-prem) | Traefik / self-signed | Cluster ingress endpoints | Manual or cert-manager | Platform Engineering |
| Ingress TLS (EKS) | AWS ACM | EKS ingress endpoints | AWS-managed auto-renewal | Platform Engineering / AWS |
| MySQL TLS (PXC-internal) | Percona Operator | PXC node-to-node and client TLS | Operator-managed | Percona Operator |

### 7.3 Certificate Rotation Procedures

**Routine Rotation (automated)**

Istio workload SVIDs are rotated automatically by `istiod` with a default TTL of approximately 24 hours. No CAB approval is required for routine SVID rotation.

**Root CA Rotation (CAB-gated)**

Root CA and intermediate CA rotation is a significant change that can affect all mesh-connected services if not coordinated correctly. The following procedure applies:

1. **CAB Change Request submission** at least 5 business days prior to planned rotation.
2. **Generate new root CA certificate** using the `generate-ca-certs` script in a test environment and validate cross-cluster connectivity.
3. **Dual-root transition period**: Istio supports a transitional period during which both the old and new root certificates are trusted. This must be used to avoid breaking existing connections.
4. **Apply new `cacerts` secret** to all clusters via Fleet GitOps commit, reviewed and approved in CAB.
5. **Monitor mTLS handshake errors** in PMM/Kiali during the 24–48 hour transition window.
6. **Remove old root from trust bundle** once all workload certificates have been re-issued.
7. **Update Certificate Inventory Register** (Appendix D) and close the CAB change record.

**Emergency Certificate Rotation**

In the event of a suspected key compromise or CA failure, an emergency rotation bypasses the standard 5-day lead time but still requires documented CAB approval (emergency change record) within 24 hours of execution. The recovery procedure is documented in the DR scenario in Section 8 and in the runbook accessible via the DR Dashboard.

### 7.4 Certificate Expiry Monitoring

- PMM alerting is configured to fire on SSL/TLS handshake failures detected at the application layer.
- The DR Dashboard scenario catalog includes `certificate-expiration-or-revocation-causing-connection-failures` as a trackable event with a 45-minute RTO.
- Certificate expiry dates for all manually managed certificates must be recorded in the Certificate Inventory Register (Appendix D) with a minimum 30-day advance renewal reminder.

---

## 8. Disaster Recovery Scenarios

This section catalogs every identified disaster recovery scenario for the data platform. Each scenario has been assessed for likelihood, business impact, recovery time objective, and recovery point objective. Detailed step-by-step runbooks for each scenario are available in the DR Emergency Response Dashboard (Section 9) and in the `dr-dashboard/recovery_processes/` directory of the platform repository.

Scenarios are ordered from highest to lowest business impact.

### 8.1 Scenario Summary Matrix

The following matrix provides a consolidated view of all 35 catalogued scenarios. A detailed narrative for each follows in Section 8.2.

| # | Scenario | Impact | Likelihood | RTO | RPO | MTTR | Automated Test |
|---|---|---|---|---|---|---|---|
| 1 | Ransomware attack on VMware hosts / storage | Critical | Low | 8 hours | 120 sec | 1–3 days | No |
| 2 | Primary data center is down | Critical | Low | 30 minutes | 60 seconds | 3 days | No |
| 3 | Accidental production restore from wrong backup | Critical | Low | 4 hours | 15 minutes | 4–12 hours | No |
| 4 | Schema change or DDL blocks writes | High | Medium | 30 minutes | 0 | 15–60 min | Yes |
| 5 | Cluster loses quorum (multiple PXC pods down) | High | Low | 90 minutes | 60 seconds | 1–3 hours | No |
| 6 | Accidental DROP/DELETE/TRUNCATE | High | Medium | 4 hours | 5 minutes | 2–8 hours | No |
| 7 | Widespread data corruption (bad migration/script) | High | Low | 6 hours | 15 minutes | 4–12 hours | No |
| 8 | Application change causes data corruption | High | Medium | 8 hours | 24 hours | 8–24 hours | No |
| 9 | HAProxy endpoints inaccessible | High | Medium | 30 minutes | 0 | 30–60 min | Yes |
| 10 | Credential compromise (DB or MinIO keys) | High | Medium | 120 minutes | 15 minutes | 2–8 hours | No |
| 11 | Certificate expiration or revocation | High | Medium | 45 minutes | 0 | 30–90 min | No |
| 12 | Database disk space exhaustion | High | Medium | 30 minutes | 0 | 30–60 min | No |
| 13 | Connection pool exhaustion (max_connections) | High | Medium | 15 minutes | 0 | 15–30 min | No |
| 14 | Memory exhaustion causing OOM kills | High | Medium | 20 minutes | 0 | 20–60 min | No |
| 15 | DNS resolution failure | High | Medium | 30 minutes | 0 | 30–60 min | No |
| 16 | Network policy misconfiguration blocking DB access | High | Medium | 30 minutes | 0 | 20–60 min | No |
| 17 | Increased API call volume / performance degradation | High | Medium | 60 minutes | 0 | 1–3 hours | No |
| 18 | Application change causes performance degradation | High | Medium | 45 minutes | 0 | 30–90 min | No |
| 19 | Encryption key rotation failure | High | Low | 90 minutes | 0 | 1–4 hours | No |
| 20 | Clock skew between nodes causing replication issues | High | Low | 60 minutes | 0 | 30–120 min | No |
| 21 | Application causing excessive replication lag | Medium | Medium | 4 hours | 0 | 2–8 hours | No |
| 22 | Kubernetes worker node failure (VM host crash) | Medium | Medium | 20 minutes | 0 | 30–60 min | Yes |
| 23 | Percona Operator / CRD misconfiguration | Medium | Medium | 45 minutes | 0 | 30–90 min | Yes |
| 24 | Kubernetes control plane outage (API server down) | Medium | Low | 90 minutes | 0 | 1–3 hours | No |
| 25 | Storage PVC corruption for a single PXC node | Medium | Low | 3 hours | 5 minutes | 2–6 hours | No |
| 26 | Primary DC network partition from secondary (WAN cut) | Medium | Medium | 0 (no failover) | N/A | 30–120 min | No |
| 27 | Both DCs up but replication stops (broken channel) | Medium | Medium | 60 minutes | 0 | 30–120 min | No |
| 28 | MinIO backup target unavailable (outage or cred issue) | Medium | Medium | 0 (runtime OK) | N/A | 1–3 hours | No |
| 29 | MinIO service failure | Medium | Medium | 0 (runtime OK) | N/A | 30–90 min | No |
| 30 | Monitoring and alerting system failure | Medium | Medium | N/A | N/A | 30–120 min | No |
| 31 | Temporary tablespace exhaustion | Medium | Medium | 15 minutes | 0 | 15–30 min | No |
| 32 | Single PXC or HAProxy pod failure | Low | Medium | 2 minutes | 0 | 10–20 min | Yes |
| 33 | Backups complete but non-restorable (silent failure) | High | Low | 4 hours | 15 minutes | 4–12 hours | No |
| 34 | Backup retention policy failure (premature deletion) | Low | Low | 4 hours | 15 minutes | 4–12 hours | No |
| 35 | Audit log corruption or loss (compliance violation) | Low | Low | 2 hours | 0 | 2–8 hours | No |

### 8.2 Scenario Detail Narratives

The following subsections provide formal narrative descriptions of each scenario, organized by business impact tier.

---

#### 8.2.1 Critical Impact Scenarios

**Scenario 1: Ransomware Attack on VMware Hosts / Storage**

*Nature of Event:* A ransomware attack encrypts VMware host filesystems and/or shared storage, rendering all Kubernetes nodes and their persistent volumes inaccessible or corrupted. This is the highest-severity scenario in the catalog.

*Detection Signals:* Endpoint detection and response (EDR) system alerts; cryptographic file activity on hosts; sudden filesystem access errors; monitoring observes mass pod failures.

*Recovery Approach:* Immediately isolate affected hosts from the network. Do not attempt to decrypt or restore in place—rebuild clean. Activate the DR replica site (`dr-std`). Promote the `dr-std` async PXC replica to primary. Redirect application traffic via DNS/ingress change. Rebuild primary infrastructure from clean OS images using the Fleet GitOps pipeline. Restore primary site from immutable MinIO backup copies held at the secondary site.

*Key Dependencies:* Immutable (write-once) backup copies at the DR site; off-site copies of critical secrets; tested DC failover runbooks; GitOps repository accessible from clean infrastructure.

*RTO: 8 hours | RPO: 120 seconds | MTTR: 1–3 days*

---

**Scenario 2: Primary Data Center is Down**

*Nature of Event:* Complete loss of primary data center availability—power outage, catastrophic cooling failure, regional event (flood, earthquake), or extended utility outage.

*Detection Signals:* Out-of-band monitoring alerts; all primary cluster nodes unreachable; site-level monitoring shows red; alert from data center operations team.

*Recovery Approach:* Promote the `dr-std` secondary DC async PXC replica to primary. This involves pausing writes briefly during role promotion, confirming the replica is current, and switching DNS/ingress to point to the secondary DC HAProxy endpoint. Application teams are notified of the VIP change and verify connectivity.

*Key Dependencies:* Async replication lag must be acceptable (target ≤ 60 seconds); `dr-std` site must be warm and operational; ingress/DNS switchover runbook must be current; app configuration must be documented for quick re-pointing.

*RTO: 30 minutes | RPO: 60 seconds | MTTR: 3 days (for primary rebuild)*

---

**Scenario 3: Accidental Production Restore from Wrong Backup or Point in Time**

*Nature of Event:* An operator restores production data from an incorrect backup or to a wrong point in time, overwriting current production state with stale data.

*Detection Signals:* Application errors reporting missing data; business users report unexpected data state; audit logs show a `PerconaXtraDBClusterRestore` resource was applied; timestamp mismatches in records.

*Recovery Approach:* Immediately halt any in-progress restore. Identify the actual correct backup target and point-in-time using the `pitr-timestamp-finder` tool and audit logs. Use PITR to restore to the correct state on a side namespace without affecting the live cluster further. Validate data integrity before cutting over. Document the incident for compliance review.

*Key Dependencies:* Audit logs capturing restore operations; correct backup artifacts available; PITR capability operational; side-namespace restore tooling (`pxc-restore`) available.

*RTO: 4 hours | RPO: 15 minutes | MTTR: 4–12 hours*

---

#### 8.2.2 High Impact Scenarios

**Scenario 4: Schema Change or DDL Blocks Writes**

*Nature of Event:* A DDL operation (ALTER TABLE, CREATE INDEX) holds a metadata lock and prevents all subsequent writes, causing application-level timeouts and write failures.

*Detection Signals:* "Waiting for table metadata lock" errors in slow query log; write latency spikes; application timeout alerts; PMM query analytics shows DDL blocked.

*Recovery Approach:* Identify the blocking DDL process via PMM or `SHOW PROCESSLIST`. If safe to kill (i.e., the DDL can be cleanly re-run), kill the process and allow queued writes to proceed. If the DDL is near completion, allow it to finish. If data was corrupted by a partial DDL, execute a PITR restore to the pre-DDL timestamp.

*Test Status:* Automated test available (`test_dr_schema_change_or_ddl_blocks_writes.py`).

*RTO: 30 minutes | RPO: 0 | MTTR: 15–60 minutes*

---

**Scenario 5: Cluster Loses Quorum (Multiple PXC Pods Down)**

*Nature of Event:* Simultaneous failure of two or more PXC nodes causes the cluster to lose Galera quorum. All write operations are refused; the cluster enters `non-Primary` state.

*Detection Signals:* `wsrep_cluster_status = non-Primary`; write failures returning errors; HAProxy/ProxySQL backends unavailable; PMM `kube_pxc_status_state` shows non-ready.

*Recovery Approach:* Identify the node with the highest Galera sequence number (`wsrep_last_committed`). Bootstrap the cluster from that node by setting `wsrep_new_cluster` and restarting. Re-join remaining nodes. Verify quorum is restored and write path is functional. If bootstrap fails, promote `dr-std` replica to primary.

*Key Dependencies:* Access to node bootstrap procedure; Galera sequence number accessible on at least one surviving node; careful execution—incorrect bootstrap choice causes data divergence.

*RTO: 90 minutes | RPO: 60 seconds | MTTR: 1–3 hours*

---

**Scenario 6: Accidental DROP/DELETE/TRUNCATE**

*Nature of Event:* An operator or application accidentally executes a destructive SQL statement, deleting tables, rows, or truncating critical data.

*Detection Signals:* Application errors reporting missing data; sudden drop in table row counts detected by monitoring; size reduction in database alerting; user reports.

*Recovery Approach:* Immediately identify the approximate timestamp of the destructive operation using the `pitr-timestamp-finder` tool, which scans binary logs to locate the exact transaction boundary. Perform PITR to a timestamp 1 transaction prior to the destructive statement on a side namespace. Selectively export the recovered data using `mysqldump`/`mydumper` and re-import into production, or execute a full cutover if the scope of loss is large.

*Key Dependencies:* PITR operational; binary log retention intact; `pitr-timestamp-finder` tool available; side-namespace restore capacity.

*RTO: 4 hours | RPO: 5 minutes | MTTR: 2–8 hours*

---

**Scenario 7: Widespread Data Corruption (Bad Migration / Script)**

*Nature of Event:* An automated migration script or manual data fix introduces systematic corruption across a significant portion of the dataset—wrong column values, referential integrity violations, or logically incorrect data.

*Detection Signals:* Application integrity checks fail; anomaly detection rules trigger; post-deploy incident volume spikes; business-layer data validation reports failures.

*Recovery Approach:* Identify the timestamp of the migration or script execution. Use the `pitr-timestamp-finder` to pinpoint the exact transaction. Execute PITR to the pre-migration state on a clean environment. Validate data. If the migration is logically reversible, apply a compensating migration from the audit trail rather than performing a full restore.

*Key Dependencies:* Strict change windows with mandatory backup verification prior to migrations; PITR operational; compensating migration scripts if available.

*RTO: 6 hours | RPO: 15 minutes | MTTR: 4–12 hours*

---

**Scenario 8: Application Change Causes Data Corruption**

*Nature of Event:* A code change introduces a bug that corrupts data gradually over time—potentially days or weeks before detection. Unlike migration failures, the corruption timeline is unclear and attribution is challenging.

*Detection Signals:* Business logic errors; customer-reported data discrepancies; gradual data anomalies; integrity checks failing; audit discrepancies appearing over time.

*Recovery Approach:* Reconstruct the corruption timeline from application and audit logs. Identify the last known-good state. Execute PITR or backup restore to that point. Re-deploy a fixed application version. Selectively replay any valid transactions that occurred between the corruption onset and detection using binlog analysis.

*Key Dependencies:* Comprehensive audit logging; application-layer integrity checks; multi-week backup retention for extended detection scenarios; ability to replay selective transactions.

*RTO: 8 hours | RPO: 24 hours | MTTR: 8–24 hours*

---

**Scenario 9: HAProxy Endpoints Inaccessible**

*Nature of Event:* HAProxy or ProxySQL service endpoints become unreachable to applications despite the underlying PXC cluster being healthy. The fault lies in Kubernetes Service/Endpoints configuration, ingress routing, DNS, or network connectivity.

*Detection Signals:* 502/503 responses from application tier; health check failures; Kubernetes Service Endpoints object empty; HAProxy pods healthy but unreachable from application pods.

*Recovery Approach:* Confirm HAProxy pods are running and healthy. Diagnose whether the failure is in Service Endpoints, NetworkPolicy, DNS, or ingress. Fix the specific layer. As an immediate workaround, configure application clients to connect directly to PXC pods (bypassing HAProxy) while the routing layer is repaired.

*Test Status:* Automated test available (`test_dr_ingressvip_failure.py`).

*RTO: 30 minutes | RPO: 0 | MTTR: 30–60 minutes*

---

**Scenario 10: Credential Compromise (DB or MinIO Keys)**

*Nature of Event:* Database user credentials or MinIO access keys are suspected to be compromised, creating a risk of unauthorized data access or backup manipulation.

*Detection Signals:* SIEM alerts on anomalous access patterns; failed authentication spikes; MinIO access log anomalies; external notification of credential exposure.

*Recovery Approach:* Immediately rotate all affected credentials via the Fleet GitOps pipeline. Revoke active sessions. Audit access logs for the compromise window. If data tampering is suspected, execute PITR to a point prior to the compromise and compare against current state. Notify the CISO and (if required by regulation) the appropriate regulatory body.

*Key Dependencies:* Secret rotation capability via Fleet; audit log access; SIEM operational; least-privilege enforcement.

*RTO: 120 minutes | RPO: 15 minutes | MTTR: 2–8 hours*

---

**Scenario 11: Certificate Expiration or Revocation Causing Connection Failures**

*Nature of Event:* An X.509 certificate used for TLS connections—either a manually managed ingress certificate or an Istio CA certificate—expires or is revoked, causing SSL/TLS handshake failures and service interruptions.

*Detection Signals:* "certificate expired" or "certificate verify failed" errors in logs; SSL handshake failure alerts; service-to-service connectivity drops within the mesh; ingress health checks fail.

*Recovery Approach:* Identify the specific certificate that has expired or been revoked (check Kubernetes Secrets, cert-manager Certificate resources, and Istio `cacerts`). Renew or rotate the certificate following the procedure in Section 7.3. Update the relevant Kubernetes Secret. Restart affected pods to force certificate reload. Verify SSL connectivity is restored.

*CAB Notification:* Root CA or intermediate CA rotation requires a CAB change record. Emergency rotation requires a post-hoc emergency change record within 24 hours.

*RTO: 45 minutes | RPO: 0 | MTTR: 30–90 minutes*

---

**Scenarios 12–20** (summarized — full runbooks available in DR Dashboard):

| # | Scenario | Primary Recovery | RTO | RPO |
|---|---|---|---|---|
| 12 | Database disk space exhaustion | Identify space consumer; purge old binlogs; increase PVC size | 30 min | 0 |
| 13 | Connection pool exhaustion | Kill idle connections; increase max_connections; fix application pool | 15 min | 0 |
| 14 | Memory exhaustion (OOM kills) | Identify memory leak; kill memory-intensive queries; increase limits | 20 min | 0 |
| 15 | DNS resolution failure | Fix DNS server; update /etc/hosts as temporary workaround | 30 min | 0 |
| 16 | Network policy misconfiguration | Fix NetworkPolicy rules; verify pod-to-pod connectivity | 30 min | 0 |
| 17 | Performance degradation from API load spike | Scale PXC cluster via CR size field in Fleet pipeline | 60 min | 0 |
| 18 | Performance degradation from application change | Rollback application deployment; optimize query; add indexes | 45 min | 0 |
| 19 | Encryption key rotation failure | Rollback key rotation; restore previous key; retry after validation | 90 min | 0 |
| 20 | Clock skew causing replication issues | Synchronize NTP; correct system time; restart affected pods | 60 min | 0 |

---

#### 8.2.3 Medium Impact Scenarios

**Scenario 22: Kubernetes Worker Node Failure**

*Nature of Event:* A VMware host running one or more Kubernetes worker nodes crashes or becomes unreachable. Pods scheduled to that node are evicted and must be rescheduled.

*Detection Signals:* Node transitions to `NotReady`; pod eviction events; HAProxy backend reports one node down; PMM shows temporary metric gaps.

*Recovery Approach:* Kubernetes automatically reschedules evicted pods to remaining healthy nodes. PodDisruptionBudgets ensure a maximum of one PXC node is unavailable at any time. The Percona Operator automatically re-joins the rescheduled PXC pod to the cluster via IST or SST. If the node hardware is unrecoverable, cordon and drain it, replace the VM, and re-add to the cluster.

*Test Status:* Automated test available (`test_dr_kubernetes_worker_node_failure.py`).

*RTO: 20 minutes | RPO: 0 | MTTR: 30–60 minutes*

---

**Scenario 23: Percona Operator / CRD Misconfiguration (Bad Rollout)**

*Nature of Event:* A GitOps change to the `PerconaXtraDBCluster` custom resource or to the Operator deployment itself causes pods to enter CrashLoopBackOff or Pending state, or causes the Operator to emit reconciliation errors.

*Detection Signals:* Pods stuck in Pending or CrashLoopBackOff; Operator logs showing reconciliation errors; Fleet sync shows unhealthy resources; PMM cluster state metric shows non-ready.

*Recovery Approach:* Roll back the GitOps commit in Fleet/Rancher. The Operator re-reconciles from the previous known-good manifest. If the Operator pod itself is affected, scale it down and back up. Verify cluster state returns to Ready.

*Test Status:* Automated test available (`test_dr_percona_operator_crd_misconfiguration.py`).

*RTO: 45 minutes | RPO: 0 | MTTR: 30–90 minutes*

---

**Scenarios 24–31** (summarized):

| # | Scenario | Primary Recovery | RTO | RPO |
|---|---|---|---|---|
| 24 | Kubernetes control plane outage | Restore control plane VMs; failover etcd; use Rancher to re-provision | 90 min | 0 |
| 25 | Storage PVC corruption (single node) | Remove failed node; recreate pod; re-seed from peers via IST/SST | 3 hours | 5 min |
| 26 | Primary DC network partition from secondary | Stay primary; queue async replication; monitor lag | 0 (no failover) | N/A |
| 27 | Replication channel broken (both DCs up) | Fix replication; GTID resync; rebuild replica from backup if diverged | 60 min | 0 |
| 28 | MinIO backup target unavailable | Buffer locally; failover to secondary MinIO; rotate credentials | 0 (runtime OK) | N/A |
| 29 | MinIO service failure | Restart MinIO pods; failover to secondary instance | 0 (runtime OK) | N/A |
| 30 | Monitoring and alerting system failure | Restore PMM; use kubectl for manual checks | N/A (DB unaffected) | N/A |
| 31 | Temporary tablespace exhaustion | Kill queries creating large temp tables; add dedicated tmpdir | 15 min | 0 |

---

#### 8.2.4 Low Impact Scenarios

**Scenario 32: Single PXC or HAProxy Pod Failure**

*Nature of Event:* A single PXC database pod or HAProxy load balancer pod fails. Kubernetes and the Percona Operator detect the failure and automatically restart or reschedule the pod.

*Detection Signals:* PXC or HAProxy liveness probe fails on the individual pod; PMM shows one backend temporarily down; Kubernetes Event shows pod restart.

*Recovery Approach:* Kubernetes restarts the pod automatically. The Percona Operator re-joins the PXC node to the cluster. No manual intervention is required unless the pod enters a permanent failure loop, in which case delete the pod and allow it to re-spawn.

*Test Status:* Automated test available (`test_dr_single_mysql_pod_failure.py`).

*RTO: 2 minutes | RPO: 0 | MTTR: 10–20 minutes*

---

**Scenarios 33–35** (summarized):

| # | Scenario | Primary Recovery | RTO | RPO |
|---|---|---|---|---|
| 33 | Backups non-restorable (silent failure) | Detect via restore drills; fix pipeline; re-run full backup | 4 hours | 15 min |
| 34 | Backup retention policy failure (premature deletion) | Restore from remaining backups; fix retention policy | 4 hours | 15 min |
| 35 | Audit log corruption or loss | Restore from backup; document gap for auditors; implement compensating controls | 2 hours | 0 |

---

## 9. DR Emergency Response Dashboard

### 9.1 Overview

The DR Emergency Response Dashboard is a purpose-built web application designed for use during active database crises. It provides immediate, browser-based access to all recovery runbooks in this document without requiring access to version control, wiki systems, or documentation portals that may themselves be unavailable during an incident.

The dashboard is designed to be the first resource an on-call engineer opens during a database incident.

### 9.2 Architecture

The dashboard is a stateless Go application with a vanilla JavaScript frontend. Its design philosophy is operational simplicity under crisis conditions:

- **Backend**: Go standard library only—no external dependencies that could fail to resolve. Startup time under 100ms. Memory usage approximately 10–20 MB.
- **Frontend**: Vanilla JavaScript and CSS3. No framework dependencies that require CDN access.
- **Data**: File-based—reads directly from the same `disaster_scenarios.json` files used by the automated testing framework, ensuring a single source of truth.
- **Availability**: Deployed as a Kubernetes Deployment in both EKS and on-premises environments, independently of the database cluster. Accessible via `http://localhost:8080` (development) or via the cluster ingress.

### 9.3 Features

- **Crisis-optimized interface**: On-call contact information is displayed prominently at page load. No navigation or login required.
- **Environment selector**: Toggle between EKS and On-Premises scenario catalogs.
- **Impact-sorted scenarios**: Scenarios are displayed sorted by business impact (Critical → High → Medium → Low) and then by likelihood, so the most critical and probable scenarios are immediately visible.
- **Scenario expand/collapse**: Each scenario card expands to show:
  - Overview tab: RTO, RPO, MTTR, likelihood, detection signals, affected components.
  - Recovery Process tab: The full markdown runbook rendered in-browser, with copy-to-clipboard buttons on all code blocks.
- **Automatic incident detection**: A `detect-scenario.sh` script can be run from the command line to analyze cluster state and suggest the most likely matching scenario.

### 9.4 API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/` | GET | Serves the dashboard UI |
| `/api/scenarios?env={eks\|on-prem}` | GET | Returns full scenario catalog as JSON |
| `/api/recovery-process?env={env}&file={name}.md` | GET | Returns markdown runbook content |
| `/static/*` | GET | Static assets (JS, CSS) |

### 9.5 Security Posture

- Read-only operations—the dashboard cannot modify cluster state.
- Path traversal protection on all file-serving endpoints (validated filenames only).
- No database—no SQL injection surface.
- Stateless—no session management or credential storage.
- Designed for internal network access only; authentication should be added if exposed beyond localhost.

### 9.6 Deployment

The dashboard is deployed to both EKS and on-premises Kubernetes environments via pre-built manifests:

```bash
# On-premises
kubectl apply -f dr-dashboard/k8s/deployment-on-prem.yaml

# EKS
kubectl apply -f dr-dashboard/k8s/deployment-eks.yaml
```

For on-premises environments, a Nix-based declarative manifest generator is also available, supporting custom registry, namespace, service type, and resource limits.

---

## 10. Automated Testing and Validation

### 10.1 Testing Philosophy

This plan does not rely solely on documentation for its assurances. Recovery procedures are validated through a three-tier testing regime:

1. **Unit tests** (~30 seconds; no cluster required): Configuration validation, YAML rendering, Helm template validation. These ensure the infrastructure-as-code is syntactically and semantically correct before deployment.
2. **Integration tests** (~5–8 minutes; requires running cluster): Verify Kubernetes version compatibility, StorageClass availability, backup secret existence, Operator status, anti-affinity rule enforcement, and resource request/limit correctness.
3. **Resiliency tests** (~30–60 minutes; with optional chaos injection via LitmusChaos): End-to-end validation of specific disaster scenarios, polling for cluster recovery within the scenario's MTTR target.

### 10.2 Automated Scenario Tests

The following scenarios have automated resiliency tests that execute chaos conditions against a live cluster and verify recovery within the defined MTTR:

| Test File | Scenario | Chaos Type | MTTR Target |
|---|---|---|---|
| `test_dr_single_mysql_pod_failure.py` | Single PXC pod failure | pod-delete (label: pxc component) | 600 sec |
| `test_dr_kubernetes_worker_node_failure.py` | Worker node failure | node-drain | 1,200 sec |
| `test_dr_percona_operator_crd_misconfiguration.py` | Operator pod failure | pod-delete (operator deployment) | 900 sec |
| `test_dr_ingressvip_failure.py` | HAProxy / ProxySQL endpoint failure | pod-delete (proxysql component) | 600 sec |
| `test_dr_schema_change_or_ddl_blocks_writes.py` | DDL blocking writes | Controlled DDL lock injection | 1,800 sec |

### 10.3 LitmusChaos Integration

Automated chaos experiments are executed via LitmusChaos. Supported chaos types include:

- `pod-delete`: Terminates individual pods and verifies operator-driven recovery.
- `node-drain`: Drains a Kubernetes node, simulating host failure.
- `pod-cpu-hog`: Injects CPU contention to test resource limit enforcement.
- `pod-memory-hog`: Injects memory pressure to test OOM kill behavior.
- `network-partition`: Simulates network isolation between pods.
- `network-latency`: Introduces artificial latency to validate timeout and retry behavior.
- `disk-fill`: Fills a volume to simulate disk space exhaustion.

### 10.4 Restore Drill Schedule

In addition to automated resiliency tests, the following manual restore drills are required:

| Drill | Frequency | Owner | Last Completed | Next Due |
|---|---|---|---|---|
| Full backup restore to side namespace | Quarterly | Platform Engineering | — | — |
| PITR restore to specific timestamp | Quarterly | Platform Engineering | — | — |
| DR site failover drill (full DC simulation) | Semi-annually | Platform Engineering + Operations | — | — |
| Certificate rotation dry-run (test environment) | Annually or before any root CA rotation | Platform Engineering | — | — |

---

## 11. Roles, Responsibilities, and Escalation

### 11.1 Roles

| Role | Responsibilities |
|---|---|
| **On-Call Platform Engineer** | First responder for all database platform incidents. Uses DR Dashboard to identify scenario and execute runbook. Escalates within 15 minutes if scenario cannot be identified or containment actions have no effect. |
| **Platform Engineering Lead** | Owns this DR plan. Declares disaster events. Coordinates with downstream teams. Approves deviations from runbook procedures. |
| **CISO** | Notified of any security-related scenarios (credential compromise, ransomware, audit log loss). Authorizes emergency certificate rotation. |
| **Data Protection Officer** | Notified of any scenario with confirmed or potential data loss. Responsible for regulatory notification decisions. |
| **Change Advisory Board (CAB)** | Reviews and approves root CA rotations and other certificate management changes. Receives emergency change records for post-hoc review. |
| **Database Administrator** | Subject matter expert for PXC-specific recovery procedures (quorum bootstrap, PITR execution, replication repair). |

### 11.2 Escalation Path

```
On-Call Engineer
      ↓ (15 min, no progress)
Platform Engineering Lead
      ↓ (30 min, Critical or High impact)
CISO (security events) / DPO (data loss events)
      ↓ (as appropriate)
Vendor Support (Percona, AWS, VMware)
```

### 11.3 Communication During Incidents

- All active incidents are tracked in the organization's incident management system.
- Status updates are communicated to affected application teams every 30 minutes during a declared incident.
- Post-incident reviews (PIRs) are conducted within 5 business days of resolution for any Medium, High, or Critical incident.

---

## 12. Plan Maintenance and Governance

### 12.1 Review Cycle

This document is reviewed:

- **Annually** as a scheduled review.
- **Following any declared disaster event** (within 30 days of resolution).
- **Following any significant architectural change** to the data platform.
- **Before any CFIUS review submission** or regulatory audit.

### 12.2 Change Control

Changes to this document are subject to:

- Version control via Git commit in the platform repository.
- Review and sign-off by the Platform Engineering Lead.
- Notification to the CAB for any changes affecting Section 7 (Certificate Management).
- Distribution to all named roles in Section 11.

### 12.3 Scenario Catalog Maintenance

The disaster scenario catalog (`disaster_scenarios.json`) is the authoritative source for the DR Dashboard and this document. Changes to the catalog (adding, retiring, or updating scenarios) require:

1. A pull request to the platform repository.
2. A corresponding update to the associated recovery process markdown file in `dr-dashboard/recovery_processes/`.
3. Verification that the DR Dashboard correctly renders the updated scenario.
4. This document updated to reflect the change in Section 8.

---

## 13. Compliance Considerations

### 13.1 CFIUS National Security Considerations

This section addresses operational resilience controls relevant to CFIUS national security review of the data platform.

**Data Sovereignty and Geographic Controls**

All production data resides within organization-controlled infrastructure. The on-premises deployment operates within data centers under physical control of the organization. The EKS deployment is confined to a single AWS region. Cross-region or cross-border data transfers do not occur as part of normal backup or replication operations.

**Access Controls**

Access to all platform infrastructure requires authentication via the organization's identity provider. Administrative access to database systems is restricted to named individuals with documented business need. All administrative actions are logged. Backup artifact access is restricted to service accounts with credentials managed in Kubernetes Secrets, rotated via the GitOps pipeline.

**Encryption**

All data at rest (database volumes, backup artifacts) is encrypted. All data in transit between cluster components uses TLS. Service-to-service communication within and between clusters uses Istio mTLS, ensuring that no plain-text traffic traverses network boundaries.

**Audit Trail Integrity**

Database audit logging is enabled on all production PXC instances. Audit logs are shipped to centralized storage independent of the database system. Scenario 35 in this plan documents the recovery procedure for audit log corruption, including the requirement to notify compliance personnel and document any audit trail gaps.

**Operational Resilience**

The platform is designed with no single point of failure at the database tier. Synchronous Galera replication ensures that no transaction is lost due to a single node failure. Asynchronous DR replicas provide geographic redundancy. The backup strategy provides PITR capability to within 60–120 seconds of any transaction across the full 12-month retention window.

### 13.2 CAB Certificate Management Forum

This section summarizes the certificate management posture for the CAB certificate management forum.

**Certificate Inventory**: The authoritative certificate inventory is maintained in Appendix D of this document and updated at each CAB forum.

**Rotation Governance**: All root CA and intermediate CA rotations are CAB-gated changes requiring a formal change record with a minimum 5-business-day lead time, except in emergency scenarios (which require a post-hoc emergency change record within 24 hours).

**Automated vs. Manual Certificates**: Istio workload SVIDs (short-lived, ~24-hour TTL) are fully automated and do not require CAB oversight. All other certificates in the inventory are manually managed and subject to CAB governance.

**DR Impact of Certificate Failures**: Scenario 11 in this plan documents the specific recovery procedure for certificate-related outages, including the 45-minute RTO target, detection signals, and step-by-step rotation procedure. The DR Dashboard exposes this runbook for immediate on-call access.

**Compliance with Certificate Policies**: All certificates issued by organization-controlled CAs comply with the organization's PKI policy. Externally issued certificates (AWS ACM) comply with the issuing CA's CPS.

---

## Appendix A — Platform Capabilities Inventory

The following table reflects the current design, development, and operations status of each declared data platform capability. Status indicators: 🟢 Green (complete/operational), 🟡 Yellow (in progress/partial), 🔴 Red (not started/blocked).

| Capability | Description | Design | Develop | Operations |
|---|---|---|---|---|
| On-prem S3-compatible storage | Object storage via MinIO exposing S3-compatible APIs | 🟢 | 🟡 | 🔴 |
| Synchronous Percona PXC cluster | PXC with Galera synchronous replication for strong consistency | 🟡 | 🔴 | 🟢 |
| HAProxy read-only endpoint (round-robin, all 4 clusters) | Dedicated read load balancer across all cluster replicas | 🔴 | 🟢 | 🟡 |
| HAProxy write endpoint (no distribution, all 4 clusters) | Single logical write entry point via HAProxy | 🟢 | 🟡 | 🔴 |
| dr-std PXC async replica (Active/Passive) | Async PXC replica at standard DR site | 🟡 | 🔴 | 🟢 |
| dr-sec PXC async replica (Active/Passive) | Secondary DR async PXC replica for geographic/regulatory separation | 🔴 | 🟢 | 🟡 |
| dr-std SeaweedFS async replication controller | Controller orchestrating SeaweedFS replication at standard DR site | 🟢 | 🟡 | 🔴 |
| dr-sec SeaweedFS async replication controller | Companion controller for secondary DR SeaweedFS replication | 🟡 | 🔴 | 🟢 |
| PXC backups S3 bucket controller | Operator-managed workload coordinating backup streams into S3 | 🔴 | 🟢 | 🟡 |
| SeaweedFS Filer per cluster | POSIX-compatible file API per cluster via SeaweedFS Filer | 🟢 | 🟡 | 🔴 |

*Note: This table is derived from `data_platform_capabilities/capabilities.json`. Mixed green/red/yellow status across capabilities reflects that the platform is under active development. Capabilities with red Operations status represent areas requiring additional operational hardening before this DRP can be considered fully validated for those capabilities.*

---

## Appendix B — Backup Schedule and Retention Matrix

| Backup Type | Schedule | Storage Target | Retention | Encryption | Cross-DC Replication |
|---|---|---|---|---|---|
| Binary log (PITR) | Continuous (60-sec upload interval) | `minio.minio.svc.cluster.local:9000 / percona-backups` | 7 days | Yes | Yes (MinIO replication) |
| Daily full (physical) | 02:00 daily | `minio.minio.svc.cluster.local:9000 / percona-backups` | 7 days | Yes | Yes |
| Weekly full (physical) | 01:00 every Sunday | `minio.minio.svc.cluster.local:9000 / percona-backups` | 8 weeks | Yes | Yes |
| Monthly full (physical) | 01:30 on 1st of month | `minio.minio.svc.cluster.local:9000 / percona-backups` | 12 months | Yes | Yes |

**PITR Coverage**: Continuous from the oldest available daily backup (7 days) to the most recent 60-second binlog checkpoint.

**Backup Credential**: `percona-backup-minio-credentials` Kubernetes Secret in the `percona` namespace. Rotation schedule: quarterly or upon suspected compromise.

---

## Appendix C — Scenario Risk Register

This register supports formal risk management processes. Likelihood and Impact ratings follow the definitions in Section 5.1.

| # | Scenario | Likelihood | Impact | Inherent Risk | Key Mitigating Control | Residual Risk |
|---|---|---|---|---|---|---|
| 1 | Ransomware attack | Low | Critical | High | Immutable backups; DR site; EDR | Medium |
| 2 | Primary DC down | Low | Critical | High | Async DR replica; switchover runbook | Low-Medium |
| 3 | Accidental production restore | Low | Critical | Medium | Side-namespace restore; audit logs; approval gates | Low |
| 4 | DDL blocks writes | Medium | High | High | PMM slow query alerting; kill procedures | Medium |
| 5 | Cluster loses quorum | Low | High | Medium | 3-node PXC; PodDisruptionBudgets; bootstrap runbook | Low |
| 6 | Accidental DROP/DELETE/TRUNCATE | Medium | High | High | PITR; pitr-timestamp-finder; 7-day binlog retention | Medium |
| 7 | Widespread data corruption | Low | High | Medium | Pre-migration backup gates; PITR; change windows | Low |
| 8 | Application data corruption | Medium | High | High | Audit logging; integrity checks; PITR | Medium |
| 9 | HAProxy inaccessible | Medium | High | High | Direct PXC bypass; automated test | Low |
| 10 | Credential compromise | Medium | High | High | Secret rotation via GitOps; SIEM; MFA | Medium |
| 11 | Certificate expiry/revocation | Medium | High | High | PMM alerting; CAB governance; 45-min RTO runbook | Low-Medium |
| 12 | Disk space exhaustion | Medium | High | High | PMM disk usage alerts; PVC expansion procedures | Low |
| 13 | Connection pool exhaustion | Medium | High | High | PMM connection monitoring; max_connections tuning | Low |
| 14 | OOM kills | Medium | High | High | Kubernetes memory limits; PMM OOM alerting | Low |
| 15 | DNS failure | Medium | High | High | DNS monitoring; /etc/hosts fallback | Low |
| 16 | Network policy misconfiguration | Medium | High | High | GitOps review; network policy backup | Low |
| 17 | Load-spike performance degradation | Medium | High | High | GitOps-driven scaling (CR size field); PMM alerting | Low |
| 18 | App-change performance degradation | Medium | High | High | Slow query alerting; app rollback | Low |
| 19 | Encryption key rotation failure | Low | High | Medium | Key backup; rollback procedure | Low |
| 20 | Clock skew | Low | High | Medium | NTP monitoring; VM clock synchronization | Low |
| 21 | Excessive replication lag | Medium | Medium | Medium | PMM replication lag alerting; query throttling | Low |
| 22 | Worker node failure | Medium | Medium | Medium | Anti-affinity; PodDisruptionBudgets; automated test | Low |
| 23 | Operator misconfiguration | Medium | Medium | Medium | GitOps rollback; automated test | Low |
| 24 | Control plane outage | Low | Medium | Low | etcd backups; Rancher re-provision | Low |
| 25 | PVC corruption (single node) | Low | Medium | Low | IST/SST re-seeding; 3-node redundancy | Low |
| 26 | WAN network partition | Medium | Medium | Medium | No auto-failover policy; replication queuing | Low |
| 27 | Replication channel broken | Medium | Medium | Medium | GTID resync; monitoring | Low |
| 28 | MinIO backup target unavailable | Medium | Medium | Medium | Secondary MinIO; local buffering | Low |
| 29 | MinIO service failure | Medium | Medium | Medium | Pod restart; secondary instance | Low |
| 30 | Monitoring system failure | Medium | Medium | Medium | Manual kubectl procedures; backup monitoring | Low |
| 31 | Temp tablespace exhaustion | Medium | Medium | Medium | Query kill procedures; tmpdir configuration | Low |
| 32 | Single pod failure | Medium | Low | Low | Auto-restart; Galera sync | Very Low |
| 33 | Non-restorable backups | Low | High | Medium | Restore drills; checksum verification; PMM alerting | Low |
| 34 | Backup retention policy failure | Low | Low | Low | Retention monitoring; immutable copies | Very Low |
| 35 | Audit log corruption | Low | Low | Low | Separate backup; integrity checks; compliance notification | Very Low |

---

## Appendix D — Certificate Inventory and Lifecycle Register

This register is the authoritative certificate inventory for CAB certificate management forum review. It must be updated whenever a certificate is issued, renewed, rotated, or revoked.

| Certificate Name | Type | Subject / SAN | Issuer | Issued Date | Expiry Date | Auto-Renew | Rotation Owner | CAB Required | Last Rotated | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| Istio Root CA | Root CA | mesh1 | Self-signed | — | — | No | Platform Engineering | Yes | — | Shared across all clusters in mesh1 |
| cluster-b Intermediate CA | Intermediate CA | cluster-b | Istio Root CA | — | — | No | Platform Engineering | Yes | — | Stored in `cacerts` secret, `istio-system` ns |
| Istio workload SVIDs | Leaf / SVID | Per service identity | cluster-b Intermediate CA | Dynamic | ~24h | Yes (istiod) | Istio | No | N/A | Auto-rotated; no manual intervention |
| PMM Ingress TLS (on-prem) | TLS Leaf | pmm.k3d.test / cluster FQDN | Traefik (self-signed) | — | — | No | Platform Engineering | Yes | — | Self-signed; update on renewal |
| PMM Ingress TLS (EKS) | TLS Leaf | PMM EKS FQDN | AWS ACM | — | — | Yes (ACM) | Platform Engineering / AWS | No | N/A | ACM auto-renews ≥60 days prior |
| DR Dashboard TLS (on-prem) | TLS Leaf | dr-dashboard FQDN | Traefik (self-signed) | — | — | No | Platform Engineering | Yes | — | Update on deployment |
| PXC Node TLS (internal) | TLS Leaf | PXC pod DNS names | Percona Operator internal CA | Dynamic | Operator-managed | Yes (Operator) | Percona Operator | No | N/A | Auto-managed by Operator |
| MinIO TLS (internal) | TLS Leaf | minio.minio.svc.cluster.local | Internal self-signed | — | — | No | Platform Engineering | Yes | — | Rotate with MinIO upgrade |

*Fields marked "—" must be populated by the Platform Engineering team upon first CAB forum review. Expiry dates for all manually managed certificates must be tracked with a minimum 30-day advance renewal reminder configured in the organization's certificate monitoring system.*

---

*End of Document*

*Document ID: DR-PLN-001 | Version 1.0 | 2026-06-02*
*For questions regarding this document, contact the Platform Engineering team.*
