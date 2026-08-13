# Sleeping through Disasters: Odoo Multi-Cluster DR with Red Hat ACM

A GitOps-managed disaster recovery solution for **Odoo 19** across two OpenShift clusters, orchestrated by Red Hat Advanced Cluster Management (ACM) and OpenShift GitOps (Argo CD), with **CloudNativePG** for database replication, **VolSync** for filestore replication, and **Skupper** for the secure cross-cluster network.

<p align="center">
  <img src="/images/sleeping-through-disasters-logo-badge-v2.svg" alt="STD Logo" width="250">
</p>

> **This project was previously built around SuiteCRM.** It has been rebuilt on Odoo — see [Why the switch from SuiteCRM to Odoo](#why-the-switch-from-suitecrm-to-odoo) below. The old SuiteCRM implementation remains in this repo's Git history.

## Why the switch from SuiteCRM to Odoo

The pattern is the same; the workload is cleaner. SuiteCRM is a PHP application backed by **MariaDB** and **Redis**, which meant the DR design had to replicate three kinds of state and translate a non-PostgreSQL database into the CloudNativePG world. Odoo is **PostgreSQL-native**, so it maps directly onto CloudNativePG with no translation, and it has **no Redis dependency** — it keeps sessions in its filestore and caches in-process and in PostgreSQL.

That leaves just **two** pieces of state to protect instead of three:

| | SuiteCRM (old) | Odoo (now) |
| --- | --- | --- |
| Database | MariaDB (needed a Postgres story bolted on) | PostgreSQL, native to CNPG |
| Cache/sessions | Redis pod (replicated separately) | None — filestore + in-process |
| File state | Upload volume | Odoo filestore PVC |
| State to replicate | 3 | **2** |

Fewer moving parts means a tighter, more honest RPO story and a simpler failover.

## What ACM Adds

The original design deployed the app with imperative shell scripts run separately on each cluster. With ACM:

- **Single source of truth**: this Git repo defines the desired state of both clusters
- **Declarative cluster configuration**: operators, namespaces, and apps are all manifests
- **Centralized observability**: one ACM console shows the health of both clusters
- **Policy enforcement**: compliance checks pull clusters back to the defined state
- **Placement-driven deployment**: cluster labels (`role=active` / `role=passive`) determine what gets deployed where
- **No more shell scripts on each cluster**: ACM/Argo CD handles application reconciliation

## Proof-of-Concept Topology

This PoC runs on two single-node OpenShift (SNO) clusters — cost-effective, and enough to prove the pattern end to end:

| Role | Cluster | Storage | Notes |
| --- | --- | --- | --- |
| **Active** | Home SNO (OpenShift 4.22, LVMS) | `lvms-vg1` | The workload being protected. Odoo + CNPG primary run here. |
| **Hub + Passive** | AWS SNO | `gp3-csi` | Runs ACM + GitOps **and** serves as the standby. Self-imported as `local-cluster`, labeled `role=passive`. |

### Honest caveat about this topology

Because ACM lives on the same cluster as the passive standby, **this design automates exactly one failure scenario: the home SNO fails, and AWS takes over.** If the AWS cluster is lost, you lose the orchestrator and the standby together — there's no third cluster to drive a failback. That's the right scenario to demonstrate anyway: an on-premises workload protected by failing over to the cloud, orchestrated from the cloud. It is *not* bidirectional DR. A production build would put the hub on its own cluster.

Because both sides are single-node, CloudNativePG runs `instances: 1` (no in-cluster Postgres HA). The DR story here is the **cross-cluster** replication, not in-cluster redundancy.

## Architecture

```
        ┌─────────────────────────────────────────────┐
        │  AWS SNO  —  Hub (ACM + GitOps) + Passive    │
        │                                              │
        │  ACM watches this Git repo → Argo CD deploys │
        │  • CNPG replica (streaming from home)        │
        │  • Odoo at 0 replicas (promoted on failover) │
        │  • VolSync ReplicationDestination            │
        │  • Skupper site (link consumer)              │
        └───────────────────▲──────────────────────────┘
                            │  Skupper VAN (secure mTLS)
                            │  PostgreSQL streaming + filestore
        ┌───────────────────┴──────────────────────────┐
        │  Home SNO  —  Active                          │
        │                                              │
        │  • CNPG primary (source of truth)            │
        │  • Odoo at full replicas (live)              │
        │  • VolSync ReplicationSource (filestore)     │
        │  • Skupper site (link provider)              │
        └──────────────────────────────────────────────┘
```

## What Replicates, and How

| State | Mechanism | Consistency |
| --- | --- | --- |
| PostgreSQL database | CNPG streaming replication (continuous) over the Skupper VAN | Near-real-time; the replica trails by network latency |
| Odoo filestore (`odoo-data` PVC) | VolSync restic, `copyMethod: Snapshot`, every 5 minutes | Snapshotted on a schedule — trails the database |

**The consistency point worth a slide:** Odoo stores attachments on disk in the filestore and references them by path from `ir_attachment` rows. The database streams continuously; the filestore snapshots every 5 minutes. At the failover instant they're therefore *close* but not transactionally identical. For a PoC that's an acceptable and honest RPO story. To eliminate it, Odoo can store attachments **in the database** (`ir_attachment.location`), collapsing the two-state problem into one at the cost of database size.

## Repository Layout

```
acm-odoo/
├── hub/                          # Hub cluster bootstrap (run once)
│   ├── 00-namespace-clusterset.yaml
│   ├── 01-placements.yaml        # active / passive / both
│   ├── 02-gitopscluster.yaml     # wires ACM → Argo CD
│   └── kustomization.yaml
│
├── applicationsets/              # One ApplicationSet per component/role
│   ├── operators-both.yaml       # CNPG, VolSync, Skupper
│   ├── namespace-both.yaml       # odoo namespace
│   ├── postgres-active.yaml      # CNPG primary
│   ├── postgres-passive.yaml     # CNPG replica
│   ├── skupper-active.yaml       # Skupper site + DB export
│   ├── skupper-passive.yaml      # Skupper site + DB import
│   ├── odoo-active.yaml          # Odoo at full replicas
│   ├── odoo-passive.yaml         # Odoo at 0 replicas
│   ├── volsync-active.yaml       # ReplicationSource
│   └── volsync-passive.yaml      # ReplicationDestination
│
├── clusters/
│   ├── both/                     # Applied to both clusters
│   │   ├── operators/            # CNPG, VolSync, Skupper subscriptions
│   │   └── namespace/            # odoo namespace
│   ├── active/                   # Home SNO (lvms-vg1)
│   │   ├── postgres/             # CNPG primary Cluster
│   │   ├── skupper/              # Skupper Site + Connector (exports DB)
│   │   ├── odoo/                 # Deployment at full replicas
│   │   └── volsync/              # ReplicationSource
│   └── passive/                  # AWS SNO (gp3-csi)
│       ├── postgres/             # CNPG replica Cluster
│       ├── skupper/              # Skupper Site + Listener (imports DB)
│       ├── odoo/                 # Deployment at 0 replicas
│       └── volsync/              # ReplicationDestination
│
└── policies/                     # ACM governance
    └── policy-operators-installed.yaml
```

## How It Works

### 1. Cluster Labeling

```bash
# Home SNO is the active workload
oc label managedcluster <home-sno-name> role=active --overwrite

# AWS SNO (the hub itself) is the passive standby
oc label managedcluster local-cluster role=passive --overwrite

# Group both into one ManagedClusterSet
oc label managedcluster <home-sno-name> cluster.open-cluster-management.io/clusterset=odoo-dr --overwrite
oc label managedcluster local-cluster  cluster.open-cluster-management.io/clusterset=odoo-dr --overwrite
```

### 2. Placement Resources Select Clusters

Three Placements determine targeting within the `odoo-dr` set:
- **odoo-both**: every cluster in the set (operators, namespace)
- **odoo-active**: `role=active` (home SNO)
- **odoo-passive**: `role=passive` (AWS SNO / `local-cluster`)

### 3. ApplicationSets Generate Argo CD Apps

Each ApplicationSet uses the `clusterDecisionResource` generator to create one Argo CD `Application` per matched cluster, pointing at the folder in this repo that matches the role.

### 4. Argo CD Reconciles

Argo CD pulls manifests from the matched folder and applies them to the target cluster. Drift is detected and corrected automatically.

### 5. DR Failover Becomes a Git Commit

To fail over, you promote the standby (flip `replica.enabled: false` on the passive CNPG cluster and scale passive Odoo to 1) — or swap the `role` labels and let the placements reconfigure both sides.

## Bootstrap

See [acm-odoo/docs/BOOTSTRAP.md](acm-odoo/docs/BOOTSTRAP.md) for the full process, including the one-time secret and Skupper-token exchanges that can't be pure GitOps (the Skupper link token, the CNPG replication certificate, and the VolSync restic credentials).

Quick version:

```bash
# 1. On the AWS SNO, install ACM + OpenShift GitOps operators.
# 2. Import the home SNO into ACM; the AWS SNO self-imports as local-cluster.
# 3. Label them (see above).
# 4. Bootstrap the hub (Placements + GitOpsCluster):
oc apply -k acm-odoo/hub/

# 5. Deploy everything to the managed clusters:
oc apply -k acm-odoo/applicationsets/
```

Argo CD then installs the operators, creates the `odoo` namespace on both clusters, deploys the CNPG primary on active and the replica on passive, brings up the Skupper VAN, deploys Odoo (full replicas on active, 0 on passive), and configures VolSync replication. The three secret exchanges in BOOTSTRAP.md are the only manual steps.

## Failover

See [acm-odoo/docs/FAILOVER.md](acm-odoo/docs/FAILOVER.md) for the full runbook. In short, when the home SNO is lost:

```bash
# Promote the standby database (stop replication → becomes primary)
oc --context aws-sno -n odoo patch cluster odoo-db --type merge \
  -p '{"spec":{"replica":{"enabled":false}}}'

# Bring Odoo up on the standby
oc --context aws-sno -n odoo scale deployment/odoo --replicas=1
```

The Odoo pod connects to the now-writable database, finds the replicated schema already present, mounts the VolSync-restored filestore, and serves.

## The Odoo Container

The Odoo image this pattern deploys (`quay.io/ryan_nix/odoo-openshift`) is built on Red Hat UBI 10 and comes from the companion **odoo-on-openshift** project. It runs as an arbitrary non-root UID, auto-initializes on first boot, and — relevant here — that first-boot init is a no-op on the passive side, because the replicated database already carries the Odoo schema when the standby is promoted.

## Author

Ryan Nix \<ryan.nix@gmail.com\>

This is a personal project, not an official Red Hat solution.