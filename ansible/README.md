# Ansible automation

Build-time automation for the parts of this pattern that GitOps cannot own.

## What this does and does not do

This is **setup automation, not reconciliation.** These playbooks run once when you stand the pattern up. Argo CD keeps everything true afterwards.

| Owned by Ansible | Owned by Argo CD |
|---|---|
| Hub operators, MultiClusterHub | Odoo, CloudNativePG, VolSync, Interconnect manifests |
| Importing and labelling managed clusters | Anything under `clusters/` |
| The three Secrets that are not in Git | Drift correction |
| The Interconnect token transfer | |
| Cloudflare load balancing | |
| Verification | |

Two systems managing the same objects is how you get drift, so the boundary is deliberate. Failover is not here either — that is a reviewed Git commit, by design.

## Setup

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
```

Fill in `inventory/hosts.yml` with the three kubeconfig paths and the names you want ACM to use for each managed cluster.

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

`playbooks/04-secrets.yml` refuses to run while the placeholders are still there.

Re-running `00` never overwrites an existing vault, so passwords cannot rotate by accident. To rotate deliberately, delete `vault.yml` first — and understand that changing `vault_volsync_restic_password` **orphans every existing backup**, because Restic cannot read a repository with a different password.

Back up `.vault-pass` somewhere real. It is the only key to the vault.

## Running

Everything, in dependency order:

```bash
ansible-playbook site.yml
```

Or a phase at a time — each is independently runnable and idempotent:

```bash
ansible-playbook playbooks/01-hub-operators.yml      # GitOps + ACM + MultiClusterHub
ansible-playbook playbooks/02-import-clusters.yml    # import, label, join the clusterset
ansible-playbook playbooks/03-deploy-gitops.yml      # hub/ + applicationsets/, wait for operators
ansible-playbook playbooks/04-secrets.yml            # the three Secrets, identical on both
ansible-playbook playbooks/05-interconnect-link.yml  # token transfer + tunnel check
ansible-playbook playbooks/06-cloudflare.yml         # monitor, pools, load balancer
ansible-playbook playbooks/99-verify.yml             # assertions, changes nothing
```

The ones you will re-run:

- **`04`** after rotating a password in the vault
- **`05`** when the Interconnect `AccessGrant` expires (default 7 days)
- **`99`** any time you want to confirm the DR posture is still sound

## Notes on specific playbooks

**`03-deploy-gitops.yml`** waits for four operators on both clusters. Expect Argo CD to show failing syncs while it waits — the postgres, interconnect and volsync Applications cannot succeed until their CRDs exist. That is the retry backoff working, not a problem.

**`05-interconnect-link.yml`** replaces the fiddliest manual step: export the grant Secret, rename it, strip the server-side metadata, apply it on the other cluster. It also proves the tunnel by running `pg_isready` against the tunnelled service from inside the passive cluster.

**`06-cloudflare.yml`** talks to the Cloudflare v4 API directly with `ansible.builtin.uri`. There is no Ansible module for Cloudflare load balancers — `community.general.cloudflare_dns` covers DNS records only. Order matters and is encoded: a monitor must exist before a pool can reference it, and both pools must exist before the load balancer can order them. Idempotency is lookup-then-create, matching on name.

The API token needs **Load Balancing: Edit** on the account plus **DNS: Edit** on the zone.

**`99-verify.yml`** asserts the things that quietly stop being true: two ready PostgreSQL instances on the active cluster, a genuinely `sync` local replica, the passive database still in replica mode, replication lag within threshold, and Odoo at zero replicas on the passive side. Run it before a demo.

## Where this goes next

If you later automate failover with Event-Driven Ansible, `05` and `06` are already the callable units a rulebook would invoke. That is why they are standalone plays rather than inline steps in `site.yml`.
