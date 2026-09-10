#!/usr/bin/env bash
# Chaos Test 1: pod failure.
#
# Deletes one running pod of a workload and times how long until a
# replacement is Ready again. For a Deployment behind a ReplicaSet this is
# the controller noticing the missing replica and scheduling a new one; for
# a single-replica StatefulSet (postgresql, redis, kafka as they stand
# today) it is the same pod name coming back with its PVC reattached, which
# is a slower path and not a failover, since there is no second replica to
# promote yet.
#
# Usage:
#   scripts/chaos/kill-pod.sh <app-name> [namespace] [component]
#
#   <app-name>   value of the app.kubernetes.io/name label
#                (event-ingestion-api, distributed-job-queue, api-gateway,
#                 postgresql, redis, kafka)
#   namespace    defaults to platform
#   component    optional app.kubernetes.io/component (api | worker),
#                needed only to disambiguate distributed-job-queue
#
# Examples:
#   scripts/chaos/kill-pod.sh api-gateway
#   scripts/chaos/kill-pod.sh distributed-job-queue platform worker
#   scripts/chaos/kill-pod.sh postgresql infra

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

echo "Selector: $SELECTOR  (namespace $NAMESPACE)"

mapfile -t PODS < <(kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" \
  --field-selector=status.phase=Running -o name)

if [[ "${#PODS[@]}" -eq 0 ]]; then
  echo "No running pods match. Nothing to kill." >&2
  exit 1
fi

if [[ "${#PODS[@]}" -eq 1 ]]; then
  echo "Warning: only one running pod matches. Deleting it means a real"
  echo "outage for this workload until the replacement is Ready, not a"
  echo "graceful failover. Continuing in 5s; Ctrl-C to abort."
  sleep 5
fi

TARGET="${PODS[RANDOM % ${#PODS[@]}]}"
echo "Killing $TARGET"

START="$(date +%s)"
kubectl delete "$TARGET" -n "$NAMESPACE" --wait=false

echo "Waiting for the workload to report all pods Ready again..."
# --for=condition=Ready on the selector waits for every pod currently
# matching it, which after the delete is the survivors plus the
# replacement once it is created. A short retry loop covers the gap
# between the delete landing and the replacement pod existing to wait on.
for _ in $(seq 1 60); do
  if kubectl wait --for=condition=Ready pod -l "$SELECTOR" -n "$NAMESPACE" \
      --timeout=5s >/dev/null 2>&1; then
    break
  fi
done

END="$(date +%s)"
echo
echo "Recovered in $((END - START))s."
echo "Record this against Chaos Test 1's 'replacement within 30s' expectation."
echo
kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" -o wide
