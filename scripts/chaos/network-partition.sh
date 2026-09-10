#!/usr/bin/env bash
# Chaos Test 6: network partition between two namespaces.
#
# Expected outcome: services in namespace A that depend on namespace B
# start failing, api-gateway's circuit breakers for the affected upstreams
# open, clients get 503s, and everything recovers once the partition
# heals.
#
# Mechanism, and why it is not a NetworkPolicy:
#
# This cluster's CNI is Flannel, which does not enforce NetworkPolicy at
# all. A deny-all NetworkPolicy between the two namespaces would apply
# cleanly with kubectl and do absolutely nothing, which is the worst kind
# of chaos test: one that reports success while changing nothing.
#
# Instead this drains the endpoints of every Service in namespace B by
# repointing its selector at a label no pod carries. The Service object
# and its DNS name stay, so callers in namespace A still resolve
# postgresql.infra.svc.cluster.local and still try to connect; the
# connection just goes nowhere, which is what a partition looks like from
# the client's side. Healing is restoring the original selectors, saved
# to a tempfile and also replayed by the EXIT trap so an interrupted run
# does not leave namespace B's services permanently unreachable.
#
# This is control-plane only: no privileged pods, no iptables, no
# dependency on which CNI is installed. It does not reproduce asymmetric
# partitions or packet loss; for those, move the cluster to a
# NetworkPolicy-enforcing CNI (Calico, Cilium) and this script can be
# swapped for the real thing.
#
# Usage:
#   scripts/chaos/network-partition.sh <namespace-a> <namespace-b>
#
# Example (from the build plan):
#   scripts/chaos/network-partition.sh platform infra

set -euo pipefail

NS_A="${1:-}"
NS_B="${2:-}"
if [[ -z "$NS_A" || -z "$NS_B" ]]; then
  echo "usage: $0 <namespace-a> <namespace-b>" >&2
  exit 2
fi

SAVED="$(mktemp)"
CHAOS_LABEL='chaos-partition=cut'

restore() {
  echo
  echo "Healing: restoring original Service selectors in $NS_B"
  while IFS=$'\t' read -r svc selector_json; do
    [[ -z "$svc" ]] && continue
    kubectl patch svc "$svc" -n "$NS_B" --type json \
      -p "[{\"op\": \"replace\", \"path\": \"/spec/selector\", \"value\": $selector_json}]" \
      >/dev/null 2>&1 || echo "  could not restore $svc (already gone?)" >&2
  done < "$SAVED"
  rm -f "$SAVED"
  echo "Selectors restored. Endpoints will repopulate within a scrape or two."
}
trap restore EXIT

echo "Services in $NS_B that will lose their endpoints:"
# ExternalName services have no selector to break; skip them.
mapfile -t SERVICES < <(kubectl get svc -n "$NS_B" -o json \
  | jq -r '.items[] | select(.spec.type != "ExternalName") | select(.spec.selector != null) | .metadata.name')

if [[ "${#SERVICES[@]}" -eq 0 ]]; then
  echo "  none. Nothing to partition." >&2
  exit 1
fi
printf '  %s\n' "${SERVICES[@]}"

echo
echo "Cutting..."
for svc in "${SERVICES[@]}"; do
  # Capture the selector as compact JSON, not jsonpath's Go-map string
  # format, so restore() can replay it verbatim into a json patch.
  original="$(kubectl get svc "$svc" -n "$NS_B" -o json | jq -c '.spec.selector')"
  printf '%s\t%s\n' "$svc" "$original" >> "$SAVED"
  # Merge a key no pod carries into the selector, so it matches nothing
  # and the Service's endpoint list drains to empty.
  kubectl patch svc "$svc" -n "$NS_B" --type merge \
    -p "{\"spec\": {\"selector\": {\"${CHAOS_LABEL%=*}\": \"${CHAOS_LABEL#*=}\"}}}" >/dev/null
done

echo
echo "Partition in place. In another terminal, watch the effect:"
echo "  kubectl get pods -n $NS_A -w"
echo "  kubectl exec deploy/api-gateway -n $NS_A -- wget -qO- localhost:8000/health"
echo "     (expect degraded/unhealthy, and 503s on proxied routes)"
echo
read -r -p "Press Enter to heal the partition... " _

# restore() runs via the EXIT trap.
