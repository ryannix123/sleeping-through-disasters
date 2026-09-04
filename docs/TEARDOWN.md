# Teardown — removing the pattern completely

How to remove every component the pattern deploys, in an order that actually
works. Use this before a fresh redeploy, or to decommission.

## Note: Argo no longer cascades deletes (by design)

Since the data-plane protection in [DESIGN-DECISIONS.md §5g](DESIGN-DECISIONS.md),
deleting an Application or ApplicationSet **orphans** its resources instead of
deleting them, and the CNPG Clusters, `odoo-data` PVCs and the `odoo` namespace
are annotated so Argo never deletes them at all. Teardown therefore relies on
the direct `oc delete namespace` in step 3 — which it always did — and you
will not see Argo remove workloads on its own. This is intentional.

## The one rule: delete the source, not the symptom

Everything on the managed clusters is owned by Argo CD, which is driven by
ApplicationSets on the hub. If you delete a namespace, a Deployment, or a Route
on a spoke while its Application still exists, **Argo recreates it within
minutes** — deletion appears to "not stick." The teardown therefore runs
**top-down**: hub definitions first, spoke resources second.

Symptom of getting this wrong: `oc get ns odoo` on the hub shows the namespace
`Active` again, seconds old, after you deleted it.

## What is kept vs. wiped

| Kept (idempotent, slow to rebuild, or a prerequisite) | Wiped |
| --- | --- |
| The four operators (CNPG, VolSync, Service Interconnect, OADP) | The `odoo` namespace on both clusters — **all PVCs and data** |
| Cloudflare monitor, pools, load balancer (`06` is idempotent) | Argo ApplicationSets/Applications for the pattern |
| The default `VolumeSnapshotClass` annotation (cluster-scoped prereq) | ACM policies, placements, GitOpsCluster, ManagedClusterSet |
| The Ansible vault (passwords are re-applied to fresh databases) | Skupper links/grants/tokens (they live in `odoo`) |

Keep the operators installed: CNPG's operator must be **running** to execute
the database cluster's finalizers when the namespace is deleted. Remove the
operators only as a deliberate last step, after the namespaces are gone.

## Setup

```bash
export HUB=~/.kube/hub.config
export ACTIVE=~/.kube/active.config
oc --kubeconfig=$HUB whoami --show-server     # hub / passive
oc --kubeconfig=$ACTIVE whoami --show-server  # active
```

Use an explicit `KUBECONFIG=` prefix on every command. A bare `oc` falls back
to your default context — which may be the cluster you are *not* targeting.

## 1. Remove the workload ApplicationSets on the hub

Explicit names — do **not** pipe into `xargs` with an env-var prefix
(`xargs -n1 KUBECONFIG=... oc delete` fails with "No such file or directory"
and silently deletes nothing).

```bash
KUBECONFIG=$HUB oc delete applicationsets.argoproj.io -n openshift-gitops \
  odoo-app-active odoo-app-passive \
  odoo-interconnect-active odoo-interconnect-passive \
  odoo-namespace \
  odoo-postgres-active odoo-postgres-passive \
  odoo-volsync-active odoo-volsync-passive
```

`odoo-operators` is intentionally left in place.

## 2. Confirm the generated Applications are gone

This is the check that breaks the recreation loop.

```bash
KUBECONFIG=$HUB oc get applications.argoproj.io -n openshift-gitops | grep odoo
# want: only odoo-operators-active and odoo-operators-local-cluster
```

**Stragglers happen.** An Application that was ever hand-patched during
troubleshooting (e.g. `operation: null`, `Replace=true`, a hard refresh) can
survive its ApplicationSet's deletion. Delete it by name; if it hangs on a
finalizer, clear the finalizer:

```bash
KUBECONFIG=$HUB oc delete applications.argoproj.io <name> -n openshift-gitops
# if it hangs:
KUBECONFIG=$HUB oc patch applications.argoproj.io <name> -n openshift-gitops \
  --type merge -p '{"metadata":{"finalizers":[]}}'
```

## 3. Delete the `odoo` namespace on both clusters

Only now — nothing is left to recreate it.

```bash
KUBECONFIG=$ACTIVE oc delete namespace odoo --wait=false
KUBECONFIG=$HUB    oc delete namespace odoo --wait=false
KUBECONFIG=$ACTIVE oc get ns odoo; KUBECONFIG=$HUB oc get ns odoo
```

Expect `Terminating` for a couple of minutes while CNPG and VolSync run their
finalizers, then `NotFound`.

**If a namespace stays `Terminating` past ~3–5 minutes**, find what is holding
it — the namespace status names the resource type:

```bash
KUBECONFIG=$ACTIVE oc get ns odoo -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

Then clear the finalizer on **that specific resource** (commonly a
`VolumeSnapshot`), not on the namespace:

```bash
KUBECONFIG=$ACTIVE oc get volumesnapshot -n odoo
KUBECONFIG=$ACTIVE oc patch volumesnapshot <name> -n odoo --type merge \
  -p '{"metadata":{"finalizers":[]}}'
```

Do not force-delete the namespace by editing `spec.finalizers`; that orphans
the stuck objects and leaves storage debris behind.

## 4. Remove the ACM policies and hub bootstrap

The exact inverse of the hub bootstrap (playbooks `03`/`04`), using the repo's own files:

```bash
cd sleeping-through-disasters
for f in policies/policy-*.yaml; do KUBECONFIG=$HUB oc delete -f $f --ignore-not-found; done
for f in $(ls -r hub/0*.yaml); do KUBECONFIG=$HUB oc delete -f $f --ignore-not-found; done
```

This removes the policies, placements, GitOpsCluster, ManagedClusterSet and
the `odoo-dr-acm` namespace. The managed clusters keep their `clusterset` and
`role` labels — `03` re-creates the set and they rejoin.

## 5. Verify the prerequisites survived (cluster-scoped, easy to lose)

The default `VolumeSnapshotClass` annotation is imperative and cluster-scoped.
`oc get volumesnapshotclass` does **not** display a `(default)` marker, so check
the annotation directly:

```bash
KUBECONFIG=$ACTIVE oc get volumesnapshotclass lvms-vg1 -o jsonpath='{.metadata.annotations}{"\n"}'
KUBECONFIG=$HUB    oc get volumesnapshotclass ocs-external-storagecluster-rbdplugin-snapclass -o jsonpath='{.metadata.annotations}{"\n"}'
```

Each must contain `snapshot.storage.kubernetes.io/is-default-class: "true"`.
Without it, the first VolSync sync on the redeploy stalls with
`cannot find default snapshot class`. See [BOOTSTRAP.md](BOOTSTRAP.md).

## 6. (Optional) remove the operators

Only for a true from-nothing rebuild, and only after step 3 completes:

```bash
KUBECONFIG=$HUB oc delete applicationsets.argoproj.io odoo-operators -n openshift-gitops
```

Then remove the Subscriptions/CSVs on each cluster as you would any OLM
operator. Reinstalling adds ~5–10 minutes to the redeploy.

## Clean-slate checklist

- [ ] Only `odoo-operators` ApplicationSet remains on the hub
- [ ] Only the two `odoo-operators-*` Applications remain
- [ ] `odoo` namespace is `NotFound` on **both** clusters
- [ ] `odoo-dr-acm` namespace and the hub bootstrap objects are gone
- [ ] Default VolumeSnapshotClass annotation present on **both** clusters
- [ ] Both kubeconfigs are single-context files with fresh tokens
      (`oc --kubeconfig=<file> config get-contexts` shows one line; `whoami` works)

Then redeploy from the top: `00-preflight` → `02` → `03-secrets` →
`04-deploy-gitops` → `05` → `99` → `06`. See [BOOTSTRAP.md](BOOTSTRAP.md).
