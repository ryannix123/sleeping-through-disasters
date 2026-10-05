# Sleeping Through Disasters

**Odoo 19 kept continuously available across the loss of an entire region — deployed to two OpenShift clusters, one on-premises and one on a hyperscaler, by Red Hat Advanced Cluster Management and GitOps.**

<p align="center">
  <img src="images/sleeping-through-disasters-logo-badge-v2.svg" alt="Sleeping Through Disasters" width="250">
</p>

---

## The objective

A firm's business of record — its ERP — stays available to its users through the loss of an entire region, with its irreplaceable customer data, documents, configuration and credentials preserved, at the lowest standby cost that meets the firm's chosen availability bar.

And the platform claim underneath it: **OpenShift is the constant.** The same manifests deploy unchanged on AWS, on Azure, or on bare metal in your own building. The substrate below and the global load balancer above are both commodity and swappable.

## Status

This pattern has been **deployed from scratch and failed over end to end**, on a fresh deployment rather than a long-lived one — which is the only test that finds the defects that hide in steady state. It found ten of them. They are fixed, and recorded in [docs/DESIGN-DECISIONS.md](docs/DESIGN-DECISIONS.md).

| | |
|---|---|
| Traffic failover | Automatic — Cloudflare health checks, no human |
| Database promotion | Automated by pipeline, **gated off by default** (`auto_promote`) |
| Filestore restore | Automated by pipeline |
| Return to steady state | Automated — `97-reset-after-failover.yml` |
| Return-to-origin preserving post-failover writes | **Not yet built** — next piece of work |

The gate defaults to `false`. That is a deliberately conservative configuration, not the recommended ceiling — see [Failover](#failover). A clean lights-out run with `auto_promote=true`, from detection through to serving with zero human touches, has not yet been recorded. Until it has, no headline RTO is quoted here.

## Why Odoo

The pattern needs a genuinely stateful, mission-critical application — one with a relational database of record, irreplaceable configuration, and user-uploaded documents that cannot be regenerated. Odoo Community is exactly that: a production ERP and CRM holding customers, quotes, invoices and attachments. If it goes dark, the business stops invoicing.

It is also **PostgreSQL-native**, which is what lets CloudNativePG do real work here rather than being decoration.

The workload image comes from [`odoo-on-openshift`](https://github.com/ryannix123/odoo-on-openshift) — Odoo 19 Community rebuilt on Red Hat UBI 10, running as an arbitrary non-root UID under the `restricted-v2` SCC.

## Dependency rule

**Red Hat products and upstream CNCF projects only.**

| Layer | Component | Provenance |
|---|---|---|
| Platform | OpenShift | Red Hat |
| Multi-cluster management | Advanced Cluster Management | Red Hat |
| GitOps | OpenShift GitOps (Argo CD) | Red Hat |
| Cross-cluster networking | Service Interconnect (Skupper) | Red Hat |
| Volume replication | VolSync | Red Hat |
| Failover automation | OpenShift Pipelines (Tekton) | Red Hat |
| Namespace backup | OADP (Velero) | Red Hat |
| Application base image | UBI 10 | Red Hat |
| Database | CloudNativePG | CNCF (Apache 2.0) |

Red Hat does not ship a supported Kubernetes PostgreSQL operator, so the database operator is the one CNCF component. CloudNativePG runs on **any** CSI driver, which keeps the pattern free of a storage-vendor dependency — the Red Hat + CNCF stack is the *more* portable choice at the storage layer, not the less.

Remove any one of these and a real capability breaks. That is an honest "better together" story, not a SKU list.

## Architecture

<p align="center">
  <img src="images/architecture-diagram.svg" alt="Sleeping Through Disasters architecture: two OpenShift clusters, with CloudNativePG two-tier WAL replication and VolSync PVC-to-PVC filestore replication, both carried over a Red Hat Service Interconnect mTLS virtual application network, plus Cloudflare traffic failover" width="100%">
</p>

The diagram shows the full pattern. Three things worth reading off it:

**The database is protected in two tiers** — synchronous between the local instances on the active cluster (RPO 0 for a node or AZ loss) and asynchronous across the Service Interconnect VAN to the passive cluster (seconds of RPO for a region loss, and it never blocks a production write).

**There is no object storage in the replication path.** VolSync copies the filestore PVC directly to the passive PVC over rsync-tls, inside the same mTLS tunnel the database uses. No bucket, no credentials to rotate, no third failure domain, no egress bill. OADP is present and optional, for point-in-time namespace recovery — a different job from replication.

**The hub rides with the passive site**, so the management plane survives the outage it has to respond to.

On a single-node demo the in-cluster synchronous tier folds to one instance; see [docs/DEMO-TOPOLOGY.md](docs/DEMO-TOPOLOGY.md).

## Two-tier database replication

| Tier | Scope | Mode | Protects against | RPO |
|---|---|---|---|---|
| 1 | Second PostgreSQL instance in the active cluster | **Synchronous** | Node / AZ failure | **0**, promotion automatic |
| 2 | Replica cluster on the passive site | **Asynchronous** over the VAN | Region / cluster loss | seconds, promotion gated |

Cross-region replication stays asynchronous deliberately. Making it synchronous would add cross-cloud round-trip latency to every write and halt production writes whenever the WAN link or the passive cluster degrades. We take RPO 0 where it is cheap, and accept seconds where synchronous would be fragile.

## Repository layout

```
sleeping-through-disasters/
├── hub/                      Hub bootstrap — run once
│   ├── 01-managedclusterset.yaml   Groups both clusters into "odoo-dr"
│   ├── 02-placement-active.yaml    Selects role=active
│   ├── 03-placement-passive.yaml   Selects role=passive
│   ├── 04-placement-both.yaml      Selects the whole set
│   ├── 05-gitopscluster.yaml       Wires ACM placements → Argo CD
│   └── 06-failover-rbac.yaml       Lets the pipeline freeze GitOps on the hub
│
├── applicationsets/          One ApplicationSet per component per role
│
├── clusters/
│   ├── both/                 Operators + namespace (both clusters)
│   ├── active/               Primary DB, Connector, Odoo ×1, VolSync Source
│   └── passive/              Replica DB, Listener, Odoo ×0, VolSync Destination
│       └── failover/         The Tekton Tasks, Pipeline, triggers and RBAC
│
├── ansible/                  Build-time and day-two automation
│   └── playbooks/
│       ├── 01-hub-operators.yml       GitOps + ACM — installs only what is missing
│       ├── 02-import-active.yml       Imports the active cluster into ACM, labels both
│       ├── 00-preflight.yml           Both clusters: storage defaults, kubelet CSRs, pod headroom
│       ├── 00-predemo-check.yml       Read-only readiness check → READY / NOT READY
│       ├── 98-diagnose.yml            Full DB + filestore + VAN diagnosis, both sites
│       └── 97-reset-after-failover.yml  Return to steady state after a failover
│
├── overlays/sno-demo/        Single-node demo variant (see docs/DEMO-TOPOLOGY.md)
├── container/                Odoo image (forked, DR-adjusted)
├── .github/workflows/        Image build + manifest validation
├── policies/                 ACM compliance policies
└── docs/
    ├── ARCHITECTURE.md       Design decisions and trade-offs
    ├── DESIGN-DECISIONS.md   The design record — what was decided, and why
    ├── BOOTSTRAP.md          Step-by-step first deployment
    ├── DEMO-TOPOLOGY.md      Running it on two single-node clusters
    ├── FAILOVER.md           DR runbook
    ├── VALIDATION.md         Commands that prove replication is working
    └── TEARDOWN.md           Clean removal
```

## How it works

Cluster **labels** drive everything. `ansible/playbooks/02-import-active.yml`
imports the active cluster and applies them; by hand they are:

```bash
oc label managedcluster <cluster-a> cluster.open-cluster-management.io/clusterset=odoo-dr
oc label managedcluster <cluster-b> cluster.open-cluster-management.io/clusterset=odoo-dr
oc label managedcluster <cluster-a> role=active
oc label managedcluster <cluster-b> role=passive
```

Three ACM `Placement` resources resolve those labels to clusters. Each ApplicationSet uses the `clusterDecisionResource` generator to create one Argo CD `Application` per matched cluster, pointed at the matching folder in this repo. Argo CD then reconciles continuously, so the passive site can never quietly drift out of readiness.

That continuous reconciliation is also why failover has to begin by freezing GitOps — see [Failover](#failover).

## Protecting the data plane from the control plane

Continuous reconciliation is a virtue right up until the moment Argo decides your database is drift. Three rules keep it from being one:

- Every Application sets `preserveResourcesOnDeletion: true` — deleting an Application never cascade-deletes the workload.
- Every data-bearing resource — both CNPG `Cluster`s, both `odoo-data` PVCs, the `odoo` Namespace — carries `argocd.argoproj.io/sync-options: Prune=false,Delete=false`.
- The failover pipeline freezes the **ApplicationSets** before it pauses the Applications, and verifies the freeze held. Pausing an Application alone is not enough: the ApplicationSet regenerates it, `automated` comes back, and the promotion you just performed is reverted underneath you.

GitOps owns the desired state of the platform. It does not own the right to destroy the customer's data.

## Prerequisites on the hub

Two operators must be installed on the ACM hub **before** anything here works.
ACM does **not** install OpenShift GitOps for you — they are separate operators,
and the pattern is inert without Argo CD on the hub.

| Operator | Why | Installed by |
|---|---|---|
| Advanced Cluster Management | The control plane — placements, policies, cluster fleet | you / the demo platform |
| **OpenShift GitOps (Argo CD)** | **Reconciles the ApplicationSets to both clusters — without it, nothing deploys** | `ansible/playbooks/01-hub-operators.yml`, or install by hand |

The Ansible layer's `01-hub-operators.yml` installs whichever of the two is
missing and leaves an existing installation alone, so it is safe on a hub that
arrives with ACM already running. With no channel pinned it installs the
release the cluster's catalog marks as current. If you deploy by hand, install
the **Red Hat OpenShift GitOps** operator from OperatorHub on the hub first.

Everything else — CloudNativePG, VolSync, Service Interconnect, OpenShift
Pipelines, OADP — is installed onto the managed clusters by GitOps from
`clusters/both/operators/`. You do not install those by hand.

> **Single-node hubs:** ACM, GitOps, Pipelines and the workload together will
> approach the 250-pod ceiling on an SNO (some demo-catalog images raise the
> limit to 500 — `00-preflight.yml` reports the real headroom). Trim the Tekton profile and the
> optional MCE/ACM components rather than disabling `app-lifecycle` — that one
> runs the GitOpsCluster integration, and turning it off silently severs Argo's
> credentials to the managed clusters.

## Quick start

Two ways in.

**Automated** — the Ansible layer handles hub operators, cluster import, the
secrets, the Interconnect token transfer, and Cloudflare:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/00-generate-secrets.yml            # generate + seal the vault
ansible-vault edit inventory/group_vars/all/vault.yml         # add Cloudflare values
ansible-playbook site.yml
```

The vault needs Cloudflare credentials. S3 credentials are only required if you
enable OADP — nothing in the replication path touches object storage.

**By hand** — if you would rather see each step:

```bash
# On the hub, with ACM and OpenShift GitOps already installed:
oc apply -k hub/
oc apply -k applicationsets/
oc apply -k policies/          # optional, compliance reporting
```

Full walkthrough either way, including the three secrets that are deliberately
**not** in Git and the one-time Interconnect token transfer:
**[docs/BOOTSTRAP.md](docs/BOOTSTRAP.md)**. The automation boundary — what
Ansible owns versus what Argo CD owns — is in **[ansible/README.md](ansible/README.md)**.

Before you demo it, run the readiness check. It is read-only and ends in one
word. Tell it which demo you are giving:

```bash
ansible-playbook playbooks/00-predemo-check.yml                              # live or recorded failover
ansible-playbook playbooks/00-predemo-check.yml -e expect_auto_promote=false  # steady state only
```

For a steady-state demo, the gate *should* be off: a network blip mid-talk then
waits for a human instead of promoting the passive site in front of the room.

## Failover

Traffic failover is automatic. Cloudflare health checks shift DNS to the passive
cluster within a few minutes, with no human involved — but DNS alone lands users
on an Odoo that is scaled to zero. **The application has to be woken up, and the
data has to be made writable and complete.** That is what the pipeline does.

Five Tekton Tasks on the passive cluster, in order:

| Task | Why it exists |
|---|---|
| `dr-suspend-gitops` | Freezes the ApplicationSets, pauses the Applications, and verifies the freeze held. Without this, Argo reverts the promotion mid-failover. |
| `dr-promote-database` | Clears `replica.enabled`, waits for the replica to leave recovery, syncs the app role password into the app Secret |
| `dr-restore-filestore` | Rebuilds the app PVC from VolSync's latest snapshot. **Skipping this gives you a promoted database whose attachments are not there.** |
| `dr-scale-application` | Scales Odoo to 1 and waits for `/web/health` |
| `dr-verify` | Confirms the site is actually serving |

The pipeline is started by an `EventListener`, fed by a poller that requires
**two independent signals** before it will act: edge health from Cloudflare, and
`pg_stat_wal_receiver` on the replica. One signal is an opinion; two is evidence.

Whether it promotes without a human is one key in one ConfigMap:

```bash
oc patch configmap dr-failover-config -n odoo --type merge \
  -p '{"data":{"auto_promote":"true"}}'
```

Default is `false`. If the active region is only network-partitioned rather than
genuinely gone, promotion on an ambiguous signal creates split-brain — and from
the passive site, "active is dead" and "I can't currently reach active" look
identical. Two-signal detection is what makes `true` defensible rather than
reckless. The pattern ships the capability because *Sleeping Through Disasters*
is a claim, and the claim is only true if the system can fail over with nobody
watching.

After a test failover, return to steady state:

```bash
ansible-playbook playbooks/97-reset-after-failover.yml
```

It disables the active pool at the edge **before** the old site powers on — that
database still believes it is primary — rebuilds the passive as a fresh replica,
unfreezes the ApplicationSets, and resets the gate. It discards post-failover
writes, which is correct for testing and wrong for production. A true
return-to-origin that preserves them is the next piece of work.

Full runbook: **[docs/FAILOVER.md](docs/FAILOVER.md)**.

## Recovery objectives

Measured on a fresh deployment, not estimated.

| Scope | RPO | Recovery |
|---|---|---|
| Pod, node or AZ failure | **0** — synchronous replica | seconds, automatic |
| Region loss — database | seconds (12–13 s steady-state lag) | promotion completes in **7 s** |
| Region loss — filestore | up to 2 min (the VolSync interval) | restored from snapshot inside the pipeline |
| Both regions lost | **not implemented** — no scheduled backup ships in this repo yet | — |

End-to-end, the mechanical path is roughly five minutes and is **dominated by
detection, not recovery**: about 3 minutes to decide (2 edge health checks plus 2
poll confirmations), 7 seconds to promote, ~90 seconds for the application cold
start, over a 30-second DNS TTL floor. Tightening the health-check interval moves
that number far more than anything in the data path does.

No headline RTO is published until a clean `auto_promote=true` run confirms it
end to end. The numbers above are what was observed; the claim will be made when
it has been earned.

## Operating it

| Playbook | What it does |
|---|---|
| `00-preflight.yml` | Before deploying: storage defaults, stuck kubelet CSRs and pod headroom on both clusters — fixing the unambiguous ones itself |
| `00-predemo-check.yml` | Seven read-only checks, ending in READY or NOT READY. Trust it — an all-red result means all-red. Add `-e expect_auto_promote=false` for a steady-state demo. |
| `98-diagnose.yml` | Writes a probe row on the active primary and confirms it arrives on the passive; reports row counts, filestore file counts on both sides, VolSync sync times, VAN link state and PVC binding. One command, full picture. |
| `99-verify.yml` | ACM policy compliance and CNPG cluster health from the hub |
| `97-reset-after-failover.yml` | Return to steady state |

`98-diagnose.yml` reports the passive **app** volume separately from the VolSync
destination volume. They are not the same volume, and conflating them is how the
empty-filestore defect stayed hidden. In steady state the app volume is expected
to be empty — it is populated at failover, by `dr-restore-filestore`.

The commands behind these, if you want to run them by hand, are in
[docs/VALIDATION.md](docs/VALIDATION.md).

## The container

This repo builds and owns its own Odoo image, forked from
[odoo-on-openshift](https://github.com/ryannix123/odoo-on-openshift) and
adjusted for multi-cluster DR. It lives in `container/`.

```
quay.io/ryan_nix/odoo-openshift-dr:19.0
```

This is a **separate Quay repository** from `odoo-openshift`, not a tag suffix on the
same one. Both push floating tags (`19`, `latest`), so sharing a repository would let
the two pipelines overwrite each other's — whichever ran last would win, and a `latest`
pull would silently return whichever variant. Separate repositories keep the timelines
independent; the layers are content-addressed, so there is no duplicated storage.

The image is rebuilt weekly from the Odoo branch tip, and the tags float. That is
deliberate for a reference pattern: it keeps the demo current with upstream and with UBI
security updates. It does mean a pod restart can pull a newer build than the one you
rehearsed against — see [docs/FAILOVER.md](docs/FAILOVER.md#before-a-live-demo) for the
handful of things to do before a live demo.

Two behaviours were added to the entrypoint for this pattern:

**Standby guard.** A CloudNativePG replica accepts connections but is
read-only. Rather than failing confusingly, the container detects
`pg_is_in_recovery()` and waits for promotion — which matters during failover,
when Odoo can be scheduled before the database finishes promoting.

**`ATTACHMENT_LOCATION`.** Set it to `db` and Odoo stores attachments in
PostgreSQL instead of the filestore, so they ride the same replication stream
as the rest of the data. That closes the window where the promoted database
references files VolSync has not yet copied. Default is `file`; see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for when to change it.

Everything else — UBI 10 base, arbitrary non-root UID, wkhtmltopdf with
patched Qt — is unchanged from upstream.

```bash
cd container
podman build --platform linux/amd64 --build-arg ODOO_VERSION=19.0 \
  -t quay.io/ryan_nix/odoo-openshift-dr:19.0 -f Containerfile .
```

## CI

| Workflow | Runs on | Does |
|---|---|---|
| `build-image.yml` | changes under `container/`, weekly, manual | Builds and pushes the Odoo image to Quay (`19.0`, `19`, `latest`) |
| `validate-manifests.yml` | any manifest change, every PR | `kustomize build` on every overlay, then checks the DR invariants |

The second one matters more than it looks. In a GitOps repo the manifests
*are* the deployment, so a typo is an outage on the passive cluster that
nobody notices until failover. It checks that every ApplicationSet points at a
path and a Placement that exist, that the Interconnect routing keys and hosts
still line up across the two sites, that the active database keeps its
synchronous replica, and that Odoo is never scaled past one replica on a
ReadWriteOnce filestore. It also flags any commit that flips the passive
database out of replica mode — a promotion should be a deliberate, reviewed
change, not something that slips through.

## Known gaps

Recorded here rather than discovered by you at an inconvenient moment. All are
tracked in [docs/DESIGN-DECISIONS.md](docs/DESIGN-DECISIONS.md).

- **No clean lights-out run yet.** `auto_promote=true`, from detection through
  to serving, with zero human touches. Until that is recorded, the RTO above is
  a measurement of parts, not of the whole.
- **No return-to-origin.** `97-reset-after-failover.yml` rebuilds the passive
  and discards post-failover writes. Preserving them — re-bootstrapping the old
  active as a replica of the promoted site, then planning a switch back — is a
  separate design.
- **No backup tier.** CNPG `ScheduledBackup` with volume snapshots, a retention
  policy, and a rehearsed restore. Replication protects against a region; it
  does not protect against a bad migration replicated faithfully to both sites.
- **The Interconnect grant is hosted by the active site.** Flipping the
  direction so the AWS site issues it removes a homelab dependency from the
  handshake.

## Related repository

[odoo-on-openshift](https://github.com/ryannix123/odoo-on-openshift) — the
upstream single-cluster deployment this container was forked from.

## Author

Ryan Nix — this is a personal project, not an official Red Hat solution.
