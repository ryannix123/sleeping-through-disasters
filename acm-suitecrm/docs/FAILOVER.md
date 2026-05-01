# DR Failover Runbook

How to fail over from the active cluster to the passive cluster.

## When to Use This

Use this runbook when:
- The active cluster is **confirmed unavailable** for an extended period
- A planned maintenance window requires shifting traffic to the passive cluster
- A regional outage affects the active cluster's underlying infrastructure

**Do NOT** run a failover for transient issues. PostgreSQL standby promotion is a one-way operation - once promoted, the standby cannot be re-attached as a replica without rebuilding from scratch.

## Failover Methods

There are two ways to fail over with this ACM-managed setup:

1. **Git commit (recommended)** - Edit YAML in this repo, commit, push. Argo CD reconciles. Fully auditable.
2. **Label swap (fastest)** - Change `role` labels on managed clusters. ApplicationSets immediately re-target.

## Method 1: Git Commit Failover (Recommended)

This is the slower but more auditable approach. All changes go through your normal PR review process, providing a paper trail.

### Step 1: Promote the standby database

In `clusters/passive/postgres/cluster.yaml`, change:

```yaml
spec:
  replica:
    enabled: true       # ← change to false
    source: suitecrm-db-primary
```

to:

```yaml
spec:
  replica:
    enabled: false      # PROMOTED to primary
    source: suitecrm-db-primary
```

Commit and push. Argo CD will patch the `Cluster` CR within 3 minutes; CNPG will then promote the standby.

### Step 2: Scale up SuiteCRM on passive cluster

In `clusters/passive/suitecrm/suitecrm.yaml`, change:

```yaml
spec:
  replicas: 0           # ← change to 2
```

to:

```yaml
spec:
  replicas: 2           # ACTIVATED
```

Commit and push.

### Step 3: Trigger VolSync restore

VolSync restore is triggered by annotation, not by a YAML edit. Run on the passive cluster:

```bash
oc annotate replicationdestination suitecrm-data-restore \
  -n suitecrm \
  volsync.backube/manual-trigger=$(date +%s) --overwrite
```

Wait for restore to complete:

```bash
oc get replicationdestination suitecrm-data-restore -n suitecrm \
  -o jsonpath='{.status.lastSyncTime}'
```

### Step 4: Update DNS

In Cloudflare (or your DNS provider), promote the passive cluster's route to primary.

If you're using Cloudflare Load Balancer with health checks, this happens automatically.

### Step 5: Verify

```bash
# Check app responds
curl -s -o /dev/null -w "%{http_code}\n" https://crm.example.com/health
# Should return: 200

# Check database is now primary
oc exec suitecrm-db-1 -n suitecrm -- psql -U postgres -c \
  "SELECT pg_is_in_recovery();"
# Should return: f
```

## Method 2: Label Swap Failover (Fastest)

This swaps the `role` labels on the managed clusters. ApplicationSets immediately re-target, causing Argo CD to redeploy with the appropriate replica counts and database modes.

### Step 1: Swap the labels

On the hub cluster:

```bash
# Demote the failed/old-active cluster
oc label managedcluster <old-active> role=passive --overwrite

# Promote the standby cluster
oc label managedcluster <old-passive> role=active --overwrite
```

Within 3 minutes (the `requeueAfterSeconds` in the ApplicationSets), Argo CD will:
- Stop deploying `clusters/active/*` to the old active cluster, start deploying `clusters/passive/*`
- Stop deploying `clusters/passive/*` to the old passive cluster, start deploying `clusters/active/*`

### Step 2: Trigger VolSync restore

Same as Method 1, Step 3.

### Step 3: Update DNS

Same as Method 1, Step 4.

### Caveat

The label swap approach has a subtle issue: when the new active cluster (formerly passive) gets `clusters/active/postgres/cluster.yaml` applied, Argo CD will try to apply a `Cluster` CR without `replica.enabled`, which CNPG interprets as "make this a primary." That works because the standby was already promoted by the absence of replica config.

However, if the underlying disks haven't actually been promoted yet (e.g., the old standby was never reachable), this could cause issues. Method 1 is more deterministic.

## Failback (After Old Active Recovers)

When the original active cluster comes back online, you have a choice:

**Option A: Stay on the new active**
- Just keep running on the cluster you failed over to
- The recovered cluster takes over the passive role
- Simplest option

**Option B: Failback to the original active**
- Requires rebuilding the original active's database from a fresh `pg_basebackup` of the new primary
- Then doing another failover, this time in reverse
- Only do this if there's a strong reason (e.g., the original cluster has better hardware)

### Steps for Option A (recommended):

1. Wait for the old active cluster to fully recover and re-join ACM
2. Verify it's healthy: `oc get managedcluster <old-active>`
3. The labels are already swapped (from Step 1 of failover), so it's already in the passive role
4. The old database on it will be stale - delete it and let Argo CD rebuild as a fresh standby:

```bash
# On the old active (now passive) cluster
oc delete cluster suitecrm-db -n suitecrm
oc delete pvc -l cnpg.io/cluster=suitecrm-db -n suitecrm
```

Argo CD will recreate the `Cluster` CR with `replica.enabled: true`. CNPG will run `pg_basebackup` from the new primary, and replication resumes.

This typically completes in 10-30 minutes depending on database size.

## Pre-Failover Checklist

Before running a failover, verify:

- [ ] The active cluster is genuinely unreachable (not a DNS or local network issue on your end)
- [ ] The passive cluster's database is up-to-date (`pg_last_xact_replay_timestamp` lag < 30 seconds)
- [ ] VolSync ReplicationSource on active was syncing successfully before the outage
- [ ] You have access to update DNS records
- [ ] Stakeholders have been notified

## Post-Failover Checklist

- [ ] Application is reachable and responsive on the new active cluster
- [ ] Users can log in
- [ ] File uploads work (test by attaching a file to a record)
- [ ] Background scheduler is running (`oc get cronjob -n suitecrm`)
- [ ] DNS has fully propagated (test from external network)
- [ ] Monitoring alerts are reset
- [ ] Postmortem incident scheduled

## Testing Failover (Without Disrupting Production)

Once a quarter, test failover end-to-end without affecting users:

1. Set up a third "test" cluster as a temporary passive
2. Run the failover procedure against the test cluster
3. Verify everything works, then tear down the test cluster
4. Document any issues encountered

Or use ACM's policy compliance feature to verify DR readiness without actually failing over - the `policy-replication-healthy` policy reports if the standby is properly configured.

## Common Issues

### "Cluster cannot find replication source"

The Skupper VAN may have lost its link. Check on passive:

```bash
oc get accesstoken -n suitecrm
oc get connector -n suitecrm
```

If the link is broken, regenerate the token (see BOOTSTRAP.md Step 8).

### "VolSync restore stuck"

Check the restore pod:

```bash
oc get pods -n suitecrm -l app.kubernetes.io/created-by=volsync
oc logs -n suitecrm <volsync-restore-pod>
```

Most often this is an S3 credential mismatch between active and passive clusters.

### "App pods crashing on startup"

Check for connection errors to the database. After a fresh promotion, sometimes the streaming_replica user no longer has the expected permissions:

```bash
oc logs -n suitecrm deployment/suitecrm
oc exec suitecrm-db-1 -n suitecrm -- psql -U postgres -d suitecrm -c "\du"
```

## Emergency Contact

DR failover is high-stakes. Don't run alone unless absolutely necessary.

Document your team's escalation paths here:

- **Primary on-call:** ___________
- **Secondary on-call:** ___________
- **Database SME:** ___________
- **Network/DNS:** ___________
