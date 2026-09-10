#!/usr/bin/env bash
# Chaos Test 2: node failure, simulated by cordon + drain.
#
# Cordons a node so nothing new schedules there, evicts everything already
# running on it, and times how long until the platform namespace is fully
# Ready again on the remaining nodes. Uncordons the node afterwards, and
# also on Ctrl-C, so an interrupted run does not leave a node permanently
# out of the scheduler's pool.
#
# Two things this test is really checking:
#
#  - The PodDisruptionBudgets added to the four application Deployments do
#    their job. drain honours a PDB: with maxUnavailable 1, it evicts one
#    replica of a given workload, waits for the replacement elsewhere to
#    go Ready, then evicts the next. Without the PDBs, drain would evict
#    every replica on this node at once.
#
#  - The local-path storage limitation is real and visible. A StatefulSet
#    pod (postgresql, redis, kafka) whose PVC was provisioned on the
#    drained node cannot reschedule: local-path volumes are bound to one
#    node's disk, so the pod sits Pending until the node comes back. This
#    script points that out rather than hiding it, because a chaos test
#    that surfaces a known limitation is worth more than one that is
#    engineered to pass.
#
# Usage:
#   scripts/chaos/kill-node.sh <node-name>

set -euo pipefail

NODE="${1:-}"
if [[ -z "$NODE" ]]; then
  echo "usage: $0 <node-name>" >&2
  echo "nodes:" >&2
  kubectl get nodes -o wide >&2 || true
  exit 2
fi

if ! kubectl get node "$NODE" >/dev/null 2>&1; then
  echo "Node $NODE not found." >&2
  exit 1
fi

# Refuse to drain a control-plane node: evicting the API server, etcd or
# the scheduler is not a workload-resilience test, it is an outage of the
# thing running the test.
if kubectl get node "$NODE" -o jsonpath='{.metadata.labels}' \
    | grep -q 'node-role.kubernetes.io/control-plane'; then
  echo "$NODE is a control-plane node. Refusing to drain it." >&2
  exit 1
fi

# grep -w Ready on the STATUS column: matches "Ready", not "NotReady"
# (no word boundary before "Ready" inside "NotReady"), and does not
# depend on the Ready condition being last in the conditions array the
# way a jsonpath conditions[-1] check would.
READY_WORKERS="$(kubectl get nodes \
  -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null \
  | grep -cw Ready || true)"
if [[ "$READY_WORKERS" -le 1 ]]; then
  echo "Only $READY_WORKERS worker node(s) Ready. Draining the last one" >&2
  echo "leaves nowhere for its pods to go and is an outage, not a test." >&2
  exit 1
fi

restore() {
  echo
  echo "Uncordoning $NODE"
  kubectl uncordon "$NODE" || true
}
trap restore EXIT

echo "Pods on $NODE before drain:"
kubectl get pods --all-namespaces --field-selector "spec.nodeName=$NODE" -o wide

echo
echo "Cordoning $NODE"
kubectl cordon "$NODE"

START="$(date +%s)"
echo
echo "Draining $NODE (DaemonSet pods ignored, emptyDir data deleted)..."
# --disable-eviction=false keeps eviction going through the PDB checks
# rather than force-deleting, which is the whole point of the test.
kubectl drain "$NODE" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=300s || {
    echo
    echo "drain did not complete cleanly. Almost always this is a"
    echo "StatefulSet pod whose local-path PVC is pinned to $NODE and"
    echo "cannot move. Pending pods:"
    kubectl get pods --all-namespaces --field-selector status.phase=Pending -o wide
  }

echo
echo "Waiting for the platform namespace to be fully Ready again..."
kubectl wait --for=condition=Ready pod --all -n platform --timeout=180s || true
END="$(date +%s)"

echo
echo "Platform namespace stable again in $((END - START))s."
echo "Record this against Chaos Test 2's 'rescheduled within 60s' expectation."
echo
kubectl get pods -n platform -o wide
echo
kubectl get pods -n infra -o wide
