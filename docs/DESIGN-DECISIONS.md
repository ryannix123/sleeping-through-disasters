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

## Stack / SKU summary (the "better together" motion)

| Product | Role in the pattern |
| --- | --- |
| OpenShift | Portable application platform — the substrate-agnostic fulcrum; also provides ingress mTLS and EgressFirewall |
| ACM (VolSync included) | Multi-cluster management, GitOps distribution, filestore replication |
| Red Hat Service Interconnect (Skupper) | Cross-cloud Virtual Application Network (the VAN) |
| AAP / EDA | *(roadmap)* automated failover decision + returning-region reconciliation |

Removing any one product breaks a real capability — an honest "better together"
story for both the engineering and the economic buyer.
