# Failover runbook

## Three levels of failure, three different responses

| Level | Example | Who handles it | RTO |
|---|---|---|---|
| **In-cluster** | Worker node or AZ dies | CNPG, automatically | seconds |
| **Cross-cluster** | Region outage | **This runbook** | 5–10 minutes |
| **Catastrophic** | Both regions lost | OADP restore | hours |

Do not run this runbook for an in-cluster failure. CNPG's synchronous local replica handles it faster than you can, with RPO 0.

Check which you have:

```bash
oc get cluster odoo-db -n odoo -o jsonpath='{.status.phase}'
```

| Result | Meaning |
|---|---|
| `Cluster in healthy state` | Normal |
| `Failing over` / `Switchover in progress` | In-cluster failover — wait |
| no response / timeout | Active cluster unreachable — continue below |

## Failover is two phases

### Phase 1 — traffic. Automatic.

Cloudflare health-checks the active route. After three consecutive failures it marks the pool unhealthy and shifts DNS to the passive cluster. Typically 1–3 minutes. **No human required.**

### Phase 2 — application. Currently manual.

Traffic now arrives at the passive cluster, where Odoo is at 0 replicas and the database is a read-only standby. Until Phase 2 runs, users get errors.

Three things must happen:

1. Promote the PostgreSQL standby
2. Scale Odoo up
3. Restore the filestore from object storage

Configure Cloudflare's webhook notifications to page on-call the moment it fails over, so Phase 2 starts immediately.

---

## Before a live demo

The Odoo image is rebuilt weekly from the Odoo branch tip and published to floating tags (`19.0`, `19`, `latest`). That is intentional for a reference pattern — but it means a pod restart can pull a newer build than the one you rehearsed against, including the restart that happens when the passive cluster scales up during failover.

For demo week:

- **Freeze reconciliation.** Turn off Argo CD auto-sync on the Odoo Applications so nothing changes underneath you mid-demo.
- **Stop opportunistic pulls.** Set `imagePullPolicy: IfNotPresent` on both Deployments, so a restarting pod reuses the image already on the node.
- **Pre-pull on both clusters.** Make sure the passive cluster already has the image locally; otherwise it fetches during the failover window and inflates your RTO on stage.

None of this is needed in day-to-day use of the pattern. It matters only when you are timing a failover in front of an audience.

## Before you promote

Promotion is one-way. A promoted standby cannot re-attach as a replica without a rebuild.

- [ ] Active cluster confirmed unreachable **from more than one network path**
- [ ] It is an outage, not a partition — check the cloud provider status page
- [ ] Replication lag before the loss was small
- [ ] VolSync was syncing successfully
- [ ] You can edit DNS
- [ ] Stakeholders notified

The split-brain risk is real: if the active region is merely partitioned and still serving writes somewhere, promoting the standby creates two primaries and divergent data.

---

## Method 1 — Git commit (recommended)

Auditable, reviewable, and it is what the pattern is designed around.

### Step 1 — promote the database

In `clusters/passive/postgres/cluster.yaml`:

```yaml
spec:
  replica:
    enabled: false      # was: true
```

### Step 2 — scale Odoo up

In `clusters/passive/odoo/odoo.yaml`:

```yaml
spec:
  replicas: 1           # was: 0
```

Commit and push. Argo CD applies both within about three minutes, or force it:

```bash
argocd app sync odoo-postgres-passive-<cluster>
argocd app sync odoo-app-passive-<cluster>
```

### Step 3 — restore the filestore

Not a YAML change — VolSync restores on annotation:

```bash
oc annotate replicationdestination odoo-data-restore -n odoo \
  volsync.backube/manual-trigger="$(date +%s)" --overwrite

# Watch
oc get replicationdestination odoo-data-restore -n odoo \
  -o jsonpath='{.status.lastSyncTime}{"\n"}'
```

Then bind the restored volume to `odoo-data` and restart Odoo so it picks up the filestore.

### Step 4 — verify

```bash
oc exec -n odoo odoo-db-1 -- psql -U postgres -c "SELECT pg_is_in_recovery();"   # expect: f
oc get pods -n odoo
curl -s -o /dev/null -w "%{http_code}\n" https://<your-host>/web/health           # expect: 200
```

Log in, open a recent record, and open an attachment — that last check is the one that exercises the filestore restore.

> **Expect a small attachment gap.** Files uploaded in the final sync interval before the outage may be missing while the database references them. See the filestore consistency section in ARCHITECTURE.md. If you have set `ir_attachment.location = db`, this does not apply.

---

## Method 2 — label swap (fast, blunter)

```bash
oc label managedcluster <old-active>  role=passive --overwrite
oc label managedcluster <old-passive> role=active  --overwrite
```

The Placements re-resolve and Argo CD redeploys both clusters into their new roles. Faster, but the manifest that lands on the newly-active cluster is the *primary* definition, which assumes the database is already promoted. Method 1 is more deterministic. Use this only when you understand that ordering.

---

## After the old region returns

**Recommended: keep running where you are.** Rebuild the recovered cluster as the new standby.

```bash
# On the recovered cluster, now labelled role=passive
oc delete cluster odoo-db -n odoo
oc delete pvc -l cnpg.io/cluster=odoo-db -n odoo
```

Argo CD recreates it with `replica.enabled: true`, and CNPG runs `pg_basebackup` from the new primary. Ten to thirty minutes depending on database size.

The Interconnect link must also be re-established in the new direction — the Connector belongs on whichever cluster now holds the primary.

Failing *back* to the original region means doing this whole procedure again in reverse. Only do it if there is a real reason.

---

## Sleeping through disasters: automating Phase 2

The name of the pattern is the aspiration. Phase 1 already achieves it. Phase 2 is manual by default because automatic promotion during a partition is how you get split-brain.

Three patterns make automation safe:

**Multi-source validation.** Require several independent observers to agree before promoting: Cloudflare health checks, an external synthetic monitor, the ACM `ManagedCluster` status on the hub, and the standby's own view of replication. Promote only when all agree for more than five minutes. Independent observers failing simultaneously is either a real outage or an event severe enough that failing over is still right.

**Fencing.** Before promoting, make it impossible for the old primary to accept writes — scale its CNPG cluster to zero, cut its egress with a NetworkPolicy, or detach its storage through the cloud API. If you can fence, split-brain becomes impossible rather than unlikely.

**Quorum.** An external lease holder (etcd, Consul, a hub controller) decides who is primary. Most robust, most infrastructure.

### A realistic progression

1. **Today** — Cloudflare automates traffic; a human runs Phase 2
2. **Next** — Cloudflare webhook triggers Event-Driven Ansible, which gathers evidence and pre-stages the failover; a human approves with one click
3. **Then** — after six months with no false positives, automate promotion behind multi-source validation
4. **Finally** — add fencing

### What "sleeping through it" looks like at step 4

```
03:42  Region A loses power
03:45  Cloudflare marks the pool unhealthy, DNS shifts to region B
03:45  Webhook fires into AAP; EDA rulebook starts
03:48  Four independent sources agree region A is gone; fencing runs
03:48  Commit: replica.enabled=false, replicas=1
03:51  PostgreSQL promoted, Odoo pods Ready
03:52  Filestore restored; Slack: "Failover complete."
08:00  You wake up to a recovered system and a thread to read.
```

| Approach | RTO | Risk | Effort |
|---|---|---|---|
| Fully manual | 30+ min | low | none |
| Cloudflare + manual Phase 2 *(today)* | 5–10 min | low | done |
| EDA pre-staged + human approval | 3–5 min | low | medium |
| Fully automatic + validation | 2–4 min | medium | high |
| Fully automatic + fencing | 2–4 min | low | high |

Most organisations stop at row 2 because the marginal RTO gain is not worth the complexity. The path is documented so the choice is deliberate.

---

## Troubleshooting

**Standby not replicating.** Check the link and the tunnelled service:

```bash
oc get site,listener,accesstoken -n odoo          # passive
oc get svc odoo-db-primary -n odoo
oc exec -n odoo odoo-db-1 -- pg_isready -h odoo-db-primary -p 5432
```

**VolSync restore stuck.** Almost always a credential mismatch — `RESTIC_PASSWORD` and the repository URL must be byte-identical on both clusters.

```bash
oc get pods -n odoo -l app.kubernetes.io/created-by=volsync
```

**Odoo starts but errors on attachments.** The filestore restore has not completed or is not bound to `odoo-data`. Confirm the restore, then restart the deployment.

**Odoo logs "PostgreSQL is a read-only standby" and waits.** Working as intended — the container refuses to start against an unpromoted replica. Complete step 1 (promote the database); Odoo continues automatically once `pg_is_in_recovery()` returns false. It gives up after `STANDBY_WAIT` seconds (default 600).

**Odoo tries to re-initialise the database.** It only does that when `ir_module_module` is absent. If you see it against a promoted standby, the database is not the one you think it is — stop and check `DB_NAME` and which cluster you are on.

## Escalation

- Primary on-call: ______________
- Database SME: ______________
- Network / DNS: ______________
- Cloud provider support: ______________
