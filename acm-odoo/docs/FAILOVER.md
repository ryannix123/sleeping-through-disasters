# DR Failover Runbook

How to fail over from the active cluster to the passive cluster.

## Three Levels of Failure - Three Different Responses

Before reading this runbook, understand which type of failure you're dealing with:

| Failure type | Example | Who handles it | RTO |
|--------------|---------|----------------|-----|
| **In-cluster** (pod/node/AZ) | A worker node dies | CNPG operator, automatic | Seconds |
| **Cross-cluster** (region/cluster) | AWS us-east-1 outage | This runbook | 5-10 min |
| **Catastrophic** (both clusters) | Multi-region failure | OADP restore from S3 | Hours |

This runbook covers the **cross-cluster** scenario. Don't run it for in-cluster failures - CNPG's automatic in-cluster failover is faster and doesn't require any human action.

### How to Tell Which Failure You Have

Run on the active cluster:

```bash
oc get cluster suitecrm-db -n suitecrm -o jsonpath='{.status.phase}'
```

| Status | Meaning | Action |
|--------|---------|--------|
| `Cluster in healthy state` | Normal operation | None |
| `Failing over` or `Switchover in progress` | In-cluster failover in progress | Wait, CNPG handles it |
| (timeout / no response from `oc`) | Active cluster unreachable | Continue with this runbook |

## When to Use This

Use this runbook when:
- The active cluster is **confirmed unavailable** for an extended period
- A planned maintenance window requires shifting traffic to the passive cluster
- A regional outage affects the active cluster's underlying infrastructure

**Do NOT** run a failover for transient issues. PostgreSQL standby promotion is a one-way operation - once promoted, the standby cannot be re-attached as a replica without rebuilding from scratch.

## How Failover Actually Happens: Two-Phase Process

Failover in this architecture happens in two phases, and it's important to understand the distinction:

### Phase 1: Traffic Failover (Automatic, ~1-3 minutes)

**Cloudflare Load Balancer handles this automatically.** When configured with priority-based failover:

- Health checks ping `https://<active-route>/health` every 60 seconds
- After 3 consecutive failures (~3 minutes total), Cloudflare marks the active origin unhealthy
- DNS responses immediately start returning the passive cluster's IPs
- Users hitting the URL now reach the passive cluster

**No human action required.** This part literally lets you sleep through a disaster.

### Phase 2: Application Failover (Currently Manual)

But here's the catch: when traffic arrives at the passive cluster after Phase 1, by default it hits:

- SuiteCRM with `replicas: 0` → 503 errors
- A read-only PostgreSQL standby → write failures even if app pods existed

So **Phase 1 alone is not enough**. The passive cluster's resources need to be activated:
1. Promote PostgreSQL standby → primary (`replica.enabled: false`)
2. Scale SuiteCRM from 0 → 2 replicas
3. Trigger VolSync restore for file uploads

This phase is currently manual by default - hence the runbook below. See **Sleeping Through Disasters: Automating Phase 2** further down for how to automate this safely.

## The Cloudflare-Triggers-Alert Pattern

If you've configured Cloudflare auto-failover and traffic shifts to passive while Phase 2 hasn't run yet, users see 503 errors. To avoid this gap:

**Configure monitoring to alert on the Cloudflare failover event itself**, not just on application errors. This gives the on-call engineer immediate context:

> "Cloudflare just failed over to passive cluster. Run failover runbook ASAP."

Cloudflare's webhook notifications (or Logpush events) can fire to PagerDuty/Slack the moment the load balancer marks the primary unhealthy. The on-call human then has 3-5 minutes to execute Phase 2 before users notice prolonged 503s.

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

## Sleeping Through Disasters: Automating Phase 2

The "Sleeping through disasters" validated pattern aspires to fully automated failover - including database promotion and app scale-up - so on-call engineers don't get woken up.

This is achievable, but it requires solving the **split-brain problem**: if the active cluster is only network-partitioned (not actually down), automated promotion of the standby creates two primaries. When the partition heals, you have data divergence that's painful (and sometimes impossible) to reconcile.

### Why Manual is the Default

A human checking the active cluster from a different network path is the cheapest, most reliable way to confirm a real outage versus a partition. That's why most enterprise DR runbooks (and ours, by default) require a human to approve promotion.

### Safe Automation Patterns

If you want to automate Phase 2, these patterns mitigate split-brain risk:

#### Pattern 1: Multi-Source Health Validation (Recommended)

Don't trust a single signal. Require **multiple independent observers** to agree the active cluster is down before promoting:

| Signal | Source |
|--------|--------|
| Cloudflare health check failed | Cloudflare's edge POPs (global) |
| External synthetic check failed | Pingdom / Datadog / external monitoring |
| Kubernetes API unreachable | Hub cluster's view of managed cluster |
| ACM ManagedCluster status: Unknown | ACM heartbeat |
| PostgreSQL streaming replication: lag growing or broken | Standby's view of primary |

Promote only when **all five sources** agree the active is unreachable for >5 minutes. This makes split-brain extremely unlikely - either there's a real outage, or there's a catastrophic network event that affects multiple independent observers simultaneously (in which case the right answer is probably still to fail over).

#### Pattern 2: Fence the Old Primary

Before promoting the standby, **forcibly prevent the old primary from accepting writes**. Options:

- Update the active cluster's network policy to deny all egress (if hub can still reach it)
- Use cloud provider APIs to detach the primary's storage
- Update DNS to remove the old primary entirely (not just deprioritize)
- Reduce CNPG instance count to 0 on the old primary

If you can fence the old primary, split-brain becomes impossible - even if the partition heals, the old primary is no longer functional.

#### Pattern 3: Quorum-Based Decisions

Run an external quorum service (etcd, Consul, or a hub-based controller) that holds the "lease" on which cluster is active. Only the cluster holding the lease accepts writes. Failover happens by transferring the lease, which can only happen when quorum agrees.

This is the most robust pattern but requires significant additional infrastructure.

### Implementation: EDA-Driven Phase 2 Automation

Event-Driven Ansible is well-suited for this. A rulebook listening for the multi-source health validation could:

```yaml
# Conceptual EDA rulebook (pseudocode)
- name: Validate active cluster outage
  condition: >
    event.source == 'cloudflare-webhook' and
    event.payload.health_status == 'critical' and
    event.payload.duration_minutes >= 5
  action:
    run_playbook:
      name: validate-and-failover.yml
      extra_vars:
        cloudflare_event_id: "{{ event.payload.id }}"
```

The `validate-and-failover.yml` playbook would:

1. Verify Cloudflare alert is genuine (not a webhook spoof)
2. Run synthetic checks from 2-3 additional regions
3. Query ACM hub for ManagedCluster status
4. Check if SSH/API access to the active cluster is possible from any path
5. Only proceed if all checks confirm outage
6. Fence the old primary (if reachable: scale CNPG to 0; if not: rely on partition)
7. Use the AAP-ACM integration to commit the YAML changes:
   - `replica.enabled: false` on passive cluster's PostgreSQL
   - `replicas: 2` on passive cluster's SuiteCRM
8. Annotate VolSync ReplicationDestination to trigger restore
9. Wait for promotion to complete, verify health
10. Send "Failover complete" notification (so the on-call still wakes up *eventually*, just not immediately)

### A Realistic Middle Ground

Full automation is a journey, not a switch. A reasonable progression:

1. **Today (default)**: Cloudflare auto-fails traffic, human runs Phase 2 (current state)
2. **Phase 1**: Cloudflare alert triggers EDA, which gathers diagnostic data and pre-stages failover (warms VolSync cache, runs read-only checks on passive). Human still approves the actual promotion via a one-click ServiceNow/Slack approval.
3. **Phase 2**: After Phase 1 has been running reliably for 6+ months with no false positives, enable fully automated promotion - but still send notifications.
4. **Phase 3**: Add fencing of the old primary for true split-brain protection.

### What "Sleeping" Actually Looks Like With Full Automation

```
3:42 AM - Active cluster region experiences power outage
3:42 AM - Cloudflare health checks start failing
3:45 AM - Cloudflare marks origin unhealthy, DNS shifts to passive
3:45 AM - Cloudflare webhook → AAP → EDA rulebook fires
3:46 AM - Multi-source validation runs (synthetic, ACM, replication)
3:48 AM - All sources confirm outage; fencing playbook runs
3:48 AM - AAP commits YAML: standby promoted, app scaled up
3:51 AM - PostgreSQL promotion complete, app pods Ready
3:52 AM - VolSync restore complete, file uploads available
3:52 AM - Slack notification: "Failover complete. Investigate root cause when convenient."
8:00 AM - On-call wakes up to a fully recovered system and a Slack thread to read.
```

That's the dream. Getting there takes investment, but each step (Phases 1 → 3 above) provides incremental value.

### Trade-offs Summary

| Approach | RTO | Risk | Effort |
|----------|-----|------|--------|
| Full manual (no Cloudflare) | 30+ min | Low | None |
| Cloudflare auto + manual Phase 2 (current) | 5-10 min | Low | Already done |
| Cloudflare + EDA-staged + human approval | 3-5 min | Low | Medium |
| Fully automated with multi-source validation | 2-4 min | Medium | High |
| Fully automated + fencing | 2-4 min | Low | High |

The current setup is at row 2. Most organizations stop there because the marginal RTO improvement isn't worth the complexity. But if your business case justifies it (high RTO penalty, large operations team, frequent regional outages), the path forward is clear.

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
