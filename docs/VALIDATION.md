# Validation — proving replication works

A copy-paste runbook that proves the pattern is actually protecting data:
the database and the Odoo filestore are replicating across the VAN, and the
cross-cluster Service Interconnect link is up. Use it as a pre-demo smoke test,
or as the "show me it's real" segment of a live demo.

Everything here is **read-only** except one clearly-marked step that writes a
throwaway record to prove cross-region replication. Nothing here performs a
failover — for that, see [FAILOVER.md](FAILOVER.md).

## Setup

Two kubeconfigs, created once with `oc login` (see [BOOTSTRAP.md](BOOTSTRAP.md)):

```bash
export HUB=~/.kube/hub.config       # AWS / passive cluster (also the ACM hub)
export ACTIVE=~/.kube/active.config  # on-prem / active cluster
```

> **After a shutdown/restart** (e.g. a demo cluster that hibernates), give both
> clusters a few minutes before validating. The CNPG replica needs to reconnect
> and catch up, and the Skupper VAN link needs to re-establish. A large
> replication-lag number right after boot is just catch-up; it settles.

---

## 1. The database is replicating (the headline proof)

### 1a. Both clusters are healthy, in the right roles

```bash
# Active: 2 instances (primary + synchronous replica), healthy
KUBECONFIG=$ACTIVE oc get cluster.postgresql.cnpg.io odoo-db -n odoo
```
Expect `INSTANCES 2`, `READY 2`, `Cluster in healthy state`, primary `odoo-db-1`.

```bash
# Passive: a replica cluster, healthy, streaming across the VAN
KUBECONFIG=$HUB oc get cluster.postgresql.cnpg.io odoo-db -n odoo
```
Expect a healthy replica cluster.

### 1b. Data actually crosses regions — write on active, read on passive

This is the most convincing single proof: a record typed into one cloud appears
in the other seconds later. The record is disposable.

```bash
# WRITE a demo record on the ACTIVE primary
KUBECONFIG=$ACTIVE oc exec -n odoo odoo-db-1 -- psql -U postgres -d odoo -c \
  "INSERT INTO res_partner (name, create_date, write_date, active)
   VALUES ('DR-PROOF — '||to_char(now(),'HH24:MI:SS'), now(), now(), true);"
```

```bash
# READ it back on the PASSIVE replica ~3s later — same row, different cloud
sleep 3
KUBECONFIG=$HUB oc exec -n odoo odoo-db-1 -- psql -U postgres -d odoo -c \
  "SELECT name FROM res_partner WHERE name LIKE 'DR-PROOF%'
   ORDER BY create_date DESC LIMIT 1;"
```
The row you just wrote on the active cluster appears on the passive one. That is
live cross-region replication over the Service Interconnect VAN.

### 1c. Replication lag — your live RPO number

```bash
KUBECONFIG=$HUB oc exec -n odoo odoo-db-1 -- psql -U postgres -d odoo -tAc \
  "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```
Typically sub-second to low seconds. This is the database recovery point for a
regional loss — name the number rather than rounding it.

---

## 2. The filestore is replicating (VolSync rsync-tls over the VAN)

### 2a. Sync is running, and steady-state is fast

```bash
KUBECONFIG=$ACTIVE oc get replicationsource -n odoo odoo-data -o jsonpath=\
'{"last sync:  "}{.status.lastSyncTime}{"\nduration:   "}{.status.lastSyncDuration}{"\nnext sync:  "}{.status.nextSyncTime}{"\n"}'
```
Expect a recent `lastSyncTime`, a `lastSyncDuration` of ~seconds (the first sync
after a cold start is a full copy and takes minutes; every incremental sync
after is seconds), and a scheduled `nextSyncTime`.

### 2b. The rsync-tls key exists on both clusters

The pre-shared key proves the PVC-to-PVC path is wired end to end. VolSync
generates it on the destination; it is copied once to the source.

```bash
KUBECONFIG=$ACTIVE oc get secret volsync-rsync-tls-odoo-data -n odoo
KUBECONFIG=$HUB    oc get secret volsync-rsync-tls-odoo-data -n odoo
```
Both should exist.

> **Note the naming quirk:** the *secret* is `volsync-rsync-tls-odoo-data` (no
> `-dst-`); the *service* VolSync creates on the destination is
> `volsync-rsync-tls-dst-odoo-data` (with `-dst-`). They differ by design.

---

## 3. The cross-cloud VAN is up (Service Interconnect / Skupper)

```bash
# The link between the two Skupper sites is Ready
KUBECONFIG=$HUB oc get links.skupper.io -n odoo
```
Expect `STATUS Ready`, remote site `odoo-active`, message `OK`.

```bash
# Both routing keys matched across the VAN (DB path + filestore path)
KUBECONFIG=$ACTIVE oc get connector,listener -n odoo
```
Expect `STATUS Ready` and `HAS MATCHING ... true` on each. This confirms the
database and filestore both have a working tunnel between clusters.

---

## 4. One-shot health summary

Runs everything above (except the write test) and dumps it to a file — handy for
a pre-demo check or for pasting into an issue.

```bash
{
  echo "=== ACTIVE DB (primary + sync replica) ==="
  KUBECONFIG=$ACTIVE oc get cluster.postgresql.cnpg.io odoo-db -n odoo
  echo; echo "=== PASSIVE DB (replica, streaming) ==="
  KUBECONFIG=$HUB oc get cluster.postgresql.cnpg.io odoo-db -n odoo
  echo; echo "=== REPLICATION LAG (live RPO) ==="
  KUBECONFIG=$HUB oc exec -n odoo odoo-db-1 -- psql -U postgres -d odoo -tAc \
    "SELECT now() - pg_last_xact_replay_timestamp();"
  echo; echo "=== VOLSYNC filestore (source) ==="
  KUBECONFIG=$ACTIVE oc get replicationsource -n odoo odoo-data -o jsonpath=\
'{"last sync: "}{.status.lastSyncTime}{"  duration: "}{.status.lastSyncDuration}{"\n"}'
  echo "=== rsync-tls key present on both clusters ==="
  KUBECONFIG=$ACTIVE oc get secret volsync-rsync-tls-odoo-data -n odoo --no-headers
  KUBECONFIG=$HUB    oc get secret volsync-rsync-tls-odoo-data -n odoo --no-headers
  echo; echo "=== VAN link + routing keys ==="
  KUBECONFIG=$HUB oc get links.skupper.io -n odoo
  KUBECONFIG=$ACTIVE oc get connector,listener -n odoo
} 2>&1 | tee /tmp/dr-validation.txt
```

---

## What "green" looks like

| Check | Healthy result |
| --- | --- |
| Active DB | 2 instances, ready, healthy, primary `odoo-db-1` |
| Passive DB | replica cluster, healthy, streaming |
| Write-on-active / read-on-passive | the `DR-PROOF` row appears on passive |
| Replication lag | sub-second to low seconds |
| VolSync source | recent `lastSyncTime`, `lastSyncDuration` ~seconds |
| rsync-tls key | present on **both** clusters |
| VAN link | `Ready` / `OK` |
| Connectors / listeners | `Ready`, `HAS MATCHING = true` |

If the passive DB pool shows unhealthy in the Cloudflare load balancer, that is
**expected** in the resting state — the passive Odoo app is scaled to zero
(pilot-light posture), so there is nothing for the health check to hit. The
*database* is still running and replicating. See
[DEMO-TOPOLOGY.md](DEMO-TOPOLOGY.md) and [FAILOVER.md](FAILOVER.md).

## Cleanup (optional)

The write test leaves throwaway `DR-PROOF …` rows in `res_partner`. To remove
them:

```bash
KUBECONFIG=$ACTIVE oc exec -n odoo odoo-db-1 -- psql -U postgres -d odoo -c \
  "DELETE FROM res_partner WHERE name LIKE 'DR-PROOF%';"
```
They replicate away on the passive side within seconds.
