#!/usr/bin/env bash
# Bootstraps a fresh kubeadm cluster with everything this platform's own
# charts assume already exists, but that no chart in helm/ should be
# responsible for installing itself: a StorageClass, an ingress controller,
# metrics-server, and the monitoring stack prometheus-adapter depends on.
#
# Deliberately separate from deploy-all.sh. This script installs
# cluster-wide infrastructure that is not specific to this platform and
# would be needed by any workload on this cluster; deploy-all.sh installs
# this platform's own charts on top of it. Splitting them is what makes
# "the cluster is broken" and "my chart is broken" two different, quickly
# distinguishable failure modes instead of one long script where either
# could be the culprit.
#
# Idempotent throughout (kubectl apply, helm upgrade --install), so running
# this again against a cluster that already has everything is a no-op, not
# an error.
#
# Requires: kubectl pointed at the target cluster, helm 3+, internet access
# from wherever this runs (fetches nothing itself; every manifest it
# applies is already vendored under manifests/, but the two Helm charts it
# installs are pulled from their upstream repos).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "== Namespaces =="
kubectl apply -f manifests/namespaces.yaml

echo
echo "== Storage: local-path-provisioner =="
# Pinned to the exact version the build plan specifies. A bare kubeadm
# cluster has no default StorageClass, so without this every PVC in the
# postgresql, redis and kafka charts sits Pending forever with no error
# beyond that one word.
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo
echo "== metrics-server =="
kubectl apply -f manifests/metrics-server.yaml

echo
echo "== ingress-nginx =="
kubectl apply -f manifests/ingress-nginx.yaml

echo
echo "== Waiting for ingress-nginx and metrics-server to become Ready =="
# Both are on the critical path for everything that follows: HPA needs
# metrics-server for CPU metrics even before prometheus-adapter enters the
# picture, and api-gateway's Ingress has nowhere to route without a
# running controller. Failing loudly here beats a confusing failure three
# steps later in deploy-all.sh.
kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=120s
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=controller -n ingress-nginx --timeout=180s

echo
echo "== Prometheus stack (kube-prometheus-stack) =="
# Installed before prometheus-adapter deliberately: adapter-values.yaml's
# prometheus.url points at the Service this chart creates, so the adapter
# would fail its own readiness checks trying to reach a Prometheus that
# does not exist yet if the order were reversed.
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update prometheus-community >/dev/null
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f manifests/prometheus/kube-prometheus-stack-values.yaml \
  --set grafana.adminPassword="$(openssl rand -hex 16)" \
  --wait --timeout 10m

echo
echo "== prometheus-adapter =="
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
  -n monitoring \
  -f manifests/prometheus/adapter-values.yaml \
  --wait --timeout 5m

echo
echo "== Done =="
echo "Cluster-wide infrastructure is up. Run scripts/deploy-all.sh next to"
echo "install this platform's own charts (postgresql, redis, kafka, then"
echo "the three application charts, then the ServiceMonitors and alert"
echo "rules)."
echo
echo "Grafana's admin password was generated above and not saved anywhere:"
echo "retrieve it with"
echo '  kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d'
