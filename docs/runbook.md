# Runbook

How to deploy, roll back, diagnose, and extend this platform.

Everything below describes what the charts and scripts in this repo are
designed to do. None of it has run against a live cluster yet: the VMs in
the build plan's cluster topology have not been provisioned as of this
writing. Treat this as the intended procedure, and update it with what
actually happened the first time each step runs for real. A runbook that
only describes the design and never gets corrected against reality is
worse than not having one, because it reads as tested when it is not.

## Deploying from nothing

1. Provision the cluster per the build plan (kubeadm, 1 control-plane + 2
   workers, Flannel CNI). Not scripted here: kubeadm init/join happens once
   per cluster and touches host state this repo has no business managing.
2. Point `kubectl` at the new cluster.
3. `./scripts/setup-cluster.sh`: storage, ingress, metrics-server, and the
   monitoring stack (kube-prometheus-stack, prometheus-adapter). Idempotent;
   safe to re-run.
4. `./scripts/deploy-all.sh`: this platform's own charts, in dependency
   order (postgresql/redis/kafka, then the three application charts, then
   ServiceMonitors and alert rules). Also idempotent: database passwords
   are read back from the already-installed `postgresql-secret` rather than
   regenerated, specifically so re-running this does not desynchronize a
   chart's Secret from the password Postgres actually has on disk.
5. `./scripts/verify-custom-metrics.sh`: confirms which HPA metrics
   actually surfaced through prometheus-adapter before trusting any HPA
   that reads one. Two are expected to be missing today
   (`kafka_consumer_lag`, `distributed-job-queue`'s
   `http_requests_per_second`); see
   `manifests/prometheus/adapter-values.yaml` for why.

## Rolling back one component

Every component here is a Helm release, so a bad rollout rolls back the
same way:

```
helm history <release> -n <namespace>
helm rollback <release> <revision> -n <namespace>
```

Two things this does not undo:

- **A completed migration.** `distributed-job-queue` and `api-gateway`'s
  `alembic upgrade head` hook Jobs run once, on install or upgrade, before
  the Deployment changes. Rolling the Helm release back does not roll back
  the schema. If a bad release shipped a migration, fixing forward with a
  new migration is the only real option; `helm rollback` alone puts old
  code in front of a newer schema.
- **A rotated database password.** `scripts/deploy-all.sh` reuses the
  existing password from `postgresql-secret` by design, but a manual
  `--set secrets.eventsDbPassword=...` outside that script changes it for
  real, immediately, independent of any later `helm rollback`.

## A pod will not start

Read `kubectl describe pod` before `kubectl logs`, and both before editing
any YAML. The Events section at the bottom of `describe` answers most of
the table below outright.

| Symptom | Check first |
|---|---|
| `Pending` | `kubectl describe pod` for a scheduling reason. Usually no node has the requested CPU/memory, or a PVC has no StorageClass to bind against. Confirm `local-path` is the default: `kubectl get storageclass`. |
| `Pending`, specifically after a node drain | The pod's PVC was provisioned by `local-path` on the drained node. local-path volumes are pinned to one node's disk; the pod cannot move until that node returns. `scripts/chaos/kill-node.sh` prints this explanation automatically when it happens. |
| `ContainerCreating` stuck | Image pull failure. `kubectl describe pod` shows the exact registry error. Check `image.registry` in that chart's values against the actual node-reachable registry from Day 3 of the build plan. |
| `CrashLoopBackOff` | `kubectl logs POD --previous` before anything else. For `api-gateway` specifically: `gateway/config.py` refuses to start in production if `JWT_SECRET_KEY` is short/default, `DEBUG` is true, or `DATABASE_URL` still has the example password: the log line says exactly which. |
| Running, never `Ready` | Check `kubectl describe pod` for probe failures, then read the specific probe. `event-ingestion-api` and `distributed-job-queue`'s readiness probes only prove the process answers HTTP, not that Postgres or Redis is reachable. See the `probes` comment in each chart's `values.yaml`. |
| HPA shows `<unknown>` | Expected for `kafka_consumer_lag` and `distributed-job-queue`'s `http_requests_per_second` today; run `scripts/verify-custom-metrics.sh` to confirm it is one of those two and not a new regression. |
| Two pods of the same Deployment both `Pending` | Check the PodDisruptionBudget is not the cause: a `maxUnavailable: 1` PDB does not block scheduling, only voluntary eviction, so if this happens it is a resource or affinity problem, not the PDB. |

## Adding a node

```
# on the new node
sudo kubeadm join <control-plane-host>:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>

# from the workstation
kubectl get nodes -o wide
```

Generate a fresh join command from the control plane if the original one
has expired: `kubeadm token create --print-join-command`. Nothing in this
repo needs to know a worker joined; the scheduler picks it up automatically,
and `local-path-provisioner` (installed by `scripts/setup-cluster.sh`) runs
on every node without extra configuration.

## Running the chaos tests

```
./scripts/chaos/kill-pod.sh api-gateway
./scripts/chaos/kill-node.sh <node-name>
./scripts/chaos/memory-pressure.sh distributed-job-queue platform worker
./scripts/chaos/network-partition.sh platform infra
```

`network-partition.sh` does not use a NetworkPolicy: this cluster's CNI
(Flannel) does not enforce them, so a NetworkPolicy-based partition would
apply cleanly and do nothing. It drains the target namespace's Service
endpoints instead, which works regardless of CNI. See the script's own
header for the full reasoning, and see `manifests/networkpolicies.yaml`
for the NetworkPolicy objects that exist for when the CNI changes but are
inert today for the same reason.

## Known gaps, so they are not mistaken for bugs later

- **Every infra StatefulSet (postgresql, redis, kafka, zookeeper) runs a
  single replica.** The README's target topology is 3 and 3 with real
  replication; none of streaming replication, Sentinel, or multi-broker
  Kafka configuration exists yet. A pod loss on any of these is a real
  outage until that work lands, not a failover.
- **Redis has no password.** `protected-mode no` plus no `requirepass`,
  because neither app authenticates to it yet. See
  `helm/redis/templates/configmap.yaml`'s own comment for the three
  coordinated changes fixing this needs.
- **NetworkPolicies exist and enforce nothing**, because Flannel does not
  implement NetworkPolicy. Real enforcement needs a CNI swap to Calico or
  Cilium.
- **Two HPA metrics are documented gaps, not bugs:** `kafka_consumer_lag`
  (`event-ingestion-api`) and `http_requests_per_second`
  (`distributed-job-queue`'s api). Neither app exposes the underlying
  metric yet. Both HPAs sit at `minReplicas` until that changes.
- **`fsGroup: 999` on the postgresql StatefulSet is stated as an unverified
  assumption**, not a confirmed fact, in that chart's own comment. If the
  PVC mount comes up without write permission, that is the first thing to
  check with `kubectl exec ... -- id`.
- **The Grafana dashboards in `manifests/grafana/dashboards-configmap.yaml`
  have never rendered against a live Grafana.** The JSON is valid and the
  PromQL is written against confirmed metric names, but panel layout, units
  and legend formatting are unverified until someone actually opens them.
