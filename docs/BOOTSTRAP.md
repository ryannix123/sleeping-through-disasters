# Bootstrap

First deployment, start to finish.

## Prerequisites

- **Three OpenShift clusters**, 4.14+: a hub, and two managed clusters in different hyperscalers
- `oc` logged in, cluster-admin on all three
- A **fork of this repo** — you will edit the `repoURL` in the ApplicationSets
- **S3-compatible object storage** for VolSync (AWS S3, Azure Blob via S3 gateway, MinIO, ODF)
- A **Cloudflare account on a plan that includes Load Balancing** (health checks and failover)

## 1. Hub operators

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

Once the operator is running, create the hub:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
EOF

# Wait for Running — takes 5–10 minutes
oc get multiclusterhub -n open-cluster-management -w
```

## 2. Import and label the managed clusters

Import both clusters through the ACM console (**Infrastructure → Clusters → Import cluster**), then label them:

```bash
oc label managedcluster <cluster-a> cluster.open-cluster-management.io/clusterset=odoo-dr
oc label managedcluster <cluster-b> cluster.open-cluster-management.io/clusterset=odoo-dr
oc label managedcluster <cluster-a> role=active
oc label managedcluster <cluster-b> role=passive
```

Verify:

```bash
oc get managedclusters -L role,cluster.open-cluster-management.io/clusterset
```

## 3. Point the repo at your fork

```bash
git clone https://github.com/<you>/sleeping-through-disasters.git
cd sleeping-through-disasters

grep -rl 'ryannix123/sleeping-through-disasters' applicationsets/ \
  | xargs sed -i 's|ryannix123/sleeping-through-disasters|<you>/sleeping-through-disasters|g'

git commit -am "Point ApplicationSets at this fork" && git push
```

## 4. Apply the hub bootstrap

```bash
oc apply -k hub/
oc get placements -n openshift-gitops
oc get gitopscluster -n openshift-gitops
```

Both managed clusters should now appear in the Argo CD UI under **Settings → Clusters**.

## 5. Create the secrets that are not in Git

Run this on **each managed cluster**. The namespace may not exist yet on a first run; create it if needed.

```bash
oc new-project odoo 2>/dev/null || oc project odoo

# Odoo admin credentials
oc create secret generic odoo-admin \
  --from-literal=admin-password="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)" \
  --from-literal=login-password="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)" \
  -n odoo
```

> Use the **same** admin values on both clusters, so a failover does not change the login.

VolSync credentials — these **must be identical on both clusters**, same bucket and same `RESTIC_PASSWORD`, or the passive site cannot read the backups:

```bash
oc create secret generic volsync-restic-config \
  --from-literal=AWS_ACCESS_KEY_ID='<key>' \
  --from-literal=AWS_SECRET_ACCESS_KEY='<secret>' \
  --from-literal=AWS_DEFAULT_REGION='us-east-1' \
  --from-literal=RESTIC_REPOSITORY='s3:s3.amazonaws.com/<bucket>/odoo-filestore' \
  --from-literal=RESTIC_PASSWORD='<a strong passphrase — save this>' \
  -n odoo
```

For production, replace both with Sealed Secrets or External Secrets Operator. See ARCHITECTURE.md.

## 6. Deploy

```bash
oc apply -k applicationsets/
```

Ten ApplicationSets appear, generating Argo CD Applications per cluster. Operators install first; the rest retries until they are ready — typically 5–10 minutes.

```bash
# On each managed cluster
oc get csv -A | grep -E 'cloudnative-pg|volsync|skupper|oadp'
```

## 7. Link the two sites

The VAN needs a one-time token transfer. On the **active** cluster the `AccessGrant` produces a Secret; the **passive** cluster consumes it as `odoo-active-token`.

```bash
# --- Active cluster ---
oc get accessgrant odoo-passive-grant -n odoo -o yaml    # confirm it is Ready
oc get secret odoo-passive-grant -n odoo -o yaml > /tmp/token.yaml

# Edit /tmp/token.yaml:
#   metadata.name -> odoo-active-token
#   remove: namespace, resourceVersion, uid, creationTimestamp, ownerReferences

# --- Passive cluster ---
oc apply -f /tmp/token.yaml -n odoo
oc get accesstoken odoo-active-link -n odoo    # should redeem and go Ready
```

Confirm the link and the tunnelled service:

```bash
# Passive cluster
oc get site,listener -n odoo
oc get svc odoo-db-primary -n odoo
```

## 8. Verify replication

```bash
# Active
oc get cluster odoo-db -n odoo
oc exec -n odoo odoo-db-1 -- psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

You should see the local synchronous replica **and** the remote standby.

```bash
# Passive — replication lag
oc exec -n odoo odoo-db-1 -- psql -U postgres -c \
  "SELECT now() - pg_last_xact_replay_timestamp() AS lag;"
```

## 9. Check Odoo

```bash
# Active
oc get pods -n odoo            # odoo-* Running, odoo-db-1 and -2 Running
oc get route odoo -n odoo
```

First boot initialises Odoo's base modules and can take several minutes; the readiness probe allows for it. Watch with `oc logs -f deployment/odoo -n odoo`.

```bash
# Passive — Odoo should be at 0 replicas, database running
oc get deployment odoo -n odoo
oc get cluster odoo-db -n odoo
```

## 10. Cloudflare load balancer

1. **Traffic → Load Balancing → Create**
2. Add two origin pools, one per cluster route
3. Health check: HTTPS, path `/web/health`, expect 200, interval 60s, 3 retries
4. Set the active pool first in priority order, passive as fallback
5. Point your hostname at the load balancer
6. Lower the DNS TTL — it dominates real RTO (see FAILOVER.md)

Add both hostnames to Odoo's trusted proxy handling if you use a custom domain; `proxy_mode` is already enabled in the image.

## 11. Optional — compliance policies

```bash
oc apply -k policies/
```

Results appear under **Governance** in the ACM console.

## Done

From here, changes are made by editing this repo and committing. Argo CD reconciles within about three minutes.

For failover, see [FAILOVER.md](FAILOVER.md).
