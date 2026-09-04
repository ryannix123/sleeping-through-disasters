# Demo topology

The pattern describes three clusters. This document describes the two-machine
environment used to demonstrate it, what that environment genuinely proves,
and what it does not.

## Why not deploy the real thing

A default OpenShift install on a hyperscaler is three control-plane nodes plus
three workers, per side. Standing up two of those to demonstrate a DR pattern
is expensive enough that it becomes a reason not to try — which is the same
objection customers raise, so it is worth answering rather than ignoring.

The honest answer is **not** that the pattern needs one node. It is that the
pattern does not require 3+3. Compact three-node clusters collapse the control
plane and workers onto the same machines, and hosted control planes reduce it
further. Single Node OpenShift is a demo convenience, not the recommendation.

## The topology

```
        ┌──────────────────────────────────────────────────────┐
        │  Homelab — Single Node OpenShift                     │
        │  role=active                                         │
        │                                                      │
        │  Odoo ×1   ·   CloudNativePG primary   ·   VolSync   │
        │  Service Interconnect Site + Connector               │
        │  Storage: LVM Storage (lvms-vg1)                     │
        └────────────────────────┬─────────────────────────────┘
                                 │
                    Service Interconnect VAN
                  (outbound HTTPS, mTLS, no VPN)
                                 │
        ┌────────────────────────┴─────────────────────────────┐
        │  AWS — Single Node OpenShift                         │
        │  role=passive   +   ACM hub   +   OpenShift GitOps   │
        │                                                      │
        │  Odoo ×0   ·   CloudNativePG replica   ·   VolSync   │
        │  Service Interconnect Site + Listener                │
        └──────────────────────────────────────────────────────┘
                                 ▲
                    Cloudflare load balancer
              health checks → automatic traffic failover
```

Two machines. Three logical roles.

## Why the hub lives with the passive site

This is the one placement decision that is not negotiable.

Phase 2 of failover — promoting the standby and scaling Odoo up — happens by
committing to Git and letting Argo CD reconcile. If the hub were co-located
with the **active** site, killing the active region would kill ACM and Argo CD
along with the workload, and that mechanism would be gone at exactly the moment
it is needed. You would be reduced to running `oc patch` by hand on the
surviving cluster, live, having just told the audience the pattern is
GitOps-driven.

With the hub on the passive side, the management plane survives the outage it
is meant to respond to.

In production the hub is independent of both sites. Here it rides along with
the DR site so that it survives — and that is worth saying out loud rather than
glossing over.

## What this environment proves

| Claim | Proven here? |
|---|---|
| Cross-substrate failover (on-prem ↔ cloud) | **Yes** — arguably a better proof than cloud-to-cloud |
| Identical manifests on both substrates | **Yes** — same base, one overlay for node count |
| Cross-cluster replication without a VPN | **Yes** — Interconnect over outbound HTTPS |
| GitOps-driven promotion | **Yes** — the hub survives to do it |
| Automatic traffic failover | **Yes** — Cloudflare health checks |
| File-store replication and restore | **Yes** — LVM (active) → Ceph (passive), one manifest |
| ACM Placement-driven targeting | **Yes** |
| **Tier 1: RPO ~0 for node/AZ failure** | **No** — needs more than one node |

That last row is the cost of the environment, and it should be stated plainly
rather than quietly dropped.

## What to say on stage

On the topology:

> "Two clusters and a co-located hub. In production the hub sits independently
> — here it rides along with the DR site so you can watch it survive the
> outage it has to respond to."

On the missing tier:

> "Synchronous in-cluster replication needs more than one node, so this
> environment demonstrates the cross-region tier. The in-cluster tier is the
> same operator, one field: `instances: 2` with a synchronous quorum."

Nobody will object to either. Claiming three clusters and being asked "where's
the hub?" mid-demo is a far worse minute than naming it up front.

## Using the overlay

The base under `clusters/` describes the full pattern. `overlays/sno-demo/`
adapts it for single-node.

Point the ApplicationSets at the overlay paths:

```bash
sed -i 's|path: clusters/active/postgres|path: overlays/sno-demo/active|'  applicationsets/postgres-active.yaml
sed -i 's|path: clusters/passive/postgres|path: overlays/sno-demo/passive|' applicationsets/postgres-passive.yaml
```

Because each overlay aggregates all four components for its side, collapse the
four per-side ApplicationSets into one. Simplest is to keep
`postgres-active` / `postgres-passive` pointing at the overlay and delete the
other six from `applicationsets/kustomization.yaml`:

```yaml
resources:
  - operators.yaml
  - namespace.yaml
  - postgres-active.yaml     # now the whole active site
  - postgres-passive.yaml    # now the whole passive site
```

Rename them if the naming bothers you; nothing depends on it.

### What the overlay changes

**Active:**
- `instances: 2` → `1`
- **removes the `synchronous` block** — see the warning below
- VolSync told to use `lvms-vg1` for the storage class, snapshot class, and cache
- CPU and memory requests trimmed

**Passive:**
- CPU and memory requests trimmed so the node can also run ACM

> **The synchronous block must be removed on a single node.** With
> `instances: 1`, `method: any / number: 1` and `dataDurability: required`,
> PostgreSQL waits indefinitely for a standby that will never exist. Every
> write blocks and Odoo appears frozen. This is not a tuning preference.

## Storage notes — two substrates, one manifest

This is a highlight of the pattern, not a footnote: the two clusters run
**different storage**, and the *same* VolSync manifest replicates between them.

- **Active (homelab)** — LVM Storage, which provisions thin volumes so
  snapshots work, and creates a StorageClass and VolumeSnapshotClass both named
  `lvms-vg1`.
- **Passive (AWS)** — OpenShift Data Foundation / Ceph, with an
  `*-rbdplugin-snapclass` VolumeSnapshotClass and a `ceph-rbd` StorageClass.

The base manifests name **no** snapshot class. VolSync's `copyMethod: Snapshot`
uses each cluster's *default* VolumeSnapshotClass, so the identical manifest
works on LVM, Ceph, EBS, or anything else. That is the storage-agnostic claim,
demonstrated live: LVM on one side, Ceph on the other, replicating with one
manifest.

**Each cluster must have a default VolumeSnapshotClass.** Storage operators
often create a snapshot class without marking it default. Set one per cluster:

```bash
oc get volumesnapshotclass                       # is one marked (default)?
oc patch volumesnapshotclass <name> --type merge \
  -p '{"metadata":{"annotations":{"snapshot.storage.kubernetes.io/is-default-class":"true"}}}'
```

Without a default, the first VolSync sync stalls with
`cannot find default snapshot class`. First sync copies the whole filestore
(minutes on a home uplink); every sync after is an incremental rsync (seconds).

Confirm before demo day, on each cluster:

```bash
oc get storageclass
oc get volumesnapshotclass
```

Two things to watch on LVM specifically:

- **RAID device classes do not support snapshots.** If your `LVMCluster` uses
  `raidConfig`, thin provisioning is unavailable and so are snapshots. Change
  `copyMethod` to `Direct` in that case, which reads a live volume and takes a
  small consistency risk.
- **Snapshots are node-local**, which is irrelevant on SNO but matters if you
  later grow the cluster.

## Reaching the homelab

Cloudflare health-checks originate from its edge, so the homelab needs a
reachable ingress. Cloudflare Tunnel is the natural fit and stays on message —
the GSLB layer is already declared pluggable commodity.

The replication path does **not** need inbound access. Service Interconnect
establishes the VAN with outbound HTTPS from both sides, so a homelab behind
NAT participates without port forwarding. That is worth demonstrating; it is
the single most common objection to cross-site replication.

## ACM local-cluster

Because the hub and the passive site are the same cluster, ACM's own
`local-cluster` is the passive site. Label it accordingly:

```bash
oc label managedcluster local-cluster \
  cluster.open-cluster-management.io/clusterset=odoo-dr --overwrite
oc label managedcluster local-cluster role=passive --overwrite
```

ACM places `local-cluster` in the `default` cluster set initially, so this is a
change rather than an addition. Verify it took before deploying:

```bash
oc get managedclusters -L role,cluster.open-cluster-management.io/clusterset
```

In the Ansible inventory, the `hub` and `passive` hosts point at the same
kubeconfig, and `managed_cluster_name` for the passive host is `local-cluster`.

## Growing out of it

Nothing here is a fork. When you have real clusters, drop the overlay and point
the ApplicationSets back at `clusters/`. The two-tier database design, the
anti-affinity, and the RPO ~0 claim come back with no other change.


## The single-node hub's pod budget

A SNO hub is capped at **250 pods**. ACM + MCE + ODF alone consume ~95, and
installing OpenShift Pipelines (full profile) adds ~13. The first failover
test hit `0/1 nodes are available: Too many pods` — the pipeline could not
even schedule. What helped, in order of cost:

| Lever | Pods freed | Notes |
| --- | --- | --- |
| `TektonConfig` profile `basic` (pipelines + triggers only) | ~6 | `oc patch tektonconfig config --type merge -p '{"spec":{"profile":"basic"}}'` |
| MCE: disable `hive`, `hypershift`, `hypershift-local-hosting`, `assisted-service`, `discovery` | ~10 | Provisioning/discovery components; this pattern *imports* clusters |
| ACM: disable `search`, `insights`, `submariner-addon`, `cluster-backup` | ~8 | Not used by the pattern |
| Remove unrelated operators (e.g. OpenShift Lightspeed) | ~6 | Demo leftovers |
| `KubeletConfig` raising `maxPods` (e.g. 500) | — | The durable fix; **reboots the node** (~10 min hub outage). Plan it. |

**Never disable ACM's `app-lifecycle`.** It looks like the ACM
Application-subscription model this pattern does not use, but it also runs
`multicluster-integrations` — the `GitOpsCluster` controller that mints and
refreshes the tokens Argo CD uses to reach every managed cluster. With it off,
Argo lost its credentials within the hour (`the server has asked for the
client to provide credentials` on every sync). Recovery required re-minting
the `ManagedServiceAccount` token and restarting the Argo application
controller.

## What the passive site costs

The AWS SNO that is both the ACM hub and the warm passive site cost
**$33.92 for nine days** on the Red Hat demo platform — one instance and a
20 GB Ceph volume. That is the pilot-light number: the standby *database* runs
continuously, the application does not, and the bill reflects it.
