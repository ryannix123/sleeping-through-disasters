# Ansible automation

> **Validated Patterns branch:** the install phases (01–05, `site.yml`) are replaced by `./pattern.sh make install`, and the Skupper link handshake now runs as framework imperative jobs in `ansible/imperative/`. The day-two playbooks below remain; see the README's Known gaps for the ones not yet ported.

Build-time automation for the parts of this pattern that GitOps cannot own.

## What this does and does not do

This is **setup automation, not reconciliation**, and it is **hub-first**.
Almost every playbook talks to the ACM hub and nothing else — ACM and Argo CD
distribute to the managed clusters. Three plays reach the managed clusters
directly, each for a reason the hub cannot cover:

| Play | Why it talks to a managed cluster directly |
|---|---|
| `00-preflight.yml` | Checks storage defaults, stuck kubelet CSRs and pod headroom on each cluster *before* anything is deployed onto it |
| `02-import-active.yml` | Applies the klusterlet that joins the active cluster to the hub — by definition, before ACM can reach it |
| `05-interconnect-link.yml` | The Skupper token handshake and the VolSync key copy |

| Owned by Ansible (hub-only) | Owned by ACM + Argo CD |
|---|---|
| Hub operators, MultiClusterHub (left alone if already installed) | Odoo, CloudNativePG, VolSync, Interconnect manifests |
| Importing the active cluster, labelling both | |
| Applying `hub/`, `applicationsets/`, `policies/` | Installing operators on both clusters |
| Secret distribution **via an ACM Policy** | Pushing secrets to both clusters |
| Reading cluster state **via ACM** (ManagedClusterView) | Drift correction |
| Cloudflare load balancing | |
| Verification (through ACM) | |

Failover is not here either: it is OpenShift Pipelines on the passive cluster
(`clusters/passive/failover/`), gated by the `auto_promote` key — see
[docs/FAILOVER.md](../docs/FAILOVER.md).

**How hub-only works:** secrets are distributed by an enforced ACM
`ConfigurationPolicy` bound to the "both clusters" Placement — declared once on
the hub, pushed to both managed clusters, kept in sync. Where a playbook needs
to read something from a managed cluster (a Route hostname, a CNPG status), it
uses ACM's `ManagedClusterView` to fetch it through the hub rather than
connecting to the cluster directly.

## Setup

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

Fill in `inventory/hosts.yml`. The `hub` host uses `~/.kube/hub.config`;
`active_cluster_name` is the name the active cluster gets in ACM (`active`) and
`passive_cluster_name` is the hub's own `local-cluster`.

The plays that reach the managed clusters directly use the `van_sites` group:
`~/.kube/active.config` for the active site, and the hub's kubeconfig for the
passive site — in this topology the passive *is* the hub. Create both files
once with `oc login`, then strip each to a single context (see the comments in
`inventory/hosts.yml`). `oc` login tokens last 24 hours; preflight tells you
when one has expired.

Then edit `group_vars/all/main.yml` — at minimum:

- `gitops_repo_url` — your fork
- `cloudflare_hostname` — the name users will hit
- `acm_channel` / `gitops_channel` — leave empty to install the catalog's
  current release, or set one to pin

## Secrets

Generate them once and seal them:

```bash
ansible-playbook playbooks/00-generate-secrets.yml
```

This creates `group_vars/all/vault.yml`, encrypts it with Ansible Vault, and writes the vault password to `.vault-pass` (mode 0600, git-ignored).

It generates the Odoo admin passwords, the PostgreSQL replication password, and the Restic password. It **cannot** generate your S3 or Cloudflare credentials, so it leaves `REPLACE-ME` placeholders:

```bash
ansible-vault edit group_vars/all/vault.yml
```

`playbooks/03-secrets.yml` refuses to run while the placeholders are still there.

Re-running `00` never overwrites an existing vault, so passwords cannot rotate by accident. To rotate deliberately, delete `vault.yml` first.

Back up `.vault-pass` somewhere real. It is the only key to the vault.

## Running

Everything, in dependency order:

```bash
ansible-playbook site.yml
```

Or a phase at a time — each targets the hub and is idempotent:

```bash
ansible-playbook playbooks/01-hub-operators.yml      # GitOps + ACM — installs only what is missing
ansible-playbook playbooks/02-import-active.yml      # import the active cluster, label both
ansible-playbook playbooks/00-preflight.yml          # both clusters: storage defaults, kubelet CSRs, pod headroom
ansible-playbook playbooks/02-verify-clusters.yml    # confirm both clusters Ready + labelled
ansible-playbook playbooks/03-secrets.yml            # hub/ bootstrap + odoo namespace + secrets via ACM Policy
ansible-playbook playbooks/04-deploy-gitops.yml      # applicationsets/ + policies/ — the GitOps hand-off
ansible-playbook playbooks/05-interconnect-link.yml  # Skupper link handshake + VolSync key (see note below)
ansible-playbook playbooks/06-cloudflare.yml         # monitor, pools, load balancer
ansible-playbook playbooks/97-reset-after-failover.yml  # AFTER a failover test: safely restore active/passive steady state (see docs/FAILOVER.md)
ansible-playbook playbooks/98-diagnose.yml           # cross-cluster proof: probe row, filestore counts, VAN (see docs/VALIDATION.md)
ansible-playbook playbooks/99-verify.yml             # assertions via ACM, changes nothing
ansible-playbook playbooks/00-predemo-check.yml      # immediately before a demo — see below
```

`01` is safe on any hub. It detects an existing ACM or GitOps install and leaves
it untouched, so a hub that arrives with ACM already running (a demo catalog
cluster, a platform team's hub) needs no special handling.

**Order matters: `03` before `04`.** CloudNativePG creates the `replicator`
role from the `odoo-replicator` Secret at bootstrap. If the workloads land
first, the role is born without its credential and the passive replica can
never authenticate (it shows as endless `pgbasebackup` jobs erroring with
`password authentication failed`). `03` creates the namespace and secrets on
both clusters first; `04` then deploys into a namespace whose credentials
already exist.

The ones you will re-run:

- **`03`** after rotating a password in the vault
- **`05`** to re-link after a cluster reboot, or when a grant expires — it is
  idempotent and skips itself if the VAN is already up
- **`99`** any time you want to confirm the DR posture is still sound

## Before a demo

`00-predemo-check.yml` is read-only and ends in READY or NOT READY. It checks
the failover gate against what *this* demo needs, so tell it which demo you
are giving:

```bash
# Recording or running a live failover — the system must finish on its own:
ansible-playbook playbooks/00-predemo-check.yml

# Showing steady state live (failover on video, or not at all):
ansible-playbook playbooks/00-predemo-check.yml -e expect_auto_promote=false
```

The second is the safer stage setting: with the gate off, a home-internet blip
during the talk is detected and waits for a human instead of promoting the
passive site in front of the audience.

## Notes on specific playbooks

**`01-hub-operators.yml`** reads what is already on the hub before creating
anything. An existing MultiClusterHub or ACM Subscription means ACM is left
alone — no second OperatorGroup (which breaks every operator in the namespace),
no re-pointed channel. With `acm_channel` empty it installs the channel the
cluster's `redhat-operators` catalog marks as default, which is always a
release supported on that OpenShift version, and prints the version it
installed.

**`00-preflight.yml`** has two plays. The hub play confirms GitOps and ACM. The
second runs against both clusters and repairs the two unambiguous problems
itself: it approves pending kubelet CSRs submitted by the cluster's **own**
nodes (a stuck `kubelet-serving` CSR breaks `oc exec`, `oc logs` and
`tkn … logs` while everything else looks healthy), and it marks a
VolumeSnapshotClass default when exactly one matches the default StorageClass's
driver (without one, VolSync fails quietly). Anything ambiguous it reports and
fails on. `-e preflight_fix=false` makes it report-only. It needs `oc` on the
machine running Ansible.

**`02-import-active.yml`** does what the console's "Run import commands"
option does: creates the `ManagedCluster` and `KlusterletAddonConfig` on the
hub, applies the generated import manifests to the active cluster, and waits
for it to report Available. If the active cluster's klusterlet is still
registered to a different (usually retired) hub, it removes that registration
first. It also labels the hub's `local-cluster` as the passive and stops with
an explanation if hub self-management is turned off. Idempotent: an
already-Available cluster is only re-labelled.

**`04-deploy-gitops.yml`** hands off to Argo CD. On a first install expect
failing syncs while the four operators land — the postgres, interconnect and
volsync Applications cannot succeed until their CRDs exist. That is the retry
backoff working, not a problem. On a redeploy with operators already present
it goes green in a couple of minutes.

**`05-interconnect-link.yml`** is the one play that talks to the managed
clusters directly (the `van_sites` group in the inventory). It performs the
Skupper v2 token handshake with plain `kubernetes.core` — deliberately **not**
the `skupper.v2` collection, which shells out to the CLI, waits without a
timeout, and can move a kubeconfig's current-context. The play does exactly
what a working manual handshake does: issue an `AccessGrant` on the active
site, wait for it to be Ready with a URL, apply an `AccessToken` (url, code,
CA) on the passive site, and wait until **both Sites report 2 sites in the
network**. Then it copies the VolSync rsync-tls key from the destination to
the source. It issues its own grant (`odoo-link-grant`) rather than consuming
the Argo-managed one, so re-runs never fight GitOps, and it skips the
handshake entirely if the VAN is already up — safe to re-run after a reboot.

The Skupper controller on the active site wedges after a reboot — its Site
never goes Ready, or its grant server never issues (on a site without a cloud
LoadBalancer its Service sits `<pending>`). Restarting the `skupper-controller`
pod clears it, so the play now does that itself: if either wait runs out, it
restarts the controller once (`skupper_restart_controller.yml`) and waits
again before failing. If the healthy Site then turns out to see both sites
already, the handshake is skipped rather than redone. A controller restart is
always followed by a rollout restart of `skupper-router`
(`skupper_restart_router.yml`), because the router reads its TLS certificate
only at start and keeps serving a replaced one.

Two more failure modes from real mornings, both handled now:

- **Token `404 No such access granted` right after a fresh grant.** A link
  Secret (`token-odoo-active-link`) left on the passive by an earlier run gets
  redeemed in a loop and spends every redemption on the new grant — the active
  controller logs "already redeemed". The play deletes the stale AccessToken,
  Link **and Secret** before redeeming. (A wrong kubeconfig only explains a 404
  if the grant URL in the error is not the active cluster.)
- **Redeemed, but the sites never link** (`Link` Not Operational, passive
  router log says `SSL certificate verify failed`). The active router is
  serving a stale certificate. If the sites don't see each other within two
  minutes, the play rolls the active router once and waits again.

**`98-diagnose.yml`** reports **CATCHING UP** instead of FAIL when the probe row
hasn't reached the passive yet but the replica's WAL replay position is moving
(or the primary lists it in state `catchup`). After the active site has been
offline for hours the backlog can take a while; re-run until it says PASS.

**`06-cloudflare.yml`** talks to the Cloudflare v4 API directly with
`ansible.builtin.uri` (no Ansible module exists for Cloudflare load balancers —
`community.general.cloudflare_dns` is DNS-records only). It reads the two Odoo
Route hostnames through ACM `ManagedClusterView`, so it stays hub-only. Order
matters and is encoded: monitor → pools → load balancer, idempotent by name.

The API token needs **Load Balancing: Edit** on the account plus **DNS: Edit** on the zone.

**`99-verify.yml`** checks the DR posture entirely from the hub: ACM policy
compliance, plus `ManagedClusterView` snapshots asserting the active database
has ready instances and the passive database is still in replica mode. Run it
before a demo.

## Where this goes next

If you later automate failover with Event-Driven Ansible, `05` and `06` are already the callable units a rulebook would invoke. That is why they are standalone plays rather than inline steps in `site.yml`.
