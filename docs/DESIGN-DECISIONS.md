# Design Decisions & Roadmap

Open architecture questions for "Sleeping Through Disasters," captured for the
working group. These are **not yet implemented** — the shipped pattern today is
the manual-promotion, public-route version described in the other docs. This
file records the options considered, the tradeoffs, and the leaning, so the
decisions can be made deliberately rather than rediscovered.

Two topics:

1. Automating the failover so the pattern earns its name (EDA / AAP)
2. Securing the origin so nobody bypasses the Cloudflare load balancer

---

## 1. Automated failover — making "sleep through it" literally true

### The gap today

The shipped pattern fails over in three acts, and only the first is automatic:

| Job | Owner | Automatic today? |
| --- | --- | --- |
| Route traffic to a healthy pool | Cloudflare LB | Yes |
| Scale up the Odoo pod on passive | *nobody* | No — manual |
| Promote the database (replica → primary) | *nobody* | No — manual |

Cloudflare's health check is a **probe, not a trigger**: when it finds the
passive origin unhealthy (Odoo scaled to zero), it just marks the pool down. It
has no ability to reach into the cluster and *start* anything. So a real
failover today needs a human to promote the DB and scale up Odoo. That is
honest DR, but it is not "sleeping through" a disaster.

### Why promotion is gated (this is the crux, not an oversight)

The database promotion is deliberately manual because **automatic promotion on
an ambiguous signal risks split-brain.** From the passive site's view, "the
active region is dead" and "I temporarily can't reach the active region" look
identical — both are "I stopped hearing from active." If promotion fired on
that ambiguous signal:

- a transient WAN blip (common on a homelab consumer uplink) makes passive
  promote itself → two primaries, both accepting writes;
- the link recovers → divergent databases → data corruption that is brutal to
  reconcile, and unacceptable for financial ERP records.

This is the CAP theorem showing up in practice. With **two sites** and strong
consistency, safe automatic failover is not achievable without a third,
independent vote — a partition splits two sites 1-1 and neither can claim
majority. So the manual gate is the *correct* posture for a two-site,
strongly-consistent design, not a missing feature.

### The chosen direction: Event-Driven Ansible / AAP

Precedent: ~3 years ago, colleagues drove a cutover with **ACM + AAP**
(ACM Governance `PolicyAutomation` firing an AAP job template on
non-compliance). EDA is the modern generalization of that same "event →
automation" idea, with rulebooks and a broader set of event sources.

Product/SKU value: this adds **AAP** as a fourth Red Hat product in the stack,
alongside OpenShift, ACM (VolSync included), and Red Hat Service Interconnect
(Skupper). Each does real, non-removable work — a clean "better together" sales
motion.

**Trigger mechanism — Cloudflare webhook → AAP:**
Cloudflare's account-level Notifications Service supports **webhooks** on pool
health-status changes. Two useful properties (verified in Cloudflare docs):

- **Multi-region health quorum.** Cloudflare probes each region from three
  separate data centers and decides health by majority — so "active is
  unhealthy" is already a distributed majority verdict, not one vantage point.
  This meaningfully (not completely) reduces the "one flaky link declared active
  dead" risk.
- **Stateful recovery notifications.** Cloudflare now sends a *distinct*
  notification when a pool returns to healthy, not only when it goes unhealthy.
  This is exactly the trigger needed for the "original region came back" case.

**Proposed flow:**

- Active pool → **Critical** fires a webhook → AAP job template
  **`promote-passive`**: promote the CNPG replica (`replica.enabled: false`),
  scale Odoo `0 → 1` on passive. The DB is already a hot, current replica, so
  this is seconds, not a restore.
- Active pool → **Healthy again** (the recovery notification) fires a webhook →
  AAP job template **`reconcile-returning-region`**: the returned site must
  rejoin as a **standby of the new primary**, never self-promote. Any writes it
  took while isolated need a conflict decision. This is the fencing logic that
  prevents split-brain on return.

**Honest caveat to keep in the design:** Cloudflare's signal is *reachability
from the internet*, not ground truth that the homelab is dead. A homelab that
loses only its uplink looks "down" while still alive and holding the old
primary. The `reconcile-returning-region` job is what catches this — forcing
safe re-standby on return. So AAP does not *eliminate* split-brain risk; it
*manages* it: trust a multi-region quorum for the promote, force safe re-standby
on return. That is defensible and far better than "promote on first failed
check."

### Recommended phasing

- **Phase 2a (recommended first):** EDA/AAP auto-*detects* and auto-*prepares*
  (scale up passive Odoo, pre-checks, drain), but the DB promotion waits on a
  one-click human confirm (e.g. a Slack button). RTO drops to seconds-plus-a-
  click; split-brain guard intact.
- **Phase 2b:** full auto-promote gated on a **quorum/witness** (a third
  independent signal), plus the `reconcile-returning-region` fencing job. Only
  now is "sleep through it" literally earned.

### Alternative considered: quorum database instead of orchestration

Rather than *automating around* the promotion (EDA), one could *design it out*
at the data layer with a distributed, consensus-based database:

- **YugabyteDB** — Postgres wire-compatible, Raft consensus, survives region
  loss automatically; a minority partition can't reach quorum so it simply stops
  taking writes (no split-brain). Apache 2.0.
- **CockroachDB** — same family (distributed SQL, Raft); Postgres wire-
  compatible; check BSL licensing.
- **Eventually-consistent multi-primary** (BDR / pgEdge / pgactive) — both sites
  always writable, but relocates the hard problem to **write-conflict
  resolution**, which is risky for financial ERP data (last-write-wins can
  silently clobber a transaction). Treat with caution.

Tradeoffs: these solve split-brain by requiring **quorum → 3 sites, not 2**
(same CAP constraint, just made explicit as a third vote), and they replace
CNPG, weakening the "standard PostgreSQL + CNCF" story. **Leaning: keep CNPG +
EDA/AAP.** It preserves real Postgres, matches the AAP sales motion, and the
quorum-database option is a bigger architectural bet best discussed *with* the
working group rather than pre-decided.

### Why CNPG was the right database choice

- vs. a hand-rolled StatefulSet: CNPG is an operator — automated in-cluster
  failover, streaming replication, backup orchestration, primary-aware routing,
  rolling upgrades. The one-field replica→primary promotion this pattern relies
  on is a CNPG primitive.
- vs. a managed cloud DB (RDS/Cloud SQL): those would break the core thesis —
  cross-cloud DR to a homelab is impossible if the DB is RDS. CNPG runs inside
  OpenShift on any CSI storage, which is what makes the substrate-agnostic claim
  true (LVM on the homelab, Ceph on AWS, the same manifest).
- CNCF-governed, Apache 2.0, available as a certified operator on OpenShift —
  community governance with Red Hat certification, no proprietary DB vendor.

---

## 2. Securing the origin — only Cloudflare should reach Odoo

### Objective

Ensure nobody can bypass the Cloudflare LB by hitting the cluster route
directly (`odoo-odoo.apps.<cluster>...`) instead of the public
`erp.openshifthelp.com`. "You can knock, but no one answers without the secret
knock."

### Direction matters: this is an INGRESS problem

The bypass is an **inbound** request arriving at the router and being served.
The enforcement must therefore live on the **ingress** path. `EgressFirewall`
governs **outbound** pod-initiated traffic and cannot see or block an inbound
request — a direct hit on the route never traverses the egress path, so no
egress rule evaluates it. EgressFirewall is the right tool for a *different*
(complementary) job — see 2b.

### 2a. The "secret knock": ingress mTLS (RECOMMENDED)

Require a **client certificate** at the OpenShift IngressController
(`clientTLS`), signed by a CA we control. Cloudflare presents that cert via
**Authenticated Origin Pulls**. The client cert *is* the secret knock.

- **Agnostic + Red Hat-supported:** enforcement is an OpenShift-native
  IngressController capability, included with the subscription — not a Cloudflare
  IP list, not a third-party operator. If Cloudflare were swapped for another
  edge that can present a client cert, the OpenShift side is unchanged.
- **Stable:** cert-based, rotates on our schedule — no daily-changing IP
  allow-list to chase.
- **Declarative:** IngressController config + CA secret live in GitOps.
- **Bypasser experience:** the route still exists, but the TLS **handshake
  fails** (no client cert) — e.g. `ERR_BAD_SSL_CLIENT_AUTH_CERT`. The request is
  rejected at TLS negotiation and **never reaches Odoo**, so junk traffic also
  never consumes app resources (a nice DoS-resistance side effect).
- **Caveat:** IngressController `clientTLS` applies to the whole controller by
  default. Fine on SNO where Odoo is the main event; on a busy multi-tenant
  cluster, use a dedicated IngressController **shard** for the Odoo route so
  other routes aren't affected.

### Alternative considered: Cloudflare Tunnel (`cloudflared`)

Run `cloudflared` as a pod that dials **outbound** to Cloudflare; expose Odoo
**only** through the tunnel, with **no public route at all**.

- **Strongest outcome:** you can't bypass a front door that doesn't exist. A
  bypasser hitting the old `.apps.` name gets NXDOMAIN / nothing.
- **Bonus:** solves the homelab NAT/inbound-reachability problem (the tunnel is
  outbound-initiated) — the same issue that briefly bit the Cloudflare health
  checks during bring-up.
- **Cost:** deepens the **Cloudflare** dependency (a Cloudflare component inside
  OpenShift), which sits awkwardly against the "portable fulcrum, no lock-in"
  thesis. **No official Red Hat- or Cloudflare-backed operator exists** — the
  community operators (adyanth, beezlabs, etc.) are unsupported and some are
  alpha. If pursued, prefer a **hardened plain `cloudflared` Deployment** in
  GitOps (runAsNonRoot, readOnlyRootFilesystem, drop ALL caps, token from a
  Secret, replicas ≥ 2 with anti-affinity) over an alpha operator.

**Leaning: ingress mTLS (2a)** for the agnostic + supported fit; document the
tunnel as the alternative with its lock-in tradeoff so the choice is visible.

### 2b. Complementary: EgressFirewall as outbound containment

Not the bypass control — the **back-door guard**. Another capability included
with the OpenShift subscription (OVN-Kubernetes), so it's value-add at no extra
SKU cost. It locks what the Odoo/DB pods may reach when *they* initiate
outbound connections:

- **Contain a compromised pod:** if Odoo is popped via an app vuln, the pod
  can't phone home, exfiltrate the database, or pull a second-stage payload — it
  can only reach permitted destinations (the Skupper VAN endpoint, Cloudflare).
- **Prevent data exfiltration:** the ERP holds financial data; restrict the DB/
  Odoo pods so that data can't be streamed to an arbitrary host.
- **Segmentation/compliance:** prove the Odoo namespace only talks to its
  permitted peers.

Supports **`dnsName`** rules, so it tracks names rather than brittle IPs.

### Defense-in-depth summary

| Layer | Tool | Direction | In the box with | Job |
| --- | --- | --- | --- | --- |
| Front door — "secret knock" | IngressController mTLS + Cloudflare Authenticated Origin Pulls | Inbound | OpenShift subscription | Only Cloudflare gets in |
| Back door — containment | EgressFirewall (`dnsName`) | Outbound | OpenShift subscription (OVN-K) | Nothing sneaks out |

Both doors guarded, each by the right tool, both included with the platform
already being purchased.

---

## 3. Operational findings from the fresh from-the-top redeploy

Things the second full deployment surfaced that the first passed by luck.
Each is either fixed in the repo or recorded as a deliberate choice.

### 3a. Secrets must exist before the database bootstraps (FIXED)

CloudNativePG creates the `replicator` role from `managed.roles[].passwordSecret`
at bootstrap. If `odoo-replicator` is not present yet, CNPG records
`managedRolesStatus.cannotReconcile: "secrets odoo-replicator not found"`, skips
the role, and does not reliably retry on its own. The passive replica then
fails forever with `password authentication failed for user "replicator"`.

Fix: playbook `03-secrets` (hub bootstrap + `odoo` namespace + secrets via ACM
Policy) now runs **before** `04-deploy-gitops`. Argo sync-waves cannot express
this because the secrets are not Argo's — they come from the Policy — so the
ordering lives in the runbook, and the Policy creates the namespace itself so
it can run first.

### 3b. Kubeconfigs must be single-context files (RULE)

A kubeconfig that is a copy of `~/.kube/config` (dozens of contexts, movable
current-context) sent commands to the wrong cluster three separate times: a
failover `oc scale` that landed on the dead site, a preflight that inspected
the homelab and declared GitOps missing, and an AccessToken applied to the
*active* cluster, which redeemed its own grant and produced a self-linking
router loop (`Existing connection takes precedence, closing …`). Every one of
those looked like a Skupper, DNS, or CNPG problem until the target was checked.

Rule (BOOTSTRAP): `oc config view --minify --flatten` after every `oc login`;
prefix every command with `KUBECONFIG=`; **verify the target before
diagnosing the symptom.** Playbooks now pass the inventory kubeconfig to every
task and never depend on ambient context.

### 3c. The Skupper handshake is done with plain kubernetes.core (FIXED)

The `skupper.v2` collection hung indefinitely on a `Pending` AccessGrant and is
suspected of changing a kubeconfig's current-context. `05` now performs the
handshake exactly as a successful manual one does — AccessGrant on active,
wait for Ready + URL, AccessToken (url/code/ca) on passive, wait until both
Sites report **2 sites in network** — with bounded retries and errors that
name the object to check. It is idempotent and safe to re-run after a reboot.

### 3d. Grant server on a NAT'd site is fragile (OPEN — topology recommendation)

On the homelab active site, `svc/skupper-grant-server` is type `LoadBalancer`
and sits at `EXTERNAL-IP <pending>` forever (no cloud LB provider on SNO).
OpenShift falls back to a Route, which works, but the grant server was
observed wedged (grants stuck `Pending` with no URL) after reboots and
controller restarts, and once returned `404 No such access granted` for a
grant it had just issued. A controller restart clears it each time.

Recommendation: **flip the link direction.** Let the cloud site (real
LoadBalancer, real ingress) hold `linkAccess: default` and issue the grant;
let the NAT'd homelab redeem and dial *out*. Skupper links are bidirectional
once formed, so replication direction is unaffected — only which side hosts
the grant endpoint changes. This is also the more honest posture for the
"active behind NAT" story: the site with no inbound reachability should never
be the one required to accept connections.

### 3e. Argo enforces `replicas: 0` on the passive Odoo (OPEN — failover fix)

During the failover test, `oc scale deployment odoo --replicas=1` on the
passive was reverted within a second: Git says `0`, and Argo self-heals it.
The scale-up is therefore not a manual `oc scale` — it must be done in a way
Argo respects. Two options: an `ignoreDifferences` on `/spec/replicas` for the
passive Odoo Application (the HPA-coexistence pattern; simplest for the demo),
or having the failover automation commit `0 → 1` to Git (purest GitOps). This
is a requirement for the EDA/AAP failover job: **promote, then scale, in a
GitOps-respecting way.**

### 3f. Why not Knative (scale-to-zero) for the passive app (DECIDED: no)

Considered as a "creative" way to keep the passive Odoo at zero and wake it on
traffic. Rejected: Knative scales *compute* in response to *traffic*, but the
gate in this failover is the *database promotion*. Traffic arriving at passive
would boot Odoo against a read-only replica — reads work, writes fail, health
checks pass — a half-alive app worse than a clean 503. Odoo is also not a
Knative-shaped workload (RWO filestore PVC, long sessions, 30–90 s cold start
that no health probe survives). The current "passive Odoo at 0 replicas" is
doing a quiet, important job: it *guarantees* the passive pool fails health
checks until promotion has happened. Keep it; let EDA own the ordering.

### 3g. Cloudflare already gates the cutover correctly (CONFIRMED)

`default_pools: [active, passive]` with `steering_policy: off` sends traffic
only to the first healthy pool; passive receives nothing while active is up.
The monitor (`60s` interval, `2` retries) marks active unhealthy after ~2
minutes of no response — the "cut over after 2 minutes" behaviour, already
configured. Keep `adaptive_routing.failover_across_pools: false`: enabling it
would retry individual failed requests against passive *before* promotion. The
passive pool being **Critical at rest is the correct state** — its health
check is the promotion gate.

---

## 4. Failover executor: OpenShift Pipelines, not AAP (DECIDED)

**The concern.** Requiring Ansible Automation Platform for the failover step
adds a substantial subscription a customer may not have. The pattern's own
rule — *better together, not required* — has to apply to its own automation.

**What the executor actually has to do** is small: receive a signal that the
active site is down, check that the signal is trustworthy, patch one CNPG
object, scale one Deployment, wait for a health check. That is a webhook and
three `oc` commands. It does not need an automation platform.

### The options, ranked

| | Trigger | Executor | Extra cost | Notes |
| --- | --- | --- | --- | --- |
| **Best** | Cloudflare webhook → Tekton `EventListener` | **OpenShift Pipelines** | none | Declarative, in Git, every failover is a `PipelineRun` with logs. **Needs a Cloudflare Pro+ zone** for generic webhooks. |
| **Better** | `CronJob` polling the pool-health API | OpenShift Pipelines (same Pipeline) | none | Works on **any** Cloudflare plan; no inbound route needed. ~1 min slower. |
| Good | Knative Service (function) | OpenShift Serverless | none | Legitimate — a stateless, seconds-long HTTP function is exactly what Knative is for. Loses Pipelines' run history; logic lives in code. |
| Optional | Cloudflare webhook → EDA rulebook | **AAP** | AAP subscription | Best if the customer already runs AAP and wants failover in their automation estate. Same signals, same safety checks. |
| Avoid | Cloudflare Worker calling the cluster API | — | — | Puts a cluster credential and the failover logic *outside* OpenShift — the opposite of the thesis. |

Both Pipelines triggers land on the **same** `dr-failover` Pipeline
(`clusters/passive/failover/`). The trigger is a plan-tier choice; the
safety logic is identical.

### Safety: two independent signals must agree

Cloudflare's health verdict is already a multi-PoP majority vote. The
Pipeline adds a second, independent witness that no external system can
provide: **the passive replica itself knows whether it can still hear the
primary.** `pg_stat_wal_receiver` reports how many seconds ago the last WAL
message arrived over the VAN.

- Edge says *unhealthy* **and** WAL silent for > 60 s → the active site is
  gone from two directions → **promote**.
- Edge says *unhealthy* **but** WAL still streaming → the active site is
  alive and merely unreachable from the internet (ingress/DNS/edge outage) →
  **refuse**. Promoting here is the split-brain case.

Webhook callers are authenticated against the `cf-webhook-auth` shared secret
(held in a Secret, never in Git), and the webhook Route is IP-allowlisted to
Cloudflare's published ranges. A forged POST is rejected before anything is
touched.

### The human gate is one parameter

`auto_promote` (default `"false"`). With it off, the Pipeline verifies, records
the decision, and stops — **Phase 2a**: detect and prepare automatically, a
human confirms. Flip the default to `"true"` in the TriggerTemplate (or the
poller's env) for **Phase 2b**: fully automatic. The same Pipeline, the same
checks; only who pulls the trigger changes. That progression is what lets a
risk function adopt this incrementally.

### What this changes in the pattern

- **Argo must not fight the scale-up.** `applicationsets/app-passive.yaml`
  now carries `ignoreDifferences` on `/spec/replicas` for the Odoo Deployment
  (+ `RespectIgnoreDifferences=true`). Git still owns everything else; the
  replica count is runtime state, like an HPA's.
- **SKU story becomes honest:** OpenShift · ACM (+VolSync) · Service
  Interconnect are load-bearing; Pipelines is included; AAP slots in *if you
  have it*. Three-plus-included, not four-or-nothing.
- The **return of the original region** (re-establishing it as a replica of
  the promoted site) is a separate reconcile pipeline — still open. It is the
  harder half and deserves its own design; it is not what breaks first.

---

## 5. What the first live failover found (3 Sep 2026)

The active site was powered off with no warning to the automation. Detection
and the promotion decision worked first time; execution needed four manual
interventions. All four are promotion-only defects — invisible in steady
state, and the file-store one was masked by a validation check that reported
green all week. **A DR pattern that has never been failed over is not a
validated pattern.** Each finding below is now fixed in the repo.

### 5a. GitOps reverted the failover (FIXED — "failover mode")

Argo CD self-healed the passive site back to its declared standby state
within seconds: `spec.replica.enabled` on the CNPG Cluster, `replicas: 0` on
the Deployment, and the empty declared PVC. Three `ignoreDifferences` rules
would paper over three symptoms and hide the real state change. Instead the
pipeline has an explicit **failover mode**: `dr-suspend-gitops` pauses
automated sync on the passive-site Applications (annotated
`dr.odoo/failover-mode=true`) before any mutation, and the reset/return
procedure re-enables it. The divergence from Git is deliberate, visible, and
reversible. The existing `ignoreDifferences` on Deployment replicas stays as
belt-and-braces.

### 5b. The application could not log in to the database it had just promoted (FIXED)

`pg_basebackup` copies the source's roles and databases verbatim (`odoo`/`odoo`),
but CNPG generates the passive cluster's `odoo-db-app` Secret from
`bootstrap.pg_basebackup.{database,owner}` — which default to `app`/`app` when
omitted. Odoo read a Secret for a role that did not exist. Two fixes: the
passive manifest now declares `database: odoo` / `owner: odoo` to match the
source, and `dr-promote-database` syncs the role's password to the Secret
after promotion (the replicated data still carries the *source's* password).

### 5c. The file store came up empty (FIXED — `dr-restore-filestore`)

VolSync replicates into its own destination PVC and snapshots it; the
application's PVC is separate. Nothing restored the newest snapshot into the
app volume before Odoo started, so the app had 946 attachment rows and no
files. `dr-restore-filestore` now reads `ReplicationDestination.status.latestImage`,
recreates the app PVC with that snapshot as `dataSource`, and runs between
promote and scale. Note `98-diagnose` had reported matching file counts all
week: it was counting the *destination* volume. It now also reports the app
volume so the two can never be confused again.

### 5d. The detector re-fired every minute (FIXED)

While the pool stayed unhealthy the poller started a pipeline every minute.
Harmless under the human gate; wrong for unattended operation. The poller now
idles when the passive is already promoted and never re-fires within 10
minutes of a previous run.


### 5g. The control plane must never be able to delete the data plane (FIXED)

The morning after the failover, the active site's `odoo` namespace had been
rebuilt from scratch — demo data, the customer records created during the
test gone from both sides. The exact trigger is not proven (the leading
hypothesis is that re-registering the `GitOpsCluster` to refresh Argo's
credentials regenerated Applications, with the cascading delete on the
powered-off active site executing when it came back online). The mechanism,
however, is certain and is the default behaviour of Argo CD: every Application
an ApplicationSet generates carries `resources-finalizer.argocd.argoproj.io`,
so deleting or regenerating an Application deletes every resource it owns —
the database Cluster and its volumes included.

*"My important customer records are gone"* is the one disaster this pattern
must make impossible, and it was one control-plane operation away. Two layers
now prevent it:

1. **ApplicationSets** set `preserveResourcesOnDeletion: true` (no finalizer:
   deleting an Application orphans its resources, which a new Application
   simply re-adopts) and `applicationsSync: create-update` (the generator may
   create and update Applications but **never delete** them, so a changed
   cluster secret cannot cascade).
2. **Data-bearing resources** — both CNPG `Cluster`s, both `odoo-data` PVCs,
   and the `odoo` Namespace — carry
   `argocd.argoproj.io/sync-options: Prune=false,Delete=false`. Even if a
   manifest is removed from Git or an Application is deleted by hand, Argo
   will not delete them.

The trade-off is explicit: stale resources can now be orphaned and must be
removed by a human ([TEARDOWN.md](TEARDOWN.md) already deletes the namespace
directly, so teardown is unaffected). That is the correct direction for the
error to fall. GitOps owns the desired state of the platform; it does not own
the right to destroy the customer's data.

### 5e. Measured numbers

- **RPO, database:** seconds (12–13 s steady-state lag; probe row visible in <5 s).
- **RPO, file store:** up to one sync interval (2 min). The last snapshot was
  45 s before the outage.
- **Promotion:** 7 seconds. Application cold start: ~90 s. Detection: ~3 min
  (2 edge health checks + 2 poll confirmations). DNS TTL floor: 30 s.
- **RTO:** not quoted until a clean run confirms it; the mechanical path
  suggests ~5 minutes, dominated by detection sensitivity.

### 5f. Reset vs. return

`97-reset-after-failover.yml` restores steady state for *testing*: it disables
the active pool at the edge **before** the old site is powered on (its
database still believes it is primary), rebuilds the passive as a fresh
replica, and discards post-failover writes. A true **return-to-origin** that
preserves those writes — old active re-bootstrapped as a replica of the
promoted site, then a planned switch back — is a separate design and the
next piece of work.

---

## Stack / SKU summary (the "better together" motion)

| Product | Role in the pattern |
| --- | --- |
| OpenShift | Portable application platform — the substrate-agnostic fulcrum; also provides ingress mTLS and EgressFirewall |
| ACM (VolSync included) | Multi-cluster management, GitOps distribution, filestore replication |
| Red Hat Service Interconnect (Skupper) | Cross-cloud Virtual Application Network (the VAN) |
| AAP / EDA | *(roadmap)* automated failover decision + returning-region reconciliation |

Removing any one product breaks a real capability — an honest "better together"
story for both the engineering and the economic buyer.
