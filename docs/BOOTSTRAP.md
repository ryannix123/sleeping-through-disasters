# Bootstrap

Deployment order, start to finish.

The steps are grouped into phases because several of them **fail confusingly if run early**. Each phase notes what must be true before you move on, and which errors are expected rather than real.

## Prerequisites

- **Three OpenShift clusters**, 4.14+: a hub, and two managed clusters in different hyperscalers
- `oc` logged in, cluster-admin on all three
- A **fork of this repo** — you will edit the `repoURL` in the ApplicationSets
- **S3-compatible object storage** for VolSync (AWS S3, Azure Blob via an S3 gateway, MinIO, ODF)
- A **Cloudflare account on a plan that includes Load Balancing** (health checks and failover)

> **Prefer to automate this?** `ansible/` covers every phase below except the
> manifests themselves, which Argo CD owns. Run `ansible-playbook site.yml`,
> or use the per-phase playbooks alongside this document. See
> [../ansible/README.md](../ansible/README.md).

## Order at a glance

| Phase | What | Gate before moving on |
|---|---|---|
| 1 | Hub foundation: operators, import clusters, labels, `hub/` | Both clusters visible in Argo CD |
| 2 | ApplicationSets — operators install first | Four operators `Succeeded` on both clusters |
| 3 | Secrets that are not in Git | Three Secrets present on both clusters |
| 4 | Active site comes up | `odoo-db` healthy, sync replica confirmed, Odoo serving |
| 5 | Link the two sites | `odoo-db-primary` answers from the passive cluster |
| 6 | Passive database, then Cloudflare | Replication lag in seconds |

---

## Phase 1 — Hub foundation

### 1.1 Install the hub operators

> **OpenShift GitOps is not optional and not automatic.** ACM does not install
> OpenShift GitOps — they are separate operators. Argo CD (from the GitOps
> operator) is what reconciles the ApplicationSets to both clusters, so the
> pattern deploys nothing without it. Both subscriptions are below; do not skip
> the GitOps one.

```bash
# OpenShift GitOps
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Advanced Cluster Management
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: open-cluster-management
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: open-cluster-management
  namespace: open-cluster-management
spec:
  targetNamespaces:
    - open-cluster-management
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: open-cluster-management
spec:
  channel: release-2.12
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

Then create the hub itself:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
EOF

oc get multiclusterhub -n open-cluster-management -w   # wait for Running, 5-10 min
```

### 1.2 Import and label the managed clusters

Import both through the ACM console (**Infrastructure → Clusters → Import cluster**), then:

```bash
oc label managedcluster <cluster-a> cluster.open-cluster-management.io/clusterset=odoo-dr
oc label managedcluster <cluster-b> cluster.open-cluster-management.io/clusterset=odoo-dr
oc label managedcluster <cluster-a> role=active
oc label managedcluster <cluster-b> role=passive

oc get managedclusters -L role,cluster.open-cluster-management.io/clusterset
```

### 1.3 Point the repo at your fork

```bash
git clone https://github.com/<you>/sleeping-through-disasters.git
cd sleeping-through-disasters

grep -rl 'ryannix123/sleeping-through-disasters' applicationsets/ \
  | xargs sed -i 's|ryannix123/sleeping-through-disasters|<you>/sleeping-through-disasters|g'

git commit -am "Point at this fork" && git push
```

### 1.4 Apply the hub bootstrap

```bash
oc apply -k hub/
oc get placements -n openshift-gitops
oc get gitopscluster -n openshift-gitops
```

> **Gate.** Both managed clusters must now appear in the Argo CD UI under **Settings → Clusters**. If they do not, stop — every ApplicationSet targets clusters by name, so nothing downstream will land correctly.

---

## Phase 2 — ApplicationSets

```bash
oc apply -k applicationsets/
```

Ten ApplicationSets appear and Argo CD starts reconciling everything at once.

> **Expect failures here, and do not chase them.** The `postgres-*`, `interconnect-*` and `volsync-*` Applications will fail their first syncs because the CRDs they depend on do not exist until the operators finish installing. The retry backoff in each ApplicationSet handles it. This is the noisiest phase of the deployment and almost none of it is real.

```bash
# On each managed cluster
oc get csv -A | grep -E 'cloudnative-pg|volsync|skupper|oadp'
```

> **Gate.** All four operators `Succeeded` on **both** clusters.

---

## Phase 3 — Secrets

Three Secrets are deliberately not in Git. The namespace ApplicationSet has created `odoo` on both clusters by now.

Run on **both** clusters, with **identical values**:

```bash
oc project odoo

# 1. Odoo admin credentials.
#    Same on both clusters, so a failover does not change the login.
oc create secret generic odoo-admin \
  --from-literal=admin-password='<master password>' \
  --from-literal=login-password='<admin login password>' \
  -n odoo

# 2. PostgreSQL replication user.
#    CNPG creates the role on the active cluster from this Secret; the passive
#    cluster authenticates with it. Must be a basic-auth Secret.
oc create secret generic odoo-replicator \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=replicator \
  --from-literal=password='<replication password>' \
  -n odoo

# 3. Object storage for VolSync.
#    Same bucket AND same RESTIC_PASSWORD on both, or the passive cluster
#    cannot read the backups it is supposed to restore from.
oc create secret generic volsync-restic-config \
  --from-literal=AWS_ACCESS_KEY_ID='<key>' \
  --from-literal=AWS_SECRET_ACCESS_KEY='<secret>' \
  --from-literal=AWS_DEFAULT_REGION='us-east-1' \
  --from-literal=RESTIC_REPOSITORY='s3:s3.amazonaws.com/<bucket>/odoo-filestore' \
  --from-literal=RESTIC_PASSWORD='<strong passphrase - save this>' \
  -n odoo
```

> Odoo CrashLoops until `odoo-admin` exists, and the passive database cannot bootstrap until `odoo-replicator` exists on both sides. Both are harmless if you are expecting them.

For production, replace these with Sealed Secrets or External Secrets Operator — see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Phase 4 — Bring the active site up

Let the active cluster settle before touching the passive one. The passive database bootstraps *from* the active primary, so there has to be something to copy.

```bash
# Active cluster
oc get cluster odoo-db -n odoo
oc get pods -n odoo
```

Confirm the synchronous local replica is genuinely synchronous — this is the Tier 1 promise:

```bash
oc exec -n odoo odoo-db-1 -- psql -U postgres -c \
  "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

You want one row with `sync_state = sync`. If it says `async`, the second instance has not caught up yet — wait and re-check.

Odoo's first boot initialises its base modules and takes several minutes; the readiness probe allows for it.

```bash
oc logs -f deployment/odoo -n odoo
oc get route odoo -n odoo
```

> **Gate.** `odoo-db` reports healthy with both instances, one replica is `sync`, and Odoo answers on its route.

---

## Phase 5 — Link the two sites

The passive database cannot bootstrap until it can reach the active primary, so this comes before Phase 6.

```bash
# Active
oc get site,connector,accessgrant -n odoo
# Passive
oc get site,listener -n odoo
```

Transfer the token once:

```bash
# --- Active ---
oc get secret odoo-passive-grant -n odoo -o yaml > /tmp/token.yaml

# Edit /tmp/token.yaml:
#   metadata.name  ->  odoo-active-token
#   remove: namespace, resourceVersion, uid, creationTimestamp, ownerReferences

# --- Passive ---
oc apply -f /tmp/token.yaml -n odoo
oc get accesstoken odoo-active-link -n odoo      # should redeem and go Ready
```

Prove the tunnel works from the passive side:

```bash
oc get svc odoo-db-primary -n odoo
oc run pgcheck --rm -it --restart=Never -n odoo \
  --image=ghcr.io/cloudnative-pg/postgresql:16.6 -- \
  pg_isready -h odoo-db-primary -p 5432
```

> **Gate.** `odoo-db-primary` resolves and accepts connections from the passive cluster. If it does not, the passive `Cluster` will fail `pg_basebackup` repeatedly — noisy, but it recovers once the link is up.

---

## Phase 6 — Passive database, then Cloudflare

The passive `Cluster` bootstraps from the primary and enters replica mode on its own once the link exists. If it has been failing while you set up Phase 5, give it a nudge:

```bash
oc delete cluster odoo-db -n odoo    # Argo CD recreates it immediately
```

Check it is replicating:

```bash
oc get cluster odoo-db -n odoo
oc exec -n odoo odoo-db-1 -- psql -U postgres -c \
  "SELECT now() - pg_last_xact_replay_timestamp() AS lag;"
```

Odoo on the passive cluster should be at **0 replicas** — that is correct, not a failure.

### Cloudflare

1. **Traffic → Load Balancing → Create**
2. Two origin pools, one per cluster route
3. Health check: HTTPS, path `/web/health`, expect 200, interval 60s, 3 retries
4. Active pool first in priority order, passive as fallback
5. Point your hostname at the load balancer
6. Lower the DNS TTL — it dominates real RTO (see [FAILOVER.md](FAILOVER.md))

### Optional — compliance policies

```bash
oc apply -k policies/
```

Results appear under **Governance** in the ACM console.

---

## Verify the whole thing

| Check | Where | Expect |
|---|---|---|
| `oc get cluster odoo-db -n odoo` | active | healthy, 2 instances |
| `pg_stat_replication` | active | one `sync` row (local) and one `async` row (passive) |
| `oc get cluster odoo-db -n odoo` | passive | healthy, replica mode |
| replay lag | passive | seconds |
| `oc get deployment odoo -n odoo` | passive | `0/0` — correct |
| `oc get replicationsource -n odoo` | active | syncing every 2 minutes |
| Cloudflare health check | dashboard | active pool healthy |

Then do the thing the demo does: create a record with an attachment on the active cluster, and confirm it arrives on the passive side within seconds.

```bash
# Run on both, compare
oc exec -n odoo odoo-db-1 -- psql -U odoo -d odoo -c \
  "SELECT count(*) FROM ir_attachment;"
```

---

## From here

Changes are made by editing this repo and committing. Argo CD reconciles within about three minutes.

For failover, see [FAILOVER.md](FAILOVER.md) — including the short list of things to do before running a live demo.
