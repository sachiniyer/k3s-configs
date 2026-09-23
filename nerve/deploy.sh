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
# The MANUAL path. Normally nothing needs it: pushing to the fork's `signal`
# branch makes CI build and publish, and nerve-deployer rolls it out at 03:30
# (or within 15 minutes of the agent requesting it). Use this when CI is down,
# or to ship something right now and watch it land.
#
# It publishes to the same `:signal` tag CI does, with the same newest
# CLI/SDK versions, so the deployer sees a hand-built image as current rather
# than "rolling back" to CI's. Pins by digest, never by tag.
set -euo pipefail

FORK="${1:-/tmp/nervefork}"
IMAGE="ghcr.io/sachiniyer/nerve:signal"
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
# Same version policy as CI (k8s-image.yml): newest CLI and SDK unless pinned
# in the environment.
CLI="${CLAUDE_CODE_VERSION:-$(npm view @anthropic-ai/claude-code version)}"
SDK="${CLAUDE_AGENT_SDK_VERSION:-$(curl -fsS https://pypi.org/pypi/claude-agent-sdk/json | jq -r .info.version)}"
echo "==> Claude Code CLI $CLI, Agent SDK $SDK"
docker build -f "$FORK/Dockerfile.k8s" -t "$IMAGE" \
  --build-arg "CLAUDE_CODE_VERSION=$CLI" --build-arg "CLAUDE_AGENT_SDK_VERSION=$SDK" "$FORK"

echo "==> pushing"
gh auth token | docker login ghcr.io -u sachiniyer --password-stdin >/dev/null
docker push "$IMAGE" | tee /tmp/nerve-push.log

# Read the digest back from the registry rather than trusting the local build.
# What matters is what the nodes will pull, which is what the registry now has.
DIGEST="$(grep -oE 'sha256:[a-f0-9]{64}' /tmp/nerve-push.log | tail -1)"
[ -n "$DIGEST" ] || { echo "error: could not determine pushed digest" >&2; exit 1; }
echo "==> digest: $DIGEST"

# Compare against what is RUNNING, not git: nerve-deployer moves the live
# image without committing, so the digest in deployment.yaml is often stale.
LIVE="$(kubectl -n "$NS" get deploy nerve \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="nerve")].image}')"
OLD="${LIVE##*@}"
if [ "$OLD" = "$DIGEST" ]; then
  echo "==> already running $DIGEST; nothing to roll out"
  exit 0
fi

echo "==> updating deployment.yaml ($OLD -> $DIGEST)"
sed -E -i "s#^([[:space:]]+image: )ghcr\.io/sachiniyer/nerve[^[:space:]]*#\1ghcr.io/sachiniyer/nerve:signal@${DIGEST}#" \
  "$HERE/deployment.yaml"
grep -q "nerve:signal@${DIGEST}" "$HERE/deployment.yaml" \
  || { echo "error: failed to write the new digest into deployment.yaml" >&2; exit 1; }

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
  echo "To roll back:"
  echo "  kubectl -n $NS rollout undo deploy/nerve"
  echo "and pause the deployer so it does not immediately retry :signal:"
  echo "  kubectl -n $NS annotate deploy nerve nerve.sachiniyer.com/auto-deploy=paused"
  exit 1
fi

echo "==> rolled out. Remember to commit the digest change:"
echo "    git -C $HERE add deployment.yaml && git -C $HERE commit"
