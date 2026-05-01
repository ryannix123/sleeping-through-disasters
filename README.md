# Sleeping through Disasters: SuiteCRM Multi-Cluster DR with Red Hat ACM

A GitOps-managed disaster recovery solution for SuiteCRM 8 across multiple OpenShift clusters, orchestrated by Red Hat Advanced Cluster Management (ACM) and OpenShift GitOps (Argo CD).

<p align="center">
  <img src="/images/logo.jpg" alt="STD Logo" width="250">
</p>


## What ACM Adds

The previous design deployed SuiteCRM with imperative shell scripts run separately on each cluster. With ACM:

- **Single source of truth**: This Git repo defines the desired state of both clusters
- **Declarative cluster configuration**: Operators, namespaces, and apps are all manifests
- **Centralized observability**: One ACM console shows the health of both clusters
- **Policy enforcement**: Compliance checks ensure clusters drift back to defined state
- **Placement-driven deployment**: Cluster labels (`role=active` / `role=passive`) determine what gets deployed where
- **No more shell scripts on each cluster**: ACM/Argo CD handles application reconciliation

## Architecture

```
                  ┌──────────────────────────────┐
                  │  Hub Cluster (ACM + GitOps)  │
                  │                              │
                  │  Watches Git repo →          │
                  │  Deploys via Argo CD         │
                  │  ApplicationSets             │
                  └──────────┬───────────────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
       ┌──────────┐   ┌──────────┐   ┌──────────┐
       │  Active  │   │ Passive  │   │  Future  │
       │ Cluster  │   │ Cluster  │   │ Clusters │
       │ role=    │   │ role=    │   │          │
       │  active  │   │ passive  │   │          │
       └──────────┘   └──────────┘   └──────────┘
```

## Repository Layout

```
acm-suitecrm/
├── hub/                          # Hub cluster bootstrap (run once)
│   ├── 00-namespace.yaml
│   ├── 01-managedclusterset.yaml # Group active+passive into one set
│   ├── 02-placement-active.yaml  # Selects clusters with role=active
│   ├── 03-placement-passive.yaml # Selects clusters with role=passive
│   ├── 04-placement-both.yaml    # Selects all clusters in the set
│   ├── 05-gitopscluster.yaml     # Wires ACM → Argo CD
│   └── kustomization.yaml
│
├── applicationsets/              # ArgoCD ApplicationSets (deployed to hub)
│   ├── operators-both.yaml       # Operators needed on both clusters
│   ├── namespace-both.yaml       # SuiteCRM namespace creation
│   ├── postgres-active.yaml      # CNPG primary cluster
│   ├── postgres-passive.yaml     # CNPG standby cluster
│   ├── skupper-active.yaml       # Skupper init + token gen
│   ├── skupper-passive.yaml      # Skupper init + link
│   ├── suitecrm-active.yaml      # SuiteCRM at full replicas
│   ├── suitecrm-passive.yaml     # SuiteCRM at 0 replicas
│   ├── volsync-active.yaml       # ReplicationSource
│   └── volsync-passive.yaml      # ReplicationDestination
│
├── clusters/
│   ├── both/                     # Manifests applied to both clusters
│   │   ├── operators/            # CNPG, VolSync, Skupper, OADP
│   │   └── namespace/            # SuiteCRM project + RBAC
│   ├── active/
│   │   ├── postgres/             # Primary CNPG Cluster
│   │   ├── skupper/              # Skupper Site (interior router)
│   │   ├── suitecrm/             # App + Redis at full replicas
│   │   └── volsync/              # ReplicationSource
│   └── passive/
│       ├── postgres/             # Standby CNPG Cluster
│       ├── skupper/              # Skupper Site (linked to active)
│       ├── suitecrm/             # App at 0 replicas, Redis at 1
│       └── volsync/              # ReplicationDestination
│
├── policies/                     # ACM Policy resources
│   ├── policy-operators-installed.yaml
│   └── policy-no-default-sa-tokens.yaml
│
└── docs/
    ├── ARCHITECTURE.md
    ├── BOOTSTRAP.md              # Step-by-step hub setup
    └── FAILOVER.md               # DR failover runbook
```

## How It Works

### 1. Cluster Labeling

Active and passive clusters are labeled in ACM:

```bash
# Mark active cluster
oc label managedcluster cluster-aws-east role=active

# Mark passive cluster
oc label managedcluster cluster-azure-west role=passive

# Both clusters are part of the same ManagedClusterSet
oc label managedcluster cluster-aws-east cluster.open-cluster-management.io/clusterset=suitecrm-dr
oc label managedcluster cluster-azure-west cluster.open-cluster-management.io/clusterset=suitecrm-dr
```

### 2. Placement Resources Select Clusters

Three Placement resources determine targeting:
- **placement-both**: matches `clusterset=suitecrm-dr` (both clusters)
- **placement-active**: matches `clusterset=suitecrm-dr,role=active` (just active)
- **placement-passive**: matches `clusterset=suitecrm-dr,role=passive` (just passive)

### 3. ApplicationSets Generate Argo CD Apps

Each ApplicationSet uses the `clusterDecisionResource` generator to create one Argo CD `Application` per matched cluster. The Application points to a different folder in this repo depending on which Placement matched.

### 4. Argo CD Reconciles

Argo CD pulls manifests from the matched folder and applies them to the target cluster. Drift is detected and corrected automatically.

### 5. DR Failover Becomes a Git Commit

To fail over, you change a label on the cluster (or commit a YAML change that flips `replica.enabled` on the standby Cluster CR). ACM/Argo CD takes care of the rest.

## Bootstrap

See [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) for the full setup process.

Quick version:

```bash
# 1. On the hub cluster, install OpenShift GitOps and ACM operators
# 2. Import your active and passive clusters into ACM
# 3. Label them
oc label managedcluster <active-cluster> role=active
oc label managedcluster <passive-cluster> role=passive
oc label managedcluster <active-cluster> cluster.open-cluster-management.io/clusterset=suitecrm-dr
oc label managedcluster <passive-cluster> cluster.open-cluster-management.io/clusterset=suitecrm-dr

# 4. Apply hub bootstrap (creates Placements + GitOpsCluster)
oc apply -k hub/

# 5. Apply ApplicationSets (deploys everything to managed clusters)
oc apply -k applicationsets/
```

That's it. Argo CD takes care of:
- Installing operators on both clusters
- Creating the SuiteCRM namespace on both clusters
- Deploying CNPG primary on active, standby on passive
- Setting up Skupper VAN
- Deploying SuiteCRM (full replicas on active, 0 on passive)
- Configuring VolSync replication

## Failover

See [docs/FAILOVER.md](docs/FAILOVER.md) for full runbook.

In short, failover swaps cluster labels:

```bash
# Demote active → passive
oc label managedcluster cluster-aws-east role=passive --overwrite

# Promote passive → active
oc label managedcluster cluster-azure-west role=active --overwrite
```

ApplicationSets pick up the new placements and reconfigure both clusters automatically.

## Author

Ryan Nix \<ryan.nix@gmail.com\>

This is a personal project, not an official Red Hat solution.
