"""DR invariants, checked on the rendered charts (tests/dr/render.sh).

In a GitOps repository the manifests ARE the deployment, so a typo is an
outage on the passive site that nobody notices until failover. These checks
encode the rules this pattern has learned the hard way.
"""
import glob
import os
import sys

import yaml

out = sys.argv[1]
errors = []


def docs(site, sizing, chart):
    path = os.path.join(out, f"{site}-{sizing}-{chart}.yaml")
    return [d for d in yaml.safe_load_all(open(path)) if d]


def one(ds, kind, name=None):
    found = [d for d in ds if d.get("kind") == kind and (name is None or d["metadata"]["name"] == name)]
    return found[0] if found else None


for sizing in ("standard", "sno"):
    passive_db = one(docs("hub", sizing, "odoo-database"), "Cluster")
    active_db = one(docs("active", sizing, "odoo-database"), "Cluster")

    # The passive database must stay a replica in Git. Promotion happens at
    # runtime (the failover pipeline), never by commit.
    if passive_db["spec"].get("replica", {}).get("enabled") is not True:
        errors.append(f"[{sizing}] passive PostgreSQL is not in replica mode")

    # Standard sizing keeps a synchronous local replica (RPO 0 for a node or
    # zone loss); any multi-instance primary must declare synchronous config.
    inst = active_db["spec"]["instances"]
    if sizing == "standard" and inst < 2:
        errors.append("[standard] active PostgreSQL has fewer than 2 instances")
    if inst > 1 and not active_db["spec"]["postgresql"].get("synchronous"):
        errors.append(f"[{sizing}] active PostgreSQL has {inst} instances but no synchronous config")
    if inst == 1 and active_db["spec"]["postgresql"].get("synchronous"):
        errors.append(f"[{sizing}] single-instance primary declares synchronous replication (writes would block)")

    # Interconnect: what one site publishes, the other must listen for.
    a_ic = docs("active", sizing, "odoo-interconnect")
    p_ic = docs("hub", sizing, "odoo-interconnect")
    keys = lambda ds, k: {d["spec"]["routingKey"] for d in ds if d["kind"] == k}
    if keys(a_ic, "Connector") != keys(p_ic, "Listener"):
        errors.append(f"[{sizing}] DB routing keys differ: {keys(a_ic, 'Connector')} vs {keys(p_ic, 'Listener')}")
    if keys(p_ic, "Connector") != keys(a_ic, "Listener"):
        errors.append(f"[{sizing}] VolSync routing keys differ: {keys(p_ic, 'Connector')} vs {keys(a_ic, 'Listener')}")

    # The replica must dial the host the passive Listener publishes.
    hosts = {ec["connectionParameters"]["host"] for ec in passive_db["spec"].get("externalClusters", [])}
    published = {d["spec"]["host"] for d in p_ic if d["kind"] == "Listener"}
    if hosts != published:
        errors.append(f"[{sizing}] replica dials {hosts} but the Listener publishes {published}")

    # VolSync: both sides must use the same pre-shared key Secret.
    rs = one(docs("active", sizing, "odoo-filestore"), "ReplicationSource")
    rd = one(docs("hub", sizing, "odoo-filestore"), "ReplicationDestination")
    if rs["spec"]["rsyncTLS"].get("keySecret") != rd["spec"]["rsyncTLS"].get("keySecret"):
        errors.append(f"[{sizing}] VolSync keySecret differs between source and destination")
    if rs["spec"]["rsyncTLS"]["address"] not in published | {d["spec"]["host"] for d in a_ic if d["kind"] == "Listener"}:
        errors.append(f"[{sizing}] ReplicationSource address is not a published Listener host")

    # Odoo cannot scale past one replica on a ReadWriteOnce filestore, and the
    # passive site must stay a pilot light.
    a_app = docs("active", sizing, "odoo-app")
    if one(a_app, "Deployment", "odoo")["spec"]["replicas"] > 1 and \
            "ReadWriteOnce" in one(a_app, "PersistentVolumeClaim", "odoo-data")["spec"]["accessModes"]:
        errors.append(f"[{sizing}] active Odoo > 1 replica on a ReadWriteOnce filestore")
    p_app = docs("hub", sizing, "odoo-app")
    if one(p_app, "Deployment", "odoo")["spec"]["replicas"] != 0:
        errors.append(f"[{sizing}] passive Odoo is not scaled to zero")
    if one(p_app, "PersistentVolumeClaim"):
        errors.append(f"[{sizing}] passive site declares a filestore PVC; it would race the failover restore")

    # Data-bearing resources must never be pruned or deleted by Argo CD.
    for ds, kind in ((docs("active", sizing, "odoo-database"), "Cluster"),
                     (docs("hub", sizing, "odoo-database"), "Cluster"),
                     (a_app, "PersistentVolumeClaim")):
        d = one(ds, kind)
        if "Delete=false" not in d["metadata"].get("annotations", {}).get("argocd.argoproj.io/sync-options", ""):
            errors.append(f"[{sizing}] {kind} {d['metadata']['name']} is missing Prune=false,Delete=false")

# Promotion safety: the hub Applications must ignore the fields a failover
# changes, or Argo CD reverts the promotion within seconds.
hub = yaml.safe_load(open("values-hub.yaml"))["clusterGroup"]["applications"]
for app, kind, pointer in (("odoo-database", "Cluster", "/spec/replica/enabled"),
                           ("odoo-app", "Deployment", "/spec/replicas")):
    spec = hub[app]
    ignored = [p for i in spec.get("ignoreDifferences", []) if i.get("kind") == kind for p in i.get("jsonPointers", [])]
    if pointer not in ignored:
        errors.append(f"values-hub.yaml: {app} does not ignore {kind} {pointer}")
    if "RespectIgnoreDifferences=true" not in spec.get("syncPolicy", {}).get("syncOptions", []):
        errors.append(f"values-hub.yaml: {app} lacks RespectIgnoreDifferences=true")

# Every local chart an Application points at must exist.
for vf in glob.glob("values-*.yaml"):
    cg = (yaml.safe_load(open(vf)) or {}).get("clusterGroup") or {}
    for name, app in (cg.get("applications") or {}).items():
        if app.get("path") and not os.path.isfile(os.path.join(app["path"], "Chart.yaml")):
            errors.append(f"{vf}: application {name} points at missing chart {app['path']}")

for e in errors:
    print("ERROR:", e)
print("DR invariants:", "FAILED" if errors else "all passed")
sys.exit(1 if errors else 0)
