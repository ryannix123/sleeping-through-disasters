# Architecture Deep Dive

Detailed explanation of how this DR setup works.

## Three-Cluster Topology

This deployment uses three OpenShift clusters:

```
┌───────────────────────────────────────────────────────────┐
│                       Hub Cluster                         │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  Red Hat Advanced Cluster Management (ACM)          │  │
│  │  - ManagedClusterSet: suitecrm-dr                   │  │
│  │  - Placements: active, passive, both                │  │
│  │  - Policies: operator compliance, replication health│  │
│  │                                                     │  │
│  │  OpenShift GitOps (Argo CD)                         │  │
│  │  - 10 ApplicationSets (in openshift-gitops)         │  │
│  │  - Watches Git repo every 3 minutes                 │  │
│  └─────────────────────────────────────────────────────┘  │
└─────────────────────────┬─────────────────────────────────┘
                          │ Reconciles
            ┌─────────────┼──────────────┐
            ▼                            ▼
   ┌────────────────────┐      ┌────────────────────┐
   │   Active Cluster   │      │   Passive Cluster  │
   │   role=active      │      │   role=passive     │
   │                    │      │                    │
   │   SuiteCRM (2)     │      │   SuiteCRM (0)     │
   │   PostgreSQL (RW)  │◄─────┤   PostgreSQL (RO)  │
   │   Redis            │ WAL  │   Redis            │
   │   VolSync source   │ over │   VolSync dest     │
   │   Skupper Site     │ VAN  │   Skupper Site     │
   └────────┬───────────┘      └────────┬───────────┘
            │                           │
            └──────────► S3 ◄───────────┘
                  (VolSync backups)
```

## Why ACM + GitOps for DR

Without ACM, multi-cluster DR is operationally painful:
- Each cluster needs its own deploy script
- Configuration drift between clusters is hard to detect
- Failover requires running scripts on multiple clusters
- No single source of truth for what *should* be deployed

With ACM + GitOps:
- The Git repo IS the source of truth
- ACM Placements determine what goes where
- Argo CD continuously reconciles to match Git
- Failover is a label change or Git commit
- All changes are auditable through Git history

## The Three Placements

### `suitecrm-active`

Selects clusters labeled `role=active` in the `suitecrm-dr` ClusterSet.

Used by ApplicationSets that should ONLY deploy to the active cluster:
- `suitecrm-postgres-active` (CNPG primary)
- `suitecrm-skupper-active` (Skupper Site + Listener)
- `suitecrm-app-active` (full app, replicas: 2)
- `suitecrm-volsync-active` (ReplicationSource)

### `suitecrm-passive`

Selects clusters labeled `role=passive` in the `suitecrm-dr` ClusterSet.

Used by ApplicationSets that should ONLY deploy to the passive cluster:
- `suitecrm-postgres-passive` (CNPG standby)
- `suitecrm-skupper-passive` (Skupper Site + Connector + AccessToken)
- `suitecrm-app-passive` (app at replicas: 0)
- `suitecrm-volsync-passive` (ReplicationDestination)

### `suitecrm-both`

Selects ALL clusters in the `suitecrm-dr` ClusterSet (no role filter).

Used for things both clusters need:
- `suitecrm-operators` (CNPG, VolSync, Skupper, OADP operators)
- `suitecrm-namespace` (the `suitecrm` namespace)

## How Argo CD Knows Which Clusters to Target

The integration between ACM Placements and Argo CD ApplicationSets goes through a `GitOpsCluster` resource:

```yaml
apiVersion: apps.open-cluster-management.io/v1beta1
kind: GitOpsCluster
spec:
  argoServer:
    cluster: local-cluster
    argoNamespace: openshift-gitops
  placementRef:
    name: suitecrm-both       # ← any Placement that references the ClusterSet
    namespace: openshift-gitops
```

When this resource is reconciled, ACM creates Argo CD cluster Secrets in the `openshift-gitops` namespace - one for each cluster matched by the Placement. These Secrets have specific labels that Argo CD recognizes.

ApplicationSets then use the `clusterDecisionResource` generator:

```yaml
generators:
  - clusterDecisionResource:
      configMapRef: acm-placement
      labelSelector:
        matchLabels:
          cluster.open-cluster-management.io/placement: suitecrm-active
      requeueAfterSeconds: 180
```

ACM auto-creates a ConfigMap named `acm-placement` that tells Argo CD how to interpret Placement results. The ApplicationSet generator queries the Placement (here `suitecrm-active`), gets back a list of cluster names, and creates one Argo CD `Application` per cluster.

## Why Skupper Instead of OpenShift Service Mesh or Submariner

For PostgreSQL streaming replication, we need:
- L4 (TCP) connectivity between clusters
- Encrypted in transit
- No firewall holes for inbound traffic
- Works across cloud providers

Options considered:

| Option | Why Not |
|--------|---------|
| Submariner | Requires cluster-wide networking changes, IPSEC tunnels |
| OpenShift Service Mesh | Layer 7 (HTTP/gRPC) only, doesn't handle PostgreSQL wire protocol |
| Site-to-site VPN | Requires firewall changes, IP address coordination |
| Public exposure | Requires firewall holes, complex TLS/auth setup |
| **Skupper / Service Interconnect** | **L4, mTLS, outbound-only, namespace-scoped** ✓ |

Skupper creates a Virtual Application Network (VAN) using AMQP messaging between cluster routers. The routers establish outbound connections (HTTPS/443) and create L4 tunnels through them. No firewall changes needed.

## Why CloudNativePG Over Crunchy

See the discussion at the top level of this project history. The summary:

- CrunchyDB was acquired by Snowflake in mid-2025; their cloud-native focus shifted toward "Snowflake Postgres" (their managed cloud product), making PGO's long-term roadmap uncertain.
- CloudNativePG is Apache 2.0, originated by EDB, now contributed to CNCF.
- Feature parity for our needs (streaming replication, backups, HA, multi-cluster).
- Not subject to a single vendor's priorities.

## Two-Tier Replication Strategy

The PostgreSQL deployment uses a deliberate two-tier replication design:

### Tier 1: Synchronous (in-cluster, on the active site)

The active cluster runs **2 PostgreSQL instances** with quorum-based synchronous replication (`method: any, number: 1`). Every transaction commit must be acknowledged by at least 1 of the local replicas before returning success to the client.

This gives:
- **RPO = 0** for AZ-level / worker-node failures
- **Automatic intra-cluster failover** managed by CNPG (no human action)
- **No risk of write halt from WAN issues** (the sync requirement is satisfied locally)

CNPG enforces pod anti-affinity by default, so the two instances run on different worker nodes (and ideally different AZs).

### Tier 2: Asynchronous (cross-cluster, to the passive site)

The passive cluster runs as a replica cluster, streaming WAL from the active cluster's primary across the Skupper VAN. This stays **asynchronous** by design.

This gives:
- **RPO ≈ seconds** for region/cluster-level failures
- **No write halt if the WAN link or passive cluster degrades** (commits don't block on remote acknowledgment)
- **Bounded blast radius** for cross-cluster network issues

### Why Not Synchronous Across Clusters?

Synchronous cross-cluster replication is technically possible but undesirable here:

| Concern | Sync cross-cluster | Async cross-cluster (current) |
|---------|-------------------|------------------------------|
| RPO during region failure | 0 | ~seconds |
| Write latency (every commit) | +RTT to passive cluster (~30-100ms) | None |
| Behavior if WAN link breaks | Writes halt | Writes continue, replication catches up |
| Behavior if passive cluster is down | Writes halt | Writes continue |

For a CRM workload, the async trade-off is correct: a few seconds of potential data loss in a regional disaster is far better than the risk of WAN issues halting all writes during normal operation.

### Failure Mode Coverage

This two-tier approach covers the realistic failure modes:

| Failure | Tier 1 (sync local) | Tier 2 (async remote) |
|---------|---------------------|----------------------|
| Worker node dies | ✓ RPO=0, automatic | (not invoked) |
| AZ outage in active cluster | ✓ RPO=0, automatic | (not invoked) |
| Active cluster network blip | ✓ writes continue locally | Catches up after blip |
| Active cluster region disaster | (both local instances down) | ✓ failover to passive |
| Passive cluster down | ✓ writes continue locally | Catches up when restored |
| WAN link broken | ✓ writes continue locally | Catches up when restored |

## Failover Mechanism

Two ways to fail over (see [FAILOVER.md](FAILOVER.md) for full procedure):

**Method 1: Git commit**
- Edit `clusters/passive/postgres/cluster.yaml` to set `replica.enabled: false`
- Edit `clusters/passive/suitecrm/suitecrm.yaml` to set `replicas: 2`
- Commit and push
- Argo CD reconciles within 3 minutes

**Method 2: Label swap**
```bash
oc label managedcluster <old-active> role=passive --overwrite
oc label managedcluster <old-passive> role=active --overwrite
```
- ApplicationSets immediately re-target
- The cluster that's now `role=active` gets `clusters/active/*` deployed (which has primary mode)
- The cluster that's now `role=passive` would get `clusters/passive/*` deployed, but its Postgres is gone

Method 1 is recommended for clarity and audit trail.

## What's NOT in This Repo

Some things are deliberately not in Git:

| Not in repo | Why | How to handle |
|-------------|-----|---------------|
| Database passwords | Sensitive | CNPG generates and stores in Secrets |
| Admin passwords | Sensitive | External Secrets Operator / Sealed Secrets |
| S3 credentials | Sensitive | External Secrets Operator / Sealed Secrets |
| Skupper tokens | Cluster-specific, expire | Generated at runtime by AccessGrant CR |
| TLS certs for routes | Auto-managed | OpenShift Router handles edge termination |

## Failure Modes and Behavior

### Active cluster's compute is gone, network OK
- Argo CD on hub still runs
- Next reconcile detects active cluster unreachable
- ApplicationSets show "OutOfSync" / "Degraded"
- DNS health check fails, Cloudflare flips to passive
- DB clients retry, hit Cloudflare's new endpoint
- **Action**: Run failover procedure (Method 1) to scale up SuiteCRM on passive

### Active cluster's network is partitioned
- Replication lag grows on passive
- Skupper VAN tunnel breaks
- DNS health checks may still succeed if route layer is up
- **Action**: Verify outage with multiple sources before failing over (split-brain risk)

### Hub cluster is down
- Managed clusters keep running their last-deployed configuration
- New changes can't be deployed until hub is restored
- ACM Policies stop reporting compliance status
- **Action**: Standard hub recovery (this is why hub clusters often run with their own HA)

### S3 backup endpoint is down
- VolSync sync jobs fail
- ReplicationSource shows error status
- File uploads on active cluster still work locally - just no offsite backup
- **Action**: Restore S3 access. VolSync resumes automatically.

### Passive cluster is down
- No impact on production - active cluster runs normally
- Replication lag accumulates as WAL waits in active's slot
- **Action**: Restore passive cluster. WAL catches up automatically when standby reconnects.

## Capacity Planning

### Active cluster
- SuiteCRM: 2 pods × (250m CPU, 512Mi RAM)
- PostgreSQL: 2 pods × (250m CPU, 512Mi RAM) + 2 × 10Gi data
  - 1 primary + 1 synchronous local replica for in-cluster RPO=0
- Redis: 1 pod × (100m CPU, 128Mi RAM) + 1Gi data
- Skupper router: ~50m CPU, ~64Mi RAM
- Total: ~950m CPU, ~2.2Gi RAM, ~41Gi storage

### Passive cluster
- SuiteCRM: 0 pods (but PVC exists, 20Gi)
- PostgreSQL: 1 pod × (250m CPU, 512Mi RAM) + 10Gi data
  - Single standby instance; could be scaled to match active after failover
- Redis: 1 pod × (100m CPU, 128Mi RAM) + 1Gi data
- Skupper router: ~50m CPU, ~64Mi RAM
- Total: ~400m CPU, ~700Mi RAM, ~31Gi storage

For multi-cloud production deployments these footprints are negligible. The two PostgreSQL pods on the active cluster should land on different worker nodes (CNPG enforces pod anti-affinity by default) for the synchronous replica to provide real protection.

## Future Enhancements

Things you could add to this setup:

- **External Secrets Operator** for sealed secret management
- **Cert-manager** for Postgres TLS certificate rotation
- **PgBouncer** in front of CNPG for connection pooling
- **Backup of OADP backup configurations** themselves (chicken-and-egg)
- **Submariner** in addition to Skupper for any L3-level workloads
- **Stretched ClusterSet** with more than 2 clusters for multi-region HA
- **Argo CD Agent** to reduce hub-to-managed-cluster traffic (Tech Preview as of late 2025)
- **Event-Driven Ansible (EDA) for automated failover** - implements the "Sleeping through disasters" pattern. See [FAILOVER.md](FAILOVER.md#sleeping-through-disasters-automating-phase-2) for the full design. Requires AAP and the AAP-ACM integration.
