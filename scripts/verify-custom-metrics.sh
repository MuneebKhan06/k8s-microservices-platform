#!/usr/bin/env bash
# Checks whether the external metrics every HPA in this platform reads have
# actually surfaced through prometheus-adapter, before trusting any of
# those HPAs.
#
# Per the build plan's own Day 9 warning: the chain is app exposes a
# metric -> Prometheus scrapes it -> prometheus-adapter publishes it ->
# HPA reads it, and every link can break silently. An HPA reading a metric
# that never arrived does not error. It reports <unknown> in
# `kubectl get hpa` and sits at minReplicas forever, which looks identical
# to "traffic is just low" until someone thinks to check this list.
#
# Usage:
#   ./scripts/verify-custom-metrics.sh
#
# Requires kubectl pointed at the cluster and jq.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required and was not found on PATH." >&2
  exit 2
fi

# name | which HPA reads it | expect-present
# expect-present is "yes" for the two rules
# manifests/prometheus/adapter-values.yaml actually publishes, and "no" for
# the two documented there as absent. A "no" entry showing up as present
# is not a failure, it means someone did the follow-up work; a "yes" entry
# showing up as absent is the real problem this script exists to catch.
METRICS=(
  "redis_stream_length_total|distributed-job-queue worker HPA|yes"
  "gateway_http_requests_per_second|api-gateway HPA|yes"
  "kafka_consumer_lag|event-ingestion-api HPA|no"
  "http_requests_per_second|distributed-job-queue api HPA|no"
)

echo "Querying the external metrics API..."
response="$(kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1" 2>&1)" || {
  echo "FAIL: could not reach the external metrics API." >&2
  echo "$response" >&2
  echo "This means prometheus-adapter is not installed, not registered as" >&2
  echo "an APIService, or not running: a different problem than any" >&2
  echo "individual metric being missing, and every HPA below is affected." >&2
  exit 1
}

available="$(echo "$response" | jq -r '.resources[].name' | sort -u)"

failures=0
echo
printf '%-38s %-32s %-9s %s\n' "METRIC" "USED BY" "EXPECTED" "STATUS"
for entry in "${METRICS[@]}"; do
  IFS='|' read -r name owner expected <<<"$entry"
  if echo "$available" | grep -qx "$name"; then
    status="present"
  else
    status="absent"
  fi

  printf '%-38s %-32s %-9s %s\n' "$name" "$owner" "$expected" "$status"

  if [[ "$expected" == "yes" && "$status" == "absent" ]]; then
    failures=$((failures + 1))
  fi
done

echo
if [[ "$failures" -gt 0 ]]; then
  echo "FAIL: $failures metric(s) expected to be working are absent."
  echo "Check prometheus-adapter's logs and confirm the underlying" >&2
  echo "Prometheus series exists first: a missing series and a wrong" >&2
  echo "adapter rule look identical from here." >&2
  exit 1
fi

echo "OK: every metric expected to be working is present."
echo "Metrics marked 'no' under EXPECTED are documented gaps, not this" >&2
echo "script's concern; see manifests/prometheus/adapter-values.yaml." >&2
