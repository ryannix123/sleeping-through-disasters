# Architecture

Design decisions, and the reasoning behind them.

## Three clusters

| Cluster | Role |
|---|---|
| **Hub** | Runs ACM and OpenShift GitOps. Holds no application state. Watches this repo and reconciles the two managed clusters. |
| **Active** | `role=active`. Serves users. Runs the PostgreSQL primary. Hyperscaler A. |
| **Passive** | `role=passive`. Database replicates continuously; application scaled to zero. Hyperscaler B. |

The hub is a management plane, not a dependency of the running application. If the hub goes down, both managed clusters keep serving — you simply cannot deploy changes until it returns.

## Why ACM plus GitOps rather than scripts

The earlier iteration of this pattern deployed with shell scripts run separately on each cluster. That fails in a specific, predictable way: the passive cluster drifts, and you discover it at the exact moment you need it. With ACM and Argo CD, the repo is the source of truth and drift is corrected continuously — the standby is provably ready, not hopefully ready.

It also makes failover auditable. Promotion is a commit with an author, a timestamp and a diff, rather than a command someone typed at 3am.

## Two-tier database replication

### Tier 1 — synchronous, in-cluster

The active cluster runs two PostgreSQL instances with quorum synchronous replication (`method: any, number: 1`). Every commit is acknowledged by the local replica before it returns. CNPG applies pod anti-affinity, so the two instances sit on different nodes.

This gives RPO 0 and fully automatic promotion for the failure that actually happens most often: a node or AZ dies.

### Tier 2 — asynchronous, cross-region

The passive cluster is a CNPG **replica cluster**, streaming WAL from the active primary across the Service Interconnect VAN.

### Why not synchronous across regions

| | Synchronous cross-region | Asynchronous (this design) |
|---|---|---|
| RPO on region loss | 0 | seconds |
| Added latency per commit | cross-cloud RTT, 30–100 ms | none |
| WAN link breaks | **writes halt** | writes continue, catches up |
| Passive cluster down | **writes halt** | writes continue, catches up |

For an ERP that people type into all day, coupling production write latency and production uptime to the health of the DR link is the wrong trade. RPO 0 where it is cheap; seconds where synchronous would be fragile.

## Why Service Interconnect rather than a VPN

Cross-hyperscaler PostgreSQL replication needs L4 connectivity, encrypted, without inbound firewall holes.

| Option | Why not |
|---|---|
| Site-to-site VPN | Firewall changes, CIDR coordination, two cloud network teams |
| Submariner | Cluster-wide networking changes, IPsec tunnels |
| Service Mesh | L7 only — does not carry the PostgreSQL wire protocol |
| Public exposure | Inbound firewall holes, bespoke TLS and auth |
| **Service Interconnect** | **L4, mTLS, outbound HTTPS only, namespace-scoped** |

This is what turns cross-cloud replication from a networking project into a config artifact — and it is the concrete proof of the "everything except OpenShift is commodity" claim.

### Connector and Listener direction

This trips people up, so it is worth stating plainly:

- The **Connector** lives on the site that **owns** the workload — the active cluster. It publishes the local PostgreSQL primary onto the VAN.
- The **Listener** lives on the **consuming** site — the passive cluster. It creates a local Service that tunnels across the VAN.

On the active cluster the Connector uses a selector, `cnpg.io/cluster=odoo-db,cnpg.io/instanceRole=primary`, so it follows an in-cluster failover automatically rather than pinning to a pod.

On the passive cluster the Listener publishes a Service named `odoo-db-primary`, deliberately distinct from the local `odoo-db-rw` so the two never collide. The replica cluster's `externalClusters` entry points at that name.

## State classes

Odoo's state is not monolithic. Each class gets the cheapest mechanism that meets its bar.

| Class | Nature | Bar | Mechanism |
|---|---|---|---|
| Database of record | Irreplaceable, constantly changing | RPO 0 committed | CNPG sync local + async cross-region |
| Filestore attachments | Irreplaceable, intermittent | Near-zero | VolSync → object storage, every 2 min |
| Config and credentials | Irreplaceable, rarely changes | RPO 0 | Present on both sites by construction (GitOps + sealed/external secrets) |
| Sessions | Re-derivable | None | Disposable; users re-authenticate after failover |
| Application compute | Stateless | Fast reschedule | Scaled to zero on passive; scale on failover |

## The filestore consistency window — read this one

This is the sharpest Odoo-specific caveat in the pattern, and it must not be glossed over.

Odoo stores attachments as files under `/var/lib/odoo/filestore/<db>/`, keyed by checksum, with `ir_attachment` rows in PostgreSQL pointing at them. Two different replication mechanisms carry them:

- the **database** replicates in **seconds**
- the **filestore** replicates every **2 minutes** via VolSync

So after a regional failover there is a window in which the promoted database contains `ir_attachment` rows referencing files that have not yet reached the passive site. Those attachments show as broken until restored. The records, quotes and invoices are intact — only recently uploaded files are affected.

Three ways to handle it. Pick deliberately.

### Option A — accept and document (current default)

Attachments uploaded in the last sync interval before a regional disaster may be missing. The schedule is set to every 2 minutes, which keeps that window small, and Restic's incremental sync makes a low-change cycle cheap.

There is a floor, though. VolSync does not stack jobs: if a sync takes longer than the interval the next trigger is skipped, so the effective RPO becomes the actual sync duration rather than the schedule. Watch `.status.lastSyncDuration` on the ReplicationSource and back the interval off if it starts approaching the schedule. A large or churn-heavy filestore will find that floor well above two minutes, and no schedule setting will move it — which is the honest argument for Option B.

### Option B — store attachments in the database (true RPO 0)

Attachments live in PostgreSQL and ride the same replication stream as everything else — one mechanism, one RPO, no dangling references.

The container in `container/` supports this directly. Set the environment variable in `clusters/active/odoo/odoo.yaml` and `clusters/passive/odoo/odoo.yaml`:

```yaml
- name: ATTACHMENT_LOCATION
  value: "db"          # default is "file"
```

The entrypoint applies it idempotently on every boot, so flipping the variable and committing is enough. It is equivalent to setting `ir_attachment.location` under **Settings → Technical → System Parameters**.

Odoo migrates existing filestore files into the database lazily as records are touched; run the storage migration from the UI to move them all at once.

Trade-off: database size and WAL volume grow with attachment traffic. For a document-heavy ERP this can be substantial, so size the storage and network accordingly.

This is the option that actually satisfies a stated "zero loss on irreplaceable state" criterion. If the pattern is being presented against that bar, use it.

### Option C — S3-backed filestore

Point Odoo at object storage for attachments so both clusters read the same bucket. Removes the replication problem entirely, at the cost of a hard runtime dependency on the object store during a regional event — which is itself a shared-fate risk worth weighing.

**Recommendation:** default to A for a simple demo; switch to B when the claim being made is near-zero loss on all irreplaceable state — including the document you open on stage.

## Why Odoo runs one replica on the active cluster

The filestore PVC is ReadWriteOnce, and Odoo pods cannot share it. The Deployment therefore uses `replicas: 1` and the `Recreate` strategy.

Scaling out requires one of:

- a **ReadWriteMany** storage class for the filestore, or
- **Option B above** (attachments in the database), which makes the filestore nearly stateless, or
- **Option C** (S3-backed filestore).

If you raise `WORKERS` above 0, Odoo forks worker processes and the longpolling port (8072) starts carrying the bus/live-chat traffic, which needs its own route. The Service already exposes 8072; add a second Route if you enable workers.

Shipping `replicas: 2` against an RWO volume would look better on a slide and fail in practice, so the manifests do not do it.

## What is deliberately not in Git

| Not committed | Why | How it gets there |
|---|---|---|
| Database credentials | Sensitive | Generated by CNPG into `odoo-db-app` |
| Replication credentials | Sensitive | `odoo-replicator` Secret — same value on both clusters |
| Odoo admin passwords | Sensitive | `odoo-admin` Secret — Sealed Secrets or External Secrets Operator |
| Object storage credentials | Sensitive | `volsync-restic-config` Secret, identical on both clusters |
| Interconnect tokens | Short-lived, cluster-specific | Issued at runtime by `AccessGrant` |

**Sealed Secrets vs External Secrets Operator** is a genuine open decision. Sealed Secrets keeps everything in Git with no runtime dependency; ESO gives better rotation but introduces a vault as a shared-fate dependency during exactly the regional event you are designing for. If the firm already runs a vault, ESO wins; otherwise Sealed Secrets is the safer default here.

## Failure modes

| Failure | What happens | Action |
|---|---|---|
| Worker node dies | Tier 1 sync replica promoted by CNPG | None |
| AZ outage, active cluster | Tier 1 sync replica promoted | None |
| Active region lost | Cloudflare shifts traffic; passive DB still in replica mode | Run the failover runbook |
| Active region partitioned, not down | Same symptoms, different cause | **Verify before promoting** — split-brain risk |
| Passive cluster down | Production unaffected; WAL queues on the primary | Restore passive; it catches up |
| WAN link broken | Production unaffected; replication lag grows | Restore link; it catches up |
| Object storage unavailable | Filestore backups fail; app unaffected | Restore access; VolSync resumes |
| Hub cluster down | Both clusters keep serving; no deployments possible | Standard hub recovery |

## Capacity

**Active:** Odoo 1 pod (500m / 1Gi) + PostgreSQL 2 pods (500m / 1Gi each) + Interconnect router ≈ 1.6 vCPU, 3.2 Gi, ~60 Gi storage.

**Passive:** Odoo 0 pods (PVC exists) + PostgreSQL 1 pod + router ≈ 0.6 vCPU, 1.2 Gi, ~40 Gi storage.

The passive footprint is the cost dial. Raising Odoo to 1 replica on the passive side buys back the container start and Odoo warm-up time; the database standby runs in every posture, because you cannot pilot-light the data itself.

## Future work

- **Event-Driven Ansible** for validated automatic promotion (see FAILOVER.md)
- **PgBouncer** in front of CNPG for connection pooling
- **cert-manager** for certificate rotation
- A third cluster, or an on-premise leg, to complete the "any substrate" claim
