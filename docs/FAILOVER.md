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

Phase 2 is automated by **`clusters/passive/failover/`** — an OpenShift
Pipelines (Tekton) Pipeline named `dr-failover` that runs on the surviving
cluster with in-cluster credentials only. Design and rationale:
[DESIGN-DECISIONS.md §4](DESIGN-DECISIONS.md).

### What it does

```
signal ──▶ verify ──▶ promote ──▶ scale ──▶ Cloudflare flips passive green
           │
           ├─ webhook? check cf-webhook-auth against the Secret; reject if wrong
           ├─ already primary?          → stop (nothing to do)
           └─ WAL still streaming from the primary over the VAN?
                                          → REFUSE (site is alive; edge-only outage)
```

`promote` and `scale` only run when verify's decision is `promote` **and** the
`auto_promote` parameter is `"true"`.

### Two triggers, one pipeline

**Webhook** (Cloudflare Pro+ zone required for generic webhooks):

1. Get the receiver URL:
   `oc get route dr-failover-webhook -n odoo -o jsonpath='https://{.spec.host}{"\n"}'`
2. Cloudflare dashboard → **Notifications → Destinations → Webhooks → Create**:
   that URL, and the secret from your vault (`vault_cloudflare_webhook_secret`).
   *Save and Test* — the test POST is rejected by the CEL filter (no
   `alert_type`), which is correct; check `oc logs -n odoo deploy/el-dr-failover`.
3. **Notifications → Add → Load Balancing Health Alert** → pool `odoo-active`,
   health `Unhealthy`, destination: the webhook.
4. Suspend the poller so both don't fire: `oc patch cronjob dr-poller -n odoo -p '{"spec":{"suspend":true}}'`
   (or set `suspend: true` in Git).

**Poller** (any plan; the default as committed): the `dr-poller` CronJob asks
the Cloudflare API every minute whether `odoo-active` is healthy and starts
the Pipeline after two consecutive *unhealthy* answers. Needs the
`cloudflare-api-token` Secret (`03-secrets`) and the `cloudflare-lb-ids`
ConfigMap (`06-cloudflare`).

### The human gate

As committed, `auto_promote` is `"false"` everywhere (Phase 2a): a signal
produces a `PipelineRun` that verifies and stops with

```
GATED. Conditions for promotion are met but auto_promote=false.
```

A human then promotes with one command:

```bash
tkn pipeline start dr-failover -n odoo -p source=manual -p auto_promote=true --serviceaccount dr-failover --showlog
```

For fully automatic failover (Phase 2b) set `auto_promote` to `"true"` in the
TriggerTemplate (webhook) or the poller's `AUTO_PROMOTE` env, and commit.

### Running it by hand, and watching

```bash
# dry verification only (no changes)
tkn pipeline start dr-failover -n odoo -p source=manual --serviceaccount dr-failover --showlog

# history — every failover is a PipelineRun with logs
tkn pipelinerun list -n odoo
tkn pipelinerun logs -n odoo <name>
```

### What is NOT automated yet

The **return** of the original region — bringing the old active back as a
replica of the promoted site — is a separate reconcile pipeline, still to be
designed. Until then, follow "After the old region returns" above.

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
