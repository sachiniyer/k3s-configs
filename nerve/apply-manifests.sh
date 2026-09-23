#!/usr/bin/env bash
# Apply every nerve manifest WITHOUT moving the image.
#
# Since nerve-deployer took over rollouts (deployer.yaml), the image digest in
# deployment.yaml is whatever git last saw — usually stale. A plain
# `kubectl apply -f deployment.yaml` would silently roll nerve back to it. This
# applies the file with the image line replaced by what is running now.
#
# To ship a NEW image, push to the fork's `signal` branch (CI builds it, the
# deployer rolls it out) or run ./deploy.sh for a hand-built one.
set -euo pipefail
cd "$(dirname "$0")"
NS=nerve

live=$(kubectl -n "$NS" get deploy nerve \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="nerve")].image}' 2>/dev/null || true)

for f in namespace.yaml pvc.yaml externalsecret.yaml service.yaml ingress.yaml \
         backup-cronjob.yaml deployer.yaml; do
  [ -f "$f" ] && kubectl apply -f "$f"
done

if [ -n "$live" ]; then
  echo "keeping live image: $live"
  sed -E "s#^([[:space:]]+image: )ghcr\.io/sachiniyer/nerve[^[:space:]]*#\1${live}#" deployment.yaml \
    | kubectl apply -f -
else
  echo "no live Deployment — applying the image from git"
  kubectl apply -f deployment.yaml
fi
