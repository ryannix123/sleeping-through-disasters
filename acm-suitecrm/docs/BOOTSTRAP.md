# Bootstrap Guide

End-to-end setup for a fresh deployment of SuiteCRM with ACM-managed DR.

## Prerequisites

You'll need:

- **3 OpenShift clusters** running 4.14+:
  - 1 hub cluster (where ACM and OpenShift GitOps run)
  - 2 managed clusters (one will be active, one passive)
- **Cluster-admin access** to all three clusters
- **A Git repo** containing this codebase (fork it and update the `repoURL` references in `applicationsets/*.yaml`)
- **S3-compatible object storage** for VolSync backups (AWS S3, MinIO, ODF, etc.)
- **DNS-based load balancer** for active/passive failover (Cloudflare, F5 GTM, AWS Route 53, etc.)

## Step 1: Hub Cluster Operators

On the hub cluster, install:

```bash
# OpenShift GitOps (provides Argo CD)
cat <<EOF | oc apply -f -
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
cat <<EOF | oc apply -f -
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

# Wait for ACM to install, then create MultiClusterHub
oc wait --for=condition=ready -n open-cluster-management \
  pod -l app=multiclusterhub-operator --timeout=300s

cat <<EOF | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
EOF
```

Wait for ACM to fully reconcile (5-10 minutes). Verify:

```bash
oc get multiclusterhub -n open-cluster-management
# STATUS should be: Running
```

## Step 2: Import Managed Clusters

In the ACM web console:

1. Navigate to **Infrastructure → Clusters → Cluster sets**
2. Create a cluster set named `suitecrm-dr`
3. Navigate to **Infrastructure → Clusters → Managed clusters**
4. Click **Import cluster** and follow prompts for each managed cluster
5. After import, edit each cluster and add it to the `suitecrm-dr` ClusterSet

Or via CLI:

```bash
# For each managed cluster, follow the import wizard, then:
oc label managedcluster <cluster-name> \
  cluster.open-cluster-management.io/clusterset=suitecrm-dr

# Designate the active and passive clusters
oc label managedcluster <active-cluster-name> role=active
oc label managedcluster <passive-cluster-name> role=passive
```

Verify:

```bash
oc get managedclusters -L role,cluster.open-cluster-management.io/clusterset
```

Output should look like:
```
NAME              HUB ACCEPTED   MANAGED CLUSTER URLS                ROLE      CLUSTERSET
cluster-aws       true           https://api.aws.example.com:6443    active    suitecrm-dr
cluster-azure     true           https://api.azure.example.com:6443  passive   suitecrm-dr
local-cluster     true           https://api.hub.example.com:6443
```

## Step 3: Update Repository References

Before applying, update the `repoURL` in each ApplicationSet to point to your fork:

```bash
# On your laptop, in your fork of this repo
find applicationsets -name '*.yaml' -exec sed -i \
  's|https://github.com/ryannix123/acm-suitecrm.git|https://github.com/<your-org>/acm-suitecrm.git|g' {} \;

git commit -am "Update repoURL to fork" && git push
```

Also update the `site_url` ConfigMaps to your actual domain:

```bash
sed -i 's|https://crm.example.com|https://crm.your-domain.com|g' \
  clusters/active/suitecrm/configmap.yaml \
  clusters/passive/suitecrm/configmap.yaml
git commit -am "Set site_url" && git push
```

## Step 4: Apply Hub Bootstrap

On the hub cluster:

```bash
oc apply -k hub/
```

This creates:
- The `suitecrm-acm` namespace
- `ManagedClusterSet` and bindings
- The three Placements (active, passive, both)
- `GitOpsCluster` integrating ACM with Argo CD

Verify:

```bash
oc get placements -n openshift-gitops
oc get gitopscluster -n openshift-gitops
# Argo CD should now show your managed clusters under Settings → Clusters
```

## Step 5: Create Required Secrets

Some secrets must exist on the managed clusters before Argo CD reconciles, since they are referenced by Deployments.

**Recommended approach: External Secrets Operator** (or Sealed Secrets, or Vault)

If you're not ready for that yet, create them imperatively. Run this against each managed cluster:

```bash
# Switch to active cluster context
oc login --token=... --server=https://api.active-cluster.example.com:6443

# Create namespace if Argo CD hasn't yet
oc new-project suitecrm 2>/dev/null || oc project suitecrm

# Admin credentials for SuiteCRM
oc create secret generic suitecrm-admin \
  --from-literal=username=admin \
  --from-literal=password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 16)" \
  -n suitecrm

# S3 credentials for VolSync
oc create secret generic volsync-restic-config \
  --from-literal=AWS_ACCESS_KEY_ID="<your-key>" \
  --from-literal=AWS_SECRET_ACCESS_KEY="<your-secret>" \
  --from-literal=AWS_DEFAULT_REGION="us-east-1" \
  --from-literal=RESTIC_REPOSITORY="s3:s3.amazonaws.com/your-bucket/suitecrm" \
  --from-literal=RESTIC_PASSWORD="$(openssl rand -base64 32)" \
  -n suitecrm

# Repeat on passive cluster - VolSync secrets MUST match the active
# (same RESTIC_PASSWORD, same bucket) so it can read the backups.
```

## Step 6: Apply ApplicationSets

Back on the hub cluster:

```bash
oc apply -k applicationsets/
```

This deploys 10 ApplicationSets. Each generates one Argo CD Application per matched cluster.

Verify in Argo CD UI (`oc get route -n openshift-gitops`):

You should see Applications appearing:
- `suitecrm-operators-<active-cluster>`
- `suitecrm-operators-<passive-cluster>`
- `suitecrm-namespace-<active-cluster>`
- `suitecrm-namespace-<passive-cluster>`
- `suitecrm-postgres-<active-cluster>`
- `suitecrm-postgres-<passive-cluster>`
- ... etc.

## Step 7: Wait for Operator Installation

The operators need to install before the rest of the stack can deploy. Argo CD will retry until they're ready, which usually takes 5-10 minutes.

Monitor:

```bash
# On each managed cluster
oc get csv -A | grep -E 'cloudnative-pg|volsync|skupper|oadp'
# All should show: Succeeded
```

## Step 8: Bridge the Skupper Token

Skupper needs a one-time token transfer between clusters. The active cluster's `AccessGrant` produces a Secret; the passive cluster needs that Secret as `suitecrm-active-token`.

**Option A: Manual transfer (one-time)**

```bash
# On active cluster
oc get secret suitecrm-passive-grant -n suitecrm -o yaml > token.yaml

# Edit token.yaml: change name to "suitecrm-active-token", remove namespace,
# remove resourceVersion/uid

# On passive cluster
oc apply -f token.yaml -n suitecrm
```

**Option B: ACM ManifestWork (automated)**

A future enhancement would use ACM `ManifestWork` to copy the token between clusters automatically. For now, manual transfer is simplest.

## Step 9: Apply Policies (Optional)

For compliance monitoring:

```bash
oc apply -k policies/
```

Check status in ACM console under **Governance**.

## Step 10: Verify End-to-End

```bash
# On active cluster
oc get cluster -n suitecrm suitecrm-db
# STATUS: Cluster in healthy state

oc get pods -n suitecrm
# Should see: suitecrm-db-1, suitecrm-db-2, redis-*, suitecrm-* (2 replicas), skupper-router-*

oc get route -n suitecrm suitecrm
# Visit the URL, log in with admin credentials

# On passive cluster
oc get cluster -n suitecrm suitecrm-db
# STATUS: Cluster in healthy state (with replica icon)

oc get pods -n suitecrm
# Should see: suitecrm-db-1, redis-*, NO suitecrm-* (replicas: 0), skupper-router-*

# Verify replication is working
oc exec -n suitecrm suitecrm-db-1 -- psql -U postgres -c \
  "SELECT now() - pg_last_xact_replay_timestamp() AS lag;"
# Lag should be a few seconds or less
```

## Step 11: Configure DNS Failover

Set up your DNS provider to:
- Primary record points to the active cluster's route
- Failover record points to the passive cluster's route
- Health check on `https://<active>/health` triggers failover

For Cloudflare specifically:
1. Create a Load Balancer in Cloudflare dashboard
2. Add both cluster routes as origins
3. Configure health check (HTTP, port 443, path `/health`, expect 200)
4. Set active cluster as primary, passive as fallback
5. Point your DNS record at the load balancer

## Done

The deployment is now fully managed by ACM and Argo CD. Future changes are made by:

1. Editing manifests in this repo
2. Committing to Git
3. Argo CD reconciles automatically (typically within 3 minutes)

For DR failover, see [FAILOVER.md](FAILOVER.md).
