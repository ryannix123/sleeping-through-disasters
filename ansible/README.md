# Ansible automation

Build-time automation for the parts of this pattern that GitOps cannot own.

## What this does and does not do

This is **setup automation, not reconciliation**, and it is **hub-only**. Every
playbook talks to the ACM hub and nothing else — ACM and Argo CD distribute to
the managed clusters. You never need a managed-cluster kubeconfig. That is the
whole point of ACM as the control plane, and the automation reflects it.

| Owned by Ansible (hub-only) | Owned by ACM + Argo CD |
|---|---|
| Hub operators, MultiClusterHub | Odoo, CloudNativePG, VolSync, Interconnect manifests |
| Applying `hub/`, `applicationsets/`, `policies/` | Installing operators on both clusters |
| Secret distribution **via an ACM Policy** | Pushing secrets to both clusters |
| Reading cluster state **via ACM** (ManagedClusterView) | Drift correction |
| Cloudflare load balancing | |
| Verification (through ACM) | |

Cluster import + labelling is done once in the ACM console (or `02-verify-clusters.yml`
confirms it). Failover is a reviewed Git commit, by design — not here.

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

Fill in `inventory/hosts.yml` — there is a **single host, the hub**. It uses
your current `oc login` by default, so as long as `oc whoami --show-server`
returns the hub API, you are set. Set `active_cluster_name` and
`passive_cluster_name` to the names as they appear in the ACM Clusters list
(here: `production` and `local-cluster`).

`05-interconnect-link.yml` is the one exception to hub-only: it needs a
kubeconfig for each managed cluster (the `van_sites` group). Create them once
with `oc login` (see the comments in `inventory/hosts.yml`). In this demo the
passive site *is* the hub cluster, so its kubeconfig is the same login you
already have.

Then edit `group_vars/all/main.yml` — at minimum:

- `gitops_repo_url` — your fork
- `cloudflare_hostname` — the name users will hit
- `volsync_s3_bucket` / `volsync_s3_endpoint` / `volsync_s3_region`

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
ansible-playbook playbooks/01-hub-operators.yml      # GitOps + ACM + MultiClusterHub (skip if already up)
ansible-playbook playbooks/02-verify-clusters.yml    # confirm both clusters Ready + labelled
ansible-playbook playbooks/03-secrets.yml            # hub/ bootstrap + odoo namespace + secrets via ACM Policy
ansible-playbook playbooks/04-deploy-gitops.yml      # applicationsets/ + policies/ — the GitOps hand-off
ansible-playbook playbooks/05-interconnect-link.yml  # Skupper link handshake + VolSync key (see note below)
ansible-playbook playbooks/06-cloudflare.yml         # monitor, pools, load balancer
ansible-playbook playbooks/97-reset-after-failover.yml  # AFTER a failover test: safely restore active/passive steady state (see docs/FAILOVER.md)
ansible-playbook playbooks/98-diagnose.yml           # cross-cluster proof: probe row, filestore counts, VAN (see docs/VALIDATION.md)
ansible-playbook playbooks/99-verify.yml             # assertions via ACM, changes nothing
```

Since you imported both clusters through the console, `01` can be skipped if
GitOps and ACM are already running on the hub — start at `02`.

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

## Notes on specific playbooks

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

If the grant never becomes Ready, the Skupper grant server on the active site
is not issuing (on a site without a cloud LoadBalancer its Service sits
`<pending>` and it occasionally wedges); restarting the `skupper-controller`
pod clears it. A token error of `404 No such access granted` means the passive
cluster reached the *wrong* grant server — almost always a kubeconfig pointing
at the wrong cluster; see the single-context rule in `docs/BOOTSTRAP.md`.

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
