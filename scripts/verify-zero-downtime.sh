#!/usr/bin/env bash
# Sends continuous traffic to api-gateway while a `helm upgrade` runs
# against it, and counts failed requests. This is the Day 12 zero-downtime
# check from the build plan: the question is not whether the rollout
# finishes, it is whether anything in flight during it saw a failure.
#
# A failure here means the readiness probe or the Deployment's
# maxUnavailable/maxSurge is wrong, not that rolling deploys are unsafe in
# general. Kubernetes only routes to Ready pods; if a request fails during
# a rollout, either a pod was marked Ready before it could actually serve
# (readiness probe too lenient, or missing an initialDelaySeconds long
# enough for real startup), or too many old pods were torn down before
# their replacements were Ready (maxUnavailable too high for a 2-replica
# Deployment, where losing even one is already half of capacity).
#
# Usage:
#   ./scripts/verify-zero-downtime.sh <new-image-tag> [duration-seconds]
#
# Requires kubectl port-forward to reach api-gateway (this script opens its
# own, on a random local port, and tears it down on exit) and curl. Does
# not require a load testing tool: the traffic here only needs to overlap
# the rollout window, not model realistic concurrency.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <new-image-tag> [duration-seconds]" >&2
  exit 2
fi

NEW_TAG="$1"
DURATION="${2:-60}"
LOCAL_PORT=18000
NAMESPACE=platform
LOG_FILE="$(mktemp)"

cleanup() {
  [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

echo "== Opening port-forward to api-gateway =="
kubectl port-forward -n "$NAMESPACE" svc/api-gateway "$LOCAL_PORT:80" >/dev/null 2>&1 &
PF_PID=$!
sleep 2

echo "== Sending traffic for ${DURATION}s while the rollout runs =="
(
  end=$((SECONDS + DURATION))
  while [[ $SECONDS -lt $end ]]; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:${LOCAL_PORT}/health/ready" || echo "000")
    echo "$code" >>"$LOG_FILE"
    sleep 0.2
  done
) &
TRAFFIC_PID=$!

echo "== Rolling api-gateway to tag ${NEW_TAG} =="
helm upgrade api-gateway ./helm/api-gateway -n "$NAMESPACE" \
  --reuse-values \
  --set image.tag="$NEW_TAG" \
  --wait --timeout 5m

wait "$TRAFFIC_PID"

TOTAL=$(wc -l <"$LOG_FILE")
FAILED=$(grep -cv '^2' "$LOG_FILE" || true)

echo
echo "== Result =="
echo "Total requests: $TOTAL"
echo "Failed (non-2xx or timeout): $FAILED"

if [[ "$FAILED" -gt 0 ]]; then
  echo "Non-2xx/timeout codes seen:"
  grep -v '^2' "$LOG_FILE" | sort | uniq -c
  echo
  echo "Zero-downtime NOT verified. Check readinessProbe timing and"
  echo "maxUnavailable in helm/api-gateway/templates/deployment.yaml before"
  echo "assuming this is a fluke and re-running."
  exit 1
fi

echo "Zero-downtime verified: no failed requests during the rollout."
