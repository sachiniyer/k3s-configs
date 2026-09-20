#!/usr/bin/env bash
# Build, push and roll out a new nerve image.
#
# This exists because doing it by hand is five steps — build, push, find the
# digest, edit deployment.yaml, apply — and the two failure modes are both
# quiet. Forget the digest edit and the cluster keeps running the OLD image
# while every sign says the deploy worked. Paste the wrong digest and the pull
# fails much later, on the next reschedule, far from the change that caused it.
#
#   ./deploy.sh [path-to-fork]     default: /tmp/nervefork
#
# Pins by digest, never by tag: a floating tag is exactly the kind of silent
# drift this cluster has been bitten by before.
set -euo pipefail

FORK="${1:-/tmp/nervefork}"
IMAGE="ghcr.io/sachiniyer/nerve:phase1"
NS="nerve"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$FORK/Dockerfile.k8s" ] || {
  echo "error: no Dockerfile.k8s in $FORK" >&2
  echo "       clone it first:" >&2
  echo "       git clone --branch signal git@github.com:sachiniyer/nerve.git $FORK" >&2
  exit 1
}

echo "==> branch: $(git -C "$FORK" branch --show-current)  head: $(git -C "$FORK" log --oneline -1)"
if [ -n "$(git -C "$FORK" status --porcelain)" ]; then
  echo "WARNING: fork has uncommitted changes. The image will contain them but"
  echo "         git will not, so the running image will be unreproducible."
  read -r -p "         continue anyway? [y/N] " a
  [ "$a" = "y" ] || exit 1
fi

echo "==> building"
# -f is resolved against the CWD, not the build context, so it must be
# an absolute path into the fork — this script runs from k3s-configs/nerve.
docker build -f "$FORK/Dockerfile.k8s" -t "$IMAGE" "$FORK"

echo "==> pushing"
gh auth token | docker login ghcr.io -u sachiniyer --password-stdin >/dev/null
docker push "$IMAGE" | tee /tmp/nerve-push.log

# Read the digest back from the registry rather than trusting the local build.
# What matters is what the nodes will pull, which is what the registry now has.
DIGEST="$(grep -oE 'sha256:[a-f0-9]{64}' /tmp/nerve-push.log | tail -1)"
[ -n "$DIGEST" ] || { echo "error: could not determine pushed digest" >&2; exit 1; }
echo "==> digest: $DIGEST"

OLD="$(grep -oE 'nerve:phase1@sha256:[a-f0-9]{64}' "$HERE/deployment.yaml" | head -1 | cut -d@ -f2)"
if [ "$OLD" = "$DIGEST" ]; then
  echo "==> digest unchanged; nothing to roll out"
  exit 0
fi

echo "==> updating deployment.yaml ($OLD -> $DIGEST)"
sed -i "s|${OLD}|${DIGEST}|" "$HERE/deployment.yaml"

echo "==> applying"
kubectl -n "$NS" apply -f "$HERE/deployment.yaml"

echo "==> waiting for rollout"
# The startup self-check runs before the gateway binds, so a config or
# credential fault fails HERE, loudly, instead of producing a healthy-looking
# pod that is quietly broken.
if ! kubectl -n "$NS" rollout status deploy/nerve --timeout=6m; then
  echo ""
  echo "ROLLOUT FAILED. Check the self-check output first:"
  echo "  kubectl -n $NS logs -l app=nerve -c nerve --tail=40 | grep -A10 -i selfcheck"
  echo ""
  echo "To roll back, restore the previous digest and re-apply:"
  echo "  sed -i 's|${DIGEST}|${OLD}|' $HERE/deployment.yaml"
  echo "  kubectl -n $NS apply -f $HERE/deployment.yaml"
  exit 1
fi

echo "==> rolled out. Remember to commit the digest change:"
echo "    git -C $HERE add deployment.yaml && git -C $HERE commit"
