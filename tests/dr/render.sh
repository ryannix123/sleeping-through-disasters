#!/usr/bin/env bash
# Render every pattern chart the way Argo CD will: with the full values stack
# for each site (values-global + the clustergroup file + the sizing profile)
# and the role override from the clustergroup file. Output: one file per
# site/profile/chart in the directory given as $1.
set -euo pipefail
out="${1:?usage: render.sh <output dir>}"
cd "$(dirname "$0")/../.."
mkdir -p "$out"
for site in hub active; do
  role=$([ "$site" = hub ] && echo passive || echo active)
  for sizing in standard sno; do
    for chart in charts/*/; do
      chart=$(basename "$chart")
      grep -q "path: charts/$chart\$" "values-$site.yaml" || continue
      args=(-f values-global.yaml -f "values-$site.yaml" -f "overrides/values-sizing-$sizing.yaml"
            --set "global.odooDR.sizing=$sizing" --set global.localClusterDomain=apps.example.com)
      case "$chart" in odoo-failover|odoo-dr-governance) ;; *) args+=(--set "role=$role");; esac
      helm template "$chart" "charts/$chart" "${args[@]}" > "$out/$site-$sizing-$chart.yaml"
      echo "rendered $site/$sizing/$chart"
    done
  done
done
