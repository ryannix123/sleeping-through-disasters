# Reproducibility fixes — apply to the repo

## Files (drop over the existing ones)
    ansible/playbooks/03-secrets.yml          NEW name (was 04-secrets.yml) — hub bootstrap + namespace + secrets, runs FIRST
    ansible/playbooks/04-deploy-gitops.yml    NEW name (was 03-deploy-gitops.yml) — the GitOps hand-off
    ansible/playbooks/05-interconnect-link.yml  REWRITTEN — kubernetes.core only, idempotent, timeouts
    ansible/site.yml                          new order: 00 01 02 03 04 05 06 99
    ansible/requirements.yml                  skupper.v2 removed
    ansible/README.md                         updated for the above
    ansible/inventory/hosts.yml               hub pinned to ~/.kube/hub.config; passive uses hub.config; single-context note
    docs/BOOTSTRAP.md                         single-context kubeconfig rule; secrets-before-workloads; order table
    docs/TEARDOWN.md                          sequence + checklist refs
    docs/DESIGN-DECISIONS.md                  new section 3: findings from the fresh redeploy

## Apply
```bash
cd sleeping-through-disasters
git mv ansible/playbooks/04-secrets.yml ansible/playbooks/03-secrets.yml
git mv ansible/playbooks/03-deploy-gitops.yml ansible/playbooks/04-deploy-gitops.yml
# then copy every file above into place, and:
git add -A ansible docs
git commit -m "Secrets before workloads (03/04 swap); rewrite 05 without skupper.v2; single-context kubeconfig rule; redeploy findings"
git push
```

## Check your local inventory
Your working copy of inventory/hosts.yml was already corrected by hand earlier;
the one here is the same values plus comments. Diff before overwriting if unsure:
    diff ansible/inventory/hosts.yml <path-to-this-folder>/ansible/inventory/hosts.yml

## Next fresh deploy is
    00-preflight → 02-verify-clusters → 03-secrets → 04-deploy-gitops → 05-interconnect-link → 99-verify → 06-cloudflare
with nothing typed by hand.
