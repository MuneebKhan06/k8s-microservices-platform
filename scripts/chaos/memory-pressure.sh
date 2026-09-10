#!/usr/bin/env bash
# Chaos Test 5: memory limit exceeded, OOM kill.
#
# execs into a running pod of the target workload and allocates memory in a
# loop until the container's cgroup hits its memory limit and the kernel
# OOM killer fires. The expected outcome is that Kubernetes restarts the
# container in place (restartCount goes up by one) and does not delete or
# reschedule the pod, since an OOM is a container-level failure, not a pod
# or node one.
#
# The allocation runs inside the container via `kubectl exec`, sharing the
# container's cgroup. Whether the OOM killer picks the exec'd allocator or
# the main application process depends on their oom_score at the moment the
# limit is hit; either way the container restarts, which is what the test
# checks. The application processes in this platform's images are all
# Python (uvicorn, or `python -m worker.main`), so `python3` is on PATH to
# do the allocating with no extra tooling in the image.
#
# Usage:
#   scripts/chaos/memory-pressure.sh <app-name> [namespace] [component]
#
# Example (from the build plan):
#   scripts/chaos/memory-pressure.sh distributed-job-queue platform worker

set -euo pipefail

APP="${1:-}"
NAMESPACE="${2:-platform}"
COMPONENT="${3:-}"

if [[ -z "$APP" ]]; then
  echo "usage: $0 <app-name> [namespace] [component]" >&2
  exit 2
fi

SELECTOR="app.kubernetes.io/name=$APP"
if [[ -n "$COMPONENT" ]]; then
  SELECTOR="$SELECTOR,app.kubernetes.io/component=$COMPONENT"
fi

POD="$(kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" \
  --field-selector=status.phase=Running -o name | head -n1)"
if [[ -z "$POD" ]]; then
  echo "No running pod matches $SELECTOR in $NAMESPACE." >&2
  exit 1
fi
POD="${POD#pod/}"

before="$(kubectl get pod "$POD" -n "$NAMESPACE" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}')"
echo "Target pod: $POD  (restartCount now: $before)"
echo "Watch it restart in another terminal with:"
echo "  kubectl get pod $POD -n $NAMESPACE -w"
echo
echo "Allocating memory inside the container until OOM..."

# `iter(int, 1)` is an endless iterator; each step appends 10 MiB of zeros
# to a bytearray that is never freed. `|| true` because the exec's exit
# code will be non-zero when the process is killed, which is the success
# case here, not a failure to report.
kubectl exec "$POD" -n "$NAMESPACE" -- \
  python3 -c "b = bytearray()
for _ in iter(int, 1):
    b.extend(b'\\0' * (10 * 1024 * 1024))" || true

echo
echo "Waiting for the restartCount to increment..."
for _ in $(seq 1 30); do
  after="$(kubectl get pod "$POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "$before")"
  if [[ "$after" -gt "$before" ]]; then
    echo "restartCount went $before -> $after. Container was OOM killed and"
    echo "restarted in place; the pod was not deleted. That matches Chaos"
    echo "Test 5's expected outcome."
    kubectl get pod "$POD" -n "$NAMESPACE" -o wide
    exit 0
  fi
  sleep 2
done

echo "restartCount did not change within 60s. Either the limit is high"
echo "enough that the exec session ended before the cgroup filled, or the"
echo "pod is already gone. Check:"
kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" -o wide
exit 1
