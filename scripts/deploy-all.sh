#!/usr/bin/env bash
# Installs this platform's own charts, in dependency order, on top of
# whatever scripts/setup-cluster.sh already installed (storage, ingress,
# metrics-server, the monitoring stack). Run that first.
#
# Order: infra (postgresql, redis, kafka) before platform (the three
# application charts), because api-gateway's and distributed-job-queue's
# migration Jobs run as pre-install hooks that need a reachable Postgres
# to apply a schema against. redis and kafka have no such hook, but are
# grouped with postgresql anyway since none of the three depend on the
# other two, and grouping by "does this need a hook target to exist
# first" is a less useful split than "is this infra or is this an app".
#
# The one thing this script has to get right that a plain sequence of
# `helm install` commands would not: every database password is generated
# exactly once, at first install, and reused on every later run of this
# script. The postgresql chart's own init script
# (helm/postgresql/templates/configmap.yaml) only creates each role and
# sets its password on first boot against an empty PVC, never again.
# Re-running this script with freshly generated passwords would push new
# Secret values to every app chart while the actual database roles kept
# their original ones, breaking every app's connection at once and
# calling it a successful deploy. Passwords are read back from the
# already-installed postgresql-secret when it exists, and only generated
# when it does not.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Reads one key out of an already-installed Secret, or prints nothing if
# the Secret or key does not exist yet. Never fails the script either way:
# a missing Secret means "first install", not an error.
read_secret_key() {
  local name=$1 namespace=$2 key=$3
  kubectl get secret "$name" -n "$namespace" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || true
}

# Returns the existing value for a key in postgresql-secret, or a freshly
# generated one. Called once per password, before postgresql is installed
# or upgraded, so the same value can then be handed to both the
# postgresql chart and the one app chart that authenticates as it.
get_or_generate_pg_password() {
  local key=$1
  local existing
  existing="$(read_secret_key postgresql-secret infra "$key")"
  if [[ -n "$existing" ]]; then
    echo "$existing"
  else
    openssl rand -hex 24
  fi
}

PG_SUPERUSER_PASSWORD="$(get_or_generate_pg_password POSTGRES_PASSWORD)"
EVENTS_DB_PASSWORD="$(get_or_generate_pg_password EVENTS_DB_PASSWORD)"
JOBQUEUE_DB_PASSWORD="$(get_or_generate_pg_password JOBQUEUE_DB_PASSWORD)"
GATEWAY_DB_PASSWORD="$(get_or_generate_pg_password GATEWAY_DB_PASSWORD)"

# JWT_SECRET_KEY has no cross-chart consumer the way the db passwords do,
# but the same reuse-on-upgrade logic applies: rotating it on every
# deploy-all.sh run would invalidate every access token issued since the
# last run, which is a self-inflicted outage for anyone mid-session.
JWT_EXISTING="$(read_secret_key api-gateway-secret platform JWT_SECRET_KEY)"
if [[ -n "$JWT_EXISTING" ]]; then
  JWT_SECRET_KEY="$JWT_EXISTING"
else
  JWT_SECRET_KEY="$(openssl rand -hex 32)"
fi

echo "== infra: postgresql =="
helm upgrade --install postgresql ./helm/postgresql -n infra \
  --set secrets.superuserPassword="$PG_SUPERUSER_PASSWORD" \
  --set secrets.eventsDbPassword="$EVENTS_DB_PASSWORD" \
  --set secrets.jobqueuePassword="$JOBQUEUE_DB_PASSWORD" \
  --set secrets.gatewayPassword="$GATEWAY_DB_PASSWORD" \
  --wait --timeout 5m

echo
echo "== infra: redis =="
helm upgrade --install redis ./helm/redis -n infra --wait --timeout 5m

echo
echo "== infra: kafka =="
helm upgrade --install kafka ./helm/kafka -n infra --wait --timeout 5m

echo
echo "== platform: event-ingestion-api =="
helm upgrade --install event-ingestion-api ./helm/event-ingestion-api -n platform \
  --set secrets.postgresPassword="$EVENTS_DB_PASSWORD" \
  --wait --timeout 5m

echo
echo "== platform: distributed-job-queue =="
helm upgrade --install distributed-job-queue ./helm/distributed-job-queue -n platform \
  --set secrets.postgresPassword="$JOBQUEUE_DB_PASSWORD" \
  --wait --timeout 5m

echo
echo "== platform: api-gateway =="
helm upgrade --install api-gateway ./helm/api-gateway -n platform \
  --set secrets.postgresPassword="$GATEWAY_DB_PASSWORD" \
  --set secrets.jwtSecretKey="$JWT_SECRET_KEY" \
  --wait --timeout 5m

echo
echo "== monitoring: ServiceMonitors and alert rules =="
# Applied last, and only meaningful if scripts/setup-cluster.sh already
# installed kube-prometheus-stack and prometheus-adapter: both the
# ServiceMonitor and PrometheusRule CRDs these objects use come from that
# stack, not from anything installed above.
kubectl apply -f manifests/prometheus/servicemonitors.yaml
kubectl apply -f manifests/prometheus/infra-servicemonitors.yaml
kubectl apply -f manifests/prometheus/alert-rules.yaml

echo
echo "== Done =="
kubectl get pods -n infra
echo
kubectl get pods -n platform
echo
echo "Verify custom metrics actually surfaced before trusting any HPA:"
echo "  ./scripts/verify-custom-metrics.sh"
