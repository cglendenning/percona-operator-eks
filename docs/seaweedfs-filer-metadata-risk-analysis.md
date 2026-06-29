# SeaweedFS Filer Metadata Risk Analysis

**Author:** Craig Glendenning
**Date:** 2026-06-29
**Scope:** On-premises deployment; PXC backup and PITR workload; cross-datacenter active-passive DR

---

## Background

The platform stores PXC backups and PITR binlogs in SeaweedFS, which exposes an S3-compatible endpoint for writes. The `pxc-restore` tooling uses the SeaweedFS Filer HTTP API (port 8888, `GET /buckets/<bucket>/binlogs/<cluster>/`) to discover and list binlog files for point-in-time recovery. This means the filer metadata service sits in the critical path for PITR — its loss is a hard failure for binlog discovery, not merely a navigation inconvenience.

Current DR configuration: one filer pod with an embedded leveldb store backed by a PVC, replicated asynchronously to the DR site via `filer.sync`.

An alternative — using a three-node PXC cluster as an external filer store — was evaluated and prototyped. This document records the risk analysis and the rationale for not adopting it.

---

## The Actual Failure Mode

SeaweedFS stores object data on volume servers and stores the namespace (file paths, bucket structure, timestamps) in the filer's embedded database. When filer metadata is lost, the volume data is almost certainly intact on the volume servers — it simply becomes unreachable via the filer namespace.

For the backup workload, the consequence is: `pxc-restore` fails at binlog listing, PITR breaks loudly. The raw backup objects remain on volume servers and are recoverable with effort, but the tooling chain is broken until filer metadata is restored.

---

## Current Setup Risk Profile

| Failure | Outcome | Recovery | Risk Level |
|---|---|---|---|
| Filer pod crash | PVC survives, pod restarts, metadata intact | Self-healing | Very Low |
| Kubernetes node failure + network-attached PVC | Pod reschedules, PVC follows | Automatic | Low |
| Kubernetes node failure + local PV | Pod cannot reschedule until node recovers or PVC is migrated manually | Manual intervention required | Medium |
| PVC corruption or storage layer loss | Metadata lost, PITR breaks | Activate DR filer | High |
| filer.sync lag at moment of failure | DR filer slightly behind primary | Within minutes RPO for this workload | Low |

For a low write frequency workload — binlogs uploaded every 60 seconds, full backups daily and weekly — filer.sync lag is unlikely to exceed a minutes RPO target under normal conditions. The filer metadata set is small and bounded: it is directory entries and file records for the backup namespace, not operational transactional data.

**The real operational gap is not the architecture — it is the absence of a defined failback process.** Once the DR filer is activated after a primary-site storage loss, there is no documented procedure to resync state back to the primary when it recovers. `weed filer.sync` can run bidirectionally. This runbook needs to exist.

---

## Evaluation: PXC as External Filer Store

### What It Provides

- The filer metadata store itself becomes HA: losing a single PXC node does not lose metadata.
- Multiple active filer replicas become possible, since all filers point at the same external database. This enables horizontal write scaling.
- The team already operates PXC, so the marginal day-2 burden is lower than it would be for a team unfamiliar with Galera.

### Why It Is Not Worth It Now

**An external store is compatible with filer.sync and is in fact the prerequisite for running multiple filer replicas at all.** The constraint is not about filer.sync — it is about the internal leveldb store. When `filer.replicas` is set to more than one and each pod uses its own internal leveldb, each pod maintains an isolated, independent copy of the metadata. Writes to one filer pod are invisible to the others. The filer instances immediately diverge and the metadata is inconsistent across replicas.

An external store solves this: all filer pods point at the same database and share a single consistent metadata state. Once the external store is in place, filer.sync works correctly from any filer replica to a DR filer, since they all see the same data. A single primary filer backed by PXC and replicating to a DR filer via filer.sync is a valid topology:

```
Primary filer → PXC external store (HA metadata)
      ↓
   filer.sync
      ↓
DR filer → embedded store
```

**What the external store actually provides in the single-filer topology** is filer pod resilience: if the filer pod crashes and its PVC is lost, the metadata survives in PXC and the pod can restart against the same store with no data loss. This is a real improvement over the embedded store — but only matters if the PVC itself is at risk. If the filer PVC is on a reliable network-attached storage class, this scenario is already low probability.

**Cross-datacenter Galera quorum design is non-trivial.** If the PXC external store is placed in the primary DC only (the simpler topology), a full primary DC loss takes down the metadata store along with everything else — no improvement over the embedded store for that failure. To make the PXC store survive a DC loss, it must span both DCs, which reintroduces the quorum problem:

- *2 primary + 1 DR*: Primary DC maintains quorum on DC link loss. If the entire primary DC goes down, the DR node is non-primary, the cluster is down, and the DR filer cannot write metadata. Bootstrapping the DR node as a new Galera primary is operationally equivalent to activating a DR filer today, but with more steps.

- *1 primary + 2 DR*: Every metadata write incurs 2x the round-trip time to the DR site. DR becomes the quorum holder, which is inconsistent with an active-passive model.

The correct resolution for cross-DC Galera is a `garbd` (Galera Arbitrator Daemon) at a third site, or an asymmetric 2+1+arbitrator topology. Neither is available in the current two-site setup.

**The failure scenario the external store actually solves — filer pod PVC loss — is low probability when PVC storage is network-attached, and is already mitigated by filer.sync for the DC-loss scenario.** The marginal resilience improvement does not justify the operational costs below.

**Additional operational costs of the external filer store:**

*Resource utilization.* A three-node PXC cluster consumes CPU and memory on nodes that are shared with other workloads. This is not free capacity — it directly competes with production database pods, backup jobs, and operator processes for the same node resources.

*Secret management complexity.* The `seaweedfs-db-secret` must be provisioned with credentials that match the MySQL user created on the new PXC cluster. This is a manual coordination step: the PXC user, the secret keys, and the SeaweedFS filer configuration must all be kept in sync. Any credential rotation requires touching all three.

*Additional Vault infrastructure.* Properly managing credentials for a new PXC cluster and the `seaweedfs-db-secret` requires Vault policies, roles, and leases for both. This is net-new Vault surface area to maintain — not a reuse of existing PXC cluster Vault configuration, because the filer store cluster is a separate entity with its own identity and access policies.

*Database and schema pre-provisioning.* The filer metadata database and `filemeta` table do not exist until you create them. The DDL must be extracted from `weed scaffold -config=filer`, applied to the PXC cluster, and kept in sync with the SeaweedFS version in use. This is a deployment prerequisite that must be documented, automated, and repeated for any cluster rebuild.

*The filer store backup problem is a circular dependency.* The external PXC cluster stores the metadata for the SeaweedFS filer. If you want to back up that PXC cluster, you need a backup target. Backing it up to the same SeaweedFS instance it is protecting creates a circular dependency: if SeaweedFS is degraded, filer metadata is degraded, which means the PXC filer store backup target is degraded, which means you cannot restore the filer store to recover SeaweedFS. An external backup target for the filer store PXC cluster — separate from the SeaweedFS it serves — must be provisioned, operated, and monitored independently. This is a meaningful addition to the backup and recovery surface area.

### When to Revisit

Implement an external filer store when the single filer pod's leveldb becomes a performance bottleneck. The concrete signals are:

- Filer metadata operation latency climbs under load (observable in SeaweedFS metrics: `weed_filer_request_seconds`)
- A single filer pod's leveldb cannot handle the write throughput of the backup namespace
- There is a genuine requirement to run multiple filer replicas in concert

At that point the external store is the correct solution. It is the prerequisite for running `filer.replicas > 1` — without it, each filer pod maintains its own isolated leveldb and the instances immediately diverge. With the external store in place, all filer replicas share a single consistent metadata state, and filer.sync continues to work from any of them to the DR filer. The operational cost of the PXC cluster is justified once the throughput requirement makes multiple replicas necessary. For the current single-writer backup workload, that threshold has not been reached.

---

## Near-Term Action Items

**1. Define the failback runbook for filer.sync.**
Document the steps to activate the DR filer and to resync state back to the primary site when it recovers. `weed filer.sync` supports bidirectional replication; the gap is a procedural one.

**2. Verify PVC storage class for the filer pod.**
Confirm the filer PVC uses a network-attached storage class (NFS, RBD, or equivalent) so the pod can reschedule to a different node after a node failure without manual PVC migration. This eliminates the Medium risk row in the table above.

**3. Eliminate the SeaweedFS Filer API dependency in pxc-restore.**
The binlog listing in `pxc-restore` uses the Filer HTTP API because it provides a fast single-request directory listing with timestamps and sizes. Replacing `seaweedfs_filer_list()` with an S3 `ListObjectsV2` call against the existing MinIO endpoint — which already has cross-DC site replication configured — removes SeaweedFS from the PITR critical path entirely. This eliminates the filer metadata risk for PITR without adding any new infrastructure.

---

## Comparison: How Other Systems Handle This Problem

The filer metadata problem is SeaweedFS-specific because SeaweedFS deliberately separates the metadata layer (filer) from the data layer (volume servers). Other systems make different architectural choices with different tradeoffs.

### Summary Table

| System | Metadata Architecture | Separate Metadata Failure Domain | Cross-DC Metadata HA | Operational Complexity | POSIX Filer Semantics |
|---|---|---|---|---|---|
| **SeaweedFS** | Embedded leveldb store per filer pod (default), optionally external RDBMS | Yes — filer pod is a distinct SPOF | Via filer.sync (async) or external store replication | Low | Yes — purpose-built filer API |
| **MinIO** | Inline with objects as `xl.meta` files in erasure-coded data | No — metadata loss = object loss | Via site replication (active-active) | Low | No — S3 only |
| **GarageFS** | Distributed LMDB per node, Raft-based consensus across nodes | No — metadata is part of storage nodes | Native zone-aware by design | Low-Medium | No — S3 only |
| **Ceph (RadosGW)** | Stored in dedicated RADOS pools, replicated across OSDs | No — metadata loss = OSD failure (same as data) | Bucket replication (async) or stretch cluster (complex) | Very High | Via CephFS + MDS (separate subsystem) |

### Tradeoffs of SeaweedFS's Architecture

**Advantages**

- *Flexibility.* The filer store is pluggable: embedded KV for simplicity, MySQL/PostgreSQL/Redis/Cassandra for scale. You can start simple and migrate the metadata store independently of your data layer.
- *POSIX semantics without a full filesystem.* The filer provides a real directory hierarchy, renames, and metadata queries (timestamps, sizes, directory listings) that S3-only systems cannot. The `pxc-restore` binlog discovery currently relies on this.
- *Lightweight default.* The embedded store requires no external dependencies for a single-filer deployment. Operational simplicity is high at small scale.
- *Separation enables independent scaling.* You can scale volume servers without touching the filer, and vice versa.

**Disadvantages**

- *Filer is a distinct failure domain.* Because metadata and data are separate processes, you can lose the filer without losing volume data — and vice versa. This adds an additional component to your availability model that S3-native systems do not have.
- *External store required for HA writes.* You cannot run multiple active filer replicas against a single embedded store. Horizontal write scaling requires the operational complexity of an external database, unlike MinIO (which scales by adding nodes to the erasure set) or Garage (which scales by adding zone members).
- *filer.sync is async and one-directional per configuration.* Unlike MinIO site replication (active-active, bidirectional by default) or Galera (synchronous), filer.sync introduces eventual consistency and requires operational procedures for failover and failback that S3-native solutions handle automatically.
- *POSIX semantics are a liability when not needed.* For pure object workloads (which PXC backups are), the filer layer adds complexity and a failure domain with no benefit. An S3 ListObjects call against MinIO returns equivalent information to the Filer HTTP API directory listing.

---

*End of analysis. Next review: when filer metadata operation latency becomes observable under backup load, or when a second active filer replica is required.*
